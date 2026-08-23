#include "media/subtitle_text.hpp"

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

void expectText(const std::string& actual, const std::string& expected,
                const char* message) {
  if (actual != expected) {
    std::cerr << "FAIL: " << message << "\n  expected [" << expected
              << "]\n  actual   [" << actual << "]\n";
    ++failures;
  }
}

constexpr std::int64_t kSecond = 1'000'000'000;

// ---------------------------------------------------------------------------

void testCodecIdentification() {
  expect(textCodecFromMatroskaCodecId("S_TEXT/UTF8") == TextCodec::SubRip,
         "S_TEXT/UTF8 is SubRip");
  expect(textCodecFromMatroskaCodecId("S_TEXT/ASS") == TextCodec::Ass,
         "S_TEXT/ASS is ASS");
  expect(textCodecFromMatroskaCodecId("S_TEXT/SSA") == TextCodec::Ssa,
         "S_TEXT/SSA is SSA");
  expect(textCodecFromMatroskaCodecId("S_TEXT/WEBVTT") == TextCodec::WebVtt,
         "S_TEXT/WEBVTT is WebVTT");
  // WebM's own namespace: the fixture generator proves ffmpeg writes this and
  // refuses subrip in a .webm entirely.
  expect(textCodecFromMatroskaCodecId("D_WEBVTT/SUBTITLES") ==
             TextCodec::WebVtt,
         "D_WEBVTT/SUBTITLES is WebVTT");
  expect(textCodecFromMatroskaCodecId("D_WEBVTT/CAPTIONS") == TextCodec::WebVtt,
         "D_WEBVTT/CAPTIONS is WebVTT");
  // Bitmap subtitles are declined, by name, so the menu never offers a track
  // this player cannot draw.
  expect(textCodecFromMatroskaCodecId("S_HDMV/PGS") == TextCodec::Unknown,
         "PGS is not a text codec");
  expect(textCodecFromMatroskaCodecId("S_VOBSUB") == TextCodec::Unknown,
         "VobSub is not a text codec");
  expect(textCodecFromMatroskaCodecId("D_WEBVTT/METADATA") ==
             TextCodec::Unknown,
         "WebVTT metadata is not displayable text");
  expect(textCodecFromMatroskaCodecId("") == TextCodec::Unknown,
         "an empty CodecID is not a text codec");
  expect(!isTextCodec(TextCodec::Unknown), "Unknown is not a text codec");
}

void testAssOverrideStripping() {
  expectText(stripAssOverrideTags("{\\i1}STYLED{\\i0}"), "STYLED",
             "italic override blocks are removed");
  expectText(stripAssOverrideTags("{\\pos(320,300)\\c&H00FF00&}GREEN"), "GREEN",
             "position and colour overrides are removed");
  expectText(stripAssOverrideTags("{\\an8}TOP"), "TOP",
             "alignment overrides are removed");
  expectText(stripAssOverrideTags("one\\Ntwo"), "one\ntwo",
             "\\N becomes a hard line break");
  expectText(stripAssOverrideTags("one\\ntwo"), "one\ntwo",
             "\\n becomes a line break");
  expectText(stripAssOverrideTags("a\\hb"), "a b",
             "\\h becomes a space");
  expectText(stripAssOverrideTags("plain"), "plain",
             "text without overrides is untouched");
  // Braces are the tag delimiters; an unterminated one must not swallow only
  // part of the line in a way that leaves a stray brace on screen.
  expectText(stripAssOverrideTags("before{\\b1}after"), "beforeafter",
             "a tag between words leaves no gap or brace");
  expectText(stripAssOverrideTags("{unclosed"), "",
             "an unclosed override block consumes the rest");
  expectText(stripAssOverrideTags("stray}text"), "straytext",
             "a stray closing brace is dropped, not shown");
  expectText(stripAssOverrideTags("{\\t(\\fscx110)}nested"), "nested",
             "an override with parenthesised arguments is removed whole");
  // A drawing command's payload is inside the same braces, so it goes too.
  expectText(stripAssOverrideTags("{\\p1}m 0 0 l 10 10{\\p0}"), "m 0 0 l 10 10",
             "only braced runs are removed, not the text between them");
}

