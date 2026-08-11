#include "jobs.hpp"

#include <chrono>
#include <cmath>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <iterator>
#include <string>

namespace fs = std::filesystem;

int main(int argc, char** argv) {
  if (argc != 3) {
    std::cerr << "expected ffmpeg and ffprobe paths\n";
    return 2;
  }
  const auto stamp = std::chrono::steady_clock::now().time_since_epoch().count();
  const fs::path directory = fs::temp_directory_path() /
                             ("wam-export-test-" + std::to_string(stamp));
  fs::create_directories(directory);
  const fs::path input = directory / "six seconds.mp4";
  const fs::path output = directory / "two seconds.mp4";
  const fs::path duration_file = directory / "duration.txt";

  const std::string generate =
      wam::quoteArg(argv[1]) +
      " -hide_banner -loglevel error -y -f lavfi -i "
      "testsrc2=size=320x180:rate=30:duration=6 -f lavfi -i "
      "sine=frequency=440:sample_rate=48000:duration=6 -shortest "
      "-c:v mpeg4 -q:v 5 -c:a aac " + wam::quoteArg(input.string());
  if (std::system(generate.c_str()) != 0) {
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
  {
    std::ifstream existing(output, std::ios::binary);
    const std::string contents{std::istreambuf_iterator<char>(existing),
                               std::istreambuf_iterator<char>()};
    if (contents != "existing destination must survive encoding") {
      std::cerr << "export modified destination before commit\n";
      wam::removeExportStagingFile(staging);
      fs::remove_all(directory);
      return 1;
    }
  }
  if (!wam::commitExportStagingFile(staging, output, &transaction_error)) {
    std::cerr << "could not commit export staging: " << transaction_error
              << "\n";
    wam::removeExportStagingFile(staging);
    fs::remove_all(directory);
    return 1;
  }

  const std::string probe =
      wam::quoteArg(argv[2]) +
      " -v error -show_entries format=duration -of default=nw=1:nk=1 " +
      wam::quoteArg(output.string()) + " > " +
      wam::quoteArg(duration_file.string());
  if (std::system(probe.c_str()) != 0) {
    std::cerr << "ffprobe failed\n";
    fs::remove_all(directory);
    return 1;
  }
  std::ifstream duration_input(duration_file);
  double duration = 0.0;
  duration_input >> duration;
  const bool correct = duration_input && std::abs(duration - 2.0) <= 0.12;
  fs::remove_all(directory);
  if (!correct) {
    std::cerr << "expected a 2.0 second export, got " << duration << "\n";
    return 1;
  }
  std::cout << "export duration test passed (" << duration << " seconds)\n";
  return 0;
}
