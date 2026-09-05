#include "media/live_caption_feed.hpp"

#include <algorithm>
#include <limits>

namespace wam::media::captions {

void LiveCaptionFeed::noteCompressedPicture(
    std::int64_t presentationNanoseconds, std::string_view sample,
    std::size_t lengthSize) {
  scratch_.clear();
  if (appendCaptionTripletsFromAvcc(sample, lengthSize, &scratch_) == 0) {
    return;
  }
  std::lock_guard lock(mutex_);
  if (stash_.size() >= kMaximumStashedPictures) {
    stash_.erase(stash_.begin());
  }
  stash_[presentationNanoseconds] = scratch_;
}

void LiveCaptionFeed::notePresentedPicture(
    std::int64_t presentationNanoseconds) {
  std::lock_guard lock(mutex_);
  if (stash_.empty()) {
    return;
  }
  const auto end = stash_.upper_bound(presentationNanoseconds);
  for (auto it = stash_.begin(); it != end; ++it) {
    decoder_.feedPicture(it->first, it->second);
  }
  stash_.erase(stash_.begin(), end);
  applyUpdatesLocked();
}

void LiveCaptionFeed::applyUpdatesLocked() {
  for (const Cea608Update& update : decoder_.takeUpdates()) {
    if (openCue_) {
      if (update.timeNanoseconds > openCueStart_) {
        if (cues_.size() >= kMaximumLiveCues) {
          cues_.erase(cues_.begin());
        }
        cues_.push_back(subtitles::Cue{openCueStart_, update.timeNanoseconds,
                                       openCueText_});
      }
      openCue_ = false;
    }
    if (!update.text.empty()) {
      openCue_ = true;
      openCueStart_ = update.timeNanoseconds;
      openCueText_ = update.text;
    }
    ++revision_;
  }
}

void LiveCaptionFeed::resetForSeek() {
  std::lock_guard lock(mutex_);
  stash_.clear();
  decoder_.reset();
  openCue_ = false;
  ++revision_;
}

void LiveCaptionFeed::clear() {
  std::lock_guard lock(mutex_);
  stash_.clear();
  decoder_ = Cea608Decoder{};
  cues_.clear();
  openCue_ = false;
  ++revision_;
}

bool LiveCaptionFeed::sawCaptions() const {
  std::lock_guard lock(mutex_);
  return decoder_.sawCaptions();
}

std::string LiveCaptionFeed::textAt(
    std::int64_t presentationNanoseconds) const {
  std::lock_guard lock(mutex_);
  if (openCue_ && presentationNanoseconds >= openCueStart_) {
    return openCueText_;
  }
  const auto it = std::upper_bound(
      cues_.begin(), cues_.end(), presentationNanoseconds,
      [](std::int64_t t, const subtitles::Cue& cue) {
        return t < cue.startNanoseconds;
      });
  if (it == cues_.begin()) {
    return {};
  }
  const subtitles::Cue& cue = *(it - 1);
  return cue.covers(presentationNanoseconds) ? cue.text : std::string{};
}

std::uint64_t LiveCaptionFeed::revision() const {
  std::lock_guard lock(mutex_);
  return revision_;
}

}  // namespace wam::media::captions
