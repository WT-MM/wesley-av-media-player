#include "media/subtitle_pgs.hpp"

#include <algorithm>
#include <cstring>
#include <utility>

namespace wam::media::subtitles::pgs {
namespace {

constexpr std::size_t kSegmentHeaderBytes = 3;   // type + u16 size
constexpr std::size_t kSupPrefixBytes = 10;      // "PG" + PTS + DTS

[[nodiscard]] std::uint16_t readU16(const std::uint8_t* p) noexcept {
  return static_cast<std::uint16_t>((static_cast<std::uint16_t>(p[0]) << 8) |
                                    static_cast<std::uint16_t>(p[1]));
}

[[nodiscard]] std::uint32_t readU24(const std::uint8_t* p) noexcept {
  return (static_cast<std::uint32_t>(p[0]) << 16) |
         (static_cast<std::uint32_t>(p[1]) << 8) |
         static_cast<std::uint32_t>(p[2]);
}

[[nodiscard]] std::uint32_t readU32(const std::uint8_t* p) noexcept {
  return (static_cast<std::uint32_t>(p[0]) << 24) |
         (static_cast<std::uint32_t>(p[1]) << 16) |
         (static_cast<std::uint32_t>(p[2]) << 8) |
         static_cast<std::uint32_t>(p[3]);
}

void setError(std::string* error, std::string_view reason) {
  if (error != nullptr && error->empty()) {
    error->assign(reason);
  }
}

[[nodiscard]] std::int64_t timestamp90kToNanoseconds(std::uint32_t ticks) noexcept {
  // Exact: 90 kHz ticks * 100000 / 9 == ticks * 1e9 / 90000, in integers.
  return static_cast<std::int64_t>(ticks) * 100'000 / 9;
}

}  // namespace

bool isKnownSegmentType(std::uint8_t value) noexcept {
  switch (value) {
    case 0x14:
    case 0x15:
    case 0x16:
    case 0x17:
    case 0x80:
      return true;
    default:
      return false;
  }
}

bool parseSegments(std::span<const std::uint8_t> bytes,
                   std::vector<Segment>* out, std::string* error) {
  if (out == nullptr) {
    return false;
  }
  out->clear();
  std::size_t pos = 0;
  while (pos < bytes.size()) {
    if (bytes.size() - pos < kSegmentHeaderBytes) {
      setError(error, "truncated PGS segment header");
      return false;
    }
    const std::uint8_t type = bytes[pos];
    const std::uint16_t size = readU16(bytes.data() + pos + 1);
    if (!isKnownSegmentType(type)) {
      setError(error, "unknown PGS segment type");
      return false;
    }
    const std::size_t body = pos + kSegmentHeaderBytes;
    if (bytes.size() - body < size) {
      setError(error, "truncated PGS segment payload");
      return false;
    }
    Segment segment;
    segment.type = static_cast<SegmentType>(type);
    segment.payload = bytes.subspan(body, size);
    out->push_back(segment);
    pos = body + size;
  }
  return true;
}

bool parseSupStream(std::span<const std::uint8_t> bytes,
                    std::vector<Segment>* out, std::string* error) {
  if (out == nullptr) {
    return false;
  }
  out->clear();
  std::size_t pos = 0;
  while (pos < bytes.size()) {
    if (bytes.size() - pos < kSupPrefixBytes + kSegmentHeaderBytes) {
      setError(error, "truncated .sup segment header");
      return false;
    }
    if (bytes[pos] != 'P' || bytes[pos + 1] != 'G') {
      setError(error, "missing PG magic in .sup stream");
      return false;
    }
    const std::uint32_t pts = readU32(bytes.data() + pos + 2);
    const std::size_t header = pos + kSupPrefixBytes;
    const std::uint8_t type = bytes[header];
    const std::uint16_t size = readU16(bytes.data() + header + 1);
    if (!isKnownSegmentType(type)) {
      setError(error, "unknown PGS segment type");
      return false;
    }
    const std::size_t body = header + kSegmentHeaderBytes;
    if (bytes.size() - body < size) {
      setError(error, "truncated .sup segment payload");
      return false;
    }
    Segment segment;
    segment.type = static_cast<SegmentType>(type);
    segment.payload = bytes.subspan(body, size);
    segment.presentationTimestamp90k = pts;
    out->push_back(segment);
    pos = body + size;
  }
  return true;
}

bool parsePresentationComposition(std::span<const std::uint8_t> payload,
                                  PresentationComposition* out,
                                  std::string* error) {
  if (out == nullptr) {
    return false;
  }
  // width(2) height(2) framerate(1) compositionNumber(2) state(1)
  // paletteUpdate(1) paletteId(1) objectCount(1)
  constexpr std::size_t kFixed = 11;
  if (payload.size() < kFixed) {
    setError(error, "short PGS presentation composition");
    return false;
  }
  *out = PresentationComposition{};
  out->width = readU16(payload.data());
  out->height = readU16(payload.data() + 2);
  // payload[4] is the frame-rate field; the spec fixes it and no decoder uses
  // it, so it is deliberately not surfaced.
  out->compositionNumber = readU16(payload.data() + 5);
  const std::uint8_t state = payload[7];
  switch (state) {
    case 0x00:
      out->state = CompositionState::Normal;
      break;
    case 0x40:
      out->state = CompositionState::AcquisitionPoint;
      break;
    case 0x80:
      out->state = CompositionState::EpochStart;
      break;
    default:
      setError(error, "invalid PGS composition state");
      return false;
  }
  out->paletteUpdate = (payload[8] & 0x80) != 0;
  out->paletteId = payload[9];
  const std::uint8_t count = payload[10];

  std::size_t pos = kFixed;
  out->objects.reserve(count);
  for (std::uint8_t i = 0; i < count; ++i) {
    // objectId(2) windowId(1) flags(1) x(2) y(2) [+ crop rect(8)]
    constexpr std::size_t kObjectFixed = 8;
    if (payload.size() - pos < kObjectFixed) {
      setError(error, "short PGS composition object");
      return false;
    }
    CompositionObject object;
    object.objectId = readU16(payload.data() + pos);
    object.windowId = payload[pos + 2];
    const std::uint8_t flags = payload[pos + 3];
    object.cropped = (flags & 0x80) != 0;
    object.forced = (flags & 0x40) != 0;
    object.x = static_cast<std::int32_t>(readU16(payload.data() + pos + 4));
    object.y = static_cast<std::int32_t>(readU16(payload.data() + pos + 6));
    pos += kObjectFixed;
    if (object.cropped) {
      if (payload.size() - pos < 8) {
        setError(error, "short PGS composition object crop rect");
        return false;
      }
      object.cropX = readU16(payload.data() + pos);
      object.cropY = readU16(payload.data() + pos + 2);
      object.cropWidth = readU16(payload.data() + pos + 4);
      object.cropHeight = readU16(payload.data() + pos + 6);
      pos += 8;
    }
    out->objects.push_back(object);
  }
  return true;
}

bool parseWindowDefinition(std::span<const std::uint8_t> payload,
                           std::vector<WindowRect>* out, std::string* error) {
  if (out == nullptr) {
    return false;
  }
  out->clear();
  if (payload.empty()) {
    setError(error, "empty PGS window definition");
    return false;
  }
  const std::uint8_t count = payload[0];
  std::size_t pos = 1;
  out->reserve(count);
  for (std::uint8_t i = 0; i < count; ++i) {
    // windowId(1) x(2) y(2) width(2) height(2)
    constexpr std::size_t kWindowBytes = 9;
    if (payload.size() - pos < kWindowBytes) {
      setError(error, "short PGS window definition");
      return false;
    }
    WindowRect rect;
    rect.windowId = payload[pos];
    rect.x = readU16(payload.data() + pos + 1);
    rect.y = readU16(payload.data() + pos + 3);
    rect.width = readU16(payload.data() + pos + 5);
    rect.height = readU16(payload.data() + pos + 7);
    out->push_back(rect);
    pos += kWindowBytes;
  }
  return true;
}

bool parsePaletteDefinition(std::span<const std::uint8_t> payload,
                            PaletteDefinition* out, std::string* error) {
  if (out == nullptr) {
    return false;
  }
  if (payload.size() < 2) {
    setError(error, "short PGS palette definition");
    return false;
  }
  *out = PaletteDefinition{};
  out->paletteId = payload[0];
  out->version = payload[1];
  const std::size_t body = payload.size() - 2;
  if (body % 5 != 0) {
    setError(error, "PGS palette definition is not a whole number of entries");
    return false;
  }
  out->entries.reserve(body / 5);
  for (std::size_t pos = 2; pos + 5 <= payload.size(); pos += 5) {
    PaletteEntry entry;
    entry.index = payload[pos];
    entry.y = payload[pos + 1];
    entry.cr = payload[pos + 2];
    entry.cb = payload[pos + 3];
    entry.alpha = payload[pos + 4];
    out->entries.push_back(entry);
  }
  return true;
}

bool parseObjectDefinition(std::span<const std::uint8_t> payload,
                           ObjectDefinition* out, std::string* error) {
  if (out == nullptr) {
    return false;
  }
  // objectId(2) version(1) sequenceFlags(1)
  constexpr std::size_t kFixed = 4;
  if (payload.size() < kFixed) {
    setError(error, "short PGS object definition");
    return false;
  }
  *out = ObjectDefinition{};
  out->objectId = readU16(payload.data());
  out->version = payload[2];
  const std::uint8_t flags = payload[3];
  out->first = (flags & 0x80) != 0;
  out->last = (flags & 0x40) != 0;
  if (!out->first && !out->last && flags != 0x00) {
    setError(error, "invalid PGS object sequence flags");
    return false;
  }
  std::size_t pos = kFixed;
  if (out->first) {
    // dataLength(3) width(2) height(2); dataLength counts width+height too.
    if (payload.size() - pos < 7) {
      setError(error, "short PGS object definition header");
      return false;
    }
    out->declaredDataLength = readU24(payload.data() + pos);
    out->width = readU16(payload.data() + pos + 3);
    out->height = readU16(payload.data() + pos + 5);
    if (out->declaredDataLength < 4) {
      setError(error, "PGS object data length excludes its own dimensions");
      return false;
    }
    pos += 7;
  }
  out->data = payload.subspan(pos);
  return true;
}

bool decodeRunLength(std::span<const std::uint8_t> rle, std::uint32_t width,
                     std::uint32_t height, std::vector<std::uint8_t>* indices,
                     std::string* error) {
  if (indices == nullptr) {
    return false;
  }
  if (width == 0 || height == 0) {
    setError(error, "PGS object has a zero dimension");
    return false;
  }
  const std::size_t pixels =
      static_cast<std::size_t>(width) * static_cast<std::size_t>(height);
  if (pixels > kMaximumBitmapPixels) {
    setError(error, "PGS object exceeds the pixel bound");
    return false;
  }
  try {
    indices->assign(pixels, 0);
  } catch (...) {
    setError(error, "PGS object allocation failed");
    return false;
  }

  std::uint32_t row = 0;
  std::uint32_t col = 0;
  std::size_t pos = 0;
  while (pos < rle.size()) {
    if (row >= height) {
      // Trailing data past the declared height. Real muxes pad; stop cleanly
      // rather than refusing a caption that has already decoded fully.
      break;
    }
    const std::uint8_t first = rle[pos++];
    std::uint32_t run = 1;
    std::uint8_t colour = first;
    if (first != 0x00) {
      // Single pixel of colour `first`; run stays 1.
    } else {
      if (pos >= rle.size()) {
        setError(error, "truncated PGS run-length escape");
        return false;
      }
      const std::uint8_t second = rle[pos++];
      if (second == 0x00) {
        // End of line: pad the remainder with colour 0 and advance.
        ++row;
        col = 0;
        continue;
      }
      const bool longRun = (second & 0x40) != 0;
      const bool coloured = (second & 0x80) != 0;
      run = static_cast<std::uint32_t>(second & 0x3F);
      if (longRun) {
        if (pos >= rle.size()) {
          setError(error, "truncated PGS long run length");
          return false;
        }
        run = (run << 8) | rle[pos++];
      }
      if (coloured) {
        if (pos >= rle.size()) {
          setError(error, "truncated PGS run colour");
          return false;
        }
        colour = rle[pos++];
      } else {
        colour = 0;
      }
      if (run == 0) {
        // A zero-length run carries no pixels and is legal padding.
        continue;
      }
    }

    // Clip rather than refuse: an encoder that emits one pixel too many on a
    // line must not cost the viewer the whole caption.
    const std::uint32_t remaining = width - std::min(col, width);
    const std::uint32_t writeCount = std::min(run, remaining);
    if (writeCount > 0) {
      std::uint8_t* line =
          indices->data() + static_cast<std::size_t>(row) * width + col;
      std::memset(line, colour, writeCount);
    }
    col += run;
    if (col >= width) {
      // The spec requires an explicit end-of-line marker, but a line that fills
      // exactly is also seen; wrapping here keeps both readable.
      col = width;
    }
  }
  return true;
}

// ---------------------------------------------------------------------------

TrackDecoder::TrackDecoder() = default;

void TrackDecoder::noteError(std::string_view reason) {
  if (!errorSet_) {
    error_.assign(reason);
    errorSet_ = true;
  }
}

void TrackDecoder::closeOpenCues(std::int64_t endNanoseconds) {
  for (const std::size_t index : openCues_) {
    if (index < content_.cues.size()) {
      content_.cues[index].endNanoseconds = endNanoseconds;
    }
  }
  openCues_.clear();
}

bool TrackDecoder::appendBlock(std::span<const std::uint8_t> payload,
                               std::int64_t timestampNanoseconds) {
  std::vector<Segment> segments;
  std::string error;
  if (!parseSegments(payload, &segments, &error)) {
    noteError(error);
    return false;
  }
  return applyDisplaySet(segments, timestampNanoseconds);
}

bool TrackDecoder::appendSupStream(std::span<const std::uint8_t> bytes) {
  std::vector<Segment> all;
  std::string error;
  if (!parseSupStream(bytes, &all, &error)) {
    noteError(error);
    return false;
  }
  // Group into display sets on END, timing each set by its first segment's PTS.
  std::vector<Segment> set;
  bool ok = true;
  for (const Segment& segment : all) {
    if (set.empty() && segment.type != SegmentType::End) {
      set.push_back(segment);
      continue;
    }
    set.push_back(segment);
    if (segment.type == SegmentType::End) {
      const std::int64_t when =
          timestamp90kToNanoseconds(set.front().presentationTimestamp90k);
      ok = applyDisplaySet(set, when) && ok;
      set.clear();
    }
  }
  if (!set.empty()) {
    const std::int64_t when =
        timestamp90kToNanoseconds(set.front().presentationTimestamp90k);
    ok = applyDisplaySet(set, when) && ok;
  }
  return ok;
}

bool TrackDecoder::applyDisplaySet(const std::vector<Segment>& segments,
                                   std::int64_t timestampNanoseconds) {
  std::optional<PresentationComposition> composition;

  for (const Segment& segment : segments) {
    std::string error;
    switch (segment.type) {
      case SegmentType::PresentationComposition: {
        PresentationComposition parsed;
        if (!parsePresentationComposition(segment.payload, &parsed, &error)) {
          noteError(error);
          return false;
        }
        if (parsed.state == CompositionState::EpochStart) {
          // A new epoch invalidates every retained object and palette.
          objects_.clear();
          palettes_.clear();
          indexBytes_ = 0;
        }
        if (parsed.width != 0 && parsed.height != 0) {
          content_.canvasWidth = parsed.width;
          content_.canvasHeight = parsed.height;
        }
        composition = std::move(parsed);
        break;
      }
      case SegmentType::WindowDefinition: {
        std::vector<WindowRect> rects;
        if (!parseWindowDefinition(segment.payload, &rects, &error)) {
          noteError(error);
          break;  // windows are advisory; a bad WDS must not lose the caption
        }
        windows_ = std::move(rects);
        break;
      }
      case SegmentType::PaletteDefinition: {
        PaletteDefinition palette;
        if (!parsePaletteDefinition(segment.payload, &palette, &error)) {
          noteError(error);
          break;
        }
        auto it = std::find_if(palettes_.begin(), palettes_.end(),
                               [&](const auto& entry) {
                                 return entry.first == palette.paletteId;
                               });
        if (it == palettes_.end()) {
          palettes_.emplace_back(palette.paletteId, BitmapPalette{});
          it = std::prev(palettes_.end());
          // Entries never sent are fully transparent, which a zeroed palette
          // already is (alpha byte 0).
        }
        for (const PaletteEntry& entry : palette.entries) {
          it->second[entry.index] =
              ycrcbToArgb(entry.y, entry.cr, entry.cb, entry.alpha);
        }
        break;
      }
      case SegmentType::ObjectDefinition: {
        ObjectDefinition object;
        if (!parseObjectDefinition(segment.payload, &object, &error)) {
          noteError(error);
          break;
        }
        auto it = std::find_if(
            objects_.begin(), objects_.end(),
            [&](const auto& entry) { return entry.first == object.objectId; });
        if (object.first) {
          if (it == objects_.end()) {
            objects_.emplace_back(object.objectId, ObjectState{});
            it = std::prev(objects_.end());
          }
          it->second = ObjectState{};
          it->second.width = object.width;
          it->second.height = object.height;
          it->second.declaredDataLength = object.declaredDataLength;
        } else if (it == objects_.end()) {
          noteError("PGS object continuation without a first segment");
          break;
        }
        ObjectState& state = it->second;
        const std::size_t pixels = static_cast<std::size_t>(state.width) *
                                   static_cast<std::size_t>(state.height);
        if (pixels == 0 || pixels > kMaximumBitmapPixels) {
          noteError("PGS object exceeds the pixel bound");
          state.complete = false;
          break;
        }
        // Bound the accumulated run-length data by the declared length so a
        // corrupt stream cannot grow this without limit.
        const std::size_t declaredRle =
            state.declaredDataLength >= 4
                ? static_cast<std::size_t>(state.declaredDataLength) - 4
                : 0;
        if (state.data.size() + object.data.size() > declaredRle) {
          const std::size_t room =
              declaredRle > state.data.size() ? declaredRle - state.data.size()
                                              : 0;
          state.data.insert(state.data.end(), object.data.begin(),
                            object.data.begin() +
                                static_cast<std::ptrdiff_t>(
                                    std::min(room, object.data.size())));
          noteError("PGS object data exceeds its declared length");
        } else {
          state.data.insert(state.data.end(), object.data.begin(),
                            object.data.end());
        }
        state.complete = object.last;
        break;
      }
      case SegmentType::End:
        break;
    }
  }

  if (!composition.has_value()) {
    // A display set with no PCS changes nothing on screen; palettes and objects
    // it carried are already retained above.
    return true;
  }

  // Any composition supersedes what is on screen.
  closeOpenCues(timestampNanoseconds);
  openSince_ = timestampNanoseconds;
  if (composition->objects.empty()) {
    return true;  // a clear
  }

  const BitmapPalette* palette = nullptr;
  for (const auto& entry : palettes_) {
    if (entry.first == composition->paletteId) {
      palette = &entry.second;
      break;
    }
  }
  if (palette == nullptr) {
    noteError("PGS composition references an undefined palette");
    return true;
  }

  for (const CompositionObject& object : composition->objects) {
    if (content_.cues.size() >= kMaximumBitmapCues ||
        indexBytes_ >= kMaximumBitmapIndexBytes) {
      content_.truncated = true;
      break;
    }
    auto it = std::find_if(
        objects_.begin(), objects_.end(),
        [&](const auto& entry) { return entry.first == object.objectId; });
    if (it == objects_.end() || !it->second.complete) {
      noteError("PGS composition references an undefined object");
      continue;
    }
    const ObjectState& state = it->second;

    BitmapCue cue;
    cue.startNanoseconds = timestampNanoseconds;
    // Left open; closed by the next composition or by finish().
    cue.endNanoseconds = timestampNanoseconds;
    cue.x = object.x;
    cue.y = object.y;
    cue.forced = object.forced;
    cue.image.width = state.width;
    cue.image.height = state.height;
    cue.image.palette = *palette;
    std::string error;
    if (!decodeRunLength(state.data, state.width, state.height,
                         &cue.image.indices, &error)) {
      noteError(error);
      continue;
    }
    if (object.cropped && object.cropWidth != 0 && object.cropHeight != 0) {
      // Cropping selects a sub-rectangle of the object for display. Rare, but
      // legal, and silently ignoring it would show the wrong pixels.
      const std::uint32_t cx = std::min<std::uint32_t>(object.cropX, state.width);
      const std::uint32_t cy =
          std::min<std::uint32_t>(object.cropY, state.height);
      const std::uint32_t cw =
          std::min<std::uint32_t>(object.cropWidth, state.width - cx);
      const std::uint32_t ch =
          std::min<std::uint32_t>(object.cropHeight, state.height - cy);
      if (cw != 0 && ch != 0) {
        std::vector<std::uint8_t> cropped(static_cast<std::size_t>(cw) * ch, 0);
        for (std::uint32_t row = 0; row < ch; ++row) {
          std::memcpy(cropped.data() + static_cast<std::size_t>(row) * cw,
                      cue.image.indices.data() +
                          static_cast<std::size_t>(row + cy) * state.width + cx,
                      cw);
        }
        cue.image.indices = std::move(cropped);
        cue.image.width = cw;
        cue.image.height = ch;
      }
    }
    if (isFullyTransparent(cue.image)) {
      continue;  // an invisible composition is not a caption
    }
    cropToOpaqueBounds(&cue);
    indexBytes_ += cue.image.indices.size();
    content_.cues.push_back(std::move(cue));
    openCues_.push_back(content_.cues.size() - 1);
  }
  return true;
}

BitmapSubtitleContent TrackDecoder::finish(std::int64_t endNanoseconds) {
  if (!openCues_.empty()) {
    if (endNanoseconds > openSince_) {
      closeOpenCues(endNanoseconds);
    } else {
      // Nothing ever closed these and the caller gave no usable end. Report
      // rather than inventing a duration.
      content_.skippedWithoutDuration +=
          static_cast<std::uint32_t>(openCues_.size());
      openCues_.clear();
    }
  }
  finalizeBitmapCues(&content_.cues);
  content_.error = error_;
  return std::move(content_);
}

}  // namespace wam::media::subtitles::pgs