void testAssDialoguePayload() {
  // The exact shape Matroska stores: the Dialogue line minus its keyword and
  // its two timestamps, i.e. 8 leading fields then the text.
  expectText(
      renderAssDialoguePayload("0,0,Default,,0,0,0,,{\\i1}STYLED ASS LINE{\\i0}"),
      "STYLED ASS LINE", "an embedded ASS payload renders its text field");
  expectText(renderAssDialoguePayload(
                 "1,0,Default,,0,0,0,,line one\\Nline two"),
             "line one\nline two", "hard breaks survive the field walk");
  // The text field may itself contain commas; counting separators (not
  // splitting) is what keeps them.
  expectText(renderAssDialoguePayload("2,0,Default,,0,0,0,,yes, and also, no"),
             "yes, and also, no",
             "commas inside the text field are not treated as separators");
  expectText(renderAssDialoguePayload("3,0,Default,,0,0,0,,"), "",
             "an empty text field renders nothing");
  // Malformed: fewer than 8 separators. Treat the payload as bare text rather
  // than discard a line.
  expectText(renderAssDialoguePayload("just text"), "just text",
             "a payload that is not a field list is treated as text");
  expectText(renderAssDialoguePayload("0,0,Default,,0,0,0,,a,b,c"), "a,b,c",
             "every comma past the eighth belongs to the text");
}

void testWebVttPayload() {
  expectText(renderWebVttPayload("plain line"), "plain line",
             "WebVTT plain text is unchanged");
  expectText(renderWebVttPayload("<i>italic</i> and <b>bold</b>"),
             "italic and bold", "WebVTT inline tags are stripped");
  expectText(renderWebVttPayload("<c.yellow>coloured</c>"), "coloured",
             "WebVTT class tags are stripped");
  expectText(renderWebVttPayload("<00:00:01.000>karaoke"), "karaoke",
             "WebVTT timestamp tags are stripped");
  expectText(renderWebVttPayload("one\ntwo"), "one\ntwo",
             "WebVTT line breaks survive");
}

void testNormalization() {
  expectText(normalizeCueText("a\r\nb"), "a\nb", "CRLF collapses to one break");
  expectText(normalizeCueText("a\rb"), "a\nb", "a lone CR becomes a break");
  expectText(normalizeCueText("  spaced  "), "spaced",
             "surrounding whitespace is trimmed");
  expectText(normalizeCueText("\n\ntext\n\n"), "text",
             "leading and trailing blank lines are trimmed");
  expectText(normalizeCueText("\xEF\xBB\xBF" "bom"), "bom",
             "a BOM is removed");

  // Truncation must land on a UTF-8 boundary or the overlay shows a
  // replacement glyph for a half-written code point.
  std::string huge;
  while (huge.size() < kMaximumCueTextBytes + 16)
    huge += "\xE2\x9C\x93";  // U+2713, three bytes
  const std::string clipped = normalizeCueText(huge);
  expect(clipped.size() <= kMaximumCueTextBytes,
         "an over-long cue is truncated to the cap");
  expect(clipped.size() % 3 == 0,
         "truncation lands on a UTF-8 code point boundary");
}

