#!/usr/bin/env python3
"""Quiet, identity-bound replays of the build app; controls only child PIDs."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import time


def sha(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--seconds', type=float, default=8)
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[1]
    app = (repo / 'build/WAM.app/Contents/MacOS/WAM').resolve()
    assets = sorted(Path('/Users/wesleymaa/Movies/RustDesk').rglob('*.mp4'))
    assert len(assets) == 6, f'Expected six RustDesk recordings, found {len(assets)}'
    assets.append(Path('/Users/wesleymaa/Downloads/appleads.mp4'))
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    candidate = sha(app)
    results = []
    for number, asset in enumerate(assets):
        run = output / str(number)
        run.mkdir(exist_ok=True)
        (run / 'home').mkdir(exist_ok=True)
        metrics_path = run / 'metrics.jsonl'
        if metrics_path.exists():
            raise RuntimeError('Use a fresh output directory for each campaign')
        env = {k: v for k, v in os.environ.items() if not k.startswith('WAM_')}
        run_id = subprocess.check_output(['uuidgen'], text=True).strip().lower()
        env.update(HOME=str(run / 'home'), WAM_NATIVE_BENCHMARK_TELEMETRY='1',
                   WAM_NATIVE_BENCHMARK_RUN_ID=run_id,
                   WAM_NATIVE_BENCHMARK_ASSET_SHA256=sha(asset),
                   WAM_NATIVE_BENCHMARK_CANDIDATE_ID=candidate,
                   WAM_TEST_BACKGROUND='1', WAM_TEST_MUTED='1',
                   WAM_TEST_GEOMETRY='480x270+2400+1000',
                   WAM_TEST_QUIT_AFTER_MS=str(int(args.seconds * 1000)),
                   WAM_PLAYBACK_METRICS_PATH=str(metrics_path))
        start = time.monotonic()
        with (run / 'log.txt').open('w') as log:
            process = subprocess.Popen([str(app), str(asset)], env=env, stdout=log, stderr=log)
            try:
                rc = process.wait(timeout=args.seconds + 20)
            except subprocess.TimeoutExpired:
                process.terminate()
                try:
                    rc = process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    rc = process.wait()
        text = (run / 'log.txt').read_text()
        metrics = [json.loads(line) for line in metrics_path.read_text().splitlines()] if metrics_path.exists() else []
        drawn = max((row.get('drawn_frames') or 0 for row in metrics), default=0)
        rates = [row.get('clock_rate') for row in metrics if row.get('clock_rate') is not None and not row.get('paused')]
        result = dict(asset=str(asset), candidate_sha256=candidate,
                      asset_sha256=env['WAM_NATIVE_BENCHMARK_ASSET_SHA256'], run_id=run_id,
                      pid=process.pid, rc=rc, seconds=time.monotonic() - start,
                      native='native_selected' in text and 'fallback_selected' not in text and 'WAM: native failure' not in text,
                      first_frame_drawn='first_frame_drawn' in text, drawn_frames=drawn, clock_rates=rates)
        result['passed'] = rc == 0 and result['native'] and result['first_frame_drawn'] and drawn > 0 and bool(rates) and all(format(rate, '.4f') == '1.0000' for rate in rates)
        assert sha(app) == candidate and sha(asset) == result['asset_sha256']
        (run / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
        results.append(result)
        (output / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
        print(json.dumps(result), flush=True)
    raise SystemExit(0 if all(result['passed'] for result in results) else 1)


if __name__ == '__main__':
    main()
