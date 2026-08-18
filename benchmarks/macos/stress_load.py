#!/usr/bin/env python3
"""Calibrated system-load generator and cost sampler for WAM resilience runs.

Two questions motivate this harness, and it answers both with the same run:

  robustness -- does WAM still draw every frame when the machine is busy with
                a background training job and a foreground game?
  lightness  -- what does WAM itself cost while it does that, so it does not
                become the thing that ruins the game?

The load side generates *calibrated*, *labelled* contention rather than "make
the fans spin":

  cpu       N spinner processes pinned to QOS_CLASS_UTILITY. Utility is the
            class a background training job actually runs at, so this models
            starvation-by-throughput-work, not starvation-by-priority-inversion.
            Optionally M more at QOS_CLASS_USER_INITIATED to stand in for a
            game's worker threads, which do compete with WAM on equal footing.
  gpu       A Metal compute loop that keeps the GPU command queue saturated.
            The kernel is compiled from source at runtime, so this needs no
            metal toolchain and no checked-in binary.
  combined  Both at once. This is the acceptance configuration.

The cost side samples the target process without sudo:

  CPU       `ps` sampled CPU-time deltas -> percent of one core.
  GPU       ioreg AGXDeviceUserClient per-client accumulatedGPUTime deltas,
            the same counter family collect.py already trusts, attributed to
            one pid. powermetrics is deliberately avoided: it needs root, and
            a benchmark that needs root is a benchmark nobody reruns.

Because Apple documents no unit for accumulatedGPUTime, `calibrate-gpu` first
measures how many units one second of a saturated GPU produces on THIS
machine, so GPU cost can be reported as a percentage rather than as a raw
number nobody can act on.

Every subcommand only ever signals processes this script itself created. A WAM
process the harness did not launch is recorded and left running.

Usage:

  # compile the helpers (also done implicitly on first use)
  stress_load.py build

  # establish the local GPU scale factor (cached; do this once per machine)
  stress_load.py calibrate-gpu

  # generate load for 60s, in the foreground
  stress_load.py load --mode combined --duration 60

  # sample a running player's own cost for 60s
  stress_load.py sample --pid 1234 --duration 60 --interval 0.5

  # hold load up while sampling an already-running player
  stress_load.py measure --pid 1234 --mode combined --duration 60

  # launch a player, hold load up, and judge it against the acceptance bar
  stress_load.py trial --mode combined --duration 60

  # the whole degradation table: no load / cpu / gpu / combined
  stress_load.py matrix --duration 60
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import threading
import time
from dataclasses import dataclass, field, asdict
from pathlib import Path
from typing import Any

PROJECT_ROOT = Path(__file__).resolve().parents[2]
CACHE_DIR = PROJECT_ROOT / ".cache" / "benchmarks" / "stress"

# ~75% of the machine's cores, the share a training job tends to take while
# still leaving the box usable. Resolved against the real core count at run
# time; see resolve_cpu_workers().
CPU_UTILITY_CORE_FRACTION = 0.75
# A game's own worker threads are few and run at foreground priority. Two is
# enough to prove WAM is not simply winning by being the only default-QoS
# consumer on the machine.
CPU_GAME_WORKERS_DEFAULT = 2

SAMPLE_INTERVAL_DEFAULT_S = 0.5


# --------------------------------------------------------------------------
# Helper sources. Compiled on demand into CACHE_DIR; never checked in built.
# --------------------------------------------------------------------------

SPINNER_SOURCE = r"""
// Calibrated CPU burner. Takes a QoS class name and a duration in seconds.
// Sets its own QoS explicitly so the load is labelled the same way a real
// training job or game worker labels itself, then spins on dependent FMAs so
// the compiler cannot hoist the work out and the core stays genuinely busy
// without generating memory-bandwidth noise that would confound the GPU run.
#include <dispatch/dispatch.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(int argc, char **argv) {
  if (argc < 3) {
    fprintf(stderr, "usage: spinner <utility|user-initiated|default|background> <seconds>\n");
    return 2;
  }
  qos_class_t qos = QOS_CLASS_UTILITY;
  if (strcmp(argv[1], "utility") == 0) {
    qos = QOS_CLASS_UTILITY;
  } else if (strcmp(argv[1], "user-initiated") == 0) {
    qos = QOS_CLASS_USER_INITIATED;
  } else if (strcmp(argv[1], "default") == 0) {
    qos = QOS_CLASS_DEFAULT;
  } else if (strcmp(argv[1], "background") == 0) {
    qos = QOS_CLASS_BACKGROUND;
  } else {
    fprintf(stderr, "spinner: unknown qos class '%s'\n", argv[1]);
    return 2;
  }
  if (pthread_set_qos_class_self_np(qos, 0) != 0) {
    fprintf(stderr, "spinner: could not set qos class\n");
    return 1;
  }

  double seconds = atof(argv[2]);
  if (!(seconds > 0.0)) {
    fprintf(stderr, "spinner: duration must be positive\n");
    return 2;
  }

  mach_timebase_info_data_t tb;
  mach_timebase_info(&tb);
  uint64_t start = mach_absolute_time();
  uint64_t limit = (uint64_t)(seconds * 1e9 * (double)tb.denom / (double)tb.numer);

  // Four independent chains keep the FMA pipelines fed without unrolling into
  // memory traffic. The result is consumed at exit so nothing is dead code.
  volatile double sink = 0.0;
  double a = 1.0000001, b = 1.0000002, c = 1.0000003, d = 1.0000004;
  for (;;) {
    for (int i = 0; i < 4096; ++i) {
      a = a * 1.0000000001 + 1e-12;
      b = b * 1.0000000002 + 1e-12;
      c = c * 1.0000000003 + 1e-12;
      d = d * 1.0000000004 + 1e-12;
    }
    if (mach_absolute_time() - start >= limit) break;
  }
  sink = a + b + c + d;
  (void)sink;
  return 0;
}
"""

METAL_LOAD_SOURCE = r"""
// Calibrated GPU burner. Saturates the GPU compute pipes with a dependent-FMA
// kernel while keeping a small number of command buffers in flight, which is
// what a game's frame loop looks like from the driver's point of view. The
// shader is compiled from source at runtime so this needs no metal toolchain.
//
// Intensity is expressed as iterations inside the kernel rather than as a
// bigger grid: that keeps each command buffer short enough that the GPU
// remains preemptible, so WAM's own compositing work can still interleave.
// A burner that submitted one enormous kernel would measure driver timeout
// behaviour instead of contention.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <mach/mach_time.h>

static NSString *const kKernel = @"#include <metal_stdlib>\n"
  "using namespace metal;\n"
  "kernel void burn(device float *out [[buffer(0)]],\n"
  "                 constant uint &iters [[buffer(1)]],\n"
  "                 uint gid [[thread_position_in_grid]]) {\n"
  "  float a = (float)gid * 1e-6f + 1.0f;\n"
  "  float b = a * 1.000001f;\n"
  "  float c = a * 1.000002f;\n"
  "  float d = a * 1.000003f;\n"
  "  for (uint i = 0; i < iters; ++i) {\n"
  "    a = fma(a, 1.0000001f, 1e-9f);\n"
  "    b = fma(b, 1.0000002f, 1e-9f);\n"
  "    c = fma(c, 1.0000003f, 1e-9f);\n"
  "    d = fma(d, 1.0000004f, 1e-9f);\n"
  "  }\n"
  "  out[gid] = a + b + c + d;\n"
  "}\n";

