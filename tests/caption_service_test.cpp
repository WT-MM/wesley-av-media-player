#include "caption_service.hpp"
#include "jobs.hpp"

#include <array>
#include <chrono>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <string>
#include <thread>
#include <utility>

#ifndef _WIN32
#include <cerrno>
#include <csignal>
#include <sys/stat.h>
#include <unistd.h>
#endif

namespace fs = std::filesystem;
using namespace std::chrono_literals;

static_assert(noexcept(std::declval<wam::CaptionService &>().cancel()),
              "caption cancellation must remain no-throw");

namespace {

#ifndef _WIN32
void exitSuccessfullyOnTerm(int) { _exit(0); }
#endif

void check(bool condition, const char *message) {
  if (!condition)
    throw std::runtime_error(message);
}

std::string readFile(const fs::path &path) {
  std::ifstream input(path, std::ios::binary);
  return std::string(std::istreambuf_iterator<char>(input),
                     std::istreambuf_iterator<char>());
}

std::size_t captionTemporaryCount(const fs::path &directory) {
  std::size_t count = 0;
  for (const auto &entry : fs::directory_iterator(directory)) {
    const auto name = entry.path().filename().string();
    if (name.rfind("wam-caption-", 0) == 0)
      ++count;
  }
  return count;
}

void writeFile(const fs::path &path, const std::string &contents) {
  std::ofstream output(path, std::ios::binary);
  output << contents;
  if (!output)
    throw std::runtime_error("could not write test file");
}

std::string toolName(const char *argv0) {
  return fs::path(argv0 ? argv0 : "").filename().string();
}

int runFakeCaptionTool(int argc, char **argv) {
  const std::string name = toolName(argv[0]);
  if (name.find("fake-ffmpeg") != std::string::npos) {
    if (argc < 2)
      return 2;
    const fs::path wav = argv[argc - 1];
    writeFile(wav, "RIFF-fake-16-kHz-mono-audio");
    if (const char *log = std::getenv("WAM_CAPTION_TEST_WAV_LOG"))
      writeFile(log, wav.string());
    return 0;
  }
  if (name.find("fake-whisper") != std::string::npos) {
    fs::path output_base;
    for (int i = 1; i + 1 < argc; ++i) {
      if (std::string(argv[i]) == "-of")
        output_base = argv[++i];
    }
    if (output_base.empty())
      return 3;
#ifndef _WIN32
    if (name.find("descendant") != std::string::npos) {
      signal(SIGTERM, exitSuccessfullyOnTerm);
      const pid_t descendant = fork();
      if (descendant < 0)
        return 4;
      if (descendant == 0) {
        signal(SIGTERM, SIG_IGN);
        if (const char *log =
                std::getenv("WAM_CAPTION_TEST_DESCENDANT_PID_LOG"))
          writeFile(log, std::to_string(getpid()));

        // More than the service's retained diagnostic cap also exceeds a
        // typical pipe buffer. Cancellation must keep draining while it waits
        // through the graceful process-group deadline.
        std::array<char, 4096> diagnostic{};
        diagnostic.fill('x');
        for (int block = 0; block < 32; ++block) {
          std::size_t written = 0;
          while (written < diagnostic.size()) {
            const ssize_t count =
                write(STDOUT_FILENO, diagnostic.data() + written,
                      diagnostic.size() - written);
            if (count > 0) {
              written += static_cast<std::size_t>(count);
            } else if (count < 0 && errno == EINTR) {
              continue;
            } else {
              break;
            }
          }
        }
        for (;;)
          pause();
      }
      for (;;)
        pause();
    }
#endif
    if (name.find("slow") != std::string::npos)
      std::this_thread::sleep_for(5s);
    fs::path srt = output_base;
    srt += ".srt";
    if (name.find("empty") != std::string::npos)
      writeFile(srt, "");
    else
      writeFile(srt, "1\n00:00:00,000 --> 00:00:01,000\nHello from WAM.\n");
    return 0;
  }
  return -1;
}

struct TestDirectory {
  fs::path path;
  explicit TestDirectory(const fs::path &base) {
    const auto stamp =
        std::chrono::steady_clock::now().time_since_epoch().count();
    path = base / ("wam-caption-service-test-" + std::to_string(stamp));
    fs::create_directories(path);
  }
  ~TestDirectory() {
    std::error_code ignored;
    fs::remove_all(path, ignored);
  }
};

fs::path copyAsTool(const fs::path &test_executable, const fs::path &directory,
                    const std::string &name) {
#ifdef _WIN32
  const fs::path destination = directory / (name + ".exe");
#else
  const fs::path destination = directory / name;
#endif
  fs::copy_file(test_executable, destination,
                fs::copy_options::overwrite_existing);
#ifndef _WIN32
  fs::permissions(destination,
                  fs::perms::owner_exec | fs::perms::group_exec |
                      fs::perms::others_exec,
                  fs::perm_options::add);
#endif
  return destination;
}

wam::CaptionRequest requestFor(const fs::path &directory,
                               const fs::path &ffmpeg, const fs::path &whisper,
                               const std::string &output_name) {
  wam::CaptionRequest request;
  request.input = directory / "input media.wav";
  request.output_srt = directory / output_name;
  request.tools.ffmpeg = ffmpeg;
  request.tools.whisper = whisper;
  request.tools.model = directory / "model.bin";
  writeFile(request.input, "non-empty-media");
  writeFile(request.tools.model, "non-empty-model");
  request.options.threads = 2;
  return request;
}

void waitForStage(wam::CaptionService &service, wam::CaptionStage stage) {
  const auto deadline = std::chrono::steady_clock::now() + 3s;
  while (std::chrono::steady_clock::now() < deadline) {
    const auto status = service.status();
    if (status.stage == stage || status.finished)
      return;
    std::this_thread::sleep_for(10ms);
  }
  throw std::runtime_error("caption service did not reach expected stage");
}

#ifndef _WIN32
bool waitForFile(const fs::path &path,
                 std::chrono::steady_clock::duration timeout) {
  const auto deadline = std::chrono::steady_clock::now() + timeout;
  while (std::chrono::steady_clock::now() < deadline) {
    std::error_code error;
    if (fs::is_regular_file(path, error) && fs::file_size(path, error) > 0)
      return true;
    std::this_thread::sleep_for(10ms);
  }
  return false;
}

bool processExists(pid_t process) {
  if (kill(process, 0) == 0)
    return true;
  return errno == EPERM;
}

bool waitForProcessExit(pid_t process,
                        std::chrono::steady_clock::duration timeout) {
  const auto deadline = std::chrono::steady_clock::now() + timeout;
  while (std::chrono::steady_clock::now() < deadline) {
    if (!processExists(process))
      return true;
    std::this_thread::sleep_for(10ms);
  }
  return !processExists(process);
}
#endif

} // namespace

