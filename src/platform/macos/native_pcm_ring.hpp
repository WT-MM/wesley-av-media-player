#pragma once

#include <array>
#include <atomic>
#include <cstddef>
#include <cstdint>
#include <span>
#include <type_traits>

namespace wam::macos {

struct NativePcmRingTestAccess;
struct NativePcmRingLayoutAssertions;

// Fixed stereo Float32 SPSC handoff for a future native CoreAudio lane.
// publish() is producer-only and consume() is consumer-only. flush() is a
// single serialized control-owner operation: stop both endpoints before
// calling it, and never race it with publish(), consume(), or another flush().
class NativePcmRing final {
public:
  static constexpr std::size_t kChannels = 2;
  static constexpr std::size_t kFramesPerSlab = 4096;
  // Occupancy is counted in SLABS and the producer's admission unit is one
  // slab per converted input lease, so the reachable occupancy is
  // kSlabCount * (frames the codec puts in a slab), which for AAC-LC is 1024
  // -- not kSlabCount * kFramesPerSlab. Four slabs therefore carried exactly
  // four 1024-frame device periods of producer headroom, which was correct
  // while one device frame consumed exactly one media frame.
  //
  // Pitch-preserved playback rate breaks that identity: at 4x a single
  // 1024-frame device callback consumes 4096 MEDIA frames, i.e. the entire
  // four-slab reachable occupancy, leaving the producer zero headroom and
  // manufacturing a permanent underrun. The headroom inequality is really
  //   kDeviceBufferFrames * kMaximumNativeRate * kRingDevicePeriodsOfHeadroom
  //       <= kSlabCount * kMinimumFramesPerPublishedSlab
  // = 1024 * 4 * 4 = 16384 <= kSlabCount * 1024, so kSlabCount must be at
  // least 16. See the static_asserts in native_audio_output.hpp, which are
  // the enforcing statement of exactly this inequality.
  static constexpr std::size_t kSlabCount = 16;
  static constexpr std::size_t kSamplesPerSlab = kFramesPerSlab * kChannels;
  static constexpr std::size_t kPcmPayloadBytes =
      kSlabCount * kSamplesPerSlab * sizeof(float);

  enum class PublishResult : std::uint8_t {
    Published,
    Full,
    StaleGeneration,
    Invalid,
  };

  struct ReadableFramesResult {
    std::size_t frames{0};
    std::size_t staleSlabs{0};
    std::uint64_t generation{0};
    bool staleConsumer{false};
  };

  struct ConsumeResult {
    std::size_t pcmFrames{0};
    std::size_t silentFrames{0};
    std::size_t staleSlabs{0};
    std::uint64_t generation{0};
    bool underrun{false};
    bool staleConsumer{false};
    bool invalidInput{false};
  };

  // Lifetime counters saturate at UINT64_MAX rather than wrapping. This is a
  // bounded, race-free observation, not a transactional snapshot while the
  // SPSC endpoints are active.
  struct Stats {
    std::uint64_t generation{0};
    std::size_t queuedSlabs{0};
    // Exact unread interleaved stereo Float32 payload bytes currently owned by
    // the ring. This is logical live data, not the fixed 128 KiB storage
    // capacity. The high-water is diagnostic since the latest successful
    // generation transition or explicit reset and must not be added to another
    // owner's high-water.
    std::size_t unreadPcmBytes{0};
    std::size_t peakUnreadPcmBytes{0};

    std::uint64_t publishedSlabs{0};
    std::uint64_t publishedFrames{0};
    std::uint64_t fullPublishes{0};
    std::uint64_t stalePublishes{0};
    std::uint64_t invalidPublishes{0};
    std::uint64_t successfulFlushes{0};
    std::uint64_t invalidFlushes{0};

    std::uint64_t consumedFrames{0};
    std::uint64_t silentFrames{0};
    std::uint64_t underrunCallbacks{0};
    std::uint64_t staleConsumers{0};
    std::uint64_t staleSlabs{0};
    std::uint64_t invalidConsumers{0};
  };

