#!/usr/bin/env python3
"""Resource-usage trial driver: WAM vs VLC vs QuickTime Player.

Measures one (player, clip) trial over a steady-state window and writes a JSON
result. Collector patterns are lifted from benchmarks/macos/collect.py and
benchmarks/macos/stress_load.py (see report for exact provenance).

Not a product change; scratchpad driver only.
"""

from __future__ import annotations

import argparse
import contextlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import uuid
from pathlib import Path

PROJECT_ROOT = Path("/Users/wesleymaa/Documents/WAM")
STATE_TSV = Path.home() / "Library" / "Application Support" / "WAM" / "state.tsv"
GPU_CALIBRATION_PATH = PROJECT_ROOT / ".cache" / "benchmarks" / "stress" / "gpu_calibration.json"
HELPER_BASENAME = "VTDecoderXPCService"

# Window geometry every player is parked at, so compositing cost is comparable.
PARK_POS = (40, 40)
PARK_SIZE = (640, 360)


# ---------------------------------------------------------------- utilities


def run(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, text=True, check=False, **kw)


def sysctl_loadavg() -> float:
    out = run(["sysctl", "-n", "vm.loadavg"]).stdout.strip()
    return float(out.strip("{} ").split()[0])


def free_bytes(path="/System/Volumes/Data") -> int:
    st = os.statvfs(path)
    return st.f_bavail * st.f_frsize


def cpu_idle_percent():
    """Whole-machine idle %, averaged over two 1s top samples.

    A better contention signal than loadavg on this box: macOS loadavg counts
    threads blocked in the iCloud/FileProvider churn that a 100%-full disk
    keeps alive, which costs no CPU and cannot contend with a video player.
    """
    res = run(["/usr/bin/top", "-l", "3", "-n", "0", "-s", "1"], timeout=30)
    vals = []
    for line in res.stdout.splitlines():
        if "CPU usage" in line and "idle" in line:
            for tok in line.split():
                if tok.endswith("%"):
                    last = tok
            with contextlib.suppress(ValueError):
                vals.append(float(line.split()[-2].rstrip("%")))
    return sum(vals[1:]) / len(vals[1:]) if len(vals) > 1 else None


def heaviest_process():
    """(percent, command) of the busiest process, excluding our own tooling."""
    res = run(["ps", "-Ao", "pcpu,comm", "-r"])
    for line in res.stdout.splitlines()[1:]:
        parts = line.strip().split(None, 1)
        if len(parts) != 2:
            continue
        with contextlib.suppress(ValueError):
            return float(parts[0]), parts[1]
    return None, None


# ------------------------------------------------------------ process trees

_PS_TIME_RE = re.compile(r"^(?:(\d+)-)?(?:(\d+):)?(\d+):(\d+(?:\.\d+)?)$")


def parse_ps_time(text: str):
    """`ps -o time=` renders as [[dd-]hh:]mm:ss[.ff]."""
    m = _PS_TIME_RE.match(text.strip())
    if not m:
        return None
    days, hours, minutes, seconds = m.groups()
    return (
        float(days or 0) * 86400.0
        + float(hours or 0) * 3600.0
        + float(minutes or 0) * 60.0
        + float(seconds)
    )


def cpu_seconds_by_pid(pids):
    """Cumulative CPU seconds per pid.

    Per-pid rather than summed so a helper later shown NOT to belong to this
    player can be subtracted out after the fact. This machine runs ~220
    VTDecoderXPCService instances for other apps, and one spawning mid-trial
    would otherwise be silently added to the player's bill.
    """
    if not pids:
        return {}
    res = run(["ps", "-o", "pid=,time=", "-p", ",".join(str(p) for p in pids)])
    out = {}
    for ln in res.stdout.splitlines():
        parts = ln.strip().split(None, 1)
        if len(parts) != 2 or not parts[0].isdigit():
            continue
        v = parse_ps_time(parts[1])
        if v is not None:
            out[int(parts[0])] = v
    return out


def cpu_seconds(pids):
    """Cumulative CPU seconds summed over pids. None if any pid vanished."""
    by_pid = cpu_seconds_by_pid(pids)
    if len(by_pid) != len(set(pids)):
        return None
    return sum(by_pid.values())


def pids_by_name(name: str):
    res = run(["pgrep", "-x", name])
    return [int(x) for x in res.stdout.split()]


def pids_matching(pattern: str):
    res = run(["pgrep", "-f", pattern])
    return [int(x) for x in res.stdout.split()]


