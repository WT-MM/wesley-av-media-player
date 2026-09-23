#pragma once
#include "cancellation.hpp"
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <filesystem>
#include <functional>
#include <future>
#include <string>
#include <vector>

namespace wam {
enum class CaptionEngine { Whisper, Apple };
struct CaptionCapabilities {
  bool available = false;
  bool asset_ready = false;
  bool needs_download = false;
  // Apple does not publish a reliable download size.
  std::int64_t download_bytes = -1;
  std::string locale;
};
inline CaptionEngine selectCaptionEngine(CaptionCapabilities apple,
                                         bool translate = false) noexcept {
  return apple.available && apple.asset_ready && !translate
             ? CaptionEngine::Apple : CaptionEngine::Whisper;
}
struct CaptionSegment {
  double start = 0, end = 0;
  std::string text;
  bool final = false;
};
// A revision replaces overlapping volatile ranges, never stable final text.
inline void reviseCaptionSegments(std::vector<CaptionSegment>& store,
                                  CaptionSegment segment) {
  if (!std::isfinite(segment.start) || !std::isfinite(segment.end) ||
      segment.start < 0 || segment.end < segment.start) return;
  std::erase_if(store, [&](const auto& old) {
    return !old.final && old.start <= segment.end && old.end >= segment.start;
  });
  if (!segment.text.empty()) store.push_back(std::move(segment));
}
struct CaptionBackendEvents {
  std::function<void(float, const std::string&)> progress;
  std::function<void(CaptionSegment)> segment;
};
struct CaptionBackendResult { bool succeeded = false; std::string error; };
// Query is worker-only (OS inventory may do IPC). Prepare/start return futures;
// events run off-main, borrowed only for the call. One operation per backend.
// cancel never waits; finish joins off-main before event owners are destroyed.
class CaptionBackend {
public:
  virtual ~CaptionBackend() = default;
  virtual CaptionCapabilities capabilities(const std::string& locale) = 0;
  virtual std::future<CaptionBackendResult> prepare(bool consent) = 0;
  virtual std::future<CaptionBackendResult> start(
      const std::filesystem::path& pcm16kMonoWav,
      const std::filesystem::path& stagingSrt, CaptionBackendEvents events) = 0;
  virtual void cancel() noexcept = 0;
  virtual void finish() = 0;
};
} // namespace wam
