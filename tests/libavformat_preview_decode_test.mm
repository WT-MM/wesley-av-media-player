#include "platform/macos/libavformat_media_source.hpp"
#include "platform/macos/native_preview_frame_lane.hpp"
#include <chrono>
#include <iostream>
#include <thread>

using namespace wam::macos;
using namespace wam::media;
namespace protocol = wam::media::native_playback;
class DecodedPort final : public NativeTrackedVideoPreviewPort {
public:
  FrameTiming timing{};
  bool submitted{};
  std::optional<NativeTrackedVideoPreviewEvent> terminal;
  NativeTrackedVideoCapacity
  capacity(std::uint64_t generation) const noexcept override {
    return generation != 1 ? NativeTrackedVideoCapacity::StaleGeneration
           : submitted     ? NativeTrackedVideoCapacity::Backpressure
                           : NativeTrackedVideoCapacity::Available;
  }
  NativeTrackedVideoPreviewSubmitResult
  submit(std::uint64_t, const FrameLease &frame,
         std::string *) noexcept override {
    timing = frame.timing();
    submitted = true;
    return {NativeTrackedVideoSubmitStatus::Accepted, {1}};
  }
  std::optional<NativeTrackedVideoPreviewEvent> takeEvent() noexcept override {
    auto result = terminal;
    terminal.reset();
    if (result)
      submitted = false;
    return result;
  }
  NativeTrackedVideoPreviewCancelProgress cancel() noexcept override {
    if (submitted)
      terminal = NativeTrackedVideoPreviewEvent{
          NativeTrackedVideoPreviewEventKind::FrameSuperseded,
          1,
          {1},
          1,
          timing};
    return submitted ? NativeTrackedVideoPreviewCancelProgress::Quiescing
                     : NativeTrackedVideoPreviewCancelProgress::Done;
  }
};
int main(int argc, char **argv) {
  if (argc < 2)
    return 2;
  const double seconds = argc > 2 ? std::stod(argv[2]) : 0.5;
  LibavformatMediaSource source;
  MediaSourceOpenOptions options;
  options.selection.requireAudio = false;
  if (!source.armOperation(1))
    return 1;
  const auto opened = source.openLocalFile(argv[1], options, 1);
  if (opened.status != MediaSourceOpenStatus::Ready) {
    std::cerr << opened.error << '\n';
    return 1;
  }
  NativePreviewBinding binding{argv[1], opened.descriptor, options.limits,
                               opened.preparedContext};
  auto port = std::make_shared<DecodedPort>();
  auto wake = std::make_shared<int>();
  auto lane =
      NativePreviewFrameLane::create({binding, {1}, {{1}, {1}}}, port,
                                     {wake, [](void *) noexcept {}, wake.get()},
                                     createLibavformatPreviewSource(binding));
  if (!lane) {
    std::cerr << "PreviewLaneNotAdmitted\n";
    return 1;
  }
  const auto target = NativePreviewFrameLane::preflightTarget(seconds);
  if (!target || lane->request({{{1}, {2}}, {1}, {1}, {1}, seconds}, *target) !=
                     NativePreviewFrameRequestStatus::Accepted)
    return 1;
  auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(5);
  while (!port->submitted && std::chrono::steady_clock::now() < deadline) {
    if (lane->pump() == NativePreviewFramePumpProgress::Failed)
      break;
    std::this_thread::sleep_for(std::chrono::milliseconds(1));
  }
  const auto facts = lane->facts();
  const auto t = port->timing;
  const auto before =
      CMTimeCompare(t.presentationTime, CMTimeMake(target->exact().value,
                                                   target->exact().timescale));
  const auto after = CMTimeCompare(
      CMTimeAdd(t.presentationTime, t.duration),
      CMTimeMake(target->exact().value, target->exact().timescale));
  const bool passed =
      port->submitted && !facts.failed && before <= 0 && after > 0;
  std::cout << "decoded=" << port->submitted
            << " hardware=" << facts.decoder.usingHardwareAcceleratedDecoder
            << " samples=" << facts.sourceSamples
            << " pts=" << t.presentationTime.value << '/'
            << t.presentationTime.timescale << " duration=" << t.duration.value
            << '/' << t.duration.timescale << " covers=" << passed
            << " error=" << facts.error << '\n';
  for (unsigned i = 0;
       i < 100 &&
       lane->stop({1}) == NativePreviewFrameCancelProgress::Quiescing;
       ++i)
    std::this_thread::sleep_for(std::chrono::milliseconds(1));
  return passed ? 0 : 1;
}