def children_of(pid: int):
    res = run(["pgrep", "-P", str(pid)])
    return [int(x) for x in res.stdout.split()]


def proc_command(pid: int) -> str:
    return run(["ps", "-p", str(pid), "-o", "command="]).stdout.strip()


# --------------------------------------------------------------- ioreg AGX

_ACCUM_GPU_TIME_RE = re.compile(r'"accumulatedGPUTime"\s*=\s*(\d+)')
_CLIENT_CREATOR_RE = re.compile(r'"IOUserClientCreator"\s*=\s*"pid (\d+)')
_CLIENT_BLOCK_RE = re.compile(r"(?m)^.*\+-o AGXDeviceUserClient\b")


def agx_gpu_time(pids):
    """Sum accumulatedGPUTime over every AGXDeviceUserClient owned by pids.

    Unit is undocumented by Apple; only DIFFERENCES of the same counter mean
    anything. Pattern from stress_load.py:510-540.
    """
    dump = run(["ioreg", "-r", "-c", "AGXDeviceUserClient", "-w", "0", "-l"]).stdout
    if not dump:
        return None
    wanted = {str(p) for p in pids}
    starts = [m.start() for m in _CLIENT_BLOCK_RE.finditer(dump)]
    total = 0
    found = False
    for i, s in enumerate(starts):
        e = starts[i + 1] if i + 1 < len(starts) else len(dump)
        block = dump[s:e]
        creator = _CLIENT_CREATOR_RE.search(block)
        if not creator or creator.group(1) not in wanted:
            continue
        for m in _ACCUM_GPU_TIME_RE.finditer(block):
            total += int(m.group(1))
            found = True
    return total if found else 0


def gpu_calibration():
    try:
        data = json.loads(GPU_CALIBRATION_PATH.read_text(encoding="utf-8"))
        v = float(data["units_per_second_at_full_gpu"])
        return v if v > 0 else None
    except (OSError, ValueError, KeyError, TypeError):
        return None


def gpu_percent_of_device(end_gpu, start_gpu, wall):
    scale = gpu_calibration()
    if scale is None or end_gpu is None or start_gpu is None or wall <= 0:
        return None
    return 100.0 * ((end_gpu - start_gpu) / wall) / scale


# --------------------------------------------------------------- footprint


def footprint(pids):
    """/usr/bin/footprint --json over pids. Returns per-pid + totals.

    Note: the AGX driver's unmapped render-pass pool is only attributable with
    `footprint --unmapped`, which requires root. Without it we still surface
    every in-process graphics-ish category we can see.
    """
    if not pids:
        return None
    with tempfile.TemporaryDirectory(prefix="wam-fp-") as d:
        out = Path(d) / "fp.json"
        cmd = ["/usr/bin/footprint", "--json", str(out)]
        for p in pids:
            cmd.extend(["--pid", str(p)])
        res = run(cmd, timeout=30)
        if not out.exists():
            return {"error": (res.stderr or res.stdout).strip()[:400]}
        report = json.loads(out.read_text())

    scale = float(report.get("bytes per unit") or 1.0)
    procs = []
    cur = peak = 0
    gfx = 0
    for p in report.get("processes", []):
        aux = p.get("auxiliary", {}) or {}
        c = aux.get("phys_footprint")
        k = aux.get("phys_footprint_peak")
        c = int(round(c * scale)) if c is not None else None
        k = int(round(k * scale)) if k is not None else None
        cats = p.get("categories", {}) or {}
        pgfx = 0
        gfx_detail = {}
        for name, v in cats.items():
            low = name.lower()
            if any(s in low for s in ("gpu", "graphic", "iokit", "accel", "carve", "metal", "iosurface")):
                b = int(round((v.get("dirty", 0) + v.get("clean", 0)) * scale))
                if b:
                    gfx_detail[name] = b
                    pgfx += b
        procs.append({
            "pid": p.get("pid"),
            "name": p.get("name"),
            "translated": p.get("translated"),
            "phys_footprint_bytes": c,
            "phys_footprint_peak_bytes": k,
            "graphics_categories_bytes": pgfx,
            "graphics_category_detail": gfx_detail,
        })
        cur += c or 0
        peak += k or 0
        gfx += pgfx
    return {
        "processes": procs,
        "phys_footprint_bytes": cur,
        "peak_phys_footprint_bytes": peak,
        "in_process_graphics_categories_bytes": gfx,
        "total_footprint_bytes": report.get("total footprint"),
        "peak_policy": (
            "sum of each process's kernel-reported peak; individual peaks may "
            "have occurred at different times"
        ),
        "unmapped_pool_note": (
            "AGX driver-owned unmapped render-pass pool is NOT included: "
            "`footprint --unmapped` requires root"
        ),
    }


