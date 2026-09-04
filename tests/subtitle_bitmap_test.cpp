#include "media/subtitle_bitmap.hpp"
#include "media/subtitle_pgs.hpp"
#include "media/subtitle_vobsub.hpp"

#include <cstdlib>
#include <iostream>
#include <string>
#include <vector>

namespace {

using namespace wam::media::subtitles;

int failures = 0;

void expect(bool condition, const char* message) {
  if (!condition) {
    std::cerr << "FAIL: " << message << '\n';
    ++failures;
  }
}

template <typename T>
void expectEqual(T actual, T expected, const char* message) {
  if (actual != expected) {
    std::cerr << "FAIL: " << message << "\n  expected [" << +expected
              << "]\n  actual   [" << +actual << "]\n";
    ++failures;
  }
}

constexpr std::int64_t kSecond = 1'000'000'000;

// ---------------------------------------------------------------------------
// Fixture builders. Every fixture is assembled from the byte layout the format
// specifies, so a test failure names a real disagreement with the format rather
// than with another copy of our own parser.
// ---------------------------------------------------------------------------

void appendU16(std::vector<std::uint8_t>& out, std::uint16_t value) {
  out.push_back(static_cast<std::uint8_t>(value >> 8));
  out.push_back(static_cast<std::uint8_t>(value & 0xFF));
}

void appendSegment(std::vector<std::uint8_t>& out, std::uint8_t type,
                   const std::vector<std::uint8_t>& payload) {
  out.push_back(type);
  appendU16(out, static_cast<std::uint16_t>(payload.size()));
  out.insert(out.end(), payload.begin(), payload.end());
}

// A PGS presentation composition placing one object.
std::vector<std::uint8_t> pcsPayload(std::uint16_t width, std::uint16_t height,
                                     std::uint16_t compositionNumber,
                                     std::uint8_t state, std::uint8_t paletteId,
                                     bool withObject, std::uint16_t objectId,
                                     bool forced, std::uint16_t x,
                                     std::uint16_t y) {
  std::vector<std::uint8_t> p;
  appendU16(p, width);
  appendU16(p, height);
  p.push_back(0x10);  // frame-rate field
  appendU16(p, compositionNumber);
  p.push_back(state);
  p.push_back(0x00);  // no palette update
  p.push_back(paletteId);
  p.push_back(withObject ? 1 : 0);
  if (withObject) {
    appendU16(p, objectId);
    p.push_back(0);  // window id
    p.push_back(forced ? 0x40 : 0x00);
    appendU16(p, x);
    appendU16(p, y);
  }
  return p;
}

std::vector<std::uint8_t> wdsPayload(std::uint16_t x, std::uint16_t y,
                                     std::uint16_t width, std::uint16_t height) {
  std::vector<std::uint8_t> p{1, 0};
  appendU16(p, x);
  appendU16(p, y);
  appendU16(p, width);
  appendU16(p, height);
  return p;
}

// One opaque white entry at index 1, plus an opaque red entry at index 2.
std::vector<std::uint8_t> pdsPayload(std::uint8_t paletteId) {
  std::vector<std::uint8_t> p{paletteId, 0};
  const std::uint8_t entries[][5] = {
      {1, 235, 128, 128, 255},  // white, fully opaque
      {2, 82, 240, 90, 255},    // red-ish, fully opaque
  };
  for (const auto& e : entries) {
    for (std::uint8_t b : e) {
      p.push_back(b);
    }
  }
  return p;
}

std::vector<std::uint8_t> odsPayload(std::uint16_t objectId,
                                     std::uint16_t width, std::uint16_t height,
                                     const std::vector<std::uint8_t>& rle,
                                     std::uint8_t sequenceFlags = 0xC0) {
  std::vector<std::uint8_t> p;
  appendU16(p, objectId);
  p.push_back(0);  // version
  p.push_back(sequenceFlags);
  if ((sequenceFlags & 0x80) != 0) {
    const std::uint32_t length = static_cast<std::uint32_t>(rle.size()) + 4;
    p.push_back(static_cast<std::uint8_t>((length >> 16) & 0xFF));
    p.push_back(static_cast<std::uint8_t>((length >> 8) & 0xFF));
    p.push_back(static_cast<std::uint8_t>(length & 0xFF));
    appendU16(p, width);
    appendU16(p, height);
  }
  p.insert(p.end(), rle.begin(), rle.end());
  return p;
}

// A 2x2 object entirely of colour 1, encoded as single-pixel codes.
std::vector<std::uint8_t> rle2x2Colour1() {
  return {0x01, 0x01, 0x00, 0x00, 0x01, 0x01, 0x00, 0x00};
}

// A whole "show" display set for a 2x2 white object at (5,7) on a 100x50 canvas.
std::vector<std::uint8_t> pgsShowBlock(bool forced = false,
                                       std::uint8_t state = 0x80) {
  std::vector<std::uint8_t> block;
  appendSegment(block, 0x16,
                pcsPayload(100, 50, 0, state, 0, true, 0, forced, 5, 7));
  appendSegment(block, 0x17, wdsPayload(5, 7, 2, 2));
  appendSegment(block, 0x14, pdsPayload(0));
  appendSegment(block, 0x15, odsPayload(0, 2, 2, rle2x2Colour1()));
  appendSegment(block, 0x80, {});
  return block;
}

std::vector<std::uint8_t> pgsClearBlock() {
  std::vector<std::uint8_t> block;
  appendSegment(block, 0x16, pcsPayload(100, 50, 1, 0x00, 0, false, 0, false, 0, 0));
  appendSegment(block, 0x80, {});
  return block;
}

// ---------------------------------------------------------------------------

void testCodecIdentification() {
  expect(bitmapCodecFromMatroskaCodecId("S_HDMV/PGS") == BitmapCodec::HdmvPgs,
         "S_HDMV/PGS is PGS");
  expect(bitmapCodecFromMatroskaCodecId("S_VOBSUB") == BitmapCodec::VobSub,
         "S_VOBSUB is VobSub");
  // The two tables must stay disjoint: a track is text or bitmap, never both.
  expect(bitmapCodecFromMatroskaCodecId("S_TEXT/UTF8") == BitmapCodec::Unknown,
         "SubRip is not a bitmap codec");
  expect(bitmapCodecFromMatroskaCodecId("S_TEXT/ASS") == BitmapCodec::Unknown,
         "ASS is not a bitmap codec");
  expect(bitmapCodecFromMatroskaCodecId("") == BitmapCodec::Unknown,
         "an empty CodecID is not a bitmap codec");
  expect(bitmapCodecFromMatroskaCodecId("s_hdmv/pgs") == BitmapCodec::Unknown,
         "Matroska CodecIDs are case-sensitive");
  // Real muxes NUL-pad string elements; the padding must not defeat the match.
  expect(bitmapCodecFromMatroskaCodecId(std::string_view("S_VOBSUB\0", 9)) ==
             BitmapCodec::VobSub,
         "a NUL-padded CodecID still matches");
  expect(isBitmapCodec(BitmapCodec::HdmvPgs), "PGS is a bitmap codec");
  expect(!isBitmapCodec(BitmapCodec::Unknown), "Unknown is not a bitmap codec");
  expect(bitmapCodecName(BitmapCodec::HdmvPgs) == "PGS", "PGS is named");
  expect(bitmapCodecName(BitmapCodec::VobSub) == "VobSub", "VobSub is named");
}

void testColourConversion() {
  // BT.601 limited range: Y=235 with neutral chroma is white, Y=16 is black.
  const std::uint32_t white = ycrcbToArgb(235, 128, 128, 255);
  expectEqual<std::uint32_t>(white, 0xFFFFFFFFU, "Y=235 neutral is opaque white");
  const std::uint32_t black = ycrcbToArgb(16, 128, 128, 255);
  expectEqual<std::uint32_t>(black, 0xFF000000U, "Y=16 neutral is opaque black");
  // Alpha is carried through untouched, never premultiplied into the colour.
  const std::uint32_t half = ycrcbToArgb(235, 128, 128, 128);
  expectEqual<std::uint32_t>(half, 0x80FFFFFFU, "alpha is straight, not premultiplied");
  // Out-of-gamut input clamps instead of wrapping.
  const std::uint32_t clamped = ycrcbToArgb(255, 255, 0, 255);
  expect((clamped & 0x00FF0000U) == 0x00FF0000U, "red clamps to 255, not wraps");
}

void testImageHelpers() {
  BitmapImage image;
  image.width = 2;
  image.height = 2;
  image.indices = {0, 1, 1, 0};
  image.palette[0] = 0x00000000;  // transparent
  image.palette[1] = 0xFF00FF00;  // opaque green
  expect(image.consistent(), "a 2x2 image with four indices is consistent");
  expect(!isFullyTransparent(image), "an image with an opaque pixel is visible");

  std::vector<std::uint32_t> bgra;
  expect(expandToBgra(image, &bgra), "expansion succeeds");
  expectEqual<std::size_t>(bgra.size(), 4, "expansion yields one word per pixel");
  expectEqual<std::uint32_t>(bgra[0], 0x00000000U, "index 0 expands transparent");
  expectEqual<std::uint32_t>(bgra[1], 0xFF00FF00U, "index 1 expands green");

  BitmapImage blank = image;
  blank.indices = {0, 0, 0, 0};
  expect(isFullyTransparent(blank), "an all-index-0 image is fully transparent");

  // An image whose palette has no opaque entry is transparent whatever the
  // indices say -- this is the case a zeroed PGS palette produces.
  BitmapImage unpainted = image;
  unpainted.palette[1] = 0x00FFFFFF;
  expect(isFullyTransparent(unpainted),
         "an image with a fully transparent palette is invisible");

  BitmapImage inconsistent;
  inconsistent.width = 4;
  inconsistent.height = 4;
  inconsistent.indices = {0, 1};
  expect(!inconsistent.consistent(), "a short index plane is inconsistent");
  std::vector<std::uint32_t> unused;
  expect(!expandToBgra(inconsistent, &unused),
         "expansion refuses an inconsistent image");
}

void testCropToOpaqueBounds() {
  BitmapCue cue;
  cue.x = 100;
  cue.y = 200;
  cue.image.width = 4;
  cue.image.height = 4;
  cue.image.palette[0] = 0x00000000;
  cue.image.palette[1] = 0xFFFFFFFF;
  // A single opaque pixel at column 2, row 1.
  cue.image.indices = {0, 0, 0, 0,
                       0, 0, 1, 0,
                       0, 0, 0, 0,
                       0, 0, 0, 0};
  expect(cropToOpaqueBounds(&cue), "a mostly-empty image crops");
  expectEqual<std::uint32_t>(cue.image.width, 1, "crop width is the opaque box");
  expectEqual<std::uint32_t>(cue.image.height, 1, "crop height is the opaque box");
  // The origin must move by exactly as much as was trimmed, or the caption
  // lands in the wrong place on screen.
  expectEqual<std::int32_t>(cue.x, 102, "crop shifts x by the trimmed columns");
  expectEqual<std::int32_t>(cue.y, 201, "crop shifts y by the trimmed rows");
  expectEqual<std::uint8_t>(cue.image.indices[0], 1, "the opaque pixel survives");

  // An already-tight image is left alone, origin included.
  BitmapCue tight;
  tight.x = 7;
  tight.image.width = 1;
  tight.image.height = 1;
  tight.image.indices = {1};
  tight.image.palette[1] = 0xFFFFFFFF;
  expect(!cropToOpaqueBounds(&tight), "a tight image does not crop");
  expectEqual<std::int32_t>(tight.x, 7, "a tight image keeps its origin");
}

// ---------------------------------------------------------------------------
// PGS
// ---------------------------------------------------------------------------

void testPgsSegmentFraming() {
  const std::vector<std::uint8_t> block = pgsShowBlock();
  std::vector<pgs::Segment> segments;
  std::string error;
  expect(pgs::parseSegments(block, &segments, &error), "a display set parses");
  expectEqual<std::size_t>(segments.size(), 5, "five segments in a display set");
  expect(segments[0].type == pgs::SegmentType::PresentationComposition,
         "the first segment is the composition");
  expect(segments[4].type == pgs::SegmentType::End, "the last segment is END");

  // A segment whose declared size runs past the buffer must be refused, not
  // read past: this is the bounds check that matters most.
  // Drop the zero-length END segment (3 bytes) plus one byte of the object's
  // payload, so the last segment's declared size overruns the buffer.
  std::vector<std::uint8_t> truncated = block;
  truncated.resize(truncated.size() - 4);
  segments.clear();
  error.clear();
  expect(!pgs::parseSegments(truncated, &segments, &error),
         "a truncated segment payload is refused");
  expect(!error.empty(), "truncation reports a reason");

  // An unknown type has no known length rule, so the run cannot be walked.
  std::vector<std::uint8_t> bogus{0x99, 0x00, 0x00};
  segments.clear();
  expect(!pgs::parseSegments(bogus, &segments, &error),
         "an unknown segment type is refused");
  expect(pgs::isKnownSegmentType(0x14) && pgs::isKnownSegmentType(0x80),
         "PDS and END are known types");
  expect(!pgs::isKnownSegmentType(0x00), "0x00 is not a segment type");
}

void testPgsCompositionParsing() {
  const std::vector<std::uint8_t> payload =
      pcsPayload(1920, 1080, 7, 0x80, 3, true, 42, true, 300, 900);
  pgs::PresentationComposition parsed;
  std::string error;
  expect(pgs::parsePresentationComposition(payload, &parsed, &error),
         "a composition parses");
  expectEqual<std::uint16_t>(parsed.width, 1920, "canvas width");
  expectEqual<std::uint16_t>(parsed.height, 1080, "canvas height");
  expectEqual<std::uint16_t>(parsed.compositionNumber, 7, "composition number");
  expect(parsed.state == pgs::CompositionState::EpochStart, "epoch start state");
  expectEqual<std::uint8_t>(parsed.paletteId, 3, "palette id");
  expectEqual<std::size_t>(parsed.objects.size(), 1, "one composition object");
  expectEqual<std::uint16_t>(parsed.objects[0].objectId, 42, "object id");
  // The forced flag is bit 0x40, NOT 0x80 (which is the crop flag). Getting
  // these two backwards would silently force every cropped caption on.
  expect(parsed.objects[0].forced, "flag 0x40 is the forced flag");
  expect(!parsed.objects[0].cropped, "flag 0x40 is not the crop flag");
  expectEqual<std::int32_t>(parsed.objects[0].x, 300, "object x");
  expectEqual<std::int32_t>(parsed.objects[0].y, 900, "object y");

  // A clear: same header, zero objects.
  const std::vector<std::uint8_t> clear =
      pcsPayload(1920, 1080, 8, 0x00, 0, false, 0, false, 0, 0);
  pgs::PresentationComposition parsedClear;
  expect(pgs::parsePresentationComposition(clear, &parsedClear, &error),
         "a clear composition parses");
  expect(parsedClear.objects.empty(), "a clear carries no objects");
  expect(parsedClear.state == pgs::CompositionState::Normal, "normal state");

  // An object count that the payload cannot satisfy must be refused.
  std::vector<std::uint8_t> lying = payload;
  lying[10] = 4;
  expect(!pgs::parsePresentationComposition(lying, &parsedClear, &error),
         "an overstated object count is refused");

  std::vector<std::uint8_t> shortPayload{0, 1, 2};
  expect(!pgs::parsePresentationComposition(shortPayload, &parsedClear, &error),
         "a short composition is refused");
}

void testPgsPaletteAndWindowParsing() {
  std::vector<pgs::WindowRect> windows;
  std::string error;
  expect(pgs::parseWindowDefinition(wdsPayload(11, 22, 33, 44), &windows, &error),
         "a window definition parses");
  expectEqual<std::size_t>(windows.size(), 1, "one window");
  expectEqual<std::uint16_t>(windows[0].x, 11, "window x");
  expectEqual<std::uint16_t>(windows[0].height, 44, "window height");

  pgs::PaletteDefinition palette;
  expect(pgs::parsePaletteDefinition(pdsPayload(2), &palette, &error),
         "a palette definition parses");
  expectEqual<std::uint8_t>(palette.paletteId, 2, "palette id");
  expectEqual<std::size_t>(palette.entries.size(), 2, "two palette entries");
  expectEqual<std::uint8_t>(palette.entries[0].index, 1, "first entry index");
  expectEqual<std::uint8_t>(palette.entries[0].alpha, 255, "first entry alpha");

  // Entries are exactly five bytes; a partial entry means a misparse upstream.
  std::vector<std::uint8_t> ragged = pdsPayload(0);
  ragged.push_back(0x01);
  expect(!pgs::parsePaletteDefinition(ragged, &palette, &error),
         "a ragged palette is refused");
}

void testPgsObjectParsing() {
  const auto rle = rle2x2Colour1();
  pgs::ObjectDefinition object;
  std::string error;
  expect(pgs::parseObjectDefinition(odsPayload(9, 2, 2, rle), &object, &error),
         "an object definition parses");
  expectEqual<std::uint16_t>(object.objectId, 9, "object id");
  expect(object.first && object.last, "0xC0 means first and last");
  expectEqual<std::uint16_t>(object.width, 2, "object width");
  expectEqual<std::uint16_t>(object.height, 2, "object height");
  // The declared length counts the width and height fields themselves; reading
  // it as "just the run-length bytes" truncates every fragmented object.
  expectEqual<std::uint32_t>(object.declaredDataLength,
                             static_cast<std::uint32_t>(rle.size()) + 4,
                             "declared length includes the dimensions");
  expectEqual<std::size_t>(object.data.size(), rle.size(), "the data is the RLE");

  // A continuation segment carries no dimensions and no length.
  pgs::ObjectDefinition continuation;
  expect(pgs::parseObjectDefinition(odsPayload(9, 0, 0, rle, 0x40),
                                    &continuation, &error),
         "a continuation object parses");
  expect(!continuation.first && continuation.last, "0x40 means last only");
  expectEqual<std::size_t>(continuation.data.size(), rle.size(),
                           "a continuation is all data");
}

void testPgsRunLength() {
  std::vector<std::uint8_t> indices;
  std::string error;

  // Single-pixel codes plus explicit end-of-line.
  expect(pgs::decodeRunLength(rle2x2Colour1(), 2, 2, &indices, &error),
         "single-pixel codes decode");
  expectEqual<std::size_t>(indices.size(), 4, "2x2 is four pixels");
  for (std::size_t i = 0; i < 4; ++i) {
    expectEqual<std::uint8_t>(indices[i], 1, "every pixel is colour 1");
  }

  // Short transparent run: 0x00 0x04 == four pixels of colour 0.
  const std::vector<std::uint8_t> transparentRun{0x00, 0x04, 0x00, 0x00};
  expect(pgs::decodeRunLength(transparentRun, 4, 1, &indices, &error),
         "a short zero run decodes");
  for (std::size_t i = 0; i < 4; ++i) {
    expectEqual<std::uint8_t>(indices[i], 0, "a zero run is colour 0");
  }

  // Short coloured run: 0x00 0x83 0x02 == three pixels of colour 2. The 0x80
  // bit selects "coloured"; reading it as the length bit yields a 3-pixel run
  // of colour 0 and a blank caption.
  const std::vector<std::uint8_t> colouredRun{0x00, 0x83, 0x02, 0x00, 0x00};
  expect(pgs::decodeRunLength(colouredRun, 3, 1, &indices, &error),
         "a short coloured run decodes");
  for (std::size_t i = 0; i < 3; ++i) {
    expectEqual<std::uint8_t>(indices[i], 2, "a coloured run is its colour");
  }

  // Long coloured run: 0x00 0xC1 0x04 0x03 == 0x104 (260) pixels of colour 3.
  std::vector<std::uint8_t> longRun{0x00, 0xC1, 0x04, 0x03, 0x00, 0x00};
  expect(pgs::decodeRunLength(longRun, 260, 1, &indices, &error),
         "a long coloured run decodes");
  expectEqual<std::size_t>(indices.size(), 260, "260 pixels");
  expectEqual<std::uint8_t>(indices[0], 3, "long run start");
  expectEqual<std::uint8_t>(indices[259], 3, "long run end");

  // Long transparent run: 0x00 0x41 0x04 == 260 pixels of colour 0.
  std::vector<std::uint8_t> longZero{0x00, 0x41, 0x04, 0x00, 0x00};
  expect(pgs::decodeRunLength(longZero, 260, 1, &indices, &error),
         "a long zero run decodes");
  expectEqual<std::uint8_t>(indices[259], 0, "long zero run is colour 0");

  // A line that ends early is padded, not refused: the second row stays 0.
  const std::vector<std::uint8_t> shortLine{0x01, 0x00, 0x00, 0x00, 0x00};
  expect(pgs::decodeRunLength(shortLine, 2, 2, &indices, &error),
         "a short line pads");
  expectEqual<std::uint8_t>(indices[0], 1, "the written pixel survives");
  expectEqual<std::uint8_t>(indices[1], 0, "the unwritten pixel is colour 0");
  expectEqual<std::uint8_t>(indices[2], 0, "the second row is colour 0");

  // A run that overruns its line is clipped rather than writing out of bounds.
  const std::vector<std::uint8_t> overrun{0x00, 0x88, 0x01, 0x00, 0x00};
  expect(pgs::decodeRunLength(overrun, 2, 1, &indices, &error),
         "an overrunning run is clipped");
  expectEqual<std::size_t>(indices.size(), 2, "the plane stays 2 pixels");
  expectEqual<std::uint8_t>(indices[1], 1, "the clipped run still paints");

  // Truncated escapes are refused rather than read past the buffer.
  const std::vector<std::uint8_t> danglingEscape{0x00};
  expect(!pgs::decodeRunLength(danglingEscape, 2, 1, &indices, &error),
         "a dangling escape is refused");
  const std::vector<std::uint8_t> danglingColour{0x00, 0x83};
  expect(!pgs::decodeRunLength(danglingColour, 4, 1, &indices, &error),
         "a run missing its colour byte is refused");
  const std::vector<std::uint8_t> danglingLength{0x00, 0xC1};
  expect(!pgs::decodeRunLength(danglingLength, 4, 1, &indices, &error),
         "a long run missing its length byte is refused");

  expect(!pgs::decodeRunLength(rle2x2Colour1(), 0, 2, &indices, &error),
         "a zero dimension is refused");
}

void testPgsTrackDecoding() {
  pgs::TrackDecoder decoder;
  expect(decoder.appendBlock(pgsShowBlock(), 1 * kSecond), "show block accepted");
  expect(decoder.appendBlock(pgsClearBlock(), 4 * kSecond), "clear block accepted");
  const BitmapSubtitleContent content = decoder.finish(10 * kSecond);

  expectEqual<std::uint32_t>(content.canvasWidth, 100, "canvas width from the PCS");
  expectEqual<std::uint32_t>(content.canvasHeight, 50, "canvas height from the PCS");
  expectEqual<std::size_t>(content.cues.size(), 1, "one cue");
  if (content.cues.empty()) {
    return;
  }
  const BitmapCue& cue = content.cues[0];
  expectEqual<std::int64_t>(cue.startNanoseconds, 1 * kSecond, "cue starts at its block");
  // The clear display set is what ends a PGS cue. Ending it anywhere else --
  // at the next show, or at the end of the file -- leaves the caption on screen.
  expectEqual<std::int64_t>(cue.endNanoseconds, 4 * kSecond,
                            "cue ends at the clearing display set");
  expectEqual<std::int32_t>(cue.x, 5, "cue x from the composition object");
  expectEqual<std::int32_t>(cue.y, 7, "cue y from the composition object");
  expectEqual<std::uint32_t>(cue.image.width, 2, "cue width from the ODS");
  expect(!cue.forced, "this fixture is not forced");
  expectEqual<std::uint32_t>(cue.image.palette[1], 0xFFFFFFFFU,
                             "palette entry 1 is opaque white");
  expect(content.error.empty(), "a clean stream reports no error");
}

void testPgsForcedFlagSurvivesDecoding() {
  pgs::TrackDecoder decoder;
  expect(decoder.appendBlock(pgsShowBlock(true), 1 * kSecond), "forced block accepted");
  expect(decoder.appendBlock(pgsClearBlock(), 2 * kSecond), "clear accepted");
  const BitmapSubtitleContent content = decoder.finish(3 * kSecond);
  expectEqual<std::size_t>(content.cues.size(), 1, "one forced cue");
  if (!content.cues.empty()) {
    // The forced flag drives the existing forced-subtitle policy; losing it
    // here would silently demote every forced caption.
    expect(content.cues[0].forced, "the forced flag reaches the cue");
  }
}

void testPgsUnclosedCueIsClosedAtFinish() {
  pgs::TrackDecoder decoder;
  expect(decoder.appendBlock(pgsShowBlock(), 1 * kSecond), "show accepted");
  const BitmapSubtitleContent content = decoder.finish(9 * kSecond);
  expectEqual<std::size_t>(content.cues.size(), 1, "the unclosed cue survives");
  if (!content.cues.empty()) {
    expectEqual<std::int64_t>(content.cues[0].endNanoseconds, 9 * kSecond,
                              "an unclosed cue ends where finish says");
  }
}

void testPgsTransparentCompositionIsDropped() {
  // A display set whose palette leaves the object invisible must not become a
  // cue: it would flash an empty overlay on and off.
  std::vector<std::uint8_t> block;
  appendSegment(block, 0x16, pcsPayload(100, 50, 0, 0x80, 0, true, 0, false, 5, 7));
  appendSegment(block, 0x17, wdsPayload(5, 7, 2, 2));
  std::vector<std::uint8_t> clearPalette{0, 0, 1, 235, 128, 128, 0};  // alpha 0
  appendSegment(block, 0x14, clearPalette);
  appendSegment(block, 0x15, odsPayload(0, 2, 2, rle2x2Colour1()));
  appendSegment(block, 0x80, {});

  pgs::TrackDecoder decoder;
  expect(decoder.appendBlock(block, 1 * kSecond), "the block is accepted");
  const BitmapSubtitleContent content = decoder.finish(5 * kSecond);
  expect(content.cues.empty(), "a fully transparent composition is not a cue");
}

void testPgsSupFraming() {
  // The same display sets, wrapped in the 10-byte "PG" + PTS + DTS header a
  // standalone .sup file uses. 90 kHz ticks, so 1 s is 90000.
  std::vector<std::uint8_t> sup;
  auto appendSup = [&sup](std::uint32_t pts, const std::vector<std::uint8_t>& run) {
    std::size_t pos = 0;
    while (pos < run.size()) {
      const std::uint16_t size =
          static_cast<std::uint16_t>((run[pos + 1] << 8) | run[pos + 2]);
      sup.push_back('P');
      sup.push_back('G');
      for (int shift = 24; shift >= 0; shift -= 8) {
        sup.push_back(static_cast<std::uint8_t>((pts >> shift) & 0xFF));
      }
      for (int i = 0; i < 4; ++i) {
        sup.push_back(0);  // DTS
      }
      sup.insert(sup.end(), run.begin() + static_cast<std::ptrdiff_t>(pos),
                 run.begin() + static_cast<std::ptrdiff_t>(pos + 3 + size));
      pos += 3 + size;
    }
  };
  appendSup(90'000, pgsShowBlock());
  appendSup(360'000, pgsClearBlock());

  std::vector<pgs::Segment> segments;
  std::string error;
  expect(pgs::parseSupStream(sup, &segments, &error), "a .sup stream parses");
  expectEqual<std::size_t>(segments.size(), 7, "seven segments across two sets");
  expectEqual<std::uint32_t>(segments[0].presentationTimestamp90k, 90'000u,
                             "the first segment carries its PTS");

  // Missing magic must be refused; without the check a byte offset error would
  // be read as segment data.
  std::vector<std::uint8_t> broken = sup;
  broken[0] = 'X';
  segments.clear();
  expect(!pgs::parseSupStream(broken, &segments, &error),
         "a .sup segment without PG magic is refused");

  pgs::TrackDecoder decoder;
  expect(decoder.appendSupStream(sup), "a .sup stream decodes");
  const BitmapSubtitleContent content = decoder.finish(0);
  expectEqual<std::size_t>(content.cues.size(), 1, "one cue from the .sup");
  if (!content.cues.empty()) {
    // 90000 ticks at 90 kHz is exactly one second.
    expectEqual<std::int64_t>(content.cues[0].startNanoseconds, 1 * kSecond,
                              "90 kHz ticks convert exactly to nanoseconds");
    expectEqual<std::int64_t>(content.cues[0].endNanoseconds, 4 * kSecond,
                              "the .sup clear ends the cue");
  }
}

void testPgsEpochResetDropsStaleObjects() {
  // After an epoch start, a composition referencing an object from the previous
  // epoch has nothing to draw and must not reuse the stale bitmap.
  pgs::TrackDecoder decoder;
  expect(decoder.appendBlock(pgsShowBlock(), 1 * kSecond), "first epoch shows");
  expect(decoder.appendBlock(pgsClearBlock(), 2 * kSecond), "first epoch clears");

  std::vector<std::uint8_t> staleReference;
  appendSegment(staleReference, 0x16,
                pcsPayload(100, 50, 2, 0x80, 0, true, 0, false, 5, 7));
  appendSegment(staleReference, 0x80, {});
  expect(decoder.appendBlock(staleReference, 3 * kSecond), "the block parses");
  const BitmapSubtitleContent content = decoder.finish(6 * kSecond);
  expectEqual<std::size_t>(content.cues.size(), 1,
                           "a new epoch does not resurrect the old object");
  expect(!content.error.empty(),
         "referencing an undefined object is reported");
}

// ---------------------------------------------------------------------------
// VobSub
// ---------------------------------------------------------------------------

// A 4x4 sub-picture at (10,20): even rows colour 1, odd rows colour 2.
std::vector<std::uint8_t> vobsubPacket(std::uint16_t stopDelay, bool forced,
                                       bool withStop = true) {
  std::vector<std::uint8_t> p;
  appendU16(p, 0);  // packet size, patched below
  appendU16(p, 0);  // control offset, patched below

  const std::size_t topOffset = p.size();
  // "run to end of line" is the four-nibble form with run 0: 0x000C | colour.
  p.insert(p.end(), {0x00, 0x01, 0x00, 0x01});  // rows 0 and 2, colour 1
  const std::size_t bottomOffset = p.size();
  p.insert(p.end(), {0x00, 0x02, 0x00, 0x02});  // rows 1 and 3, colour 2

  const std::size_t controlOffset = p.size();
  appendU16(p, 0);  // delay 0 -> starts at the block timestamp
  const std::size_t nextField = p.size();
  appendU16(p, 0);  // next sequence offset, patched below
  if (forced) {
    p.push_back(0x00);  // forced display
  }
  p.push_back(0x01);  // start display
  p.push_back(0x03);  // set palette: colours 3,2,1,0 -> idx 3,2,1,0
  p.push_back(0x32);
  p.push_back(0x10);
  p.push_back(0x04);  // set alpha: colours 3,2,1 opaque, colour 0 transparent
  p.push_back(0xFF);
  p.push_back(0xF0);
  p.push_back(0x05);  // display area x1=10 x2=13 y1=20 y2=23
  p.push_back(0x00);
  p.push_back(0xA0);
  p.push_back(0x0D);
  p.push_back(0x01);
  p.push_back(0x40);
  p.push_back(0x17);
  p.push_back(0x06);  // pixel-data offsets
  appendU16(p, static_cast<std::uint16_t>(topOffset));
  appendU16(p, static_cast<std::uint16_t>(bottomOffset));
  p.push_back(0xFF);  // end of commands

  std::size_t secondOffset = controlOffset;
  if (withStop) {
    secondOffset = p.size();
    appendU16(p, stopDelay);
    appendU16(p, static_cast<std::uint16_t>(secondOffset));  // points at itself
    p.push_back(0x02);  // stop display
    p.push_back(0xFF);
  }
  p[nextField] = static_cast<std::uint8_t>(secondOffset >> 8);
  p[nextField + 1] = static_cast<std::uint8_t>(secondOffset & 0xFF);

  p[0] = static_cast<std::uint8_t>(p.size() >> 8);
  p[1] = static_cast<std::uint8_t>(p.size() & 0xFF);
  p[2] = static_cast<std::uint8_t>(controlOffset >> 8);
  p[3] = static_cast<std::uint8_t>(controlOffset & 0xFF);
  return p;
}

void testVobsubIdxParsing() {
  const std::string idx =
      "# a comment\n"
      "size: 720x480\n"
      "palette: 000000, ffffff, ff0000, 00ff00, 0000ff, ffff00, 00ffff,"
      " ff00ff, 808080, 404040, c0c0c0, 800000, 008000, 000080, 808000,"
      " 800080\n"
      "langidx: 0\n";
  vobsub::IdxMetadata metadata;
  std::string error;
  expect(vobsub::parseIdxMetadata(idx, &metadata, &error), "an .idx parses");
  expect(metadata.hasSize, "the size line is found");
  expectEqual<std::uint32_t>(metadata.width, 720, "idx width");
  expectEqual<std::uint32_t>(metadata.height, 480, "idx height");
  expect(metadata.hasPalette, "the palette line is found");
  // The .idx palette is RGB, not YCrCb: entry 2 is pure red. Treating it as
  // luma/chroma would tint every DVD caption.
  expectEqual<std::uint32_t>(metadata.palette[1], 0xFFFFFFU, "entry 1 is white");
  expectEqual<std::uint32_t>(metadata.palette[2], 0xFF0000U, "entry 2 is red");
  expectEqual<std::uint32_t>(metadata.palette[4], 0x0000FFU, "entry 4 is blue");

  // A CodecPrivate with no size still yields a usable canvas rather than a
  // zero-sized one that would divide by zero downstream.
  vobsub::IdxMetadata bare;
  expect(vobsub::parseIdxMetadata("palette: 000000, ffffff\n", &bare, &error),
         "a palette-only .idx parses");
  expect(!bare.hasSize, "no size line was present");
  expectEqual<std::uint32_t>(bare.width, 720, "a missing size falls back to 720");
  expectEqual<std::uint32_t>(bare.height, 480, "a missing size falls back to 480");

  vobsub::IdxMetadata empty;
  expect(!vobsub::parseIdxMetadata("", &empty, &error),
         "an empty CodecPrivate reports that it carried nothing");
  expectEqual<std::uint32_t>(empty.width, 720, "the fallback canvas is still set");
}

void testVobsubRunLength() {
  // Rows alternate between the two fields; decoding both into one plane in the
  // right interleave is the whole trick of the format.
  const std::vector<std::uint8_t> data{0x00, 0x01, 0x00, 0x01,
                                       0x00, 0x02, 0x00, 0x02};
  std::vector<std::uint8_t> indices;
  std::string error;
  expect(vobsub::decodeRunLength(data, 0, 4, 4, 4, &indices, &error),
         "an interleaved sub-picture decodes");
  expectEqual<std::size_t>(indices.size(), 16, "4x4 is sixteen pixels");
  for (std::uint32_t col = 0; col < 4; ++col) {
    expectEqual<std::uint8_t>(indices[col], 1, "row 0 comes from the top field");
    expectEqual<std::uint8_t>(indices[4 + col], 2,
                              "row 1 comes from the bottom field");
    expectEqual<std::uint8_t>(indices[8 + col], 1, "row 2 comes from the top field");
    expectEqual<std::uint8_t>(indices[12 + col], 2,
                              "row 3 comes from the bottom field");
  }

  // The short forms: 0x4 | colour in one nibble is a run of 1.
  // 0x7 == run 1 colour 3; 0x9 == run 2 colour 1.
  const std::vector<std::uint8_t> shortForms{0x79, 0x00};
  expect(vobsub::decodeRunLength(shortForms, 0, 0, 3, 1, &indices, &error),
         "one-nibble runs decode");
  expectEqual<std::uint8_t>(indices[0], 3, "nibble 0x7 is one pixel of colour 3");
  expectEqual<std::uint8_t>(indices[1], 1, "nibble 0x9 is two pixels of colour 1");
  expectEqual<std::uint8_t>(indices[2], 1, "the second pixel of that run");

  expect(!vobsub::decodeRunLength(data, 0, 4, 0, 4, &indices, &error),
         "a zero dimension is refused");
  // Offsets past the packet cannot paint anything and must be reported.
  expect(!vobsub::decodeRunLength(data, 99, 99, 4, 4, &indices, &error),
         "out-of-range field offsets are refused");
}

void testVobsubSubPictureDecoding() {
  vobsub::IdxMetadata metadata;
  std::string error;
  (void)vobsub::parseIdxMetadata(
      "size: 720x480\npalette: 000000, ffffff, ff0000, 00ff00\n", &metadata,
      &error);

  vobsub::SubPicture picture;
  expect(vobsub::decodeSubPicture(vobsubPacket(263, false), metadata, &picture,
                                  &error),
         "a sub-picture decodes");
  expectEqual<std::int32_t>(picture.x, 10, "display area x1");
  expectEqual<std::int32_t>(picture.y, 20, "display area y1");
  // The area is inclusive at both ends: x1=10, x2=13 is four pixels, not three.
  expectEqual<std::uint32_t>(picture.image.width, 4, "display area width");
  expectEqual<std::uint32_t>(picture.image.height, 4, "display area height");
  expect(picture.hasStop, "the stop command is seen");
  expect(!picture.forced, "this packet is not forced");
  // Colour 0 is transparent by its alpha nibble; 1 and 2 take .idx entries.
  expectEqual<std::uint32_t>(picture.image.palette[0], 0x00000000U,
                             "colour 0 is transparent");
  expectEqual<std::uint32_t>(picture.image.palette[1], 0xFFFFFFFFU,
                             "colour 1 is opaque white from idx entry 1");
  expectEqual<std::uint32_t>(picture.image.palette[2], 0xFFFF0000U,
                             "colour 2 is opaque red from idx entry 2");

  vobsub::SubPicture forcedPicture;
  expect(vobsub::decodeSubPicture(vobsubPacket(263, true), metadata,
                                  &forcedPicture, &error),
         "a forced sub-picture decodes");
  expect(forcedPicture.forced, "command 0x00 sets the forced flag");

  // A packet with no display area cannot be sized and must be refused.
  std::vector<std::uint8_t> noArea{0x00, 0x08, 0x00, 0x04, 0x00, 0x00, 0xFF, 0x00};
  expect(!vobsub::decodeSubPicture(noArea, metadata, &picture, &error),
         "a packet with no display area is refused");
  std::vector<std::uint8_t> tiny{0x00};
  expect(!vobsub::decodeSubPicture(tiny, metadata, &picture, &error),
         "a truncated packet is refused");
}

void testVobsubDurationPolicy() {
  const std::string idx = "size: 720x480\npalette: 000000, ffffff, ff0000\n";

  // BlockDuration is the container's statement and outranks the SPU's stop.
  {
    vobsub::TrackDecoder decoder(idx);
    expect(decoder.appendBlock(vobsubPacket(263, false), 1 * kSecond, 3 * kSecond),
           "a block with a duration is accepted");
    const BitmapSubtitleContent content = decoder.finish(20 * kSecond);
    expectEqual<std::size_t>(content.cues.size(), 1, "one cue");
    if (!content.cues.empty()) {
      expectEqual<std::int64_t>(content.cues[0].startNanoseconds, 1 * kSecond,
                                "the cue starts at its block");
      expectEqual<std::int64_t>(content.cues[0].endNanoseconds, 4 * kSecond,
                                "BlockDuration sets the end");
    }
  }

  // With no BlockDuration the SPU's own stop delay is used: 263 units of
  // 1024/90000 s is 2.992 s.
  {
    vobsub::TrackDecoder decoder(idx);
    expect(decoder.appendBlock(vobsubPacket(263, false), 1 * kSecond, 0),
           "a block with no duration is accepted");
    const BitmapSubtitleContent content = decoder.finish(20 * kSecond);
    expectEqual<std::size_t>(content.cues.size(), 1, "one cue");
    if (!content.cues.empty()) {
      const std::int64_t end = content.cues[0].endNanoseconds;
      expect(end > 1 * kSecond + 2'900'000'000LL &&
                 end < 1 * kSecond + 3'100'000'000LL,
             "the SPU stop delay sets the end when the container is silent");
    }
  }

  // A maximal stop delay means "unknown", not twelve minutes on screen.
  {
    vobsub::TrackDecoder decoder(idx);
    expect(decoder.appendBlock(vobsubPacket(0xFFFF, false), 1 * kSecond, 0),
           "a block with a maximal delay is accepted");
    const BitmapSubtitleContent content = decoder.finish(1000 * kSecond);
    expectEqual<std::size_t>(content.cues.size(), 1, "one cue");
    if (!content.cues.empty()) {
      expectEqual<std::int64_t>(
          content.cues[0].endNanoseconds,
          1 * kSecond + kMaximumBitmapCueDurationNanoseconds,
          "an unknown stop delay is clamped");
    }
  }

  // No stop command at all: the next sub-picture closes the previous one.
  {
    vobsub::TrackDecoder decoder(idx);
    expect(decoder.appendBlock(vobsubPacket(0, false, false), 1 * kSecond, 0),
           "an open sub-picture is accepted");
    expect(decoder.appendBlock(vobsubPacket(0, false, false), 5 * kSecond, 0),
           "the following sub-picture is accepted");
    const BitmapSubtitleContent content = decoder.finish(20 * kSecond);
    expectEqual<std::size_t>(content.cues.size(), 2, "two cues");
    if (content.cues.size() == 2) {
      expectEqual<std::int64_t>(content.cues[0].endNanoseconds, 5 * kSecond,
                                "the next sub-picture closes the previous one");
      expectEqual<std::int64_t>(content.cues[1].endNanoseconds, 20 * kSecond,
                                "the last one is closed at finish");
    }
  }
}

void testVobsubTrackGeometry() {
  vobsub::TrackDecoder decoder("size: 720x480\npalette: 000000, ffffff, ff0000\n");
  expect(decoder.appendBlock(vobsubPacket(263, false), 0, 3 * kSecond),
         "a block is accepted");
  const BitmapSubtitleContent content = decoder.finish(10 * kSecond);
  expectEqual<std::uint32_t>(content.canvasWidth, 720, "canvas width from the idx");
  expectEqual<std::uint32_t>(content.canvasHeight, 480, "canvas height from the idx");
  expectEqual<std::size_t>(content.cues.size(), 1, "one cue");
  if (!content.cues.empty()) {
    expectEqual<std::int32_t>(content.cues[0].x, 10, "cue x from the display area");
    expectEqual<std::int32_t>(content.cues[0].y, 20, "cue y from the display area");
  }
}

// ---------------------------------------------------------------------------

void testCueLookup() {
  std::vector<BitmapCue> cues;
  auto make = [](std::int64_t start, std::int64_t end) {
    BitmapCue cue;
    cue.startNanoseconds = start;
    cue.endNanoseconds = end;
    cue.image.width = 1;
    cue.image.height = 1;
    cue.image.indices = {1};
    cue.image.palette[1] = 0xFFFFFFFF;
    return cue;
  };
  cues.push_back(make(5 * kSecond, 7 * kSecond));
  cues.push_back(make(1 * kSecond, 4 * kSecond));
  cues.push_back(make(2 * kSecond, 6 * kSecond));  // overlaps both
  finalizeBitmapCues(&cues);
  expectEqual<std::size_t>(cues.size(), 3, "all three cues survive finalizing");
  expectEqual<std::int64_t>(cues[0].startNanoseconds, 1 * kSecond,
                            "finalizing sorts by start");

  std::vector<std::size_t> hits;
  bitmapCuesAt(cues, 3 * kSecond, &hits);
  // Two composition objects can legally be on screen at once, so the lookup
  // must return a set: collapsing it to one would drop half of a two-line
  // caption.
  expectEqual<std::size_t>(hits.size(), 2, "two cues cover 3s");
  bitmapCuesAt(cues, 6 * kSecond + 500'000'000LL, &hits);
  expectEqual<std::size_t>(hits.size(), 1, "one cue covers 6.5s");
  bitmapCuesAt(cues, 8 * kSecond, &hits);
  expect(hits.empty(), "no cue covers 8s");
  bitmapCuesAt(cues, 0, &hits);
  expect(hits.empty(), "no cue covers 0s");
  // A cue's end is exclusive, matching the text cue rule.
  bitmapCuesAt(cues, 7 * kSecond, &hits);
  expect(hits.empty(), "a cue's end bound is exclusive");

  std::vector<BitmapCue> degenerate;
  degenerate.push_back(make(5 * kSecond, 5 * kSecond));
  degenerate.push_back(make(9 * kSecond, 8 * kSecond));
  finalizeBitmapCues(&degenerate);
  expect(degenerate.empty(), "zero and negative length cues are dropped");
}

}  // namespace

int main() {
  testCodecIdentification();
  testColourConversion();
  testImageHelpers();
  testCropToOpaqueBounds();
  testPgsSegmentFraming();
  testPgsCompositionParsing();
  testPgsPaletteAndWindowParsing();
  testPgsObjectParsing();
  testPgsRunLength();
  testPgsTrackDecoding();
  testPgsForcedFlagSurvivesDecoding();
  testPgsUnclosedCueIsClosedAtFinish();
  testPgsTransparentCompositionIsDropped();
  testPgsSupFraming();
  testPgsEpochResetDropsStaleObjects();
  testVobsubIdxParsing();
  testVobsubRunLength();
  testVobsubSubPictureDecoding();
  testVobsubDurationPolicy();
  testVobsubTrackGeometry();
  testCueLookup();
  if (failures != 0) {
    std::cerr << failures << " bitmap subtitle test(s) failed\n";
    return EXIT_FAILURE;
  }
  std::cout << "Bitmap subtitle tests passed\n";
  return EXIT_SUCCESS;
}
