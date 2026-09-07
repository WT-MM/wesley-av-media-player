#include "native_open_preflight.hpp"

namespace wam::qt {
namespace {
PlaybackSourceClass qtClass(macos::NativeSourceClass value) {
  switch (value) {
  case macos::NativeSourceClass::Network: return PlaybackSourceClass::Network;
  case macos::NativeSourceClass::BufferedLocal: return PlaybackSourceClass::BufferedLocal;
  case macos::NativeSourceClass::FastLocal: return PlaybackSourceClass::FastLocal;
  }
}
macos::NativeSourceClass nativeClass(PlaybackSourceClass value) {
  switch (value) {
  case PlaybackSourceClass::Network: return macos::NativeSourceClass::Network;
  case PlaybackSourceClass::BufferedLocal: return macos::NativeSourceClass::BufferedLocal;
  case PlaybackSourceClass::FastLocal: return macos::NativeSourceClass::FastLocal;
  }
}
NativeOpenPreflightResult qtResult(macos::NativeOpenPreflightResult value) {
  NativeOpenPreflightResult result;
  result.requestId = value.requestId;
  result.sourceKey = value.sourceKey;
  result.source = QUrl::fromEncoded(QByteArray::fromStdString(value.source));
  result.canonicalSource = QUrl::fromEncoded(QByteArray::fromStdString(value.canonicalSource));
  result.absoluteLocalPath = std::move(value.absoluteLocalPath);
  result.sourceClass = qtClass(value.sourceClass);
  result.route = value.route;
  result.initialPositionSeconds = value.initialPositionSeconds;
  result.paused = value.paused;
  result.preflightFailed = value.preflightFailed;
  result.initialPosition = value.initialPosition;
  return result;
}
}
NativeOpenPreflight::NativeOpenPreflight(Completion completion)
    : NativeOpenPreflight(std::move(completion), {}) {}
NativeOpenPreflight::NativeOpenPreflight(Completion completion, Dependencies dependencies) {
  macos::NativeOpenPreflight::Dependencies native;
  native.beforeEvaluate = std::move(dependencies.beforeEvaluate);
  native.queueCompletion = std::move(dependencies.queueCompletion);
  if (dependencies.classifySource) {
    native.classifySource = [classify = std::move(dependencies.classifySource)](
        const std::string& source, const std::string& path) {
      return nativeClass(classify(QUrl::fromEncoded(QByteArray::fromStdString(source)),
                                  QString::fromStdString(path)));
    };
  }
  native_ = std::make_unique<macos::NativeOpenPreflight>(
      [completion = std::move(completion)](macos::NativeOpenPreflightResult result) {
        if (completion) completion(qtResult(std::move(result)));
      }, std::move(native));
}
NativeOpenPreflight::~NativeOpenPreflight() = default;
std::optional<NativeOpenPreflight::RequestId> NativeOpenPreflight::enqueue(
    NativeOpenPreflightRequest request) noexcept {
  try {
    return native_->enqueue({request.sourceKey, request.source.toEncoded().toStdString(),
        request.initialPositionSeconds, request.paused, request.nativeAdmissionAllowed});
  } catch (...) { return {}; }
}
void NativeOpenPreflight::cancel() noexcept { native_->cancel(); }
void NativeOpenPreflight::stop() noexcept { native_->stop(); }
}