# -------------------------------------------------------------- top power


# ------------------------------------------------------- WAM health gate


def read_metrics(path: Path):
    rows = []
    if not path.exists():
        return rows
    for line in path.read_text(errors="replace").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
        except ValueError:
            continue
        if obj.get("record") == "playback_sample":
            rows.append(obj)
    return rows


def summarize_playback(rows, t0_ns=None, t1_ns=None):
    sel = [r for r in rows if r.get("drawn_frames") is not None]
    if t0_ns is not None:
        sel = [r for r in sel if r.get("t_mono_ns", 0) >= t0_ns]
    if t1_ns is not None:
        sel = [r for r in sel if r.get("t_mono_ns", 0) <= t1_ns]
    if len(sel) < 2:
        return {"status": "unknown", "reason": f"only {len(sel)} drawing samples in window"}
    a, b = sel[0], sel[-1]
    wall = (b["t_mono_ns"] - a["t_mono_ns"]) / 1e9
    if wall <= 0:
        return {"status": "unknown", "reason": "zero wall span"}
    out = {
        "window_seconds": round(wall, 3),
        "drawn_fps": round((b["drawn_frames"] - a["drawn_frames"]) / wall, 3),
        "submitted_fps": round((b.get("submitted_frames", 0) - a.get("submitted_frames", 0)) / wall, 3),
        "discarded_late_frames": b.get("discarded_late_frames", 0) - a.get("discarded_late_frames", 0),
        "superseded_frames": b.get("superseded_frames", 0) - a.get("superseded_frames", 0),
        "samples": len(sel),
    }
    if a.get("audio_underrun_callbacks") is not None and b.get("audio_underrun_callbacks") is not None:
        out["audio_underruns"] = b["audio_underrun_callbacks"] - a["audio_underrun_callbacks"]
    else:
        out["audio_underruns"] = None
    if a.get("media_seconds") is not None and b.get("media_seconds") is not None:
        out["media_advanced_seconds"] = round(b["media_seconds"] - a["media_seconds"], 3)
        out["media_rate_vs_wall"] = round((b["media_seconds"] - a["media_seconds"]) / wall, 4)
    rates = [r["clock_rate"] for r in sel if r.get("clock_rate") is not None]
    out["clock_rate_mean"] = round(sum(rates) / len(rates), 5) if rates else None

    # ACCEPTANCE mirrors stress_load.py:1158-1162
    reasons = []
    if out["drawn_fps"] < 27.0:
        reasons.append(f"drawn_fps {out['drawn_fps']} < 27.0")
    if out["audio_underruns"] is None:
        pass  # silent clip / fallback: not a failure by itself
    elif out["audio_underruns"] > 0:
        reasons.append(f"{out['audio_underruns']} audio underruns")
    if out["clock_rate_mean"] is not None and not (0.99 <= out["clock_rate_mean"] <= 1.01):
        reasons.append(f"clock_rate {out['clock_rate_mean']} out of [0.99,1.01]")
    out["status"] = "pass" if not reasons else "fail"
    out["reasons"] = reasons
    return out


# ------------------------------------------------------------ window park


def park_window(app_process: str, timeout_s: float = 15.0):
    """Park window 1 at the common geometry, waiting for it to exist first.

    A bare one-shot park races the app's window creation and silently returns
    "no-windows", which would leave the trial compositing at whatever default
    size the app chose -- not comparable across rows.
    """
    deadline = time.monotonic() + timeout_s
    last = "no-windows"
    while time.monotonic() < deadline:
        last = _park_once(app_process)
        if last.startswith("parked"):
            geom = window_geometry(app_process)
            return f"{last}; geometry={geom}"
        time.sleep(0.5)
    return f"FAILED-TO-PARK ({last})"


def _park_once(app_process: str):
    script = f'''
    tell application "System Events"
      if exists process "{app_process}" then
        tell process "{app_process}"
          if (count of windows) > 0 then
            set position of window 1 to {{{PARK_POS[0]}, {PARK_POS[1]}}}
            set size of window 1 to {{{PARK_SIZE[0]}, {PARK_SIZE[1]}}}
            return "parked " & (name of window 1)
          else
            return "no-windows"
          end if
        end tell
      else
        return "no-process"
      end if
    end tell
    '''
    return run(["osascript", "-e", script]).stdout.strip()