int main(int argc, char **argv) {
  const int fake_result = runFakeCaptionTool(argc, argv);
  if (fake_result >= 0)
    return fake_result;

  try {
    TestDirectory temporary(fs::temp_directory_path());
    const fs::path this_executable = fs::weakly_canonical(argv[0]);
    const auto fake_ffmpeg =
        copyAsTool(this_executable, temporary.path, "fake-ffmpeg");
    const auto fake_whisper =
        copyAsTool(this_executable, temporary.path, "fake-whisper");
    const auto empty_whisper =
        copyAsTool(this_executable, temporary.path, "fake-whisper-empty");
    const auto slow_whisper =
        copyAsTool(this_executable, temporary.path, "fake-whisper-slow");
#ifndef _WIN32
    const auto descendant_whisper = copyAsTool(
        this_executable, temporary.path, "fake-whisper-descendant");
#endif

    const fs::path awkward = temporary.path / "media ' ; & $ file.mov";
    const fs::path awkward_wav = temporary.path / "audio ' ; & $ file.wav";
    const auto audio_command =
        wam::buildCaptionAudioCommand(fake_ffmpeg, awkward, awkward_wav);
    check(audio_command.find(wam::quoteArg(awkward.string())) !=
              std::string::npos,
          "caption diagnostic command must quote the input path");
    check(audio_command.find("-nostdin") != std::string::npos,
          "FFmpeg command must not read from the app's input");

    const fs::path wav_log = temporary.path / "wav-path.log";
#ifdef _WIN32
    _putenv_s("WAM_CAPTION_TEST_WAV_LOG", wav_log.string().c_str());
#else
    setenv("WAM_CAPTION_TEST_WAV_LOG", wav_log.c_str(), 1);
#endif

    // A valid tool exit is followed by SRT verification and an output commit.
    {
      auto request = requestFor(temporary.path, fake_ffmpeg, fake_whisper,
                                "captions without extension");
      writeFile(request.output_srt.string() + ".srt", "old captions");
      wam::CaptionService service;
      check(service.start(request), "valid caption request should start");
      check(!service.start(request),
            "a second concurrent request must be refused");
      service.wait();
      const auto status = service.status();
      check(status.stage == wam::CaptionStage::Completed,
            "valid caption pipeline should complete");
      check(status.succeeded && status.finished && !status.running,
            "successful status flags are inconsistent");
      check(status.progress == 1.0f, "successful progress must reach one");
      check(status.output_srt.extension() == ".srt",
            "service should normalize the SRT extension");
      check(readFile(status.output_srt).find("Hello from WAM") !=
                std::string::npos,
            "generated SRT was not committed");
      check(captionTemporaryCount(temporary.path) == 0,
            "successful captioning leaked a staging file");
      const fs::path used_wav = readFile(wav_log);
      check(!used_wav.empty() && !fs::exists(used_wav),
            "temporary WAV was not cleaned up");
    }

    // No-overwrite mode still commits atomically when the destination is free.
    {
      auto request = requestFor(temporary.path, fake_ffmpeg, fake_whisper,
                                "no-overwrite-success.srt");
      request.options.overwrite = false;
      wam::CaptionService service;
      check(service.start(request), "no-overwrite request should start");
      service.wait();
      const auto status = service.status();
      check(status.stage == wam::CaptionStage::Completed && status.succeeded,
            "no-overwrite request should commit to a free destination");
      check(readFile(request.output_srt).find("Hello from WAM") !=
                std::string::npos,
            "no-overwrite commit did not save the generated SRT");
      check(captionTemporaryCount(temporary.path) == 0,
            "no-overwrite captioning leaked a staging file");
    }

    // No-overwrite mode must preserve an existing destination.
    {
      auto request = requestFor(temporary.path, fake_ffmpeg, fake_whisper,
                                "no-overwrite-existing.srt");
      request.options.overwrite = false;
      writeFile(request.output_srt, "keep existing captions");
      wam::CaptionService service;
      check(service.start(request),
            "existing no-overwrite request should validate asynchronously");
      service.wait();
      const auto status = service.status();
      check(status.stage == wam::CaptionStage::Failed && !status.succeeded,
            "no-overwrite request must fail for an existing destination");
      check(readFile(request.output_srt) == "keep existing captions",
            "no-overwrite request modified an existing destination");
      check(captionTemporaryCount(temporary.path) == 0,
            "failed no-overwrite request leaked a staging file");
    }

    // A zero exit code cannot turn a missing/empty SRT into success.
    {
      auto request = requestFor(temporary.path, fake_ffmpeg, empty_whisper,
                                "empty-output.srt");
      writeFile(request.output_srt, "existing captions must survive");
      wam::CaptionService service;
      check(service.start(request), "empty-output request should start");
      service.wait();
      const auto status = service.status();
      check(status.stage == wam::CaptionStage::Failed && !status.succeeded,
            "empty SRT must fail even when whisper exits zero");
      check(status.error.find("non-empty SRT") != std::string::npos,
            "empty SRT failure should be actionable");
      check(readFile(request.output_srt) == "existing captions must survive",
            "invalid staged SRT must not modify an existing output");
      check(captionTemporaryCount(temporary.path) == 0,
            "failed captioning leaked a staging file");
    }

    // Validation is also asynchronous and reports the precise bad resource.
    {
      auto request = requestFor(temporary.path, fake_ffmpeg, fake_whisper,
                                "validation.srt");
      request.input = temporary.path / "missing-input.mov";
      wam::CaptionService service;
      check(service.start(request), "invalid request should enter validation");
      service.wait();
      const auto status = service.status();
      check(status.stage == wam::CaptionStage::Failed,
            "missing input should fail validation");
      check(status.error.find("Input media was not found") != std::string::npos,
            "missing input error should identify the input");
    }

    // Cancellation terminates the active child process and still performs WAV
    // cleanup. This also keeps CaptionService destruction bounded.
    {
      auto request = requestFor(temporary.path, fake_ffmpeg, slow_whisper,
                                "cancelled.srt");
      writeFile(request.output_srt, "existing captions must survive cancel");
      wam::CaptionService service;
      check(service.start(request), "cancellable request should start");
      waitForStage(service, wam::CaptionStage::Transcribing);
      const auto started = std::chrono::steady_clock::now();
      service.cancel();
      service.wait();
      const auto elapsed = std::chrono::steady_clock::now() - started;
      const auto status = service.status();
      check(status.stage == wam::CaptionStage::Cancelled && status.cancelled,
            "cancelled request should have terminal cancelled state");
      check(elapsed < 2s, "cancelling a caption subprocess took too long");
      check(readFile(request.output_srt) ==
                "existing captions must survive cancel",
            "cancelled captions must not modify an existing output");
      check(captionTemporaryCount(temporary.path) == 0,
            "cancelled captioning leaked a staging file");
      const fs::path used_wav = readFile(wav_log);
      check(!used_wav.empty() && !fs::exists(used_wav),
            "cancelled request leaked its temporary WAV");

      auto retry = requestFor(temporary.path, fake_ffmpeg, fake_whisper,
                              "retry-after-cancel.srt");
      check(service.start(retry),
            "caption service should be reusable after cancellation");
      service.wait();
      const auto retry_status = service.status();
      check(retry_status.stage == wam::CaptionStage::Completed &&
                retry_status.succeeded,
            "caption reuse must clear the previous cancellation request");
      check(readFile(retry.output_srt).find("Hello from WAM") !=
                std::string::npos,
            "caption reuse did not commit the retry output");
    }

#ifndef _WIN32
    // A cooperative tool leader can exit zero on TERM while a descendant
    // ignores TERM and keeps the diagnostic pipe open. Keep the leader
    // unreaped until the final whole-group kill, then leave no descendant.
    {
      const fs::path descendant_log = temporary.path / "descendant.pid";
      setenv("WAM_CAPTION_TEST_DESCENDANT_PID_LOG", descendant_log.c_str(), 1);
      auto request = requestFor(temporary.path, fake_ffmpeg,
                                descendant_whisper, "descendant-cancel.srt");
      writeFile(request.output_srt, "preserve captions during group cancel");
      wam::CaptionService service;
      check(service.start(request), "descendant caption request should start");
      waitForStage(service, wam::CaptionStage::Transcribing);
      check(waitForFile(descendant_log, 2s),
            "caption descendant should report its PID");
      const pid_t descendant =
          static_cast<pid_t>(std::stol(readFile(descendant_log)));
      const pid_t descendant_group = getpgid(descendant);
      check(descendant_group > 0 && descendant_group != getpgrp(),
            "caption helper must be isolated from the test runner group");

      const auto started = std::chrono::steady_clock::now();
      service.cancel();
      service.cancel();
      service.wait();
      const auto elapsed = std::chrono::steady_clock::now() - started;
      const auto status = service.status();
      const bool descendant_gone = waitForProcessExit(descendant, 1s);
      if (!descendant_gone)
        kill(descendant, SIGKILL);

      check(status.stage == wam::CaptionStage::Cancelled && status.cancelled,
            "descendant caption request should finish as cancelled");
      check(descendant_gone,
            "caption cancellation must kill a TERM-ignoring descendant");
      check(elapsed < 2s,
            "repeated caption cancellation must not extend the deadline");
      check(readFile(request.output_srt) ==
                "preserve captions during group cancel",
            "descendant cancellation must preserve an existing output");
      check(captionTemporaryCount(temporary.path) == 0,
            "descendant cancellation leaked a staging file");
      unsetenv("WAM_CAPTION_TEST_DESCENDANT_PID_LOG");
    }
#endif

#ifdef __APPLE__
    // Cloud placeholders report a logical size but can block indefinitely on
    // their first read. WAM must fail before starting FFmpeg and explain how
    // to make the media locally available. Some non-APFS test volumes reject
    // SF_DATALESS, in which case this platform-specific assertion is skipped.
    {
      auto request =
          requestFor(temporary.path, fake_ffmpeg, fake_whisper, "dataless.srt");
      struct stat information {};
      if (::chflags(request.input.c_str(), SF_DATALESS) == 0 &&
          ::stat(request.input.c_str(), &information) == 0 &&
          (information.st_flags & SF_DATALESS) != 0) {
        wam::CaptionService service;
        check(service.start(request), "dataless request should validate");
        service.wait();
        const auto status = service.status();
        check(status.stage == wam::CaptionStage::Failed && !status.succeeded,
              "dataless media must fail before extraction");
        check(status.error.find("not downloaded") != std::string::npos,
              "dataless error should tell the user to download the media");
      }
    }
#endif

    std::cout << "caption service tests passed\n";
    return 0;
  } catch (const std::exception &exception) {
    std::cerr << "caption service test failed: " << exception.what() << '\n';
    return 1;
  }
}
