#include "platform/macos/mpegts_sample_builder.hpp"

#include "media/codec/ac3.hpp"
#include "media/codec/mpeg_audio.hpp"
#include "media/mpegts_packet.hpp"

#import <CoreMedia/CoreMedia.h>

#include <limits>
#include <numeric>

namespace wam::macos {
namespace {

using media::MediaCodec;
using media::codec::Ac3SyncFrame;
using media::codec::MpegAudioFrame;
using media::MediaCodecConfigurationKind;
using media::MediaTime;
using media::MediaTimeOrder;
using media::MediaTrackDescriptor;
using media::MediaTrackKind;
using media::mpegts::AdtsHeader;
using media::mpegts::MpegTsCompressedSample;
using media::MediaRefusalClass;

}  // namespace

bool layOutMpegTsAudioFrames(
    std::span<const std::byte> payload, MediaCodec codec,
    const media::mpegts::LatmStreamMuxConfig* latmConfig,
    std::uint32_t sampleRate, std::uint32_t channels,
    std::uint32_t framesPerPacket, MpegTsAudioFrameLayout& layout,
    std::string* error) noexcept {
  layout.reset();
  if (payload.empty() || sampleRate == 0 || channels == 0 ||
      framesPerPacket == 0) {
    assignError(error, "mpeg-ts audio payload has no admitted frame grid");
    return false;
  }
  std::size_t cursor = 0;
  while (cursor < payload.size()) {
    const std::span<const std::byte> rest = payload.subspan(cursor);
    std::uint32_t frameBytes = 0;
    std::uint32_t headerBytes = 0;
    std::uint32_t rate = 0;
    std::uint32_t frameChannels = 0;
    std::uint32_t decoded = 0;
    // Where this access unit begins inside `rest`, as a byte and a bit. Every
    // byte-aligned framing leaves the shift at zero and the offset at its
    // header length.
    std::uint32_t payloadOffset = 0;
    std::uint32_t payloadBitShift = 0;
    std::uint32_t payloadBytes = 0;
    if (codec == MediaCodec::Aac && latmConfig != nullptr) {
      media::mpegts::LatmFrame frame{};
      const media::mpegts::LatmStatus status =
          media::mpegts::parseLatmFrame(rest, latmConfig, frame);
      if (status != media::mpegts::LatmStatus::Ok) {
        // Named, not swallowed. A `break` here would fall through to the
        // "does not divide into whole access units" refusal below and lose
        // which of the six LATM verdicts actually fired -- the difference
        // between a truncated PES, a mid-stream mux change and a config this
        // route does not carry.
        if (status == media::mpegts::LatmStatus::NotSynced && cursor > 0) {
          break;  // trailing bytes: the remainder check below rules on them
        }
        const std::string reason =
            std::string("mpeg-ts LOAS/LATM frame refused: ") +
            media::mpegts::latmStatusName(status);
        assignError(error, reason.c_str());
        layout.reset();
        return false;
      }
      // A StreamMuxConfig restated mid-stream must describe the SAME decoder.
      // The ADTS path makes the identical check against every frame's header;
      // this is that check, against the only place LATM states it.
      if (frame.configPresent && !frame.config.sameDecoder(*latmConfig)) {
        assignError(error,
                    "mpeg-ts LOAS/LATM StreamMuxConfig changes mid-stream");
        layout.reset();
        return false;
      }
      frameBytes = frame.frameBytes;
      payloadOffset = frame.payloadBitOffset / 8U;
      payloadBitShift = frame.payloadBitOffset % 8U;
      payloadBytes = frame.payloadBytes;
      headerBytes = 0;  // not a byte-aligned prefix; see payloadOffset
      rate = frame.config.sampleRate;
      frameChannels = frame.config.channelConfiguration;
      decoded = framesPerPacket;
    } else if (codec == MediaCodec::Aac) {
      AdtsHeader header{};
      if (!media::mpegts::parseAdtsHeader(rest, header)) {
        break;
      }
      frameBytes = header.frameBytes;
      // The ADTS header is stripped: the converter was configured from the
      // ES_Descriptor magic cookie the demuxer synthesized, and a cookie-bearing
      // AAC decoder expects raw access units, not re-framed ones.
      headerBytes = header.headerBytes;
      rate = header.sampleRate;
      frameChannels = header.channelConfiguration;
      decoded = framesPerPacket;
    } else if (codec == MediaCodec::Ac3 || codec == MediaCodec::Eac3) {
      Ac3SyncFrame frame{};
      if (media::codec::readAc3SyncframeHeader(rest, frame) !=
          media::codec::Ac3AdmissionError::None) {
        break;
      }
      frameBytes = frame.frameBytes;
      headerBytes = 0;
      rate = frame.sampleRate;
      // `channels` already includes LFE; do not add it again.
      frameChannels = frame.channels;
      decoded = frame.samplesPerFrame;
    } else if (codec == MediaCodec::Mp3) {
      MpegAudioFrame frame{};
      if (media::codec::readMpegAudioFrameHeader(rest, frame) !=
          media::codec::MpegAudioAdmissionError::None) {
        break;
      }
      frameBytes = frame.frameBytes;
      headerBytes = 0;
      rate = frame.sampleRate;
      frameChannels = frame.channels;
      decoded = frame.samplesPerFrame;
    } else {
      assignError(error, "mpeg-ts audio codec has no admitted framing");
      return false;
    }

    if (frameBytes == 0 || frameBytes > rest.size() ||
        headerBytes >= frameBytes) {
      break;
    }
    // The byte-aligned framings state their access unit as "the frame minus a
    // header"; LATM stated it explicitly above. Normalize to one shape so the
    // copy has a single rule.
    if (payloadBytes == 0) {
      payloadOffset = headerBytes;
      payloadBytes = frameBytes - headerBytes;
    }
    // The access unit, including the trailing byte a nonzero shift straddles
    // into, must lie inside the frame this iteration claimed.
    const std::uint64_t lastSourceByte =
        static_cast<std::uint64_t>(payloadOffset) + payloadBytes +
        (payloadBitShift != 0U ? 1U : 0U);
    if (payloadBytes == 0 || lastSourceByte > frameBytes) {
      break;
    }
    // Every access unit in one generation must restate the SAME format. A
    // mid-stream rate or channel change is a format change this backend does
    // not implement, and letting one through would publish PCM the converter's
    // ASBD does not describe.
    if (rate != sampleRate || frameChannels != channels ||
        decoded != framesPerPacket) {
      assignError(error,
                  "mpeg-ts audio access unit changes its format mid-stream");
      return false;
    }
    if (layout.count >= kMaximumMpegTsAudioFrames) {
      assignError(error, "mpeg-ts PES carries more access units than admitted");
      return false;
    }
    layout.sourceOffset[layout.count] = static_cast<std::uint32_t>(cursor);
    layout.sourceSize[layout.count] = frameBytes;
    layout.outputSize[layout.count] = payloadBytes;
    layout.outputOffset[layout.count] =
        static_cast<std::uint32_t>(cursor) + payloadOffset;
    layout.outputBitShift[layout.count] =
        static_cast<std::uint8_t>(payloadBitShift);
    layout.outputBytes += payloadBytes;
    layout.decodedFrames += framesPerPacket;
    ++layout.count;
    cursor += frameBytes;
  }
  if (layout.count == 0 || cursor != payload.size()) {
    // See the header: a trailing remainder is refused rather than dropped.
    assignError(error,
                "mpeg-ts audio PES does not divide into whole access units");
    layout.reset();
    return false;
  }
  return true;
}

MpegTsSampleBuildStatus buildMpegTsCompressedSampleBuffer(
    const MpegTsSampleBuildInputs& inputs, const MpegTsCompressedSample& sample,
    ScopedSampleBuffer* out, std::string* error) {
  if (out == nullptr || inputs.asset == nullptr || inputs.format == nullptr) {
    assignError(error, "mpeg-ts sample factory has no admitted format");
    return MpegTsSampleBuildStatus::Failed;
  }
  const std::size_t payloadBytes = sample.payloadBytes;
  if (payloadBytes == 0) {
    assignError(error, "mpeg-ts access unit is empty");
    return MpegTsSampleBuildStatus::Failed;
  }

  CMBlockBufferRef block = nullptr;
  std::span<std::byte> destination;
  CMItemCount numSamples = 1;
  CMItemCount sizeEntries = 1;
  std::array<std::size_t, 1> videoSizes{};
  const std::size_t* sizePointer = nullptr;

  if (inputs.video && (inputs.codec == MediaCodec::H264 ||
                       inputs.codec == MediaCodec::Hevc)) {
    // The one seam that costs an extra copy. Annex-B to AVCC cannot know its
    // output size until the input is assembled -- a three-byte start code
    // grows by one byte and a four-byte one does not -- so the gather lands in
    // a reusable workspace and the repack writes straight into the CoreMedia
    // block. That is two payload copies per video sample against Matroska's
    // one. The available optimization (when every start code is four bytes the
    // sizes are equal and the gather could go straight into the block) is
    // deliberately NOT taken because it is unmeasured: page residency, not
    // staging shape, dominates this cost.
    if (inputs.workspace == nullptr) {
      assignError(error, "mpeg-ts video repack has no workspace");
      return MpegTsSampleBuildStatus::Failed;
    }
    std::vector<std::byte>& workspace = *inputs.workspace;
    if (workspace.size() < payloadBytes) {
      workspace.resize(payloadBytes);
    }
    const std::span<std::byte> gathered(workspace.data(), payloadBytes);
    MediaRefusalClass copyError = MediaRefusalClass::None;
    if (!inputs.asset->copyAccessUnit(sample, gathered, inputs.cancellation,
                                      &copyError)) {
      if (copyError == MediaRefusalClass::Cancelled) {
        return MpegTsSampleBuildStatus::Cancelled;
      }
      if (error != nullptr) {
        *error = media::refusalMessage("mpeg-ts payload gather failed",
                                         copyError);
      }
      return MpegTsSampleBuildStatus::Failed;
    }
    const std::size_t repacked =
        media::mpegts::annexBToAvccSize(gathered, inputs.codec);
    if (repacked == 0) {
      assignError(error, "mpeg-ts access unit holds no complete NAL unit");
      return MpegTsSampleBuildStatus::Failed;
    }
    if (!allocateSampleBlock(repacked, "mpeg-ts", &block, &destination, error)) {
      return MpegTsSampleBuildStatus::Failed;
    }
    if (media::mpegts::annexBToAvcc(gathered, destination, inputs.codec) !=
        repacked) {
      CFRelease(block);
      assignError(error, "mpeg-ts Annex-B to AVCC repack refused the unit");
      return MpegTsSampleBuildStatus::Failed;
    }
    videoSizes[0] = repacked;
    sizePointer = videoSizes.data();
  } else if (inputs.video) {
    // MPEG-2 needs no repack at all: the elementary stream bytes ARE what the
    // decoder wants, start codes included, so the gather goes straight into the
    // block and this path costs exactly one copy.
    if (!allocateSampleBlock(payloadBytes, "mpeg-ts", &block, &destination, error)) {
      return MpegTsSampleBuildStatus::Failed;
    }
    MediaRefusalClass copyError = MediaRefusalClass::None;
    if (!inputs.asset->copyAccessUnit(sample, destination, inputs.cancellation,
                                      &copyError)) {
      CFRelease(block);
      if (copyError == MediaRefusalClass::Cancelled) {
        return MpegTsSampleBuildStatus::Cancelled;
      }
      if (error != nullptr) {
        *error = media::refusalMessage("mpeg-ts payload gather failed",
                                         copyError);
      }
      return MpegTsSampleBuildStatus::Failed;
    }
    videoSizes[0] = payloadBytes;
    sizePointer = videoSizes.data();
  } else {
    if (inputs.audioLayout == nullptr || inputs.workspace == nullptr) {
      assignError(error, "mpeg-ts audio framing has no workspace");
      return MpegTsSampleBuildStatus::Failed;
    }
    std::vector<std::byte>& workspace = *inputs.workspace;
    if (workspace.size() < payloadBytes) {
      workspace.resize(payloadBytes);
    }
    const std::span<std::byte> gathered(workspace.data(), payloadBytes);
    MediaRefusalClass copyError = MediaRefusalClass::None;
    if (!inputs.asset->copyAccessUnit(sample, gathered, inputs.cancellation,
                                      &copyError)) {
      if (copyError == MediaRefusalClass::Cancelled) {
        return MpegTsSampleBuildStatus::Cancelled;
      }
      if (error != nullptr) {
        *error = media::refusalMessage("mpeg-ts payload gather failed",
                                         copyError);
      }
      return MpegTsSampleBuildStatus::Failed;
    }
    MpegTsAudioFrameLayout& layout = *inputs.audioLayout;
    if (!layOutMpegTsAudioFrames(gathered, inputs.codec, inputs.latmConfig,
                                 inputs.audioSampleRate, inputs.audioChannels,
                                 inputs.audioFramesPerPacket, layout, error)) {
      return MpegTsSampleBuildStatus::Failed;
    }
    if (!allocateSampleBlock(layout.outputBytes, "mpeg-ts", &block, &destination,
                             error)) {
      return MpegTsSampleBuildStatus::Failed;
    }
    std::size_t written = 0;
    for (std::size_t index = 0; index < layout.count; ++index) {
      const std::byte* source = gathered.data() + layout.outputOffset[index];
      const std::uint32_t shift = layout.outputBitShift[index];
      if (shift == 0) {
        std::memcpy(destination.data() + written, source,
                    layout.outputSize[index]);
      } else {
        // LOAS/LATM only. Each output byte is the low (8 - shift) bits of one
        // source byte followed by the high `shift` bits of the next; the layout
        // proved the extra byte is inside the frame. This is the ONE place the
        // TS route touches audio payload bits, and it is the price of a framing
        // that does not byte-align its access units.
        const std::uint32_t low = 8U - shift;
        for (std::size_t i = 0; i < layout.outputSize[index]; ++i) {
          const auto high = static_cast<std::uint32_t>(
              static_cast<unsigned char>(source[i]));
          const auto rest = static_cast<std::uint32_t>(
              static_cast<unsigned char>(source[i + 1]));
          destination[written + i] = static_cast<std::byte>(
              ((high << shift) | (rest >> low)) & 0xFFU);
        }
      }
      written += layout.outputSize[index];
    }
    numSamples = static_cast<CMItemCount>(layout.count);
    sizeEntries = numSamples;
    sizePointer = layout.outputSize.data();
  }

  CMSampleTimingInfo timing{};
  const MediaTime presentation =
      inputs.video ? sample.presentationTime : inputs.audioPresentationTime;
  if (!presentation.valid()) {
    CFRelease(block);
    assignError(error, "mpeg-ts sample has no exact presentation time");
    return MpegTsSampleBuildStatus::Failed;
  }
  timing.presentationTimeStamp =
      CMTimeMake(presentation.value, presentation.timescale);
  if (inputs.video) {
    // TS carries a REAL decode timestamp. Stating it is the whole difference
    // from the Matroska carriage, which must leave this invalid because
    // Matroska has no DTS and the demuxer refuses to invent one.
    timing.decodeTimeStamp =
        sample.decodeTime.valid()
            ? CMTimeMake(sample.decodeTime.value, sample.decodeTime.timescale)
            : kCMTimeInvalid;
    timing.duration = sample.duration.valid()
                          ? CMTimeMake(sample.duration.value,
                                       sample.duration.timescale)
                          : kCMTimeInvalid;
  } else {
    timing.decodeTimeStamp = kCMTimeInvalid;
    // One timing entry whose duration is a single access unit. CoreMedia then
    // derives each unit's own stamp, which is what the converter's per-packet
    // timeline walk validates against the packet frame counts.
    timing.duration =
        CMTimeMake(static_cast<std::int64_t>(inputs.audioFramesPerPacket),
                   static_cast<std::int32_t>(inputs.audioSampleRate));
  }

  CompressedSampleShape shape;
  shape.timing = timing;
  shape.sampleCount = numSamples;
  shape.sizeEntryCount = sizeEntries;
  shape.sizes = sizePointer;
  if (inputs.video) {
    // Transport Stream states no per-sample keyframe flag, so `keyFrame` here
    // is the demuxer's bitstream verdict corroborated by the adaptation
    // field's random_access_indicator -- not a container claim.
    shape.videoKeyFrame = sample.keyFrame;
  }
  if (!buildCompressedSampleBuffer(block, inputs.format, shape, "mpeg-ts",
                                   out, error)) {
    return MpegTsSampleBuildStatus::Failed;
  }
  return MpegTsSampleBuildStatus::Built;
}

}  // namespace wam::macos
