"""Identity-bound measurements of the build app; never controls an installed app."""
import argparse,hashlib,json,os,pathlib,subprocess,uuid
parser=argparse.ArgumentParser()
parser.add_argument('--output',required=True)
parser.add_argument('--sampler',required=True)
parser.add_argument('--asset',action='append',required=True)
parser.add_argument('--seek',default='')
parser.add_argument('--no-hardware',action='store_true')
args=parser.parse_args()
repo=pathlib.Path(__file__).resolve().parents[1]
app=repo/'build/WAM.app/Contents/MacOS/WAM'
def sha(path):
    with open(path,'rb') as f:return hashlib.file_digest(f,'sha256').hexdigest()
candidate=sha(app);root=pathlib.Path(args.output);root.mkdir(parents=True,exist_ok=True)
results=[]
for index,path in enumerate(args.asset):
    asset=pathlib.Path(path).resolve();run=root/str(index);run.mkdir();(run/'home').mkdir()
    env=os.environ.copy();run_id=str(uuid.uuid4())
    env.update(HOME=str(run/'home'),WAM_NATIVE_BENCHMARK_TELEMETRY='1',WAM_NATIVE_BENCHMARK_RUN_ID=run_id,
        WAM_NATIVE_BENCHMARK_ASSET_SHA256=sha(asset),WAM_NATIVE_BENCHMARK_CANDIDATE_ID=candidate,
        WAM_TEST_BACKGROUND='1',WAM_TEST_MUTED='1',WAM_TEST_GEOMETRY='480x270+2400+1000',
        WAM_TEST_QUIT_AFTER_MS='14000',WAM_PLAYBACK_METRICS_PATH=str(run/'metrics.jsonl'),WAM_TEST_SEEK_SCRIPT=args.seek)
    if args.no_hardware:env['WAM_TEST_NO_VIDEO_HARDWARE']='1'
    if sha(app)!=candidate:raise RuntimeError('candidate changed')
    with (run/'stdout.txt').open('w') as out,(run/'stderr.txt').open('w') as err,(run/'usage.json').open('w') as usage:
        p=subprocess.Popen([str(app),str(asset)],env=env,stdout=out,stderr=err)
        sampler=subprocess.Popen([args.sampler,str(p.pid)],stdout=usage)
        try:rc=p.wait(timeout=25)
        except subprocess.TimeoutExpired:p.terminate();rc=p.wait(timeout=5)
        sampler.wait(timeout=5)
    text=(run/'stderr.txt').read_text()+(run/'stdout.txt').read_text()
    metrics=[json.loads(line) for line in (run/'metrics.jsonl').read_text().splitlines()] if (run/'metrics.jsonl').exists() else []
    samples=[r for r in metrics if r.get('record')=='playback_sample']
    row=dict(asset=str(asset),asset_sha256=sha(asset),candidate_sha256=candidate,run_id=run_id,pid=p.pid,rc=rc,
        first_frame='first_frame_drawn' in text,failures=[r for r in text.splitlines() if 'WAM: native failure' in r],
        routes=[r for r in text.splitlines() if r.startswith('WAM: native decoder stage=')],
        usage=json.loads((run/'usage.json').read_text()),last_sample=samples[-1] if samples else None)
    results.append(row);(root/'results.json').write_text(json.dumps(results,indent=2));print(json.dumps(row),flush=True)
