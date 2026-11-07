#include "platform/macos/routed_media_source.hpp"
#include "media/audio_track_admission.hpp"
#include "media/libavformat_cursor.hpp"
#include "media/media_container_probe.hpp"
#include "platform/macos/avfoundation_media_source.hpp"
#include "platform/macos/libavformat_media_source.hpp"
#include "platform/macos/matroska_media_source.hpp"
#include "platform/macos/mpegts_media_source.hpp"
#include <array>
#include <atomic>
#include <cstdio>
#include <fcntl.h>
#include <unistd.h>
namespace wam::macos {
namespace {
class RoutedSource final : public media::MediaSource {
public:
  bool armOperation(media::MediaGeneration generation) noexcept override {
    if (active_)
      return active_->armOperation(generation);
    for (auto *source : all())
      if (!source->armOperation(generation))
        return false;
    armed_.store(generation, std::memory_order_release);
    return true;
  }
  media::MediaSourceOpenOutcome
  openLocalFile(const std::filesystem::path &path,
                const media::MediaSourceOpenOptions &options,
                media::MediaGeneration generation) override {
    std::array<std::byte, 1024> bytes{};
    const int fd = ::open(path.c_str(), O_RDONLY | O_NONBLOCK | O_CLOEXEC);
    const ssize_t count =
        fd < 0 ? -1 : ::pread(fd, bytes.data(), bytes.size(), 0);
    if (fd >= 0)
      ::close(fd);
    const auto backend =
        media::containerBackendForBytes(std::span<const std::byte>(bytes).first(
                                            count > 0 ? std::size_t(count) : 0),
                                        path);
    const media::CancellationToken cancellation{
        this, [](const void *router) noexcept {
          return static_cast<const RoutedSource *>(router)->cancelled();
        }};
    const bool recovery =
        backend == media::MediaSourceBackendKind::AVFoundation &&
        media::LibavformatCursor::requiresExactDemuxTimeline(path, cancellation);
    media::MediaSource *selected =
        options.bufferedStorage || recovery ? &libavformat_ : &sourceFor(backend);
    auto outcome = selected->openLocalFile(path, options, generation);
    if (outcome.status == media::MediaSourceOpenStatus::Unsupported &&
        selected != &libavformat_ &&
        outcome.refusal != media::MediaRefusalClass::SegmentLayout) {
      const auto firstRefusal = outcome.error;
      selected->close();
      selected = &libavformat_;
      outcome = selected->openLocalFile(path, options, generation);
      if (outcome.status == media::MediaSourceOpenStatus::Unsupported &&
          outcome.refusal != media::MediaRefusalClass::MissingInitialization)
        outcome.error = firstRefusal + "; libavformat: " + outcome.error;
    }
    if (outcome.status == media::MediaSourceOpenStatus::Ready)
      active_ = selected;
    if (active_ == &libavformat_)
      std::fprintf(stderr, "WAM: native demux stage=Libavformat\n");
    for (auto *source : all())
      if (source != active_)
        source->close();
    return outcome;
  }
  [[nodiscard]] bool supportsAudioTrackRetry() const noexcept override {
    return active_ && active_->supportsAudioTrackRetry();
  }
  media::MediaSourceOpenOutcome
  retryAudioTrack(const std::filesystem::path &path,
                  const media::MediaSourceOpenOptions &options,
                  media::MediaGeneration generation,
                  media::MediaTrackId rejected) override {
    return active_ ? active_->retryAudioTrack(path, options, generation, rejected)
                   : MediaSource::retryAudioTrack(path, options, generation,
                                                  rejected);
  }
  media::MediaSourceSeekOutcome
  seek(const media::MediaSourceSeekRequest &request) override {
    if (active_)
      return active_->seek(request);
    media::MediaSourceSeekOutcome out;
    out.generation = request.generation;
    out.error = "DemuxSourceNotOpen";
    return out;
  }
  media::MediaSourceReadResult
  readNext(media::MediaGeneration generation) override {
    return active_ ? active_->readNext(generation)
                   : media::MediaSourceReadResult(media::MediaSourceFailure{
                         generation, "DemuxSourceNotOpen"});
  }
  void requestCancel(media::MediaGeneration generation) noexcept override {
    if (generation != 0 &&
        armed_.load(std::memory_order_acquire) == generation)
      cancelled_.store(generation, std::memory_order_release);
    for (auto *source : all())
      source->requestCancel(generation);
  }
  void close() noexcept override {
    for (auto *source : all())
      source->close();
    active_ = nullptr;
    armed_.store(0, std::memory_order_release);
  }
  media::MediaSourceStats stats() const noexcept override {
    return active_ ? active_->stats() : media::MediaSourceStats{};
  }

private:
  [[nodiscard]] bool cancelled() const noexcept {
    const auto armed = armed_.load(std::memory_order_acquire);
    return armed != 0 && cancelled_.load(std::memory_order_acquire) == armed;
  }
  media::MediaSource &sourceFor(media::MediaSourceBackendKind kind) noexcept {
    switch (kind) {
    case media::MediaSourceBackendKind::AVFoundation:
      return avfoundation_;
    case media::MediaSourceBackendKind::Matroska:
      return matroska_;
    case media::MediaSourceBackendKind::MpegTs:
      return mpegts_;
    case media::MediaSourceBackendKind::Libavformat:
      return libavformat_;
    }
    return libavformat_;
  }
  [[nodiscard]] std::array<media::MediaSource *, 4> all() noexcept {
    return {&avfoundation_, &matroska_, &mpegts_, &libavformat_};
  }

  AVFoundationMediaSource avfoundation_;
  MatroskaMediaSource matroska_;
  MpegTsMediaSource mpegts_;
  LibavformatMediaSource libavformat_;
  media::MediaSource *active_{};
  // The open's own cancellation, for the pre-open timeline probe.
  std::atomic<media::MediaGeneration> armed_{0};
  std::atomic<media::MediaGeneration> cancelled_{0};
};
} // namespace
std::unique_ptr<media::MediaSource> createRoutedMediaSource() {
  return std::make_unique<RoutedSource>();
}
} // namespace wam::macos
