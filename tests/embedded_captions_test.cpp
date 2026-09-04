#include <cstdlib>
#include <iostream>
#include <string>
#include <vector>

#include "media/cea608_decoder.hpp"
#include "media/h264_caption_sei.hpp"
#include "media/mp4_subtitles.hpp"
#include "media/tx3g_text.hpp"

namespace {

using namespace wam::media::subtitles;
using namespace wam::media::captions;

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

std::string bytes(std::initializer_list<int> values) {
  std::string out;
  out.reserve(values.size());
  for (const int v : values) out.push_back(static_cast<char>(v));
  return out;
}

// A tx3g sample: 16-bit big-endian length, UTF-8 text, then optional boxes.
std::string tx3gSample(const std::string& text, const std::string& boxes = {}) {
  std::string out;
  out.push_back(static_cast<char>((text.size() >> 8) & 0xFF));
  out.push_back(static_cast<char>(text.size() & 0xFF));
  out += text;
  out += boxes;
  return out;
}

// A 'styl' box holding one style record.
std::string stylBox(std::initializer_list<std::array<int, 4>> records) {
  std::string body;
  body.push_back(0);
  body.push_back(static_cast<char>(records.size()));
  for (const auto& r : records) {
    // startChar, endChar, fontId=1, faceFlags, fontSize=0x10, colour=white
    body += bytes({(r[0] >> 8) & 0xFF, r[0] & 0xFF, (r[1] >> 8) & 0xFF,
                   r[1] & 0xFF, 0x00, 0x01, r[2], r[3]});
    body += bytes({0xFF, 0xFF, 0xFF, 0xFF});
  }
  const std::size_t size = body.size() + 8;
  std::string out = bytes({static_cast<int>((size >> 24) & 0xFF),
                           static_cast<int>((size >> 16) & 0xFF),
                           static_cast<int>((size >> 8) & 0xFF),
                           static_cast<int>(size & 0xFF)});
  out += "styl";
  out += body;
  return out;
}

// ---------------------------------------------------------------------------
// tx3g
// ---------------------------------------------------------------------------

void testTx3gPlainSample() {
  Tx3gSample sample;
  expect(decodeTx3gSample(tx3gSample("WAM CAPTION ONE"), &sample),
         "a plain tx3g sample decodes");
  expectText(sample.text, "WAM CAPTION ONE", "plain tx3g text");
  expect(!sample.clearsScreen, "a text sample does not clear the screen");
  expect(sample.styles.empty(), "a plain sample carries no styles");
  expect(!sample.malformed, "a plain sample is well formed");
}

void testTx3gEmptySampleClears() {
  // A zero-length sample is the format's explicit "nothing on screen"; it must
  // NOT be reported as an empty cue, which would leave the previous text up.
  Tx3gSample sample;
  expect(decodeTx3gSample(tx3gSample(""), &sample), "an empty sample decodes");
  expect(sample.clearsScreen, "a zero-length sample clears the screen");
  expect(sample.text.empty(), "a clearing sample has no text");
}

void testTx3gTooShortIsRefused() {
  Tx3gSample sample;
  expect(!decodeTx3gSample("", &sample), "an empty buffer is refused");
  expect(!decodeTx3gSample(std::string(1, '\0'), &sample),
         "a one-byte buffer cannot hold the length field");
}

void testTx3gStyleRecords() {
  // "plain then BOLD tail": bold over chars 11..15, exactly as ffmpeg's
  // mov_text encoder writes it (verified against a real muxed specimen).
  const std::string sample = tx3gSample(
      "plain then BOLD tail",
      stylBox({{11, 15, Tx3gStyleRecord::kBold, 0x10}}));
  Tx3gSample decoded;
  expect(decodeTx3gSample(sample, &decoded), "a styled sample decodes");
  expectText(decoded.text, "plain then BOLD tail", "styled sample text");
  expect(decoded.styles.size() == 1, "one style span survives");
  if (decoded.styles.size() == 1) {
    const Tx3gStyleSpan& span = decoded.styles[0];
    expect(span.startByte == 11 && span.endByte == 15,
           "the bold span covers exactly BOLD");
    expect(span.bold && !span.italic && !span.underline,
           "the span is bold only");
    expectText(decoded.text.substr(span.startByte,
                                   span.endByte - span.startByte),
               "BOLD", "the span indexes the intended word");
  }
}

void testTx3gFaceStyleFlags() {
  const std::string sample = tx3gSample(
      "abcdef", stylBox({{0, 6, Tx3gStyleRecord::kItalic |
                                    Tx3gStyleRecord::kUnderline,
                          0x10}}));
  Tx3gSample decoded;
  expect(decodeTx3gSample(sample, &decoded), "italic+underline decodes");
  expect(decoded.styles.size() == 1, "one combined span");
  if (decoded.styles.size() == 1) {
    expect(!decoded.styles[0].bold && decoded.styles[0].italic &&
               decoded.styles[0].underline,
           "italic and underline both survive, bold does not");
  }
}

void testTx3gStyleOffsetsAreUtf16() {
  // "AB" then U+1F600 (one 4-byte UTF-8 sequence, TWO UTF-16 code units) then
  // "CD". A style over UTF-16 units 4..6 is "CD" -- byte offsets 6..8.
  const std::string text = "AB\xF0\x9F\x98\x80" "CD";
  Tx3gSample decoded;
  expect(decodeTx3gSample(
             tx3gSample(text, stylBox({{4, 6, Tx3gStyleRecord::kBold, 0x10}})),
             &decoded),
         "an astral-plane sample decodes");
  expect(decoded.styles.size() == 1, "one span across a surrogate pair");
  if (decoded.styles.size() == 1) {
    expectText(decoded.text.substr(decoded.styles[0].startByte,
                                   decoded.styles[0].endByte -
                                       decoded.styles[0].startByte),
               "CD", "UTF-16 style offsets resolve to the right UTF-8 bytes");
  }
}

void testTx3gMalformedBoxIsSurvivable() {
  // A box claiming more bytes than the sample holds: the text still shows.
  std::string sample = tx3gSample("VISIBLE");
  sample += bytes({0x00, 0x00, 0xFF, 0x00});
  sample += "styl";
  Tx3gSample decoded;
  expect(decodeTx3gSample(sample, &decoded), "a truncated box still decodes");
  expectText(decoded.text, "VISIBLE", "text survives a malformed trailing box");
  expect(decoded.malformed, "the sample is reported malformed");
}

void testTx3gOutOfRangeStyleIsClamped() {
  Tx3gSample decoded;
  expect(decodeTx3gSample(
             tx3gSample("SHORT", stylBox({{0, 999, Tx3gStyleRecord::kBold,
                                           0x10}})),
             &decoded),
         "an over-long style range decodes");
  expect(decoded.malformed, "an out-of-range style range is reported");
  if (decoded.styles.size() == 1) {
    expect(decoded.styles[0].endByte <= decoded.text.size(),
           "the span is clamped inside the text");
  }
}

// ---------------------------------------------------------------------------
// A/53 SEI extraction
// ---------------------------------------------------------------------------

// Builds one SEI NAL (no start code) carrying `count` cc triplets.
std::string ccSeiNal(const std::vector<CcTriplet>& triplets) {
  std::string payload;
  payload += bytes({0xB5, 0x00, 0x31});
  payload += "GA94";
  payload += bytes({0x03});
  payload += bytes({0x40 | static_cast<int>(triplets.size())});
  payload += bytes({0x00});
  for (const CcTriplet& t : triplets) {
    const int marker = 0xF8 | (t.valid ? 0x04 : 0x00) |
                       static_cast<int>(t.type);
    payload += bytes({marker, t.data1, t.data2});
  }
  payload += bytes({0xFF});

  std::string sei;
  sei += bytes({0x06});  // NAL header: type 6
  sei += bytes({0x04});  // payloadType = user_data_registered_itu_t_t35
  sei += bytes({static_cast<int>(payload.size())});
  sei += payload;
  sei += bytes({0x80});  // rbsp trailing
  return sei;
}

CcTriplet field1(int b1, int b2) {
  CcTriplet t;
  t.type = CcType::Ntsc608Field1;
  t.valid = true;
  t.data1 = static_cast<std::uint8_t>(b1);
  t.data2 = static_cast<std::uint8_t>(b2);
  return t;
}

void testSeiExtractsTriplets() {
  const std::string nal = ccSeiNal({field1(0x94, 0x2F), field1(0x80, 0x80)});
  std::vector<CcTriplet> out;
  const std::size_t n = appendCaptionTripletsFromSeiRbsp(nal, &out);
  expect(n == 2, "two triplets are extracted");
  expect(out.size() == 2, "two triplets are appended");
  if (out.size() == 2) {
    expect(out[0].type == CcType::Ntsc608Field1 && out[0].valid,
           "the first triplet is a valid 608 field-1 pair");
    expect(out[0].data1 == 0x94 && out[0].data2 == 0x2F,
           "the caption bytes survive intact");
  }
}

void testSeiIgnoresForeignPayloads() {
  // A picture-timing SEI (type 1) followed by our cc_data message.
  std::string sei;
  sei += bytes({0x06, 0x01, 0x03, 0xAA, 0xBB, 0xCC});
  const std::string cc = ccSeiNal({field1(0x14, 0x20)});
  sei += cc.substr(1);  // drop the duplicate NAL header
  std::vector<CcTriplet> out;
  expect(appendCaptionTripletsFromSeiRbsp(sei, &out) == 1,
         "a non-caption SEI message is skipped, the caption one is read");
}

void testSeiRejectsWrongCountryOrProvider() {
  std::string nal = ccSeiNal({field1(0x14, 0x20)});
  // Country code byte sits right after NAL header + payloadType + payloadSize.
  nal[3] = static_cast<char>(0xB6);
  std::vector<CcTriplet> out;
  expect(appendCaptionTripletsFromSeiRbsp(nal, &out) == 0,
         "a non-USA T.35 country code is not a caption payload");
}

void testSeiHonoursProcessFlag() {
  std::string nal = ccSeiNal({field1(0x14, 0x20)});
  const std::size_t flagsIndex = 3 + 3 + 4 + 1;
  nal[flagsIndex] = static_cast<char>(0x01);  // process_cc_data_flag clear
  std::vector<CcTriplet> out;
  expect(appendCaptionTripletsFromSeiRbsp(nal, &out) == 0,
         "cc_data with process_cc_data_flag clear is not processed");
}

void testEmulationPreventionRemoval() {
  const std::string escaped = bytes({0x00, 0x00, 0x03, 0x01, 0x00, 0x00, 0x03,
                                     0x02});
  const std::vector<char> rbsp = removeEmulationPrevention(escaped);
  const std::string got(rbsp.data(), rbsp.size());
  expectText(got, bytes({0x00, 0x00, 0x01, 0x00, 0x00, 0x02}),
             "emulation-prevention bytes are removed");
}

void testAnnexBWalk() {
  std::string stream;
  stream += bytes({0x00, 0x00, 0x00, 0x01, 0x67, 0x42});  // SPS, ignored
  stream += bytes({0x00, 0x00, 0x01});
  stream += ccSeiNal({field1(0x14, 0x2F)});
  stream += bytes({0x00, 0x00, 0x00, 0x01, 0x65, 0x88});  // IDR slice
  std::vector<CcTriplet> out;
  expect(appendCaptionTripletsFromAnnexB(stream, &out) == 1,
         "the Annex-B walker finds the caption SEI among other NALs");
}

void testAvccWalk() {
  const std::string nal = ccSeiNal({field1(0x14, 0x2F)});
  std::string sample;
  const std::size_t n = nal.size();
  sample += bytes({static_cast<int>((n >> 24) & 0xFF),
                   static_cast<int>((n >> 16) & 0xFF),
                   static_cast<int>((n >> 8) & 0xFF),
                   static_cast<int>(n & 0xFF)});
  sample += nal;
  std::vector<CcTriplet> out;
  expect(appendCaptionTripletsFromAvcc(sample, 4, &out) == 1,
         "a 4-byte length-prefixed sample yields its caption SEI");
  out.clear();
  expect(appendCaptionTripletsFromAvcc(sample, 3, &out) == 0,
         "an unsupported length size is refused rather than misparsed");
}

void testTruncatedSeiDoesNotOverrun() {
  std::string nal = ccSeiNal({field1(0x14, 0x2F)});
  nal.resize(nal.size() - 4);
  std::vector<CcTriplet> out;
  // The contract is only that this terminates and reports honestly.
  appendCaptionTripletsFromSeiRbsp(nal, &out);
  expect(true, "a truncated SEI does not overrun");
}

// ---------------------------------------------------------------------------
// CEA-608
// ---------------------------------------------------------------------------

std::uint8_t oddParity(std::uint8_t b) {
  std::uint8_t v = b & 0x7F;
  std::uint8_t p = v;
  p ^= static_cast<std::uint8_t>(p >> 4);
  p ^= static_cast<std::uint8_t>(p >> 2);
  p ^= static_cast<std::uint8_t>(p >> 1);
  return (p & 1U) != 0U ? v : static_cast<std::uint8_t>(v | 0x80U);
}

CcTriplet pair608(int b1, int b2) {
  CcTriplet t;
  t.type = CcType::Ntsc608Field1;
  t.valid = true;
  t.data1 = oddParity(static_cast<std::uint8_t>(b1));
  t.data2 = oddParity(static_cast<std::uint8_t>(b2));
  return t;
}

// Feeds a control code the way a real encoder sends it: twice.
void feedControl(Cea608Decoder* d, std::int64_t t, int b1, int b2) {
  d->feed(t, pair608(b1, b2));
  d->feed(t, pair608(b1, b2));
}

void feedText(Cea608Decoder* d, std::int64_t t, const std::string& s) {
  for (std::size_t i = 0; i < s.size(); i += 2) {
    const int a = s[i];
    const int b = (i + 1 < s.size()) ? s[i + 1] : 0x00;
    d->feed(t, pair608(a, b));
  }
}

std::string lastText(Cea608Decoder* d) {
  const std::vector<Cea608Update> updates = d->takeUpdates();
  return updates.empty() ? std::string("<no update>") : updates.back().text;
}

void testCea608PopOn() {
  Cea608Decoder d;
  feedControl(&d, 0, 0x14, 0x20);  // RCL
  feedControl(&d, 0, 0x14, 0x2E);  // ENM
  feedControl(&d, 0, 0x14, 0x60);  // PAC row 15
  feedText(&d, 0, "HELLO");
  // Nothing is displayed until EOC flips the memories.
  expect(d.takeUpdates().empty(), "pop-on text is not shown before EOC");
  feedControl(&d, 1000, 0x14, 0x2F);  // EOC
  expectText(lastText(&d), "HELLO", "EOC displays the loaded caption");
}

void testCea608PopOnErase() {
  Cea608Decoder d;
  feedControl(&d, 0, 0x14, 0x20);
  feedControl(&d, 0, 0x14, 0x60);
  feedText(&d, 0, "GONE");
  feedControl(&d, 10, 0x14, 0x2F);
  expectText(lastText(&d), "GONE", "caption shows");
  feedControl(&d, 20, 0x14, 0x2C);  // EDM
  expectText(lastText(&d), "", "EDM erases the displayed caption");
}

void testCea608DoubledControlIsNotRepeated() {
  // The doubled EOC must flip the memories ONCE. If the duplicate were acted
  // on, the second swap would put the (now empty) buffer back on screen.
  Cea608Decoder d;
  feedControl(&d, 0, 0x14, 0x20);
  feedControl(&d, 0, 0x14, 0x60);
  feedText(&d, 0, "ONCE");
  feedControl(&d, 10, 0x14, 0x2F);
  expectText(lastText(&d), "ONCE", "a doubled EOC displays the caption once");
}

void testCea608TwoRows() {
  Cea608Decoder d;
  feedControl(&d, 0, 0x14, 0x20);
  feedControl(&d, 0, 0x14, 0x40);  // PAC row 14
  feedText(&d, 0, "TOP");
  feedControl(&d, 0, 0x14, 0x60);  // PAC row 15
  feedText(&d, 0, "BOTTOM");
  feedControl(&d, 10, 0x14, 0x2F);
  expectText(lastText(&d), "TOP\nBOTTOM", "two rows render in row order");
}

void testCea608RollUp() {
  Cea608Decoder d;
  feedControl(&d, 0, 0x14, 0x26);  // RU3
  feedControl(&d, 0, 0x14, 0x60);  // base row 15
  feedText(&d, 0, "LINE A");
  expectText(lastText(&d), "LINE A", "roll-up text appears as it is written");
  feedControl(&d, 10, 0x14, 0x2D);  // CR
  feedText(&d, 10, "LINE B");
  expectText(lastText(&d), "LINE A\nLINE B", "CR scrolls and adds a line");
  feedControl(&d, 20, 0x14, 0x2D);
  feedText(&d, 20, "LINE C");
  expectText(lastText(&d), "LINE A\nLINE B\nLINE C",
             "a 3-row roll-up holds three lines");
  feedControl(&d, 30, 0x14, 0x2D);
  feedText(&d, 30, "LINE D");
  expectText(lastText(&d), "LINE B\nLINE C\nLINE D",
             "the oldest line rolls off the top of a 3-row window");
}

void testCea608ParityIsChecked() {
  Cea608Decoder d;
  CcTriplet bad = pair608('A', 'B');
  bad.data1 ^= 0x80;  // break the parity bit
  d.feed(0, bad);
  expect(d.parityErrors() == 1, "a parity error is counted");
  expect(d.takeUpdates().empty(), "a parity-failed pair puts nothing on screen");
}

void testCea608IgnoresOtherField() {
  Cea608Decoder d(Cea608Channel::Cc1);
  CcTriplet t = pair608('X', 'Y');
  t.type = CcType::Ntsc608Field2;
  d.feed(0, t);
  expect(d.takeUpdates().empty(), "CC1 ignores field-2 traffic");
  CcTriplet dtvcc = pair608('X', 'Y');
  dtvcc.type = CcType::Dtvcc708Data;
  d.feed(0, dtvcc);
  expect(d.takeUpdates().empty(), "CC1 ignores DTVCC 708 packets");
}

void testCea608IgnoresInvalidTriplet() {
  Cea608Decoder d;
  CcTriplet t = pair608('X', 'Y');
  t.valid = false;
  d.feed(0, t);
  expect(d.takeUpdates().empty(), "a cc_valid=0 triplet is discarded");
}

void testCea608CharacterSet() {
  // 0x7E is 'ñ' in the basic North American set, not '~'.
  expect(cea608BasicCharacter(0x7E) == U'ñ', "0x7E decodes as n-tilde");
  expect(cea608BasicCharacter(0x5C) == U'é', "0x5C decodes as e-acute");
  expect(cea608BasicCharacter('A') == U'A', "ASCII letters are unchanged");
}

void testCea608SpecialCharacter() {
  Cea608Decoder d;
  feedControl(&d, 0, 0x14, 0x20);
  feedControl(&d, 0, 0x14, 0x60);
  feedText(&d, 0, "A");
  feedControl(&d, 0, 0x11, 0x37);  // special character: eighth note
  feedControl(&d, 10, 0x14, 0x2F);
  expectText(lastText(&d), "A♪", "a special character is written");
}

void testCea608Backspace() {
  Cea608Decoder d;
  feedControl(&d, 0, 0x14, 0x20);
  feedControl(&d, 0, 0x14, 0x60);
  feedText(&d, 0, "ABC");
  feedControl(&d, 0, 0x14, 0x21);  // BS
  feedControl(&d, 10, 0x14, 0x2F);
  expectText(lastText(&d), "AB", "backspace removes the last character");
}

void testCea608ResetClearsState() {
  Cea608Decoder d;
  feedControl(&d, 0, 0x14, 0x20);
  feedControl(&d, 0, 0x14, 0x60);
  feedText(&d, 0, "BEFORE");
  feedControl(&d, 10, 0x14, 0x2F);
  expectText(lastText(&d), "BEFORE", "the pre-seek caption showed");
  d.reset();
  expect(d.takeUpdates().empty(), "reset drops pending updates");
  // After a seek the machine restarts: the next caption must stand alone
  // rather than accumulating on top of what was on screen before.
  feedControl(&d, 20, 0x14, 0x20);
  feedControl(&d, 20, 0x14, 0x60);
  feedText(&d, 20, "AFTER");
  feedControl(&d, 30, 0x14, 0x2F);
  expectText(lastText(&d), "AFTER",
             "after reset a new caption replaces, not appends to, the old one");
}

void testCea608SawCaptions() {
  Cea608Decoder d;
  expect(!d.sawCaptions(), "no captions seen before any valid byte");
  feedControl(&d, 0, 0x14, 0x20);
  expect(d.sawCaptions(), "a valid control byte marks the stream as captioned");
}

void testCea608PaddingDoesNotDisturb() {
  Cea608Decoder d;
  feedControl(&d, 0, 0x14, 0x20);
  feedControl(&d, 0, 0x14, 0x60);
  feedText(&d, 0, "AB");
  d.feed(1, pair608(0x00, 0x00));  // padding between characters
  feedText(&d, 2, "CD");
  feedControl(&d, 10, 0x14, 0x2F);
  expectText(lastText(&d), "ABCD", "null padding does not break a caption");
}

void testCea608UpdateQueueIsBounded() {
  Cea608Decoder d;
  feedControl(&d, 0, 0x14, 0x26);  // roll-up, so every character publishes
  feedControl(&d, 0, 0x14, 0x60);
  for (std::size_t i = 0; i < kMaximumPendingUpdates + 64; ++i) {
    // Erase, re-home the cursor, then write: the screen genuinely alternates
    // between "" and "X", so every step is a real change and the queue grows.
    const auto t = static_cast<std::int64_t>(i);
    feedControl(&d, t, 0x14, 0x2C);  // EDM -> ""
    feedControl(&d, t, 0x14, 0x60);  // PAC row 15, column 0
    feedText(&d, t, "X");            // -> "X"
  }
  const std::vector<Cea608Update> updates = d.takeUpdates();
  expect(updates.size() <= kMaximumPendingUpdates,
         "the pending-update queue never exceeds its bound");
  expect(d.droppedUpdates() > 0, "overflow beyond the bound is reported");
}

// ---------------------------------------------------------------------------
// MP4 track inventory
// ---------------------------------------------------------------------------

std::string box(const std::string& type, const std::string& body) {
  const std::size_t size = body.size() + 8;
  std::string out = bytes({static_cast<int>((size >> 24) & 0xFF),
                           static_cast<int>((size >> 16) & 0xFF),
                           static_cast<int>((size >> 8) & 0xFF),
                           static_cast<int>(size & 0xFF)});
  out += type;
  out += body;
  return out;
}

std::string u32be(std::uint32_t v) {
  return bytes({static_cast<int>((v >> 24) & 0xFF),
                static_cast<int>((v >> 16) & 0xFF),
                static_cast<int>((v >> 8) & 0xFF), static_cast<int>(v & 0xFF)});
}

// A minimal but structurally real moov holding one timed-text track.
std::string syntheticMoov(const std::string& handler,
                          const std::string& sampleFormat,
                          std::uint32_t trackId, std::uint16_t packedLanguage) {
  // tkhd v0: version/flags(4) creation(4) modification(4) track_id(4) ...
  std::string tkhd = u32be(0x00000001);  // flags: enabled
  tkhd += u32be(0) + u32be(0) + u32be(trackId) + u32be(0) + u32be(0);
  // mdhd v0: version/flags(4) creation(4) modification(4) timescale(4)
  //          duration(4) language(2) quality(2)
  std::string mdhd = u32be(0) + u32be(0) + u32be(0) + u32be(1000) + u32be(0);
  mdhd += bytes({(packedLanguage >> 8) & 0xFF, packedLanguage & 0xFF, 0, 0});
  // hdlr: version/flags(4) pre_defined(4) handler(4) reserved(12) name
  std::string hdlr = u32be(0) + u32be(0) + handler + u32be(0) + u32be(0) +
                     u32be(0) + std::string(1, '\0');
  // stsd: version/flags(4) entry_count(4) then one sample entry box
  std::string stsd = u32be(0) + u32be(1) + box(sampleFormat, std::string(8, '\0'));
  const std::string stbl = box("stbl", box("stsd", stsd) +
                                           box("stsz", u32be(0) + u32be(0) +
                                                           u32be(0)));
  const std::string minf = box("minf", stbl);
  const std::string mdia = box("mdia", box("mdhd", mdhd) + box("hdlr", hdlr) +
                                           minf);
  return box("moov", box("trak", box("tkhd", tkhd) + mdia));
}

void testMp4LanguageUnpacking() {
  // 'e','n','g' packed as three 5-bit letters offset from 0x60.
  const std::uint16_t eng = static_cast<std::uint16_t>(
      ((('e' - 0x60) & 0x1F) << 10) | ((('n' - 0x60) & 0x1F) << 5) |
      (('g' - 0x60) & 0x1F));
  expectText(wam::media::mp4::unpackIso639Language(eng), "eng",
             "eng unpacks from its 5-bit packing");
  expectText(wam::media::mp4::unpackIso639Language(0), "und",
             "a zero language code is undetermined");
  expectText(wam::media::mp4::unpackIso639Language(0xFFFF), "und",
             "a language code with the high bit set is undetermined");
}

void testMp4InventoryFindsTx3gTrack() {
  const std::uint16_t fre = static_cast<std::uint16_t>(
      ((('f' - 0x60) & 0x1F) << 10) | ((('r' - 0x60) & 0x1F) << 5) |
      (('e' - 0x60) & 0x1F));
  const auto inventory = wam::media::mp4::inspectMp4SubtitleTracksInMemory(
      syntheticMoov("sbtl", "tx3g", 3, fre));
  expect(inventory.valid, "a synthetic moov parses");
  expect(inventory.tracks.size() == 1, "one timed-text track is found");
  if (inventory.tracks.size() == 1) {
    const auto& track = inventory.tracks[0];
    expect(track.trackId == 3, "the tkhd track_id is reported");
    expect(track.kind == wam::media::mp4::SubtitleTrackKind::Tx3gText,
           "an sbtl/tx3g track is timed text");
    expectText(track.language, "fre", "the mdhd language is reported");
    expect(track.enabled, "the tkhd enabled flag is read");
  }
}

void testMp4InventoryClassifiesClosedCaptionTrack() {
  const auto inventory = wam::media::mp4::inspectMp4SubtitleTracksInMemory(
      syntheticMoov("clcp", "c608", 2, 0));
  expect(inventory.tracks.size() == 1, "a clcp track is reported");
  if (inventory.tracks.size() == 1) {
    expect(inventory.tracks[0].kind ==
               wam::media::mp4::SubtitleTrackKind::ClosedCaptionTrack,
           "a clcp track is a closed-caption track, not timed text");
  }
}

void testMp4InventoryIgnoresAudioVideoTracks() {
  const auto inventory = wam::media::mp4::inspectMp4SubtitleTracksInMemory(
      syntheticMoov("vide", "avc1", 1, 0));
  expect(inventory.valid, "a video-only moov still parses");
  expect(inventory.tracks.empty(), "a video track is not a subtitle track");
}

void testMp4InventoryRejectsGarbage() {
  const auto inventory =
      wam::media::mp4::inspectMp4SubtitleTracksInMemory("not an mp4 at all");
  expect(inventory.tracks.empty(), "garbage yields no subtitle tracks");
}

}  // namespace

