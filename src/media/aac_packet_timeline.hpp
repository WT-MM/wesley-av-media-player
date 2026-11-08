#pragma once
#include "media/audio_codec_timing.hpp"
#include <algorithm>
#include <vector>

namespace wam::media {
// Immutable after finish(). The observed stamps identify packets after any
// seek; presentation stamps and extents are the same proof used at open.
class AacPacketTimeline {
  static constexpr std::int64_t kAacFrames = codec::kAacLcSamplesPerAccessUnit;

public:
  struct Packet { MediaTime observed; std::int64_t start; std::int64_t duration; };
  explicit AacPacketTimeline(std::uint32_t rate)
      : rate_(rate) {}
  bool append(MediaTime pts, MediaTime duration) {
    if (packets_.size() == 2'000'000 || !pts.valid() || !duration.valid() || duration.value <= 0)
      return false;
    const auto exact = exactAudioFrameIndex(pts, rate_);
    if (packets_.empty()) {
      if (!exact) return false;
      origin_ = *exact;
    } else {
      if (compareMediaTime(pts, packets_.back().observed) != MediaTimeOrder::Greater) return false;
      // Packet durations describe timestamp jitter as well as real edits.
      // Only cumulative displacement from this segment's ORIGINAL grid can
      // establish a boundary. Inside the bound, all decoded PCM is contiguous.
      if (!projectAacPacketGrid(pts, origin_, packets_.size()-segmentOrdinal_, rate_)) {
        if (!exact) return false;
        // A short AU can cross the bound while its predecessor was projected
        // slightly late. The overlap then spans more than one decoded AU.
        // Walk that edit backwards, retaining positive extents for CoreMedia;
        // the aggregate trim is still exactly the single re-anchor shift.
        auto boundary = *exact;
        for (std::size_t i = packets_.size(); i > 0; --i) {
          auto& priorPacket = packets_[i-1];
          if (boundary > priorPacket.start) break;
          if (boundary == INT64_MIN || i == 1) return false;
          priorPacket.start = boundary-1;
          priorPacket.duration = 1;
          boundary = priorPacket.start;
        }
        for (std::size_t i = packets_.size()-1; i > 0; --i) {
          auto& previous = packets_[i-1];
          const auto extent = packets_[i].start-previous.start;
          if (previous.duration == extent) break;
          previous.duration = extent;
        }
        const __int128 extent = __int128(*exact) - packets_.back().start;
        if (extent > INT64_MAX) return false;
        packets_.back().duration = static_cast<std::int64_t>(extent);
        origin_ = *exact;
        segmentOrdinal_ = packets_.size();
      }
    }
    const auto projected = projectAacPacketGrid(pts, origin_, packets_.size()-segmentOrdinal_, rate_);
    if (!projected || projected->value > INT64_MAX-kAacFrames) return false;
    packets_.push_back({pts,projected->value,kAacFrames});
    previousDuration_ = duration;
    return true;
  }
  // A packet whose exact extent another codec proved (WMA v2's superframe
  // counts); it must continue the previous packet without a gap.
  bool appendExtent(MediaTime observed, std::int64_t start, std::int64_t duration) {
    if (packets_.size() == 2'000'000 || !observed.valid() || duration <= 0 ||
        start > INT64_MAX - duration ||
        (!packets_.empty() &&
         (compareMediaTime(observed, packets_.back().observed) != MediaTimeOrder::Greater ||
          start != packets_.back().start + packets_.back().duration)))
      return false;
    packets_.push_back({observed, start, duration});
    return true;
  }
  void extendLast(std::int64_t frames) { packets_.back().duration += frames; }
  bool finish(bool exactTail = true) {
    if (packets_.empty()) return false;
    const auto tail = exactTail ? exactAudioFrameIndex(previousDuration_,rate_) : std::optional<std::int64_t>(kAacFrames);
    if (!tail || *tail <= 0) return false;
    packets_.back().duration = std::min<std::int64_t>(*tail,kAacFrames);
    return packets_.back().start <= INT64_MAX-packets_.back().duration;
  }
  const Packet* find(MediaTime observed) const {
    const auto it = std::lower_bound(packets_.begin(),packets_.end(),observed,
        [](const Packet& p,MediaTime t){return compareMediaTime(p.observed,t)==MediaTimeOrder::Less;});
    return it!=packets_.end() && compareMediaTime(it->observed,observed)==MediaTimeOrder::Equal ? &*it : nullptr;
  }
  std::size_t indexAtFrame(std::int64_t frame) const {
    const auto it = std::upper_bound(packets_.begin(),packets_.end(),frame,
        [](std::int64_t f,const Packet& p){ return f < p.start; });
    return it == packets_.begin() ? 0 : static_cast<std::size_t>(it-packets_.begin()-1);
  }
  const std::vector<Packet>& packets() const { return packets_; }
  std::uint32_t rate() const { return rate_; }
private:
  std::uint32_t rate_;
  std::int64_t origin_{};
  std::size_t segmentOrdinal_{};
  MediaTime previousDuration_{};
  std::vector<Packet> packets_;
};
}
