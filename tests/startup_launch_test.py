#!/usr/bin/env python3
"""Quiet macOS integration check: startup ordering, argv/Apple Event and lazy blank.

Usage: python3 tests/startup_launch_test.py build/WAM.app --ffmpeg ffmpeg
Requires a telemetry build and a logged-in GUI session. The media is synthetic.
"""
import argparse
import pathlib
import subprocess
import sys
import tempfile

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent / 'support'))
import wam_launch  # noqa: E402

parser = argparse.ArgumentParser()
parser.add_argument('app', type=pathlib.Path)
parser.add_argument('--ffmpeg', default='ffmpeg')
args = parser.parse_args()
app = args.app.resolve()
with tempfile.TemporaryDirectory(prefix='wam-startup-test-') as root:
    root = pathlib.Path(root)
    media = root / 'synthetic.mp4'
    subprocess.run([args.ffmpeg, '-v', 'error', '-f', 'lavfi', '-i', 'testsrc2=size=160x90:rate=24:duration=4',
                    '-c:v', 'libx264', '-threads', '1', '-pix_fmt', 'yuv420p', str(media)], check=True, timeout=60)
    for mode in ['argv', 'apple-event', 'blank']:
        dest = root / mode
        dest.mkdir()
        env = wam_launch.seam_env(dest, WAM_TEST_QUIT_AFTER_MS=1500)
        log = dest / 'stderr.log'
        if mode == 'apple-event':
            # LaunchServices delivers the file as an odoc Apple Event, as
            # Finder does; -g keeps the app in the background.
            command = ['open', '-n', '-g', '-W', '-a', str(app), '--stderr', str(log),
                       '--stdout', str(dest / 'stdout.log')]
            for key, value in env.items():
                if key == 'HOME' or key.startswith('WAM_'):
                    command += ['--env', f'{key}={value}']
            subprocess.run(command + [str(media)], check=True, timeout=30)
            text = log.read_text(errors='replace')
        else:
            code, text = wam_launch.run(app / 'Contents/MacOS/WAM', [] if mode == 'blank' else [media],
                                        env, log, 30)
            assert code == 0, (mode, code, text[-2000:])
        events, counts = {}, {}
        for record in wam_launch.records(text):
            if record.get('record') == 'event':
                events.setdefault(record['event'], record['monotonic_ns'])
                counts[record['event']] = counts.get(record['event'], 0) + 1
        assert 'first_scene_frame' in events, (mode, 'no window frame')
        if mode == 'blank':
            assert not {'open_requested', 'fallback_load_begin', 'fallback_initialize_begin'} & events.keys(), \
                'blank engine must stay dormant'
        else:
            assert counts.get('open_requested') == 1, (mode, 'open lost or duplicated', counts)
            assert 'first_frame_drawn' in events and 'fallback_selected' not in events, \
                (mode, 'synthetic native playback failed')
            assert events['open_requested'] < events['first_window_exposed'], \
                (mode, 'launch open waited for window exposure')
            if mode == 'apple-event':
                assert events['file_open_received'] < events['qml_root_loaded'], \
                    'Apple Event must be buffered before window construction'
        print(mode + ': passed', flush=True)
