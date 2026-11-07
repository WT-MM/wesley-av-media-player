#!/usr/bin/env python3
"""Quiet, synthetic-only UI checks. Never activates a window or controls other PIDs."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parent / 'support'))
import wam_launch  # noqa: E402

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

def run(name, source, script, ms=6500, expect=0, **extra):
    out = root / name
    out.mkdir(exist_ok=True)
    home = out / ('home-' + uuid.uuid4().hex)
    home.mkdir(exist_ok=True)
    # Cocoa is required for native menus; no window is activated.
    env = wam_launch.seam_env(home, WAM_TEST_QUIT_AFTER_MS=ms, WAM_TEST_WINDOW_SCRIPT=script,
                              WAM_TEST_NOTICE_TRACE=1, WAM_PLAYBACK_METRICS_PATH=out/'samples.jsonl',
                              WAM_PLAYBACK_METRICS_INTERVAL_MS=100, QT_QPA_PLATFORM='cocoa', **extra)
    rc, log = wam_launch.run(a.app.resolve(), [source], env, out/'stderr.log', ms/1000 + 20)
    (out/'receipt.json').write_text(json.dumps(dict(returncode=rc, script=script, source=str(source)), indent=2))
    assert rc == expect, (rc, str(out), log[-2000:])
    reports = wam_launch.records(log)
    samples = [r for r in wam_launch.records((out/'samples.jsonl').read_text()) if r['record'] == 'playback_sample'] \
        if (out/'samples.jsonl').exists() else []
    print(name, json.dumps(of(reports, 'test_window')), 'log=' + str(out/'stderr.log'), flush=True)
    return log, reports, samples

def of(reports, record, **match):
    return [r for r in reports if r.get('record') == record and all(r.get(k) == v for k, v in match.items())]

def check(condition, why):
    if not a.record_only:
        assert condition, why + '; evidence: ' + str(root)

def menu_items(reports):
    return [item for menu in of(reports, 'test_menu') for item in menu['items']]

case = a.case
windows = lambda reports: of(reports, 'test_window')
notices = lambda reports: of(reports, 'notice_state')
layout = lambda reports, name: of(reports, 'test_layout', name=name)
if case == 'refusal':
    _, reports, samples = run(case, media, 'nativefail:0@1800,report@2200')
    check(any(s['backend']=='mpv' for s in samples), 'Injected refusal must really recover through mpv')
    check(not any(n['error'] or n['notice'] for n in notices(reports)), 'Recovered refusal must be quiet')
    check(windows(reports)[-1]['playing']==1, 'Recovery continues playing')
elif case == 'pending':
    _, reports, _ = run(case, media, f'report@100,layout:0@1,open:{media}@50,report@1,report@3000', WAM_TEST_OPEN_DELAY_MS='1500')
    rows = windows(reports)
    check(of(reports, 'test_loading', loading=True, title='fixture.mp4'), 'Pending request must expose loading/title')
    check(not of(reports, 'test_windows', count=2), 'Pending open must reuse its window')
    check(rows[0]['media']==1 and rows[-1]['playing']==1, 'Pending request owns media and starts')
elif case == 'failed':
    _, reports, _ = run(case, root/'garbage.mp4', f'report@1800,menu@1,load:0:{media}@50,report@3000')
    rows = windows(reports)
    check(rows[0]['media']==0 and rows[0]['dur']==0, 'Failed open must empty the player')
    check('Play (disabled)' in menu_items(reports), 'Failed open must disable transport')
    check(rows[-1]['playing']==1 and rows[-1]['pos']>0.2, 'Valid replacement must autoplay')
    check(of(reports, 'test_dialog', idx=0)[-1]['visible']==0, 'Replacement dismisses the obsolete error dialog')
elif case == 'rapid':
    script = ','.join(f'load:0:{media}@{delay}' for delay in [1500, 60, 80, 100, 60, 80]) + f',load:0:{root}/last.mp4@80,report@2500'
    _, reports, _ = run(case, media, script)
    last = windows(reports)[-1]
    check(last['source']=='last.mp4' and last['playing']==1 and last['pos']>0.2, 'Last rapid open wins and plays')
elif case == 'skip':
    _, reports, samples = run(case, fallback, 'pause:0@1800,skip:0:10@100,report@700,skip:0:-0.5@100,report@700,skip:0:999@100,report@700')
    rows = windows(reports)
    check(any(s['backend']=='mpv' for s in samples), 'Fixture must use fallback')
    check(abs(rows[0]['pos']-rows[1]['pos']-0.5)<0.08, 'Relative skip must be exact')
    check(rows[-1]['dur']-rows[-1]['pos']<0.06, 'Skip past EOF lands on last frame')
elif case == 'replay':
    for name, source in [('native',media), ('fallback',fallback)]:
        _, reports, _ = run(name, source, 'pause:0@1800,skip:0:999@100,report@700,play:0@100,report@1000')
        last = windows(reports)[-1]
        check(last['playing']==1 and 0.2<last['pos']<3, 'Play at last frame must restart')
elif case in ('volume', 'mute'):
    script = ('volume:0:0@1600,mute:0@100,report@100,volume:0:0.7@100,report@100' if case=='volume'
              else 'volume:0:0@1600,key:0:M@100,report@100,key:0:M@100,report@100,menu@1')
    _, reports, _ = run(case, media, script)
    rows = windows(reports)
    check(rows[0]['muted']==1 and rows[1]['muted']==0, 'Mute/volume keyboard state')
    if case=='mute': check('[ ] Mute  M' in menu_items(reports), 'Playback menu must expose mute')
elif case in ('subtitles', 'transport'):
    script = (f'subsload:0:{root}/cue.srt@1600,controls:0:0@100,volume:0:0.7@100,mute:0@10,mute:0@10,layout:0@300,grab:0:{root}/hidden.png@1,controls:0:1@50,volume:0:0.8@50,layout:0@150,grab:0:{root}/visible.png@1'
              if case=='subtitles' else f'edit:0@1600,controls:0:1@500,layout:0@100,grab:0:{root}/narrow.png@1')
    extra = {} if case=='subtitles' else {'WAM_TEST_GEOMETRY':'800x450+2400+1000'}
    _, reports, _ = run(case, media, script, **extra)
    if case=='subtitles':
        cues, bars, osds = layout(reports,'subtitleLayer'), layout(reports,'transport'), layout(reports,'volumeOsd')
        check(all(o['visible']==1 and o['w']>0 for o in osds), 'Exercise a visible volume OSD')
        check(all(c['y'] >= o['y']+o['h']+8 for c,o in zip(cues,osds)), 'Cues clear the volume OSD')
        check(cues[0]['y']>200, 'Hidden transport must release subtitle space at 270px')
        check(bars[1]['visible']==1, 'Exercise visible controls')
        check(cues[1]['y']+cues[1]['h']<=bars[1]['y']-7, 'Visible transport must clear cues')
    else:
        play, utility = layout(reports,'playCluster')[-1], layout(reports,'utilityCluster')[-1]
        check(play['visible']==1 and layout(reports,'transport')[-1]['w']<450, 'Exercise a visible narrow bar')
        check(play['x']+play['w']+4<=utility['x'], 'Narrow transport clusters must not overlap')
elif case == 'rate':
    for name, source in [('native',media), ('fallback',fallback)]:
        _, reports, _ = run(name, source, 'rate:0:5@1600,report@200,rate:0:0.1@100,report@200,rate:0:1.37@100,report@200')
        check([r['rate'] for r in windows(reports)]==[4, .25, 1.375], 'Both routes clamp/snap rate equally')
        check(not any(n['error'] or n['notice'] for n in notices(reports)), 'Clamped rate needs no notice')
elif case == 'truncated':
    _, reports, _ = run(case, root/'truncated.mp4', 'report@2400')
    check(any('incomplete' in n['error'] for n in notices(reports)), 'Specific file damage must survive fallback failure')
    check(windows(reports)[-1]['media']==0, 'Damaged file must empty the player')
elif case == 'menu':
    _, reports, _ = run(case, media, 'seekstep:1@1600,menu@50,seekstep:5@50,menu@50')
    items = menu_items(reports)
    check('Skip Forward 1 Second' in items and 'Skip Forward 5 Seconds' in items, 'Menu singular/plural')
elif case == 'metrics':
    _, _, samples = run(case, media, 'rate:0:4@1200,report@6000', ms=8000)
    check(any(s['clock_rate']==4 and not s['paused'] for s in samples), 'Metrics report actual configured rate')
    check(samples[-1]['paused'] is True, 'Metrics report paused at EOF')
elif case == 'badscript':
    log, _, _ = run(case, media, 'report@100,repport@100', expect=2)
    check("WAM_TEST_WINDOW_SCRIPT: unknown verb in entry 'repport'" in log, 'A bad script entry must fail the launch by name')
elif case == 'gapseek':
    # Matroska stores 59.94 fps frames at whole milliseconds with a 16.683 ms
    # DefaultDuration, so 4.921875 s falls after one frame's stated end and
    # before the next frame's start. Both seeks must still commit and draw.
    gapped = root / 'gapped.mkv'
    subprocess.run([a.ffmpeg, '-v', 'error', '-y', '-f', 'lavfi', '-i', 'testsrc2=size=320x180:rate=60000/1001',
                    '-t', '8', '-an', '-c:v', 'libx264', '-preset', 'ultrafast', '-g', '240', str(gapped)], check=True)
    _, reports, _ = run(case, gapped, 'report@4000', WAM_TEST_SEEK_SCRIPT='4.921875@1.5,2.21875@3')
    events = [r.get('event') for r in reports]
    check(events.count('commit_seek_submitted') == 2 and events.count('commit_frame_drawn') == 2,
          'A seek between stated frame intervals must draw and release the next seek')
else:
    raise AssertionError(case)