int main(int argc, char **argv) {
  @autoreleasepool {
    if (argc < 2) {
      fprintf(stderr, "usage: metalload <seconds> [threads] [iters] [inflight]\n");
      return 2;
    }
    double seconds = atof(argv[1]);
    NSUInteger threads = argc > 2 ? (NSUInteger)atoll(argv[2]) : (NSUInteger)(1 << 20);
    uint32_t iters = argc > 3 ? (uint32_t)atoll(argv[3]) : 2048u;
    NSUInteger inflight = argc > 4 ? (NSUInteger)atoll(argv[4]) : 3;
    if (!(seconds > 0.0) || threads == 0 || iters == 0 || inflight == 0) {
      fprintf(stderr, "metalload: invalid parameters\n");
      return 2;
    }

    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) { fprintf(stderr, "metalload: no Metal device\n"); return 1; }

    NSError *error = nil;
    id<MTLLibrary> library = [device newLibraryWithSource:kKernel options:nil error:&error];
    if (!library) {
      fprintf(stderr, "metalload: shader compile failed: %s\n",
              error.localizedDescription.UTF8String);
      return 1;
    }
    id<MTLFunction> fn = [library newFunctionWithName:@"burn"];
    id<MTLComputePipelineState> pipeline =
        [device newComputePipelineStateWithFunction:fn error:&error];
    if (!pipeline) {
      fprintf(stderr, "metalload: pipeline failed: %s\n",
              error.localizedDescription.UTF8String);
      return 1;
    }
    id<MTLCommandQueue> queue = [device newCommandQueue];
    id<MTLBuffer> out = [device newBufferWithLength:threads * sizeof(float)
                                            options:MTLResourceStorageModePrivate];

    NSUInteger tg = pipeline.maxTotalThreadsPerThreadgroup;
    if (tg > threads) tg = threads;

    mach_timebase_info_data_t tb;
    mach_timebase_info(&tb);
    uint64_t start = mach_absolute_time();
    uint64_t limit = (uint64_t)(seconds * 1e9 * (double)tb.denom / (double)tb.numer);

    dispatch_semaphore_t gate = dispatch_semaphore_create((long)inflight);
    unsigned long long dispatched = 0;
    while (mach_absolute_time() - start < limit) {
      dispatch_semaphore_wait(gate, DISPATCH_TIME_FOREVER);
      id<MTLCommandBuffer> cb = [queue commandBuffer];
      id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
      [enc setComputePipelineState:pipeline];
      [enc setBuffer:out offset:0 atIndex:0];
      [enc setBytes:&iters length:sizeof(iters) atIndex:1];
      [enc dispatchThreads:MTLSizeMake(threads, 1, 1)
          threadsPerThreadgroup:MTLSizeMake(tg, 1, 1)];
      [enc endEncoding];
      [cb addCompletedHandler:^(id<MTLCommandBuffer> _) {
        dispatch_semaphore_signal(gate);
      }];
      [cb commit];
      ++dispatched;
    }
    // Drain so the process does not exit with work still queued on the device.
    for (NSUInteger i = 0; i < inflight; ++i) {
      dispatch_semaphore_wait(gate, DISPATCH_TIME_FOREVER);
    }
    fprintf(stderr, "metalload: dispatched %llu command buffers\n", dispatched);
    return 0;
  }
}
"""


@dataclass(frozen=True)
class Helper:
    name: str
    source: str
    frameworks: tuple[str, ...]
    objc: bool


HELPERS: tuple[Helper, ...] = (
    Helper("spinner", SPINNER_SOURCE, (), objc=False),
    Helper("metalload", METAL_LOAD_SOURCE, ("Foundation", "Metal"), objc=True),
)


class HarnessError(RuntimeError):
    """A failure the operator needs to fix before the run can mean anything."""


# --------------------------------------------------------------------------
# Building
# --------------------------------------------------------------------------

def helper_path(helper: Helper) -> Path:
    return CACHE_DIR / helper.name


def build_helper(helper: Helper, *, force: bool = False) -> Path:
    """Compile one helper into the benchmark cache, reusing a fresh binary."""
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    binary = helper_path(helper)
    stamp = CACHE_DIR / f"{helper.name}.stamp"
    # A stable digest, not hash(): PYTHONHASHSEED randomisation would make the
    # stamp miss on every run and silently rebuild both helpers each time.
    digest = hashlib.sha256(helper.source.encode("utf-8")).hexdigest()
    if not force and binary.exists() and stamp.exists():
        if stamp.read_text(encoding="utf-8").strip() == digest:
            return binary

    suffix = ".m" if helper.objc else ".c"
    src = CACHE_DIR / f"{helper.name}{suffix}"
    src.write_text(helper.source, encoding="utf-8")
    cmd = [
        "clang", "-O2", "-fno-fast-math",
        str(src), "-o", str(binary),
    ]
    if helper.objc:
        cmd.insert(1, "-fobjc-arc")
    for framework in helper.frameworks:
        cmd += ["-framework", framework]
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode != 0:
        raise HarnessError(
            f"failed to compile {helper.name}:\n{proc.stderr.strip()}"
        )
    stamp.write_text(digest, encoding="utf-8")
    return binary


def build_all(*, force: bool = False) -> dict[str, str]:
    return {h.name: str(build_helper(h, force=force)) for h in HELPERS}


# --------------------------------------------------------------------------
# Load generation
# --------------------------------------------------------------------------

def physical_cores() -> int:
    out = subprocess.run(
        ["sysctl", "-n", "hw.ncpu"], capture_output=True, text=True, check=True
    ).stdout.strip()
    return max(1, int(out))


def resolve_cpu_workers(explicit: int | None) -> int:
    if explicit is not None:
        return max(0, explicit)
    return max(1, int(round(physical_cores() * CPU_UTILITY_CORE_FRACTION)))


@dataclass
class LoadHandle:
    """Owns exactly the processes this harness spawned, and nothing else."""

    procs: list[subprocess.Popen] = field(default_factory=list)
    description: dict[str, Any] = field(default_factory=dict)

    def pids(self) -> list[int]:
        return [p.pid for p in self.procs]

    def poll_failures(self) -> list[str]:
        failures = []
        for proc in self.procs:
            code = proc.poll()
            if code not in (None, 0):
                failures.append(f"pid {proc.pid} exited {code}")
        return failures

    def stop(self) -> None:
        for proc in self.procs:
            if proc.poll() is None:
                try:
                    proc.terminate()
                except ProcessLookupError:
                    pass
        deadline = time.monotonic() + 5.0
        for proc in self.procs:
            remaining = max(0.0, deadline - time.monotonic())
            try:
                proc.wait(timeout=remaining)
            except subprocess.TimeoutExpired:
                try:
                    proc.kill()
                except ProcessLookupError:
                    pass
        self.procs.clear()


def start_load(
    mode: str,
    duration_s: float,
    *,
    cpu_workers: int | None = None,
    game_workers: int = CPU_GAME_WORKERS_DEFAULT,
    gpu_threads: int = 1 << 20,
    gpu_iters: int = 2048,
    gpu_inflight: int = 3,
    quiet: bool = True,
) -> LoadHandle:
    """Spawn the load processes for `mode`, each self-terminating after
    `duration_s`. Returns a handle that can also stop them early."""
    if mode not in {"none", "cpu", "gpu", "combined"}:
        raise HarnessError(f"unknown load mode '{mode}'")

    handle = LoadHandle()
    handle.description = {"mode": mode, "duration_s": duration_s}
    if mode == "none":
        return handle

    sink = subprocess.DEVNULL if quiet else None
    # Each helper self-terminates, with a margin so an orchestrator that is a
    # little slow to tear down never measures a window where load has already
    # evaporated. stop() is still the authoritative teardown.
    helper_duration = duration_s + 5.0

    if mode in {"cpu", "combined"}:
        spinner = build_helper(HELPERS[0])
        n_utility = resolve_cpu_workers(cpu_workers)
        for _ in range(n_utility):
            handle.procs.append(subprocess.Popen(
                [str(spinner), "utility", f"{helper_duration:.3f}"],
                stdout=sink, stderr=sink,
            ))
        for _ in range(max(0, game_workers)):
            handle.procs.append(subprocess.Popen(
                [str(spinner), "user-initiated", f"{helper_duration:.3f}"],
                stdout=sink, stderr=sink,
            ))
        handle.description["cpu"] = {
            "utility_workers": n_utility,
            "user_initiated_workers": max(0, game_workers),
            "host_cores": physical_cores(),
        }

    if mode in {"gpu", "combined"}:
        metalload = build_helper(HELPERS[1])
        handle.procs.append(subprocess.Popen(
            [
                str(metalload), f"{helper_duration:.3f}",
                str(gpu_threads), str(gpu_iters), str(gpu_inflight),
            ],
            stdout=sink, stderr=sink,
        ))
        handle.description["gpu"] = {
            "threads": gpu_threads,
            "iters": gpu_iters,
            "inflight": gpu_inflight,
        }

    handle.description["pids"] = handle.pids()
    return handle


# --------------------------------------------------------------------------
# Cost sampling: what the player itself costs
# --------------------------------------------------------------------------

_PS_TIME_RE = re.compile(r"^(?:(\d+)-)?(?:(\d+):)?(\d+):(\d+(?:\.\d+)?)$")


def _parse_ps_time(text: str) -> float | None:
    """`ps -o time=` renders as [[dd-]hh:]mm:ss[.ff]."""
    match = _PS_TIME_RE.match(text.strip())
    if not match:
        return None
    days, hours, minutes, seconds = match.groups()
    total = float(seconds) + 60.0 * int(minutes)
    if hours:
        total += 3600.0 * int(hours)
    if days:
        total += 86400.0 * int(days)
    return total


def process_cpu_seconds(pid: int) -> float | None:
    """Accumulated CPU time for a pid, or None once it is gone."""
    proc = subprocess.run(
        ["ps", "-o", "time=", "-p", str(pid)], capture_output=True, text=True
    )
    if proc.returncode != 0 or not proc.stdout.strip():
        return None
    return _parse_ps_time(proc.stdout)


# ioreg exposes per-accelerator-client statistics as a flat plist-ish dump.
# The accumulated GPU-time counters live in the PerformanceStatistics dict of
# each IOAccelerator client and are named by the driver, so match a family of
# plausible keys rather than one exact spelling: the name has moved between
# macOS releases and a hard-coded key silently reports zero forever.
_GPU_TIME_KEYS = (
    "gpuCoreUtilization",
    "Device Utilization %",
    "Renderer Utilization %",
    "Tiler Utilization %",
)
_ACCUM_GPU_TIME_RE = re.compile(r'"accumulatedGPUTime"\s*=\s*(\d+)')
_CLIENT_CREATOR_RE = re.compile(r'"IOUserClientCreator"\s*=\s*"pid (\d+)')
_CLIENT_BLOCK_RE = re.compile(r"(?m)^.*\+-o AGXDeviceUserClient\b")


def _ioreg_dump(cls: str, *, deep: bool = False) -> str:
    # `-d 1` is enough for IOAccelerator's PerformanceStatistics, but the
    # per-process AppUsage dictionaries hang below the AGXDeviceUserClient
    # nodes and only appear with the full property listing.
    args = ["ioreg", "-r", "-c", cls, "-w", "0"]
    args += ["-l"] if deep else ["-d", "1"]
    proc = subprocess.run(args, capture_output=True, text=True)
    return proc.stdout if proc.returncode == 0 else ""


def gpu_accumulated_time_for_pid(pid: int) -> int | None:
    """Driver-accumulated GPU time charged to one process.

    The counter lives on AGXDeviceUserClient nodes, not on IOAccelerator:
    asking only the accelerator returns whole-device utilisation and silently
    no per-process attribution at all. Each process may own several client
    nodes, so every block whose IOUserClientCreator names the pid is summed.

    The unit is undocumented by Apple, so only DIFFERENCES between two samples
    of the same counter are meaningful; this returns the raw value and callers
    subtract.
    """
    dump = _ioreg_dump("AGXDeviceUserClient", deep=True)
    if not dump:
        return None
    starts = [m.start() for m in _CLIENT_BLOCK_RE.finditer(dump)]
    if not starts:
        return None
    starts.append(len(dump))
    total = 0
    found = False
    for index in range(len(starts) - 1):
        block = dump[starts[index]:starts[index + 1]]
        creator = _CLIENT_CREATOR_RE.search(block)
        if not creator or int(creator.group(1)) != pid:
            continue
        for match in _ACCUM_GPU_TIME_RE.finditer(block):
            total += int(match.group(1))
            found = True
    return total if found else None


def gpu_utilization_percent() -> dict[str, float]:
    """Instantaneous device/renderer/tiler utilisation, whole-GPU.

    This is a system-wide reading, not per-process: with load running it
    reports the sum. It is still the cheapest honest signal for "is the GPU
    actually saturated", which is what the load side needs to prove.
    """
    dump = _ioreg_dump("IOAccelerator")
    result: dict[str, float] = {}
    for key in _GPU_TIME_KEYS:
        match = re.search(rf'"{re.escape(key)}"\s*=\s*(\d+)', dump)
        if match:
            result[key] = float(match.group(1))
    return result




def ambient_top_consumers(limit: int = 8) -> list[dict[str, Any]]:
    """The busiest processes that are not ours.

    A dev Mac is never actually quiet -- screen sharing, editors and sync
    daemons all take a cut, and screen-capture tools inflate WindowServer and
    the GPU in particular. Recording who else was busy turns "the numbers
    moved" into an answerable question instead of a mystery, so every report
    carries this whether or not anyone reads it.
    """
    proc = subprocess.run(
        ["ps", "-Ao", "pid,%cpu,comm", "-r"], capture_output=True, text=True
    )
    if proc.returncode != 0:
        return []
    rows: list[dict[str, Any]] = []
    for line in proc.stdout.splitlines()[1: limit + 1]:
        parts = line.split(None, 2)
        if len(parts) < 3:
            continue
        try:
            rows.append({
                "pid": int(parts[0]),
                "cpu_percent": float(parts[1]),
                "command": parts[2].strip(),
            })
        except ValueError:
            continue
    return rows


def load_average() -> list[float] | None:
    try:
        return list(os.getloadavg())
    except OSError:
        return None


GPU_CALIBRATION_PATH = CACHE_DIR / "gpu_calibration.json"


def load_gpu_calibration() -> float | None:
    """The cached units-per-second-at-full-GPU scale, if one was measured."""
    try:
        data = json.loads(GPU_CALIBRATION_PATH.read_text(encoding="utf-8"))
        value = float(data["units_per_second_at_full_gpu"])
        return value if value > 0 else None
    except (OSError, ValueError, KeyError, TypeError):
        return None


def calibrate_gpu_saturation(seconds: float = 8.0) -> dict[str, Any]:
    """Measure how many accumulated-GPU-time units one second of a fully
    saturated GPU produces on this machine.

    Apple documents no unit for accumulatedGPUTime, so a raw delta says
    nothing on its own -- "WAM used 4.2e8 units" is not a number anyone can
    act on. Running the burner, which is known to pin the device at ~100%,
    and dividing gives a local scale factor, so every later GPU cost can be
    quoted as a percentage of the whole GPU. The factor is machine- and
    OS-specific, which is exactly why it is measured rather than hard-coded.
    """
    binary = build_helper(HELPERS[1])
    proc = subprocess.Popen(
        [str(binary), f"{seconds + 4.0:.3f}", str(1 << 20), "2048", "3"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    try:
        time.sleep(2.0)  # let the queue fill and the clocks ramp
        report = sample_cost(proc.pid, seconds, interval_s=0.5)
    finally:
        if proc.poll() is None:
            proc.terminate()
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()

    per_second = report["gpu"]["accumulated_units_per_second"]
    utilization = report["gpu"]["device_utilization_mean_percent"]
    if per_second is None or not utilization:
        raise HarnessError(
            "GPU calibration failed: no per-process counter delta observed"
        )
    result = {
        "units_per_second_at_full_gpu": per_second * (100.0 / utilization),
        "measured_units_per_second": per_second,
        "measured_device_utilization_percent": utilization,
        "seconds": seconds,
    }
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    GPU_CALIBRATION_PATH.write_text(json.dumps(result, indent=2), encoding="utf-8")
    return result


def _gpu_percent_of_device(
    end_gpu: int | None, start_gpu: int | None, wall: float
) -> float | None:
    scale = load_gpu_calibration()
    if scale is None or end_gpu is None or start_gpu is None or wall <= 0:
        return None
    return 100.0 * ((end_gpu - start_gpu) / wall) / scale


@dataclass
class CostSample:
    t: float
    cpu_percent_of_core: float | None
    gpu_util: dict[str, float]


def sample_cost(
    pid: int,
    duration_s: float,
    *,
    interval_s: float = SAMPLE_INTERVAL_DEFAULT_S,
    on_sample=None,
) -> dict[str, Any]:
    """Sample a process's own CPU cost, plus whole-GPU utilisation, for a
    window. Returns a report dict; raises if the process dies mid-window,
    because a truncated window is not a measurement."""
    start_cpu = process_cpu_seconds(pid)
    if start_cpu is None:
        raise HarnessError(f"pid {pid} is not running; nothing to sample")
    start_gpu = gpu_accumulated_time_for_pid(pid)
    ambient_before = ambient_top_consumers()
    loadavg_before = load_average()
    start_t = time.monotonic()

    samples: list[CostSample] = []
    prev_cpu = start_cpu
    prev_t = start_t
    deadline = start_t + duration_s
    while time.monotonic() < deadline:
        time.sleep(min(interval_s, max(0.0, deadline - time.monotonic())))
        now = time.monotonic()
        cpu = process_cpu_seconds(pid)
        if cpu is None:
            raise HarnessError(
                f"pid {pid} exited after {now - start_t:.1f}s of a "
                f"{duration_s:.1f}s window; sample discarded"
            )
        dt = now - prev_t
        percent = 100.0 * (cpu - prev_cpu) / dt if dt > 0 else None
        sample = CostSample(now - start_t, percent, gpu_utilization_percent())
        samples.append(sample)
        if on_sample is not None:
            on_sample(sample)
        prev_cpu, prev_t = cpu, now

    end_cpu = process_cpu_seconds(pid)
    end_gpu = gpu_accumulated_time_for_pid(pid)
    end_t = time.monotonic()
    if end_cpu is None:
        raise HarnessError(f"pid {pid} exited at the end of the window")

    wall = end_t - start_t
    percents = [s.cpu_percent_of_core for s in samples if s.cpu_percent_of_core is not None]
    device_utils = [s.gpu_util.get("Device Utilization %") for s in samples]
    device_utils = [d for d in device_utils if d is not None]

    return {
        "pid": pid,
        "wall_s": wall,
        "cpu": {
            # The mean over the whole window is the number that matters for a
            # budget; per-sample peaks are reported so a spiky profile cannot
            # hide behind a flattering mean.
            "mean_percent_of_core": 100.0 * (end_cpu - start_cpu) / wall if wall > 0 else None,
            "peak_percent_of_core": max(percents) if percents else None,
            "total_cpu_seconds": end_cpu - start_cpu,
            "samples": len(samples),
        },
        "gpu": {
            "accumulated_delta": (
                end_gpu - start_gpu
                if end_gpu is not None and start_gpu is not None else None
            ),
            "device_utilization_mean_percent": (
                sum(device_utils) / len(device_utils) if device_utils else None
            ),
            "device_utilization_peak_percent": max(device_utils) if device_utils else None,
            "accumulated_units_per_second": (
                (end_gpu - start_gpu) / wall
                if end_gpu is not None and start_gpu is not None and wall > 0
                else None
            ),
            "percent_of_device": _gpu_percent_of_device(
                end_gpu, start_gpu, wall
            ),
            "note": (
                "accumulated_delta is charged to this pid only; "
                "device_utilization is whole-GPU and includes any load. "
                "percent_of_device needs `calibrate-gpu` to have been run"
            ),
        },
        "ambient": {
            "top_consumers_before": ambient_before,
            "top_consumers_after": ambient_top_consumers(),
            "loadavg_before": loadavg_before,
            "loadavg_after": load_average(),
        },
        "series": [asdict(s) for s in samples],
    }


# --------------------------------------------------------------------------
# Driving one WAM trial under load
# --------------------------------------------------------------------------

DEFAULT_APP = PROJECT_ROOT / "build" / "WAM.app"
CLIP_DIR = PROJECT_ROOT / ".cache" / "benchmarks" / "media" / "adhoc-native-1080p"
STATE_TSV = Path.home() / "Library" / "Application Support" / "WAM" / "state.tsv"
# Auto-resume of a benchmark clip issues a CommitSeek at open, which changes
# the very thing these runs measure. The clip names below are the ones the
# benchmark corpus uses; scrubbing them leaves the user's real history alone.
STATE_SCRUB_PATTERNS = (
    "adhoc-native-1080p", "leflexitac", "pyflexitac",
)
# Clips used in ad hoc validation are scrubbed too, but their names stay out
# of the repository: one substring per line in this untracked file.
LOCAL_SCRUB_PATTERNS_PATH = (
    PROJECT_ROOT / ".cache" / "benchmarks" / "local_scrub_patterns.txt"
)


def _scrub_patterns() -> tuple:
    extra = ()
    if LOCAL_SCRUB_PATTERNS_PATH.exists():
        extra = tuple(
            line.strip()
            for line in LOCAL_SCRUB_PATTERNS_PATH.read_text(
                encoding="utf-8").splitlines()
            if line.strip())
    return STATE_SCRUB_PATTERNS + extra


def scrub_state(path: Path = STATE_TSV) -> int:
    """Drop benchmark clips from the resume ledger. Returns lines removed."""
    if not path.exists():
        return 0
    patterns = _scrub_patterns()
    lines = path.read_text(encoding="utf-8", errors="replace").splitlines(True)
    keep = [ln for ln in lines
            if not any(pattern in ln for pattern in patterns)]
    if len(keep) != len(lines):
        tmp = path.with_suffix(path.suffix + ".tmp")
        tmp.write_text("".join(keep), encoding="utf-8")
        tmp.replace(path)
    return len(lines) - len(keep)


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def probe_duration_seconds(clip: Path) -> float | None:
    """Clip length via ffprobe, or None when ffprobe is not installed.

    Used only as a guard rail, so an absent ffprobe must not block a run.
    """
    try:
        proc = subprocess.run(
            ["ffprobe", "-v", "error", "-show_entries", "format=duration",
             "-of", "default=noprint_wrappers=1:nokey=1", str(clip)],
            capture_output=True, text=True, timeout=20,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    if proc.returncode != 0:
        return None
    try:
        return float(proc.stdout.strip())
    except ValueError:
        return None


def app_executable(app: Path) -> Path:
    return app / "Contents" / "MacOS" / "WAM"


def wam_pids(executable: Path) -> set[int]:
    proc = subprocess.run(
        ["/bin/ps", "-axo", "pid=,comm="], capture_output=True, text=True
    )
    found = set()
    for line in proc.stdout.splitlines():
        parts = line.strip().split(None, 1)
        if len(parts) == 2 and parts[1].strip() == str(executable):
            found.add(int(parts[0]))
    return found


def parse_metrics(path: Path) -> list[dict[str, Any]]:
    """Read the playback metrics JSONL, tolerating a truncated final line.

    The metrics stream is flushed per line and is deliberately not
    hash-chained, so an interrupted run still yields every completed sample.
    """
    if not path.exists():
        return []
    rows = []
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        line = line.strip()
        if not line or not line.startswith("{"):
            continue
        try:
            row = json.loads(line)
        except json.JSONDecodeError:
            continue
        if row.get("record") == "playback_sample":
            rows.append(row)
    return rows


PARK_SCRIPT = """
tell application "System Events"
  set procs to (every process whose unix id is {pid})
  if (count of procs) is 0 then return "no-process"
  set p to item 1 of procs
  set frontmost of p to true
  try
    set ws to windows of p
    if (count of ws) is 0 then return "no-window"
    set w to item 1 of ws
    set position of w to {{{x}, {y}}}
    set size of w to {{{width}, {height}}}
    perform action "AXRaise" of w
    return "parked"
  on error errText
    return "error: " & errText
  end try
