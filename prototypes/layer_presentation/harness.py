#!/usr/bin/env python3
"""Measurement harness for the layer-presentation prototype (Phase A).

Launches layerproto detached once per (mode, run) and measures a 60 s
steady-state window with the SAME instrument the existing WAM/QuickTime report
used, imported by path from benchmarks/macos/player_resource_trial.py. That
import is what makes these numbers comparable to the existing rows; nothing in
that file is copied or modified.

Usage:
    python3 harness.py [--modes a,b,c] [--runs 2] [--window 60]
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
PROJECT_ROOT = Path("/Users/wesleymaa/Documents/WAM")
INSTRUMENT = PROJECT_ROOT / "benchmarks" / "macos" / "player_resource_trial.py"
BINARY = HERE / "layerproto"
RESULTS = HERE / "results"
CLIP = (PROJECT_ROOT / ".cache" / "benchmarks" / "media" /
        "adhoc-native-1080p" / "h264-high.mp4")

MODES = ["asbdl-decoded", "asbdl-compressed", "metal-blit",
         "iosurface-contents", "idle-window"]

HELPER_NAME = "VTDecoderXPCService"


# ------------------------------------------------------------- instrument

def load_instrument():
    """Import benchmarks/macos/player_resource_trial.py by path.

    Reusing the exact collectors (cpu_seconds, agx_gpu_time, footprint, ...)
    is the whole point: a re-implementation would not be comparable to the
    existing WAM / QuickTime numbers.
    """
    spec = importlib.util.spec_from_file_location("wam_trial", INSTRUMENT)
    mod = importlib.util.module_from_spec(spec)
    # The module parses argv at main() only, so a plain exec_module is safe.
    spec.loader.exec_module(mod)
    return mod


T = load_instrument()

REQUIRED = ["cpu_seconds", "agx_gpu_time", "gpu_calibration",
            "gpu_percent_of_device", "footprint", "cpu_idle_percent",
            "heaviest_process", "free_bytes"]
missing = [n for n in REQUIRED if not hasattr(T, n)]
if missing:
    sys.exit(f"instrument missing required collectors: {missing}")


# ------------------------------------------------------------- extras
# Additive probes that the shared instrument does not provide. These do not
# duplicate or replace any collector above.

_AGX_BLOCK = re.compile(r"(?m)^.*\+-o AGXDeviceUserClient\b")
_AGX_CREATOR = re.compile(r'"IOUserClientCreator"\s*=\s*"pid (\d+)')


def agx_client_count(pids):
    """How many AGXDeviceUserClient objects the kernel attributes to pids.

    Distinguishes "this process never opened the GPU" (count 0) from "opened
    the GPU but did no work" (count > 0, accumulatedGPUTime delta 0). That
    difference is the whole question for the pivot.
    """
    dump = subprocess.run(["ioreg", "-r", "-c", "AGXDeviceUserClient", "-w", "0", "-l"],
                          capture_output=True, text=True).stdout
    if not dump:
        return None
    wanted = {str(p) for p in pids}
    starts = [m.start() for m in _AGX_BLOCK.finditer(dump)]
    n = 0
    for i, s in enumerate(starts):
        e = starts[i + 1] if i + 1 < len(starts) else len(dump)
        m = _AGX_CREATOR.search(dump[s:e])
        if m and m.group(1) in wanted:
            n += 1
    return n


_SIZE_RE = re.compile(r"^\s*([\d.]+)\s*(B|KB|MB|GB)\s")
_UNITS = {"B": 1, "KB": 1024, "MB": 1024 ** 2, "GB": 1024 ** 3}
_GFX_TOKENS = ("iosurface", "ioaccelerator", "agx", "metal", "graphic",
               "gpu", "iokit", "carve", "coregraphics")


def footprint_verbose(pid):
    """Parse `/usr/bin/footprint -v <pid>`.

    The brief asked for the "Owned physical footprint (graphics)" line, which
    is where the ~244 MiB AGX render-pass pool shows up on some systems. On
    macOS 26.3.1 this build of footprint(1) does not emit a line with that
    label, so we report whether it was present and fall back to summing the
    graphics-ish rows of the category summary table.
    """
    res = subprocess.run(["/usr/bin/footprint", "-v", str(pid)],
                         capture_output=True, text=True, timeout=60)
    out = res.stdout or ""
    owned_line = None
    for ln in out.splitlines():
        if "owned physical footprint" in ln.lower():
            owned_line = ln.strip()
    gfx = {}
    total = None
    phys = None
    for ln in out.splitlines():
        m = _SIZE_RE.match(ln)
        if not m:
            continue
        parts = ln.split()
        cat = " ".join(parts[6:]) if len(parts) > 6 else ""
        low = cat.lower()
        val = float(m.group(1)) * _UNITS[m.group(2)]
        if cat.strip() == "TOTAL":
            total = val
        if any(tok in low for tok in _GFX_TOKENS):
            gfx[cat] = gfx.get(cat, 0) + val
    m = re.search(r"phys_footprint:\s*([\d.]+)\s*(B|KB|MB|GB)", out)
    if m:
        phys = float(m.group(1)) * _UNITS[m.group(2)]
    return {
        "owned_physical_footprint_graphics_line": owned_line,
        "owned_graphics_line_present": owned_line is not None,
        "graphics_rows_bytes": int(sum(gfx.values())),
        "graphics_rows_detail": {k: int(v) for k, v in gfx.items()},
        "verbose_total_bytes": int(total) if total else None,
        "verbose_phys_footprint_bytes": int(phys) if phys else None,
    }


def helper_pids():
    res = subprocess.run(["pgrep", "-x", HELPER_NAME], capture_output=True, text=True)
    return {int(x) for x in res.stdout.split()}


def alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


# ------------------------------------------------------------- one trial

def launch(mode, app_json, proof_tsv, duration):
    cmd = [str(BINARY), f"--mode={mode}", f"--duration={duration}",
           f"--out={app_json}"]
    if mode != "idle-window":
        cmd.append(f"--clip={CLIP}")
        cmd.append(f"--proof-log={proof_tsv}")
    # Detached: no controlling terminal, survives independently, and its
    # stdout does not interleave with the harness.
    return subprocess.Popen(cmd, stdout=subprocess.DEVNULL,
                            stderr=subprocess.PIPE, start_new_session=True)


def measure_window(pid, helpers, window):
    """Sample the collectors, wait `window` seconds, sample again.

    The headline numbers are PROCESS-ONLY (the prototype's own pid). This
    machine keeps ~220 VTDecoderXPCService instances alive for other apps and
    they churn constantly, so folding "new" helper pids into the primary set
    lets unrelated system noise both inflate the numbers and break footprint(1)
    when a helper exits mid-window. Helper cost is measured separately with
    cpu_seconds_by_pid, which tolerates pids that come and go.
    """
    fp_start = T.footprint([pid])
    cpu0 = T.cpu_seconds([pid])
    hcpu0 = T.cpu_seconds_by_pid(helpers) if helpers else {}
    gpu0 = T.agx_gpu_time([pid])
    clients0 = agx_client_count([pid])
    t0 = time.monotonic()

    time.sleep(window)

    wall = time.monotonic() - t0
    cpu1 = T.cpu_seconds([pid])
    hcpu1 = T.cpu_seconds_by_pid(helpers) if helpers else {}
    gpu1 = T.agx_gpu_time([pid])
    cpu_pct = None
    if cpu0 is not None and cpu1 is not None and wall > 0:
        cpu_pct = 100.0 * (cpu1 - cpu0) / wall
    both = set(hcpu0) & set(hcpu1)
    helper_cpu = sum(hcpu1[p] - hcpu0[p] for p in both)
    return {
        "window_seconds": wall,
        "cpu_percent_of_one_core": cpu_pct,
        "helper_cpu_percent_of_one_core": (100.0 * helper_cpu / wall) if wall > 0 else None,
        "helper_pids_sampled": sorted(both),
        "gpu_percent_of_device": T.gpu_percent_of_device(gpu1, gpu0, wall),
        "agx_gpu_time_delta": ((gpu1 - gpu0)
                               if (gpu0 is not None and gpu1 is not None) else None),
        "agx_client_count_start": clients0,
        "agx_client_count_end": agx_client_count([pid]),
        "footprint_start": fp_start,
        "footprint_end": T.footprint([pid]),
        "footprint_verbose": footprint_verbose(pid),
    }


def reap(proc, pid, app_json, tail):
    deadline = time.time() + tail + 30
    while alive(pid) and time.time() < deadline:
        time.sleep(0.5)
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        proc.kill()
    if not app_json.exists():
        return {}
    try:
        return json.loads(app_json.read_text())
    except json.JSONDecodeError as e:
        return {"parse_error": str(e)}


def run_trial(mode, run_idx, window, warmup, tail):
    app_json = RESULTS / f"{mode}-{run_idx}.app.json"
    proof_tsv = RESULTS / f"{mode}-{run_idx}.proof.tsv"

    helpers_before = helper_pids()
    quiet_before = {"cpu_idle_percent": T.cpu_idle_percent(),
                    "heaviest_process": T.heaviest_process()}
    free_before = T.free_bytes()

    proc = launch(mode, app_json, proof_tsv, warmup + window + tail)
    pid = proc.pid
    time.sleep(warmup)
    if not alive(pid):
        err = (proc.stderr.read() or b"").decode()[:400]
        return {"mode": mode, "run": run_idx, "error": f"died during warmup: {err}"}

    # Attribute decode helpers by before/after pid diff: this machine keeps
    # ~220 VTDecoderXPCService instances alive for other apps, all reparented
    # to launchd, so ppid-based attribution is useless here.
    helpers_new = sorted(helper_pids() - helpers_before)

    row = measure_window(pid, helpers_new, window)
    quiet_after = {"cpu_idle_percent": T.cpu_idle_percent(),
                   "heaviest_process": T.heaviest_process()}
    app = reap(proc, pid, app_json, tail)
    # A helper still alive after the prototype exited was never the
    # prototype's -- same rule the existing WAM harness uses.
    survivors = helper_pids()
    row["helper_pids_confirmed"] = [p for p in helpers_new if p not in survivors]
    row["helper_pids_spurious"] = [p for p in helpers_new if p in survivors]

    # Machine-quiet guard. This project has been burned by measuring during a
    # build, so a busy machine is flagged rather than silently reported.
    idles = [q["cpu_idle_percent"] for q in (quiet_before, quiet_after)
             if q["cpu_idle_percent"] is not None]

    row.update({
        "mode": mode,
        "run": run_idx,
        "pid": pid,
        "helper_pids_attributed": helpers_new,
        "quiet_before": quiet_before,
        "quiet_after": quiet_after,
        "machine_contended": bool(idles) and min(idles) < 70.0,
        "free_bytes_before": free_before,
        "free_bytes_after": T.free_bytes(),
        "app": app,
        "app_valid": bool(app.get("valid")),
    })
    return row


def summarize_row(r):
    fp = r.get("footprint_end") or {}
    fpv = r.get("footprint_verbose") or {}
    app = r.get("app") or {}
    vpm = app.get("video_performance_metrics_last") or {}
    return {
        "mode": r.get("mode"),
        "run": r.get("run"),
        "valid": r.get("app_valid"),
        "contended": r.get("machine_contended"),
        "cpu_percent_of_one_core": r.get("cpu_percent_of_one_core"),
        "gpu_percent_of_device": r.get("gpu_percent_of_device"),
        "agx_client_count_end": r.get("agx_client_count_end"),
        "phys_footprint_mb": round(fp.get("phys_footprint_bytes", 0) / 1e6, 1),
        "graphics_categories_mb": round(
            fp.get("in_process_graphics_categories_bytes", 0) / 1e6, 2),
        "footprint_v_graphics_mb": round(fpv.get("graphics_rows_bytes", 0) / 1e6, 2),
        "owned_graphics_line_present": fpv.get("owned_graphics_line_present"),
        "helper_pids": r.get("helper_pids_attributed"),
        "frames_enqueued": app.get("frames_enqueued"),
        "frames_proven_displayed": app.get("frames_proven_displayed"),
        "frames_expected": app.get("frames_expected"),
        "effective_display_fps": app.get("effective_display_fps"),
        "inflight_depth": app.get("inflight_depth"),
        "optimized_compositing": vpm.get(
            "numberOfFramesDisplayedUsingOptimizedCompositing"),
        "dropped_frames": vpm.get("numberOfDroppedFrames"),
        "corrupted_frames": vpm.get("numberOfCorruptedFrames"),
        "metrics_total_frames": vpm.get("totalNumberOfFrames"),
        "accumulated_frame_delay_s": vpm.get("totalAccumulatedFrameDelay"),
        "reader_loop_restarts": app.get("reader_loop_restarts"),
        "no_clip_wrap": app.get("no_clip_wrap"),
        "consumed_distinct_frames": app.get("consumed_distinct_frames"),
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--modes", default=",".join(MODES))
    ap.add_argument("--runs", type=int, default=2)
    # warmup + window + tail MUST stay inside the clip length (h264-high.mp4
    # is 72.0 s). Wrapping the reader stalls the feeder and corrupts the drop
    # and latency statistics, so the prototype marks any wrapped run invalid.
    ap.add_argument("--window", type=float, default=60.0)
    ap.add_argument("--warmup", type=float, default=6.0)
    ap.add_argument("--tail", type=float, default=3.0)
    ap.add_argument("--retries", type=int, default=2)
    ap.add_argument("--outdir", default=None,
                    help="write results under results/<outdir> instead of results/")
    args = ap.parse_args()

    if not BINARY.exists():
        sys.exit(f"missing {BINARY}; run ./build.sh")
    if args.outdir:
        global RESULTS
        RESULTS = RESULTS / args.outdir
    RESULTS.mkdir(parents=True, exist_ok=True)

    modes = [m.strip() for m in args.modes.split(",") if m.strip()]
    all_rows = []
    for mode in modes:
        for n in range(1, args.runs + 1):
            row = None
            for attempt in range(args.retries + 1):
                r = run_trial(mode, n, args.window, args.warmup, args.tail)
                r["attempt"] = attempt + 1
                # Health gate: only a run the prototype itself certifies as
                # VALID (not occluded, fps sustained) is reportable.
                if r.get("app_valid") or mode == "idle-window" and not r.get("error"):
                    row = r
                    break
                print(f"  [{mode} run {n}] attempt {attempt+1} INVALID "
                      f"(occluded={r.get('app', {}).get('occluded_samples_after_grace')}, "
                      f"fps_ok={r.get('app', {}).get('fps_sustained')}) retrying",
                      flush=True)
                row = r
            out = RESULTS / f"{mode}-{n}.json"
            out.write_text(json.dumps(row, indent=2))
            all_rows.append(row)
            fp = (row.get("footprint_end") or {})
            print(f"[{mode} run {n}] cpu={row.get('cpu_percent_of_one_core')} "
                  f"gpu={row.get('gpu_percent_of_device')} "
                  f"phys={ (fp.get('phys_footprint_bytes') or 0)/1e6 :.1f}MB "
                  f"gfx={ (fp.get('in_process_graphics_categories_bytes') or 0)/1e6 :.1f}MB "
                  f"valid={row.get('app_valid')}", flush=True)

    summary = {
        "generated": time.strftime("%Y-%m-%dT%H:%M:%S"),
        "clip": str(CLIP),
        "instrument": str(INSTRUMENT),
        "gpu_calibration": T.gpu_calibration(),
        "window_seconds": args.window,
        "rows": [summarize_row(r) for r in all_rows],
    }
    (RESULTS / "summary.json").write_text(json.dumps(summary, indent=2))
    print(f"\nwrote {RESULTS/'summary.json'}")


if __name__ == "__main__":
    main()
