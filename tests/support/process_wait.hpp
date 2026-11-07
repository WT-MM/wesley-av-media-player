#pragma once

// Polling waits for tests that synchronise with a real child process. The
// timeouts are failure bounds only: each wait returns as soon as its event
// is observed.

#include <chrono>
#include <filesystem>
#include <system_error>
#include <thread>

#ifndef _WIN32
#include <cerrno>
#include <csignal>
#include <sys/types.h>
#endif

// True once `path` is a non-empty regular file (a child's "I have started"
// marker or PID log).
inline bool waitForFile(const std::filesystem::path& path,
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

#ifndef _WIN32
inline bool processExists(pid_t process) {
  if (kill(process, 0) == 0) return true;
  return errno == EPERM;
}

inline bool waitForProcessExit(pid_t process,
                               std::chrono::steady_clock::duration timeout) {
  const auto deadline = std::chrono::steady_clock::now() + timeout;
  while (std::chrono::steady_clock::now() < deadline) {
    if (!processExists(process)) return true;
    std::this_thread::sleep_for(std::chrono::milliseconds(10));
  }
  return !processExists(process);
}
#endif
