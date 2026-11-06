#include "media/byte_source.hpp"

#include <algorithm>
#include <cerrno>
#include <fcntl.h>
#include <limits>
#include <sys/stat.h>
#if defined(_WIN32)
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#include <io.h>
#else
#include <unistd.h>
#endif

namespace wam::media {

std::optional<FileIdentity> FileIdentity::of(int descriptor) noexcept {
#if defined(_WIN32)
  struct _stati64 facts {};
  BY_HANDLE_FILE_INFORMATION information{};
  if (::_fstati64(descriptor, &facts) != 0 ||
      !::GetFileInformationByHandle(
          reinterpret_cast<HANDLE>(::_get_osfhandle(descriptor)),
          &information)) {
    return std::nullopt;
  }
  const std::int64_t modifiedSeconds = static_cast<std::int64_t>(
      (static_cast<std::uint64_t>(information.ftLastWriteTime.dwHighDateTime)
       << 32U) |
      information.ftLastWriteTime.dwLowDateTime);
  const std::int64_t modifiedNanoseconds = 0;
#else
  struct stat facts {};
  if (::fstat(descriptor, &facts) != 0) {
    return std::nullopt;
  }
#if defined(__APPLE__)
  const auto& modified = facts.st_mtimespec;
#else
  const auto& modified = facts.st_mtim;
#endif
  const std::int64_t modifiedSeconds = modified.tv_sec;
  const std::int64_t modifiedNanoseconds = modified.tv_nsec;
#endif
  if (facts.st_size < 0 || !S_ISREG(facts.st_mode)) {
    return std::nullopt;
  }
  return FileIdentity{static_cast<std::uint64_t>(facts.st_dev),
                      static_cast<std::uint64_t>(facts.st_ino),
                      static_cast<std::uint64_t>(facts.st_size),
                      modifiedSeconds, modifiedNanoseconds};
}

std::shared_ptr<StableFileReader> StableFileReader::open(
    const std::filesystem::path& path) noexcept {
#if defined(_WIN32)
  const int descriptor =
      ::_wopen(path.c_str(), _O_RDONLY | _O_BINARY | _O_NOINHERIT);
#else
  const int descriptor = ::open(path.c_str(), O_RDONLY | O_CLOEXEC);
#endif
  if (descriptor < 0) {
    return nullptr;
  }
  const auto identity = FileIdentity::of(descriptor);
  if (!identity) {
    ::close(descriptor);
    return nullptr;
  }
  try {
    return std::shared_ptr<StableFileReader>(
        new StableFileReader(descriptor, *identity));
  } catch (...) {
    ::close(descriptor);
    return nullptr;
  }
}

StableFileReader::~StableFileReader() { ::close(descriptor_); }

bool StableFileReader::readAt(std::uint64_t offset,
                              std::span<std::byte> destination) noexcept {
#if defined(_WIN32)
  // The CRT's off_t can be 32-bit; ReadFile accepts 64-bit offsets.
  using off_t = std::int64_t;
#endif
  const std::uint64_t size = identity_.size;
  if (destination.empty()) {
    return offset <= size;
  }
  if (offset > size || destination.size() > size - offset ||
      offset > static_cast<std::uint64_t>(std::numeric_limits<off_t>::max())) {
    return false;
  }
  std::size_t copied = 0;
  while (copied < destination.size()) {
    const std::uint64_t current = offset + copied;
    if (current >
        static_cast<std::uint64_t>(std::numeric_limits<off_t>::max())) {
      return false;
    }
#if defined(_WIN32)
    OVERLAPPED position{};
    position.Offset = static_cast<DWORD>(current);
    position.OffsetHigh = static_cast<DWORD>(current >> 32);
    DWORD transferred = 0;
    const bool succeeded = ::ReadFile(
        reinterpret_cast<HANDLE>(::_get_osfhandle(descriptor_)),
        destination.data() + copied,
        static_cast<DWORD>(
            std::min<std::size_t>(destination.size() - copied, MAXDWORD)),
        &transferred, &position);
    if (!succeeded) return false;
    const auto result = static_cast<std::int64_t>(transferred);
#else
    const ssize_t result =
        ::pread(descriptor_, destination.data() + copied,
                destination.size() - copied, static_cast<off_t>(current));
#endif
    if (result < 0 && errno == EINTR) {
      continue;
    }
    if (result <= 0) {
      return false;
    }
    copied += static_cast<std::size_t>(result);
  }
  return true;
}

bool StableFileReader::unchanged() const noexcept {
  return FileIdentity::of(descriptor_) == identity_;
}

}  // namespace wam::media