  explicit NativePcmRing(std::uint64_t initialGeneration = 1) noexcept;

  NativePcmRing(const NativePcmRing &) = delete;
  NativePcmRing &operator=(const NativePcmRing &) = delete;
  NativePcmRing(NativePcmRing &&) = delete;
  NativePcmRing &operator=(NativePcmRing &&) = delete;

  // Copies one interleaved stereo slab into fixed storage. The input span must
  // contain exactly frameCount * kChannels samples. Requiring the exact size
  // rejects mono, multichannel, truncated, and overlong buffers at this seam.
  [[nodiscard]] PublishResult publish(std::uint64_t generation,
                                      std::span<const float> interleaved,
                                      std::size_t frameCount) noexcept;

  // Consumer-only, non-destructive preflight. It scans one acquire-published
  // snapshot of at most kSlabCount slabs, accounts for a partially consumed
  // current slab, and logically skips exactly the metadata consume() drops.
  // With no intervening consumer/control operation, a following valid
  // consume() request of at most min(result.frames, kFramesPerSlab) cannot
  // underrun. A concurrent producer may append and increase that availability,
  // but cannot reduce the reported lower bound. The call does not alter
  // cursors, statistics, payload, or slab metadata.
  [[nodiscard]] ReadableFramesResult
  readableFrames(std::uint64_t expectedGeneration) const noexcept;

  // Valid output is a nonempty, even-sized stereo span of at most
  // kFramesPerSlab frames. A valid stale-generation call is filled with
  // silence and does not drain current audio. A valid underrun copies queued
  // PCM and zeros exactly the missing tail. Invalid input is returned
  // untouched. An AudioUnit wrapper must treat invalidInput as a terminal
  // stream-format configuration error; it must not submit that buffer for
  // rendering.
  [[nodiscard]] ConsumeResult
  consume(std::uint64_t expectedGeneration,
          std::span<float> interleavedOutput) noexcept;

  // Consumer-only, copy-free retirement of already-superseded audio. The
  // single PCM consumer uses this after it has published media time across a
  // real device interval it could not fill: those frames have provably missed
  // their presentation instant, so playing them later would re-introduce the
  // exact drift the published clock refused. Returns the number of frames
  // actually retired, which is at most what the ring holds. It is bounded, and
  // it never crosses a generation change or invents silence.
  [[nodiscard]] std::size_t discard(std::uint64_t expectedGeneration,
                                    std::size_t frames) noexcept;

  // Immediately drops queued/partial audio and changes the accepted generation.
  // nextGeneration must be nonzero and strictly greater than generation(). One
  // serialized lifecycle owner calls flush only while both SPSC endpoints are
  // stopped; concurrent publish, consume, or flush calls are forbidden.
  [[nodiscard]] bool flush(std::uint64_t nextGeneration) noexcept;

  [[nodiscard]] std::uint64_t generation() const noexcept;
  [[nodiscard]] std::size_t queuedSlabs() const noexcept;
  [[nodiscard]] Stats stats() const noexcept;
  // Control-owner phase boundary. The SPSC endpoints must be stopped exactly
  // as for flush(). A successful reset seeds the diagnostic HWM from current
  // unread ownership rather than zero.
  [[nodiscard]] bool resetUnreadPcmByteHighWater(
      std::uint64_t expectedGeneration) noexcept;

private:
  // Apple silicon can use a 128-byte destructive-interference boundary. Use
  // that conservative separation on every platform so the RT consumer and
  // producer/control owners never share a hot cache line.
  static constexpr std::size_t kCacheLineBytes = 128;
  using PcmSlab = std::array<float, kSamplesPerSlab>;
  using PcmStorage = std::array<PcmSlab, kSlabCount>;

  struct alignas(kCacheLineBytes) ProducerCounters {
    std::atomic<std::uint64_t> publishedSlabs{0};
    std::atomic<std::uint64_t> publishedFrames{0};
    std::atomic<std::uint64_t> fullPublishes{0};
    std::atomic<std::uint64_t> stalePublishes{0};
    std::atomic<std::uint64_t> invalidPublishes{0};
    std::atomic<std::uint64_t> successfulFlushes{0};
    std::atomic<std::uint64_t> invalidFlushes{0};
  };

