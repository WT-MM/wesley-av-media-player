#pragma once
#include "native_audio_benchmark.hpp"
// Share the bounded telemetry mailbox: timestamps may originate on workers or
// the render thread; formatting and I/O remain on the GUI owner at checkpoints.
#if defined(WAM_NATIVE_BENCHMARK_TELEMETRY)
#define WAM_STARTUP_STAMP(event) ::wam::media::audioBenchmarkStamp( \
    ::wam::media::AudioBenchmarkEvent::event, 0)
#else
#define WAM_STARTUP_STAMP(event) ((void)0)
#endif
