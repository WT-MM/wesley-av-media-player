"""Quiet, identity-bound measurements of this clone's build app only."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import time
import uuid

REPO = Path(__file__).resolve().parents[1]
SCRATCH = Path('/private/tmp/wam-late-scratch')
APP = REPO / 'build/WAM.app/Contents/MacOS/WAM'


def sha(path):
    with open(path, 'rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def snapshot():
    result = subprocess.run(['ps', '-axo', 'pid=,ppid=,%cpu=,lstart=,comm='],
                            capture_output=True, text=True, check=True)
    all_rows = [line.strip() for line in result.stdout.splitlines()]
    rows = [line for line in all_rows
            if '.app/Contents/MacOS/WAM' in line]
    busiest = sorted(all_rows, key=lambda line: float(line.split()[2]), reverse=True)[:8]
    return dict(host_ns=time.monotonic_ns(), processes=rows, busiest_processes=busiest)


def trial(rows, output, seconds=None, require_quiet=True, quiet_seconds=0, sampler=None):
    output.mkdir(parents=True, exist_ok=False)
    before = snapshot()
    (output / 'ps-before.json').write_text(json.dumps(before, indent=2))
    if before['processes'] and require_quiet:
        (output / 'blocked.json').write_text(json.dumps(before, indent=2))
        print('BLOCKED: another WAM GUI is running', flush=True)
        return False
    if require_quiet and quiet_seconds:
        until = time.monotonic() + quiet_seconds
        with (output / 'ps-preflight.jsonl').open('w') as preflight:
            while time.monotonic() < until:
                state = snapshot()
                preflight.write(json.dumps(state) + '\n')
                preflight.flush()
                if state['processes']:
                    (output / 'blocked.json').write_text(json.dumps(state, indent=2))
                    print('BLOCKED: GUI appeared during quiet preflight', flush=True)
                    return False
                time.sleep(0.25)
    candidate = sha(APP)
    children = []
    samplers = {}
    try:
        launch_rows(rows, output, seconds, sampler, candidate, children, samplers)
        overlaps = monitor_children(children, output, require_quiet)
        return collect_results(children, samplers, output, overlaps, candidate, seconds, sampler)
    finally:
        for sample_process, usage in samplers.values():
            if sample_process.poll() is None:
                sample_process.terminate()
                sample_process.wait(timeout=5)
            usage.close()
        for child, log, home, *_ in children:
            if child.poll() is None:
                child.terminate()
                try:
                    child.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    child.kill()
                    child.wait()
            log.close()
            shutil.rmtree(home)


def launch_rows(rows, output, seconds, sampler, candidate, children, samplers):
    for index, row in enumerate(rows):
        asset = Path(row['path'])
        run = output / str(index)
        run.mkdir()
        home = SCRATCH / ('home-' + str(uuid.uuid4()))
        home.mkdir()
        duration = seconds or (float(subprocess.check_output([
            'ffprobe', '-v', 'error', '-show_entries', 'format=duration',
            '-of', 'default=nw=1:nk=1', str(asset)], text=True)) + 8)
        env = os.environ.copy()
        for key in list(env):
            if key.startswith('WAM_'):
                del env[key]
        env.update(HOME=str(home), WAM_NATIVE_BENCHMARK_TELEMETRY='1',
            WAM_NATIVE_BENCHMARK_RUN_ID=subprocess.check_output(['uuidgen'], text=True).strip().lower(),
            WAM_NATIVE_BENCHMARK_ASSET_SHA256=sha(asset),
            WAM_NATIVE_BENCHMARK_CANDIDATE_ID=candidate,
            WAM_TEST_BACKGROUND='1', WAM_TEST_MUTED='1',
            WAM_TEST_GEOMETRY='480x270+2400+1000',
            WAM_PLAYBACK_METRICS_PATH=str(run / 'metrics.jsonl'),
            WAM_PLAYBACK_METRICS_INTERVAL_MS='1000' if sampler else '100',
            WAM_TEST_QUIT_AFTER_MS=str(int(duration * 1000)))
        if row.get('no_hardware'):
            env['WAM_TEST_NO_VIDEO_HARDWARE'] = '1'
        log = (run / 'log.txt').open('w')
        child = subprocess.Popen([str(APP), str(asset)], env=env, stdout=log, stderr=log)
        receipt = dict(asset=str(asset), expected_frames=row.get('frames'),
            pid=child.pid, identities={k: v for k, v in env.items() if k.startswith('WAM_') or k == 'HOME'},
            timeout_seconds=duration + 30)
        children.append((child, log, home, run, receipt, time.monotonic()))
        if sampler:
            usage = (run / 'usage.json').open('w')
            sample_process = subprocess.Popen([str(sampler), str(child.pid)], stdout=usage)
            samplers[child.pid] = (sample_process, usage)
            receipt['sampler_sha256'] = sha(sampler)
        (run / 'launch.json').write_text(json.dumps(receipt, indent=2))


def stop_owned(children):
    for child, *_ in children:
        if child.poll() is None:
            child.terminate()


def monitor_children(children, output, require_quiet):
    own = {child.pid for child, *_ in children}
    overlaps = []
    with (output / 'ps-during.jsonl').open('w') as pslog:
        while any(c.poll() is None for c, *_ in children):
            state = snapshot()
            pslog.write(json.dumps(state) + '\n')
            pslog.flush()
            other = [line for line in state['processes'] if int(line.split()[0]) not in own]
            if other:
                overlaps.append(dict(host_ns=state['host_ns'], processes=other))
                if require_quiet:
                    stop_owned(children)
                    print('Aborted owned trial: sibling GUI overlap', flush=True)
            for child, _, _, _, receipt, start in children:
                if child.poll() is None and time.monotonic() - start > receipt['timeout_seconds']:
                    child.terminate()
            time.sleep(0.25)
    return overlaps


def collect_results(children, samplers, output, overlaps, candidate, seconds, sampler):
    results = []
    for child, log, home, run, receipt, start in children:
        receipt['rc'] = child.wait()
        log.close()
        if child.pid in samplers:
            sample_process, usage = samplers[child.pid]
            receipt['sampler_rc'] = sample_process.wait(timeout=5)
            usage.close()
            try:
                receipt['usage'] = json.loads((run / 'usage.json').read_text())
            except json.JSONDecodeError as error:
                receipt['usage_error'] = str(error)
        metrics = []
        receipt['metrics_parse_errors'] = 0
        if (run / 'metrics.jsonl').exists():
            for line in (run / 'metrics.jsonl').read_text().splitlines():
                try:
                    metrics.append(json.loads(line))
                except json.JSONDecodeError:
                    receipt['metrics_parse_errors'] += 1
        samples = [r for r in metrics if r.get('record') == 'playback_sample' and r.get('drawn_frames') is not None]
        traces = [r for r in metrics if r.get('record') == 'video_frame_trace']
        receipt.update(last_sample=samples[-1] if samples else None,
            late=[r for r in traces if r['late']], trace_count=len(traces),
            quiet=not overlaps, overlap=overlaps,
            trace_losses=max((r['lost_or_unavailable'] for r in metrics if r.get('record') == 'video_trace_health'), default=None),
            elapsed_seconds=time.monotonic() - start)
        logtext = (run / 'log.txt').read_text()
        receipt['native'] = 'native_selected' in logtext and 'first_frame_drawn' in logtext and 'WAM: native failure' not in logtext
        receipt['candidate_unchanged'] = sha(APP) == candidate
        last = receipt['last_sample'] or {}
        receipt['complete_accounting'] = receipt['expected_frames'] is not None and sum(last.get(k) or 0 for k in ['drawn_frames', 'discarded_late_frames', 'superseded_frames']) == receipt['expected_frames']
        (run / 'result.json').write_text(json.dumps(receipt, indent=2))
        results.append(receipt)
        print(run.name, receipt['rc'], receipt['quiet'], receipt['last_sample'], flush=True)
    (output / 'results.json').write_text(json.dumps(results, indent=2))
    return not overlaps and all(r['rc'] == 0 and r['native'] and r['candidate_unchanged'] and
        not r['metrics_parse_errors'] and (not sampler or 'usage' in r) and
        (r['complete_accounting'] if seconds is None or sampler else True) for r in results)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--mode', choices=['soak', 'mixed', 'replay', 'resources'], required=True)
    parser.add_argument('--repeats', type=int, default=1)
    parser.add_argument('--max-attempts', type=int, default=12)
    parser.add_argument('--quiet-seconds', type=float, default=30)
    parser.add_argument('--sampler', type=Path)
    args = parser.parse_args()
    if args.mode == 'resources':
        if args.sampler is None:
            parser.error('--sampler is required for resources')
        index = 0
        completed = 0
        for mode in ['normal', 'no-hardware']:
            baseline = json.loads((REPO / f'docs/native-coverage/phase2f/measure-shipped-final-{mode}.json').read_text())
            for original in baseline:
                if (original.get('last_sample') or {}).get('drawn_frames') != 300:
                    continue
                row = dict(path=original['asset'], frames=300, no_hardware=mode == 'no-hardware')
                if sha(row['path']) != original['asset_sha256']:
                    raise ValueError('resource asset identity changed')
                for attempt in range(args.max_attempts):
                    if trial([row], args.output.resolve() / str(index) / str(attempt), 14,
                             quiet_seconds=args.quiet_seconds, sampler=args.sampler):
                        completed += 1
                        break
                    time.sleep(15)
                index += 1
        print(f'GUI-quiet completed resource rows: {completed}/{index}', flush=True)
        raise SystemExit(0 if completed == index else 2)
    rows = json.loads((REPO / 'docs/native-coverage/phase3/rustdesk-full-decode.json').read_text())
    for row in rows:
        row['frames'] = int(row['stdout'].split('frames=')[1].split()[0])
    if args.mode == 'mixed':
        rows = [dict(path='/private/tmp/wam-phase2e/rustdesk-audio-celt/0-opus.mkv', frames=987)]
    elif args.mode == 'replay':
        rows += [dict(path='/Users/wesleymaa/Downloads/appleads.mp4')]
    completed = 0
    for attempt in range(args.max_attempts):
        quiet = trial(rows, args.output.resolve() / str(attempt), 8 if args.mode == 'replay' else None, require_quiet=args.mode != 'replay', quiet_seconds=args.quiet_seconds)
        if quiet:
            completed += 1
            if completed == args.repeats:
                break
        else:
            time.sleep(15)
    print(f'GUI-quiet completed trials: {completed}/{args.repeats}', flush=True)
    raise SystemExit(0 if completed == args.repeats else 2)