def window_geometry(app_process: str):
    script = f'''
    tell application "System Events"
      tell process "{app_process}"
        if (count of windows) > 0 then
          set p to position of window 1
          set s to size of window 1
          return ((item 1 of p) as text) & "," & ((item 2 of p) as text) & "," & ((item 1 of s) as text) & "," & ((item 2 of s) as text)
        else
          return "no-windows"
        end if
      end tell
    end tell
    '''
    res = run(["osascript", "-e", script])
    return res.stdout.strip() or f"error: {res.stderr.strip()[:120]}"


# ------------------------------------------------------------------ trial


def sample_loop(pids_fn, duration, cadence=1.0):
    """Sample CPU at cadence; return per-sample %CPU list and endpoint totals."""
    t_start = time.monotonic()
    pids = pids_fn()
    first_by_pid = cpu_seconds_by_pid(pids)
    last_by_pid = dict(first_by_pid)
    c_prev = cpu_seconds(pids)
    c_start = c_prev
    t_prev = time.monotonic()
    percents = []
    tree_snapshots = [sorted(pids)]
    while True:
        now = time.monotonic()
        if now - t_start >= duration:
            break
        time.sleep(max(0.0, cadence - (time.monotonic() - t_prev)))
        pids = pids_fn()
        if sorted(pids) not in tree_snapshots:
            tree_snapshots.append(sorted(pids))
        now = time.monotonic()
        by_pid = cpu_seconds_by_pid(pids)
        for pid, v in by_pid.items():
            first_by_pid.setdefault(pid, v)
            last_by_pid[pid] = v
        c = sum(by_pid.values()) if len(by_pid) == len(set(pids)) else None
        dt = now - t_prev
        if c is None or c_prev is None:
            c_prev, t_prev = c, now
            continue
        if dt > 0 and c >= c_prev:
            percents.append(100.0 * (c - c_prev) / dt)
        c_prev, t_prev = c, now
    t_end = time.monotonic()
    c_end = cpu_seconds(pids)
    wall = t_end - t_start
    mean = None
    if c_end is not None and c_start is not None and wall > 0:
        mean = 100.0 * (c_end - c_start) / wall
    cpu_seconds_per_pid = {
        pid: round(last_by_pid[pid] - first_by_pid.get(pid, last_by_pid[pid]), 3)
        for pid in last_by_pid
    }
    return {
        "cpu_mean_percent": mean,
        "cpu_max_percent": max(percents) if percents else None,
        "cpu_samples": len(percents),
        "cpu_seconds_total": (c_end - c_start) if (c_end is not None and c_start is not None) else None,
        "cpu_seconds_per_pid": cpu_seconds_per_pid,
        "wall_seconds": wall,
        "tree_snapshots": tree_snapshots,
    }


def check_guards(args, result):
    """Machine-quietness, disk, and pre-existing-instance gates.

    Returns an exit code to abort with, or None to proceed.
    """
    # Refusal is unconditional and independent of machine state, so it is
    # decided before the quietness gate gets a chance to mask it.
    refuse = {"vlc": "VLC", "quicktime": "QuickTime Player"}.get(args.player)
    if refuse:
        pre = pids_by_name(refuse)
        if pre:
            result["status"] = "refused"
            result["reason"] = (
                f"{refuse} already running (pids {pre}); task forbids "
                "measuring a pre-existing instance"
            )
            return 3

    la = sysctl_loadavg()
    idle = cpu_idle_percent()
    heavy_pct, heavy_cmd = heaviest_process()
    result["loadavg_1m_at_start"] = la
    result["cpu_idle_percent_at_start"] = idle
    result["heaviest_process_at_start"] = {"percent": heavy_pct, "command": heavy_cmd}
    if idle is not None and idle < args.min_idle:
        result["status"] = "aborted"
        result["reason"] = f"cpu idle {idle:.1f}% < {args.min_idle}%"
        return 2
    if heavy_pct is not None and heavy_pct > args.max_heavy:
        result["status"] = "aborted"
        result["reason"] = f"heavy process {heavy_cmd} at {heavy_pct}% > {args.max_heavy}%"
        return 2
    if la > args.max_loadavg:
        result["status"] = "aborted"
        result["reason"] = f"loadavg {la} > {args.max_loadavg}"
        return 2
    fb = free_bytes()
    result["free_disk_bytes"] = fb
    if fb < 2 * 1024**3:
        result["status"] = "aborted"
        result["reason"] = "disk guard: <2GB free"
        return 2
    return None


