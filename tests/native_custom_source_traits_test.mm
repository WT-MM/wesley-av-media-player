// The Traits surface of the shared custom-source core.
//
// `native_custom_source_core.hpp` is one body instantiated twice, and every
// place the Matroska and MPEG-TS backends deliberately differ is a named
// member of `MatroskaSourceTraits` or `MpegTsSourceTraits`. This suite pins
// those members directly, without container bytes, so a future edit that
// moves one container's rule cannot silently move the other's:
//
//   1. THE MERGE KEY. Matroska video sorts on a key that leads its
//      presentation time by exactly kVideoMergeLeadNanoseconds (rounded up in
//      the timestamp's own timescale); Matroska audio sorts on its
//      presentation time. MPEG-TS sorts on the real decode timestamp when the
//      sample carries one and on the presentation time otherwise, with NO
//      lead -- and the type has no lead constant at all.
//   2. AUDIO-ONLY ADMISSION. Matroska admits a container with no video track;
//      MPEG-TS always requests a video cursor.
//   3. ONE FACADE. Both backends answer the neutral entry refusals with the
//      shared core's text, prefixed by their own kName, so an edit to the
//      facade is by construction an edit to both.
//
// The fixture-driven backend suites (matroska_media_source_test,
// mpegts_media_source_test) prove the same divergences over real bytes; this
// one proves them at the seam.

#include "platform/macos/matroska_media_source.hpp"
#include "platform/macos/mpegts_media_source.hpp"

#include "media/native_media_source.hpp"

#include <cstdint>
#include <iostream>
#include <string>

#include "support/expect.hpp"

