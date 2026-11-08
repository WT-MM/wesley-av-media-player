#include "avcodec/library_directory.hpp"
#include "media/libavformat_cursor.hpp"
#include "media/avcodec/api.hpp"
#include "media/avcodec/closure.hpp"
#include "media/avcodec/runtime.hpp"
#include "media/avcodec_time.hpp"
#include "media/media_container_probe.hpp"
extern "C" {
#include <libavformat/avformat.h>
}
#include <algorithm>
#include <array>
#include <cerrno>
#include <climits>
#include <cstring>
#include <dlfcn.h>
#include <fcntl.h>
#include <mach-o/dyld.h>
#include <unistd.h>

namespace wam::media {
namespace {

// The demuxers the native libavformat route requires of the bundled library.
constexpr std::array<const char *, 9> kRequiredDemuxers{
    "mov", "avi", "flv", "ogg", "asf", "rm", "mpeg", "mpegts", "matroska"};

struct FormatApi {
#define WAM_AVFORMAT_API(X)                                                    \
  X(avformat_alloc_context)                                                    \
  X(avformat_free_context)                                                     \
  X(avformat_open_input) X(avformat_find_stream_info) X(avformat_close_input)  \
      X(av_read_frame) X(av_seek_frame) X(avio_alloc_context)                  \
          X(avio_context_free) X(av_demuxer_iterate) X(avio_enum_protocols)    \
              X(avformat_version) X(avformat_configuration)                    \
                  X(avformat_license) X(av_find_input_format)
#define DECLARE(name) decltype(&::name) name{};
  WAM_AVFORMAT_API(DECLARE)
#undef DECLARE
};
std::uint32_t be32(const unsigned char *p) noexcept {
  return (std::uint32_t(p[0]) << 24) | (std::uint32_t(p[1]) << 16) |
         (std::uint32_t(p[2]) << 8) | p[3];
}
} // namespace
struct LibavformatCursor::Impl {
  avcodec::RuntimeLease runtime;
  FormatApi api;
  void *library{};
  AVFormatContext *format{};
  AVIOContext *io{};
  AVPacket *packet{};
  int fd{-1};
  FileIdentity identity{};
  CancellationToken cancellation{};
  std::int64_t position{}, extent{};
  std::uint64_t ioBudget{};
  // Why the AVIO callbacks refused the latest libav call, if they did.
  enum class IoFault : std::uint8_t { None, FileChanged, Budget };
  IoFault ioFault{IoFault::None};
  bool fragmented{};
  ~Impl() {
    if (packet)
      avcodec::api().av_packet_free(&packet);
    if (format)
      api.avformat_close_input(&format);
    if (io) {
      avcodec::api().av_free(io->buffer);
      io->buffer = nullptr;
      api.avio_context_free(&io);
    }
    if (fd >= 0)
      ::close(fd);
    if (library) {
      std::lock_guard lock(avcodec::playbackClosureMutex());
      dlclose(library);
    }
  }
  bool cancelled() const noexcept { return cancellation.cancelled(); }
  static int rejectExternalIo(AVFormatContext *, AVIOContext **, const char *,
                              int, AVDictionary **) {
    return AVERROR(EACCES);
  }
  static int interrupt(void *opaque) {
    return static_cast<Impl *>(opaque)->cancelled();
  }
  bool sameFile() noexcept {
    if (FileIdentity::of(fd) == identity) return true;
    ioFault = IoFault::FileChanged;
    return false;
  }
  static int readBytes(void *opaque, std::uint8_t *buffer, int count) {
    auto &self = *static_cast<Impl *>(opaque);
    if (self.cancelled())
      return AVERROR_EXIT;
    if (!self.sameFile())
      return AVERROR(EIO);
    if (self.position >= self.extent)
      return AVERROR_EOF;
    const auto size = std::min<std::int64_t>(
        {count, std::int64_t(kIoBytes), self.extent - self.position});
    if (std::uint64_t(size) > self.ioBudget) {
      self.ioFault = IoFault::Budget;
      return AVERROR(EFBIG);
    }
    self.ioBudget -= size;
    ssize_t got;
    do {
      got = ::pread(self.fd, buffer, size, self.position);
    } while (got < 0 && errno == EINTR && !self.cancelled());
    if (got <= 0)
      return got == 0 ? AVERROR_EOF : AVERROR(errno);
    self.position += got;
    return int(got);
  }
  static std::int64_t seekBytes(void *opaque, std::int64_t offset, int whence) {
    auto &self = *static_cast<Impl *>(opaque);
    if (self.cancelled())
      return AVERROR_EXIT;
    if (whence == AVSEEK_SIZE)
      return self.extent;
    whence &= ~AVSEEK_FORCE;
    const __int128 value =
        __int128(offset) + (whence == SEEK_CUR   ? self.position
                            : whence == SEEK_END ? self.extent
                                                 : 0);
    if ((whence != SEEK_SET && whence != SEEK_CUR && whence != SEEK_END) ||
        value < 0 || value > self.extent)
      return AVERROR(EINVAL);
    self.position = std::int64_t(value);
    return self.position;
  }
  bool load(std::string &error) {
    if (const char *why = runtime.acquire()) {
      error = why;
      return false;
    }
    const auto libraries = avcodec::libraryDirectory(reinterpret_cast<const void*>(&LibavformatCursor::runtimeFailure));
    const auto path = libraries / pins::kNativeAvformatLibrary;
    if (!std::filesystem::is_regular_file(path)) {
      error = "LibavformatStageNotBuilt";
      return false;
    }
    if (std::filesystem::canonical(path).parent_path() !=
        std::filesystem::canonical(libraries)) {
      error = "LibavformatOutsideBundle";
      return false;
    }
    std::lock_guard lock(avcodec::playbackClosureMutex());
    library = dlopen(path.c_str(), RTLD_LOCAL | RTLD_NOW);
    if (!library) {
      error = "LibavformatLibraryUnavailable";
      return false;
    }
#define BIND(name)                                                             \
  api.name = reinterpret_cast<decltype(api.name)>(dlsym(library, #name));      \
  if (!api.name) {                                                             \
    error = "LibavformatSymbolMissing: " #name;                                \
    return false;                                                              \
  }
    WAM_AVFORMAT_API(BIND)
#undef BIND
    if (api.avformat_version() != LIBAVFORMAT_VERSION_INT ||
        std::strcmp(api.avformat_license(), "LGPL version 2.1 or later") ||
        std::strcmp(api.avformat_configuration(),
                    avcodec::api().avcodec_configuration())) {
      error = "LibavformatBuildMismatch";
      return false;
    }
    for (const char *name : kRequiredDemuxers)
      if (!api.av_find_input_format(name)) {
        error = "LibavformatDemuxerMissing";
        return false;
      }
    void *protocolIterator{};
    unsigned protocols{};
    while (const char *name = api.avio_enum_protocols(&protocolIterator, 0)) {
      if (std::strcmp(name, "file")) {
        error = "LibavformatUnexpectedProtocol";
        return false;
      }
      ++protocols;
    }
    if (protocols != 1) {
      error = "LibavformatFileProtocolMissing";
      return false;
    }
    void *demuxIterator{};
    unsigned demuxers{};
    while (api.av_demuxer_iterate(&demuxIterator))
      ++demuxers;
    if (demuxers != kRequiredDemuxers.size()) {
      error = "LibavformatUnexpectedDemuxer";
      return false;
    }
    return true;
  }
  static bool needsRouting(const std::filesystem::path& path, CancellationToken cancellation) {
  Impl probe;
  probe.cancellation = cancellation;
  probe.fd = ::open(path.c_str(), O_RDONLY | O_CLOEXEC | O_NONBLOCK);
  const auto identity = probe.fd < 0 ? std::nullopt : FileIdentity::of(probe.fd);
  if (!identity)
    return false;
  probe.identity = *identity;
  probe.extent = std::int64_t(identity->size);
  std::string error;
  // A cut box needs libavformat. Fewer than a box header's 8 bytes after the
  // last complete box cannot hold any media, so such a file is complete and
  // keeps its ordinary route.
  return probe.inspectTail(error) &&
         (probe.extent + 8 <= std::int64_t(identity->size) || probe.fragmented);
  }
  bool inspectTail(std::string &error, MediaRefusalClass *refusal = nullptr) {
    std::array<unsigned char, 16> box{};
    if (::pread(fd, box.data(), box.size(), 0) < 8)
      return true;
    if (!isoBmffTopLevelBoxAt(std::as_bytes(std::span(box)), 4))
      return true;
    bool init = false;
    std::int64_t offset = 0, fragment = -1;
    for (unsigned count = 0; offset < extent; ++count) {
      if (cancelled()) {
        error = "LibavformatCancelled";
        return false;
      }
      if (count == 65536) {
        error = "LibavformatBoxIndexLimit";
        return false;
      }
      const auto got = ::pread(fd, box.data(), box.size(), offset);
      if (got < 8) {
        extent = fragment >= 0 ? fragment : offset;
        break;
      }
      std::uint64_t length = be32(box.data());
      unsigned header = 8;
      if (length == 1) {
        if (got < 16) {
          extent = fragment >= 0 ? fragment : offset;
          break;
        }
        length =
            (std::uint64_t(be32(box.data() + 8)) << 32) | be32(box.data() + 12);
        header = 16;
      }
      if (!length)
        length = extent - offset;
      if (length < header) {
        error = "LibavformatInvalidBoxLength";
        return false;
      }
      if (!std::memcmp(box.data() + 4, "moof", 4)) {
        fragment = offset; fragmented = true;
      }
      if (length > std::uint64_t(extent - offset)) {
        extent = fragment >= 0 ? fragment : offset;
        break;
      }
      if (!std::memcmp(box.data() + 4, "moov", 4))
        init = true;
      if (!std::memcmp(box.data() + 4, "mdat", 4))
        fragment = -1;
      offset += length;
    }
    if (fragment >= 0)
      extent = fragment;
    if (!init) {
      error = "this recording is incomplete: its initialization metadata is "
              "missing";
      if (refusal)
        *refusal = MediaRefusalClass::MissingInitialization;
      return false;
    }
    return true;
  }
};
std::string LibavformatCursor::runtimeDescription() {
  std::string text = "libavformat=" AV_STRINGIFY(LIBAVFORMAT_VERSION)
                     " loading=lazy protocols=file demuxers=";
  for (const char *name : kRequiredDemuxers) {
    if (name != kRequiredDemuxers[0])
      text += ',';
    text += name;
  }
  return text;
}

std::string LibavformatCursor::runtimeFailure() {
  Impl runtime;
  std::string error;
  runtime.load(error);
  return error;
}
bool LibavformatCursor::requiresExactDemuxTimeline(const std::filesystem::path& path, CancellationToken cancellation) {
  return Impl::needsRouting(path,cancellation);
}
LibavformatCursor::LibavformatCursor() = default;
LibavformatCursor::~LibavformatCursor() = default;
bool LibavformatCursor::open(const std::filesystem::path &path,
                             const std::atomic<bool> &cancellation,
                             std::string &error, MediaRefusalClass *refusal) {
  return open(
      path,
      CancellationToken{&cancellation,
                   [](const void *value) noexcept {
                     return static_cast<const std::atomic<bool> *>(value)->load(
                         std::memory_order_acquire);
                   }},
      error, refusal);
}
bool LibavformatCursor::open(const std::filesystem::path &path,
                             CancellationToken cancellation, std::string &error,
                             MediaRefusalClass *refusal) {
  // Opened means impl_ is set: a failed open leaves the cursor closed.
  impl_.reset();
  auto opening = std::make_unique<Impl>();
  auto &s = *opening;
  s.cancellation = cancellation;
  if (s.cancelled()) {
    error = "LibavformatCancelled";
    return false;
  }
  s.fd = ::open(path.c_str(), O_RDONLY | O_CLOEXEC | O_NONBLOCK);
  const auto identity = s.fd < 0 ? std::nullopt : FileIdentity::of(s.fd);
  if (!identity) {
    error = "LibavformatLocalFileRequired";
    return false;
  }
  s.identity = *identity;
  s.extent = std::int64_t(identity->size);
  if (!s.inspectTail(error, refusal) || !s.load(error))
    return false;
  auto *buffer =
      static_cast<unsigned char *>(avcodec::api().av_mallocz(kIoBytes));
  s.io = s.api.avio_alloc_context(buffer, kIoBytes, 0, &s, &Impl::readBytes,
                                  nullptr, &Impl::seekBytes);
  if (!s.io) {
    avcodec::api().av_free(buffer);
    error = "LibavformatIoAllocation";
    return false;
  }
  s.format = s.api.avformat_alloc_context();
  if (!s.format) {
    error = "LibavformatContextAllocation";
    return false;
  }
  s.format->io_open = &Impl::rejectExternalIo;
  s.format->pb = s.io;
  s.format->flags |= AVFMT_FLAG_CUSTOM_IO;
  s.format->interrupt_callback = {&Impl::interrupt, &s};
  s.format->probesize = kProbeBytes;
  s.format->max_analyze_duration = 2 * AV_TIME_BASE;
  s.format->max_probe_packets = 256;
  s.format->max_streams = 32;
  s.format->max_index_size = kIndexBytes;
  s.format->max_picture_buffer = kPacketBytes;
  s.ioBudget = 4 * kProbeBytes;
  s.ioFault = Impl::IoFault::None;
  if (s.api.avformat_open_input(&s.format, nullptr, nullptr, nullptr) < 0 ||
      s.api.avformat_find_stream_info(s.format, nullptr) < 0) {
    if (s.cancelled()) {
      error = "LibavformatCancelled";
      return false;
    }
    switch (s.ioFault) {
      case Impl::IoFault::Budget: error = "LibavformatProbeLimit"; break;
      case Impl::IoFault::FileChanged:
      case Impl::IoFault::None: error = "LibavformatProbeFailed"; break;
    }
    return false;
  }
  s.packet = avcodec::api().av_packet_alloc();
  if (!s.packet) {
    error = "LibavformatPacketAllocation";
    return false;
  }
  impl_ = std::move(opening);
  return true;
}
LibavformatCursor::Read LibavformatCursor::read(Packet &out,
                                                std::string &error) {
  out = {};
  if (!impl_) {
    error = "LibavformatCursorNotOpen";
    return Read::Failed;
  }
  auto &s = *impl_;
  if (s.cancelled())
    return Read::Cancelled;
  if (!s.sameFile()) {
    error = "LibavformatFileChanged";
    return Read::Failed;
  }
  s.ioBudget = kProbeBytes;
  s.ioFault = Impl::IoFault::None;
  avcodec::api().av_packet_unref(s.packet);
  const int rc = s.api.av_read_frame(s.format, s.packet);
  if (s.cancelled())
    return Read::Cancelled;
  if (rc == AVERROR_EOF)
    return Read::End;
  if (rc < 0) {
    switch (s.ioFault) {
      case Impl::IoFault::FileChanged: error = "LibavformatFileChanged"; break;
      case Impl::IoFault::Budget: error = "LibavformatReadBudget"; break;
      case Impl::IoFault::None: error = "LibavformatPacketReadFailed"; break;
    }
    return Read::Failed;
  }
  const auto &p = *s.packet;
  if (p.stream_index < 0 || unsigned(p.stream_index) >= s.format->nb_streams ||
      p.size <= 0 || unsigned(p.size) > kPacketBytes) {
    error = "LibavformatPacketLimit";
    return Read::Failed;
  }
  const auto tb = s.format->streams[p.stream_index]->time_base;
  auto stamp = [&](std::int64_t value, MediaTime &result) {
    if (value == AV_NOPTS_VALUE)
      return true;
    const auto exact = avcodecExactTime(value, tb.num, tb.den);
    if (!exact)
      return false;
    result = *exact;
    return true;
  };
  if (!stamp(p.pts, out.pts) || !stamp(p.dts, out.dts) ||
      (p.duration > 0 && !stamp(p.duration, out.duration))) {
    error = "LibavformatTimestampUnrepresentable";
    return Read::Failed;
  }
  // Matroska stores presentation times only, and libavformat's Matroska
  // demuxer copies each block's presentation time into dts, which is not a
  // decode order once frames reorder. Native Matroska carriage never invents
  // a decode timestamp either; VideoToolbox decodes in storage order.
  if (std::strstr(s.format->iformat->name, "matroska"))
    out.dts = {};
  out.stream = p.stream_index;
  out.key = p.flags & AV_PKT_FLAG_KEY;
  out.corrupt = p.flags & AV_PKT_FLAG_CORRUPT;
  out.bytes = {reinterpret_cast<const std::byte *>(p.data),
               std::size_t(p.size)};
  for (int i = 0; i < p.side_data_elems; ++i) {
    const auto &data = p.side_data[i];
    if (data.type == AV_PKT_DATA_SKIP_SAMPLES && data.size >= 10) {
      auto little = [](const unsigned char *b) {
        return std::uint32_t(b[0]) | (std::uint32_t(b[1]) << 8) |
               (std::uint32_t(b[2]) << 16) | (std::uint32_t(b[3]) << 24);
      };
      out.skipStart = little(data.data);
      out.skipEnd = little(data.data + 4);
    }
    if (data.type == AV_PKT_DATA_ENCRYPTION_INFO ||
        data.type == AV_PKT_DATA_ENCRYPTION_INIT_INFO) {
      error = "this file requires a decryption key WAM does not have";
      return Read::Failed;
    }
    if (data.type == AV_PKT_DATA_NEW_EXTRADATA) {
      error = "LibavformatConfigurationChanged";
      return Read::Failed;
    }
  }
  return Read::Packet;
}
const char* LibavformatCursor::formatName() const noexcept {
  return impl_ && impl_->format->iformat ? impl_->format->iformat->name : "";
}
bool LibavformatCursor::seek(unsigned stream, MediaTime target,
                             std::string &error) {
  if (!impl_) {
    error = "LibavformatCursorNotOpen";
    return false;
  }
  auto &s = *impl_;
  if (stream >= streamCount() || !target.valid()) {
    error = "LibavformatSeekTarget";
    return false;
  }
  if (s.cancelled()) {
    error = "LibavformatCancelled";
    return false;
  }
  const auto tb = s.format->streams[stream]->time_base;
  if (tb.num <= 0 || tb.den <= 0) {
    error = "LibavformatSeekTimeBase";
    return false;
  }
  const auto tick = mediaTimeToTicks(target, tb.den, tb.num, TickRounding::Floor);
  if (!tick) {
    error = "LibavformatSeekUnrepresentable";
    return false;
  }
  s.ioBudget = 4 * kProbeBytes;
  s.ioFault = Impl::IoFault::None;
  avcodec::api().av_packet_unref(s.packet);
  if (s.api.av_seek_frame(s.format, stream, *tick,
                          AVSEEK_FLAG_BACKWARD) < 0) {
    error = "LibavformatSeekFailed";
    return false;
  }
  return true;
}
FileIdentity LibavformatCursor::identity() const noexcept {
  return impl_ ? impl_->identity : FileIdentity{};
}
unsigned LibavformatCursor::streamCount() const noexcept {
  return impl_ ? impl_->format->nb_streams : 0;
}
LibavformatCursor::Stream LibavformatCursor::stream(unsigned i) const noexcept {
  if (i >= streamCount())
    return {};
  const auto &s = *impl_->format->streams[i];
  const auto &p = *s.codecpar;
  Stream out;
  out.codecId = p.codec_id;
  out.containerTrackId = s.id;
  out.video = p.codec_type == AVMEDIA_TYPE_VIDEO;
  out.audio = p.codec_type == AVMEDIA_TYPE_AUDIO;
  out.attached = s.disposition & AV_DISPOSITION_ATTACHED_PIC;
  out.unsupportedMetadata =
      (p.sample_aspect_ratio.num > 0 && p.sample_aspect_ratio.den > 0 &&
       p.sample_aspect_ratio.num != p.sample_aspect_ratio.den) ||
      (p.field_order != AV_FIELD_UNKNOWN &&
       p.field_order != AV_FIELD_PROGRESSIVE) ||
      p.nb_coded_side_data != 0 ||
      // MP4/QuickTime chapters (a chapter text track or Nero chpl) only
      // navigate; elsewhere (Matroska ordered editions) chapters can change
      // the presentation, which libavformat does not apply.
      (impl_->format->nb_chapters != 0 &&
       !std::strstr(impl_->format->iformat->name, "mov"));
  out.primaries = p.color_primaries;
  out.transfer = p.color_trc;
  out.matrix = p.color_space;
  out.fullRange = p.color_range == AVCOL_RANGE_JPEG;
  out.rangeSpecified = p.color_range != AVCOL_RANGE_UNSPECIFIED;
  out.width = std::max(0, p.width);
  out.height = std::max(0, p.height);
  out.rate = std::max(0, p.sample_rate);
  out.channels = std::max(0, p.ch_layout.nb_channels);
  out.frameSize = std::max(0, p.frame_size);
  out.blockAlign = static_cast<unsigned>(std::max(0, p.block_align));
  out.bitRate = std::max<std::int64_t>(0, p.bit_rate);
  out.timeBase = avcodecExactTime(1, s.time_base.num, s.time_base.den)
                     .value_or(MediaTime{});
  out.start = avcodecExactTime(s.start_time, s.time_base.num, s.time_base.den)
                  .value_or(MediaTime{});
  out.duration = avcodecExactTime(s.duration, s.time_base.num, s.time_base.den)
                     .value_or(MediaTime{});
  if (p.extradata_size > 0)
    out.extradata = {reinterpret_cast<const std::byte *>(p.extradata),
                     std::size_t(p.extradata_size)};
  return out;
}
const char *LibavformatCursor::codecName(unsigned i) const noexcept {
  const auto id = stream(i).codecId;
  switch (id) {
  case AV_CODEC_ID_HEVC:
    return "hevc";
  case AV_CODEC_ID_H264:
    return "h264";
  case AV_CODEC_ID_MPEG4:
    return "mpeg4";
  case AV_CODEC_ID_AAC:
    return "aac";
  case AV_CODEC_ID_OPUS:
    return "opus";
  case AV_CODEC_ID_VORBIS:
    return "vorbis";
  case AV_CODEC_ID_THEORA:
    return "theora";
  case AV_CODEC_ID_WMV2:
    return "wmv2";
  case AV_CODEC_ID_WMV3:
    return "wmv3";
  case AV_CODEC_ID_WMAV2:
    return "wmav2";
  case AV_CODEC_ID_MPEG2VIDEO:
    return "mpeg2video";
  default:
    return "unmapped codec";
  }
}
} // namespace wam::media
