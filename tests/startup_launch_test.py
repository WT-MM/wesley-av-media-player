#!/usr/bin/env python3
"""Quiet macOS integration check: startup ordering, argv/Apple Event and lazy blank.
Run: python3 tests/startup_launch_test.py build/WAM.app
Requires a telemetry build, ffmpeg, and a logged-in GUI session.
"""
import json, os, pathlib, subprocess, sys, tempfile, uuid
app=pathlib.Path(sys.argv[1]).resolve()
with tempfile.TemporaryDirectory(prefix='wam-startup-test-') as root:
 root=pathlib.Path(root)
 media=root/'synthetic.mp4'
 subprocess.run(['ffmpeg','-v','error','-f','lavfi','-i','testsrc2=size=160x90:rate=24:duration=4','-c:v','libx264','-threads','1','-pix_fmt','yuv420p',str(media)],check=True)
 for mode in ['argv','apple-event','blank']:
  dest=root/mode;dest.mkdir()
  env=dict(os.environ,HOME=str(dest),WAM_NATIVE_BENCHMARK_TELEMETRY='1',
      WAM_NATIVE_BENCHMARK_RUN_ID=str(uuid.uuid4()),WAM_NATIVE_BENCHMARK_ASSET_SHA256='0'*64,
      WAM_NATIVE_BENCHMARK_CANDIDATE_ID='1'*64,WAM_TEST_BACKGROUND='1',WAM_TEST_MUTED='1',
      WAM_TEST_GEOMETRY='480x270+2400+1000',WAM_TEST_QUIT_AFTER_MS='1500')
  log=dest/'stderr.log'
  if mode=='apple-event':
   command=['open','-n','-g','-W','-a',str(app),'--stderr',str(log),'--stdout',str(dest/'stdout.log')]
   for k,v in env.items():
    if k=='HOME' or k.startswith('WAM_'): command+=['--env',f'{k}={v}']
   subprocess.run(command+[str(media)],check=True,timeout=20)
  else:
   with log.open('w') as err:
    subprocess.run([str(app/'Contents/MacOS/WAM')]+([] if mode=='blank' else [str(media)]),env=env,stderr=err,stdout=subprocess.DEVNULL,check=True,timeout=20)
  events={};counts={}
  for line in log.read_text(errors='replace').splitlines():
   try:r=json.loads(line)
   except ValueError:continue
   if r.get('record')=='event':
    events.setdefault(r['event'],r['monotonic_ns']);counts[r['event']]=counts.get(r['event'],0)+1
  assert 'first_scene_frame' in events, (mode,'no window frame')
  if mode=='blank':
   assert not {'open_requested','fallback_load_begin','fallback_initialize_begin'} & events.keys(), 'blank engine must stay dormant'
  else:
   assert counts.get('open_requested')==1, (mode,'open lost or duplicated',counts)
   assert 'first_frame_drawn' in events and 'fallback_selected' not in events, (mode,'synthetic native playback failed')
   assert events['open_requested'] < events['first_window_exposed'], (mode,'launch open waited for window exposure')
   if mode=='apple-event':
    assert events['file_open_received'] < events['qml_root_loaded'], 'Apple Event must be buffered before window construction'
  print(mode+': passed',flush=True)
