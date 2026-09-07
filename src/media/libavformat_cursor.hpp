#pragma once
#include "media/native_media_source.hpp"
#include <atomic>
#include <memory>
#include <span>

namespace wam::media {
// One owner worker calls every method except cancellation. The packet view
// expires on the next read/seek; retained payload belongs to the consumer.
class LibavformatCursor final {
public:
  static constexpr std::size_t kIoBytes = 64 * 1024;
  static constexpr std::size_t kPacketBytes = 4 * 1024 * 1024;
  static constexpr std::size_t kProbeBytes = 8 * 1024 * 1024;
  static constexpr std::size_t kIndexBytes = 4 * 1024 * 1024;
  struct Packet {
    unsigned stream{};
    MediaTime pts{}, dts{}, duration{};
    std::span<const std::byte> bytes{};
    bool key{}, corrupt{};
    std::uint32_t skipStart{}, skipEnd{};
  };
  struct Identity {
    std::uint64_t device{}, inode{}, size{};
    std::int64_t modifiedSeconds{}, modifiedNanoseconds{};
    friend bool operator==(const Identity &, const Identity &) = default;
  };
  Identity identity() const noexcept;
  struct Stream {
    int codecId{};
    bool video{}, audio{}, attached{}, unsupportedMetadata{};
    unsigned primaries{}, transfer{}, matrix{};
    unsigned width{}, height{}, rate{}, channels{}, frameSize{};
    MediaTime timeBase{}, duration{}, start{};
    std::span<const std::byte> extradata{};
  };
  enum class Read { Packet, End, Cancelled, Failed };
  static std::string runtimeFailure();
  LibavformatCursor();
  ~LibavformatCursor();
  LibavformatCursor(const LibavformatCursor &) = delete;
  LibavformatCursor &operator=(const LibavformatCursor &) = delete;
  struct Cancellation {
    const void *context{};
    bool (*probe)(const void *) noexcept {};
    bool cancelled() const noexcept { return probe && probe(context); }
  };
  static bool requiresTailRecovery(const std::filesystem::path &, Cancellation);
  static bool requiresExactDemuxTimeline(const std::filesystem::path &, Cancellation);
  bool open(const std::filesystem::path &, Cancellation, std::string &error);
  bool open(const std::filesystem::path &,
            const std::atomic<bool> &cancellation, std::string &error);
  Read read(Packet &, std::string &error);
  bool seek(unsigned stream, MediaTime target, std::string &error);
  unsigned streamCount() const noexcept;
  Stream stream(unsigned) const noexcept;
  const char *codecName(unsigned) const noexcept;
  const char *formatName() const noexcept;
  std::uint64_t trimmedBytes() const noexcept;

private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};
static_assert(LibavformatCursor::kIoBytes + LibavformatCursor::kPacketBytes +
                  LibavformatCursor::kProbeBytes +
                  LibavformatCursor::kIndexBytes ==
              16'842'752);
} // namespace wam::media
