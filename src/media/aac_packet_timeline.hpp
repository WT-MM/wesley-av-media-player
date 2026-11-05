#pragma once
#include "media/audio_codec_timing.hpp"
#include <algorithm>
#include <vector>

namespace wam::media {
// Immutable after finish(). The observed stamps identify packets after any
// seek; presentation stamps and extents are the same proof used at open.
class AacPacketTimeline {
public:
  struct Packet { MediaTime observed; std::int64_t start; std::int64_t duration; };
  explicit AacPacketTimeline(std::uint32_t rate, std::uint32_t quantumFrames = 1)
      : rate_(rate), quantumFrames_(quantumFrames) {}
  bool append(MediaTime pts, MediaTime duration) {
    if (packets_.size() == 2'000'000 || !pts.valid() || !duration.valid() || duration.value <= 0)
      return false;
    const auto exact = exactAudioFrameIndex(pts, rate_);
    if (packets_.empty()) {
      if (!exact) return false;
      origin_ = *exact;
    } else {
      if (compareMediaTime(pts, packets_.back().observed) != MediaTimeOrder::Greater) return false;
      // One container tick is timestamp quantization, not an edit. A stated
      // short/long packet or a successor beyond its natural extent establishes
      // a new segment. Ordinary jitter is still tested against the segment's
      // ORIGINAL anchor, so accumulated drift cannot continually re-anchor.
      const auto prior = packets_.back().observed;
      const __int128 durationError = __int128(previousDuration_.value)*rate_ -
                                    __int128(1024)*previousDuration_.timescale;
      const __int128 tick = __int128(quantumFrames_)*previousDuration_.timescale;
      const __int128 delta = (__int128(pts.value)*prior.timescale -
                              __int128(prior.value)*pts.timescale)*rate_;
      const __int128 natural = __int128(1024)*pts.timescale*prior.timescale;
      const bool declaredEdit = durationError < -tick || durationError > tick;
      const bool gap = delta > natural + __int128(quantumFrames_)*pts.timescale*prior.timescale;
      if (declaredEdit || gap) {
        if (!exact || *exact <= packets_.back().start) return false;
        const __int128 extent = __int128(*exact) - packets_.back().start;
        if (extent > INT64_MAX) return false;
        packets_.back().duration = static_cast<std::int64_t>(extent);
        origin_ = *exact;
        segmentOrdinal_ = packets_.size();
      }
    }
    const auto projected = projectAacPacketGrid(pts, origin_, packets_.size()-segmentOrdinal_, rate_);
    if (!projected || projected->value > INT64_MAX-1024) return false;
    packets_.push_back({pts,projected->value,1024});
    previousDuration_ = duration;
    return true;
  }
  bool finish(bool exactTail = true) {
    if (packets_.empty()) return false;
    const auto tail = exactTail ? exactAudioFrameIndex(previousDuration_,rate_) : std::optional<std::int64_t>(1024);
    if (!tail || *tail <= 0) return false;
    packets_.back().duration = std::min<std::int64_t>(*tail,1024);
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
  std::uint32_t quantumFrames_;
  std::int64_t origin_{};
  std::size_t segmentOrdinal_{};
  MediaTime previousDuration_{};
  std::vector<Packet> packets_;
};
}
