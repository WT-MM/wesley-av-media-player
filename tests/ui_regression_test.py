#!/usr/bin/env python3
"""Quiet, synthetic-only UI checks. Never activates a window or controls other PIDs."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import uuid

p = argparse.ArgumentParser()
p.add_argument('--app', required=True, type=Path)
p.add_argument('--ffmpeg', required=True)
p.add_argument('--case', required=True)
p.add_argument('--output', type=Path)
p.add_argument('--record-only', action='store_true')
a = p.parse_args()
root = a.output or Path(tempfile.mkdtemp(prefix='wam-ui-regression-'))
root.mkdir(parents=True, exist_ok=True)
media = root / 'fixture.mp4'
fallback = root / 'fallback.wmv'
# Silent video: even the mute/unmute tests cannot produce sound.
subprocess.run([a.ffmpeg, '-v', 'error', '-y', '-f', 'lavfi', '-i',
                'testsrc2=size=320x180:rate=30', '-t', '20', '-an',
                '-c:v', 'libx264', '-preset', 'ultrafast', '-g', '240', str(media)], check=True)
subprocess.run([a.ffmpeg, '-v', 'error', '-y', '-i', str(media), '-an',
                '-c:v', 'wmv2', str(fallback)], check=True)
(root / 'last.mp4').write_bytes(media.read_bytes())
(root / 'garbage.mp4').write_bytes(b'not a media container\x00' * 100)
(root / 'truncated.mp4').write_bytes(media.read_bytes()[:10000])
(root / 'cue.srt').write_text('1\n00:00:00,000 --> 00:00:19,900\nA subtitle near the bottom\n')

def run(name, source, script, ms=6500, **extra):
    out = root / name
    out.mkdir(exist_ok=True)
    home = out / ('home-' + uuid.uuid4().hex)
    home.mkdir(exist_ok=True)
    env = dict(os.environ, HOME=str(home), WAM_TEST_BACKGROUND='1', WAM_TEST_MUTED='1',
               WAM_TEST_GEOMETRY='480x270+2400+1000', WAM_TEST_QUIT_AFTER_MS=str(ms),
               WAM_TEST_WINDOW_SCRIPT=script, WAM_TEST_NOTICE_TRACE='1',
               WAM_NATIVE_BENCHMARK_TELEMETRY='1', WAM_NATIVE_BENCHMARK_RUN_ID=str(uuid.uuid4()),
               WAM_NATIVE_BENCHMARK_ASSET_SHA256='0'*64, WAM_NATIVE_BENCHMARK_CANDIDATE_ID='1'*64,
               WAM_PLAYBACK_METRICS_PATH=str(out/'samples.jsonl'), WAM_PLAYBACK_METRICS_INTERVAL_MS='100')
    env.update(extra)
    # Cocoa is required for native menus; no window is activated.
    env['QT_QPA_PLATFORM'] = 'cocoa'
    with (out/'stderr.log').open('w') as log:
        child = subprocess.Popen([str(a.app.resolve()), str(source)], env=env, stdout=log, stderr=log)
        try:
            rc = child.wait(timeout=ms/1000 + 20)
        except subprocess.TimeoutExpired:
            child.kill()
            child.wait()
            raise AssertionError('Own child timed out; log: ' + str(out))
    (out/'receipt.json').write_text(json.dumps(dict(pid=child.pid, returncode=rc, script=script, source=str(source)), indent=2))
    log = (out/'stderr.log').read_text()
    assert rc == 0, (rc, str(out), log[-2000:])
    rows = [dict(re.findall(r'(\w+)=([^ ]+)', line)) for line in log.splitlines()
            if line.startswith('WAM_TEST_WINDOW idx=')]
    samples = [json.loads(line) for line in (out/'samples.jsonl').read_text().splitlines()
               if '"record":"playback_sample"' in line]
    notices = [json.loads(line) for line in log.splitlines() if line.startswith('{') and '"record":"notice_state"' in line]
    print(name, json.dumps(rows), 'log=' + str(out/'stderr.log'), flush=True)
    return log, rows, samples, notices

def check(condition, why):
    if not a.record_only:
        assert condition, why + '; evidence: ' + str(root)

def layout(log, name):
    return [dict(re.findall(r'(\w+)=([^ ]+)', line)) for line in log.splitlines()
            if line.startswith('WAM_TEST_LAYOUT name=' + name + ' ')]

case = a.case
if case == 'refusal':
    log, rows, samples, notices = run(case, media, 'nativefail:0@1800,report@2200')
    check(any(s['backend']=='mpv' for s in samples), 'Injected refusal must really recover through mpv')
    check(not any(n['error'] or n['notice'] for n in notices), 'Recovered refusal must be quiet')
    check(rows[-1]['playing']=='1', 'Recovery continues playing')
elif case == 'pending':
    log, rows, _, _ = run(case, media, f'report@100,layout:0@1,open:{media}@50,report@1,report@3000', WAM_TEST_OPEN_DELAY_MS='1500')
    check('WAM_TEST_LOADING true fixture.mp4' in log, 'Pending request must expose loading/title')
    check('WAM_TEST_WINDOWS count=2' not in log, 'Pending open must reuse its window')
    check(rows[0]['media']=='1' and rows[-1]['playing']=='1', 'Pending request owns media and starts')
elif case == 'failed':
    log, rows, _, _ = run(case, root/'garbage.mp4', f'report@1800,menu@1,load:0:{media}@50,report@3000')
    check(rows[0]['media']=='0' and rows[0]['dur']=='0.0000', 'Failed open must empty the player')
    check('Play (disabled)' in log, 'Failed open must disable transport')
    check(rows[-1]['playing']=='1' and float(rows[-1]['pos'])>0.2, 'Valid replacement must autoplay')
    check(re.findall(r'WAM_TEST_DIALOG idx=0 visible=(\d)',log)[-1]=='0', 'Replacement dismisses the obsolete error dialog')
elif case == 'rapid':
    script = ','.join(f'load:0:{media}@{delay}' for delay in [1500, 60, 80, 100, 60, 80]) + f',load:0:{root}/last.mp4@80,report@2500'
    _, rows, _, _ = run(case, media, script)
    check(rows[-1]['source']=='last.mp4' and rows[-1]['playing']=='1' and float(rows[-1]['pos'])>0.2, 'Last rapid open wins and plays')
elif case == 'skip':
    _, rows, samples, _ = run(case, fallback, 'pause:0@1800,skip:0:10@100,report@700,skip:0:-0.5@100,report@700,skip:0:999@100,report@700')
    check(any(s['backend']=='mpv' for s in samples), 'Fixture must use fallback')
    check(abs(float(rows[0]['pos'])-float(rows[1]['pos'])-0.5)<0.08, 'Relative skip must be exact')
    check(float(rows[-1]['dur'])-float(rows[-1]['pos'])<0.06, 'Skip past EOF lands on last frame')
elif case == 'replay':
    for name, source in [('native',media), ('fallback',fallback)]:
        _, rows, _, _ = run(name, source, 'pause:0@1800,skip:0:999@100,report@700,play:0@100,report@1000')
        check(rows[-1]['playing']=='1' and 0.2<float(rows[-1]['pos'])<3, 'Play at last frame must restart')
elif case in ('volume', 'mute'):
    script = ('volume:0:0@1600,mute:0@100,report@100,volume:0:0.7@100,report@100' if case=='volume'
              else 'volume:0:0@1600,key:0:M@100,report@100,key:0:M@100,report@100,menu@1')
    log, rows, _, _ = run(case, media, script)
    check(rows[0]['muted']=='1' and rows[1]['muted']=='0', 'Mute/volume keyboard state')
    if case=='mute': check('Mute  M' in log, 'Playback menu must expose mute')
elif case in ('subtitles', 'transport'):
    script = (f'subsload:0:{root}/cue.srt@1600,controls:0:0@100,volume:0:0.7@100,mute:0@10,mute:0@10,layout:0@300,grab:0:{root}/hidden.png@1,controls:0:1@50,volume:0:0.8@50,layout:0@150,grab:0:{root}/visible.png@1'
              if case=='subtitles' else f'edit:0@1600,controls:0:1@500,layout:0@100,grab:0:{root}/narrow.png@1')
    extra = {} if case=='subtitles' else {'WAM_TEST_GEOMETRY':'800x450+2400+1000'}
    log, _, _, _ = run(case, media, script, **extra)
    if case=='subtitles':
        cues, bars = layout(log,'subtitleLayer'), layout(log,'transport')
        osds = layout(log,'volumeOsd')
        check(all(o['visible']=='1' and float(o['w'])>0 for o in osds), 'Exercise a visible volume OSD')
        check(all(float(c['y']) >= float(o['y'])+float(o['h'])+8 for c,o in zip(cues,osds)), 'Cues clear the volume OSD')
        check(float(cues[0]['y'])>200, 'Hidden transport must release subtitle space at 270px')
        check(bars[1]['visible']=='1', 'Exercise visible controls')
        check(float(cues[1]['y'])+float(cues[1]['h'])<=float(bars[1]['y'])-7, 'Visible transport must clear cues')
    else:
        play, utility = layout(log,'playCluster')[-1], layout(log,'utilityCluster')[-1]
        check(play['visible']=='1' and float(layout(log,'transport')[-1]['w'])<450, 'Exercise a visible narrow bar')
        check(float(play['x'])+float(play['w'])+4<=float(utility['x']), 'Narrow transport clusters must not overlap')
elif case == 'rate':
    for name, source in [('native',media), ('fallback',fallback)]:
        _, rows, _, notices = run(name, source, 'rate:0:5@1600,report@200,rate:0:0.1@100,report@200,rate:0:1.37@100,report@200')
        check([float(r['rate']) for r in rows]==[4, .25, 1.375], 'Both routes clamp/snap rate equally')
        check(not any(n['error'] or n['notice'] for n in notices), 'Clamped rate needs no notice')
elif case == 'truncated':
    _, rows, _, notices = run(case, root/'truncated.mp4', 'report@2400')
    check(any('incomplete' in n['error'] for n in notices), 'Specific file damage must survive fallback failure')
    check(rows[-1]['media']=='0', 'Damaged file must empty the player')
elif case == 'menu':
    log, _, _, _ = run(case, media, 'seekstep:1@1600,menu@50,seekstep:5@50,menu@50')
    check('Skip Forward 1 Second |' in log and 'Skip Forward 5 Seconds |' in log, 'Menu singular/plural')
elif case == 'metrics':
    _, _, samples, _ = run(case, media, 'rate:0:4@1200,report@6000', ms=8000)
    check(any(s['clock_rate']==4 and not s['paused'] for s in samples), 'Metrics report actual configured rate')
    check(samples[-1]['paused'] is True, 'Metrics report paused at EOF')
elif case == 'gapseek':
    # Matroska stores 59.94 fps frames at whole milliseconds with a 16.683 ms
    # DefaultDuration, so 4.921875 s falls after one frame's stated end and
    # before the next frame's start. Both seeks must still commit and draw.
    gapped = root / 'gapped.mkv'
    subprocess.run([a.ffmpeg, '-v', 'error', '-y', '-f', 'lavfi', '-i', 'testsrc2=size=320x180:rate=60000/1001',
                    '-t', '8', '-an', '-c:v', 'libx264', '-preset', 'ultrafast', '-g', '240', str(gapped)], check=True)
    log, _, _, _ = run(case, gapped, 'report@4000', WAM_TEST_SEEK_SCRIPT='4.921875@1.5,2.21875@3')
    events = [json.loads(line).get('event') for line in log.splitlines() if line.startswith('{')]
    check(events.count('commit_seek_submitted') == 2 and events.count('commit_frame_drawn') == 2,
          'A seek between stated frame intervals must draw and release the next seek')
else:
    raise AssertionError(case)