def launch_player(args, result, metrics_path, telemetry_path):
    """Start the player under test. Returns its AX process name."""
    if args.player == "wam":
        app = PROJECT_ROOT / "build" / "WAM.app"
        quit_after_ms = int((args.lead_in + args.window + 8.0) * 1000)
        env_args = [
            "--env", "WAM_NATIVE_BENCHMARK_TELEMETRY=1",
            "--env", f"WAM_NATIVE_BENCHMARK_RUN_ID={uuid.uuid4()}",
            "--env", f"WAM_TEST_QUIT_AFTER_MS={quit_after_ms}",
            "--env", f"WAM_PLAYBACK_METRICS_PATH={metrics_path}",
            "--env", "WAM_PLAYBACK_METRICS_INTERVAL_MS=500",
            "--stderr", str(telemetry_path),
        ]
        cmd = ["/usr/bin/open", "-n", *env_args, "-a", str(app)]
        if args.clip:
            cmd += ["--args", args.clip]
        name = "WAM"
    elif args.player == "vlc":
        cmd = ["/usr/bin/open", "-n", "-a", "/Applications/VLC.app", args.clip]
        name = "VLC"
    else:
        cmd = ["open", "-a", "QuickTime Player", args.clip]
        name = "QuickTime Player"
    result["launch_command"] = " ".join(cmd)
    run(cmd)
    return name


def resolve_pid(player):
    """Wait for the launched player process to appear."""
    deadline = time.monotonic() + 20
    while time.monotonic() < deadline:
        if player == "wam":
            cands = pids_matching("build/WAM.app/Contents/MacOS/WAM")
        elif player == "vlc":
            cands = pids_by_name("VLC")
        else:
            cands = pids_by_name("QuickTime Player")
        if cands:
            return max(cands)
        time.sleep(0.25)
    return None


def qt_current_time():
    return run(["osascript", "-e",
                'tell application "QuickTime Player" to get current time of document 1']
               ).stdout.strip()


def vlc_current_time():
    """VLC exposes `current time` as an INTEGER number of seconds (1 s
    resolution), so the position gate tolerates +/-1 s over the window."""
    return run(["osascript", "-e",
                'tell application "VLC" to get current time']).stdout.strip()


def vlc_state():
    out = run(["osascript", "-e",
               'tell application "VLC" to return '
               '((playing as text) & "|" & (current time as text) & "|" & '
               '(duration of current item as text) & "|" & name of current item)'])
    return out.stdout.strip() or f"error: {out.stderr.strip()[:120]}"


def qt_document_count():
    out = run(["osascript", "-e",
               'tell application "QuickTime Player" to return (count of documents) as text'])
    text = out.stdout.strip()
    return int(text) if text.isdigit() else 0


def verify_advancing(player, timeout_s=45.0, gap=1.5):
    """Poll until the transport actually moves, not merely reports 'playing'.

    VLC reports playing=true up to ~10 s before its clock starts, and resizing
    its window during that load phase stalls it outright -- so this has to be a
    patient poll, and everything else has to wait behind it.
    """
    deadline = time.monotonic() + timeout_s
    reads = []
    baseline = None
    while time.monotonic() < deadline:
        pos = player_position(player)
        reads.append(pos)
        try:
            v = float(pos)
        except (TypeError, ValueError):
            v = None
        if v is not None:
            if baseline is None:
                baseline = v
            elif v > baseline:
                return True, {"reads": reads[-6:], "advanced": True,
                              "waited_s": round(timeout_s - (deadline - time.monotonic()), 1)}
        time.sleep(gap)
    return False, {"reads": reads[-8:], "advanced": False, "waited_s": timeout_s}


def ensure_playing(player, timeout_s=30.0):
    """Drive a third-party player into a confirmed-advancing state.

    QuickTime opens its document asynchronously, so `play document 1` sent too
    early fails with -1719 and the trial silently measures a paused window.
    VLC also resizes its own window to the video once loaded, which is why
    parking has to happen after this, not before.
    """
    detail = {"player": player}
    deadline = time.monotonic() + timeout_s
    if player == "quicktime":
        while time.monotonic() < deadline and qt_document_count() < 1:
            time.sleep(0.5)
        detail["documents"] = qt_document_count()
        play = run(["osascript", "-e",
                    'tell application "QuickTime Player" to play document 1'])
        detail["play_stderr"] = play.stderr.strip()[:160]
    elif player == "vlc":
        # VLC autoplays on open; nudge it only if it says it is not playing.
        while time.monotonic() < deadline:
            state = run(["osascript", "-e",
                         'tell application "VLC" to return playing as text']).stdout.strip()
            if state == "true":
                break
            time.sleep(0.5)
        detail["reported_playing"] = state
        if state != "true":
            run(["osascript", "-e", 'tell application "VLC" to play'])
    ok, adv = verify_advancing(player)
    detail.update(adv)
    detail["ok"] = ok
    return ok, detail


