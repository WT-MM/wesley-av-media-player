#pragma once

#include <cctype>
#include <cstddef>
#include <string>
#include <string_view>

namespace wam::qt {

enum class PlaybackSourceClass {
  FastLocal,
  BufferedLocal,
  Network,
};

// Buffering is deliberately selected per source instead of applying a large
// network-oriented cache to every file. The byte limits bound compressed
// demux packets, can be exceeded slightly by mpv, and do not include decoder
// or renderer allocations.
struct PlaybackBufferPolicy {
  const char *cache_mode;
  const char *cache_seconds;
  const char *readahead_seconds;
  const char *forward_bytes;
  const char *backward_bytes;
  const char *hysteresis_seconds;
  std::size_t maximum_packet_bytes;
};

[[nodiscard]] constexpr PlaybackBufferPolicy
playbackBufferPolicy(PlaybackSourceClass source_class) {
  if (source_class == PlaybackSourceClass::FastLocal) {
    // Local storage can refill on demand. One second is enough to absorb
    // scheduler jitter without retaining tens of seconds of compressed data.
    return {"no", "0", "1", "16MiB", "0", "0.25", 16U * 1024U * 1024U};
  }

  // Slow/network media gets a modest eight-second jitter window, a small
  // five-second-skip back buffer, and hysteresis so the demuxer reads in
  // batches instead of waking continuously to keep the cache exactly full.
  // A mounted share or removable device still looks like a local file to mpv,
  // so explicitly enable its cache there; protocol URLs can retain mpv's
  // automatic seekability/network decision.
  return {source_class == PlaybackSourceClass::BufferedLocal ? "yes" : "auto",
          "8",
          "3",
          "32MiB",
          "8MiB",
          "2",
          40U * 1024U * 1024U};
}

// Mounted network shares arrive as file URLs, so URL syntax alone is not
// enough to choose the lean local policy. Qt exposes the filesystem type on
// every desktop platform; keep the classification here so it is independently
// testable and easy to extend as platforms add filesystems.
[[nodiscard]] inline bool isRemoteFilesystemType(std::string_view type) {
  std::string normalized(type);
  for (char &value : normalized) {
    value = static_cast<char>(std::tolower(static_cast<unsigned char>(value)));
  }

  constexpr std::string_view remote_types[] = {
      "9p",     "afs", "afpfs", "ceph", "cifs",  "davfs", "davfs2", "gpfs",
      "lustre", "nfs", "nfs4",  "smb3", "smbfs", "sshfs", "webdav", "glusterfs",
  };
  for (const std::string_view remote : remote_types) {
    if (normalized == remote)
      return true;
  }
  if (normalized.starts_with("fuse.") && normalized != "fuseblk")
    return true;
  return false;
}

} // namespace wam::qt
