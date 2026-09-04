#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

#include "media/h264_caption_sei.hpp"

// Neutral CEA-608 ("line 21") caption decoder.
//
// CEA-608 is not a cue list. It is a byte stream of commands against a 15-row
// by 32-column character screen, at two bytes per frame per field. This class
// runs that machine and reports, with a timestamp, every moment the DISPLAYED
// screen changes. The caller turns those moments into cues.
//
// Because the stream is fed live from decoded pictures, captions ahead of the
// playhead are not known until they are read. That is inherent to the format,
// not a limitation of this implementation; a seek calls reset().
//
// Free of Qt and of Apple frameworks.
namespace wam::media::captions {

inline constexpr std::size_t kCaptionRows{15};
inline constexpr std::size_t kCaptionColumns{32};

// Which of the four 608 caption channels to decode. CC1 is the primary
// language on field 1 and is what essentially all US content uses; the others
// are selectable so a second language is a policy choice, not a rewrite.
enum class Cea608Channel : std::uint8_t {
  Cc1,  // field 1, channel 1
  Cc2,  // field 1, channel 2
  Cc3,  // field 2, channel 1
  Cc4,  // field 2, channel 2
};

enum class Cea608Mode : std::uint8_t {
  None,
  PopOn,    // RCL: load off-screen, EOC flips it into view
  RollUp,   // RU2/RU3/RU4: base row plus 1..3 rows above, CR scrolls
  PaintOn,  // RDC: written straight to the displayed screen
};

// One moment at which the displayed caption changed. `text` is the whole
// screen rendered as lines joined by '\n', with trailing blank rows removed;
// it is empty when the screen was cleared.
struct Cea608Update {
  std::int64_t timeNanoseconds{0};
  std::string text;
  Cea608Mode mode{Cea608Mode::None};
  // Topmost occupied row (1..15), or 0 when the screen is empty. Carried so a
  // future overlay can honour vertical placement; v1 ignores it.
  std::uint8_t topRow{0};
};

// Bounds: an update queue that is never drained cannot grow without limit.
inline constexpr std::size_t kMaximumPendingUpdates{4'096};

class Cea608Decoder {
 public:
  explicit Cea608Decoder(Cea608Channel channel = Cea608Channel::Cc1) noexcept
      : channel_(channel) {}

  // Feeds one triplet carried by the picture presented at `timeNanoseconds`.
  // Triplets whose field does not match the selected channel, whose cc_valid
  // bit is clear, or whose parity is wrong are discarded here.
  void feed(std::int64_t timeNanoseconds, const CcTriplet& triplet);

  // Feeds every triplet of one picture, in order.
  void feedPicture(std::int64_t timeNanoseconds,
                   const std::vector<CcTriplet>& triplets);

  // Hands over and clears the pending updates.
  [[nodiscard]] std::vector<Cea608Update> takeUpdates();

  // Discards all state. Called on a seek: the caption stream is resynchronized
  // by the next pop-on or roll-up command, exactly as a television does.
  void reset();

  // True once any valid caption byte for the selected channel has been seen,
  // which is what makes the "Closed Captions" entry appear in the menu.
  [[nodiscard]] bool sawCaptions() const noexcept { return sawCaptions_; }

  // Counters, for tests and for the diagnostic line.
  [[nodiscard]] std::size_t parityErrors() const noexcept {
    return parityErrors_;
  }
  [[nodiscard]] std::size_t droppedUpdates() const noexcept {
    return droppedUpdates_;
  }

 private:
  struct Screen {
    std::array<std::array<char32_t, kCaptionColumns>, kCaptionRows> cells{};
    void clear() noexcept;
    [[nodiscard]] bool empty() const noexcept;
    [[nodiscard]] std::string render(std::uint8_t* topRow) const;
    void clearRow(std::size_t row) noexcept;
  };

  void handleControl(std::int64_t t, std::uint8_t b1, std::uint8_t b2);
  void handlePreambleAddress(std::uint8_t b1, std::uint8_t b2);
  void handleMidRow(std::uint8_t b2);
  void handleMiscControl(std::int64_t t, std::uint8_t b2);
  void putCharacter(char32_t c);
  void replaceLastCharacter(char32_t c);
  void carriageReturn(std::int64_t t);
  void publish(std::int64_t t);

  [[nodiscard]] Screen& target() noexcept {
    return mode_ == Cea608Mode::PopOn ? nonDisplayed_ : displayed_;
  }

  Cea608Channel channel_;
  Screen displayed_{};
  Screen nonDisplayed_{};
  Cea608Mode mode_{Cea608Mode::None};
  std::size_t row_{kCaptionRows - 1};  // 0-based; row 15 is the bottom
  std::size_t column_{0};
  std::size_t rollUpRows_{2};
  bool underline_{false};
  bool italic_{false};
  // The channel bit carried by the last PAC/control, so channel 2 traffic on
  // the same field is ignored without being mistaken for text.
  bool channelSelectsSecond_{false};
  std::uint16_t lastControl_{0xFFFF};
  // The last screen this decoder reported, so "nothing changed" is judged
  // against what the caller was actually told rather than against the tail of
  // a queue the caller may already have drained. Starts empty because an
  // untouched screen shows nothing, which is why loading a pop-on caption
  // off-screen must not produce an update.
  std::string lastPublished_;
  bool sawCaptions_{false};
  std::size_t parityErrors_{0};
  std::size_t droppedUpdates_{0};
  std::vector<Cea608Update> updates_;
};

// Maps one basic-North-American byte (0x20..0x7F) to its character. The set is
// ASCII with nine substitutions, which is why a naive ASCII cast produces
// "Ni~no" where a decoder should produce "Niño".
[[nodiscard]] char32_t cea608BasicCharacter(std::uint8_t byte) noexcept;

// What this decoder deliberately does not do, as a named list:
//   - CEA-708 window/pen/style commands. The 708 wrapper's 608-compatibility
//     bytes (cc_type 0 and 1) are decoded; cc_type 2/3 DTVCC packets are
//     collected by the SEI layer and dropped here.
//   - Colour and flash-on attributes from PACs and mid-row codes. Underline
//     and italics are tracked but the v1 overlay renders neither.
//   - Horizontal placement: the PAC's indent and the column are decoded and
//     tracked, but every cue is presented bottom-centre.
//   - Text mode (TR/RTD), which carries non-caption text services.
inline constexpr std::string_view kDroppedCea608Features{
    "cea-608: DTVCC 708 windows/styling, colour, flash, horizontal placement "
    "and text-mode services are not carried; pop-on, roll-up, paint-on, the "
    "full character set, and vertical row tracking are"};

}  // namespace wam::media::captions
