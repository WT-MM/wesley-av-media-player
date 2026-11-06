#pragma once

#include <cstddef>
#include <cstdint>
#include <filesystem>
#include <memory>
#include <optional>
#include <span>

namespace wam::media {

// Container-neutral byte access shared by every demuxer. Readers must either
// fill the complete destination or return false.
class SeekableByteReader {
 public:
  virtual ~SeekableByteReader() = default;
  [[nodiscard]] virtual std::uint64_t size() const noexcept = 0;
  [[nodiscard]] virtual bool
  readAt(std::uint64_t offset, std::span<std::byte> destination) noexcept = 0;
};

struct CancellationToken {
  const void* context{nullptr};
  bool (*probe)(const void*) noexcept{nullptr};

  [[nodiscard]] bool cancelled() const noexcept {
    return probe != nullptr && probe(context);
  }
};

struct ByteRange {
  std::uint64_t offset{0};
  std::uint64_t size{0};

  friend constexpr bool operator==(ByteRange, ByteRange) = default;
};

struct FrameRange {
  ByteRange bytes;

  friend constexpr bool operator==(FrameRange, FrameRange) = default;
};

// One sequential read: the Matroska copy chunk, the MPEG-TS read window and
// the libavformat AVIO buffer, so every demuxer presents the same I/O shape to
// the page cache.
inline constexpr std::size_t kSequentialReadBytes{64U * 1024U};

// What "the file did not change" means for every reader that holds a plan
// built from a file's bytes: the bytes reachable through the retained
// descriptor are still the bytes the plan was built against. dev+ino catch a
// replaced file, size catches truncation and extension, and mtime catches any
// write to the content.
//
// st_ctime is deliberately NOT part of that identity. ctime is the
// INODE-metadata timestamp: it moves for xattr writes, chmod, chown,
// link-count and rename -- none of which touch a single content byte. On
// macOS those happen to a media file constantly and from outside this
// process: Spotlight/mds indexing, iCloud/FileProvider sync bookkeeping,
// quarantine and last-used-date stamping. Including ctime would report "the
// file changed" for events that are, by construction, not changes to the
// file's content -- a false positive whose probability grows with how long
// the plan is held and with how busy the machine's metadata daemons are. It
// surfaced as a load-dependent Matroska-only open/playback failure
// (FileChanged -> SourceOpen/SourceRead -> Protocol/Decode -> fallback) that
// the AVFoundation route, which makes no such assertion, never shows.
//
// What dropping ctime gives up is only the case of an in-place, byte-count-
// preserving write whose mtime is then restored by an explicit utimes() call.
// That is deliberate forgery, not a hazard a local media player is defending
// against, and every honest mutation still moves mtime or size.
struct FileIdentity {
  std::uint64_t device{}, inode{}, size{};
  // On Windows modifiedSeconds holds the raw FILETIME (100 ns units).
  std::int64_t modifiedSeconds{}, modifiedNanoseconds{};

  // Empty unless the descriptor names a regular file.
  [[nodiscard]] static std::optional<FileIdentity> of(int descriptor) noexcept;

  friend bool operator==(const FileIdentity&, const FileIdentity&) = default;
};

// pread-backed reader over one retained descriptor.
class StableFileReader final : public SeekableByteReader {
 public:
  [[nodiscard]] static std::shared_ptr<StableFileReader>
  open(const std::filesystem::path& path) noexcept;
  ~StableFileReader() override;
  StableFileReader(const StableFileReader&) = delete;
  StableFileReader& operator=(const StableFileReader&) = delete;

  [[nodiscard]] std::uint64_t size() const noexcept override {
    return identity_.size;
  }
  [[nodiscard]] bool readAt(std::uint64_t offset,
                            std::span<std::byte> destination) noexcept override;
  // True while the descriptor keeps the FileIdentity it had at open.
  [[nodiscard]] bool unchanged() const noexcept;

 private:
  StableFileReader(int descriptor, FileIdentity identity) noexcept
      : descriptor_(descriptor), identity_(identity) {}

  int descriptor_{-1};
  FileIdentity identity_{};
};

}  // namespace wam::media
