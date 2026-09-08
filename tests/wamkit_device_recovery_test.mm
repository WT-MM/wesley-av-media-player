#define main frozenAudioFixtureMain
#include "native_audio_session_test.mm"
#undef main

int main() {
  for (int iteration = 0; iteration < 30; ++iteration) {
    auto platform = std::make_shared<FakePlatform>();
    auto backend = std::make_shared<BackendState>();
    auto session = NativeAudioSession::create(
        1, dependencies(platform, std::make_unique<FakeBackend>(backend)));
    expect(session->configure(audioTrack(), 1, timeline(1, 0), nullptr) ==
               NativeMediaConsumeResult::Accepted, "recovery fixture configured");
    platform->listener(platform->listenerContext,
        reinterpret_cast<AudioUnit>(&platform->unitToken),
        kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0);
    auto target = timeline(2, 1602);
    target.requestedTarget = {1001, 30000};
    target.presentationFloor = target.requestedTarget;
    expect(session->flush(1, 2, target) ==
               NativeMediaConsumerProgress::Done,
           "seek reconciles unchanged device format before activation");
    expect(session->close() == NativeMediaConsumerProgress::Done,
           "recovery seek closes cleanly");
  }
  auto platform = std::make_shared<FakePlatform>();
  auto backend = std::make_shared<BackendState>();
  auto seams = dependencies(platform, std::make_unique<FakeBackend>(backend));
  static bool changed = false;
  seams.outputCalls.getProperty = [](void* context, AudioUnit unit,
      AudioUnitPropertyID property, AudioUnitScope scope, AudioUnitElement element,
      void* data, UInt32* size) -> OSStatus {
    const auto status = FakePlatform::getProperty(context, unit, property, scope,
                                                  element, data, size);
    if (status == noErr && changed && property == kAudioUnitProperty_StreamFormat &&
        scope == kAudioUnitScope_Output) {
      static_cast<AudioStreamBasicDescription*>(data)->mSampleRate = 44100.0;
    }
    return status;
  };
  auto session = NativeAudioSession::create(1, std::move(seams));
  expect(session->configure(audioTrack(), 1, timeline(1, 0), nullptr) ==
             NativeMediaConsumeResult::Accepted, "changed-rate fixture configured");
  changed = true;
  platform->listener(platform->listenerContext,
      reinterpret_cast<AudioUnit>(&platform->unitToken),
      kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0);
  expect(session->flush(1, 2, timeline(2, 1602)) == NativeMediaConsumerProgress::Failed,
         "a changed device rate remains refused");
  static_cast<void>(session->close());
  std::cout << "unchanged-format seeks: 30; changed-rate refusal: 1; failures: "
            << failures << '\n';
  return failures ? EXIT_FAILURE : EXIT_SUCCESS;
}