def player_position(player):
    if player == "quicktime":
        return qt_current_time()
    if player == "vlc":
        return vlc_current_time()
    return None


def measure_window(args, result, tree, app_process_name, metrics_path, t_open):
    """Park the window, run the lead-in, then sample the steady-state window."""
    time.sleep(2.0)
    t_ref = t_open
    if args.player != "wam":
        # Establish playback FIRST and anchor the lead-in to it. VLC needs ~10 s
        # before its clock moves and resizes its own window on load, so parking
        # before that both gets overwritten and stalls the transport.
        ok, detail = ensure_playing(args.player)
        result["prepare"] = detail
        t_ref = time.monotonic()
        result["lead_in_anchored_to"] = "confirmed playback advance"

    result["park_result"] = park_window(app_process_name)

    if args.player != "wam":
        # Parking resizes the window; confirm that did not stall the transport.
        ok2, detail2 = verify_advancing(args.player, timeout_s=20.0)
        result["liveness_after_park"] = detail2

    remaining = args.lead_in - (time.monotonic() - t_ref)
    if remaining > 0:
        time.sleep(remaining)

    # Re-park if the app moved its own window after we placed it.
    geom = window_geometry(app_process_name)
    if not geom.startswith(f"{PARK_POS[0]},{PARK_POS[1]},"):
        result["reparked"] = park_window(app_process_name, timeout_s=6.0)
        geom = window_geometry(app_process_name)
    result["window_geometry_at_window_start"] = geom

    pids0 = tree()
    result["tree_at_window_start"] = [{"pid": p, "command": proc_command(p)} for p in pids0]
    gpu0 = agx_gpu_time(pids0)
    fp_start = footprint(pids0)
    rows_before = read_metrics(metrics_path)
    t0_ns = rows_before[-1]["t_mono_ns"] if rows_before else None
    qt_pos0 = player_position(args.player)
    if args.player == "vlc":
        result["vlc_state_window_start"] = vlc_state()

    power_proc = subprocess.Popen(
        ["/usr/bin/top", "-l", str(int(args.window) + 1), "-s", "1",
         "-stats", "pid,command,power"] + [a for p in pids0 for a in ("-pid", str(p))],
        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)

    sampled = sample_loop(tree, args.window, cadence=1.0)
    result.update(sampled)

    pids1 = tree()
    gpu1 = agx_gpu_time(pids1)
    qt_pos1 = player_position(args.player)
    if args.player == "vlc":
        result["vlc_state_window_end"] = vlc_state()
    power_out, _ = power_proc.communicate(timeout=60)

    result["power"] = parse_top_output(power_out)
    result["footprint_window_start"] = fp_start
    result["footprint_window_end"] = footprint(pids1)
    wall = sampled["wall_seconds"]
    result["gpu"] = {
        "accumulated_units_start": gpu0,
        "accumulated_units_end": gpu1,
        "delta_units": (gpu1 - gpu0) if (gpu0 is not None and gpu1 is not None) else None,
        "delta_units_per_second": ((gpu1 - gpu0) / wall)
        if (gpu0 is not None and gpu1 is not None and wall) else None,
        "percent_of_device": gpu_percent_of_device(gpu1, gpu0, wall),
        "calibration_units_per_second_at_full_gpu": gpu_calibration(),
    }
    return t0_ns, qt_pos0, qt_pos1


def evaluate_health(args, result, metrics_path, telemetry_path, t0_ns,
                    qt_pos0, qt_pos1, wall):
    if args.player == "wam":
        rows = read_metrics(metrics_path)
        result["metrics_rows"] = len(rows)
        result["health"] = (
            summarize_playback(rows, t0_ns=t0_ns) if rows else {
                "status": "unknown",
                "reason": "no playback_sample rows: native path never drew "
                          "(fallback route, or no media)",
            }
        )
        try:
            result["telemetry_bytes"] = telemetry_path.stat().st_size
        except OSError:
            result["telemetry_bytes"] = 0
    else:
        adv = None
        with contextlib.suppress(TypeError, ValueError):
            adv = float(qt_pos1) - float(qt_pos0)
        # VLC reports whole seconds, so allow one quantisation second of slack.
        floor = 0.9 * wall - (1.0 if args.player == "vlc" else 0.0)
        result["health"] = {
            "position_start": qt_pos0, "position_end": qt_pos1,
            "advanced_seconds": adv,
            "expected_seconds": round(wall, 2),
            "status": "pass" if (adv is not None and adv >= floor) else "fail",
            "gate": f"position advanced >= {floor:.2f}s over a {wall:.1f}s window",
        }