end tell
"""


RAISE_SCRIPT = """
tell application "System Events"
  set procs to (every process whose unix id is {pid})
  if (count of procs) is 0 then return "no-process"
  set ws to windows of (item 1 of procs)
  if (count of ws) is 0 then return "no-window"
  perform action "AXRaise" of (item 1 of ws)
  return "raised"
end tell
"""


def raise_window(pid: int, *, timeout_s: float = 8.0) -> str:
    """Re-raise the window, and do NOTHING else.

    Deliberately separate from park_window: repeatedly re-applying position
    and size forces a window resize on every tick, and a resize tears down and
    reallocates the video surface. Measured, that alone dragged playback to
    0.84x and more than doubled CPU -- the keeper was corrupting the very
    numbers it existed to protect. Geometry is set once at launch; only the
    window ordering is maintained.

    The timeout is generous because this competes with the synthetic load for
    a core. A stingy timeout silently stops keeping the window up exactly when
    load makes that most necessary, which is the worst possible time to fail.
    """
    try:
        proc = subprocess.run(
            ["osascript", "-e", RAISE_SCRIPT.format(pid=pid)],
            capture_output=True, text=True, timeout=timeout_s,
        )
    except (OSError, subprocess.TimeoutExpired):
        return "timeout"
    return proc.stdout.strip() or "failed"


def park_window(pid: int, *, x: int = 40, y: int = 60,
                width: int = 960, height: int = 600,
                timeout_s: float = 15.0) -> str:
    """Move the player's window to a known corner and raise it above others.

    Measurement validity depends on the window being visible: macOS stops the
    render loop for an occluded window, and a measured run of a stopped render
    loop is a measurement of nothing. Parking is part of the measurement, not
    cosmetics.

    AXRaise is what actually matters here, and it is enough on its own. Making
    the *application* frontmost is neither achievable nor necessary: modern
    macOS refuses programmatic focus steals, but raising the window in the
    window-server ordering restores drawing anyway. Measured directly: while
    covered, drawn frames held flat and late drops climbed at 30/s; the
    instant AXRaise landed, drawing resumed at exactly 30 fps and late drops
    stopped. So this deliberately does not fight for focus.

    The window does not exist at launch, so this retries until it appears.
    It stays best-effort -- accessibility permission can be denied -- and the
    caller proves liveness afterwards rather than trusting the return value.
    """
    script = PARK_SCRIPT.format(pid=pid, x=x, y=y, width=width, height=height)
    deadline = time.monotonic() + timeout_s
    last = "not-attempted"
    while time.monotonic() < deadline:
        try:
            proc = subprocess.run(
                ["osascript", "-e", script], capture_output=True, text=True,
                timeout=20,
            )
        except (OSError, subprocess.TimeoutExpired) as exc:
            return f"unavailable: {exc}"
        last = proc.stdout.strip() or f"failed: {proc.stderr.strip()}"
        if last == "parked":
            return last
        time.sleep(0.5)
    return f"gave up after {timeout_s:.0f}s: {last}"


def user_idle_seconds() -> float | None:
    """Seconds since the last human input event, or None if unreadable.

    This harness raises a video window over whatever else is on screen and
    saturates every core. That is fine on an unattended machine and hostile on
    one somebody is using, and the two are indistinguishable without asking.
    """
    proc = subprocess.run(
        ["ioreg", "-c", "IOHIDSystem", "-w", "0"],
        capture_output=True, text=True,
    )
    if proc.returncode != 0:
        return None
    match = re.search(r'"HIDIdleTime"\s*=\s*(\d+)', proc.stdout)
    if not match:
        return None
    return int(match.group(1)) / 1e9


class WindowKeeper:
    """Keeps the player's window raised for the duration of a measurement.

    A single raise at launch is not enough: anything that activates later --
    another app, a notification, the player's own dialogs -- puts the window
    back under, and drawing stops the moment it does. Re-raising on an
    interval is what makes a long unattended window trustworthy.

    This deliberately does NOT steal application focus; it only reorders the
    window, which is all that drawing requires.
    """

    def __init__(self, pid: int, metrics_path: Path,
                 interval_s: float = 2.0) -> None:
        self._pid = pid
        self._metrics_path = metrics_path
        self._interval = interval_s
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None
        self.raises = 0
        self.failed_raises = 0

    def __enter__(self) -> "WindowKeeper":
        self._thread = threading.Thread(target=self._run, daemon=True)
        self._thread.start()
        return self

    def __exit__(self, *exc_info: object) -> None:
        self._stop.set()
        if self._thread is not None:
            self._thread.join(timeout=10.0)

    def _run(self) -> None:
        """Raise ON DEMAND, never on a schedule.

        An unconditional periodic raise is not free: at one every two seconds
        it cost a measured ~16% of wall time, pinning playback at 0.83x in
        every condition -- uniform enough to look like a real property of the
        player rather than damage done by the instrument. So the keeper now
        watches drawn_frames and intervenes only when drawing has actually
        stalled. On an uncontended machine it does nothing at all, which is
        the only way the no-load row can be trusted.
        """
        last_drawn: int | None = None
        while not self._stop.is_set():
            self._stop.wait(self._interval)
            if self._stop.is_set():
                break
            rows = parse_metrics(self._metrics_path)
            drawing = [r for r in rows if r.get("drawn_frames") is not None]
            current = drawing[-1]["drawn_frames"] if drawing else None
            if current is None:
                continue
            stalled = last_drawn is not None and current <= last_drawn
            last_drawn = current
            if not stalled:
                continue
            if raise_window(self._pid) == "raised":
                self.raises += 1
            else:
                self.failed_raises += 1


class OcclusionError(HarnessError):
    """The window is not drawing, so nothing measured here is about load."""


def assert_draws_advancing(metrics_path: Path, *, minimum_fps: float = 10.0) -> None:
    """Refuse to open a measurement window on a window that is not drawing.

    macOS stops the render loop for an occluded window. When that happens the
    clock, the audio callbacks and the late-drop counter all keep advancing
    perfectly while drawn_frames freezes -- which reads as a catastrophic fps
    collapse that has nothing whatsoever to do with system load. This harness
    learned that the hard way: a fullscreen video player covering the WAM
    window produced exactly the signature of the bug it was built to find.

    So liveness is proved before every window rather than assumed. The bar is
    deliberately low: this separates "drawing" from "not drawing at all", and
    leaves judging the actual frame rate to the acceptance check.
    """
    rows = parse_metrics(metrics_path)
    drawing = [r for r in rows if r.get("drawn_frames") is not None]
    if len(drawing) < 2:
        raise OcclusionError(
            f"no usable playback samples yet in {metrics_path.name}; the "
            f"player may not have started drawing"
        )
    # Only the most recent samples count. Averaging over a longer tail lets
    # the startup ramp -- which always draws -- mask a window that has since
    # been covered, which is exactly the false pass this guard exists to
    # prevent.
    recent = drawing[-min(len(drawing), 3):]
    span_s = (recent[-1]["t_mono_ns"] - recent[0]["t_mono_ns"]) / 1e9
    frames = recent[-1]["drawn_frames"] - recent[0]["drawn_frames"]
    if span_s <= 0:
        raise OcclusionError("metric samples carry no elapsed time")
    fps = frames / span_s
    if fps < minimum_fps:
        raise OcclusionError(
            f"window is drawing at {fps:.1f} fps before the measured window "
            f"even opened -- it is almost certainly occluded or minimised. "
            f"Park the player where nothing covers it and rerun; measuring "
            f"now would record occlusion, not load."
        )


def _delta(rows: list[dict[str, Any]], key: str) -> int | None:
    first = rows[0].get(key)
    last = rows[-1].get(key)
    if first is None or last is None:
        return None
    return int(last) - int(first)


def summarize_playback(
    rows: list[dict[str, Any]], *, window_s: float | None = None
) -> dict[str, Any]:
    """Reduce metric samples to the acceptance numbers.

    `window_s` trims to the LAST window of that length, which is what the
    acceptance criteria mean by "sustained over 60s": the steady state, not
    the startup transient that every player is allowed to have.
    """
    usable = [r for r in rows if r.get("t_mono_ns") is not None]
    if len(usable) < 2:
        return {"status": "insufficient_samples", "sample_count": len(usable)}

    usable.sort(key=lambda r: r["t_mono_ns"])
    if window_s is not None:
        cutoff = usable[-1]["t_mono_ns"] - window_s * 1e9
        trimmed = [r for r in usable if r["t_mono_ns"] >= cutoff]
        if len(trimmed) >= 2:
            usable = trimmed

    span_s = (usable[-1]["t_mono_ns"] - usable[0]["t_mono_ns"]) / 1e9
    if span_s <= 0:
        return {"status": "zero_span", "sample_count": len(usable)}

    drawn = _delta(usable, "drawn_frames")
    late = _delta(usable, "discarded_late_frames")
    superseded = _delta(usable, "superseded_frames")
    submitted = _delta(usable, "submitted_frames")
    underruns = _delta(usable, "audio_underrun_callbacks")
    clock_underruns = _delta(usable, "audio_clock_advanced_underruns")
    audio_late = _delta(usable, "audio_retired_late_frames")

    media_first = usable[0].get("media_seconds")
    media_last = usable[-1].get("media_seconds")
    achieved_rate = None
    if media_first is not None and media_last is not None:
        achieved_rate = (media_last - media_first) / span_s

    # The worst single inter-sample interval is reported alongside the mean:
    # a mean of 29.8 fps built from one stall and a burst is a different
    # product than a steady 29.8, and only the minimum tells them apart.
    per_interval_fps = []
    for older, newer in zip(usable, usable[1:]):
        dt = (newer["t_mono_ns"] - older["t_mono_ns"]) / 1e9
        a, b = older.get("drawn_frames"), newer.get("drawn_frames")
        if dt > 0 and a is not None and b is not None:
            per_interval_fps.append((b - a) / dt)

    return {
        "status": "ok",
        "sample_count": len(usable),
        "span_s": span_s,
        "drawn_fps_mean": drawn / span_s if drawn is not None else None,
        "drawn_fps_min_interval": min(per_interval_fps) if per_interval_fps else None,
        "drawn_frames": drawn,
        "submitted_frames": submitted,
        "superseded_frames": superseded,
        "late_drops": late,
        "audio_underruns": underruns,
        "audio_clock_advanced_underruns": clock_underruns,
        "audio_retired_late_frames": audio_late,
        "achieved_clock_rate": achieved_rate,
        "reported_clock_rate": usable[-1].get("clock_rate"),
    }


ACCEPTANCE = {
    "drawn_fps_min": 27.0,
    "audio_underruns_max": 0,
    "clock_rate_range": (0.99, 1.01),
}


def check_acceptance(summary: dict[str, Any]) -> dict[str, Any]:
    """Judge one summary against the stated bar, field by field.

    A criterion whose input is missing is 'unknown', never 'pass'. A harness
    that reports success because it failed to measure something is worse than
    one that reports nothing.
    """
    checks: dict[str, Any] = {}

    fps = summary.get("drawn_fps_mean")
    checks["drawn_fps"] = {
        "value": fps, "threshold": f">= {ACCEPTANCE['drawn_fps_min']}",
        "result": "unknown" if fps is None
        else ("pass" if fps >= ACCEPTANCE["drawn_fps_min"] else "FAIL"),
    }

    underruns = summary.get("audio_underruns")
    checks["audio_underruns"] = {
        "value": underruns, "threshold": "== 0",
        "result": "unknown" if underruns is None
        else ("pass" if underruns == 0 else "FAIL"),
    }

    rate = summary.get("achieved_clock_rate")
    low, high = ACCEPTANCE["clock_rate_range"]
    checks["clock_rate"] = {
        "value": rate, "threshold": f"in [{low}, {high}]",
        "result": "unknown" if rate is None
        else ("pass" if low <= rate <= high else "FAIL"),
    }

    # An occluded window fails every frame criterion while the clock stays
    # perfect. Naming that explicitly stops a covered window from being filed
    # as a load regression, which is the single most misleading result this
    # harness can produce.
    if (isinstance(fps, (int, float)) and fps < 1.0
            and isinstance(rate, (int, float)) and low <= rate <= high):
        checks["diagnosis"] = (
            "window appears OCCLUDED, not load-starved: the clock held "
            "rate while no frames were drawn. Raise the player window and "
            "rerun; this run says nothing about load."
        )

    results = [c["result"] for c in checks.values()
               if isinstance(c, dict) and "result" in c]
    checks["overall"] = (
        "FAIL" if "FAIL" in results
        else ("unknown" if "unknown" in results else "pass")
    )
    return checks


def run_trial(args: argparse.Namespace) -> dict[str, Any]:
    """Play one clip under one load mode and report both halves of the goal."""
    app = args.app
    executable = app_executable(app)
    if not executable.exists():
        raise HarnessError(f"no WAM executable at {executable}")
    clip = args.clip
    if not clip.exists():
        raise HarnessError(f"no clip at {clip}")

    out_dir = args.out_dir
    out_dir.mkdir(parents=True, exist_ok=True)
    tag = f"{args.mode}-{clip.stem}-{int(time.time())}"
    metrics_path = out_dir / f"{tag}.metrics.jsonl"
    telemetry_path = out_dir / f"{tag}.wam.native.jsonl"

    removed = scrub_state()

    # Foreign WAM instances are logged and left strictly alone: this harness
    # only ever signals what it launched, and a run that cannot prove which
    # process it measured is not a measurement.
    pre_existing = wam_pids(executable)

    # The self-quit must land strictly AFTER the sampling window closes, or
    # the player disappears mid-window and the run is discarded. The margin
    # covers launch/PID-attribution latency plus teardown.
    play_seconds = args.startup_grace + args.settle + args.duration + 15.0
    play_ms = int(play_seconds * 1000)

    # A window that runs past the end of the clip would measure EOF, not
    # playback: drawn frames stop while wall time keeps going, which reads as
    # a catastrophic fps drop that has nothing to do with load.
    clip_seconds = probe_duration_seconds(clip)
    if clip_seconds is not None:
        needed = args.startup_grace + args.settle + args.duration
        if needed > clip_seconds:
            raise HarnessError(
                f"window needs {needed:.0f}s of playback but {clip.name} is "
                f"only {clip_seconds:.0f}s long; lower --duration or "
                f"--startup-grace"
            )
    env_args = [
        "--env", "WAM_NATIVE_BENCHMARK_TELEMETRY=1",
        "--env", f"WAM_NATIVE_BENCHMARK_RUN_ID={_uuid4()}",
        "--env", f"WAM_NATIVE_BENCHMARK_ASSET_SHA256={sha256_file(clip)}",
        "--env", f"WAM_NATIVE_BENCHMARK_CANDIDATE_ID={sha256_file(executable)}",
        "--env", f"WAM_TEST_QUIT_AFTER_MS={play_ms}",
        "--env", f"WAM_PLAYBACK_METRICS_PATH={metrics_path}",
        "--env", f"WAM_PLAYBACK_METRICS_INTERVAL_MS={args.metrics_interval_ms}",
        "--stderr", str(telemetry_path),
    ]
    command = [
        "/usr/bin/open", "-n", "-W", *env_args,
        "-a", str(app), "--args", f"--rate={args.rate:g}", str(clip),
    ]

    launcher = subprocess.Popen(command, stdout=subprocess.DEVNULL,
                                stderr=subprocess.DEVNULL)

    # Attribute the PID by diffing against the pre-launch table. `open` is a
    # launcher, so its own PID is never the player's.
    target_pid = None
    deadline = time.monotonic() + 20.0
    while time.monotonic() < deadline:
        fresh = wam_pids(executable) - pre_existing
        if len(fresh) == 1:
            target_pid = fresh.pop()
            break
        if len(fresh) > 1:
            raise HarnessError(
                f"ambiguous launch: {len(fresh)} new WAM processes appeared"
            )
        time.sleep(0.1)
    if target_pid is None:
        launcher.terminate()
        raise HarnessError("WAM did not start within 20s")

    park_result = park_window(target_pid)

    load = start_load(
        args.mode, args.startup_grace + args.settle + args.duration + 5.0,
        cpu_workers=args.cpu_workers, game_workers=args.game_workers,
        gpu_threads=args.gpu_threads, gpu_iters=args.gpu_iters,
        gpu_inflight=args.gpu_inflight,
    )
    idle_at_start = user_idle_seconds()
    cost: dict[str, Any] | None = None
    cost_error: str | None = None
    window_start_index = 0
    window_end_index: int | None = None
    keeper = WindowKeeper(target_pid, metrics_path)
    try:
        # Let playback and the load both reach steady state before the
        # measured window opens.
        with keeper:
            time.sleep(args.startup_grace + args.settle)
            if not args.skip_liveness_check:
                assert_draws_advancing(metrics_path)
            # Anchor the playback summary to exactly the window the cost
            # sampler measures. Selecting "the last N seconds of the file"
            # instead silently swept in the post-EOF tail, where the clip has
            # ended and nothing draws -- which read as 25 fps at 0.84x when
            # the player was in fact holding a flawless 30 fps at 1.0x.
            window_start_index = len(parse_metrics(metrics_path))
            cost = sample_cost(target_pid, args.duration,
                               interval_s=args.interval)
            window_end_index = len(parse_metrics(metrics_path))
        failures = load.poll_failures()
        if failures and args.mode != "none":
            raise HarnessError("load died mid-window: " + "; ".join(failures))
    except HarnessError as exc:
        cost_error = str(exc)
    finally:
        load.stop()

    # The player self-quits via WAM_TEST_QUIT_AFTER_MS, which is what produces
    # the terminal telemetry commit. Never SIGTERM: Qt installs no handler, so
    # the stream would be truncated and the run disqualified.
    try:
        launcher.wait(timeout=60.0)
    except subprocess.TimeoutExpired:
        launcher.terminate()

    rows = parse_metrics(metrics_path)
    windowed = rows[window_start_index:window_end_index]
    summary = summarize_playback(windowed if len(windowed) >= 2 else rows,
                                 window_s=None if len(windowed) >= 2
                                 else args.duration)
    summary["window_rows"] = len(windowed)

    report: dict[str, Any] = {
        "trial": tag,
        "mode": args.mode,
        "clip": str(clip),
        "rate": args.rate,
        "pid": target_pid,
        "duration_s": args.duration,
        "state_lines_scrubbed": removed,
        "foreign_wam_pids_left_alone": sorted(pre_existing),
        "window_park": park_result,
        "window_raises": keeper.raises,
        "window_raise_failures": keeper.failed_raises,
        "user_idle_s_at_start": idle_at_start,
        "user_idle_s_at_end": user_idle_seconds(),
        "load": load.description,
        "playback": summary,
        "acceptance": check_acceptance(summary),
        "self_cost": cost,
        "artifacts": {
            "metrics": str(metrics_path),
            "telemetry": str(telemetry_path),
        },
    }
    if cost_error:
        report["cost_error"] = cost_error
    return report


def _uuid4() -> str:
    import uuid
    return str(uuid.uuid4())


# --------------------------------------------------------------------------
# Commands
# --------------------------------------------------------------------------

def cmd_build(args: argparse.Namespace) -> int:
    built = build_all(force=args.force)
    print(json.dumps({"built": built}, indent=2))
    return 0


def cmd_load(args: argparse.Namespace) -> int:
    handle = start_load(
        args.mode, args.duration,
        cpu_workers=args.cpu_workers,
        game_workers=args.game_workers,
        gpu_threads=args.gpu_threads,
        gpu_iters=args.gpu_iters,
        gpu_inflight=args.gpu_inflight,
        quiet=not args.verbose,
    )
    print(json.dumps(handle.description, indent=2), file=sys.stderr)
    try:
        deadline = time.monotonic() + args.duration
        while time.monotonic() < deadline:
            time.sleep(0.5)
            failures = handle.poll_failures()
            if failures:
                raise HarnessError("load process died: " + "; ".join(failures))
    except KeyboardInterrupt:
        pass
    finally:
        handle.stop()
    return 0


def cmd_sample(args: argparse.Namespace) -> int:
    report = sample_cost(args.pid, args.duration, interval_s=args.interval)
    if not args.series:
        report.pop("series", None)
    print(json.dumps(report, indent=2))
    return 0


def cmd_measure(args: argparse.Namespace) -> int:
    """Hold load up across a sampling window against an already-running target.

    Load is started first and given a settle period so the window never
    straddles the ramp; the target's cost is then sampled across steady-state
    contention only.
    """
    handle = start_load(
        args.mode, args.duration + args.settle + 2.0,
        cpu_workers=args.cpu_workers,
        game_workers=args.game_workers,
        gpu_threads=args.gpu_threads,
        gpu_iters=args.gpu_iters,
        gpu_inflight=args.gpu_inflight,
    )
    try:
        if args.settle > 0:
            time.sleep(args.settle)
        failures = handle.poll_failures()
        if failures:
            raise HarnessError("load failed to hold: " + "; ".join(failures))
        report = sample_cost(args.pid, args.duration, interval_s=args.interval)
        report["load"] = handle.description
        failures = handle.poll_failures()
        if failures:
            raise HarnessError(
                "load died during the window, so the result is not a "
                "loaded measurement: " + "; ".join(failures)
            )
    finally:
        handle.stop()
    if not args.series:
        report.pop("series", None)
    print(json.dumps(report, indent=2))
    return 0


def cmd_calibrate_gpu(args: argparse.Namespace) -> int:
    print(json.dumps(calibrate_gpu_saturation(args.duration), indent=2))
    return 0


def cmd_trial(args: argparse.Namespace) -> int:
    report = run_trial(args)
    print(json.dumps(report, indent=2))
    return 0 if report["acceptance"]["overall"] == "pass" else 1


def cmd_matrix(args: argparse.Namespace) -> int:
    """The baseline table: one clip across all four load conditions."""
    reports = []
    aborted = None
    for mode in args.modes:
        # The current window always finishes -- a half-measured window is
        # worthless -- but a returning user stops the NEXT one. Saturating
        # every core under someone who has just sat back down is not a
        # benchmark, it is a denial of service.
        idle = user_idle_seconds()
        if (reports and args.min_idle_s > 0 and idle is not None
                and idle < args.min_idle_s):
            aborted = (
                f"stopped before '{mode}': user active again "
                f"(idle {idle:.0f}s < {args.min_idle_s:.0f}s). "
                f"Completed: {[r['mode'] for r in reports]}"
            )
            print(aborted, file=sys.stderr)
            break
        trial_args = argparse.Namespace(**vars(args))
        trial_args.mode = mode
        print(f"--- {mode} (idle {idle}) ---", file=sys.stderr)
        reports.append(run_trial(trial_args))
        if args.cooldown > 0:
            time.sleep(args.cooldown)

    print(json.dumps({"matrix": reports, "aborted": aborted}, indent=2))
    print("\n" + format_matrix_table(reports), file=sys.stderr)
    return 0


def format_matrix_table(reports: list[dict[str, Any]]) -> str:
    header = (
        f"{'mode':10} {'fps':>7} {'fps_min':>8} {'late':>6} {'under':>6} "
        f"{'rate':>7} {'cpu%':>7} {'verdict':>8}"
    )
    lines = [header, "-" * len(header)]
    for report in reports:
        play = report.get("playback", {})
        cost = report.get("self_cost") or {}
        cpu = (cost.get("cpu") or {}).get("mean_percent_of_core")

        def num(value, spec=".1f"):
            return format(value, spec) if isinstance(value, (int, float)) else "-"

        lines.append(
            f"{report['mode']:10} "
            f"{num(play.get('drawn_fps_mean')):>7} "
            f"{num(play.get('drawn_fps_min_interval')):>8} "
            f"{str(play.get('late_drops', '-')):>6} "
            f"{str(play.get('audio_underruns', '-')):>6} "
            f"{num(play.get('achieved_clock_rate'), '.4f'):>7} "
            f"{num(cpu):>7} "
            f"{report['acceptance']['overall']:>8}"
        )
    return "\n".join(lines)


def add_trial_options(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--app", type=Path, default=DEFAULT_APP)
    parser.add_argument(
        "--clip", type=Path, default=CLIP_DIR / "h264-high.mp4"
    )
    parser.add_argument("--duration", type=float, default=60.0,
                        help="length of the measured window")
    parser.add_argument("--startup-grace", type=float, default=4.0,
                        help="playback settle time before the window opens")
    parser.add_argument("--settle", type=float, default=2.0,
                        help="load ramp time before the window opens")
    parser.add_argument("--interval", type=float, default=SAMPLE_INTERVAL_DEFAULT_S)
    parser.add_argument("--metrics-interval-ms", type=int, default=500)
    parser.add_argument("--rate", type=float, default=1.0)
    parser.add_argument(
        "--out-dir", type=Path,
        default=PROJECT_ROOT / ".cache" / "benchmarks" / "stress" / "runs",
    )
    parser.add_argument(
        "--skip-liveness-check", action="store_true",
        help="measure even if the window is not drawing. Only meaningful "
             "when occlusion IS the thing under test",
    )


def add_load_options(parser: argparse.ArgumentParser) -> None:
    parser.add_argument(
        "--mode", choices=["none", "cpu", "gpu", "combined"], default="combined"
    )
    parser.add_argument(
        "--cpu-workers", type=int, default=None,
        help="utility-QoS spinners; default is ~75%% of cores",
    )
    parser.add_argument(
        "--game-workers", type=int, default=CPU_GAME_WORKERS_DEFAULT,
        help="user-initiated-QoS spinners standing in for a game's workers",
    )
    parser.add_argument("--gpu-threads", type=int, default=1 << 20)
    parser.add_argument("--gpu-iters", type=int, default=2048)
    parser.add_argument("--gpu-inflight", type=int, default=3)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)

    p_build = sub.add_parser("build", help="compile the load helpers")
    p_build.add_argument("--force", action="store_true")
    p_build.set_defaults(func=cmd_build)

    p_load = sub.add_parser("load", help="generate load for a duration")
    p_load.add_argument("--duration", type=float, default=60.0)
    p_load.add_argument("--verbose", action="store_true")
    add_load_options(p_load)
    p_load.set_defaults(func=cmd_load)

    p_sample = sub.add_parser("sample", help="sample a pid's own cost")
    p_sample.add_argument("--pid", type=int, required=True)
    p_sample.add_argument("--duration", type=float, default=60.0)
    p_sample.add_argument("--interval", type=float, default=SAMPLE_INTERVAL_DEFAULT_S)
    p_sample.add_argument("--series", action="store_true")
    p_sample.set_defaults(func=cmd_sample)

    p_measure = sub.add_parser(
        "measure", help="hold load up while sampling a pid's own cost"
    )
    p_measure.add_argument("--pid", type=int, required=True)
    p_measure.add_argument("--duration", type=float, default=60.0)
    p_measure.add_argument("--interval", type=float, default=SAMPLE_INTERVAL_DEFAULT_S)
    p_measure.add_argument("--settle", type=float, default=3.0)
    p_measure.add_argument("--series", action="store_true")
    add_load_options(p_measure)
    p_measure.set_defaults(func=cmd_measure)

    p_cal = sub.add_parser(
        "calibrate-gpu",
        help="measure this machine's accumulated-GPU-time units per second "
             "at full saturation, so GPU costs can be quoted as a percentage",
    )
    p_cal.add_argument("--duration", type=float, default=8.0)
    p_cal.set_defaults(func=cmd_calibrate_gpu)

    p_trial = sub.add_parser(
        "trial", help="play one clip under one load mode and judge it"
    )
    add_trial_options(p_trial)
    add_load_options(p_trial)
    p_trial.set_defaults(func=cmd_trial)

    p_matrix = sub.add_parser(
        "matrix", help="run the full no-load/cpu/gpu/combined table"
    )
    add_trial_options(p_matrix)
    add_load_options(p_matrix)
    p_matrix.add_argument(
        "--modes", nargs="+", default=["none", "cpu", "gpu", "combined"],
        choices=["none", "cpu", "gpu", "combined"],
    )
    p_matrix.add_argument("--cooldown", type=float, default=5.0)
    p_matrix.add_argument(
        "--min-idle-s", type=float, default=45.0,
        help="stop before the next condition if the user has been active "
             "more recently than this; 0 disables the check",
    )
    p_matrix.set_defaults(func=cmd_matrix)

    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        return args.func(args)
    except HarnessError as exc:
        print(f"stress_load: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
