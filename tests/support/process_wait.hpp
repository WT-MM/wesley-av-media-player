#pragma once

// Polling waits for tests. The timeouts are failure bounds only: each wait
// returns as soon as its event is observed.

#include <chrono>
#include <filesystem>
#include <system_error>
#include <thread>

#ifndef _WIN32
#include <cerrno>
#include <csignal>
#include <sys/types.h>
#endif

// Polls `predicate` until it holds, running `idle` between polls (pump a run
// loop, sleep), and returns false once `timeout` has passed. The predicate is
// never re-evaluated after the deadline: some tests poll consuming predicates
// (a capacity-one mailbox), where a trailing re-evaluation would take the
// event a second time and report failure exactly when the wait succeeded.
template <typename Predicate, typename Idle>
bool waitUntil(Predicate&& predicate,
               std::chrono::steady_clock::duration timeout, Idle&& idle) {
  const auto deadline = std::chrono::steady_clock::now() + timeout;
  for (;;) {
    if (predicate()) return true;
    if (std::chrono::steady_clock::now() >= deadline) return false;
    idle();
  }
}

template <typename Predicate>
bool waitUntil(Predicate&& predicate,
               std::chrono::steady_clock::duration timeout) {
  return waitUntil(predicate, timeout, [] {
    std::this_thread::sleep_for(std::chrono::milliseconds(1));
  });
}

// True once `path` is a non-empty regular file (a child's "I have started"
// marker or PID log).
inline bool waitForFile(const std::filesystem::path& path,
                        std::chrono::steady_clock::duration timeout) {
  return waitUntil([&] {
    std::error_code error;
    return std::filesystem::is_regular_file(path, error) &&
           std::filesystem::file_size(path, error) > 0;
  }, timeout, [] { std::this_thread::sleep_for(std::chrono::milliseconds(10)); });
}

#ifndef _WIN32
inline bool processExists(pid_t process) {
  if (kill(process, 0) == 0) return true;
  return errno == EPERM;
}

inline bool waitForProcessExit(pid_t process,
                               std::chrono::steady_clock::duration timeout) {
  return waitUntil([process] { return !processExists(process); }, timeout,
                   [] { std::this_thread::sleep_for(std::chrono::milliseconds(10)); });
}
#endif
