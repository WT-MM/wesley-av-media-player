#pragma once

#include "cancellation.hpp"
#include "caption_backend.hpp"
#include <memory>
#include <optional>

#include <filesystem>
#include <mutex>
#include <string>
#include <thread>

namespace wam {

// Captioning is deliberately modelled separately from BackgroundJob.  A
// successful whisper process is not sufficient: CaptionService only reports
// success after the requested, non-empty SRT has been committed to disk.
enum class CaptionStage {
  Idle,
  Validating,
  ExtractingAudio,
  Transcribing,
  AwaitingDownloadConsent,
  PreparingEngine,
  VerifyingOutput,
  Completed,
  Failed,
  Cancelled,
};

const char *captionStageName(CaptionStage stage) noexcept;

struct CaptionTools {
  std::filesystem::path ffmpeg;
  std::filesystem::path whisper;
  std::filesystem::path model;
};

// Resolves the tools through wam::executableSearch / wam::captionModelSearch
// (see jobs.hpp): packaged runtime, development runtime, environment override,
// standard install prefixes, then PATH. A bare executable name survives here
// only when nothing matched; the request re-runs the same search so the
// failure can name every location that was tried.
CaptionTools findCaptionTools(const char *argv0);

struct CaptionOptions {
  // Zero selects a conservative value based on the machine's CPU count.
  unsigned threads = 0;
  // Metal is the default: the bake-off (docs/captions/ASR_BAKEOFF.md) measured
  // it 5.9x faster than the CPU path per 300 s file at 1/55 of the CPU time and
  // equal accuracy. whisper.cpp's Metal backend can still become
  // uninterruptibly stuck on some macOS/driver combinations, so the caption
  // worker watches for caption-time progress, kills a stalled process group and
  // retries once on the Accelerate/BLAS CPU path.
  bool use_gpu = true;
  bool prefer_apple = true;
  // Testable no-caption-progress deadline; applies whenever use_gpu is set.
  unsigned gpu_watchdog_ms = 30000;
  bool translate_to_english = false;
  bool overwrite = true;
  // "auto" uses whisper.cpp language detection. A BCP-47/whisper language
  // code such as "en", "es", or "ja" can be supplied instead.
  std::string language = "auto";
};

struct CaptionRequest {
  std::filesystem::path input;
  std::filesystem::path output_srt;
  CaptionTools tools;
  CaptionOptions options;
  // Worker-only callbacks. Consumers must queue/coalesce delivery to the UI.
  std::function<void(std::vector<CaptionSegment>)> live_segments;
  std::function<void(const std::filesystem::path&)> committed;
};

struct CaptionStatus {
  CaptionStage stage = CaptionStage::Idle;
  float progress = 0.0f;
  bool running = false;
  bool finished = false;
  bool succeeded = false;
  bool cancelled = false;
  std::string message;
  std::string error;
  CaptionEngine engine = CaptionEngine::Whisper;
  unsigned engine_preparations = 0;
  bool needs_download_consent = false;
  std::string download_locale;
  std::vector<CaptionSegment> segments;
  std::filesystem::path output_srt;
};

// These functions are useful in diagnostics and tests. CaptionService executes
// the equivalent argument vectors directly (without a command shell), so user
// paths cannot become shell syntax. quoteArg is still used here to produce an
// accurate, copyable representation on each supported platform.
std::string buildCaptionAudioCommand(const std::filesystem::path &ffmpeg,
                                     const std::filesystem::path &input,
                                     const std::filesystem::path &wav);
std::string buildCaptionWhisperCommand(const std::filesystem::path &whisper,
                                       const std::filesystem::path &model,
                                       const std::filesystem::path &wav,
                                       const std::filesystem::path &output_base,
                                       const CaptionOptions &options = {});

class CaptionService {
public:
  CaptionService() = default;
  ~CaptionService();
  CaptionService(const CaptionService &) = delete;
  CaptionService &operator=(const CaptionService &) = delete;

  // Returns false only when another request is still active. Validation and all
  // media work happen on the worker thread; callers should poll status().
  bool start(CaptionRequest request);
  void cancel() noexcept;
  void respondToDownload(bool consent) noexcept;
  void wait();

  CaptionStatus status() const;
  // UI polling skips a turn if the worker is publishing a snapshot.
  std::optional<CaptionStatus> tryStatus() const;
  bool running() const;
  bool transcribing() const noexcept { return transcribing_.load(); }
  bool finished() const;
  bool succeeded() const;

private:
  void run(CaptionRequest request,
           const detail::CancellationFlag &cancellation) noexcept;
  void update(CaptionStage stage, float progress, std::string message);
  void complete(const std::filesystem::path &output);
  void fail(std::string error);
  void cancelled();

  mutable std::mutex status_mutex_;
  CaptionStatus status_;
  mutable std::mutex worker_mutex_;
  std::thread worker_;
  detail::CancellationFlag cancellation_;
  std::unique_ptr<CaptionBackend> apple_;
  std::atomic<int> download_response_{0};
  std::atomic<bool> transcribing_{false};
  bool download_asked_ = false;
};

} // namespace wam
