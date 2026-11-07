#pragma once

#include "platform/macos/native_audio_converter.hpp"

#include <algorithm>
#include <array>
#include <atomic>
#include <cstddef>
#include <cstdint>
#include <initializer_list>
#include <span>
#include <stdexcept>
#include <string>

// One scripted NativeAudioConverterBackend::convert() result. Calls past the
// end of the script repeat the zero entry after it.
struct Script {
  std::size_t consume{0};
  std::size_t produce{0};
  bool finalInputReleased{false};
  bool needsInput{false};
  bool drained{false};
  bool failed{false};
  bool throws{false};
};

// Records what the converter hands its backend and returns scripted results;
// output sample i of call n is 100 * n + i + 1.
class FakeBackend final : public wam::macos::NativeAudioConverterBackend {
public:
  [[nodiscard]] bool
  configure(const wam::macos::NativeAudioBackendConfiguration& configuration,
            std::string*) override {
    ++configureCalls;
    if (throwConfigure) {
      throw std::runtime_error("configure");
    }
    configuredRate = configuration.outputSampleRate;
    configuredChannels = configuration.outputChannels;
    configuredFormatTag = configuration.input.formatTag;
    configuredFramesPerPacket = configuration.input.framesPerPacket;
    configuredLayoutPresent = configuration.input.channelLayoutPresent;
    configuredLayoutTag = configuration.input.channelLayoutTag;
    cookieSize = configuration.codecConfiguration.size();
    std::copy_n(configuration.codecConfiguration.begin(),
                std::min(cookieSize, cookie.size()), cookie.begin());
    return configureSucceeds;
  }

  [[nodiscard]] wam::macos::NativeAudioBackendResult
  convert(wam::macos::NativeAudioBackendInput input,
          std::span<float> interleavedOutput) override {
    ++convertCalls;
    observedPacketCount = input.packets.size();
    observedByteCount = input.bytes.size();
    observedBytesData = input.bytes.data();
    observedEof = input.endOfStream;
    const std::size_t observedPacketsToCopy =
        std::min(input.packets.size(), observedPackets.size());
    std::copy_n(input.packets.begin(), observedPacketsToCopy,
                observedPackets.begin());
    const std::size_t observedBytesToCopy =
        std::min(input.bytes.size(), observedBytes.size());
    std::copy_n(input.bytes.begin(), observedBytesToCopy,
                observedBytes.begin());
    if (observedPacketsToCopy != 0) {
      firstPacket = observedPackets.front();
    }
    const Script current =
        scripts[scriptIndex < scriptCount ? scriptIndex++ : scriptCount];
    if (current.throws) {
      throw std::runtime_error("convert");
    }
    const std::size_t samples = std::min(
        interleavedOutput.size(),
        current.produce * static_cast<std::size_t>(configuredChannels));
    for (std::size_t index = 0; index < samples; ++index) {
      interleavedOutput[index] =
          static_cast<float>(100 * convertCalls + index + 1);
    }
    return {current.consume,    current.produce, current.finalInputReleased,
            current.needsInput, current.drained, current.failed};
  }

  [[nodiscard]] bool reset(std::string*) override {
    ++resetCalls;
    if (lifecycleReleaseCounter != nullptr) {
      releaseCountSeenByReset =
          lifecycleReleaseCounter->load(std::memory_order_relaxed);
    }
    if (throwReset) {
      throw std::runtime_error("reset");
    }
    return resetSucceeds;
  }
  void close() noexcept override {
    ++closeCalls;
    if (lifecycleReleaseCounter != nullptr) {
      releaseCountSeenByClose =
          lifecycleReleaseCounter->load(std::memory_order_relaxed);
    }
  }

  void setScripts(std::initializer_list<Script> values) {
    scriptCount = values.size();
    scriptIndex = 0;
    std::copy(values.begin(), values.end(), scripts.begin());
  }

  std::array<Script, 12> scripts{};
  std::array<std::byte, 32> cookie{};
  std::size_t scriptCount{0};
  std::size_t scriptIndex{0};
  std::size_t cookieSize{0};
  std::size_t observedPacketCount{0};
  std::size_t observedByteCount{0};
  const std::byte* observedBytesData{nullptr};
  std::array<wam::macos::NativeAudioPacketDescription, 16> observedPackets{};
  std::array<std::byte, 32> observedBytes{};
  wam::macos::NativeAudioPacketDescription firstPacket{};
  std::uint32_t configuredRate{0};
  std::uint32_t configuredChannels{0};
  std::uint32_t configuredFormatTag{0};
  std::uint32_t configuredFramesPerPacket{0};
  bool configuredLayoutPresent{false};
  std::uint32_t configuredLayoutTag{0};
  int configureCalls{0};
  int convertCalls{0};
  int resetCalls{0};
  int closeCalls{0};
  int releaseCountSeenByReset{-1};
  int releaseCountSeenByClose{-1};
  std::atomic<int>* lifecycleReleaseCounter{nullptr};
  bool observedEof{false};
  bool configureSucceeds{true};
  bool resetSucceeds{true};
  bool throwConfigure{false};
  bool throwReset{false};
};
