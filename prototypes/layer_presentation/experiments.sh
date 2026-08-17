#!/bin/sh
# Focused ASBDL display-proof / integration sub-experiments.
#
# These are diagnostic runs, NOT resource measurements -- several of them
# deliberately occlude the window or retain extra surfaces, which would
# invalidate a cost trial. Run them only when harness.py is NOT running.
set -e
cd "$(dirname "$0")"
CLIP=/Users/wesleymaa/Documents/WAM/.cache/benchmarks/media/adhoc-native-1080p/h264-high.mp4
OUT=results/experiments
mkdir -p "$OUT"

echo "== 1. paused-attestation, 30 probes at varied intra-frame phases =="
./layerproto --mode=asbdl-pausedproof --clip="$CLIP" --duration=50 --probes=30 \
  --out="$OUT/pausedproof.json" > /dev/null

echo "== 2. greedy feed (baseline for ack lead + retention) =="
./layerproto --mode=asbdl-decoded --clip="$CLIP" --duration=30 --feed=greedy \
  --surface-probe=4 --out="$OUT/feed-greedy.json" --proof-log="$OUT/feed-greedy.tsv" > /dev/null

echo "== 3. just-in-time feed, 50 ms lead: does the ack lead track feed depth? =="
./layerproto --mode=asbdl-decoded --clip="$CLIP" --duration=30 --feed=jit --jit-lead=0.05 \
  --out="$OUT/feed-jit50.json" --proof-log="$OUT/feed-jit50.tsv" > /dev/null

echo "== 4. just-in-time feed, 400 ms lead =="
./layerproto --mode=asbdl-decoded --clip="$CLIP" --duration=30 --feed=jit --jit-lead=0.40 \
  --out="$OUT/feed-jit400.json" --proof-log="$OUT/feed-jit400.tsv" > /dev/null

echo "== 5. flush: does BufferConsumed fire for DISCARDED frames? =="
./layerproto --mode=asbdl-decoded --clip="$CLIP" --duration=30 --flush-at=15 \
  --out="$OUT/flush.json" > /dev/null

echo "== 6. occlusion: does the layer keep consuming when covered? =="
./layerproto --mode=asbdl-decoded --clip="$CLIP" --duration=40 \
  --occlude-after=12 --occlude-for=15 --out="$OUT/occlusion.json" > /dev/null

echo "== 7. translucent chrome overlay vs optimized compositing =="
./layerproto --mode=asbdl-decoded --clip="$CLIP" --duration=40 --overlay-at=20 \
  --out="$OUT/overlay.json" > /dev/null

echo "== 8. HEVC cross-check =="
./layerproto --mode=asbdl-decoded \
  --clip=/Users/wesleymaa/Documents/WAM/.cache/benchmarks/media/adhoc-native-1080p/hevc-main.mp4 \
  --duration=25 --out="$OUT/hevc.json" > /dev/null

echo "all experiments written to $OUT"
