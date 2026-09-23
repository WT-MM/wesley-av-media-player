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
  const bool hardware = argc == 4 && std::string(argv[3]) == "--hardware";
  const std::string preset_name = argc == 4 && std::string(argv[3]).starts_with("--preset=")
      ? std::string(argv[3]).substr(9) : "";
  const bool all_presets = argc == 4 &&
      (std::string(argv[3]) == "--all-presets" || !preset_name.empty());
  if (argc != 3 && !hardware && !all_presets) {
    std::cerr << "expected ffmpeg and ffprobe paths [--hardware|--all-presets|--preset=NAME]\n";
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
  options.prefer_hardware_encoder = hardware;
  if (all_presets) {
    // Attempt every preset even when a platform encoder is unavailable.
    struct Preset { wam::ExportFormat format; bool hardware; const char* name;
                    const char* video; const char* audio; };
    const Preset presets[] = {
        {wam::ExportFormat::Mp4Hevc, true, "hevc", "hevc", "aac"},
        {wam::ExportFormat::WebmVp9, false, "vp9", "vp9", "opus"},
        {wam::ExportFormat::MkvCopy, false, "mkv-reencode", "h264", "aac"},
        {wam::ExportFormat::Gif, false, "gif", "gif", ""},
        {wam::ExportFormat::Mp4H264, false, "h264-software-preference", "h264", "aac"},
        {wam::ExportFormat::Mp4H264, true, "h264-hardware-preference", "h264", "aac"}};
    bool all_valid = true;
    bool matched = false;
    for (const auto& preset : presets) {
      if (!preset_name.empty() && preset_name != preset.name) continue;
      matched = true;
      options.format = preset.format;
      options.prefer_hardware_encoder = preset.hardware;
      options.preserve_pitch = true;
      options.output = directory / (std::string(preset.name) +
                                    wam::exportFormatExtension(preset.format));
      if (!runProcess(preset.name, wam::buildExportProcess(argv[1], options))) {
        all_valid = false;
        continue;
      }
      const auto metadata = directory / "metadata.txt";
      wam::ProcessCommand inspect;
      inspect.executable = argv[2];
      inspect.arguments = {"-v", "error", "-show_entries",
          "stream=codec_name:format=duration", "-of", "default=nw=1",
          "-o", utf8Path(metadata), utf8Path(options.output)};
      if (!runProcess("preset ffprobe", std::move(inspect))) {
        all_valid = false;
        continue;
      }
      std::ifstream stream(metadata);
      const std::string info{std::istreambuf_iterator<char>(stream),
                             std::istreambuf_iterator<char>()};
      const auto duration_at = info.find("duration=");
      const bool valid = info.find(std::string("codec_name=") + preset.video + "\n") != std::string::npos &&
          (!*preset.audio || info.find(std::string("codec_name=") + preset.audio + "\n") != std::string::npos) &&
          duration_at != std::string::npos &&
          std::abs(std::stod(info.substr(duration_at + 9)) - 2.0) <= 0.12;
      std::cout << preset.name << ": " << info;
      if (!valid) {
        std::cerr << "preset codec/duration mismatch\n";
        all_valid = false;
        continue;
      }
    }
    fs::remove_all(directory);
    if (!matched) std::cerr << "unknown preset: " << preset_name << "\n";
    return matched && all_valid ? 0 : 1;
  }
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
  if (!correct) {
    fs::remove_all(directory);
    std::cerr << "expected a 2.0 second export, got " << duration << "\n";
    return 1;
  }

  // The same retiming with pitch preservation off. This runs the varispeed
  // filter chain through a real FFmpeg because its arguments are only ever
  // validated when the output is opened: a chain that is merely well-formed
  // as a string can still fail every export at run time.
  const fs::path varispeed_output = directory / "two seconds varispeed.mp4";
  const fs::path varispeed_duration = directory / "varispeed-duration.txt";
  options.output = varispeed_output;
  options.preserve_pitch = false;
  if (!runProcess("varispeed export",
                  wam::buildExportProcess(argv[1], options))) {
    fs::remove_all(directory);
    std::cerr << "pitch-shifted export failed\n";
    return 1;
  }

  wam::ProcessCommand varispeed_probe;
  varispeed_probe.executable = argv[2];
  varispeed_probe.arguments = {
      "-v", "error", "-show_entries", "format=duration", "-of",
      "default=nw=1:nk=1", "-o", utf8Path(varispeed_duration),
      utf8Path(varispeed_output)};
  if (!runProcess("varispeed ffprobe", std::move(varispeed_probe))) {
    fs::remove_all(directory);
    std::cerr << "varispeed ffprobe failed\n";
    return 1;
  }
  double varispeed_seconds = 0.0;
  bool varispeed_correct = false;
  {
    std::ifstream duration_input(varispeed_duration);
    duration_input >> varispeed_seconds;
    varispeed_correct =
        duration_input && std::abs(varispeed_seconds - 2.0) <= 0.12;
  }
  if (!varispeed_correct) {
    fs::remove_all(directory);
    std::cerr << "expected a 2.0 second pitch-shifted export, got "
              << varispeed_seconds << "\n";
    return 1;
  }

  fs::remove_all(directory);
  std::cout << "export duration test passed (" << duration
            << " seconds pitch-preserved, " << varispeed_seconds
            << " seconds pitch-shifted)\n";
  return 0;
}
