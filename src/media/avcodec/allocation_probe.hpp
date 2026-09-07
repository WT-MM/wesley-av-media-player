#pragma once
#if defined(WAM_AVCODEC_ALLOCATION_PROBE)
namespace wam::media::avcodec {
void allocationProbeBegin() noexcept;
void allocationProbeEnd() noexcept;
unsigned allocationProbeDomain(unsigned domain) noexcept;
void allocationProbeFrame() noexcept;
struct AllocationProbe {
  AllocationProbe() { allocationProbeBegin(); }
  ~AllocationProbe() { allocationProbeEnd(); }
};
struct AdapterProbe {
  unsigned previous{allocationProbeDomain(2)};
  ~AdapterProbe() { allocationProbeDomain(previous); }
};
}
#endif
