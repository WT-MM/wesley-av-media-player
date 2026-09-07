#pragma once
#include "media/native_media_source.hpp"
#include "platform/macos/native_preview_source.hpp"
namespace wam::macos {
class LibavformatMediaSource final : public media::MediaSource {
public:
  LibavformatMediaSource();
  ~LibavformatMediaSource() override;
  bool armOperation(media::MediaGeneration) noexcept override;
  media::MediaSourceOpenOutcome
  openLocalFile(const std::filesystem::path &,
                const media::MediaSourceOpenOptions &,
                media::MediaGeneration) override;
  media::MediaSourceSeekOutcome
  seek(const media::MediaSourceSeekRequest &) override;
  media::MediaSourceReadResult readNext(media::MediaGeneration) override;
  void requestCancel(media::MediaGeneration) noexcept override;
  void close() noexcept override;
  media::MediaSourceStats stats() const noexcept override;

private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};
std::unique_ptr<NativePreviewSource>
    createLibavformatPreviewSource(NativePreviewBinding) noexcept;
} // namespace wam::macos