def attribute_helpers(result):
    """Decide which sampled pids really belonged to the player.

    Run after teardown: a VTDecoderXPCService that survives the player it was
    supposedly decoding for was never the player's. Recomputes CPU and memory
    over the confirmed set so a stray helper cannot inflate the row.
    """
    tree = result.get("tree_at_window_start") or []
    player_pid = result.get("player_pid")
    survivors = set(pids_by_name(HELPER_BASENAME))
    confirmed, spurious = [], []
    for entry in tree:
        pid = entry["pid"]
        if pid == player_pid or pid not in survivors:
            confirmed.append(pid)
        else:
            spurious.append(pid)
    result["helper_attribution"] = {
        "confirmed_pids": confirmed,
        "spurious_pids": spurious,
        "rule": "a helper still alive after the player exited was not the player's",
    }
    if not spurious:
        return

    per_pid = result.get("cpu_seconds_per_pid") or {}
    wall = result.get("wall_seconds") or 0
    kept = sum(v for k, v in per_pid.items() if int(k) in confirmed)
    if wall > 0:
        result["cpu_mean_percent_raw"] = result.get("cpu_mean_percent")
        result["cpu_mean_percent"] = 100.0 * kept / wall

    for tag in ("footprint_window_start", "footprint_window_end"):
        fp = result.get(tag)
        if not fp or "processes" not in fp:
            continue
        procs = [p for p in fp["processes"] if p.get("pid") in confirmed]
        fp["phys_footprint_bytes_raw"] = fp.get("phys_footprint_bytes")
        fp["phys_footprint_bytes"] = sum(p.get("phys_footprint_bytes") or 0 for p in procs)
        fp["peak_phys_footprint_bytes_raw"] = fp.get("peak_phys_footprint_bytes")
        fp["peak_phys_footprint_bytes"] = sum(p.get("phys_footprint_peak_bytes") or 0 for p in procs)
        fp["excluded_processes"] = [
            {"pid": p.get("pid"), "name": p.get("name")}
            for p in fp["processes"] if p.get("pid") not in confirmed
        ]
        fp["processes"] = procs

    power = result.get("power") or {}
    means = power.get("per_pid_mean") or {}
    if means:
        power["tree_mean_raw"] = power.get("tree_mean")
        power["tree_mean"] = sum(v for k, v in means.items() if int(k) in confirmed)


def invalid_park(args, result):
    """An unparked window composites at whatever size the app chose, which is
    not comparable with the other rows, so it fails the trial outright."""
    if not args.require_park:
        return False
    if str(result.get("park_result", "")).startswith("parked"):
        return False
    result["status"] = "invalid"
    result["reason"] = f"window never parked: {result.get('park_result')}"
    teardown(args.player, result)
    Path(args.out).write_text(json.dumps(result, indent=2))
    print(f"INVALID: {result['reason']}")
    return True