void testSubRipParsing() {
  const std::string srt =
      "1\n"
      "00:00:01,000 --> 00:00:04,000\n"
      "FIRST LINE\n"
      "\n"
      "2\n"
      "00:00:05,500 --> 00:00:08,250\n"
      "SECOND LINE\n"
      "with a second row\n"
      "\n"
      "3\n"
      "00:00:10,000 --> 00:00:14,000\n"
      "THIRD LINE\n";
  const ParsedFile parsed = parseSubRip(srt);
  expect(parsed.error.empty(), "a well-formed SRT parses without error");
  expect(parsed.cues.size() == 3, "three SRT cues are read");
  if (parsed.cues.size() == 3) {
    expect(parsed.cues[0].startNanoseconds == 1 * kSecond,
           "the first cue starts at 1 s");
    expect(parsed.cues[0].endNanoseconds == 4 * kSecond,
           "the first cue ends at 4 s");
    expectText(parsed.cues[0].text, "FIRST LINE", "the first cue's text");
    expect(parsed.cues[1].startNanoseconds == 5 * kSecond + 500'000'000,
           "millisecond precision is exact");
    expect(parsed.cues[1].endNanoseconds == 8 * kSecond + 250'000'000,
           "the second cue's end is exact");
    expectText(parsed.cues[1].text, "SECOND LINE\nwith a second row",
               "a two-row cue keeps its break");
    // The last cue has no trailing blank line; it must still be read.
    expectText(parsed.cues[2].text, "THIRD LINE",
               "a final cue with no trailing blank line is read");
  }
}

void testSubRipTolerance() {
  // CRLF, a BOM, '.' instead of ',', a duplicated index and a missing index.
  const std::string srt =
      "\xEF\xBB\xBF"
      "7\r\n"
      "00:00:01.000 --> 00:00:02.000\r\n"
      "dotted\r\n"
      "\r\n"
      "7\r\n"
      "0:00:03,000 --> 0:00:04,000\r\n"
      "short hours\r\n"
      "\r\n"
      "00:00:05,000 --> 00:00:06,000\r\n"
      "no index\r\n";
  const ParsedFile parsed = parseSubRip(srt);
  expect(parsed.cues.size() == 3, "a tolerant SRT yields all three cues");
  if (parsed.cues.size() == 3) {
    expectText(parsed.cues[0].text, "dotted",
               "a '.' millisecond separator is accepted");
    expectText(parsed.cues[1].text, "short hours",
               "a one-digit hour field is accepted");
    expectText(parsed.cues[2].text, "no index",
               "a cue with no index line is accepted");
  }
  // SRT position coordinates trail the end timestamp and must be ignored.
  const ParsedFile positioned = parseSubRip(
      "1\n00:00:01,000 --> 00:00:02,000 X1:100 X2:200 Y1:1 Y2:2\ntext\n");
  expect(positioned.cues.size() == 1,
         "trailing SRT position coordinates do not break the timing line");
}

void testMalformedInput() {
  expect(parseSubRip("").cues.empty(), "an empty file yields no cues");
  expect(!parseSubRip("").error.empty(), "an empty file reports a reason");
  expect(parseSubRip("not a subtitle file at all\n").cues.empty(),
         "prose is not read as cues");
  // A block whose timing line is unreadable is skipped; the ones around it are
  // not lost with it.
  const ParsedFile mixed = parseSubRip(
      "1\n00:00:01,000 --> 00:00:02,000\ngood one\n"
      "\n"
      "2\n99:99 broken --> nonsense\nbad\n"
      "\n"
      "3\n00:00:05,000 --> 00:00:06,000\ngood two\n");
  expect(mixed.cues.size() == 2,
         "a malformed block is skipped without losing its neighbours");
  // End before start is not a cue.
  const ParsedFile inverted =
      parseSubRip("1\n00:00:09,000 --> 00:00:02,000\nbackwards\n");
  expect(inverted.cues.empty(), "a cue that ends before it starts is dropped");
  // Zero-length is equally unshowable.
  const ParsedFile empty =
      parseSubRip("1\n00:00:02,000 --> 00:00:02,000\nzero\n");
  expect(empty.cues.empty(), "a zero-length cue is dropped");
  // A timing line with a truncated timestamp must not be half-accepted.
  const ParsedFile truncated =
      parseSubRip("1\n00:00: --> 00:00:02,000\nragged\n");
  expect(truncated.cues.empty(), "a truncated timestamp is refused");
}

