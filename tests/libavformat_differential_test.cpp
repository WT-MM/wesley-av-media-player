#include "media/libavformat_cursor.hpp"
#include "media/matroska_demuxer.hpp"
#include "media/mpegts_demuxer.hpp"
#include <algorithm>
#include <iostream>
#include <vector>
#define REQUIRE(condition)                                                     \
  do {                                                                         \
    if (!(condition)) {                                                        \
      std::cerr << "FAIL " << __LINE__ << ": " #condition "\n";                \
      return 1;                                                                \
    }                                                                          \
  } while (false)
using namespace wam::media;
bool equal(MediaTime a, MediaTime b) {
  return (!a.valid() && !b.valid()) ||
         compareMediaTime(a, b) == MediaTimeOrder::Equal;
}
int main(int argc, char **argv) {
  if (argc != 3)
    return 2;
  std::atomic<bool> cancelled{};
  LibavformatCursor oracle;
  std::string error;
  REQUIRE(oracle.open(argv[1], cancelled, error));
  MediaSourceOpenOptions options;
  options.selection.requireAudio = false;
  std::uint64_t count{}, bytes{};
  std::vector<std::byte> payload(LibavformatCursor::kPacketBytes);
  const bool mkv = std::string_view(argv[2]) == "mkv";
  const auto matroska =
      mkv ? matroska::prepareMatroskaLocalFile(argv[1], options)
          : matroska::MatroskaPrepareOutcome{};
  const auto ts = !mkv ? mpegts::prepareMpegTsLocalFile(argv[1], options)
                       : mpegts::MpegTsPrepareOutcome{};
  if (mkv) {
    if (!matroska.asset)
      std::cerr << matroska.message << '\n';
    REQUIRE(matroska.asset);
  } else {
    if (!ts.asset)
      std::cerr << ts.message << '\n';
    REQUIRE(ts.asset);
  }
  auto mc =
      mkv ? matroska.asset->makeVideoCursor(
                *matroska.asset->planGeneration({0, 1}, MediaSeekMode::Accurate)
                     .plan)
          : nullptr;
  auto tc =
      !mkv
          ? ts.asset->makeVideoCursor(
                *ts.asset->planGeneration({0, 1}, MediaSeekMode::Accurate).plan)
          : nullptr;
  for (;;) {
    LibavformatCursor::Packet packet;
    const auto read = oracle.read(packet, error);
    if (read == LibavformatCursor::Read::End)
      break;
    if (read != LibavformatCursor::Read::Packet)
      std::cerr << error << '\n';
    REQUIRE(read == LibavformatCursor::Read::Packet);
    if (!oracle.stream(packet.stream).video)
      continue;
    MediaTime pts{}, dts{}, duration{};
    std::size_t size{};
    bool key{};
    if (mkv) {
      auto result = mc->readNext();
      auto *raw = std::get_if<matroska::MatroskaCompressedSample>(&result);
      REQUIRE(raw);
      size = raw->aggregateBytes;
      REQUIRE(size <= payload.size());
      REQUIRE(matroska.asset->copyRanges(
          std::span(raw->frames).first(raw->frameCount),
          std::span(payload).first(size)));
      pts = raw->presentationTime;
      dts = raw->decodeTime;
      duration = raw->duration;
      key = raw->keyFrame;
    } else {
      auto result = tc->readNext();
      auto *raw = std::get_if<mpegts::MpegTsCompressedSample>(&result);
      REQUIRE(raw);
      size = raw->payloadBytes;
      REQUIRE(size <= payload.size());
      REQUIRE(ts.asset->copyAccessUnit(*raw, std::span(payload).first(size)));
      pts = raw->presentationTime;
      dts = raw->decodeTime;
      duration = raw->duration;
      key = raw->keyFrame;
    }
    if (!equal(pts, packet.pts) || !equal(dts, packet.dts) ||
        !equal(duration, packet.duration))
      std::cerr << "packet=" << count << " pts=" << pts.value << '/'
                << pts.timescale << ":" << packet.pts.value << '/'
                << packet.pts.timescale << " dts=" << dts.value << '/'
                << dts.timescale << ":" << packet.dts.value << '/'
                << packet.dts.timescale << " duration=" << duration.value << '/'
                << duration.timescale << ":" << packet.duration.value << '/'
                << packet.duration.timescale << '\n';
    REQUIRE(equal(pts, packet.pts));
    REQUIRE(equal(dts, packet.dts));
    REQUIRE(equal(duration, packet.duration));
    REQUIRE(key == packet.key);
    REQUIRE(size == packet.bytes.size());
    REQUIRE(
        std::equal(packet.bytes.begin(), packet.bytes.end(), payload.begin()));
    ++count;
    bytes += size;
  }
  if (mkv)
    REQUIRE(
        std::holds_alternative<matroska::MatroskaCursorEnd>(mc->readNext()));
  else
    REQUIRE(std::holds_alternative<mpegts::MpegTsCursorEnd>(tc->readNext()));
  REQUIRE(count > 0);
  std::cout << "agreement packets=" << count << " bytes=" << bytes
            << " pts=" << count << " dts=" << count << " duration=" << count
            << " key=" << count << '\n';
  return 0;
}
