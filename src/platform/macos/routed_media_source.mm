#include "platform/macos/routed_media_source.hpp"
#include "media/audio_track_admission.hpp"
#include "media/libavformat_cursor.hpp"
#include "media/media_container_probe.hpp"
#include "platform/macos/avfoundation_media_source.hpp"
#include "platform/macos/libavformat_media_source.hpp"
#include "platform/macos/matroska_media_source.hpp"
#include "platform/macos/mpegts_media_source.hpp"
#include <array>
#include <cstdio>
#include <fcntl.h>
#include <sys/mount.h>
#include <unistd.h>
namespace wam::macos {
namespace {
class RoutedSource final : public media::MediaSource,
                           public media::AudioTrackRetrySource {
public:
  RoutedSource() {
    sources_[0] = std::make_unique<AVFoundationMediaSource>();
    sources_[1] = std::make_unique<MatroskaMediaSource>();
    sources_[2] = std::make_unique<MpegTsMediaSource>();
    sources_[3] = std::make_unique<LibavformatMediaSource>();
  }
  bool armOperation(media::MediaGeneration generation) noexcept override {
    if (active_)
      return active_->armOperation(generation);
    for (auto &source : sources_)
      if (!source->armOperation(generation))
        return false;
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
    struct statfs mount{};
    const bool buffered =
        ::statfs(path.c_str(), &mount) == 0 && !(mount.f_flags & MNT_LOCAL);
    const media::LibavformatCursor::Cancellation cancellation{
        sources_[3].get(), [](const void *source) noexcept {
          return static_cast<const media::MediaSource *>(source)
              ->stats()
              .cancelled;
        }};
    const bool recovery =
        backend == media::MediaSourceBackendKind::AVFoundation &&
        media::LibavformatCursor::requiresTailRecovery(path, cancellation);
    const auto selected =
        buffered || recovery ? 3U : static_cast<std::size_t>(backend);
    auto outcome = sources_[selected]->openLocalFile(path, options, generation);
    if (outcome.status == media::MediaSourceOpenStatus::Unsupported &&
        selected != 3 &&
        outcome.error.find("unlinked Matroska Segment") == std::string::npos) {
      const auto firstRefusal = outcome.error;
      sources_[selected]->close();
      outcome = sources_[3]->openLocalFile(path, options, generation);
      if (outcome.status == media::MediaSourceOpenStatus::Ready)
        active_ = sources_[3].get();
      else if (outcome.status == media::MediaSourceOpenStatus::Unsupported &&
               outcome.error != "this recording is incomplete: its "
                                "initialization metadata is missing")
        outcome.error = firstRefusal + "; libavformat: " + outcome.error;
    } else if (outcome.status == media::MediaSourceOpenStatus::Ready)
      active_ = sources_[selected].get();
    if (active_ == sources_[3].get())
      std::fprintf(stderr, "WAM: native demux stage=Libavformat\n");
    for (auto &source : sources_)
      if (source.get() != active_)
        source->close();
    return outcome;
  }
  media::MediaSourceOpenOutcome
  retryAudioTrack(const std::filesystem::path &path,
                  const media::MediaSourceOpenOptions &options,
                  media::MediaGeneration generation,
                  media::MediaTrackId rejected) override {
    if (auto *retry = dynamic_cast<media::AudioTrackRetrySource *>(active_))
      return retry->retryAudioTrack(path, options, generation, rejected);
    media::MediaSourceOpenOutcome out;
    out.generation = generation;
    out.error = "LibavformatAudioTrackRetryUnavailable";
    return out;
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
    for (auto &source : sources_)
      source->requestCancel(generation);
  }
  void close() noexcept override {
    for (auto &source : sources_)
      source->close();
    active_ = nullptr;
  }
  media::MediaSourceStats stats() const noexcept override {
    return active_ ? active_->stats() : media::MediaSourceStats{};
  }

private:
  std::array<std::unique_ptr<media::MediaSource>, 4> sources_;
  media::MediaSource *active_{};
};
} // namespace
std::unique_ptr<media::MediaSource> createRoutedMediaSource() {
  return std::make_unique<RoutedSource>();
}
} // namespace wam::macos
