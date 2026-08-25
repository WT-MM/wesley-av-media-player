#include "jobs.hpp"

#include <algorithm>
#include <array>
#include <cctype>
#include <chrono>
#include <cmath>
#include <cstdlib>
#include <sstream>
#include <system_error>
#include <thread>
#include <vector>

#if !defined(_WIN32)
#include <cerrno>
#include <csignal>
#include <fcntl.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>
#endif

#ifdef __APPLE__
#include <mach-o/dyld.h>
#elif defined(_WIN32)
#include <windows.h>
#endif

namespace wam {

namespace {

using namespace std::chrono_literals;

constexpr auto kProcessPollInterval = 20ms;
constexpr auto kGracefulShutdownTimeout = 750ms;

std::string pathArgument(const std::filesystem::path& path) {
#ifdef _WIN32
  const auto utf8 = path.u8string();
  return std::string(reinterpret_cast<const char*>(utf8.data()), utf8.size());
#else
  return path.string();
#endif
}

#ifdef _WIN32

std::wstring widenUtf8(const std::string& value) {
  if (value.empty()) return {};
  const int size = MultiByteToWideChar(CP_UTF8, 0, value.data(),
                                       static_cast<int>(value.size()), nullptr, 0);
  if (size <= 0) return std::wstring(value.begin(), value.end());
  std::wstring result(static_cast<size_t>(size), L'\0');
  MultiByteToWideChar(CP_UTF8, 0, value.data(), static_cast<int>(value.size()),
                      result.data(), size);
  return result;
}

std::wstring quoteWindowsArgument(const std::wstring& value) {
  std::wstring result = L"\"";
  std::size_t slashes = 0;
  for (const wchar_t c : value) {
    if (c == L'\\') {
      ++slashes;
    } else if (c == L'\"') {
      result.append(slashes * 2 + 1, L'\\');
      result.push_back(L'\"');
      slashes = 0;
    } else {
      result.append(slashes, L'\\');
      slashes = 0;
      result.push_back(c);
    }
  }
  result.append(slashes * 2, L'\\');
  result.push_back(L'\"');
  return result;
}

std::filesystem::path resolveWindowsExecutable(
    const std::filesystem::path& executable) {
  if (executable.is_absolute() || executable.has_parent_path())
    return executable;
  std::array<wchar_t, 32768> resolved{};
  const wchar_t* extension = executable.has_extension() ? nullptr : L".exe";
  const DWORD length = SearchPathW(nullptr, executable.c_str(), extension,
                                   static_cast<DWORD>(resolved.size()),
                                   resolved.data(), nullptr);
  if (length > 0 && length < resolved.size())
    return std::filesystem::path(std::wstring(resolved.data(), length));
  return executable;
}

int runWindowsChild(const detail::CancellationFlag& cancellation,
                    const wchar_t* application, std::wstring command_line) {
  if (cancellation.requested()) return 130;

  HANDLE job = CreateJobObjectW(nullptr, nullptr);
  if (!job) return static_cast<int>(GetLastError());

  JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits{};
  limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
  if (!SetInformationJobObject(job, JobObjectExtendedLimitInformation, &limits,
                               sizeof(limits))) {
    const int error = static_cast<int>(GetLastError());
    CloseHandle(job);
    return error;
  }

  std::vector<wchar_t> mutable_command(command_line.begin(), command_line.end());
  mutable_command.push_back(L'\0');

  STARTUPINFOW startup{};
  startup.cb = sizeof(startup);
  PROCESS_INFORMATION process{};
  const DWORD flags = CREATE_NO_WINDOW | CREATE_NEW_PROCESS_GROUP | CREATE_SUSPENDED;
  if (!CreateProcessW(application, mutable_command.data(), nullptr, nullptr, FALSE,
                      flags, nullptr, nullptr, &startup, &process)) {
    const int error = static_cast<int>(GetLastError());
    CloseHandle(job);
    return error;
  }

  if (!AssignProcessToJobObject(job, process.hProcess)) {
    const int error = static_cast<int>(GetLastError());
    TerminateProcess(process.hProcess, static_cast<UINT>(error));
    ResumeThread(process.hThread);
    WaitForSingleObject(process.hProcess, INFINITE);
    CloseHandle(process.hThread);
    CloseHandle(process.hProcess);
    CloseHandle(job);
    return error;
  }
  ResumeThread(process.hThread);
  CloseHandle(process.hThread);

  bool cancellation_started = false;
  std::chrono::steady_clock::time_point force_kill_at{};
  for (;;) {
    const DWORD wait = WaitForSingleObject(process.hProcess,
                                            static_cast<DWORD>(kProcessPollInterval.count()));
    if (wait == WAIT_OBJECT_0) {
      // Preserve cancellation as the public result even when a cooperative
      // child handles CTRL_BREAK and exits zero.
      if (cancellation.requested()) cancellation_started = true;
      break;
    }
    if (wait == WAIT_FAILED) {
      const int error = static_cast<int>(GetLastError());
      TerminateJobObject(job, static_cast<UINT>(error));
      CloseHandle(process.hProcess);
      CloseHandle(job);
      return error;
    }

    if (cancellation.requested() && !cancellation_started) {
      cancellation_started = true;
      force_kill_at = std::chrono::steady_clock::now() + kGracefulShutdownTimeout;
      // Best effort for console-aware tools such as FFmpeg. CREATE_NO_WINDOW
      // means this may not be deliverable, so the Job Object remains the
      // reliable bounded fallback below.
      GenerateConsoleCtrlEvent(CTRL_BREAK_EVENT, process.dwProcessId);
    }
    if (cancellation_started && std::chrono::steady_clock::now() >= force_kill_at) {
      TerminateJobObject(job, 137);
      WaitForSingleObject(process.hProcess, INFINITE);
      break;
    }
  }

  DWORD exit_code = 1;
  GetExitCodeProcess(process.hProcess, &exit_code);
  CloseHandle(process.hProcess);
  // Closing the configured Job Object also guarantees no descendant survives
  // a shell that happened to exit before its child.
  CloseHandle(job);
  return cancellation_started ? 130 : static_cast<int>(exit_code);
}

int runCommand(const detail::CancellationFlag& cancellation,
               const std::string& command) {
  // Legacy/test-only shell route. Production exports use runProcessCommand().
  std::wstring command_line =
      L"cmd.exe /D /S /C \"" + widenUtf8(command) + L"\"";
  return runWindowsChild(cancellation, nullptr, std::move(command_line));
}

int runProcessCommand(const detail::CancellationFlag& cancellation,
                      const ProcessCommand& command) {
  if (command.executable.empty()) return ERROR_FILE_NOT_FOUND;
  const auto executable = resolveWindowsExecutable(command.executable);
  std::wstring command_line = quoteWindowsArgument(executable.wstring());
  for (const auto& argument : command.arguments) {
    command_line.push_back(L' ');
    command_line += quoteWindowsArgument(widenUtf8(argument));
  }
  const std::wstring application = executable.wstring();
  return runWindowsChild(cancellation, application.c_str(),
                         std::move(command_line));
}

#else

int normalizedExitCode(int status) {
  if (WIFEXITED(status)) return WEXITSTATUS(status);
  if (WIFSIGNALED(status)) return 128 + WTERMSIG(status);
  return 1;
}

bool establishProcessGroup(pid_t child, int* error) {
  if (setpgid(child, child) == 0) return true;

  const int setup_error = errno ? errno : 1;
  // The child can win the setpgid/exec race. EACCES alone is not proof that
  // the numeric group belongs to it, so verify the group before any negative
  // PID signal is allowed.
  if (setup_error == EACCES && getpgid(child) == child) return true;
  if (error) *error = setup_error;
  return false;
}

void signalVerifiedProcessGroup(pid_t group, int signal) {
  int result = 0;
  do {
    result = kill(-group, signal);
  } while (result != 0 && errno == EINTR);
}

bool reapPosixChild(pid_t child, int* status, int* error) {
  pid_t waited = -1;
  do {
    waited = waitpid(child, status, 0);
  } while (waited < 0 && errno == EINTR);
  if (waited == child) return true;
  if (error) *error = errno ? errno : 1;
  return false;
}

enum class ChildObservation { Running, Exited, Error };

ChildObservation observePosixChild(pid_t child, int* error) {
  siginfo_t information{};
  int observed = -1;
  do {
    observed = waitid(P_PID, static_cast<id_t>(child), &information,
                      WEXITED | WNOHANG | WNOWAIT);
  } while (observed != 0 && errno == EINTR);
  if (observed != 0) {
    if (error) *error = errno ? errno : 1;
    return ChildObservation::Error;
  }
  return information.si_pid == child ? ChildObservation::Exited
                                     : ChildObservation::Running;
}

int terminateUnisolatedChild(pid_t child, int error) {
  int killed = 0;
  do {
    killed = kill(child, SIGKILL);
  } while (killed != 0 && errno == EINTR);
  int ignored_status = 0;
  int ignored_error = 0;
  reapPosixChild(child, &ignored_status, &ignored_error);
  return error ? error : 1;
}

int waitForPosixChild(const detail::CancellationFlag& cancellation,
                      pid_t child) {
  int setup_error = 0;
  if (!establishProcessGroup(child, &setup_error)) {
    // macOS can report ESRCH when a very short-lived, already-isolated child
    // has become waitable before the parent wins the setpgid race. Preserve
    // its real status without ever signalling an unverified numeric PGID.
    int observation_error = 0;
    if (observePosixChild(child, &observation_error) ==
        ChildObservation::Exited) {
      int status = 0;
      int reap_error = 0;
      if (!reapPosixChild(child, &status, &reap_error))
        return reap_error ? reap_error : setup_error;
      return cancellation.requested() ? 130 : normalizedExitCode(status);
    }
    if (observation_error == ECHILD)
      return setup_error ? setup_error : observation_error;
    return terminateUnisolatedChild(child, setup_error);
  }

  bool cancellation_started = false;
  std::chrono::steady_clock::time_point force_kill_at{};
  for (;;) {
    if (!cancellation_started) {
      if (cancellation.requested()) {
        cancellation_started = true;
        force_kill_at =
            std::chrono::steady_clock::now() + kGracefulShutdownTimeout;
        signalVerifiedProcessGroup(child, SIGTERM);
      } else {
        int observation_error = 0;
        const auto observation = observePosixChild(child, &observation_error);
        if (observation == ChildObservation::Error) {
          // ECHILD means somebody else already reaped the leader, so its PID
          // can no longer protect the group identity. Never group-signal it.
          if (observation_error != ECHILD) {
            signalVerifiedProcessGroup(child, SIGKILL);
            int ignored_status = 0;
            int ignored_error = 0;
            reapPosixChild(child, &ignored_status, &ignored_error);
          }
          return observation_error ? observation_error : 1;
        }
        if (observation == ChildObservation::Exited) {
          // The exit is only observed, not reaped. Re-check cancellation while
          // the PID still reserves the process-group identity.
          if (cancellation.requested()) {
            cancellation_started = true;
            force_kill_at =
                std::chrono::steady_clock::now() + kGracefulShutdownTimeout;
            signalVerifiedProcessGroup(child, SIGTERM);
          } else {
            int status = 0;
            int reap_error = 0;
            if (!reapPosixChild(child, &status, &reap_error))
              return reap_error ? reap_error : 1;
            return normalizedExitCode(status);
          }
        }
      }
    }

    if (cancellation_started &&
        std::chrono::steady_clock::now() >= force_kill_at) {
      // The leader remains waitable (possibly a zombie) through this final
      // group signal. That reserves its PID/PGID and makes -child safe.
      signalVerifiedProcessGroup(child, SIGKILL);
      int status = 0;
      int reap_error = 0;
      reapPosixChild(child, &status, &reap_error);
      // Cancellation is the canonical public outcome even if a cooperative
      // TERM handler made the leader exit zero.
      return 130;
    }
    std::this_thread::sleep_for(kProcessPollInterval);
  }
}

int runCommand(const detail::CancellationFlag& cancellation,
               const std::string& command) {
  if (cancellation.requested()) return 130;

  const pid_t child = fork();
  if (child < 0) return errno ? errno : 1;
  if (child == 0) {
    // A dedicated process group lets cancellation reach the shell and every
    // command it spawned.
    if (setpgid(0, 0) != 0) _exit(125);
    execl("/bin/sh", "sh", "-c", command.c_str(), static_cast<char*>(nullptr));
    _exit(127);
  }
  return waitForPosixChild(cancellation, child);
}

int runProcessCommand(const detail::CancellationFlag& cancellation,
                      const ProcessCommand& command) {
  if (cancellation.requested()) return 130;
  if (command.executable.empty()) return ENOENT;

  std::vector<std::string> storage;
  storage.reserve(command.arguments.size() + 1);
  storage.push_back(pathArgument(command.executable));
  storage.insert(storage.end(), command.arguments.begin(),
                 command.arguments.end());
  std::vector<char*> arguments;
  arguments.reserve(storage.size() + 1);
  for (auto& value : storage) arguments.push_back(value.data());
  arguments.push_back(nullptr);

  const pid_t child = fork();
  if (child < 0) return errno ? errno : 1;
  if (child == 0) {
    if (setpgid(0, 0) != 0) _exit(125);
    execvp(arguments.front(), arguments.data());
    _exit(errno == ENOENT ? 127 : 126);
  }
  return waitForPosixChild(cancellation, child);
}

#endif

bool reserveFileExclusively(const std::filesystem::path& path,
                            std::string* error) {
#ifdef _WIN32
  HANDLE file = CreateFileW(path.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_NEW,
                            FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) {
    if (error)
      *error = std::error_code(static_cast<int>(GetLastError()),
                               std::system_category())
                   .message();
    return false;
  }
  CloseHandle(file);
  return true;
#else
  const int file =
      open(path.c_str(), O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC, 0666);
  if (file < 0) {
    if (error)
      *error = std::error_code(errno, std::generic_category()).message();
    return false;
  }
  close(file);
  return true;
#endif
}

std::string formatNumber(double value) {
  std::ostringstream stream;
  stream.precision(12);
  stream << value;
  return stream.str();
}

}  // namespace

std::string quoteArg(const std::string& value) {
#ifdef _WIN32
  std::string out = "\"";
  unsigned slashes = 0;
  for (char c : value) {
    if (c == '\\') {
      ++slashes;
    } else if (c == '"') {
      out.append(slashes * 2 + 1, '\\');
      out += '"';
      slashes = 0;
    } else {
      out.append(slashes, '\\');
      slashes = 0;
      out += c;
    }
  }
  out.append(slashes * 2, '\\');
  return out + '"';
#else
  std::string out = "'";
  for (char c : value) out += (c == '\'' ? "'\\''" : std::string(1, c));
  return out + "'";
#endif
}

std::string atempoFilter(double speed) {
  speed = std::clamp(speed, 0.0625, 16.0);
  std::vector<double> stages;
  while (speed < 0.5) {
    stages.push_back(0.5);
    speed /= 0.5;
  }
  while (speed > 2.0) {
    stages.push_back(2.0);
    speed /= 2.0;
  }
  stages.push_back(speed);
  std::ostringstream out;
  for (size_t i = 0; i < stages.size(); ++i) {
    if (i) out << ',';
    out << "atempo=" << stages[i];
  }
  return out.str();
}

// The varispeed ("tape speed") route: relabel the sample rate so the audio
// plays faster and higher together, then resample back to a normal rate.
//
// asetrate takes a plain integer -- it has no variable for the stream's own
// sample rate, so the earlier `asetrate=sample_rate*N` was not a filter
// expression at all and every pitch-shifted export failed to even open its
// output ("Undefined constant ... in 'sample_rate*2'", exit 234). Pinning the
// audio to a known rate first makes the arithmetic possible without probing
// the input: resample to 48 kHz, relabel that as 48000*speed, resample back.
std::string varispeedFilter(double speed) {
  constexpr long kBaseRate = 48000;
  speed = std::clamp(speed, 0.0625, 16.0);
  const long shifted = std::lround(static_cast<double>(kBaseRate) * speed);
  const std::string base = std::to_string(kBaseRate);
  return "aresample=" + base + ",asetrate=" + std::to_string(shifted) +
         ",aresample=" + base;
}

bool CropRect::active() const {
  // One part in a thousand of the frame. Below that the rectangle is a
  // rounding artefact of a pointer drag, not an edit, and running the crop
  // filter for it would only cost an even-rounding shift.
  constexpr double kTolerance = 0.001;
  return std::isfinite(x) && std::isfinite(y) && std::isfinite(width) &&
         std::isfinite(height) &&
         (x > kTolerance || y > kTolerance || width < 1.0 - kTolerance ||
          height < 1.0 - kTolerance);
}

const char* exportFormatExtension(ExportFormat format) {
  switch (format) {
    case ExportFormat::Mp4H264:
    case ExportFormat::Mp4Hevc:
      return ".mp4";
    case ExportFormat::WebmVp9:
      return ".webm";
    case ExportFormat::MkvCopy:
      return ".mkv";
    case ExportFormat::Gif:
      return ".gif";
  }
  return ".mp4";
}

bool exportUsesStreamCopy(const EditOptions& options) {
  if (options.format != ExportFormat::MkvCopy) return false;
  // Copying never decodes, so it can neither retime nor crop. There is no
  // partial version of this: either both are absent and the export is a pure
  // remux, or the request needs pixels and a re-encode is the honest answer.
  if (std::abs(options.speed - 1.0) > 1e-9) return false;
  return !options.crop.active();
}

std::string cropFilter(const CropRect& crop) {
  if (!crop.active()) return {};
  // The rectangle is clamped into the frame here rather than trusted from the
  // UI: a drag can leave a fraction a hair outside [0,1], and `crop` answers
  // an out-of-frame rectangle with a hard failure rather than a clamp.
  const double w = std::clamp(crop.width, 0.02, 1.0);
  const double h = std::clamp(crop.height, 0.02, 1.0);
  const double x = std::clamp(crop.x, 0.0, 1.0 - w);
  const double y = std::clamp(crop.y, 0.0, 1.0 - h);
  // `iw`/`ih` are the crop filter's own source-dimension variables, so the
  // normalized rectangle is multiplied out by FFmpeg against the real coded
  // size. Nothing on this side needs to know the source dimensions, which is
  // exactly why the rectangle is stored normalized.
  //
  // floor(.../2)*2 on all four terms is the even-dimension rule from the
  // header: 4:2:0 chroma is subsampled by two in both axes, so an odd size or
  // an odd offset is either refused by the encoder or silently shifts chroma.
  std::ostringstream filter;
  filter << "crop=w=floor(iw*" << formatNumber(w) << "/2)*2"
         << ":h=floor(ih*" << formatNumber(h) << "/2)*2"
         << ":x=floor(iw*" << formatNumber(x) << "/2)*2"
         << ":y=floor(ih*" << formatNumber(y) << "/2)*2";
  return filter.str();
}

ProcessCommand buildExportProcess(const std::filesystem::path& ffmpeg,
                                  const EditOptions& o) {
  const double speed = std::clamp(o.speed, 0.0625, 16.0);
  const bool copy = exportUsesStreamCopy(o);
  const bool gif = o.format == ExportFormat::Gif;
  const std::string crop = cropFilter(o.crop);
  ProcessCommand command;
  command.executable = ffmpeg;
  auto& args = command.arguments;
  args = {"-hide_banner", "-loglevel", "warning", "-nostdin", "-y"};
  if (o.in_seconds > 0.001) {
    args.emplace_back("-ss");
    args.push_back(formatNumber(o.in_seconds));
  }
  // `-t` is deliberately an input option. If it is placed after `-i`, FFmpeg
  // limits the already-retimed output and a 2x export reads twice as much of
  // the source as the selected trim range.
  if (o.out_seconds > o.in_seconds + 0.001) {
    double window = o.out_seconds - o.in_seconds;
    if (gif) {
      // The cap is on the GIF's own playing time, so the amount of SOURCE it
      // may consume scales with the retime: a 2x export fits twice as much
      // source into the same capped output.
      window = std::min(window, kGifMaximumOutputSeconds * speed);
    }
    args.emplace_back("-t");
    args.push_back(formatNumber(window));
  } else if (gif) {
    args.emplace_back("-t");
    args.push_back(formatNumber(kGifMaximumOutputSeconds * speed));
  }
  args.emplace_back("-i");
  args.push_back(pathArgument(o.input));

  if (gif) {
    // GIF has no audio and a 256-colour palette per frame. A default export
    // quantizes to a fixed web palette and bands badly, so the palette is
    // generated from these exact frames and applied in one pass:
    // split the stream, build a palette from one branch, map the other
    // through it. `-filter_complex` and `-filter:v` are mutually exclusive,
    // which is why this branch builds the whole chain itself.
    std::ostringstream chain;
    chain << "[0:v]";
    if (!crop.empty()) chain << crop << ',';
    chain << "setpts=(PTS-STARTPTS)/" << formatNumber(speed) << ','
          << "fps=" << kGifFramesPerSecond << ','
          // Scale AFTER the crop, never before: cropping a scaled frame would
          // map the rectangle to the wrong source pixels. -2 keeps the aspect
          // and lands on an even height. `min(iw,cap)` never upscales.
          << "scale=w=min(iw\\," << kGifMaximumWidth << "):h=-2:flags=lanczos,"
          << "split[s0][s1];[s0]palettegen=stats_mode=diff[p];"
          << "[s1][p]paletteuse=dither=bayer:bayer_scale=5:diff_mode=rectangle";
    args.emplace_back("-filter_complex");
    args.push_back(chain.str());
    args.insert(args.end(), {"-an", "-loop", "0"});
    args.push_back(pathArgument(o.output));
    return command;
  }

  args.insert(args.end(), {"-map", "0:v:0?", "-map", "0:a:0?"});

  if (copy) {
    // A pure remux: no filters (they would require decoding), no pixel format,
    // no encoder settings. The trim's IN point snaps back to the nearest
    // keyframe because a copied stream must begin on one -- surfaced in the
    // Quick Edit sheet, not swallowed here.
    args.insert(args.end(), {"-c", "copy"});
    args.push_back(pathArgument(o.output));
    return command;
  }

  args.emplace_back("-filter:v");
  // Crop BEFORE anything that changes geometry. Nothing here scales, but the
  // ordering is the rule the GIF branch also follows and the one a future
  // scale step must not break.
  args.push_back(crop.empty()
                     ? "setpts=(PTS-STARTPTS)/" + formatNumber(speed)
                     : crop + ",setpts=(PTS-STARTPTS)/" + formatNumber(speed));
  args.emplace_back("-filter:a");
  args.push_back(o.preserve_pitch ? atempoFilter(speed)
                                  : varispeedFilter(speed));

  switch (o.format) {
    case ExportFormat::Mp4Hevc:
      args.insert(args.end(), {"-c:v", "hevc_videotoolbox", "-allow_sw", "1",
                               "-realtime", "1", "-q:v", "65", "-pix_fmt",
                               "yuv420p",
                               // Apple's players refuse the `hev1` sample
                               // entry FFmpeg writes by default; `hvc1` is the
                               // tag QuickTime, Safari and Photos accept.
                               "-tag:v", "hvc1"});
      args.insert(args.end(), {"-c:a", "aac", "-b:a", "192k", "-movflags",
                               "+faststart"});
      break;
    case ExportFormat::WebmVp9:
      // Software only -- there is no VP9 hardware encoder on this platform.
      // `-b:v 0` is what puts libvpx in constant-quality mode; without it the
      // CRF is ignored and the result is a very low default bitrate.
      args.insert(args.end(), {"-c:v", "libvpx-vp9", "-b:v", "0", "-crf", "32",
                               "-row-mt", "1", "-pix_fmt", "yuv420p"});
      args.insert(args.end(), {"-c:a", "libopus", "-b:a", "128k"});
      break;
    case ExportFormat::MkvCopy:
      // MkvCopy that reached here needs pixels (a retime or a crop), so it is
      // an MKV RE-ENCODE. Same video settings as the default preset; Matroska
      // takes AAC happily and has no faststart concept.
      args.insert(args.end(), {"-c:v", "h264_videotoolbox", "-allow_sw", "1",
                               "-realtime", "1", "-q:v", "65", "-pix_fmt",
                               "yuv420p"});
      args.insert(args.end(), {"-c:a", "aac", "-b:a", "192k"});
      break;
    case ExportFormat::Gif:
    case ExportFormat::Mp4H264:
    default:
      if (o.prefer_hardware_encoder) {
#ifdef __APPLE__
        args.insert(args.end(), {"-c:v", "h264_videotoolbox", "-allow_sw", "1",
                                 "-realtime", "1", "-q:v", "65", "-pix_fmt",
                                 "yuv420p"});
#else
        args.insert(args.end(), {"-c:v", "libx264", "-preset", "veryfast",
                                 "-crf", "18", "-pix_fmt", "yuv420p"});
#endif
      } else {
        args.insert(args.end(), {"-c:v", "libx264", "-preset", "veryfast",
                                 "-crf", "18", "-pix_fmt", "yuv420p"});
      }
      args.insert(args.end(), {"-c:a", "aac", "-b:a", "192k", "-movflags",
                               "+faststart"});
      break;
  }
  args.push_back(pathArgument(o.output));
  return command;
}

std::string buildExportCommand(const std::filesystem::path& ffmpeg,
                               const EditOptions& options) {
  const ProcessCommand process = buildExportProcess(ffmpeg, options);
  std::ostringstream command;
  command << quoteArg(pathArgument(process.executable));
  for (const auto& argument : process.arguments)
    command << ' ' << quoteArg(argument);
  return command.str();
}

std::filesystem::path reserveExportStagingFile(
    const std::filesystem::path& destination, std::string* error) {
  if (error) error->clear();
  if (destination.empty()) {
    if (error) *error = "The export destination is empty.";
    return {};
  }

  std::error_code path_error;
  const auto absolute_destination =
      std::filesystem::absolute(destination, path_error);
  if (path_error) {
    if (error) *error = path_error.message();
    return {};
  }
  const auto directory = absolute_destination.parent_path();
  if (!std::filesystem::is_directory(directory, path_error)) {
    if (error)
      *error = path_error ? path_error.message()
                          : "The export destination folder does not exist.";
    return {};
  }

  static std::atomic<uint64_t> counter{0};
#ifdef _WIN32
  const uint64_t process_id = static_cast<uint64_t>(GetCurrentProcessId());
#else
  const uint64_t process_id = static_cast<uint64_t>(getpid());
#endif
  for (int attempt = 0; attempt < 128; ++attempt) {
    const uint64_t token =
        static_cast<uint64_t>(
            std::chrono::steady_clock::now().time_since_epoch().count()) ^
        (process_id << 32U) ^
        counter.fetch_add(1, std::memory_order_relaxed);
    // The staging file carries the DESTINATION's extension, not a fixed
    // ".mp4". FFmpeg selects its muxer from the output path it is handed, and
    // the path it is handed is this staging file -- so a WebM or GIF export
    // whose staging file ended in ".mp4" would be muxed as MP4 and then
    // renamed into place, producing a file that lies about itself. An
    // extensionless destination keeps the historical ".mp4".
    const auto destination_extension = absolute_destination.extension().string();
    std::ostringstream name;
    name << ".wam-export-" << std::hex << token << '-' << attempt
         << (destination_extension.empty() ? std::string(".mp4")
                                           : destination_extension);
    const auto candidate = directory / name.str();
    std::string reserve_error;
    if (reserveFileExclusively(candidate, &reserve_error)) return candidate;
    if (attempt == 127 && error) *error = std::move(reserve_error);
  }
  if (error && error->empty())
    *error = "Could not reserve a unique export staging file.";
  return {};
}

bool commitExportStagingFile(const std::filesystem::path& staging,
                             const std::filesystem::path& destination,
                             std::string* error) {
  if (error) error->clear();
  if (staging.empty() || destination.empty()) {
    if (error) *error = "The export staging or destination path is empty.";
    return false;
  }
  std::error_code path_error;
  if (!std::filesystem::is_regular_file(staging, path_error) || path_error) {
    if (error)
      *error = path_error ? path_error.message()
                          : "The encoded staging file is missing.";
    return false;
  }
  const auto size = std::filesystem::file_size(staging, path_error);
  if (path_error || size == 0) {
    if (error)
      *error = path_error ? path_error.message()
                          : "The encoded staging file is empty.";
    return false;
  }

  const auto staging_parent =
      std::filesystem::weakly_canonical(staging.parent_path(), path_error);
  if (path_error) {
    if (error) *error = path_error.message();
    return false;
  }
  path_error.clear();
  const auto absolute_destination =
      std::filesystem::absolute(destination, path_error);
  if (path_error) {
    if (error) *error = path_error.message();
    return false;
  }
  path_error.clear();
  const auto destination_parent =
      std::filesystem::weakly_canonical(absolute_destination.parent_path(),
                                        path_error);
  if (path_error || staging_parent != destination_parent) {
    if (error)
      *error = path_error
                   ? path_error.message()
                   : "Export staging and destination must share a folder.";
    return false;
  }

#ifdef _WIN32
  if (!MoveFileExW(staging.c_str(), absolute_destination.c_str(),
                   MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH)) {
    if (error)
      *error = std::error_code(static_cast<int>(GetLastError()),
                               std::system_category())
                   .message();
    return false;
  }
#else
  std::filesystem::rename(staging, absolute_destination, path_error);
  if (path_error) {
    if (error) *error = path_error.message();
    return false;
  }
#endif
  return true;
}

void removeExportStagingFile(const std::filesystem::path& staging) noexcept {
  if (staging.empty()) return;
  std::error_code ignored;
  std::filesystem::remove(staging, ignored);
}

BackgroundJob::~BackgroundJob() {
  cancel();
  wait();
}

bool BackgroundJob::start(std::string label, std::string command) {
  return startWorker(
      std::move(label),
      [command = std::move(command)](
          const detail::CancellationFlag& cancellation) {
        return runCommand(cancellation, command);
      });
}

bool BackgroundJob::start(std::string label, ProcessCommand command) {
  return startWorker(
      std::move(label),
      [command = std::move(command)](
          const detail::CancellationFlag& cancellation) {
        return runProcessCommand(cancellation, command);
      });
}

bool BackgroundJob::startWorker(
    std::string label,
    std::function<int(const detail::CancellationFlag&)> operation) {
  std::lock_guard worker_lock(worker_mutex_);
  if (running_.load(std::memory_order_acquire)) return false;
  if (worker_.joinable()) worker_.join();

  // Reset the reusable source before publishing the new job as running.
  // cancel() never takes worker_mutex_, so every request made after this
  // publication remains visible to the worker and cannot be overwritten.
  cancellation_.reset();
  finished_ = false;
  exit_code_ = -1;
  {
    std::lock_guard lock(label_mutex_);
    label_ = std::move(label);
  }
  running_.store(true, std::memory_order_release);
  try {
    worker_ = std::thread(
        [this, operation = std::move(operation)] {
          int code = 1;
          try {
            code = operation(cancellation_);
          } catch (...) {
            code = 1;
          }
          exit_code_ = code;
          running_ = false;
          finished_ = true;
        });
  } catch (...) {
    // `running_` is claimed before thread creation to serialize callers. Give
    // that claim back if the OS cannot create the worker, otherwise this job
    // object can never be used again.
    exit_code_ = -1;
    finished_ = true;
    running_ = false;
    throw;
  }
  return true;
}

std::string BackgroundJob::label() const {
  std::lock_guard lock(label_mutex_);
  return label_;
}

void BackgroundJob::cancel() noexcept { cancellation_.request(); }

void BackgroundJob::wait() {
  std::lock_guard worker_lock(worker_mutex_);
  if (worker_.joinable()) worker_.join();
}

void BackgroundJob::reset() {
  std::lock_guard worker_lock(worker_mutex_);
  if (running_.load(std::memory_order_acquire)) return;
  if (worker_.joinable()) worker_.join();
  finished_ = false;
  exit_code_ = -1;
  std::lock_guard lock(label_mutex_);
  label_.clear();
}

static std::filesystem::path executablePath(const char* argv0) {
#ifdef __APPLE__
  uint32_t size = 0;
  _NSGetExecutablePath(nullptr, &size);
  std::string buffer(size, '\0');
  if (_NSGetExecutablePath(buffer.data(), &size) == 0)
    return std::filesystem::weakly_canonical(buffer.c_str());
#elif defined(_WIN32)
  std::wstring buffer(32768, L'\0');
  const DWORD size = GetModuleFileNameW(nullptr, buffer.data(), buffer.size());
  if (size) return std::filesystem::path(buffer.substr(0, size));
#else
  std::vector<char> buffer(4096);
  const auto size = readlink("/proc/self/exe", buffer.data(), buffer.size() - 1);
  if (size > 0) return std::filesystem::path(std::string(buffer.data(), size));
#endif
  return std::filesystem::absolute(argv0 ? argv0 : "wam");
}

namespace {

// A packaged app puts its runtime under Contents/Resources; a development
// build leaves it in build/runtime, three levels above Contents/MacOS. Both
// are "ours" and both outrank anything installed on the host.
std::vector<std::filesystem::path> packagedToolDirectories(const char* argv0) {
  const auto dir = executablePath(argv0).parent_path();
#ifdef __APPLE__
  return {dir / "../Resources/tools", dir / "../../../runtime",
          dir / "runtime"};
#elif defined(_WIN32)
  return {dir / "tools", dir / "runtime"};
#else
  return {dir / "../lib/wam/tools", dir / "runtime"};
#endif
}

std::vector<std::filesystem::path> packagedModelDirectories(const char* argv0) {
  const auto dir = executablePath(argv0).parent_path();
#ifdef __APPLE__
  return {dir / "../Resources/models", dir / "../../../runtime/models",
          dir / "runtime/models"};
#elif defined(_WIN32)
  return {dir / "models", dir / "runtime/models"};
#else
  return {dir / "../share/wam/models", dir / "runtime/models"};
#endif
}

std::vector<std::filesystem::path> standardToolDirectories() {
#ifdef _WIN32
  return {};
#else
  // Homebrew (Apple silicon), Homebrew (Intel) / manual installs, MacPorts.
  return {"/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin"};
#endif
}

std::vector<std::filesystem::path> pathDirectories() {
  std::vector<std::filesystem::path> directories;
#ifdef _WIN32
  const char separator = ';';
#else
  const char separator = ':';
#endif
  const char* raw = std::getenv("PATH");
  if (!raw) return directories;
  const std::string paths(raw);
  std::size_t start = 0;
  for (;;) {
    const auto end = paths.find(separator, start);
    const auto part = paths.substr(
        start, end == std::string::npos ? std::string::npos : end - start);
    if (!part.empty()) directories.emplace_back(part);
    if (end == std::string::npos) break;
    start = end + 1;
  }
  return directories;
}

// "whisper-cli.exe" -> "WAM_WHISPER_CLI". A stable, documented name derived
// from the tool itself rather than a separate hand-maintained table.
std::string overrideVariableName(const std::string& file) {
  std::string name = "WAM_";
  for (const char c : file) {
    if (c == '.') break;
    if (std::isalnum(static_cast<unsigned char>(c)))
      name += static_cast<char>(std::toupper(static_cast<unsigned char>(c)));
    else
      name += '_';
  }
  return name;
}

void appendOverride(std::vector<std::filesystem::path>& candidates,
                    const char* variable) {
  if (!variable) return;
  const char* value = std::getenv(variable);
  if (value && *value) candidates.emplace_back(value);
}

void appendNormalized(std::vector<std::filesystem::path>& candidates,
                      const std::filesystem::path& candidate) {
  std::error_code error;
  auto normalized = std::filesystem::weakly_canonical(candidate, error);
  candidates.push_back(error ? candidate.lexically_normal()
                             : std::move(normalized));
}

}  // namespace

ToolSearch executableSearch(const char* tool, const char* file,
                            const char* argv0) {
  ToolSearch search;
  search.tool = tool ? tool : "";
  search.file = file ? file : "";
  if (search.file.empty()) return search;

  for (const auto& directory : packagedToolDirectories(argv0))
    appendNormalized(search.candidates, directory / search.file);
  const auto variable = overrideVariableName(search.file);
  appendOverride(search.candidates, variable.c_str());
  for (const auto& directory : standardToolDirectories())
    search.candidates.push_back(directory / search.file);
  for (const auto& directory : pathDirectories())
    search.candidates.push_back(directory / search.file);
  return search;
}

ToolSearch captionModelSearch(const char* argv0) {
  ToolSearch search;
  search.tool = "The Whisper caption model";
  search.file = "ggml-base.en.bin";
  for (const auto& directory : packagedModelDirectories(argv0))
    appendNormalized(search.candidates, directory / search.file);
  // A model is data, not a program: there is no standard install prefix and
  // PATH is meaningless for it, so the explicit override is the last word.
  appendOverride(search.candidates, "WAM_WHISPER_MODEL");
  return search;
}

std::filesystem::path resolveTool(const ToolSearch& search,
                                  const ToolProbe& probe) {
  if (!probe) return {};
  for (const auto& candidate : search.candidates) {
    if (probe(candidate)) return candidate;
  }
  return {};
}

bool toolIsExecutable(const std::filesystem::path& path) {
  std::error_code error;
  if (!std::filesystem::is_regular_file(path, error) || error) return false;
#ifdef _WIN32
  return true;
#else
  return access(path.c_str(), X_OK) == 0;
#endif
}

bool toolFileExists(const std::filesystem::path& path) {
  std::error_code error;
  if (!std::filesystem::is_regular_file(path, error) || error) return false;
  const auto size = std::filesystem::file_size(path, error);
  return !error && size > 0;
}

std::string toolSearchFailure(const ToolSearch& search) {
  std::ostringstream message;
  message << (search.tool.empty() ? "The tool" : search.tool)
          << " was not found. WAM looked for \"" << search.file << "\" in:";
  if (search.candidates.empty()) {
    message << " no known location.";
    return message.str();
  }
  for (const auto& candidate : search.candidates)
    message << "\n  " << candidate.string();
  return message.str();
}

std::filesystem::path findBundledTool(const char* executable, const char* argv0) {
  const auto search = executableSearch(executable, executable, argv0);
  auto resolved = resolveTool(search, toolIsExecutable);
  // The bare name preserves this function's historical non-empty contract.
  // Callers that need to explain a miss run the search themselves.
  return resolved.empty() ? std::filesystem::path(executable ? executable : "")
                          : resolved;
}

std::filesystem::path defaultWhisperModel(const char* argv0) {
  const auto search = captionModelSearch(argv0);
  auto resolved = resolveTool(search, toolFileExists);
  if (!resolved.empty()) return resolved;
  return search.candidates.empty() ? std::filesystem::path()
                                   : search.candidates.front();
}

}  // namespace wam
