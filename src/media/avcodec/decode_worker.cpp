#include "decode_worker.hpp"
#include "media/avcodec_time.hpp"
extern "C" {
#include <libavcodec/avcodec.h>
#include <libavutil/buffer.h>
#include <libavutil/mem.h>
}
#include <array>
#include <atomic>
#include <cstring>
#include <limits>
#include <thread>

namespace wam::media::avcodec {
namespace {
constexpr std::array ids{AV_CODEC_ID_H264, AV_CODEC_ID_MPEG4, AV_CODEC_ID_VP9,
                        AV_CODEC_ID_DTS, AV_CODEC_ID_TRUEHD, AV_CODEC_ID_MLP};
std::atomic<unsigned> activeWorkers{0};
constexpr unsigned kMaximumWorkers = 16;
struct Provenance { PacketTiming timing; AVBufferRef* reference{}; };
void releaseProvenance(void*, std::uint8_t*) {}
bool timestampTicks(MediaTime time, std::int32_t scale, std::int64_t& result) {
  if (!time.valid()) { result = AV_NOPTS_VALUE; return true; }
  const auto product = __int128(time.value) * scale;
  if (product % time.timescale) return false;
  const auto ticks = product / time.timescale;
  if (ticks <= std::numeric_limits<std::int64_t>::min() ||
      ticks > std::numeric_limits<std::int64_t>::max()) return false;
  result = static_cast<std::int64_t>(ticks);
  return true;
}
}
struct DecodeWorker::Impl {
  struct Slot {
    std::unique_ptr<std::byte[]> bytes;
    std::size_t size{};
    PacketTiming timing;
  };
  FrameHandler handler;
  WakeHandler wake;
  Configuration configuration;
  std::unique_ptr<std::byte[]> extra;
  std::array<Slot, kPacketSlots> slots;
  std::array<Provenance, kProvenanceSlots> provenance;
  std::atomic<std::uint64_t> read{0}, write{0}, signal{0}, bytes{0}, peakBytes{0};
  std::atomic<bool> stopping{false}, ready{false}, eos{false}, done{false};
  std::atomic<const char*> error{nullptr};
  std::thread worker;
  AVCodecContext* context{};
  AVPacket* packet{};
  AVFrame* frame{};
  bool counted{};
  void notify() noexcept { signal.fetch_add(1, std::memory_order_release); signal.notify_one(); }
  void ownerWake() noexcept { if (wake.wake) wake.wake(wake.context); }
  void fail(const char* reason) noexcept { error.store(reason, std::memory_order_release); ownerWake(); }
  bool open() {
    const auto index = static_cast<std::size_t>(configuration.codec);
    const AVCodec* codec = index < ids.size() ? avcodec_find_decoder(ids[index]) : nullptr;
    if (!codec) { fail("AvcodecDecoderUnavailable"); return false; }
    context = avcodec_alloc_context3(codec);
    packet = av_packet_alloc();
    frame = av_frame_alloc();
    if (!context || !packet || !frame) { fail("AvcodecAllocationFailed"); return false; }
    context->thread_count = 1;
    context->thread_type = 0;
    context->err_recognition = AV_EF_BITSTREAM | AV_EF_BUFFER | AV_EF_EXPLODE;
    context->flags |= AV_CODEC_FLAG_COPY_OPAQUE;
    // WAM owns all publication trimming; libavcodec exposes skip metadata.
    context->flags2 |= AV_CODEC_FLAG2_SKIP_MANUAL;
    context->max_pixels = kMaximumSoftwarePixels;
    context->max_samples = 65536;
    context->width = static_cast<int>(configuration.width);
    context->height = static_cast<int>(configuration.height);
    context->sample_rate = static_cast<int>(configuration.rate);
    av_channel_layout_default(&context->ch_layout, static_cast<int>(configuration.channels));
    if (!configuration.extradata.empty()) {
      context->extradata = static_cast<std::uint8_t*>(av_mallocz(configuration.extradata.size() + AV_INPUT_BUFFER_PADDING_SIZE));
      if (!context->extradata) { fail("AvcodecExtradataAllocationFailed"); return false; }
      context->extradata_size = static_cast<int>(configuration.extradata.size());
      std::memcpy(context->extradata, configuration.extradata.data(), configuration.extradata.size());
    }
    for (auto& record : provenance) {
      record.reference = av_buffer_create(reinterpret_cast<std::uint8_t*>(&record),
          sizeof(Provenance), releaseProvenance, nullptr, 0);
      if (!record.reference) { fail("AvcodecProvenanceAllocationFailed"); return false; }
    }
    if (avcodec_open2(context, codec, nullptr) < 0) { fail("AvcodecOpenFailed"); return false; }
    return true;
  }
  void run() noexcept {
    const bool opened = open();
    ready.store(true, std::memory_order_release);
    ready.notify_one();
    bool retainedFrame = false, retainedPacket = false, sentEos = false;
    std::int32_t scale = 0;
    while (opened && !stopping.load(std::memory_order_acquire) && !error.load()) {
      const auto observed = signal.load(std::memory_order_acquire);
      if (retainedFrame) {
        const auto* provenanceRecord = frame->opaque_ref
          ? reinterpret_cast<const Provenance*>(frame->opaque_ref->data) : nullptr;
        if (!provenanceRecord) { fail("AvcodecFrameProvenanceMissing"); break; }
        PacketTiming timing = provenanceRecord->timing;
        if (frame->pts != AV_NOPTS_VALUE) {
          auto exact = avcodecExactTime(frame->pts, 1, scale);
          if (!exact) { fail("AvcodecTimestampUnrepresentable"); break; }
          timing.pts = *exact;
        }
        if (frame->duration > 0) {
          auto exact = avcodecExactTime(frame->duration, 1, scale);
          if (!exact) { fail("AvcodecDurationUnrepresentable"); break; }
          timing.duration = *exact;
        }
        const auto result = handler.receive(handler.context, *frame, timing);
        if (result == FrameResult::Failed) { fail("AvcodecFrameRefused"); break; }
        if (result == FrameResult::Backpressure) { signal.wait(observed); continue; }
        av_frame_unref(frame);
        retainedFrame = false;
        ownerWake();
      }
      const int received = avcodec_receive_frame(context, frame);
      if (received == 0) { retainedFrame = true; continue; }
      if (received == AVERROR_EOF) { done.store(true, std::memory_order_release); ownerWake(); break; }
      if (received != AVERROR(EAGAIN)) { fail("AvcodecReceiveFailed"); break; }
      const auto head = read.load(std::memory_order_relaxed);
      if (head < write.load(std::memory_order_acquire)) {
        auto& slot = slots[head % kPacketSlots];
        if (!retainedPacket) {
          if (!scale) {
            if (!slot.timing.pts.valid()) { fail("AvcodecPacketTimestampMissing"); break; }
            const auto divisor = std::gcd(slot.timing.pts.timescale, slot.timing.duration.timescale);
            if (divisor <= 0) { fail("AvcodecPacketDurationMissing"); break; }
            const auto common = std::int64_t(slot.timing.pts.timescale / divisor) * slot.timing.duration.timescale;
            if (common <= 0 || common > INT32_MAX) { fail("AvcodecTimeBaseUnrepresentable"); break; }
            scale = static_cast<std::int32_t>(common);
            context->pkt_timebase = AVRational{1, scale};
          }
          Provenance* record = nullptr;
          for (auto& candidate : provenance) {
            if (av_buffer_get_ref_count(candidate.reference) == 1) { record = &candidate; break; }
          }
          if (!record) { fail("AvcodecProvenanceBudgetExceeded"); break; }
          record->timing = slot.timing;
          // Refcount metadata and decoder-owned packet copies stay on this worker.
          packet->opaque_ref = av_buffer_ref(record->reference);
          if (!packet->opaque_ref) { fail("AvcodecPacketReferenceFailed"); break; }
          packet->data = reinterpret_cast<std::uint8_t*>(slot.bytes.get());
          packet->size = static_cast<int>(slot.size);
          if (!timestampTicks(slot.timing.pts, scale, packet->pts) ||
              !timestampTicks(slot.timing.dts, scale, packet->dts) ||
              !timestampTicks(slot.timing.duration, scale, packet->duration)) {
            fail("AvcodecTimestampUnrepresentable"); break;
          }
          packet->time_base = context->pkt_timebase;
          retainedPacket = true;
        }
        const int sent = avcodec_send_packet(context, packet);
        // receive EAGAIN followed by send EAGAIN violates the codec API contract.
        if (sent < 0) { fail(sent == AVERROR(EAGAIN) ? "AvcodecSendReceiveDeadlock" : "AvcodecPacketRefused"); break; }
        av_packet_unref(packet);
        retainedPacket = false;
        bytes.fetch_sub(slot.size, std::memory_order_relaxed);
        read.store(head + 1, std::memory_order_release);
        ownerWake();
        continue;
      }
      if (eos.load(std::memory_order_acquire) && !sentEos) {
        if (avcodec_send_packet(context, nullptr) < 0) { fail("AvcodecDrainRefused"); break; }
        sentEos = true;
        continue;
      }
      if (sentEos) { fail("AvcodecDrainNeedsInput"); break; }
      signal.wait(observed);
    }
    av_frame_free(&frame);
    av_packet_free(&packet);
    avcodec_free_context(&context);
    for (auto& record : provenance) av_buffer_unref(&record.reference);
  }
};
DecodeWorker::DecodeWorker(FrameHandler handler, WakeHandler wake) : impl_(std::make_unique<Impl>()) {
  impl_->handler = handler; impl_->wake = wake;
}
DecodeWorker::~DecodeWorker() { close(); }
bool DecodeWorker::configure(const Configuration& configuration) {
  auto& s = *impl_;
  if (s.worker.joinable() || !s.handler.receive || !configuration.generation ||
      configuration.extradata.size() > MediaSourceLimits::kHardMaximumCodecConfigurationBytes) return false;
  if (std::uint64_t(configuration.width) * configuration.height > kMaximumSoftwarePixels) {
    s.fail("AvcodecSoftwareReferenceBudgetExceeded"); return false;
  }
  if (activeWorkers.fetch_add(1) >= kMaximumWorkers) {
    activeWorkers.fetch_sub(1); s.fail("AvcodecWorkerBudgetExceeded"); return false;
  }
  s.counted = true;
  s.configuration = configuration;
  try {
    s.extra = std::make_unique<std::byte[]>(configuration.extradata.size());
    if (!configuration.extradata.empty()) std::memcpy(s.extra.get(), configuration.extradata.data(), configuration.extradata.size());
    s.configuration.extradata = {s.extra.get(), configuration.extradata.size()};
    for (auto& slot : s.slots) slot.bytes = std::make_unique<std::byte[]>(kPacketBytes + AV_INPUT_BUFFER_PADDING_SIZE);
    s.worker = std::thread([&s] { s.run(); });
    s.ready.wait(false);
  } catch (...) { s.fail("AvcodecWorkerAllocationFailed"); return false; }
  return !s.error.load(std::memory_order_acquire);
}
WorkerResult DecodeWorker::submit(std::span<const std::byte> bytes, PacketTiming timing) {
  auto& s = *impl_;
  if (timing.generation != s.configuration.generation || timing.epoch != s.configuration.epoch) return WorkerResult::StaleGeneration;
  if (bytes.empty() || bytes.size() > kPacketBytes || s.error.load() || s.eos.load() || !s.ready.load()) return WorkerResult::Failed;
  const auto tail = s.write.load(std::memory_order_relaxed);
  if (tail - s.read.load(std::memory_order_acquire) >= kPacketSlots) return WorkerResult::Backpressure;
  auto& slot = s.slots[tail % kPacketSlots];
  std::memcpy(slot.bytes.get(), bytes.data(), bytes.size());
  std::memset(slot.bytes.get() + bytes.size(), 0, AV_INPUT_BUFFER_PADDING_SIZE);
  slot.size = bytes.size(); slot.timing = timing;
  const auto current=s.bytes.fetch_add(bytes.size(),std::memory_order_relaxed)+bytes.size();
  if(current>s.peakBytes.load(std::memory_order_relaxed))s.peakBytes.store(current,std::memory_order_relaxed);
  s.write.store(tail + 1, std::memory_order_release);
  s.notify();
  return WorkerResult::Accepted;
}
WorkerResult DecodeWorker::endOfStream(std::uint64_t generation) {
  auto& s = *impl_;
  if (generation != s.configuration.generation) return WorkerResult::StaleGeneration;
  if (s.error.load() || !s.ready.load()) return WorkerResult::Failed;
  s.eos.store(true, std::memory_order_release); s.notify(); return WorkerResult::Accepted;
}
void DecodeWorker::retryOutput() noexcept { impl_->notify(); }
void DecodeWorker::close() noexcept {
  auto& s = *impl_;
  s.stopping.store(true, std::memory_order_release); s.notify();
  if (s.worker.joinable()) s.worker.join();
  if (s.counted) { activeWorkers.fetch_sub(1); s.counted = false; }
}
bool DecodeWorker::hasCapacity() const noexcept {
  const auto& s = *impl_;
  return s.ready.load() && !s.stopping.load() && !s.eos.load() && !s.error.load() &&
      s.write.load() - s.read.load() < kPacketSlots;
}
bool DecodeWorker::drained() const noexcept { return impl_->done.load(std::memory_order_acquire); }
std::size_t DecodeWorker::queuedPackets() const noexcept {
  return static_cast<std::size_t>(impl_->write.load(std::memory_order_acquire)-impl_->read.load(std::memory_order_acquire));
}
std::uint64_t DecodeWorker::compressedBytes() const noexcept { return impl_->bytes.load(std::memory_order_relaxed); }
std::uint64_t DecodeWorker::peakCompressedBytes() const noexcept { return impl_->peakBytes.load(std::memory_order_relaxed); }
const char* DecodeWorker::failure() const noexcept { return impl_->error.load(std::memory_order_acquire); }
}
