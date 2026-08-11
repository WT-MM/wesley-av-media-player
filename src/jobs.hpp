#pragma once

#include "cancellation.hpp"

#include <atomic>
#include <filesystem>
#include <functional>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace wam {

struct EditOptions {
  std::filesystem::path input;
  std::filesystem::path output;
  double in_seconds = 0.0;
  double out_seconds = 0.0;
  double speed = 1.0;
  bool preserve_pitch = true;
  bool prefer_hardware_encoder = true;
};

// A shell-free child process description. Arguments are UTF-8 on every
// platform; the executable remains a filesystem path so Windows can launch it
// through its native wide-character API without lossy conversion.
struct ProcessCommand {
  std::filesystem::path executable;
  std::vector<std::string> arguments;
};

std::string quoteArg(const std::string& value);
std::string atempoFilter(double speed);
std::string buildExportCommand(const std::filesystem::path& ffmpeg,
                               const EditOptions& options);
ProcessCommand buildExportProcess(const std::filesystem::path& ffmpeg,
                                  const EditOptions& options);

// Export transactions encode into a reserved same-directory file, then use a
// single filesystem replacement only after a non-empty result is verified.
std::filesystem::path reserveExportStagingFile(
    const std::filesystem::path& destination, std::string* error = nullptr);
bool commitExportStagingFile(const std::filesystem::path& staging,
                             const std::filesystem::path& destination,
                             std::string* error = nullptr);
void removeExportStagingFile(
    const std::filesystem::path& staging) noexcept;

class BackgroundJob {
 public:
  BackgroundJob() = default;
  ~BackgroundJob();
  BackgroundJob(const BackgroundJob&) = delete;
  BackgroundJob& operator=(const BackgroundJob&) = delete;

  bool start(std::string label, std::string command);
  bool start(std::string label, ProcessCommand command);
  bool running() const { return running_.load(); }
  bool succeeded() const { return finished_.load() && exit_code_.load() == 0; }
  bool finished() const { return finished_.load(); }
  int exitCode() const { return exit_code_.load(); }
  std::string label() const;
  void cancel() noexcept;
  void wait();
  void reset();

 private:
  bool startWorker(std::string label,
                   std::function<int(const detail::CancellationFlag&)>
                       operation);

  std::thread worker_;
  detail::CancellationFlag cancellation_;
  mutable std::mutex worker_mutex_;
  std::atomic<bool> running_{false};
  std::atomic<bool> finished_{false};
  std::atomic<int> exit_code_{-1};
  mutable std::mutex label_mutex_;
  std::string label_;
};

std::filesystem::path findBundledTool(const char* executable, const char* argv0);
std::filesystem::path defaultWhisperModel(const char* argv0);

}  // namespace wam
