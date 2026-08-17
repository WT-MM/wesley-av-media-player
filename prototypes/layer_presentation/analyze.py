#!/usr/bin/env python3
"""Render the measured comparison table and the sub-experiment findings."""

import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
RESULTS = HERE / "results"
EXP = RESULTS / "experiments"


def load(p):
    try:
        return json.loads(Path(p).read_text())
    except (OSError, json.JSONDecodeError):
        return None


def contention():
    """Per-trial machine-quiet record, read from the per-trial JSONs.

    House rule (docs/AGENT_PERFORMANCE_PRINCIPLES.md): measure on a quiet
    machine. This box runs a 100%-full disk that keeps the iCloud/FileProvider
    stack burning real cores, so every CPU number here has to be read next to
    its contention row.
    """
    print("\n== machine quiet record (CPU% numbers are only as good as these) ==")
    hdr = f"{'trial':<24}{'idle%_before':>14}{'idle%_after':>13}{'flagged':>9}  heaviest_after"
    print(hdr)
    print("-" * (len(hdr) + 20))
    for p in sorted(RESULTS.glob("*-[0-9].json")):
        d = load(p)
        if not d or "quiet_before" in d and d.get("quiet_before") is None:
            continue
        qb = (d.get("quiet_before") or {})
        qa = (d.get("quiet_after") or {})
        heavy = qa.get("heaviest_process") or ["", ""]
        name = str(heavy[1]).split("/")[-1] if len(heavy) > 1 else ""
        print(f"{p.stem:<24}{str(qb.get('cpu_idle_percent')):>14}"
              f"{str(qa.get('cpu_idle_percent')):>13}"
              f"{str(d.get('machine_contended')):>9}  {heavy[0]}% {name}")


def table():
    s = load(RESULTS / "summary.json")
    if not s:
        print("no summary.json")
        return
    hdr = (f"{'mode':<20}{'run':>4}{'CPU%':>8}{'GPU%':>7}{'phys MB':>9}"
           f"{'gfxMB':>7}{'AGX':>5}{'disp/exp':>12}{'fps':>7}{'inflt':>6}{'valid':>7}")
    print(hdr)
    print("-" * len(hdr))
    for r in s["rows"]:
        d = r.get("frames_proven_displayed")
        e = r.get("frames_expected")
        ratio = f"{d}/{int(e)}" if d is not None and e else "-"
        infl = (r.get("inflight_depth") or {}).get("max")
        cpu = r.get("cpu_percent_of_one_core")
        gpu = r.get("gpu_percent_of_device")
        fps = r.get("effective_display_fps")
        print(f"{r['mode']:<20}{r['run']:>4}"
              f"{(f'{cpu:.2f}' if cpu is not None else '-'):>8}"
              f"{(f'{gpu:.2f}' if gpu is not None else '-'):>7}"
              f"{r.get('phys_footprint_mb', 0):>9.1f}"
              f"{r.get('graphics_categories_mb', 0):>7.2f}"
              f"{str(r.get('agx_client_count_end')):>5}"
              f"{ratio:>12}"
              f"{(f'{fps:.2f}' if fps is not None else '-'):>7}"
              f"{str(infl):>6}"
              f"{str(r.get('valid')):>7}")
    print()
    for r in s["rows"]:
        if r.get("contended"):
            print(f"  CONTENDED: {r['mode']} run {r['run']}")
        if r.get("optimized_compositing") is not None:
            print(f"  {r['mode']} run {r['run']}: optimizedCompositing="
                  f"{r['optimized_compositing']} dropped={r.get('dropped_frames')}")


