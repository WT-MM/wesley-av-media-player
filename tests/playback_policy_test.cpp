#include "qt/playback_policy.hpp"

#include <cstdlib>
#include <iostream>
#include <string>

int main() {
  using wam::qt::isRemoteFilesystemType;
  using wam::qt::playbackBufferPolicy;
  using wam::qt::PlaybackSourceClass;

  int failures = 0;
  const auto expect = [&failures](bool condition, const char *message) {
    if (condition)
      return;
    std::cerr << "FAIL: " << message << '\n';
    ++failures;
  };

  const auto local = playbackBufferPolicy(PlaybackSourceClass::FastLocal);
  expect(std::string(local.cache_mode) == "no", "local cache is disabled");
  expect(std::string(local.cache_seconds) == "0", "local cache time is zero");
  expect(std::string(local.readahead_seconds) == "1",
         "local readahead remains bounded");
  expect(std::string(local.forward_bytes) == "16MiB",
         "local forward byte ceiling");
  expect(std::string(local.backward_bytes) == "0",
         "local back buffer is disabled");
  expect(std::string(local.hysteresis_seconds) == "0.25", "local hysteresis");
  expect(local.maximum_packet_bytes == 16U * 1024U * 1024U,
         "local maximum packet bytes");

  const auto mounted = playbackBufferPolicy(PlaybackSourceClass::BufferedLocal);
  expect(std::string(mounted.cache_mode) == "yes",
         "mounted and removable media explicitly enable caching");
  expect(mounted.maximum_packet_bytes == 40U * 1024U * 1024U,
         "mounted maximum packet bytes");

  const auto remote = playbackBufferPolicy(PlaybackSourceClass::Network);
  expect(std::string(remote.cache_mode) == "auto", "remote cache is automatic");
  expect(std::string(remote.cache_seconds) == "8", "remote cache duration");
  expect(std::string(remote.readahead_seconds) == "3",
         "remote readahead duration");
  expect(std::string(remote.forward_bytes) == "32MiB",
         "remote forward byte ceiling");
  expect(std::string(remote.backward_bytes) == "8MiB",
         "remote backward byte ceiling");
  expect(std::string(remote.hysteresis_seconds) == "2", "remote hysteresis");
  expect(remote.maximum_packet_bytes == 40U * 1024U * 1024U,
         "remote maximum packet bytes");

  expect(isRemoteFilesystemType("smbfs"), "macOS SMB is remote");
  expect(isRemoteFilesystemType("NFS4"),
         "filesystem matching is case-insensitive");
  expect(isRemoteFilesystemType("fuse.sshfs"), "SSHFS is remote");
  expect(isRemoteFilesystemType("fuse.rclone"), "rclone mounts are remote");
  expect(isRemoteFilesystemType("lustre"), "Lustre is remote");
  expect(isRemoteFilesystemType("cifs"), "Linux/Windows CIFS is remote");
  expect(!isRemoteFilesystemType("apfs"), "APFS is local");
  expect(!isRemoteFilesystemType("ntfs"), "NTFS is local by type");

  return failures == 0 ? EXIT_SUCCESS : EXIT_FAILURE;
}
