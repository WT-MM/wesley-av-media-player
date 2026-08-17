#!/bin/sh
cd "$(dirname "$0")"
CLIP=/Users/wesleymaa/Documents/WAM/.cache/benchmarks/media/adhoc-native-1080p/h264-high.mp4
OUT=results/experiments
mkdir -p "$OUT"

# Give the structural matrix a bounded chance to finish, then stop it.
i=0
while [ $i -lt 30 ] && [ ! -f results/structural/summary.json ]; do sleep 5; i=$((i+1)); done
pkill -f "outdir structural" 2>/dev/null
sleep 1
pkill -x layerproto 2>/dev/null
sleep 1

# Ad-hoc sign: taskgated SIGKILLed the unsigned binary twice mid-trial
# ("Code Signature Invalid"), which is what killed the asbdl-compressed run.
codesign -f -s - layerproto 2>&1 | head -2

echo "== overlay =="
./layerproto --mode=asbdl-decoded --clip="$CLIP" --duration=40 --overlay-at=20 \
  --out="$OUT/overlay.json" >/dev/null 2>&1; echo "  rc=$?"

echo "== flush =="
./layerproto --mode=asbdl-decoded --clip="$CLIP" --duration=30 --flush-at=15 \
  --out="$OUT/flush.json" >/dev/null 2>&1; echo "  rc=$?"

echo "== occlusion =="
./layerproto --mode=asbdl-decoded --clip="$CLIP" --duration=40 \
  --occlude-after=12 --occlude-for=15 --out="$OUT/occlusion.json" >/dev/null 2>&1; echo "  rc=$?"

echo "== pausedproof 30 =="
./layerproto --mode=asbdl-pausedproof --clip="$CLIP" --duration=50 --probes=30 \
  --out="$OUT/pausedproof.json" >/dev/null 2>&1; echo "  rc=$?"

echo "== feed greedy =="
./layerproto --mode=asbdl-decoded --clip="$CLIP" --duration=25 --feed=greedy --surface-probe=4 \
  --out="$OUT/feed-greedy.json" >/dev/null 2>&1; echo "  rc=$?"

echo "== feed jit 50ms =="
./layerproto --mode=asbdl-decoded --clip="$CLIP" --duration=25 --feed=jit --jit-lead=0.05 \
  --out="$OUT/feed-jit50.json" >/dev/null 2>&1; echo "  rc=$?"

echo "== asbdl-compressed retry =="
./layerproto --mode=asbdl-compressed --clip="$CLIP" --duration=25 \
  --out="$OUT/compressed.json" >/dev/null 2>&1; echo "  rc=$?"

echo "ENDGAME DONE"
