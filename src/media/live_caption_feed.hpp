#pragma once

#include "media/cea608_decoder.hpp"
#include "media/h264_caption_sei.hpp"
#include "media/subtitle_text.hpp"

#include <cstddef>
#include <cstdint>
#include <map>
#include <mutex>
#include <string>
#include <string_view>
#include <vector>

// Closed captions carried INSIDE an H.264 stream (CEA-608 in A/53 SEI) have no
// track and no cue list: they are read as the pictures go by. This object is
// the live tap the video consumer feeds and the subtitle overlay reads, so the
// two sides -- a session worker and the GUI thread -- share one lock and one
// growing cue list.
//
// Caption bytes ride the compressed picture, which arrives in DECODE order,
// but the 608 machine must run in PRESENTATION order (A/53: cc_data is
// reordered to display order before interpretation). Triplets are therefore
// stashed per picture at consume time and fed when that picture is presented.
//
// Free of Qt and of Apple frameworks.
namespace wam::media::captions {

// Pictures decoded but never presented (a seek's preroll) leave their
// triplets stashed; the stash is bounded so such a run cannot grow it.
inline constexpr std::size_t kMaximumStashedPictures{64};
// A caption cue list is small (a two-hour programme is a few thousand cues);
// the bound keeps a pathological stream from growing without limit.
inline constexpr std::size_t kMaximumLiveCues{8'192};

class LiveCaptionFeed {
 public:
  // Records the triplets carried by one compressed H.264 picture. `sample` is
  // the length-prefixed (AVCC) access unit and `lengthSize` its NAL length
  // prefix width. Cheap when the picture carries no caption SEI.
  void noteCompressedPicture(std::int64_t presentationNanoseconds,
                             std::string_view sample, std::size_t lengthSize);

  // Feeds every stashed picture at or before `presentationNanoseconds` into
  // the 608 machine, in presentation order, and turns its screen changes into
  // cues.
  void notePresentedPicture(std::int64_t presentationNanoseconds);

  // Drops the stash, the open cue and the 608 state. Called on a seek: the
  // caption stream resynchronises at the next pop-on or roll-up command.
  // Cues already closed are kept, so scrubbing backwards over captioned
  // material still shows what was read.
  void resetForSeek();

  // Forgets everything, including whether captions were ever seen. Called
  // when the media changes.
  void clear();

  // Whether any valid caption byte has been read from this media. Decides
  // whether a "Closed Captions" source exists at all.
  [[nodiscard]] bool sawCaptions() const;

  // The caption text on screen at `presentationNanoseconds`, or empty.
  [[nodiscard]] std::string textAt(std::int64_t presentationNanoseconds) const;

  // Bumps whenever the cue list changes, so a reader can cache.
  [[nodiscard]] std::uint64_t revision() const;

 private:
  void applyUpdatesLocked();

  mutable std::mutex mutex_;
  Cea608Decoder decoder_;
  std::map<std::int64_t, std::vector<CcTriplet>> stash_;
  std::vector<subtitles::Cue> cues_;
  bool openCue_{false};
  std::int64_t openCueStart_{0};
  std::string openCueText_;
  std::uint64_t revision_{0};
  std::vector<CcTriplet> scratch_;
};

}  // namespace wam::media::captions
