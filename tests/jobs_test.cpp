#include "jobs.hpp"

#include <algorithm>
#include <chrono>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <string>
#include <thread>

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

int main(int argc, char** argv) {
  if (argc == 4 && std::string(argv[1]) == "--structured-child") {
    writeFile(argv[2], argv[3]);
    return 0;
  }
  if (argc == 2 && std::string(argv[1]) == "--structured-slow-child") {
    std::this_thread::sleep_for(std::chrono::seconds(30));
    return 0;
  }

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
    expect(std::chrono::steady_clock::now() - started_at < std::chrono::seconds(3),
           "cancellation is bounded");
  }

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
  std::cout << "jobs tests passed\n";
  return failures == 0 ? 0 : 1;
}
