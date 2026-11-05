#pragma once

#if defined(Q_OS_MACOS)
#include <QCoreApplication>
#include <QSocketNotifier>
#include <memory>
#include <cerrno>
#include <csignal>
#include <fcntl.h>
#include <unistd.h>

namespace wam::qt {
// Translate SIGTERM into ordinary Qt quit. The signal handler only writes to
// a nonblocking pipe; all window/decoder teardown happens on the GUI thread.
class TerminationSignal final {
public:
  TerminationSignal() {
    if (::pipe(pipe_) != 0) qFatal("Cannot create termination signal pipe");
    for (int fd : pipe_) {
      if (::fcntl(fd, F_SETFL, O_NONBLOCK) == -1 ||
          ::fcntl(fd, F_SETFD, FD_CLOEXEC) == -1)
        qFatal("Cannot configure termination signal pipe");
    }
    notifier_ = std::make_unique<QSocketNotifier>(pipe_[0], QSocketNotifier::Read);
    QObject::connect(notifier_.get(), &QSocketNotifier::activated,
                     notifier_.get(), [this] {
      notifier_->setEnabled(false);
      QCoreApplication::quit();
    });
    writeFd_ = pipe_[1];
    struct sigaction action{};
    action.sa_handler = &handle;
    sigemptyset(&action.sa_mask);
    action.sa_flags = SA_RESTART;
    if (::sigaction(SIGTERM, &action, &previous_) != 0)
      qFatal("Cannot install termination signal handler");
  }
  ~TerminationSignal() {
    ::sigaction(SIGTERM, &previous_, nullptr);
    writeFd_ = -1;
    notifier_.reset();
    ::close(pipe_[0]);
    ::close(pipe_[1]);
  }
  TerminationSignal(const TerminationSignal&) = delete;
  TerminationSignal& operator=(const TerminationSignal&) = delete;
private:
  static void handle(int) noexcept {
    const int savedErrno = errno;
    const char byte = 1;
    if (writeFd_ >= 0) (void)::write(writeFd_, &byte, 1);
    errno = savedErrno;
  }
  inline static volatile sig_atomic_t writeFd_{-1};
  int pipe_[2]{-1, -1};
  struct sigaction previous_{};
  std::unique_ptr<QSocketNotifier> notifier_;
};
} // namespace wam::qt
#endif