def paused():
    d = load(EXP / "pausedproof.json")
    if not d:
        return
    print("\n== copyDisplayedPixelBuffer paused attestation ==")
    n = d.get("paused_probe_count")
    print(f"probes={n} nonnull={d.get('paused_probe_nonnull')} "
          f"covers={d.get('paused_probe_covers_position')} "
          f"nonnull_while_playing={d.get('paused_probe_nonnull_while_playing')}")
    print(f"delay_ms={d.get('paused_probe_delay_ms')}")
    misses = [p for p in d.get("paused_probes", []) if not p["covers"]]
    print(f"misses: {len(misses)}")
    for p in misses:
        exp_pts = p["matched_pts"]
        delta_frames = (p["pause_timeline_s"] - exp_pts) / (p["matched_dur"] or (1 / 30))
        print(f"  target={p['pause_timeline_s']:.4f} expected_idx={p['expected_index']} "
              f"expected_pts={exp_pts:.4f} dur={p['matched_dur']:.4f} "
              f"got_surface={p['surface_id']} expected_surface={p['expected_surface_id']} "
              f"phase_into_frame={delta_frames:.3f}")


def feed_lead():
    print("\n== BufferConsumed ack lead vs feed depth ==")
    for tag in ("feed-greedy", "feed-jit50", "feed-jit400"):
        d = load(EXP / f"{tag}.json")
        if not d:
            continue
        print(f"{tag:<14} lead={d.get('jit_lead_s')} "
              f"ack_vs_display_ms={d['proof_latency_vs_inferred_display_ms']['median']:.1f} "
              f"ack_vs_enqueue_ms={d['proof_latency_vs_enqueue_ms']['median']:.1f} "
              f"inflight_max={d['inflight_depth']['max']} "
              f"first_fill={d.get('first_fill_count')} "
              f"notifiers={d.get('consumed_notifier_classes')}")
        if d.get("surface_use_count", {}).get("n"):
            print(f"{'':<14} IOSurfaceGetUseCount {d['surface_use_count']}")


def others():
    d = load(EXP / "flush.json")
    if d:
        print("\n== flush ==")
        print(f"flush_ran={d.get('flush_ran')} inflight_at_flush={d.get('inflight_at_flush')} "
              f"consumed_after_flush={d.get('consumed_after_flush')} "
              f"enqueued={d.get('frames_enqueued')} acked={d.get('consumed_distinct_frames')} "
              f"requires_flush_events={d.get('requires_flush_events')}")
        print("  events:", [e["what"] for e in d.get("events", [])][:12])
    d = load(EXP / "occlusion.json")
    if d:
        print("\n== occlusion ==")
        print(f"test_ran={d.get('occlusion_test_ran')} "
              f"occluded_samples={d.get('occluded_samples')} "
              f"enqueued_while_occluded={d.get('enqueued_while_occluded')} "
              f"consumed_while_occluded={d.get('consumed_while_occluded')} "
              f"dropped={d.get('video_performance_metrics_last', {}).get('numberOfDroppedFrames')}")
    d = load(EXP / "overlay.json")
    if d:
        print("\n== translucent overlay vs optimized compositing ==")
        at = d.get("overlay_at_elapsed_s")
        print(f"overlay raised at elapsed={at}")
        series = d.get("metrics_series", [])
        before = [s for s in series if s["elapsed_s"] < at]
        after = [s for s in series if s["elapsed_s"] >= at + 1]
        for label, seg in (("before", before), ("after", after)):
            if len(seg) >= 2:
                dt = seg[-1]["elapsed_s"] - seg[0]["elapsed_s"]
                dopt = seg[-1]["optimized"] - seg[0]["optimized"]
                dtot = seg[-1]["total"] - seg[0]["total"]
                print(f"  {label:<7} dt={dt:.1f}s total+={dtot} optimized+={dopt} "
                      f"({100.0*dopt/dtot if dtot else 0:.1f}% of frames)")
    d = load(EXP / "hevc.json")
    if d:
        print("\n== HEVC cross-check ==")
        print(f"enqueued={d.get('frames_enqueued')} displayed={d.get('frames_proven_displayed')} "
              f"fps={d.get('effective_display_fps'):.2f} valid={d.get('valid')} "
              f"optimized={d.get('video_performance_metrics_last', {}).get('numberOfFramesDisplayedUsingOptimizedCompositing')}")


if __name__ == "__main__":
    table()
    contention()
    paused()
    feed_lead()
    others()