int main() {
  testTx3gPlainSample();
  testTx3gEmptySampleClears();
  testTx3gTooShortIsRefused();
  testTx3gStyleRecords();
  testTx3gFaceStyleFlags();
  testTx3gStyleOffsetsAreUtf16();
  testTx3gMalformedBoxIsSurvivable();
  testTx3gOutOfRangeStyleIsClamped();

  testSeiExtractsTriplets();
  testSeiIgnoresForeignPayloads();
  testSeiRejectsWrongCountryOrProvider();
  testSeiHonoursProcessFlag();
  testEmulationPreventionRemoval();
  testAnnexBWalk();
  testAvccWalk();
  testTruncatedSeiDoesNotOverrun();

  testCea608PopOn();
  testCea608PopOnErase();
  testCea608DoubledControlIsNotRepeated();
  testCea608TwoRows();
  testCea608RollUp();
  testCea608ParityIsChecked();
  testCea608IgnoresOtherField();
  testCea608IgnoresInvalidTriplet();
  testCea608CharacterSet();
  testCea608SpecialCharacter();
  testCea608Backspace();
  testCea608ResetClearsState();
  testCea608SawCaptions();
  testCea608PaddingDoesNotDisturb();
  testCea608UpdateQueueIsBounded();

  testMp4LanguageUnpacking();
  testMp4InventoryFindsTx3gTrack();
  testMp4InventoryClassifiesClosedCaptionTrack();
  testMp4InventoryIgnoresAudioVideoTracks();
  testMp4InventoryRejectsGarbage();

  if (failures != 0) {
    std::cerr << failures << " embedded caption test(s) failed\n";
    return EXIT_FAILURE;
  }
  std::cout << "Embedded caption tests passed\n";
  return EXIT_SUCCESS;
}
