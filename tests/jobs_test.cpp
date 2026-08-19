#include "jobs.hpp"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <string>
#include <string_view>
#include <thread>
#include <utility>
#include <vector>

#ifndef _WIN32
#include <cerrno>
#include <csignal>
#include <unistd.h>
#endif

static_assert(noexcept(std::declval<wam::BackgroundJob&>().cancel()),
              "background cancellation must remain no-throw");

namespace {
int failures = 0;
void expect(bool condition, const char* message) {
  if (!condition) {
    std::cerr << "FAIL: " << message << '\n';
    ++failures;
  }
}
}  // namespace

std::string readFile(const std::filesystem::path& path) {
  std::ifstream input(path, std::ios::binary);
  return std::string(std::istreambuf_iterator<char>(input),
                     std::istreambuf_iterator<char>());
}

void writeFile(const std::filesystem::path& path, const std::string& contents) {
  std::ofstream output(path, std::ios::binary);
  output << contents;
}

#ifndef _WIN32
void exitSuccessfullyOnTerm(int) { _exit(0); }

bool waitForFile(const std::filesystem::path& path,
                 std::chrono::steady_clock::duration timeout) {
  const auto deadline = std::chrono::steady_clock::now() + timeout;
  while (std::chrono::steady_clock::now() < deadline) {
    std::error_code error;
    if (std::filesystem::is_regular_file(path, error) &&
        std::filesystem::file_size(path, error) > 0)
      return true;
    std::this_thread::sleep_for(std::chrono::milliseconds(10));
  }
  return false;
}

bool processExists(pid_t process) {
  if (kill(process, 0) == 0) return true;
  return errno == EPERM;
}

bool waitForProcessExit(pid_t process,
                        std::chrono::steady_clock::duration timeout) {
  const auto deadline = std::chrono::steady_clock::now() + timeout;
  while (std::chrono::steady_clock::now() < deadline) {
    if (!processExists(process)) return true;
    std::this_thread::sleep_for(std::chrono::milliseconds(10));
  }
  return !processExists(process);
}
#endif