void testAssFileParsing() {
  const std::string ass =
      "[Script Info]\n"
      "ScriptType: v4.00+\n"
      "\n"
      "[V4+ Styles]\n"
      "Format: Name, Fontname\n"
      "Style: Default,Arial\n"
      "\n"
      "[Events]\n"
      "Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, "
      "Effect, Text\n"
      "Dialogue: 0,0:00:01.00,0:00:04.00,Default,,0,0,0,,{\\i1}one{\\i0}\n"
      "Dialogue: 0,0:00:05.00,0:00:08.00,Default,,0,0,0,,two\\Nrows\n"
      "Comment: 0,0:00:09.00,0:00:10.00,Default,,0,0,0,,ignored\n";
  const ParsedFile parsed = parseAss(ass);
  expect(parsed.cues.size() == 2, "two ASS dialogues are read");
  if (parsed.cues.size() == 2) {
    expect(parsed.cues[0].startNanoseconds == 1 * kSecond,
           "ASS centisecond timestamps parse exactly");
    expectText(parsed.cues[0].text, "one", "ASS override tags are stripped");
    expectText(parsed.cues[1].text, "two\nrows", "ASS hard breaks survive");
  }
  // A Comment: line is not a Dialogue: line and must not be shown.
  for (const Cue& cue : parsed.cues)
    expect(cue.text != "ignored", "Comment lines are not shown");
  // Centiseconds, not milliseconds: 0:00:00.05 is 50 ms.
  const ParsedFile centi = parseAss(
      "[Events]\nFormat: Layer, Start, End, Text\n"
      "Dialogue: 0,0:00:00.05,0:00:01.00,x\n");
  expect(centi.cues.size() == 1 &&
             centi.cues[0].startNanoseconds == 50'000'000,
         "a two-digit ASS fraction is centiseconds");
}

void testWebVttFileParsing() {
  const std::string vtt =
      "WEBVTT\n"
      "\n"
      "NOTE this is a comment\n"
      "that spans two lines\n"
      "\n"
      "cue-identifier\n"
      "00:00:01.000 --> 00:00:04.000 line:0 position:50%\n"
      "<v Speaker>hello</v>\n"
      "\n"
      "00:05.000 --> 00:08.000\n"
      "short form\n";
  const ParsedFile parsed = parseWebVtt(vtt);
  expect(parsed.cues.size() == 2, "two WebVTT cues are read");
  if (parsed.cues.size() == 2) {
    expectText(parsed.cues[0].text, "hello",
               "WebVTT voice tags are stripped");
    expect(parsed.cues[1].startNanoseconds == 5 * kSecond,
           "the mm:ss.mmm short form parses");
  }
  for (const Cue& cue : parsed.cues) {
    expect(cue.text.find("comment") == std::string::npos,
           "a NOTE block's body is never shown");
  }
}

void testFormatSniffing() {
  const std::string ass = "[Script Info]\nScriptType: v4.00+\n[Events]\n"
                          "Format: Layer, Start, End, Text\n"
                          "Dialogue: 0,0:00:01.00,0:00:02.00,sniffed\n";
  // Content wins over a wrong extension: an .srt holding ASS is common.
  const ParsedFile byContent = parseSubtitleFile(ass, "srt");
  expect(byContent.cues.size() == 1 && byContent.cues[0].text == "sniffed",
         "ASS content is detected despite an .srt extension");
  const std::string vtt = "WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nv\n";
  expect(parseSubtitleFile(vtt, "srt").cues.size() == 1,
         "a WEBVTT header is detected despite an .srt extension");
  const std::string srt = "1\n00:00:01,000 --> 00:00:02,000\ns\n";
  expect(parseSubtitleFile(srt, "").cues.size() == 1,
         "SubRip is the fallback with no usable hint");
}

