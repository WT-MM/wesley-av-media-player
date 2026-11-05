#!/usr/bin/env python3
"""Interleaved quiet blank-launch memory, measured at two seconds via libproc."""
import ctypes,json,os,pathlib,statistics,subprocess,sys,time,uuid
base,candidate,out=map(pathlib.Path,sys.argv[1:4]);out.mkdir(parents=True,exist_ok=True)
lib=ctypes.CDLL('/usr/lib/libproc.dylib'); rows=[]
for i in range(7):
 for label,app in [('baseline',base),('candidate',candidate)]:
  dest=(out/f'{i}-{label}').resolve();dest.mkdir(exist_ok=True)
  env=dict(os.environ,HOME=str(dest),WAM_NATIVE_BENCHMARK_TELEMETRY='1',WAM_NATIVE_BENCHMARK_RUN_ID=str(uuid.uuid4()),WAM_NATIVE_BENCHMARK_ASSET_SHA256='0'*64,WAM_NATIVE_BENCHMARK_CANDIDATE_ID='1'*64,WAM_TEST_BACKGROUND='1',WAM_TEST_MUTED='1',WAM_TEST_GEOMETRY='480x270+2400+1000',WAM_TEST_QUIT_AFTER_MS='2500')
  with open(dest/'stderr.log','w') as f:
   p=subprocess.Popen([str(app.resolve()/'Contents/MacOS/WAM')],env=env,stdout=subprocess.DEVNULL,stderr=f)
   time.sleep(2)
   usage=(ctypes.c_uint64*128)()
   assert lib.proc_pid_rusage(p.pid,0,ctypes.byref(usage))==0
   rows.append(dict(build=label,iteration=i,resident=usage[8],footprint=usage[9]))
   p.wait(timeout=10)
  (out/'memory.json').write_text(json.dumps(rows,indent=2))
for label in ['baseline','candidate']:
 for metric in ['resident','footprint']:
  v=[r[metric]/1024**2 for r in rows if r['build']==label]
  print(label,metric,round(statistics.median(v),2),round(min(v),2),round(max(v),2),flush=True)
