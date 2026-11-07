#pragma once
#include "caption_backend.hpp"
#include "wamkit/include/WAMKit/WAMCaption.h"
#include <condition_variable>
#include <fstream>
#include <iomanip>
#include <mutex>
#include <optional>
#include <sstream>

namespace wam {
// One WAMCaption operation at a time. Each begins a new generation; events
// from any other generation are dropped, and await() ends the operation, so
// its events and result never outlive it.
class AppleCaptionBackend final : public CaptionBackend {
public:
  AppleCaptionBackend() : session_(wam_caption_create_v1(event, this)) {}
  ~AppleCaptionBackend() override { finish(); wam_caption_release_v1(session_); }
  CaptionCapabilities capabilities(const std::string& locale) override {
    const auto generation = begin({});
    wam_caption_query_v1(session_, generation, locale.c_str());
    auto done = await(generation);
    // A failed query reports Apple unavailable, never an earlier answer.
    if (!done.result.succeeded || !done.capabilities) return {};
    return *done.capabilities;
  }
  std::future<CaptionBackendResult> prepare(bool consent,
                                            CaptionBackendEvents events) override {
    const auto generation = begin(std::move(events));
    wam_caption_prepare_v1(session_, generation, consent);
    return std::async(std::launch::async,
                      [this, generation] { return await(generation).result; });
  }
  std::future<CaptionBackendResult> start(const std::filesystem::path& wav,
      const std::filesystem::path& staging, CaptionBackendEvents events) override {
    const auto generation = begin(std::move(events));
    wam_caption_start_v1(session_, generation, wav.string().c_str());
    return std::async(std::launch::async, [this, generation, staging] {
      auto done = await(generation);
      if (!done.result.succeeded) return done.result;
      std::ofstream output(staging, std::ios::trunc);
      unsigned index = 0;
      for (const auto& s : done.segments) if (s.final) {
        output << ++index << '\n' << stamp(s.start) << " --> " << stamp(s.end)
               << '\n' << s.text << "\n\n";
      }
      if (!output) return CaptionBackendResult{false,"Could not write Apple Speech staging file"};
      return done.result;
    });
  }
  void cancel() noexcept override { wam_caption_cancel_v1(session_); }
  void finish() override {
    const auto generation = begin({});
    wam_caption_finish_v1(session_, generation);
    await(generation);
  }
private:
  struct Operation {
    uint64_t generation = 0;
    CaptionBackendEvents events;
    std::vector<CaptionSegment> segments;
    std::optional<CaptionCapabilities> capabilities;
    // Set by the operation's terminal event.
    std::optional<CaptionBackendResult> result;
  };
  struct Completed {
    CaptionBackendResult result;
    std::optional<CaptionCapabilities> capabilities;
    std::vector<CaptionSegment> segments;
  };
  static std::string stamp(double seconds) {
    const auto n = static_cast<std::int64_t>(std::max(0.0, std::round(seconds*1000)));
    std::ostringstream out; out << std::setfill('0') << std::setw(2) << n/3600000
      << ':' << std::setw(2) << n/60000%60 << ':' << std::setw(2) << n/1000%60
      << ',' << std::setw(3) << n%1000; return out.str();
  }
  uint64_t begin(CaptionBackendEvents events) {
    std::lock_guard lock(mutex_);
    operation_ = Operation{++generation_, std::move(events), {}, {}, {}};
    return generation_;
  }
  // Ends the operation and hands back what it produced. An operation
  // superseded by a later begin() reports failure.
  Completed await(uint64_t generation) {
    std::unique_lock lock(mutex_);
    cv_.wait(lock, [&] {
      return !operation_ || operation_->generation != generation ||
             operation_->result;
    });
    if (!operation_ || operation_->generation != generation) return {};
    Completed done{std::move(*operation_->result),
                   std::move(operation_->capabilities),
                   std::move(operation_->segments)};
    operation_.reset();
    return done;
  }
  static void event(void* context, uint64_t generation, int32_t kind,
      double start, double end, double progress, int32_t flags, const char* text) noexcept {
    auto& self = *static_cast<AppleCaptionBackend*>(context);
    try {
      std::lock_guard lock(self.mutex_);
      if (!self.operation_ || generation != self.operation_->generation) return;
      Operation& operation = *self.operation_;
      if (operation.result) return;
      if (kind == WAM_CAPTION_SEGMENT) {
        CaptionSegment segment{start,end,text ? text : "",flags == 1};
        reviseCaptionSegments(operation.segments,segment);
        if (operation.events.segment) operation.events.segment(std::move(segment));
      } else if (kind == WAM_CAPTION_PROGRESS) {
        if (operation.events.progress) operation.events.progress(float(progress),text ? text : "");
      } else {
        if (kind == WAM_CAPTION_CAPABILITIES)
          operation.capabilities = CaptionCapabilities{bool(flags&1),bool(flags&2),bool(flags&4),-1,text ? text : ""};
        operation.result = CaptionBackendResult{kind != WAM_CAPTION_ERROR && kind != WAM_CAPTION_CANCELLED, text ? text : ""};
        self.cv_.notify_all();
      }
    } catch (...) {
      // No exception may unwind through Swift. Allocation failure is terminal.
      std::lock_guard lock(self.mutex_);
      if (self.operation_ && generation == self.operation_->generation)
        self.operation_->result = CaptionBackendResult{};
      self.cv_.notify_all();
    }
  }
  wam_caption_session_v1 session_;
  std::mutex mutex_;
  std::condition_variable cv_;
  uint64_t generation_ = 0;
  std::optional<Operation> operation_;
};
}
