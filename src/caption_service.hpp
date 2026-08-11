#pragma once

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

// Resolves the tools using the same bundle layout as the rest of WAM. Bare
// executable names are intentional fallbacks and are resolved through PATH
// when a request starts.
CaptionTools findCaptionTools(const char *argv0);

struct CaptionOptions {
  // Zero selects a conservative value based on the machine's CPU count.
  unsigned threads = 0;
  // whisper.cpp's Metal backend can become uninterruptibly stuck on some
  // macOS/driver combinations. The bundled Accelerate/BLAS CPU path is the
  // reliable default; callers may opt into a supported GPU backend.
  bool use_gpu = false;
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
  void wait();

  CaptionStatus status() const;
  bool running() const;
  bool finished() const;
  bool succeeded() const;

private:
  void run(CaptionRequest request, std::stop_token stop_token) noexcept;
  void update(CaptionStage stage, float progress, std::string message);
  void complete(const std::filesystem::path &output);
  void fail(std::string error);
  void cancelled();

  mutable std::mutex status_mutex_;
  CaptionStatus status_;
  mutable std::mutex worker_mutex_;
  std::jthread worker_;
};

} // namespace wam
