// The per-codec facts table, asserted in BOTH directions.
//
// A one-sided test passes on a table that answers the same thing for every
// codec, so every membership below is checked for a codec that is IN the set
// and a codec that is deliberately OUT of it, and the coverage checks walk the
// whole enumeration rather than naming rows.

#include "media/media_codec_facts.hpp"

#include "media/audio_codec_timing.hpp"

#include <cstdlib>
#include <iostream>
#include <set>

#include "support/expect.hpp"

namespace {

using wam::media::kMediaCodecCount;
using wam::media::kMediaCodecFacts;
using wam::media::kProRes422FamilyCoreMediaTypes;
using wam::media::MediaCodec;
using wam::media::mediaCodecFacts;
using wam::media::mediaCodecForCoreMediaType;
using wam::media::MediaCodecConfigurationKind;
using wam::media::MediaCodecKind;


// Every enumerator has exactly one row, and the row it has is its own. This is
// the property the header's static_asserts also state; restating it at run time
// is what makes the failure readable when a new enumerator is appended.
void testEveryEnumeratorHasItsOwnRow() {
  expect(kMediaCodecFacts.size() == kMediaCodecCount,
         "the table has one row per enumerator");
  std::set<int> seen;
  for (std::size_t index = 0; index < kMediaCodecCount; ++index) {
    const auto codec = static_cast<MediaCodec>(index);
    const auto &facts = mediaCodecFacts(codec);
    expect(facts.codec == codec, "lookup returns the row for its own codec");
    expect(seen.insert(static_cast<int>(facts.codec)).second,
           "no enumerator is named by two rows");
  }
  expect(seen.size() == kMediaCodecCount, "every enumerator was reached");
  // The last enumerator the table was written against. Appending one without a
  // row makes this fail rather than silently taking row zero.
  expect(mediaCodecFacts(MediaCodec::AdpcmMs).codec == MediaCodec::AdpcmMs,
         "the last enumerator has its own row");
}

// The kind field agrees with the existing classifiers: every codec the audio
// timing predicates can be asked about is Audio, and no video codec is.
void testKindAgreesWithTheAudioClassifiers() {
  for (const auto &facts : kMediaCodecFacts) {
    if (wam::media::audioCodecPrecedesStreamOrigin(facts.codec) ||
        wam::media::audioCodecStatesExactDecodedDuration(facts.codec)) {
      expect(facts.kind == MediaCodecKind::Audio,
             "a codec the audio timing predicates admit is an audio codec");
    }
    if (facts.kind == MediaCodecKind::Video) {
      expect(!wam::media::audioCodecPrecedesStreamOrigin(facts.codec) &&
                 !wam::media::audioCodecStatesExactDecodedDuration(facts.codec),
             "no video codec is admitted by an audio timing predicate");
    }
  }
  expect(mediaCodecFacts(MediaCodec::H264).kind == MediaCodecKind::Video &&
             mediaCodecFacts(MediaCodec::Aac).kind == MediaCodecKind::Audio &&
             mediaCodecFacts(MediaCodec::Unknown).kind ==
                 MediaCodecKind::Unknown,
         "the three kinds are each reachable");
}

// A four-character code is stated by exactly the video rows, and names its own
// codec back. The ProRes family is the one many-to-one mapping.
void testCoreMediaTypesRoundTrip() {
  for (const auto &facts : kMediaCodecFacts) {
    const bool stated = facts.coreMediaType != 0;
    expect(stated == (facts.kind == MediaCodecKind::Video),
           "exactly the video rows state a four-character code");
    if (stated) {
      expect(mediaCodecForCoreMediaType(facts.coreMediaType) == facts.codec,
             "a stated four-character code names its own codec back");
    }
  }
  for (const std::uint32_t proRes : kProRes422FamilyCoreMediaTypes) {
    expect(mediaCodecForCoreMediaType(proRes) == MediaCodec::ProRes,
           "every ProRes 422 four-character code names ProRes");
  }
  // 'ap4h' is the 4444 family, a SECOND decode contract this build does not
  // admit, so it must stay unnamed rather than fold into the 422 enumerator.
  expect(mediaCodecForCoreMediaType(0x61703468U) == MediaCodec::Unknown,
         "ProRes 4444 is not named by the 422 enumerator");
  expect(mediaCodecForCoreMediaType(0) == MediaCodec::Unknown &&
             mediaCodecForCoreMediaType(0x7A7A7A7AU) == MediaCodec::Unknown,
         "an unnamed four-character code is Unknown");
}

// The record shape. carriesConfigurationRecord and statesCodedSampleFormat are
// deliberately different sets, and so are configurationKind and the atom name.
void testConfigurationRecordShape() {
  expect(mediaCodecFacts(MediaCodec::H264).carriesConfigurationRecord &&
             mediaCodecFacts(MediaCodec::Hevc).carriesConfigurationRecord &&
             mediaCodecFacts(MediaCodec::Av1).carriesConfigurationRecord &&
             mediaCodecFacts(MediaCodec::Vp9).carriesConfigurationRecord &&
             mediaCodecFacts(MediaCodec::Vp8).carriesConfigurationRecord &&
             mediaCodecFacts(MediaCodec::Mpeg4Visual)
                 .carriesConfigurationRecord,
         "the codecs with a parameter-set record state that they carry one");
  expect(!mediaCodecFacts(MediaCodec::Mpeg2Video).carriesConfigurationRecord &&
             !mediaCodecFacts(MediaCodec::ProRes).carriesConfigurationRecord &&
             !mediaCodecFacts(MediaCodec::Mjpeg).carriesConfigurationRecord,
         "the record-less codecs state that they carry none");
  // MPEG-2 is the break between the two: no out-of-band record, but its
  // sequence header IS parsed in band into a stated sample format.
  expect(mediaCodecFacts(MediaCodec::Mpeg2Video).statesCodedSampleFormat,
         "MPEG-2 states a coded sample format without carrying a record");
  expect(!mediaCodecFacts(MediaCodec::ProRes).statesCodedSampleFormat &&
             !mediaCodecFacts(MediaCodec::Mjpeg).statesCodedSampleFormat,
         "ProRes and Motion JPEG state no coded sample format");
  // MPEG-4 Part 2 is the break the other way: its record kind is CodecPrivate
  // (the contract names no Esds enumerator) while its atom is 'esds'.
  expect(mediaCodecFacts(MediaCodec::Mpeg4Visual).configurationKind ==
                 MediaCodecConfigurationKind::CodecPrivate &&
             std::string(mediaCodecFacts(MediaCodec::Mpeg4Visual)
                             .configurationAtomName) == "esds",
         "MPEG-4 Part 2's record kind and atom name are different facts");
  // VP8 is the break again: a vpcC record kind with no CoreMedia atom, because
  // the software stage reads the record directly.
  expect(mediaCodecFacts(MediaCodec::Vp8).configurationKind ==
                 MediaCodecConfigurationKind::VpcC &&
             mediaCodecFacts(MediaCodec::Vp8).configurationAtomName == nullptr,
         "VP8 states a record kind and no atom");
  expect(std::string(mediaCodecFacts(MediaCodec::H264)
                         .configurationAtomName) == "avcC" &&
             std::string(mediaCodecFacts(MediaCodec::Hevc)
                             .configurationAtomName) == "hvcC" &&
             std::string(mediaCodecFacts(MediaCodec::Av1)
                             .configurationAtomName) == "av1C" &&
             std::string(mediaCodecFacts(MediaCodec::Vp9)
                             .configurationAtomName) == "vpcC",
         "the four parameter-set atoms are spelled as CoreMedia spells them");
  // Every audio row holds the neutral record value, because an audio track's
  // record kind is a container fact rather than a codec one.
  for (const auto &facts : kMediaCodecFacts) {
    if (facts.kind != MediaCodecKind::Audio) {
      continue;
    }
    expect(facts.configurationKind == MediaCodecConfigurationKind::None &&
               facts.configurationAtomName == nullptr &&
               !facts.carriesConfigurationRecord &&
               !facts.statesCodedSampleFormat,
           "an audio row holds no video record fields");
  }
}

// The decode-session facts. Each of the three is asserted for a member and for
// a deliberate non-member.
void testDecodeSessionFacts() {
  expect(mediaCodecFacts(MediaCodec::Mpeg2Video)
                 .needsPinnedOutputPixelFormat &&
             mediaCodecFacts(MediaCodec::Mpeg4Visual)
                 .needsPinnedOutputPixelFormat &&
             mediaCodecFacts(MediaCodec::ProRes)
                 .needsPinnedOutputPixelFormat &&
             mediaCodecFacts(MediaCodec::Mjpeg).needsPinnedOutputPixelFormat,
         "the legacy decoders pin their output pixel format");
  expect(!mediaCodecFacts(MediaCodec::H264).needsPinnedOutputPixelFormat &&
             !mediaCodecFacts(MediaCodec::Hevc).needsPinnedOutputPixelFormat,
         "the bi-planar decoders need no pin");
  // MPEG-4 Part 2 is the codec that breaks the coincidence between pinning and
  // the record: it carries a record AND decodes to a packed 4:2:2 surface.
  expect(mediaCodecFacts(MediaCodec::Mpeg4Visual)
                 .carriesConfigurationRecord &&
             mediaCodecFacts(MediaCodec::Mpeg4Visual)
                 .needsPinnedOutputPixelFormat,
         "pinning and the record are separate fields");

  expect(mediaCodecFacts(MediaCodec::H264).requiresHardwareDecode &&
             mediaCodecFacts(MediaCodec::Hevc).requiresHardwareDecode &&
             mediaCodecFacts(MediaCodec::Av1).requiresHardwareDecode &&
             mediaCodecFacts(MediaCodec::Vp9).requiresHardwareDecode,
         "the block-backed codecs require hardware decode");
  expect(!mediaCodecFacts(MediaCodec::Mpeg2Video).requiresHardwareDecode &&
             !mediaCodecFacts(MediaCodec::Mpeg4Visual)
                  .requiresHardwareDecode &&
             !mediaCodecFacts(MediaCodec::Mjpeg).requiresHardwareDecode &&
             !mediaCodecFacts(MediaCodec::ProRes).requiresHardwareDecode &&
             !mediaCodecFacts(MediaCodec::Vp8).requiresHardwareDecode,
         "the codecs with a software decoder on some target host do not");
}

// The two route memberships. Each is a set two sites read, and a codec one site
// admits and the other refuses is the failure they exist to prevent.
void testRouteMemberships() {
  expect(mediaCodecFacts(MediaCodec::H264).avfoundationVideoAdmitted &&
             mediaCodecFacts(MediaCodec::Hevc).avfoundationVideoAdmitted &&
             mediaCodecFacts(MediaCodec::Av1).avfoundationVideoAdmitted &&
             mediaCodecFacts(MediaCodec::Vp9).avfoundationVideoAdmitted &&
             mediaCodecFacts(MediaCodec::ProRes).avfoundationVideoAdmitted &&
             mediaCodecFacts(MediaCodec::Mjpeg).avfoundationVideoAdmitted,
         "AVFoundation admits its six video codecs");
  expect(!mediaCodecFacts(MediaCodec::Vp8).avfoundationVideoAdmitted &&
             !mediaCodecFacts(MediaCodec::Mpeg2Video)
                  .avfoundationVideoAdmitted &&
             !mediaCodecFacts(MediaCodec::Mpeg4Visual)
                  .avfoundationVideoAdmitted,
         "the demuxer-only video codecs are not admitted on that route");

  expect(mediaCodecFacts(MediaCodec::H264).previewScrubAdmitted &&
             mediaCodecFacts(MediaCodec::Hevc).previewScrubAdmitted &&
             mediaCodecFacts(MediaCodec::Mpeg2Video).previewScrubAdmitted &&
             mediaCodecFacts(MediaCodec::Mpeg4Visual).previewScrubAdmitted &&
             mediaCodecFacts(MediaCodec::ProRes).previewScrubAdmitted &&
             mediaCodecFacts(MediaCodec::Mjpeg).previewScrubAdmitted,
         "the preview lane admits the six codecs it can decode");
  expect(!mediaCodecFacts(MediaCodec::Av1).previewScrubAdmitted &&
             !mediaCodecFacts(MediaCodec::Vp9).previewScrubAdmitted &&
             !mediaCodecFacts(MediaCodec::Vp8).previewScrubAdmitted,
         "the capability-gated and software-stage codecs are not scrubbed");
  for (const auto &facts : kMediaCodecFacts) {
    if (facts.kind == MediaCodecKind::Audio) {
      expect(!facts.avfoundationVideoAdmitted && !facts.previewScrubAdmitted,
             "an audio row is in neither video route");
    }
  }
}

// The decoder lead-in. Three layers ask this question and their answers have to
// meet on the presentation floor. The frames a decoder never EMITS is a
// different question and is deliberately not this field.
void testDecoderLeadInFrames() {
  expect(mediaCodecFacts(MediaCodec::Ac3).decoderLeadInFrames == 256 &&
             mediaCodecFacts(MediaCodec::Eac3).decoderLeadInFrames == 256,
         "AC-3 and E-AC-3 state the 256-frame decoder delay");
  expect(mediaCodecFacts(MediaCodec::Mp3).decoderLeadInFrames == 529,
         "MP3 states the 529-frame decoder delay");
  expect(mediaCodecFacts(MediaCodec::Opus).decoderLeadInFrames == 120,
         "Opus states the 120-frame libopus decoder delay");
  // Vorbis's lead-in is one access unit rather than a constant, so the table
  // states zero and the one site that needs it supplies the packet length.
  expect(mediaCodecFacts(MediaCodec::Vorbis).decoderLeadInFrames == 0,
         "Vorbis states no constant lead-in");
  expect(mediaCodecFacts(MediaCodec::Aac).decoderLeadInFrames == 0 &&
             mediaCodecFacts(MediaCodec::Flac).decoderLeadInFrames == 0 &&
             mediaCodecFacts(MediaCodec::Alac).decoderLeadInFrames == 0 &&
             mediaCodecFacts(MediaCodec::Pcm).decoderLeadInFrames == 0 &&
             mediaCodecFacts(MediaCodec::AdpcmIma).decoderLeadInFrames == 0 &&
             mediaCodecFacts(MediaCodec::AdpcmMs).decoderLeadInFrames == 0,
         "the codecs that swallow nothing state zero");
  for (const auto &facts : kMediaCodecFacts) {
    if (facts.kind == MediaCodecKind::Video) {
      expect(facts.decoderLeadInFrames == 0,
             "no video row states an audio decoder lead-in");
    }
  }
}

} // namespace

int main() {
  testEveryEnumeratorHasItsOwnRow();
  testKindAgreesWithTheAudioClassifiers();
  testCoreMediaTypesRoundTrip();
  testConfigurationRecordShape();
  testDecodeSessionFacts();
  testRouteMemberships();
  testDecoderLeadInFrames();
  if (failures != 0) {
    std::cerr << failures << " media codec facts expectation(s) failed\n";
    return EXIT_FAILURE;
  }
  std::cout << "media codec facts: all expectations passed\n";
  return EXIT_SUCCESS;
}
