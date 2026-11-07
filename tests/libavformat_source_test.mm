#include "media/avcodec_time.hpp"
#include "media/libavformat_cursor.hpp"
#include "media/media_container_probe.hpp"
#include "platform/macos/libavformat_media_source.hpp"
#include "platform/macos/routed_media_source.hpp"
#include "support/expect.hpp"
#include <fstream>
#include <iostream>
#include <limits>
#include <unistd.h>

int main(int argc, char **argv) {
  using namespace wam::media;
  using namespace wam::macos;
  if (argc < 2)
    return 2;
  EXPECT(!avcodecExactTime(INT64_MIN, 1, 90000));
  EXPECT(!avcodecExactTime(INT64_MAX, 2, 1));
  EXPECT(avcodecExactTime(9007199254740993LL, 1, 90000)->value ==
          3002399751580331LL);
  const std::filesystem::path path(argv[1]);
  auto source = argc > 3 && std::string_view(argv[3]) == "routed"
                    ? createRoutedMediaSource()
                    : std::make_unique<LibavformatMediaSource>();
  MediaSourceOpenOptions options;
  options.selection.requireAudio = false;
  options.selection.requireVideo = false;
  REQUIRE(source->armOperation(1));
  const auto opened = source->openLocalFile(path, options, 1);
  std::cout << "status=" << unsigned(opened.status) << " error=" << opened.error
            << '\n';
  if (argc > 2 && std::string_view(argv[2]) != "ready") {
    REQUIRE(opened.status == MediaSourceOpenStatus::Unsupported);
    EXPECT(opened.error == argv[2]);
    EXPECT(!opened.preparedContext);
    return failures == 0 ? 0 : 1;
  }
  REQUIRE(opened.status == MediaSourceOpenStatus::Ready);
  if (path.filename() == "asp-full.mkv") {
    REQUIRE(opened.descriptor->tracks.front().video);
    EXPECT(opened.descriptor->tracks.front().video->fullRangeVideo);
  }
  REQUIRE(opened.preparedContext->backendKind() ==
          MediaSourceBackendKind::Libavformat);
  EXPECT(opened.preparedContext->descriptor() == opened.descriptor);
  std::uint64_t packets{}, bytes{};
  bool eos = false;
  for (;;) {
    auto result = source->readNext(1);
    if (auto *sample = std::get_if<MediaSample>(&result)) {
      EXPECT(!eos);
      EXPECT(validateMediaSample(*sample, *opened.descriptor, options.limits));
      EXPECT(sample->presentationTime.valid());
      EXPECT(sample->duration.valid());
      EXPECT(sample->payload.contiguousBytes().size() ==
              sample->payload.byteSize());
      ++packets;
      bytes += sample->payload.byteSize();
    } else if (std::holds_alternative<MediaEndOfStream>(result)) {
      EXPECT(!eos);
      eos = true;
    } else if (std::holds_alternative<MediaSourceExhausted>(result))
      break;
    else {
      if (auto *error = std::get_if<MediaSourceFailure>(&result))
        std::cerr << error->error << '\n';
      REQUIRE(false);
    }
  }
  EXPECT(eos && packets > 0);
  if (path.filename() == "fragmented.mp4" || path.filename() == "asp.avi")
    EXPECT(packets == 75);
  if (path.filename() == "boundary.mp4" || path.filename() == "mid-moof.mp4" ||
      path.filename() == "mid-mdat.mp4")
    EXPECT(packets == 50);
  std::cout << "packets=" << packets << " bytes=" << bytes
            << " duration=" << opened.descriptor->duration.value << '/'
            << opened.descriptor->duration.timescale << '\n';
  REQUIRE(source->armOperation(2));
  const auto seek = source->seek({2, {1, 2}, MediaSeekMode::Accurate});
  std::cout << "seek=" << seek.accepted << " error=" << seek.error << '\n';
  EXPECT(seek.accepted);
  EXPECT(seek.preparedContext == opened.preparedContext);
  EXPECT(compareMediaTime(seek.actualDecodeStart, {1, 2}) !=
          MediaTimeOrder::Greater);
  auto first = source->readNext(2);
  REQUIRE(std::holds_alternative<MediaSample>(first));
  EXPECT(std::get<MediaSample>(first).keyFrame);
  auto preview = createLibavformatPreviewSource(
      {path, opened.descriptor, options.limits, opened.preparedContext});
  REQUIRE(preview);
  const auto begun = preview->begin({1, {1, 2}});
  EXPECT(begun.status == NativePreviewStatus::Ready);
  auto previewSample = preview->readNext(1);
  REQUIRE(std::holds_alternative<MediaSample>(previewSample));
  EXPECT(std::get<MediaSample>(previewSample).keyFrame);
  preview->requestCancel(9);
  EXPECT(!preview->facts().cancelled);
  preview->requestCancel(1);
  EXPECT(std::holds_alternative<NativePreviewCancelled>(preview->readNext(1)));
  // At its end the preview reader stays open: a repeated read is end of
  // stream again and a forward retarget is still served.
  const MediaTime end = opened.descriptor->duration;
  REQUIRE(preview->begin({2, end}).status == NativePreviewStatus::Ready);
  bool ended = false;
  for (unsigned i = 0; i < 1000 && !ended; ++i) {
    const auto read = preview->readNext(2);
    REQUIRE(std::holds_alternative<MediaSample>(read) ||
            std::holds_alternative<NativePreviewEndOfStream>(read));
    ended = std::holds_alternative<NativePreviewEndOfStream>(read);
  }
  EXPECT(ended);
  EXPECT(std::holds_alternative<NativePreviewEndOfStream>(preview->readNext(2)));
  EXPECT(preview->facts().open && preview->advanceTarget(2, end));
  preview->close();
  source->requestCancel(1);
  EXPECT(!source->stats().cancelled);
  source->requestCancel(2);
  EXPECT(std::holds_alternative<MediaSourceCancelled>(source->readNext(2)));
  source->close();
  REQUIRE(source->armOperation(3));
  source->requestCancel(3);
  EXPECT(source->openLocalFile(path, options, 3).status ==
          MediaSourceOpenStatus::Cancelled);
  if (path.filename() == "fragmented.mp4") {
    LibavformatMediaSource retained;
    REQUIRE(retained.armOperation(1));
    REQUIRE(retained.openLocalFile(path, options, 1).status ==
            MediaSourceOpenStatus::Ready);
    std::vector<MediaSample> leases;
    leases.reserve(32);
    for (unsigned i = 0; i < 32; ++i) {
      auto read = retained.readNext(1);
      REQUIRE(std::holds_alternative<MediaSample>(read));
      leases.push_back(std::move(std::get<MediaSample>(read)));
    }
    const auto limited = retained.readNext(1);
    REQUIRE(std::holds_alternative<MediaSourceFailure>(limited));
    EXPECT(std::get<MediaSourceFailure>(limited).error ==
            "LibavformatPayloadLeaseLimit");
    retained.close();
    EXPECT(!leases.front().payload.contiguousBytes().empty());
    const auto temporary =
        std::filesystem::path("/private/tmp") /
        ("wam-avformat-identity-" + std::to_string(getpid()) + ".mp4");
    const auto backup = temporary.string() + ".original";
    struct Cleanup {
      std::filesystem::path first, second;
      ~Cleanup() {
        std::error_code error;
        std::filesystem::remove(first, error);
        std::filesystem::remove(second, error);
      }
    } cleanup{temporary, backup};
    std::filesystem::copy_file(
        path, temporary, std::filesystem::copy_options::overwrite_existing);
    LibavformatCursor cursor;
    std::atomic<bool> cancelled{};
    std::string error;
    LibavformatCursor::Packet packet;
    REQUIRE(cursor.open(temporary, cancelled, error));
    EXPECT(cursor.read(packet, error) == LibavformatCursor::Read::Packet);
    {
      std::ofstream changed(temporary, std::ios::binary | std::ios::app);
      changed.put('x');
    }
    EXPECT(cursor.read(packet, error) == LibavformatCursor::Read::Failed);
    EXPECT(error == "LibavformatFileChanged");
    std::filesystem::copy_file(
        path, temporary, std::filesystem::copy_options::overwrite_existing);
    LibavformatMediaSource identity;
    REQUIRE(identity.armOperation(1));
    const auto admitted = identity.openLocalFile(temporary, options, 1);
    REQUIRE(admitted.status == MediaSourceOpenStatus::Ready);
    auto rebound = createLibavformatPreviewSource(
        {temporary, admitted.descriptor, options.limits,
         admitted.preparedContext});
    REQUIRE(rebound);
    std::filesystem::rename(temporary, backup);
    std::filesystem::copy_file(path, temporary);
    const auto changed = rebound->begin({1, {1, 2}});
    EXPECT(changed.status == NativePreviewStatus::Failed);
    EXPECT(changed.error == "LibavformatFileChanged");
    std::cout << "retained lease limit, file growth, preview file replacement "
                 "passed\n";
  }
  return failures == 0 ? 0 : 1;
}
