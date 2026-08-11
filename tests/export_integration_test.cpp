#include "jobs.hpp"

#include <chrono>
#include <cmath>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <iterator>
#include <string>
#include <utility>

namespace fs = std::filesystem;

namespace {

std::string utf8Path(const fs::path& path) {
  const auto value = path.u8string();
  return {reinterpret_cast<const char*>(value.data()), value.size()};
}

bool runProcess(const char* label, wam::ProcessCommand command) {
  wam::BackgroundJob job;
  if (!job.start(label, std::move(command))) {
    std::cerr << "could not start " << label << "\n";
    return false;
  }
  job.wait();
  if (!job.succeeded()) {
    std::cerr << label << " failed with exit code " << job.exitCode() << "\n";
    return false;
  }
  return true;
}

}  // namespace

int main(int argc, char** argv) {
  if (argc != 3) {
    std::cerr << "expected ffmpeg and ffprobe paths\n";
    return 2;
  }
  const auto stamp = std::chrono::steady_clock::now().time_since_epoch().count();
  const fs::path directory = fs::temp_directory_path() /
                             ("wam-export-test-" + std::to_string(stamp));
  fs::create_directories(directory);
  // These names contain metacharacters from both POSIX shells and cmd.exe.
  // The integration test therefore fails if any media path is accidentally
  // routed through a shell instead of WAM's structured process launcher.
  const fs::path input = directory / "six seconds & $WAM %WAM%.mp4";
  const fs::path output = directory / "two seconds & $WAM %WAM%.mp4";
  const fs::path duration_file = directory / "duration.txt";

  wam::ProcessCommand generate;
  generate.executable = argv[1];
  generate.arguments = {
      "-hide_banner", "-loglevel", "error", "-nostdin", "-y",
      "-f", "lavfi", "-i", "testsrc2=size=320x180:rate=30:duration=6",
      "-f", "lavfi", "-i",
      "sine=frequency=440:sample_rate=48000:duration=6", "-shortest",
      "-c:v", "mpeg4", "-q:v", "5", "-c:a", "aac", utf8Path(input)};
  if (!runProcess("export fixture generation", std::move(generate))) {
    std::cerr << "could not create export fixture\n";
    fs::remove_all(directory);
    return 1;
  }

  wam::EditOptions options;
  options.input = input;
  options.in_seconds = 1.0;
  options.out_seconds = 5.0;
  options.speed = 2.0;
  options.preserve_pitch = true;
  options.prefer_hardware_encoder = false;
  {
    std::ofstream existing(output, std::ios::binary);
    existing << "existing destination must survive encoding";
  }
  std::string transaction_error;
  const auto staging =
      wam::reserveExportStagingFile(output, &transaction_error);
  if (staging.empty()) {
    std::cerr << "could not reserve export staging: " << transaction_error
              << "\n";
    fs::remove_all(directory);
    return 1;
  }
  options.output = staging;
  wam::BackgroundJob export_job;
  if (!export_job.start("integration export",
                        wam::buildExportProcess(argv[1], options))) {
    std::cerr << "could not start structured export process\n";
    wam::removeExportStagingFile(staging);
    fs::remove_all(directory);
    return 1;
  }
  export_job.wait();
  if (!export_job.succeeded()) {
    std::cerr << "structured export process failed\n";
    wam::removeExportStagingFile(staging);
    fs::remove_all(directory);
    return 1;
  }
  bool destination_preserved = false;
  {
    std::ifstream existing(output, std::ios::binary);
    const std::string contents{std::istreambuf_iterator<char>(existing),
                               std::istreambuf_iterator<char>()};
    destination_preserved =
        contents == "existing destination must survive encoding";
  }
  if (!destination_preserved) {
    std::cerr << "export modified destination before commit\n";
    wam::removeExportStagingFile(staging);
    fs::remove_all(directory);
    return 1;
  }
  if (!wam::commitExportStagingFile(staging, output, &transaction_error)) {
    std::cerr << "could not commit export staging: " << transaction_error
              << "\n";
    wam::removeExportStagingFile(staging);
    fs::remove_all(directory);
    return 1;
  }

  wam::ProcessCommand probe;
  probe.executable = argv[2];
  probe.arguments = {"-v", "error", "-show_entries", "format=duration",
                     "-of", "default=nw=1:nk=1", "-o",
                     utf8Path(duration_file), utf8Path(output)};
  if (!runProcess("ffprobe", std::move(probe))) {
    std::cerr << "ffprobe failed\n";
    fs::remove_all(directory);
    return 1;
  }
  double duration = 0.0;
  bool correct = false;
  {
    std::ifstream duration_input(duration_file);
    duration_input >> duration;
    correct = duration_input && std::abs(duration - 2.0) <= 0.12;
  }
  fs::remove_all(directory);
  if (!correct) {
    std::cerr << "expected a 2.0 second export, got " << duration << "\n";
    return 1;
  }
  std::cout << "export duration test passed (" << duration << " seconds)\n";
  return 0;
}
