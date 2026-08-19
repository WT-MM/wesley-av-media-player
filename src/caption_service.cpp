#include "caption_service.hpp"

#include "jobs.hpp"

#include <algorithm>
#include <array>
#include <atomic>
#include <cctype>
#include <cerrno>
#include <chrono>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <iomanip>
#include <optional>
#include <random>
#include <sstream>
#include <system_error>
#include <utility>
#include <vector>

#ifdef _WIN32
#ifndef NOMINMAX
#define NOMINMAX
#endif
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#else
#include <fcntl.h>
#include <signal.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>
#endif

namespace wam {
namespace {

using namespace std::chrono_literals;
namespace fs = std::filesystem;

std::string pathArgument(const fs::path &path) {
#ifdef _WIN32
  const auto utf8 = path.u8string();
  return std::string(reinterpret_cast<const char *>(utf8.data()), utf8.size());
#else
  return path.string();
#endif
}

struct ProcessResult {
  bool launched = false;
  bool cancelled = false;
  int exit_code = -1;
  std::string output;
  std::string launch_error;
};

void appendProcessOutput(std::string &destination, const char *bytes,
                         std::size_t count) {
  constexpr std::size_t kMaxDiagnosticBytes = 64 * 1024;
  destination.append(bytes, count);
  if (destination.size() > kMaxDiagnosticBytes) {
    destination.erase(0, destination.size() - kMaxDiagnosticBytes);
  }
}

std::string trimDiagnostic(std::string text) {
  while (!text.empty() &&
         std::isspace(static_cast<unsigned char>(text.front())))
    text.erase(text.begin());
  while (!text.empty() && std::isspace(static_cast<unsigned char>(text.back())))
    text.pop_back();
  constexpr std::size_t kUsefulTail = 1200;
  if (text.size() > kUsefulTail)
    text = "..." + text.substr(text.size() - kUsefulTail);
  return text;
}

std::string processFailure(const char *tool, const ProcessResult &result) {
  std::ostringstream message;
  if (!result.launched) {
    message << "Could not start " << tool;
    if (!result.launch_error.empty())
      message << ": " << result.launch_error;
    return message.str();
  }
  message << tool << " exited with code " << result.exit_code;
  const auto diagnostic = trimDiagnostic(result.output);
  if (!diagnostic.empty())
    message << ". " << diagnostic;
  return message.str();
}

std::vector<std::string> audioArguments(const fs::path &input,
                                        const fs::path &wav) {
  return {"-hide_banner",
          "-loglevel",
          "error",
          "-nostdin",
          "-y",
          "-i",
          pathArgument(input),
          "-map",
          "0:a:0",
          "-vn",
          "-ar",
          "16000",
          "-ac",
          "1",
          "-c:a",
          "pcm_s16le",
          pathArgument(wav)};
}

unsigned effectiveThreadCount(const CaptionOptions &options) {
  if (options.threads != 0)
    return std::clamp(options.threads, 1u, 64u);
  const auto available = std::thread::hardware_concurrency();
  return std::clamp(available == 0 ? 4u : available, 1u, 16u);
}

std::vector<std::string> whisperArguments(const fs::path &model,
                                          const fs::path &wav,
                                          const fs::path &output_base,
                                          const CaptionOptions &options) {
  std::vector<std::string> args{"-m",
                                pathArgument(model),
                                "-f",
                                pathArgument(wav),
                                "-t",
                                std::to_string(effectiveThreadCount(options)),
                                "-osrt",
                                "-of",
                                pathArgument(output_base)};
  if (!options.use_gpu)
    args.emplace_back("-ng");
  if (!options.language.empty()) {
    args.emplace_back("-l");
    args.emplace_back(options.language);
  }
  if (options.translate_to_english)
    args.emplace_back("-tr");
  return args;
}

std::string displayCommand(const fs::path &executable,
                           const std::vector<std::string> &arguments) {
  std::ostringstream command;
  command << quoteArg(pathArgument(executable));
  for (const auto &argument : arguments)
    command << ' ' << quoteArg(argument);
  return command.str();
}

#ifdef _WIN32
std::wstring quoteWindowsArgument(const std::wstring &value) {
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

std::wstring utf8ToWide(const std::string &value) {
  if (value.empty())
    return {};
  const int size =
      MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
                          static_cast<int>(value.size()), nullptr, 0);
  if (size <= 0)
    return std::wstring(value.begin(), value.end());
  std::wstring wide(static_cast<std::size_t>(size), L'\0');
  MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
                      static_cast<int>(value.size()), wide.data(), size);
  return wide;
}

std::wstring windowsCommandLine(const fs::path &executable,
                                const std::vector<std::string> &arguments) {
  std::wstring line = quoteWindowsArgument(executable.wstring());
  for (const auto &argument : arguments) {
    line.push_back(L' ');
    line += quoteWindowsArgument(utf8ToWide(argument));
  }
  return line;
}

void drainWindowsPipe(HANDLE pipe, std::string &output) {
  std::array<char, 4096> buffer{};
  for (;;) {
    DWORD available = 0;
    if (!PeekNamedPipe(pipe, nullptr, 0, nullptr, &available, nullptr) ||
        available == 0)
      return;
    DWORD read = 0;
    const DWORD wanted =
        std::min<DWORD>(available, static_cast<DWORD>(buffer.size()));
    if (!ReadFile(pipe, buffer.data(), wanted, &read, nullptr) || read == 0)
      return;
    appendProcessOutput(output, buffer.data(), read);
  }
}

ProcessResult runProcess(const fs::path &executable,
                         const std::vector<std::string> &arguments,
                         const detail::CancellationFlag &cancellation) {
  ProcessResult result;
  if (cancellation.requested()) {
    result.cancelled = true;
    return result;
  }

  SECURITY_ATTRIBUTES security{};
  security.nLength = sizeof(security);
  security.bInheritHandle = TRUE;
  HANDLE output_read = nullptr;
  HANDLE output_write = nullptr;
  if (!CreatePipe(&output_read, &output_write, &security, 0)) {
    result.launch_error = "could not create output pipe";
    return result;
  }
  SetHandleInformation(output_read, HANDLE_FLAG_INHERIT, 0);

  HANDLE null_input =
      CreateFileW(L"NUL", GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE,
                  &security, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);

  STARTUPINFOW startup{};
  startup.cb = sizeof(startup);
  startup.dwFlags = STARTF_USESTDHANDLES;
  startup.hStdOutput = output_write;
  startup.hStdError = output_write;
  startup.hStdInput = null_input;
  PROCESS_INFORMATION process{};
  auto command = windowsCommandLine(executable, arguments);
  std::vector<wchar_t> mutable_command(command.begin(), command.end());
  mutable_command.push_back(L'\0');

  const DWORD flags = CREATE_NO_WINDOW | CREATE_SUSPENDED;
  const BOOL created = CreateProcessW(
      executable.wstring().c_str(), mutable_command.data(), nullptr, nullptr,
      TRUE, flags, nullptr, nullptr, &startup, &process);
  CloseHandle(output_write);
  if (null_input != INVALID_HANDLE_VALUE)
    CloseHandle(null_input);
  if (!created) {
    result.launch_error = "Windows error " + std::to_string(GetLastError());
    CloseHandle(output_read);
    return result;
  }
  result.launched = true;

  HANDLE job = CreateJobObjectW(nullptr, nullptr);
  bool process_in_job = false;
  if (job) {
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits{};
    limits.BasicLimitInformation.LimitFlags =
        JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    if (SetInformationJobObject(job, JobObjectExtendedLimitInformation, &limits,
                                sizeof(limits)) &&
        AssignProcessToJobObject(job, process.hProcess)) {
      process_in_job = true;
    }
  }
  ResumeThread(process.hThread);
  CloseHandle(process.hThread);

  bool termination_sent = false;
  for (;;) {
    drainWindowsPipe(output_read, result.output);
    const DWORD wait = WaitForSingleObject(process.hProcess, 25);
    if (wait == WAIT_OBJECT_0)
      break;
    if (wait == WAIT_FAILED) {
      TerminateProcess(process.hProcess, GetLastError());
      WaitForSingleObject(process.hProcess, INFINITE);
      break;
    }
    if (cancellation.requested() && !termination_sent) {
      result.cancelled = true;
      termination_sent = true;
      if (process_in_job)
        TerminateJobObject(job, ERROR_CANCELLED);
      else
        TerminateProcess(process.hProcess, ERROR_CANCELLED);
    }
  }
  drainWindowsPipe(output_read, result.output);
  DWORD exit_code = static_cast<DWORD>(-1);
  GetExitCodeProcess(process.hProcess, &exit_code);
  result.exit_code = static_cast<int>(exit_code);
  CloseHandle(process.hProcess);
  CloseHandle(output_read);
  if (job)
    CloseHandle(job);
  return result;
}

#else

constexpr auto kCaptionProcessPollInterval = 20ms;
constexpr auto kCaptionGracefulShutdownTimeout = 500ms;

void drainPosixPipe(int pipe, std::string &output) {
  std::array<char, 4096> buffer{};
  for (;;) {
    const ssize_t count = read(pipe, buffer.data(), buffer.size());
    if (count > 0) {
      appendProcessOutput(output, buffer.data(),
                          static_cast<std::size_t>(count));
      continue;
    }
    if (count < 0 && errno == EINTR)
      continue;
    return;
  }
}

bool establishCaptionProcessGroup(pid_t child, int *error) {
  if (setpgid(child, child) == 0)
    return true;

  const int setup_error = errno ? errno : 1;
  // The child can reach exec before the parent's setpgid. Only signal a
  // negative PID after proving the child owns that process-group identity.
  if (setup_error == EACCES && getpgid(child) == child)
    return true;
  if (error)
    *error = setup_error;
  return false;
}

void signalVerifiedCaptionProcessGroup(pid_t group, int signal) {
  int result = 0;
  do {
    result = kill(-group, signal);
  } while (result != 0 && errno == EINTR);
}

bool reapCaptionChild(pid_t child, int *status, int *error) {
  pid_t waited = -1;
  do {
    waited = waitpid(child, status, 0);
  } while (waited < 0 && errno == EINTR);
  if (waited == child)
    return true;
  if (error)
    *error = errno ? errno : 1;
  return false;
}

enum class CaptionChildObservation { Running, Exited, Error };

CaptionChildObservation observeCaptionChild(pid_t child, int *error) {
  siginfo_t information{};
  int observed = -1;
  do {
    observed = waitid(P_PID, static_cast<id_t>(child), &information,
                      WEXITED | WNOHANG | WNOWAIT);
  } while (observed != 0 && errno == EINTR);
  if (observed != 0) {
    if (error)
      *error = errno ? errno : 1;
    return CaptionChildObservation::Error;
  }
  return information.si_pid == child ? CaptionChildObservation::Exited
                                     : CaptionChildObservation::Running;
}

void terminateUnisolatedCaptionChild(pid_t child) {
  int killed = 0;
  do {
    killed = kill(child, SIGKILL);
  } while (killed != 0 && errno == EINTR);
  int ignored_status = 0;
  int ignored_error = 0;
  reapCaptionChild(child, &ignored_status, &ignored_error);
}

ProcessResult runProcess(const fs::path &executable,
                         const std::vector<std::string> &arguments,
                         const detail::CancellationFlag &cancellation) {
  ProcessResult result;
  if (cancellation.requested()) {
    result.cancelled = true;
    return result;
  }

  int output_pipe[2];
  if (pipe(output_pipe) != 0) {
    result.launch_error = std::strerror(errno);
    return result;
  }
  const int existing_flags = fcntl(output_pipe[0], F_GETFL, 0);
  if (existing_flags < 0 ||
      fcntl(output_pipe[0], F_SETFL, existing_flags | O_NONBLOCK) != 0) {
    result.launch_error =
        std::string("could not make the caption output pipe nonblocking: ") +
        std::strerror(errno);
    close(output_pipe[0]);
    close(output_pipe[1]);
    return result;
  }

  std::vector<std::string> storage;
  storage.reserve(arguments.size() + 1);
  storage.push_back(executable.string());
  storage.insert(storage.end(), arguments.begin(), arguments.end());
  std::vector<char *> argv;
  argv.reserve(storage.size() + 1);
  for (auto &item : storage)
    argv.push_back(item.data());
  argv.push_back(nullptr);

  const pid_t pid = fork();
  if (pid < 0) {
    result.launch_error = std::strerror(errno);
    close(output_pipe[0]);
    close(output_pipe[1]);
    return result;
  }
  if (pid == 0) {
    if (setpgid(0, 0) != 0)
      _exit(125);
    dup2(output_pipe[1], STDOUT_FILENO);
    dup2(output_pipe[1], STDERR_FILENO);
    close(output_pipe[0]);
    close(output_pipe[1]);
    execv(executable.c_str(), argv.data());
    const int failure = errno;
    const char prefix[] = "Could not execute caption tool: ";
    write(STDERR_FILENO, prefix, sizeof(prefix) - 1);
    const char *detail = std::strerror(failure);
    write(STDERR_FILENO, detail, std::strlen(detail));
    write(STDERR_FILENO, "\n", 1);
    _exit(127);
  }

  result.launched = true;
  close(output_pipe[1]);
  int setup_error = 0;
  if (!establishCaptionProcessGroup(pid, &setup_error)) {
    int observation_error = 0;
    const auto observation =
        observeCaptionChild(pid, &observation_error);
    int status = 0;
    int reap_error = 0;
    const bool exited = observation == CaptionChildObservation::Exited &&
                        reapCaptionChild(pid, &status, &reap_error);
    if (observation == CaptionChildObservation::Running ||
        (observation == CaptionChildObservation::Error &&
         observation_error != ECHILD))
      terminateUnisolatedCaptionChild(pid);
    drainPosixPipe(output_pipe[0], result.output);
    close(output_pipe[0]);
    result.cancelled = cancellation.requested();
    if (exited) {
      if (WIFEXITED(status))
        result.exit_code = WEXITSTATUS(status);
      else if (WIFSIGNALED(status))
        result.exit_code = 128 + WTERMSIG(status);
      if (result.cancelled)
        result.exit_code = 130;
    } else {
      result.launched = false;
      result.exit_code = result.cancelled ? 130 : setup_error;
      result.launch_error =
          std::string("could not establish an isolated process group: ") +
          std::strerror(setup_error);
    }
    return result;
  }

  bool termination_sent = false;
  auto force_at = std::chrono::steady_clock::time_point::max();
  int status = 0;
  bool status_valid = false;
  for (;;) {
    drainPosixPipe(output_pipe[0], result.output);
    if (!termination_sent) {
      if (cancellation.requested()) {
        result.cancelled = true;
        termination_sent = true;
        force_at = std::chrono::steady_clock::now() +
                   kCaptionGracefulShutdownTimeout;
        signalVerifiedCaptionProcessGroup(pid, SIGTERM);
      } else {
        int observation_error = 0;
        const auto observation =
            observeCaptionChild(pid, &observation_error);
        if (observation == CaptionChildObservation::Error) {
          // After ECHILD the PID may already be reusable. Do not direct a
          // process-group signal at that numeric identity.
          if (observation_error != ECHILD) {
            signalVerifiedCaptionProcessGroup(pid, SIGKILL);
            int ignored_error = 0;
            status_valid = reapCaptionChild(pid, &status, &ignored_error);
          }
          if (!status_valid)
            result.exit_code = observation_error ? observation_error : 1;
          break;
        }
        if (observation == CaptionChildObservation::Exited) {
          // waitid(WNOWAIT) leaves the leader unreaped. Re-check cancellation
          // before choosing between a normal reap and whole-group cleanup.
          if (cancellation.requested()) {
            result.cancelled = true;
            termination_sent = true;
            force_at = std::chrono::steady_clock::now() +
                       kCaptionGracefulShutdownTimeout;
            signalVerifiedCaptionProcessGroup(pid, SIGTERM);
          } else {
            int reap_error = 0;
            status_valid = reapCaptionChild(pid, &status, &reap_error);
            if (!status_valid)
              result.exit_code = reap_error ? reap_error : 1;
            break;
          }
        }
      }
    }

    if (termination_sent &&
        std::chrono::steady_clock::now() >= force_at) {
      // Keep the leader waitable until this final group signal. Its unreaped
      // PID prevents the process-group number from being reused underneath us.
      signalVerifiedCaptionProcessGroup(pid, SIGKILL);
      int reap_error = 0;
      status_valid = reapCaptionChild(pid, &status, &reap_error);
      if (!status_valid)
        result.exit_code = 130;
      break;
    }
    std::this_thread::sleep_for(kCaptionProcessPollInterval);
  }
  drainPosixPipe(output_pipe[0], result.output);
  close(output_pipe[0]);
  if (status_valid && WIFEXITED(status))
    result.exit_code = WEXITSTATUS(status);
  else if (status_valid && WIFSIGNALED(status))
    result.exit_code = 128 + WTERMSIG(status);
  return result;
}

#endif

struct ResolvedTool {
  fs::path path;
  // Set only when `path` is empty: what was looked for and where.
  std::string failure;
};

// A caller-supplied path (a test fixture, or a future explicit setting) is
// honoured verbatim. A bare tool name goes through the shared ordered search
// in jobs.cpp, because PATH alone cannot see a Homebrew/MacPorts install from
// a GUI launch.
ResolvedTool resolveCaptionTool(const char *label, const fs::path &requested) {
  if (requested.empty())
    return {{}, std::string(label) + " was not configured."};
  if (requested.has_parent_path() || requested.is_absolute()) {
    if (toolIsExecutable(requested)) {
      std::error_code error;
      auto canonical = fs::weakly_canonical(requested, error);
      return {error ? requested : canonical, {}};
    }
    return {{}, std::string(label) + " was not found or is not executable: " +
                    requested.string()};
  }

  const auto name = requested.string();
  const auto search = executableSearch(label, name.c_str(), nullptr);
  auto resolved = resolveTool(search, toolIsExecutable);
  if (resolved.empty())
    return {{}, toolSearchFailure(search)};
  return {std::move(resolved), {}};
}

std::optional<std::string> validateNonEmptyFile(const fs::path &file,
                                                const char *label) {
  std::error_code error;
  if (!fs::exists(file, error))
    return std::string(label) + " was not found: " + file.string();
  if (!fs::is_regular_file(file, error))
    return std::string(label) + " is not a file: " + file.string();
#ifdef __APPLE__
  struct stat information{};
  if (::stat(file.c_str(), &information) == 0 &&
      (information.st_flags & SF_DATALESS) != 0) {
    return std::string(label) +
           " is stored in the cloud but is not downloaded. Download it in "
           "Finder, then try captioning again: " +
           file.string();
  }
#endif
  const auto size = fs::file_size(file, error);
  if (error || size == 0)
    return std::string(label) + " is empty or unreadable: " + file.string();
  return std::nullopt;
}

fs::path absolutePath(const fs::path &path) {
  std::error_code error;
  const auto absolute = fs::absolute(path, error);
  return error ? path : absolute.lexically_normal();
}

std::string lowerExtension(fs::path path) {
  std::string extension = path.extension().string();
  std::transform(
      extension.begin(), extension.end(), extension.begin(),
      [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
  return extension;
}

bool pathsReferToSameFile(const fs::path &first, const fs::path &second) {
  std::error_code error;
  if (fs::exists(first, error) && fs::exists(second, error)) {
    const bool equivalent = fs::equivalent(first, second, error);
    if (!error && equivalent)
      return true;
  }
  return absolutePath(first) == absolutePath(second);
}

std::uint64_t processIdentifier() {
#ifdef _WIN32
  return GetCurrentProcessId();
#else
  return static_cast<std::uint64_t>(getpid());
#endif
}

bool reserveFileExclusively(const fs::path &path) {
#ifdef _WIN32
  const HANDLE file = CreateFileW(path.c_str(), GENERIC_WRITE, 0, nullptr,
                                  CREATE_NEW, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE)
    return false;
  CloseHandle(file);
  return true;
#else
  const int file = open(path.c_str(), O_CREAT | O_EXCL | O_WRONLY, 0600);
  if (file < 0)
    return false;
  close(file);
  return true;
#endif
}

std::optional<fs::path> reserveUniqueFile(const fs::path &directory,
                                          const char *suffix) {
  static std::atomic<std::uint64_t> sequence{0};
  std::random_device random;
  for (int attempt = 0; attempt < 100; ++attempt) {
    const auto count = sequence.fetch_add(1, std::memory_order_relaxed);
    const auto stamp = static_cast<std::uint64_t>(
        std::chrono::steady_clock::now().time_since_epoch().count());
    const auto entropy =
        (static_cast<std::uint64_t>(random()) << 32) ^ random();
    std::ostringstream name;
    name << "wam-caption-" << processIdentifier() << '-' << std::hex
         << (stamp ^ entropy ^ count) << suffix;
    const fs::path candidate = directory / name.str();
    if (reserveFileExclusively(candidate))
      return candidate;
  }
  return std::nullopt;
}

class RemoveFileOnExit {
public:
  explicit RemoveFileOnExit(fs::path path) : path_(std::move(path)) {}
  ~RemoveFileOnExit() {
    std::error_code ignored;
    if (!path_.empty())
      fs::remove(path_, ignored);
  }
  RemoveFileOnExit(const RemoveFileOnExit &) = delete;
  RemoveFileOnExit &operator=(const RemoveFileOnExit &) = delete;

private:
  fs::path path_;
};

bool fileHasVisibleContent(const fs::path &file) {
  std::error_code error;
  if (!fs::is_regular_file(file, error) || fs::file_size(file, error) == 0 ||
      error)
    return false;
  std::ifstream stream(file, std::ios::binary);
  std::array<char, 4096> buffer{};
  while (stream) {
    stream.read(buffer.data(), static_cast<std::streamsize>(buffer.size()));
    const auto count = stream.gcount();
    for (std::streamsize i = 0; i < count; ++i) {
      if (!std::isspace(static_cast<unsigned char>(buffer[i])))
        return true;
    }
  }
  return false;
}

bool commitCaptionFile(const fs::path &staging, const fs::path &destination,
                       bool overwrite, std::string *error) {
  if (error)
    error->clear();
  if (!fileHasVisibleContent(staging)) {
    if (error)
      *error = "The generated caption staging file is empty or unreadable.";
    return false;
  }

  std::error_code path_error;
  const auto staging_parent =
      fs::weakly_canonical(staging.parent_path(), path_error);
  if (path_error) {
    if (error)
      *error = path_error.message();
    return false;
  }
  path_error.clear();
  const auto absolute_destination = fs::absolute(destination, path_error);
  if (path_error) {
    if (error)
      *error = path_error.message();
    return false;
  }
  path_error.clear();
  const auto destination_parent =
      fs::weakly_canonical(absolute_destination.parent_path(), path_error);
  if (path_error || staging_parent != destination_parent) {
    if (error) {
      *error = path_error
                   ? path_error.message()
                   : "Caption staging and destination must share a folder.";
    }
    return false;
  }

#ifdef _WIN32
  const DWORD flags =
      MOVEFILE_WRITE_THROUGH | (overwrite ? MOVEFILE_REPLACE_EXISTING : 0);
  if (!MoveFileExW(staging.c_str(), absolute_destination.c_str(), flags)) {
    if (error) {
      *error = std::error_code(static_cast<int>(GetLastError()),
                               std::system_category())
                   .message();
    }
    return false;
  }
#else
  if (overwrite) {
    // staging lives beside the destination, so rename is a single atomic
    // replacement: observers see either the complete old SRT or the complete
    // new one, never a partially copied file.
    fs::rename(staging, absolute_destination, path_error);
    if (path_error) {
      if (error)
        *error = path_error.message();
      return false;
    }
  } else {
    // link() is an atomic create-if-absent operation. It preserves the
    // no-overwrite promise even if another process creates the destination
    // between validation and commit.
    if (::link(staging.c_str(), absolute_destination.c_str()) != 0) {
      if (error)
        *error = std::error_code(errno, std::generic_category()).message();
      return false;
    }
    // The destination now references the complete staged inode. Failure to
    // remove the temporary name is harmless; RemoveFileOnExit retries it.
    (void)::unlink(staging.c_str());
  }
#endif
  return true;
}

} // namespace

const char *captionStageName(CaptionStage stage) noexcept {
  switch (stage) {
  case CaptionStage::Idle:
    return "Idle";
  case CaptionStage::Validating:
    return "Validating";
  case CaptionStage::ExtractingAudio:
    return "Preparing audio";
  case CaptionStage::Transcribing:
    return "Transcribing";
  case CaptionStage::VerifyingOutput:
    return "Saving captions";
  case CaptionStage::Completed:
    return "Complete";
  case CaptionStage::Failed:
    return "Failed";
  case CaptionStage::Cancelled:
    return "Cancelled";
  }
  return "Unknown";
}

CaptionTools findCaptionTools(const char *argv0) {
  CaptionTools tools;
#ifdef _WIN32
  tools.ffmpeg = findBundledTool("ffmpeg.exe", argv0);
  tools.whisper = findBundledTool("whisper-cli.exe", argv0);
#else
  tools.ffmpeg = findBundledTool("ffmpeg", argv0);
  tools.whisper = findBundledTool("whisper-cli", argv0);
#endif
  tools.model = defaultWhisperModel(argv0);
  return tools;
}

std::string buildCaptionAudioCommand(const fs::path &ffmpeg,
                                     const fs::path &input,
                                     const fs::path &wav) {
  return displayCommand(ffmpeg, audioArguments(input, wav));
}

std::string buildCaptionWhisperCommand(const fs::path &whisper,
                                       const fs::path &model,
                                       const fs::path &wav,
                                       const fs::path &output_base,
                                       const CaptionOptions &options) {
  return displayCommand(whisper,
                        whisperArguments(model, wav, output_base, options));
}

CaptionService::~CaptionService() {
  cancel();
  wait();
}

bool CaptionService::start(CaptionRequest request) {
  std::lock_guard worker_lock(worker_mutex_);
  {
    std::lock_guard status_lock(status_mutex_);
    if (status_.running)
      return false;
  }
  if (worker_.joinable())
    worker_.join();
  cancellation_.reset();
  {
    std::lock_guard status_lock(status_mutex_);
    status_ = {};
    status_.stage = CaptionStage::Validating;
    status_.progress = 0.02f;
    status_.running = true;
    status_.message = "Checking media, model, and local caption tools…";
    status_.output_srt = request.output_srt;
  }
  try {
    worker_ = std::thread([this, request = std::move(request)]() mutable {
      run(std::move(request), cancellation_);
    });
  } catch (const std::exception &exception) {
    fail(std::string("Could not start caption worker: ") + exception.what());
    return false;
  }
  return true;
}

void CaptionService::cancel() noexcept {
  // Cancellation must remain available even while another caller is joining
  // the worker. The atomic request is the functional operation; the status
  // message is best-effort and must never make this noexcept method throw.
  cancellation_.request();
  try {
    std::lock_guard status_lock(status_mutex_);
    if (!status_.running)
      return;
    status_.message = "Cancelling caption generation…";
  } catch (...) {
    // The cancellation flag is already published. A diagnostic status update
    // is optional and must not violate this method's no-throw contract.
  }
}

void CaptionService::wait() {
  std::lock_guard worker_lock(worker_mutex_);
  if (worker_.joinable())
    worker_.join();
}

CaptionStatus CaptionService::status() const {
  std::lock_guard lock(status_mutex_);
  return status_;
}

bool CaptionService::running() const { return status().running; }
bool CaptionService::finished() const { return status().finished; }
bool CaptionService::succeeded() const { return status().succeeded; }

void CaptionService::update(CaptionStage stage, float progress,
                            std::string message) {
  std::lock_guard lock(status_mutex_);
  status_.stage = stage;
  status_.progress = std::clamp(progress, 0.0f, 1.0f);
  status_.message = std::move(message);
}

void CaptionService::complete(const fs::path &output) {
  std::lock_guard lock(status_mutex_);
  status_.stage = CaptionStage::Completed;
  status_.progress = 1.0f;
  status_.running = false;
  status_.finished = true;
  status_.succeeded = true;
  status_.cancelled = false;
  status_.message = "Captions are ready.";
  status_.error.clear();
  status_.output_srt = output;
}

void CaptionService::fail(std::string error) {
  std::lock_guard lock(status_mutex_);
  status_.stage = CaptionStage::Failed;
  status_.running = false;
  status_.finished = true;
  status_.succeeded = false;
  status_.cancelled = false;
  status_.message = "Caption generation failed.";
  status_.error = std::move(error);
}

void CaptionService::cancelled() {
  std::lock_guard lock(status_mutex_);
  status_.stage = CaptionStage::Cancelled;
  status_.running = false;
  status_.finished = true;
  status_.succeeded = false;
  status_.cancelled = true;
  status_.message = "Caption generation was cancelled.";
  status_.error.clear();
}

void CaptionService::run(
    CaptionRequest request,
    const detail::CancellationFlag &cancellation) noexcept {
  try {
    auto stopIfRequested = [&]() {
      if (!cancellation.requested())
        return false;
      cancelled();
      return true;
    };

    if (request.input.empty()) {
      fail("Choose an input media file first.");
      return;
    }
    request.input = absolutePath(request.input);
    if (const auto error = validateNonEmptyFile(request.input, "Input media")) {
      fail(*error);
      return;
    }
    if (stopIfRequested())
      return;

    if (request.output_srt.empty()) {
      fail("Choose where to save the captions.");
      return;
    }
    if (lowerExtension(request.output_srt) != ".srt")
      request.output_srt += ".srt";
    request.output_srt = absolutePath(request.output_srt);
    {
      std::lock_guard lock(status_mutex_);
      status_.output_srt = request.output_srt;
    }
    const fs::path output_directory = request.output_srt.parent_path();
    std::error_code path_error;
    if (!fs::is_directory(output_directory, path_error)) {
      fail("Caption output folder does not exist: " +
           output_directory.string());
      return;
    }
    if (fs::is_directory(request.output_srt, path_error)) {
      fail("Caption output path is a folder: " + request.output_srt.string());
      return;
    }
    if (!request.options.overwrite &&
        fs::exists(request.output_srt, path_error)) {
      fail("Caption output already exists: " + request.output_srt.string());
      return;
    }
    if (pathsReferToSameFile(request.input, request.output_srt)) {
      fail("Caption output cannot overwrite the input media file.");
      return;
    }

    const auto ffmpeg = resolveCaptionTool("FFmpeg", request.tools.ffmpeg);
    if (ffmpeg.path.empty()) {
      fail(ffmpeg.failure);
      return;
    }
    const auto whisper =
        resolveCaptionTool("whisper.cpp", request.tools.whisper);
    if (whisper.path.empty()) {
      fail(whisper.failure);
      return;
    }
    request.tools.ffmpeg = ffmpeg.path;
    request.tools.whisper = whisper.path;
    if (request.tools.model.empty()) {
      fail(toolSearchFailure(captionModelSearch(nullptr)));
      return;
    }
    request.tools.model = absolutePath(request.tools.model);
    if (const auto error =
            validateNonEmptyFile(request.tools.model, "Whisper model")) {
      // The packaged/development runtime is the normal source of this file, so
      // a miss should say where WAM looked rather than only naming one path.
      fail(fs::exists(request.tools.model)
               ? *error
               : toolSearchFailure(captionModelSearch(nullptr)));
      return;
    }
    if (pathsReferToSameFile(request.tools.model, request.output_srt)) {
      fail("Caption output cannot overwrite the Whisper model.");
      return;
    }
    if (stopIfRequested())
      return;

    std::error_code temp_error;
    const fs::path temp_directory = fs::temp_directory_path(temp_error);
    if (temp_error || !fs::is_directory(temp_directory, temp_error)) {
      fail("The system temporary folder is unavailable.");
      return;
    }
    const auto wav = reserveUniqueFile(temp_directory, ".wav");
    if (!wav) {
      fail("Could not reserve a temporary audio file.");
      return;
    }
    RemoveFileOnExit remove_wav(*wav);

    update(CaptionStage::ExtractingAudio, 0.12f,
           "Preparing clean speech audio with FFmpeg…");
    const auto extraction = runProcess(
        request.tools.ffmpeg, audioArguments(request.input, *wav),
        cancellation);
    if (extraction.cancelled) {
      cancelled();
      return;
    }
    if (stopIfRequested())
      return;
    if (!extraction.launched || extraction.exit_code != 0) {
      fail(processFailure("FFmpeg", extraction));
      return;
    }
    if (!fileHasVisibleContent(*wav)) {
      fail(
          "FFmpeg finished but did not produce usable audio. The media may not "
          "contain an audio track.");
      return;
    }

    const auto staged_srt = reserveUniqueFile(output_directory, ".srt");
    if (!staged_srt) {
      fail("Could not create a temporary caption file in: " +
           output_directory.string());
      return;
    }
    RemoveFileOnExit remove_staged_srt(*staged_srt);
    fs::path output_base = *staged_srt;
    output_base.replace_extension();

    update(CaptionStage::Transcribing, 0.35f,
           "Listening and generating captions locally…");
    const auto transcription =
        runProcess(request.tools.whisper,
                   whisperArguments(request.tools.model, *wav, output_base,
                                    request.options),
                   cancellation);
    if (transcription.cancelled) {
      cancelled();
      return;
    }
    if (stopIfRequested())
      return;

    update(CaptionStage::VerifyingOutput, 0.92f,
           "Checking and saving the generated captions…");
    const bool usable_srt = fileHasVisibleContent(*staged_srt);
    if (!transcription.launched || transcription.exit_code != 0) {
      fail(processFailure("whisper.cpp", transcription));
      return;
    }
    if (!usable_srt) {
      fail("whisper.cpp reported success but did not create a non-empty SRT. "
           "No speech may have been detected, or this model may be "
           "incompatible.");
      return;
    }
    if (stopIfRequested())
      return;

    std::string commit_error;
    if (!commitCaptionFile(*staged_srt, request.output_srt,
                           request.options.overwrite, &commit_error)) {
      fail("Could not safely save captions to " + request.output_srt.string() +
           ": " + commit_error);
      return;
    }
    if (!fileHasVisibleContent(request.output_srt)) {
      fail("The caption file could not be verified after saving: " +
           request.output_srt.string());
      return;
    }
    complete(request.output_srt);
  } catch (const fs::filesystem_error &exception) {
    fail(std::string("Caption file error: ") + exception.what());
  } catch (const std::exception &exception) {
    fail(std::string("Caption generation error: ") + exception.what());
  } catch (...) {
    fail("Caption generation failed unexpectedly.");
  }
}

} // namespace wam