int main(int argc, char** argv) {
  if (argc == 4 && std::string(argv[1]) == "--structured-child") {
    writeFile(argv[2], argv[3]);
    return 0;
  }
  if (argc == 2 && std::string(argv[1]) == "--structured-slow-child") {
    std::this_thread::sleep_for(std::chrono::seconds(30));
    return 0;
  }
  if (argc == 2 && std::string(argv[1]) == "--structured-fast-child")
    return 0;
#ifndef _WIN32
  if (argc == 3 &&
      std::string(argv[1]) == "--structured-descendant-leader") {
    signal(SIGTERM, exitSuccessfullyOnTerm);
    const pid_t descendant = fork();
    if (descendant < 0) return 3;
    if (descendant == 0) {
      signal(SIGTERM, SIG_IGN);
      writeFile(argv[2], std::to_string(getpid()));
      for (;;) pause();
    }
    for (;;) pause();
  }
#endif

  expect(wam::atempoFilter(1.0) == "atempo=1", "1x atempo");
  expect(wam::atempoFilter(4.0) == "atempo=2,atempo=2", "4x atempo chain");
  expect(wam::atempoFilter(0.25) == "atempo=0.5,atempo=0.5", "0.25x atempo chain");
  wam::EditOptions options;
  options.input = "/tmp/a file.mov";
  options.output = "/tmp/out.mp4";
  options.in_seconds = 2.0;
  options.out_seconds = 8.0;
  options.speed = 2.0;
  const auto process = wam::buildExportProcess("ffmpeg", options);
  const auto seek = std::find(process.arguments.begin(), process.arguments.end(),
                              "-ss");
  const auto trim = std::find(process.arguments.begin(), process.arguments.end(),
                              "-t");
  const auto input = std::find(process.arguments.begin(), process.arguments.end(),
                               "-i");
  expect(seek != process.arguments.end(), "input seek is present");
  expect(trim != process.arguments.end(), "trim duration is present");
  expect(input != process.arguments.end() && trim < input,
         "trim duration is an input option before -i");
  expect(std::find(process.arguments.begin(), process.arguments.end(),
                   "atempo=2") != process.arguments.end(),
         "audio is retimed");
  expect(std::find(process.arguments.begin(), process.arguments.end(),
                   "setpts=(PTS-STARTPTS)/2") != process.arguments.end(),
         "video is retimed");
#ifdef __APPLE__
  expect(std::find(process.arguments.begin(), process.arguments.end(),
                   "h264_videotoolbox") != process.arguments.end(),
         "macOS defaults to VideoToolbox export");
#else
  expect(std::find(process.arguments.begin(), process.arguments.end(),
                   "libx264") != process.arguments.end(),
         "non-Apple platforms default to libx264 export");
#endif

  {
    wam::EditOptions unicode_options;
    unicode_options.input = std::filesystem::path(u8"/tmp/媒体 source.mov");
    unicode_options.output = std::filesystem::path(u8"/tmp/完成 video.mp4");
    const auto unicode_process =
        wam::buildExportProcess(std::filesystem::path(u8"/tmp/工具/ffmpeg"),
                                unicode_options);
    const auto input_utf8 = unicode_options.input.u8string();
    const std::string expected_input(
        reinterpret_cast<const char*>(input_utf8.data()), input_utf8.size());
    const auto output_utf8 = unicode_options.output.u8string();
    const std::string expected_output(
        reinterpret_cast<const char*>(output_utf8.data()), output_utf8.size());
    expect(std::find(unicode_process.arguments.begin(),
                     unicode_process.arguments.end(), expected_input) !=
               unicode_process.arguments.end(),
           "export command preserves a Unicode input path as UTF-8");
    expect(std::find(unicode_process.arguments.begin(),
                     unicode_process.arguments.end(), expected_output) !=
               unicode_process.arguments.end(),
           "export command preserves a Unicode output path as UTF-8");
  }

  {
    const auto stamp =
        std::chrono::steady_clock::now().time_since_epoch().count();
    const auto directory = std::filesystem::temp_directory_path() /
                           ("wam-export-transaction-test-" +
                            std::to_string(stamp));
    std::filesystem::create_directories(directory);
    const auto destination = directory / "existing.mp4";
    writeFile(destination, "original destination");

    std::string staging_error;
    auto empty_staging =
        wam::reserveExportStagingFile(destination, &staging_error);
    expect(!empty_staging.empty() && empty_staging.parent_path() == directory,
           "staging file is reserved beside the destination");
    expect(empty_staging.extension() == ".mp4",
           "staging file keeps an MP4 extension for muxer detection");
    expect(readFile(destination) == "original destination",
           "reserving staging leaves an existing destination untouched");
    std::string commit_error;
    expect(!wam::commitExportStagingFile(empty_staging, destination,
                                         &commit_error),
           "an empty staging file cannot be committed");
    expect(readFile(destination) == "original destination",
           "failed validation leaves the destination untouched");
    wam::removeExportStagingFile(empty_staging);

    auto completed_staging =
        wam::reserveExportStagingFile(destination, &staging_error);
    writeFile(completed_staging, "complete encoded media");
    expect(wam::commitExportStagingFile(completed_staging, destination,
                                        &commit_error),
           "a non-empty staged export commits successfully");
    expect(readFile(destination) == "complete encoded media",
           "commit atomically replaces the destination contents");
    expect(!std::filesystem::exists(completed_staging),
           "successful commit consumes the staging file");
    std::filesystem::remove_all(directory);
  }

  {
    const auto stamp =
        std::chrono::steady_clock::now().time_since_epoch().count();
    const auto output = std::filesystem::temp_directory_path() /
                        ("wam-structured-process-" + std::to_string(stamp));
    const std::string literal = "%WAM_DIRECT_PROCESS_SENTINEL%";
    wam::ProcessCommand child;
    child.executable = std::filesystem::absolute(argv[0]);
    child.arguments = {"--structured-child", output.string(), literal};
    wam::BackgroundJob job;
    expect(job.start("structured argument test", std::move(child)),
           "structured process starts");
    job.wait();
    expect(job.succeeded(), "structured process exits successfully");
    expect(readFile(output) == literal,
           "structured process preserves percent-delimited arguments literally");
    std::filesystem::remove(output);
  }

  {
    const auto stamp =
        std::chrono::steady_clock::now().time_since_epoch().count();
    const auto directory = std::filesystem::temp_directory_path() /
                           ("wam-structured-cancel-" +
                            std::to_string(stamp));
    std::filesystem::create_directories(directory);
    const auto destination = directory / "existing.mp4";
    writeFile(destination, "keep me");
    std::string staging_error;
    const auto staging =
        wam::reserveExportStagingFile(destination, &staging_error);
    wam::ProcessCommand child;
    child.executable = std::filesystem::absolute(argv[0]);
    child.arguments = {"--structured-slow-child"};
    wam::BackgroundJob job;
    const auto started_at = std::chrono::steady_clock::now();
    expect(!staging.empty() && job.start("structured cancellation", child),
           "cancellable structured process starts with staging reserved");
    std::this_thread::sleep_for(std::chrono::milliseconds(60));
    job.cancel();
    job.wait();
    wam::removeExportStagingFile(staging);
    expect(!job.succeeded(), "cancelled structured process does not succeed");
    expect(std::chrono::steady_clock::now() - started_at <
               std::chrono::seconds(3),
           "structured process cancellation is bounded");
    expect(!std::filesystem::exists(staging),
           "cancel cleanup removes the staging file");
    expect(readFile(destination) == "keep me",
           "cancel cleanup leaves the destination untouched");

    const auto retry_output = directory / "retry.txt";
    wam::ProcessCommand retry;
    retry.executable = std::filesystem::absolute(argv[0]);
    retry.arguments = {"--structured-child", retry_output.string(),
                       "reused after cancellation"};
    expect(job.start("reuse after cancellation", std::move(retry)),
           "a cancelled job can be reused");
    job.wait();
    expect(job.succeeded() &&
               readFile(retry_output) == "reused after cancellation",
           "job reuse clears the previous cancellation request");
    std::filesystem::remove_all(directory);
  }

  {
    wam::BackgroundJob job;
#ifdef _WIN32
    const std::string long_command = "ping -n 30 127.0.0.1 >NUL";
#else
    // Exercise the force-kill deadline as well as graceful SIGTERM: both the
    // shell and sleep inherit an ignored TERM disposition.
    const std::string long_command = "trap '' TERM; sleep 30";
#endif
    const auto started_at = std::chrono::steady_clock::now();
    expect(job.start("cancellation test", long_command), "background job starts");
    expect(!job.start("overlapping test", long_command),
           "background job refuses overlapping work");
    std::this_thread::sleep_for(std::chrono::milliseconds(60));
    job.cancel();
    while (!job.finished() &&
           std::chrono::steady_clock::now() - started_at < std::chrono::seconds(3)) {
      std::this_thread::sleep_for(std::chrono::milliseconds(10));
    }
    expect(job.finished(), "cancelled job finishes promptly");
    expect(!job.succeeded(), "cancelled job is not successful");
    expect(job.exitCode() == 130,
           "cancelled job reports the canonical cancellation code");
    expect(std::chrono::steady_clock::now() - started_at < std::chrono::seconds(3),
           "cancellation is bounded");
  }

  {
    // Race cancel() against start() after running() is published. The first
    // request must never be erased by reusable-worker initialization.
    bool lost_cancellation = false;
    for (int attempt = 0; attempt < 16 && !lost_cancellation; ++attempt) {
      wam::ProcessCommand child;
      child.executable = std::filesystem::absolute(argv[0]);
      child.arguments = {"--structured-slow-child"};
      wam::BackgroundJob job;
      std::atomic<bool> start_returned{false};
      bool started = false;
      std::thread starter([&] {
        started = job.start("publication cancellation", child);
        start_returned.store(true, std::memory_order_release);
      });
      while (!job.running() &&
             !start_returned.load(std::memory_order_acquire))
        std::this_thread::yield();
      if (job.running())
        job.cancel();
      starter.join();

      const auto deadline =
          std::chrono::steady_clock::now() + std::chrono::seconds(2);
      while (!job.finished() && std::chrono::steady_clock::now() < deadline)
        std::this_thread::sleep_for(std::chrono::milliseconds(2));
      lost_cancellation = !started || !job.finished() || job.succeeded() ||
                          job.exitCode() != 130;
      if (!job.finished())
        job.cancel();
      job.wait();
    }
    expect(!lost_cancellation,
           "cancellation published after running is never reset or lost");
  }

#ifndef _WIN32
  {
    // Exercise the very-fast child/setpgid race repeatedly. A child that is
    // already waitable before the parent's setpgid still reports its real
    // successful exit rather than an isolation error.
    for (int attempt = 0; attempt < 64; ++attempt) {
      wam::ProcessCommand child;
      child.executable = std::filesystem::absolute(argv[0]);
      child.arguments = {"--structured-fast-child"};
      wam::BackgroundJob job;
      expect(job.start("fast process-group race", child),
             "fast structured child starts");
      job.wait();
      expect(job.succeeded(), "fast structured child preserves exit zero");
    }
  }

  {
    // The process-group leader exits on SIGTERM while its child deliberately
    // ignores TERM. wait() must retain the PGID through the grace deadline and
    // kill that descendant before reporting completion.
    const auto stamp =
        std::chrono::steady_clock::now().time_since_epoch().count();
    const auto directory = std::filesystem::temp_directory_path() /
                           ("wam-descendant-cancel-" + std::to_string(stamp));
    std::filesystem::create_directories(directory);
    const auto pid_file = directory / "descendant.pid";
    wam::ProcessCommand child;
    child.executable = std::filesystem::absolute(argv[0]);
    child.arguments = {"--structured-descendant-leader", pid_file.string()};
    wam::BackgroundJob job;
    expect(job.start("descendant cancellation", child),
           "descendant cancellation process starts");
    const bool descendant_started =
        waitForFile(pid_file, std::chrono::seconds(2));
    expect(descendant_started, "TERM-ignoring descendant reports its PID");
    const pid_t descendant =
        descendant_started ? static_cast<pid_t>(std::stol(readFile(pid_file)))
                           : -1;
    expect(descendant <= 0 || getpgid(descendant) != getpgrp(),
           "test descendant is isolated from the test runner process group");
    const auto started_at = std::chrono::steady_clock::now();
    job.cancel();
    job.wait();
    const bool descendant_gone =
        descendant > 0 && waitForProcessExit(descendant, std::chrono::seconds(1));
    if (descendant > 0 && !descendant_gone)
      kill(descendant, SIGKILL);
    expect(descendant_gone,
           "cancellation reaps a TERM-ignoring process-group descendant");
    expect(!job.succeeded(), "descendant cancellation is not successful");
    expect(job.exitCode() == 130,
           "zero-exiting TERM handler still reports cancellation");
    expect(std::chrono::steady_clock::now() - started_at <
               std::chrono::seconds(3),
           "descendant cleanup remains bounded");
    std::filesystem::remove_all(directory);
  }
#endif

  {
    const auto started_at = std::chrono::steady_clock::now();
    {
      wam::BackgroundJob job;
#ifdef _WIN32
      expect(job.start("destructor test", "ping -n 30 127.0.0.1 >NUL"),
#else
      expect(job.start("destructor test", "sleep 30"),
#endif
             "destructor test job starts");
      std::this_thread::sleep_for(std::chrono::milliseconds(60));
    }
    expect(std::chrono::steady_clock::now() - started_at < std::chrono::seconds(3),
           "destructor cancels and joins promptly");
  }
  {
    // Tool resolution order. resolveTool is pure over its probe, so the whole
    // precedence rule is testable without installing anything.
#ifdef _WIN32
    const auto search = wam::executableSearch("FFmpeg", "ffmpeg.exe", nullptr);
#else
    const auto search = wam::executableSearch("FFmpeg", "ffmpeg", nullptr);
#endif
    expect(search.candidates.size() >= 2,
           "an executable search probes more than one location");

    const auto index = [&search](std::string_view fragment) {
      for (std::size_t i = 0; i < search.candidates.size(); ++i) {
        if (search.candidates[i].string().find(fragment) != std::string::npos)
          return static_cast<long>(i);
      }
      return -1L;
    };

#ifndef _WIN32
    const long homebrew = index("/opt/homebrew/bin/");
    const long local = index("/usr/local/bin/");
    const long macports = index("/opt/local/bin/");
    expect(homebrew >= 0 && local > homebrew && macports > local,
           "standard install prefixes are probed in a stable order");
    // Everything WAM ships or a developer stages must outrank the host.
    expect(homebrew > 0,
           "a packaged/development runtime is probed before any host install");
#endif

    // First acceptance wins, and nothing after it is probed.
    std::vector<std::filesystem::path> probed;
    const auto accept_second = [&probed, &search](
                                   const std::filesystem::path& candidate) {
      probed.push_back(candidate);
      return search.candidates.size() > 1 && candidate == search.candidates[1];
    };
    const auto resolved = wam::resolveTool(search, accept_second);
    expect(search.candidates.size() < 2 || resolved == search.candidates[1],
           "resolution returns the first accepted candidate");
    expect(probed.size() == 2, "resolution stops at the first match");

    expect(wam::resolveTool(search,
                            [](const std::filesystem::path&) { return false; })
               .empty(),
           "a search that matches nothing resolves to an empty path");

    const auto failure = wam::toolSearchFailure(search);
    expect(failure.find("FFmpeg") != std::string::npos,
           "a failure names the tool");
    expect(failure.find(search.file) != std::string::npos,
           "a failure names the file that was looked for");
    expect(failure.find(search.candidates.front().string()) !=
               std::string::npos,
           "a failure lists where WAM looked");

    const auto model = wam::captionModelSearch(nullptr);
    expect(!model.candidates.empty(),
           "the caption model has at least one known location");
    expect(index("ggml-base.en.bin") < 0,
           "the model is not searched for on the executable path");
    expect(model.candidates.front().string().find("ggml-base.en.bin") !=
               std::string::npos,
           "the model search looks for the pinned model file");
  }

  std::cout << "jobs tests passed\n";
  return failures == 0 ? 0 : 1;
}
