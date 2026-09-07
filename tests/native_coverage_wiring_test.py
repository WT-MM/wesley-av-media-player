"""Measured production-app wiring proofs, including actual owner notices."""
import argparse
import contextlib
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import uuid


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def records(text):
    result = []
    for line in text.splitlines():
        # Non-record lines (no brace, or a brace inside prose) are expected in
        # the interleaved stderr stream and carry no data.
        with contextlib.suppress(ValueError, json.JSONDecodeError):
            result.append(json.loads(line[line.index('{'):]))
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--app', required=True)
    parser.add_argument('--ffmpeg', required=True)
    parser.add_argument('--artifacts')
    parser.add_argument('--slow-fixture')
    parser.add_argument('--case', default='all')
    a = parser.parse_args()
    app = Path(a.app).resolve()
    assert app.parts[-4:] == ('WAM.app', 'Contents', 'MacOS', 'WAM')
    assert app.parent.parent.parent.parent.name == 'build'
    temporary = tempfile.TemporaryDirectory(prefix='wam-wiring-', dir='/private/tmp')
    root = Path(a.artifacts or temporary.name)
    root.mkdir(parents=True, exist_ok=True)
    candidate = sha(app)
    manifest = dict(executable=str(app), executable_sha256=candidate, recipes=[], runs=[])

    def ffmpeg(name, args):
        path = root/name
        argv = [a.ffmpeg, '-v', 'error', '-nostdin', '-y', *map(str,args), str(path)]
        subprocess.run(argv, check=True, capture_output=True)
        manifest['recipes'].append(dict(argv=argv, asset_sha256=sha(path)))
        return path

    def launch(path, name, milliseconds=4500, extra=None):
        run_id = str(uuid.uuid4())
        run = root/(name+'-'+run_id)
        run.mkdir(parents=True, exist_ok=True)
        (run/'home').mkdir(exist_ok=True)
        env = {k:v for k,v in os.environ.items() if not k.startswith('WAM_')}
        env.update(HOME=str(run/'home'), WAM_NATIVE_BENCHMARK_TELEMETRY='1',
                   WAM_NATIVE_BENCHMARK_RUN_ID=run_id,
                   WAM_NATIVE_BENCHMARK_ASSET_SHA256=sha(path),
                   WAM_NATIVE_BENCHMARK_CANDIDATE_ID=candidate,
                   WAM_TEST_BACKGROUND='1', WAM_TEST_MUTED='1',
                   WAM_TEST_GEOMETRY='480x270+2400+1000',
                   WAM_TEST_QUIT_AFTER_MS=str(milliseconds), WAM_TEST_NOTICE_TRACE='1',
                   WAM_PLAYBACK_METRICS_PATH=str(run/'metrics.jsonl'))
        env.update(extra or {})
        with (run/'stdout.log').open('w') as out, (run/'stderr.log').open('w') as err:
            proc = subprocess.Popen([str(app),str(path)], env=env, stdout=out, stderr=err)
            receipt = dict(name=name,argv=[str(app),str(path)],pid=proc.pid,
                           executable_sha256=candidate,
                           env={k:v for k,v in env.items() if k.startswith('WAM_') or k=='HOME'})
            (run/'launch.json').write_text(json.dumps(receipt,indent=2)+'\n')
            try:
                rc = proc.wait(timeout=milliseconds/1000+15)
            except subprocess.TimeoutExpired:
                proc.terminate()
                try:
                    proc.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    proc.wait()
                raise AssertionError(f'{name}: orderly quit timed out, PID {proc.pid}')
        text = (run/'stderr.log').read_text()+(run/'stdout.log').read_text()
        assert rc == 0, (name,rc,text)
        assert sha(app) == candidate, 'executable changed during proof'
        events = records(text)
        notices = [x for x in events if x.get('record')=='notice_state']
        assert notices, 'production notice trace missing'
        metrics = records((run/'metrics.jsonl').read_text()) if (run/'metrics.jsonl').exists() else []
        receipt.update(rc=rc,notices=notices,events=events,
                       rendered_frames=max(((x.get('audio_rendered_frames') or 0) for x in metrics),default=0))
        manifest['runs'].append(receipt)
        (root/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
        return text,receipt

    if a.case in ('all','notice'):
        path=ffmpeg('mjpeg422.mov',['-f','lavfi','-i','testsrc2=size=320x180:rate=24',
                    '-t','1','-c:v','mjpeg','-pix_fmt','yuvj422p','-threads','1'])
        text,receipt=launch(path,'notice')
        assert 'Motion JPEG chroma' in text and 'fallback_selected' in text, text
        assert all(not x['notice'] for x in receipt['notices']), receipt['notices']
        assert all(not x['error'] or x['error'].startswith('cannot load bundled fallback:')
                   for x in receipt['notices']), receipt['notices']
        print('PASS: actual native admission route publishes no owner notice',flush=True)
    if a.case in ('all','retry'):
        bad=ffmpeg('ima64.mka',['-f','lavfi','-i','sine=frequency=997:sample_rate=48000',
                   '-t','2','-ac','2','-c:a','adpcm_ima_wav','-block_size','64','-threads','1'])
        good=ffmpeg('pcm441.mka',['-f','lavfi','-i','sine=frequency=997:sample_rate=44100',
                    '-t','2','-c:a','pcm_s16le','-threads','1'])
        path=ffmpeg('retry-three.mka',['-i',bad,'-i',bad,'-i',good,'-map','0:a','-map','1:a',
                    '-map','2:a','-c','copy','-disposition:a:0','default',
                    '-disposition:a:1','0','-disposition:a:2','0'])
        text,receipt=launch(path,'retry')
        assert 'prepared' in text and 'native_selected' in text and 'fallback_selected' not in text, text
        assert 'WAM: native failure' not in text and receipt['rendered_frames']==88200, receipt
        print('PASS: two refused decoder graphs retire; third track renders 88200 frames',flush=True)
    if a.case in ('all','progress'):
        path=Path(a.slow_fixture) if a.slow_fixture else ffmpeg('slow.mp4',[
            '-f','lavfi','-i','color=c=steelblue:size=3840x2160:rate=24','-t','40',
            '-c:v','libx264','-preset','ultrafast','-g','960','-keyint_min','960',
            '-sc_threshold','0','-bf','0','-threads','4'])
        text,receipt=launch(path,'progress',8500,{'WAM_TEST_SEEK_SCRIPT':'30@1'})
        assert 'commit_ready' in text and 'fallback_selected' not in text and 'WAM: native failure' not in text, text
        assert any(x['notice'].startswith('Seeking: decoded ') for x in receipt['notices']), receipt['notices']
        assert any(x.get('event')=='commit_ready' and x.get('target_seconds')==30
                   for x in receipt['events']), receipt['events']
        print('PASS: real slow seek publishes owner progress and exact target readiness',flush=True)


if __name__ == '__main__':
    main()