def teardown(player, result):
    if player == "wam":
        # WAM_TEST_QUIT_AFTER_MS can be vetoed by the app's own quit guard, and
        # an orderly AppleScript quit is refused too (-128). The metrics JSONL
        # is flushed per line, so a SIGTERM costs nothing this report reads.
        deadline = time.monotonic() + 12
        while time.monotonic() < deadline and pids_matching("build/WAM.app/Contents/MacOS/WAM"):
            time.sleep(0.5)
        result["wam_self_quit"] = not pids_matching("build/WAM.app/Contents/MacOS/WAM")
        if not result["wam_self_quit"]:
            run(["osascript", "-e", 'tell application "WAM" to quit'])
            time.sleep(3)
        if pids_matching("build/WAM.app/Contents/MacOS/WAM"):
            run(["pkill", "-f", "WAM.app/Contents/MacOS/WAM"])
            time.sleep(2)
        result["wam_exited_cleanly"] = not pids_matching("build/WAM.app/Contents/MacOS/WAM")
    elif player == "vlc":
        run(["osascript", "-e", 'tell application "VLC" to quit'])
        time.sleep(3)
        run(["pkill", "-x", "VLC"])
    else:
        run(["osascript", "-e",
             'tell application "QuickTime Player" to close every document without saving'])
        run(["osascript", "-e", 'tell application "QuickTime Player" to quit'])
        time.sleep(3)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--player", required=True, choices=["wam", "vlc", "quicktime"])
    ap.add_argument("--clip", default=None)
    ap.add_argument("--label", required=True)
    ap.add_argument("--lead-in", type=float, default=10.0)
    ap.add_argument("--window", type=float, default=30.0)
    ap.add_argument("--out", required=True)
    ap.add_argument("--max-loadavg", type=float, default=4.0)
    ap.add_argument("--min-idle", type=float, default=80.0,
                    help="minimum whole-machine CPU idle %% required to start")
    ap.add_argument("--max-heavy", type=float, default=25.0,
                    help="abort if any single process exceeds this %%CPU")
    ap.add_argument("--require-park", action="store_true",
                    help="fail the trial if the window could not be parked")
    args = ap.parse_args()

    result = {
        "label": args.label,
        "player": args.player,
        "clip": args.clip,
        "lead_in_s": args.lead_in,
        "window_s": args.window,
        "started_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "park_geometry_requested": {"pos": PARK_POS, "size": PARK_SIZE},
    }

    guard_exit = check_guards(args, result)
    if guard_exit is not None:
        Path(args.out).write_text(json.dumps(result, indent=2))
        print(f"{result['status'].upper()}: {result['reason']}")
        return guard_exit

    helpers_before = set(pids_by_name(HELPER_BASENAME))
    result["vt_helpers_before"] = sorted(helpers_before)

    metrics_path = Path(tempfile.mkdtemp(prefix="wam-metrics-")) / "metrics.jsonl"
    telemetry_path = metrics_path.with_name("telemetry.jsonl")

    app_process_name = launch_player(args, result, metrics_path, telemetry_path)
    t_open = time.monotonic()

    target = resolve_pid(args.player)
    if target is None:
        result["status"] = "error"
        result["reason"] = "player process never appeared"
        Path(args.out).write_text(json.dumps(result, indent=2))
        return 1
    result["player_pid"] = target
    result["player_command"] = proc_command(target)

    if args.player == "quicktime":
        time.sleep(3.0)
        play = run(["osascript", "-e",
                    'tell application "QuickTime Player" to play document 1'])
        result["quicktime_play"] = {"stdout": play.stdout.strip(), "stderr": play.stderr.strip()}

    def tree():
        pids = {target}
        pids.update(children_of(target))
        # VT decoder helpers are reparented to launchd: attribute the ones that
        # appeared after our launch.
        for h in pids_by_name(HELPER_BASENAME):
            if h not in helpers_before:
                pids.add(h)
        if args.player == "quicktime":
            for p in pids_matching("com.apple.quicktime"):
                pids.add(p)
        return sorted(p for p in pids if p)

    t0_ns, qt_pos0, qt_pos1 = measure_window(
        args, result, tree, app_process_name, metrics_path, t_open)

    if invalid_park(args, result):
        return 4

    evaluate_health(args, result, metrics_path, telemetry_path, t0_ns,
                    qt_pos0, qt_pos1, result["wall_seconds"])
    teardown(args.player, result)

    attribute_helpers(result)

    result["metrics_path"] = str(metrics_path)
    result["status"] = "ok"
    Path(args.out).write_text(json.dumps(result, indent=2))
    print(json.dumps({k: result[k] for k in
                      ("label", "cpu_mean_percent", "cpu_max_percent", "health") if k in result}, indent=2))
    return 0


def parse_top_output(text):
    per_pid = {}
    block = 0
    header_seen = False
    for line in text.splitlines():
        s = line.strip()
        if s.startswith("PID") and "POWER" in s:
            block += 1
            header_seen = True
            continue
        if not header_seen or not s:
            continue
        toks = s.split()
        if len(toks) < 3 or not toks[0].isdigit():
            continue
        if block <= 1:
            continue
        try:
            power = float(toks[-1].rstrip("+-"))
        except ValueError:
            continue
        per_pid.setdefault(int(toks[0]), []).append(power)
    if not per_pid:
        return {"error": "no POWER rows parsed"}
    means = {p: sum(v) / len(v) for p, v in per_pid.items()}
    return {
        "per_pid_mean": means,
        "tree_mean": sum(means.values()),
        "samples_per_pid": {p: len(v) for p, v in per_pid.items()},
        "note": "POWER is Apple's unitless relative energy-impact score, not watts",
    }


if __name__ == "__main__":
    sys.exit(main())