  struct alignas(kCacheLineBytes) ConsumerCounters {
    std::atomic<std::uint64_t> consumedFrames{0};
    std::atomic<std::uint64_t> silentFrames{0};
    std::atomic<std::uint64_t> underrunCallbacks{0};
    std::atomic<std::uint64_t> staleConsumers{0};
    std::atomic<std::uint64_t> staleSlabs{0};
    std::atomic<std::uint64_t> invalidConsumers{0};
  };

  static_assert(sizeof(PcmStorage) == kPcmPayloadBytes);
  // 16 slabs x 4096 frames x 2 channels x 4 bytes. The figure is spelled out
  // so that a change to kSlabCount or kFramesPerSlab has to state its new
  // resident cost here rather than growing it silently.
  static_assert(kPcmPayloadBytes == 524288);
  static_assert(sizeof(float) == 4);
  static_assert(std::atomic<std::uint64_t>::is_always_lock_free);
  static_assert(std::atomic<std::size_t>::is_always_lock_free);
  static_assert(alignof(ProducerCounters) >= kCacheLineBytes);
  static_assert(alignof(ConsumerCounters) >= kCacheLineBytes);

  static void saturatingAdd(std::atomic<std::uint64_t> &counter,
                            std::uint64_t amount) noexcept;
  void addUnreadPcmBytes(std::size_t bytes) noexcept;
  void removeUnreadPcmBytes(std::size_t bytes) noexcept;
  [[nodiscard]] static bool
  readableSlab(std::uint64_t slabGeneration, std::size_t slabFrames,
               std::size_t frameOffset,
               std::uint64_t activeGeneration) noexcept;

  alignas(kCacheLineBytes) PcmStorage pcm_{};
  std::array<std::uint64_t, kSlabCount> slabGenerations_{};
  std::array<std::uint32_t, kSlabCount> slabFrames_{};
  // Exact charged logical bytes remaining in each published slot. Keeping this
  // independent of format metadata makes accounting fail-safe even if a
  // malformed slab is discarded.
  std::array<std::size_t, kSlabCount> slabUnreadPcmBytes_{};

  alignas(kCacheLineBytes) std::atomic<std::uint64_t> readCursor_{0};
  std::size_t consumerOffsetFrames_{0};
  alignas(kCacheLineBytes) std::atomic<std::uint64_t> writeCursor_{0};
  alignas(kCacheLineBytes) std::atomic<std::uint64_t> generation_{1};

  ProducerCounters producerCounters_{};
  ConsumerCounters consumerCounters_{};
  // Producer and RT consumer both update these lock-free facts. Keeping them
  // on their own destructive-interference boundary avoids sharing either
  // endpoint's hot counter line.
  alignas(kCacheLineBytes) std::atomic<std::size_t> unreadPcmBytes_{0};
  std::atomic<std::size_t> peakUnreadPcmBytes_{0};

  friend struct NativePcmRingTestAccess;
  friend struct NativePcmRingLayoutAssertions;
};

struct NativePcmRingLayoutAssertions {
  static_assert(std::is_standard_layout_v<NativePcmRing>);
  static_assert(offsetof(NativePcmRing, writeCursor_) -
                    offsetof(NativePcmRing, readCursor_) >=
                NativePcmRing::kCacheLineBytes);
  static_assert(offsetof(NativePcmRing, generation_) -
                    offsetof(NativePcmRing, writeCursor_) >=
                NativePcmRing::kCacheLineBytes);
  static_assert(offsetof(NativePcmRing, producerCounters_) -
                    offsetof(NativePcmRing, generation_) >=
                NativePcmRing::kCacheLineBytes);
  static_assert(offsetof(NativePcmRing, consumerCounters_) -
                    offsetof(NativePcmRing, producerCounters_) >=
                NativePcmRing::kCacheLineBytes);
};

} // namespace wam::macos
