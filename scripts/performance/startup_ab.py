#!/usr/bin/env python3
"""Quiet alternating direct/LaunchServices startup trials; macOS telemetry build.
Usage: startup_ab.py baseline.app candidate.app outdir specimens-dir [N=7]
Uses the maintainer's run.zsh harness for direct launches. No app activation.
"""
import json, os, pathlib, statistics, subprocess, sys, time, uuid
baseline, candidate, out, media = map(pathlib.Path, sys.argv[1:5])
n = int(sys.argv[5]) if len(sys.argv)>5 else 7
out.mkdir(parents=True, exist_ok=True)
cases = [('u004','u004.mp4','direct'), ('u005','u005.mp4','direct'),
         ('u007','u007.mp4','direct'), ('launchservices','u004.mp4','ls'),
         ('blank',None,'direct')]
rows=[]
for case, filename, mode in cases:
 for i in range(n):
  for label, app in [('baseline',baseline),('candidate',candidate)]:
   dest=(out/f'{case}-{i:02}-{label}').resolve(); dest.mkdir(parents=True,exist_ok=True)
   if mode=='direct':
    command=['/private/tmp/wam-harness/run.zsh',str(app.resolve()),str(dest),str(media/filename) if filename else '-', 'WAM_TEST_QUIT_AFTER_MS=3500']
   else:
    home=dest/'home'; home.mkdir(exist_ok=True)
    env={'HOME':str(home),'WAM_NATIVE_BENCHMARK_TELEMETRY':'1',
         'WAM_NATIVE_BENCHMARK_RUN_ID':str(uuid.uuid4()),'WAM_NATIVE_BENCHMARK_ASSET_SHA256':'0'*64,
         'WAM_NATIVE_BENCHMARK_CANDIDATE_ID':'1'*64,'WAM_TEST_BACKGROUND':'1','WAM_TEST_MUTED':'1',
         'WAM_TEST_GEOMETRY':'480x270+2400+1000','WAM_TEST_QUIT_AFTER_MS':'3500'}
    command=['/usr/bin/open','-n','-g','-W','-a',str(app.resolve()),'--stdout',str(dest/'stdout.log'),'--stderr',str(dest/'stderr.log')]
    for k,v in env.items(): command+=['--env',f'{k}={v}']
    command+=[str(media/filename)]
   subprocess.run(command,check=True,timeout=45)
   records=[]
   for line in (dest/'stderr.log').read_text(errors='replace').splitlines():
    try: records.append(json.loads(line))
    except ValueError: pass
   header=next(r for r in records if 'process_start_abstime' in r)
   offset=time.clock_gettime_ns(4)-time.clock_gettime_ns(8)
   start=header['process_start_abstime']*125/3+offset
   events={}
   for r in sorted((r for r in records if r.get('record')=='event'),key=lambda r:r['monotonic_ns']):
    events.setdefault(r['event'],(r['monotonic_ns']-start)/1e6)
   row={'case':case,'iteration':i,'build':label,'events':events,'clock_offset_ns':offset}
   rows.append(row)
   (out/'results.json').write_text(json.dumps(rows,indent=2))
   print(case,i,label,round(events.get('first_frame_drawn',events.get('fallback_playback_restart',events.get('first_scene_frame',-1))),1),flush=True)
summary={}
for case,_,_ in cases:
 summary[case]={}
 for label in ['baseline','candidate']:
  selected=[r['events'] for r in rows if r['case']==case and r['build']==label]
  summary[case][label]={}
  for key in sorted(set().union(*selected)):
   values=[r[key] for r in selected if key in r]
   summary[case][label][key]={'n':len(values),'median':statistics.median(values),'min':min(values),'max':max(values)}
(out/'summary.json').write_text(json.dumps(summary,indent=2))
