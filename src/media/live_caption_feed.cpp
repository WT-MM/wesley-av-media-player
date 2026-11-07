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
    if (open_ && update.timeNanoseconds > open_->start)
      closeCueLocked(subtitles::Cue{open_->start, update.timeNanoseconds,
                                    std::move(open_->text)});
    open_.reset();
    if (!update.text.empty()) open_ = OpenCue{update.timeNanoseconds, update.text};
    ++revision_;
  }
}

void LiveCaptionFeed::closeCueLocked(subtitles::Cue cue) {
  const auto at = std::upper_bound(
      cues_.begin(), cues_.end(), cue.startNanoseconds,
      [](std::int64_t t, const subtitles::Cue& c) {
        return t < c.startNanoseconds;
      });
  // Already read before a backward seek.
  for (auto same = at; same != cues_.begin() &&
                       (same - 1)->startNanoseconds == cue.startNanoseconds;
       --same) {
    const subtitles::Cue& existing = *(same - 1);
    if (existing.endNanoseconds == cue.endNanoseconds &&
        existing.text == cue.text)
      return;
  }
  const auto index = at - cues_.begin();
  cues_.insert(cues_.begin() + index, std::move(cue));
  if (cues_.size() > kMaximumLiveCues) cues_.erase(cues_.begin());
}

void LiveCaptionFeed::resetForSeek() {
  std::lock_guard lock(mutex_);
  stash_.clear();
  decoder_.reset();
  open_.reset();
  ++revision_;
}

void LiveCaptionFeed::clear() {
  std::lock_guard lock(mutex_);
  stash_.clear();
  decoder_ = Cea608Decoder{};
  cues_.clear();
  open_.reset();
  ++revision_;
}

bool LiveCaptionFeed::sawCaptions() const {
  std::lock_guard lock(mutex_);
  return decoder_.sawCaptions();
}

std::string LiveCaptionFeed::textAt(
    std::int64_t presentationNanoseconds) const {
  std::lock_guard lock(mutex_);
  if (open_ && presentationNanoseconds >= open_->start) {
    return open_->text;
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
