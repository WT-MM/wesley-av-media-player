"""Measured AppKit/C-ABI playback, exact seek, refusal, and retirement proof."""
import argparse,hashlib,json,os,pathlib,subprocess,time
p=argparse.ArgumentParser();p.add_argument('--host',type=pathlib.Path,required=True);p.add_argument('--asset',type=pathlib.Path,required=True);p.add_argument('--output',type=pathlib.Path,required=True);p.add_argument('--refusal');p.add_argument('--seek',action='store_true');p.add_argument('--api',action='store_true');p.add_argument('--replace',action='store_true');p.add_argument('--quarantine',action='store_true');p.add_argument('--unique',action='store_true');a=p.parse_args()
host=a.host.resolve();asset=a.asset.resolve();assert '/build/' in str(host)
def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()
if a.unique:a.output=a.output/subprocess.check_output(['uuidgen'],text=True).strip().lower()
a.output.mkdir(parents=True,exist_ok=False);home=a.output/'home';home.mkdir();metrics=a.output/'metrics.jsonl'
env={k:v for k,v in os.environ.items() if not k.startswith('WAM_')}
env.update(HOME=str(home),WAM_NATIVE_BENCHMARK_TELEMETRY='1',WAM_NATIVE_BENCHMARK_RUN_ID=subprocess.check_output(['uuidgen'],text=True).strip().lower(),WAM_NATIVE_BENCHMARK_ASSET_SHA256=sha(asset),WAM_NATIVE_BENCHMARK_CANDIDATE_ID=sha(host),WAM_TEST_BACKGROUND='1',WAM_TEST_MUTED='1',WAM_TEST_GEOMETRY='480x270+2400+1000',WAM_PLAYBACK_METRICS_PATH=str(metrics),WAM_TEST_QUIT_AFTER_MS='4000')
if a.quarantine:env.update(WAM_TEST_RETIRE_STALL='1',WAM_TEST_QUIT_AFTER_MS='1000')
if a.replace:env['WAM_TEST_REPLACE']='1'
if a.api:env['WAM_TEST_API']='1'
if a.seek:env['WAM_TEST_SEEK_SCRIPT']='1001/30000@1'
with (a.output/'log.txt').open('w') as log:
 process=subprocess.Popen([str(host),str(asset)],env=env,stdout=log,stderr=log)
 try:rc=process.wait(timeout=22)
 except subprocess.TimeoutExpired:
  process.terminate()
  try:rc=process.wait(timeout=3)
  except subprocess.TimeoutExpired:process.kill();rc=process.wait()
rows=[json.loads(line) for line in metrics.read_text().splitlines()] if metrics.exists() else []
errors=[]
if rc!=0:errors.append(f'host rc={rc}')
closed=[r for r in rows if r['kind']==2 and r['state']==9 and r['result']==0 and not r['retiring'] and r['charged_sessions']==0]
if a.quarantine:
 if not any(r['kind']==2 and r['result']==4 and r['retiring'] and r['charged_sessions']>0 for r in rows):errors.append('no charged quarantine result')
 if not any(r['state']==9 and not r['retiring'] and r['charged_sessions']==0 for r in rows):errors.append('quarantine never actually retired')
 if closed:errors.append('quarantine forged a completed close')
elif not closed:errors.append('no clean close completion')
if a.api:
 if 'API checks passed: 33 terminal results' not in (a.output/'log.txt').read_text():errors.append('API command checks failed')
elif a.refusal:
 if not any(r['refusal']==a.refusal and r['kind']==3 for r in rows):errors.append('missing named refusal '+a.refusal)
 if a.refusal=='HeAacSbrDecoderDelayUnproven' and not any('LibavformatAudioTimingUnproven' in r.get('related_refusals',[]) for r in rows):errors.append('missing structured secondary refusal')
else:
 if max((r['drawn_frames'] for r in rows),default=0)<=0:errors.append('no drawn frames')
 if not any(r['kind']==5 and r['first_pts_timescale']>0 and r['first_pts_value']==0 for r in rows):errors.append('no exact first PTS zero')
 rates=[r['clock_rate'] for r in rows if r['kind']==4 and r['clock_valid']]
 if not rates or any(format(rate,'.4f')!='1.0000' for rate in rates):errors.append('clock is not 1.0000')
 if any(r['kind']==3 for r in rows):errors.append('unexpected native refusal')
 if a.replace:
  firsts=[r for r in rows if r['kind']==5]
  if len(firsts)!=2 or firsts[1]['first_pts_value']!=firsts[1]['first_pts_timescale'] or firsts[1]['generation']<=firsts[0]['generation']:errors.append('replacement did not publish its own exact first PTS and generation')
 if a.seek:
  seeks=[r for r in rows if r['kind']==2 and r['requested_value']==1001 and r['requested_timescale']==30000 and r['result']==0]
  if not seeks:errors.append('missing exact off-grid seek completion')
  elif any(r['audio_start_value']*8000!=267*r['audio_start_timescale'] for r in seeks):errors.append('audio boundary differs from ceil(T*48000)/48000')
assert sha(host)==env['WAM_NATIVE_BENCHMARK_CANDIDATE_ID'] and sha(asset)==env['WAM_NATIVE_BENCHMARK_ASSET_SHA256']
result=dict(host=str(host),asset=str(asset),pid=process.pid,rc=rc,identities={k:v for k,v in env.items() if k.startswith('WAM_NATIVE_BENCHMARK')},errors=errors,passed=not errors)
(a.output/'result.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result));raise SystemExit(bool(errors))
