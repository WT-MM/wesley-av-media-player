#pragma once
#include "caption_backend.hpp"
#include "wamkit/include/WAMKit/WAMCaption.h"
#include <condition_variable>
#include <fstream>
#include <iomanip>
#include <mutex>
#include <sstream>

namespace wam {
class AppleCaptionBackend final : public CaptionBackend {
public:
  AppleCaptionBackend() : session_(wam_caption_create_v1(event, this)) {}
  ~AppleCaptionBackend() override { finish(); wam_caption_release_v1(session_); }
  CaptionCapabilities capabilities(const std::string& locale) override {
    begin();
    wam_caption_query_v1(session_, generation_, locale.c_str());
    await();
    std::lock_guard lock(mutex_);
    return capabilities_;
  }
  std::future<CaptionBackendResult> prepare(bool consent) override {
    begin();
    wam_caption_prepare_v1(session_, generation_, consent);
    return std::async(std::launch::async, [this] { return await(); });
  }
  void setEvents(CaptionBackendEvents events) {
    std::lock_guard lock(mutex_); events_ = std::move(events);
  }
  std::future<CaptionBackendResult> start(const std::filesystem::path& wav,
      const std::filesystem::path& staging, CaptionBackendEvents events) override {
    begin();
    { std::lock_guard lock(mutex_); events_ = std::move(events); segments_.clear(); }
    wam_caption_start_v1(session_, generation_, wav.string().c_str());
    return std::async(std::launch::async, [this, staging] {
      auto result = await();
      if (!result.succeeded) return result;
      std::lock_guard lock(mutex_);
      std::ofstream output(staging, std::ios::trunc);
      unsigned index = 0;
      for (const auto& s : segments_) if (s.final) {
        output << ++index << '\n' << stamp(s.start) << " --> " << stamp(s.end)
               << '\n' << s.text << "\n\n";
      }
      if (!output) return CaptionBackendResult{false,"Could not write Apple Speech staging file"};
      return result;
    });
  }
  void cancel() noexcept override { wam_caption_cancel_v1(session_); }
  void finish() override {
    begin(); wam_caption_finish_v1(session_, generation_); await();
  }
private:
  static std::string stamp(double seconds) {
    const auto n = static_cast<std::int64_t>(std::max(0.0, std::round(seconds*1000)));
    std::ostringstream out; out << std::setfill('0') << std::setw(2) << n/3600000
      << ':' << std::setw(2) << n/60000%60 << ':' << std::setw(2) << n/1000%60
      << ',' << std::setw(3) << n%1000; return out.str();
  }
  void begin() {
    std::lock_guard lock(mutex_); ++generation_; done_ = false; result_ = {};
  }
  CaptionBackendResult await() {
    std::unique_lock lock(mutex_); cv_.wait(lock,[this] {return done_;}); return result_;
  }
  static void event(void* context, uint64_t generation, int32_t kind,
      double start, double end, double progress, int32_t flags, const char* text) noexcept {
    auto& self = *static_cast<AppleCaptionBackend*>(context);
    try {
      std::lock_guard lock(self.mutex_);
      if (generation != self.generation_) return;
      if (kind == WAM_CAPTION_SEGMENT) {
        CaptionSegment segment{start,end,text ? text : "",flags == 1};
        reviseCaptionSegments(self.segments_,segment);
        if (self.events_.segment) self.events_.segment(std::move(segment));
      } else if (kind == WAM_CAPTION_PROGRESS) {
        if (self.events_.progress) self.events_.progress(float(progress),text ? text : "");
      } else {
        if (kind == WAM_CAPTION_CAPABILITIES)
          self.capabilities_ = {bool(flags&1),bool(flags&2),bool(flags&4),-1,text ? text : ""};
        self.result_ = {kind != WAM_CAPTION_ERROR && kind != WAM_CAPTION_CANCELLED, text ? text : ""};
        self.done_ = true; self.cv_.notify_all();
      }
    } catch (...) {
      // No exception may unwind through Swift. Allocation failure is terminal.
      std::lock_guard lock(self.mutex_); self.done_ = true; self.result_.succeeded = false; self.cv_.notify_all();
    }
  }
  wam_caption_session_v1 session_;
  std::mutex mutex_;
  std::condition_variable cv_;
  uint64_t generation_ = 0;
  bool done_ = false;
  CaptionCapabilities capabilities_;
  CaptionBackendResult result_;
  CaptionBackendEvents events_;
  std::vector<CaptionSegment> segments_;
};
}
