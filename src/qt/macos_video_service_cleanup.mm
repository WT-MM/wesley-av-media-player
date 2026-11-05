#include "macos_video_service_cleanup.hpp"
#include "macos_video_service_identity.hpp"

#include <libproc.h>
#include <sys/proc_info.h>
#include <sys/wait.h>
#include <poll.h>
#include <spawn.h>
#include <unistd.h>
#include <signal.h>
#include <fcntl.h>

#include <cerrno>
#include <climits>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <thread>

extern char **environ;
namespace wam::qt {
namespace {
// launchctl's pid domain supplies the client association missing from ppid
// (XPC helpers have launchd as their parent). Query only our own domain; never
// enumerate services or infer ownership from a process name or timestamp alone.
std::string ownServiceDescription() {
  int pipefd[2];
  if (pipe(pipefd) != 0) return {};
  if (fcntl(pipefd[0], F_SETFD, FD_CLOEXEC) != 0 ||
      fcntl(pipefd[1], F_SETFD, FD_CLOEXEC) != 0 ||
      fcntl(pipefd[0], F_SETFL, O_NONBLOCK) != 0) {
    close(pipefd[0]); close(pipefd[1]); return {};
  }
  const std::string target = "pid/" + std::to_string(getpid()) + "/" + std::string(videoServiceName);
  posix_spawn_file_actions_t actions;
  if (posix_spawn_file_actions_init(&actions) != 0) {
    close(pipefd[0]); close(pipefd[1]); return {};
  }
  const bool configured =
      posix_spawn_file_actions_adddup2(&actions, pipefd[1], STDOUT_FILENO) == 0 &&
      posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0) == 0 &&
      posix_spawn_file_actions_addclose(&actions, pipefd[0]) == 0 &&
      posix_spawn_file_actions_addclose(&actions, pipefd[1]) == 0;
  if (!configured) {
    posix_spawn_file_actions_destroy(&actions);
    close(pipefd[0]); close(pipefd[1]); return {};
  }
  char* argv[] = {const_cast<char*>("/bin/launchctl"), const_cast<char*>("print"),
                  const_cast<char*>(target.c_str()), nullptr};
  pid_t child = -1;
  const int result = posix_spawn(&child, argv[0], &actions, nullptr, argv, environ);
  posix_spawn_file_actions_destroy(&actions);
  close(pipefd[1]);
  if (result != 0) { close(pipefd[0]); return {}; }
  std::string output;
  const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(2);
  bool eof = false;
  while (!eof && output.size() < 64 * 1024 && std::chrono::steady_clock::now() < deadline) {
    pollfd descriptor{pipefd[0], POLLIN, 0};
    if (poll(&descriptor, 1, 20) <= 0) continue;
    char buffer[4096];
    const ssize_t count = read(pipefd[0], buffer, sizeof(buffer));
    if (count > 0) output.append(buffer, static_cast<std::size_t>(count));
    else if (count == 0) eof = true;
    else if (errno != EINTR && errno != EAGAIN) break;
  }
  close(pipefd[0]);
  int status = 0;
  pid_t reaped = 0;
  do {
    reaped = waitpid(child, &status, WNOHANG);
    if (reaped == child || (reaped < 0 && errno != EINTR)) break;
    reaped = 0;
    std::this_thread::sleep_for(std::chrono::milliseconds(5));
  } while (std::chrono::steady_clock::now() < deadline);
  if (reaped == 0) {
    kill(child, SIGKILL); // Only the launchctl child we just spawned.
    while (waitpid(child, &status, 0) < 0 && errno == EINTR) {}
    return {};
  }
  if (reaped != child || !eof || !WIFEXITED(status) || WEXITSTATUS(status) != 0) return {};
  if (output.rfind(target + " = {", 0) != 0) return {};
  return output;
}

bool info(pid_t pid, proc_bsdinfo& result) {
  return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &result, sizeof(result)) == sizeof(result);
}
bool sameProcess(const proc_bsdinfo& a, const proc_bsdinfo& b) {
  return a.pbi_pid == b.pbi_pid && a.pbi_start_tvsec == b.pbi_start_tvsec &&
         a.pbi_start_tvusec == b.pbi_start_tvusec;
}
} // namespace

void finishMacosVideoServices() noexcept {
  if (__builtin_available(macOS 26.0, *)) {
    try {
      const std::string description = ownServiceDescription();
      const auto ownedPid = ownedVideoServicePid(description, getpid());
      if (!ownedPid) return;
      const pid_t pid = *ownedPid;
      proc_bsdinfo self{}, peer{}, current{};
      char path[PROC_PIDPATHINFO_MAXSIZE]{};
      if (!info(getpid(), self) || !info(pid, peer) || peer.pbi_uid != getuid() ||
          peer.pbi_start_tvsec < self.pbi_start_tvsec ||
          (peer.pbi_start_tvsec == self.pbi_start_tvsec && peer.pbi_start_tvusec < self.pbi_start_tvusec) ||
          proc_pidpath(pid, path, sizeof(path)) <= 0 || std::string_view(path) != videoServiceExecutable ||
          !info(pid, current) || !sameProcess(peer, current)) return;
      // NSOpenGLContext's window attachment leaves this process's launchd
      // domain alive on macOS 26 even after VT invalidation and process exit.
      // SIGTERM gives the now-idle, exclusively per-client helper its normal
      // clean exit. No decoder or graphics producer may still be running here.
      if (kill(pid, SIGTERM) != 0) return;
      const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(2);
      while (info(pid, current) && sameProcess(peer, current) &&
             std::chrono::steady_clock::now() < deadline)
        std::this_thread::sleep_for(std::chrono::milliseconds(10));
      if (info(pid, current) && sameProcess(peer, current)) {
        std::fprintf(stderr, "WAM: owned VideoToolbox service %d did not terminate\n", pid);
      } else if (const char* trace = std::getenv("WAM_NATIVE_BENCHMARK_TELEMETRY");
                 trace && std::strcmp(trace, "1") == 0) {
        std::fprintf(stderr, "WAM: retired owned VideoToolbox service %d after media teardown\n", pid);
      }
    } catch (...) {
      std::fprintf(stderr, "WAM: could not inspect owned VideoToolbox service at exit\n");
    }
  }
}
} // namespace wam::qt
