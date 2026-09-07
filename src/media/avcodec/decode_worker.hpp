#pragma once
#include "media/native_media_source.hpp"
#include "media/software_decoder_reservation.hpp"
#include "platform/macos/native_surface_budget.hpp"
#include <cstddef>
#include <cstdint>
#include <memory>
#include <span>

struct AVFrame;
namespace wam::media::avcodec {
// Decoder IDs are explicitly mapped at admission, never cast from MediaCodec.
enum class Codec : std::uint8_t { H264, Mpeg4, Vp9, Dts, TrueHd, Mlp };
struct PacketTiming {
  MediaTime pts{}, dts{}, duration{};
  std::uint64_t generation{}, epoch{};
};
enum class WorkerResult : std::uint8_t { Accepted, Backpressure, Failed, StaleGeneration };
enum class FrameResult : std::uint8_t { Accepted, Backpressure, Failed };
struct FrameHandler {
  FrameResult (*receive)(void*, const AVFrame&, const PacketTiming&) noexcept{};
  void* context{};
};
struct WakeHandler { void (*wake)(void*) noexcept{}; void* context{}; };
struct Configuration {
  Codec codec{};
  std::span<const std::byte> extradata{};
  std::uint64_t generation{1}, epoch{1};
  std::uint32_t width{}, height{}, rate{}, channels{};
  unsigned bitDepth{10}, chroma{2};
};
class DecodeWorker final {
public:
  // Four queue slots and 32 provenance slots bound queued and decoder-held packets.
  static constexpr std::size_t kPacketBytes = macos::kNativeSoftwarePacketBytes;
  static constexpr std::size_t kPacketSlots = macos::kNativeSoftwarePacketSlots;
  static constexpr std::size_t kProvenanceSlots = 32;
  // Coded geometry remains bounded before private byte reservation.
  static constexpr std::uint64_t kMaximumSoftwarePixels = macos::kNativeSoftwareMaximumPicturePixels;
  explicit DecodeWorker(FrameHandler handler, WakeHandler wake = {});
  ~DecodeWorker();
  DecodeWorker(const DecodeWorker&) = delete;
  DecodeWorker& operator=(const DecodeWorker&) = delete;
  bool configure(const Configuration& configuration);
  WorkerResult submit(std::span<const std::byte> bytes, PacketTiming timing);
  WorkerResult endOfStream(std::uint64_t generation);
  void retryOutput() noexcept;
  void close() noexcept;
  [[nodiscard]] bool hasCapacity() const noexcept;
  [[nodiscard]] bool drained() const noexcept;
  [[nodiscard]] std::size_t queuedPackets() const noexcept;
  [[nodiscard]] std::uint64_t compressedBytes() const noexcept;
  [[nodiscard]] std::uint64_t peakCompressedBytes() const noexcept;
  [[nodiscard]] const char* failure() const noexcept;
  [[nodiscard]] static std::uint64_t reservedProcessBytes() noexcept;
  [[nodiscard]] static unsigned reservedWorkers() noexcept;
  [[nodiscard]] std::span<std::byte> conversionStorage() noexcept;
private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};
}