namespace {

using wam::macos::MatroskaMediaSource;
using wam::macos::MatroskaSourceTraits;
using wam::macos::MpegTsMediaSource;
using wam::macos::MpegTsSourceTraits;
using wam::media::MediaSample;
using wam::media::MediaSampleKind;
using wam::media::MediaSourceOpenOptions;
using wam::media::MediaSourceOpenStatus;
using wam::media::MediaSourceSeekRequest;
using wam::media::MediaTime;
using wam::media::MediaTimeOrder;

// ---- compile-time facts ----------------------------------------------------

static_assert(!MatroskaSourceTraits::kVideoRequired,
              "Matroska admits audio-only containers");
static_assert(MpegTsSourceTraits::kVideoRequired,
              "MPEG-TS refuses a stream with no video");
static_assert(MatroskaSourceTraits::kVideoMergeLeadNanoseconds == 250'000'000,
              "the Matroska decode-order lead is a quarter second");
// The lead is a Matroska fact and must not grow a transport-stream twin: a
// container with a real DTS has nothing for it to reconstruct.
template <class Traits>
constexpr bool statesMergeLead = requires {
  Traits::kVideoMergeLeadNanoseconds;
};
static_assert(statesMergeLead<MatroskaSourceTraits>,
              "Matroska states its synthetic merge lead by name");
static_assert(!statesMergeLead<MpegTsSourceTraits>,
              "MPEG-TS states no synthetic merge lead");

[[nodiscard]] bool sameTime(MediaTime lhs, MediaTime rhs) noexcept {
  const auto order = wam::media::compareMediaTime(lhs, rhs);
  return order.has_value() && *order == MediaTimeOrder::Equal;
}

[[nodiscard]] MediaSample sampleAt(MediaSampleKind kind, MediaTime pts,
                                   MediaTime dts = MediaTime{}) {
  MediaSample sample;
  sample.kind = kind;
  sample.presentationTime = pts;
  sample.decodeTime = dts;
  return sample;
}

// The lead restated independently of the backend: ceil(lead * timescale / 1e9)
// ticks, in 128-bit arithmetic.
[[nodiscard]] std::int64_t leadTicks(std::int32_t timescale) noexcept {
  const __int128 scaled =
      static_cast<__int128>(250'000'000) * static_cast<__int128>(timescale);
  return static_cast<std::int64_t>((scaled + 999'999'999) / 1'000'000'000);
}

// ---- 1. the merge key ------------------------------------------------------

void testMatroskaVideoLeadsItsPresentationTime() {
  // Timescales that divide the lead exactly, and ones that do not.
  const std::int32_t timescales[] = {1000, 90'000, 30'000, 1'000'000'000, 7,
                                     1001};
  for (const std::int32_t timescale : timescales) {
    const MediaTime pts{3 * static_cast<std::int64_t>(timescale), timescale};
    const MediaTime key = MatroskaSourceTraits::mergeOrderKey(
        sampleAt(MediaSampleKind::EncodedVideo, pts));
    expect(key.valid() && key.timescale == timescale &&
               key.value == pts.value - leadTicks(timescale),
           "Matroska video sorts exactly one lead ahead of its presentation "
           "time, rounded up in its own timescale");
  }
  // 7 ticks/s: 250 ms is 1.75 ticks and must round UP to 2, never down.
  const MediaTime coarse = MatroskaSourceTraits::mergeOrderKey(
      sampleAt(MediaSampleKind::EncodedVideo, MediaTime{21, 7}));
  expect(coarse.value == 19 && coarse.timescale == 7,
         "a lead that is not a whole tick rounds up so the key never lands "
         "short of the reorder window");
  const MediaTime invalid = MatroskaSourceTraits::mergeOrderKey(
      sampleAt(MediaSampleKind::EncodedVideo, MediaTime{}));
  expect(!invalid.valid(), "an invalid presentation time keys as itself");
}

void testMatroskaAudioSortsOnPresentationTime() {
  const MediaTime pts{48'000 * 5, 48'000};
  expect(sameTime(MatroskaSourceTraits::mergeOrderKey(
                      sampleAt(MediaSampleKind::EncodedAudio, pts)),
                  pts),
         "Matroska audio sorts on its exact presentation time");
  expect(sameTime(MatroskaSourceTraits::mergeOrderKey(sampleAt(
                      MediaSampleKind::EncodedAudio, MediaTime{-960, 48'000})),
                  MediaTime{-960, 48'000}),
         "a negative audio origin keys as itself");
}

void testMpegTsKeysOnTheRealDecodeTimestamp() {
  const MediaTime pts{270'000, 90'000};
  const MediaTime dts{261'000, 90'000};
  expect(sameTime(MpegTsSourceTraits::mergeOrderKey(
                      sampleAt(MediaSampleKind::EncodedVideo, pts, dts)),
                  dts),
         "MPEG-TS video with a decode timestamp sorts on that timestamp");
  expect(sameTime(MpegTsSourceTraits::mergeOrderKey(
                      sampleAt(MediaSampleKind::EncodedVideo, pts)),
                  pts),
         "MPEG-TS video without a decode timestamp sorts on its presentation "
         "time with no lead");
  expect(sameTime(MpegTsSourceTraits::mergeOrderKey(
                      sampleAt(MediaSampleKind::EncodedAudio, pts)),
                  pts),
         "MPEG-TS audio sorts on its presentation time");
}

// The two containers answer the SAME video sample differently by exactly the
// lead. This is the assertion that fails if either rule is copied across.
void testTheTwoContainersDisagreeByExactlyTheLead() {
  const MediaTime pts{90'000 * 4, 90'000};
  const MediaSample video = sampleAt(MediaSampleKind::EncodedVideo, pts);
  const MediaTime matroska = MatroskaSourceTraits::mergeOrderKey(video);
  const MediaTime mpegTs = MpegTsSourceTraits::mergeOrderKey(video);
  expect(mpegTs.value - matroska.value == leadTicks(90'000) &&
             mpegTs.timescale == matroska.timescale,
         "for one DTS-less video sample the MPEG-TS key trails the Matroska "
         "key by exactly the lead");
  const MediaSample audio = sampleAt(MediaSampleKind::EncodedAudio, pts);
  expect(sameTime(MatroskaSourceTraits::mergeOrderKey(audio),
                  MpegTsSourceTraits::mergeOrderKey(audio)),
         "for one audio sample both containers key identically");
}

// ---- 2. audio-only admission --------------------------------------------

void testVideoRequirementDiffers() {
  expect(MatroskaSourceTraits::kVideoRequired !=
             MpegTsSourceTraits::kVideoRequired,
         "exactly one of the two containers requires a video cursor");
}

// ---- 3. one facade -----------------------------------------------------------

template <class Source>
void testSharedFacadeRefusals(const char* name) {
  const std::string prefix(name);
  Source source;
  MediaSourceOpenOptions options;

  const auto unarmed = source.openLocalFile("/nonexistent/clip", options, 1);
  expect(unarmed.status == MediaSourceOpenStatus::Failed &&
             unarmed.error == prefix + " open generation was not armed",
         "an unarmed open is refused with the shared text under the "
         "container's own name");

  expect(source.armOperation(1), "generation 1 arms");
  const auto emptyPath = source.openLocalFile("", options, 1);
  expect(emptyPath.status == MediaSourceOpenStatus::Failed &&
             emptyPath.error == "invalid " + prefix + " open path or state",
         "an empty path is refused by the shared entry check under the "
         "container's own name");
  expect(!source.stats().open && source.stats().operationGeneration == 0,
         "a rejected open restores an idle publication");

  expect(source.armOperation(2), "generation 2 arms");
  source.requestCancel(2);
  const auto cancelled = source.openLocalFile("/nonexistent/clip", options, 2);
  expect(cancelled.status == MediaSourceOpenStatus::Cancelled &&
             cancelled.error == prefix + " open was cancelled before entry",
         "a cancel published before entry is answered by the shared facade");
  expect(source.stats().generation == 2 && !source.stats().open,
         "a cancelled open withdraws its publication");

  expect(source.armOperation(3), "generation 3 arms");
  const MediaSourceSeekRequest request{3, MediaTime{1, 2},
                                       wam::media::MediaSeekMode::Accurate};
  const auto seek = source.seek(request);
  expect(!seek.accepted && seek.error == "invalid " + prefix + " seek request",
         "a seek on a closed source is refused by the shared facade");

  expect(!source.armOperation(3),
         "a generation at or below the high-water mark cannot re-arm");
  source.close();
  expect(source.stats().generation == 3 && !source.stats().open,
         "close keeps the generation high-water mark");
}

}  // namespace

int main() {
  testMatroskaVideoLeadsItsPresentationTime();
  testMatroskaAudioSortsOnPresentationTime();
  testMpegTsKeysOnTheRealDecodeTimestamp();
  testTheTwoContainersDisagreeByExactlyTheLead();
  testVideoRequirementDiffers();
  // The names are restated as literals rather than read from the Traits: a
  // prefix that agreed with the backend by construction would prove nothing.
  testSharedFacadeRefusals<MatroskaMediaSource>("matroska");
  testSharedFacadeRefusals<MpegTsMediaSource>("mpeg-ts");

  if (failures == 0) {
    std::cout << "native custom source traits passed\n";
  }
  return failures == 0 ? 0 : 1;
}