void testFinalizeAndLookup() {
  std::vector<Cue> cues{
      {5 * kSecond, 8 * kSecond, "second"},
      {1 * kSecond, 4 * kSecond, "first"},
      {9 * kSecond, 9 * kSecond, "zero length"},
      {10 * kSecond, 12 * kSecond, ""},
  };
  finalizeCues(&cues, false);
  expect(cues.size() == 2, "empty and zero-length cues are removed");
  expect(cues.front().text == "first", "cues are sorted by start time");

  expect(cueIndexAt(cues, 0, -1) == -1, "before the first cue there is none");
  expect(cueIndexAt(cues, 1 * kSecond, -1) == 0,
         "a cue is live exactly at its start");
  expect(cueIndexAt(cues, 3 * kSecond, -1) == 0, "mid-cue resolves to that cue");
  expect(cueIndexAt(cues, 4 * kSecond, -1) == -1,
         "a cue is over exactly at its end");
  expect(cueIndexAt(cues, 6 * kSecond, -1) == 1, "the second cue resolves");
  expect(cueIndexAt(cues, 100 * kSecond, -1) == -1,
         "past the last cue there is none");

  // The hint is an optimization, never a correctness input: every wrong hint
  // must still give the right answer. This is what makes a seek safe.
  for (std::ptrdiff_t hint = -5; hint <= 5; ++hint) {
    expect(cueIndexAt(cues, 6 * kSecond, hint) == 1,
           "any hint, valid or not, yields the correct cue");
    expect(cueIndexAt(cues, 4'500'000'000, hint) == -1,
           "any hint yields no cue in a gap");
  }

  // Overlapping cues are legal and are NOT clamped by default.
  std::vector<Cue> overlapping{
      {1 * kSecond, 6 * kSecond, "long"},
      {2 * kSecond, 3 * kSecond, "short"},
  };
  finalizeCues(&overlapping, false);
  expect(overlapping[0].endNanoseconds == 6 * kSecond,
         "overlaps are preserved when clamping is off");
  expect(cueIndexAt(overlapping, 2'500'000'000, -1) == 1,
         "the later-starting cue wins an overlap");
  expect(cueIndexAt(overlapping, 4 * kSecond, -1) == 0,
         "after the short cue ends the long one is visible again");

  std::vector<Cue> clamped{
      {1 * kSecond, 6 * kSecond, "long"},
      {2 * kSecond, 3 * kSecond, "short"},
  };
  finalizeCues(&clamped, true);
  expect(clamped[0].endNanoseconds == 2 * kSecond,
         "clamping trims a cue to the next cue's start when asked");
}

void testCueCapacity() {
  // The parser must stop at the cue cap rather than grow without bound.
  std::string many;
  for (std::size_t i = 0; i < kMaximumCues + 32; ++i) {
    const std::size_t seconds = i;
    char block[128];
    std::snprintf(block, sizeof(block),
                  "%zu\n00:00:%02zu,000 --> 00:00:%02zu,500\nx\n\n", i + 1,
                  seconds % 60, seconds % 60);
    many += block;
  }
  const ParsedFile parsed = parseSubRip(many);
  expect(parsed.cues.size() <= kMaximumCues,
         "cue count never exceeds the cap");
  expect(parsed.truncated, "hitting the cap is reported as truncation");
}

}  // namespace

int main() {
  testCodecIdentification();
  testAssOverrideStripping();
  testAssDialoguePayload();
  testWebVttPayload();
  testNormalization();
  testSubRipParsing();
  testSubRipTolerance();
  testMalformedInput();
  testAssFileParsing();
  testWebVttFileParsing();
  testFormatSniffing();
  testFinalizeAndLookup();
  testCueCapacity();
  if (failures != 0) {
    std::cerr << failures << " subtitle text test(s) failed\n";
    return EXIT_FAILURE;
  }
  std::cout << "Subtitle text tests passed\n";
  return EXIT_SUCCESS;
}
