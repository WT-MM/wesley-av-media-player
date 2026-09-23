#!/usr/bin/env python3
"""Offline, resumable WAM ASR bake-off. All generated data stays in scratch."""
import argparse, collections, difflib, hashlib, json, os, pathlib, random, re, selectors, statistics, subprocess, time, wave
ROOT = pathlib.Path('/private/tmp/wam-asr-scratch')
APP = pathlib.Path('/Applications/WAM.app/Contents/Resources')
def normalize(s):
    return re.sub(r'[^A-Z0-9\s]', '', s.upper()).split()
def distance(a, b):
    row = list(range(len(b)+1))
    for i, x in enumerate(a, 1):
        new = [i]
        for j, y in enumerate(b, 1):
            new.append(min(new[-1]+1, row[j]+1, row[j-1]+(x != y)))
        row = new
    return row[-1]
def prepare():
    corpus = ROOT/'LibriSpeech/test-clean'
    refs = {}
    for p in sorted(corpus.rglob('*.trans.txt')):
        for line in p.read_text().splitlines():
            key, text = line.split(' ', 1)
            refs[key] = (p.parent/(key+'.flac'), text)
    rng = random.Random(20260922)
    short = rng.sample(sorted(refs), 300)
    groups = collections.defaultdict(list)
    for key in sorted(refs, key=lambda x: tuple(map(int,x.split('-')))):
        groups[key.split('-')[0]].append(key)
    (ROOT/'audio').mkdir(exist_ok=True)
    def decode(key):
        return subprocess.check_output([str(APP/'tools/ffmpeg'), '-v','error','-i',str(refs[key][0]),'-ar','16000','-ac','1','-f','s16le','-'])
    def save(key, keys, pcm, kind, bounds):
        p = ROOT/'audio'/(key+'.wav')
        with wave.open(str(p),'wb') as w:
            w.setparams((1,2,16000,0,'NONE','not compressed')); w.writeframes(pcm)
        return dict(id=key, path=str(p), kind=kind, duration=len(pcm)/32000, reference=' '.join(refs[k][1] for k in keys), utterances=bounds, sha256=hashlib.sha256(p.read_bytes()).hexdigest())
    entries = []
    for key in short:
        pcm = decode(key)
        entries.append(save(key,[key],pcm,'short',[dict(id=key,start=0,text=refs[key][1])]))
    speakers = sorted(groups); rng.shuffle(speakers)
    for speaker in speakers:
        pcm = bytearray(); keys=[]; bounds=[]
        for key in groups[speaker]:
            audio=decode(key)
            if len(pcm)+len(audio)>600*32000: break
            bounds.append(dict(id=key,start=len(pcm)/32000,text=refs[key][1])); keys.append(key); pcm.extend(audio)
            if len(pcm)>=300*32000: break
        if len(pcm)<300*32000: continue
        entries.append(save('long-'+speaker,keys,pcm,'long',bounds))
        if sum(e['kind']=='long' for e in entries)==20: break
    assert len(entries)==320
    (ROOT/'manifest.json').write_text(json.dumps(entries,indent=2))
    print('Prepared', len(entries), 'files;', sum(e['duration'] for e in entries), 'audio seconds',flush=True)
# Half the logical cores: this 16-core host idles near load 5 with a browser,
# WindowServer and remote desktop; builds are detected separately below.
QUIET_LOAD = max(4, os.cpu_count() // 2)
def quiet_snapshot():
    uptime = subprocess.check_output(['uptime'],text=True).strip()
    loads = [float(x) for x in re.search(r'load averages?:\s*([\d.]+)[, ]+([\d.]+)[, ]+([\d.]+)',uptime).groups()]
    ps = subprocess.run(['ps','-axo','pid=,comm='],capture_output=True,text=True)
    builds = [s for s in ps.stdout.splitlines() if re.search(r'/(?:clang(?:\+\+)?|cc1|swift-frontend|swiftc|ninja|make|cmake|xcodebuild|ld)(?:\s|$)',s)]
    return dict(time=time.time(), uptime=uptime, loads=loads, builds=builds, ps_ok=ps.returncode==0, quiet=loads[0]<QUIET_LOAD and not builds and ps.returncode==0)
def wait_quiet():
    while True:
        s=quiet_snapshot()
        with (ROOT/'quiet.jsonl').open('a') as f: f.write(json.dumps(s)+'\n')
        if s['quiet']: return s
        print('WAIT',s['uptime'],'builds=',len(s['builds']),'ps_ok=',s['ps_ok'],flush=True)
        time.sleep(30)
def segments(path):
    if not path.exists(): return []
    out=[]
    def sec(x):
        h,m,s=re.split('[:,]',x)[:3]; ms=x[-3:]
        return int(h)*3600+int(m)*60+int(s)+int(ms)/1000
    for block in re.split(r'\n\s*\n',path.read_text().strip()):
        lines=block.splitlines()
        if len(lines)>=3 and ' --> ' in lines[1]:
            a,b=lines[1].split(' --> '); out.append(dict(start=sec(a),end=sec(b),text=' '.join(lines[2:])))
    return out
def boundary_alignment(entry, seg):
    """Match exact word-sequence anchors; only compare matching utterance/segment starts."""
    ref=[]; boundaries={}
    for u in entry['utterances']:
        boundaries[len(ref)]=u['start']; ref.extend(normalize(u['text']))
    hyp=[]; starts={}
    for s in seg:
        starts[len(hyp)]=s['start']; hyp.extend(normalize(s['text']))
    anchors={}
    for block in difflib.SequenceMatcher(None,ref,hyp,autojunk=False).get_matching_blocks():
        if block.size<3: continue
        for offset in range(block.size): anchors[block.a+offset]=block.b+offset
    errors=[starts[anchors[i]]-t for i,t in boundaries.items() if i in anchors and anchors[i] in starts]
    return dict(matched=len(errors), total=len(boundaries), signed_errors=errors,
                median_absolute=statistics.median(map(abs,errors)) if errors else None)
class OutputCapture:
    def __init__(self, events):
        self.events = events
        self.data = bytearray()
        self.pending = b''
        self.first = None
        self.core_start = None
        self.core_load = None
        self.ready = None
        self.prepare_time = None

    def observe_line(self, line, now):
        record = dict(seconds=now, line=line)
        event = {}
        if line.startswith('{'):
            try:
                event = json.loads(line)
            except json.JSONDecodeError as error:
                # Merged stderr may contain non-JSON diagnostics; retain the error.
                record['parse_error'] = str(error)
        self.events.write(json.dumps(record) + '\n')
        self.events.flush()
        is_segment = re.search(r'\[\d\d:\d\d:\d\d\.\d+ -->', line)
        if self.first is None and (is_segment or event.get('event') == 'segment'):
            self.first = now
        if 'processing ' in line and 'samples' in line:
            self.ready = now
        if event.get('event') == 'prepared':
            self.ready = now
            self.prepare_time = event['seconds']
        if 'loading Core ML model from' in line:
            self.core_start = now
        if 'Core ML model loaded' in line and self.core_start is not None:
            self.core_load = now - self.core_start

    def feed(self, chunk, now):
        self.data.extend(chunk)
        self.pending += chunk
        while b'\n' in self.pending:
            raw, self.pending = self.pending.split(b'\n', 1)
            self.observe_line(raw.decode(errors='replace'), now)

    def drain_ready(self, selector, started):
        for key, _ in selector.select(timeout=1):
            chunk = os.read(key.fileobj.fileno(), 65536)
            if not chunk:
                selector.unregister(key.fileobj)
                continue
            self.feed(chunk, time.monotonic() - started)

def monitor_output(process, capture, started):
    samples = []
    next_check = started + 10
    with selectors.DefaultSelector() as selector:
        selector.register(process.stdout, selectors.EVENT_READ)
        while selector.get_map():
            capture.drain_ready(selector, started)
            if time.monotonic() >= next_check:
                samples.append(quiet_snapshot())
                next_check = time.monotonic() + 10
            if time.monotonic() - started > 1800:
                raise RuntimeError('engine timed out after 1800 seconds')
    return samples

def capture_process(process, folder, started):
    try:
        with (folder/'events.jsonl').open('w') as events:
            capture = OutputCapture(events)
            samples = monitor_output(process, capture, started)
        return process.wait(), capture, samples
    except BaseException:
        if process.poll() is None:
            os.killpg(process.pid, 9)
            process.wait()
        raise
    finally:
        process.stdout.close()

def run_one(engine, e, rep):
    folder=ROOT/'runs'/engine/e['id']/str(rep); folder.mkdir(parents=True,exist_ok=True)
    record=folder/'result.json'
    if record.exists():
        previous=json.loads(record.read_text())
        if previous['valid']: return
        record.rename(folder/('invalid-'+str(time.time_ns())+'.json'))
    base=folder/'out'
    if engine=='C': cmd=[str(ROOT/'apple-transcribe'),e['path'],str(base)]
    else:
        exe=ROOT/'whisper-coreml' if engine=='B' else APP/'tools/whisper-cli'
        model=ROOT/'models/ggml-base.en.bin' if engine=='B' else APP/'models/ggml-base.en.bin'
        cmd=[str(exe),'-m',str(model),'-f',e['path'],'-t',str(min(os.cpu_count() or 4,16)),'-osrt','-of',str(base),'-l','auto']
        if engine=='D': cmd+=['-ng']
    pre=wait_quiet(); started=time.monotonic()
    p=subprocess.Popen(['/usr/bin/time','-l','-o',str(folder/'time.txt')]+cmd,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,start_new_session=True)
    rc,capture,samples=capture_process(p,folder,started)
    wall=time.monotonic()-started
    log=capture.data.decode(errors='replace'); (folder/'output.log').write_text(log)
    timing=(folder/'time.txt').read_text(); post=quiet_snapshot()
    ts=re.search(r'([\d.]+) real\s+([\d.]+) user\s+([\d.]+) sys',timing)
    rss=re.search(r'(\d+)\s+maximum resident set size',timing)
    load=re.search(r'load time\s*=\s*([\d.]+) ms',log)
    seg=segments(base.with_suffix('.srt')); hyp=' '.join(s['text'] for s in seg)
    ref=normalize(e['reference']); errors=distance(ref,normalize(hyp))
    # Boundary proximity is diagnostic only: segments need not start at utterance boundaries.
    starts=[u['start'] for u in e['utterances']]
    offsets=[min(abs(s['start']-b) for b in starts) for s in seg] if e['kind']=='long' else []
    result=dict(engine=engine,id=e['id'],kind=e['kind'],rep=rep,command=cmd,returncode=rc,wall=wall,rtf=wall/e['duration'],first_caption=capture.first,ready=capture.ready,prepare_time=capture.prepare_time,coreml_load=capture.core_load,model_load=float(load[1])/1000 if load else None,cpu=float(ts[2])+float(ts[3]) if ts else None,rss=int(rss[1]) if rss else None,words=len(ref),errors=errors,wer=errors/len(ref),segments=seg,boundary_offsets=offsets,pre=pre,post=post,samples=samples,valid=rc==0 and bool(seg) and post['ps_ok'] and not post['builds'] and all(s['ps_ok'] and not s['builds'] for s in samples))
    if engine=='B' and 'Core ML model loaded' not in log: result['valid']=False
    result['boundary_alignment']=boundary_alignment(e,seg)
    record.write_text(json.dumps(result,indent=2))
    print(engine,e['id'],rep,'wall',round(wall,2),'WER',round(errors/len(ref),3),'valid',result['valid'],flush=True)
def run(engines):
    entries=json.loads((ROOT/'manifest.json').read_text())
    # First invocation is separated from steady state; never delete system caches.
    for engine in engines: run_one(engine,next(e for e in entries if e['kind']=='long'),'first')
    for rep in range(3):
        for index,e in enumerate(entries):
            shift=(index+rep)%len(engines)
            for engine in engines[shift:]+engines[:shift]: run_one(engine,e,rep)
def summarize():
    rows=[json.loads(p.read_text()) for p in (ROOT/'runs').glob('*/*/*/result.json')]
    summary=[]
    for engine in 'ABCD':
        for kind in ['short','long']:
            files=collections.defaultdict(list)
            for r in rows:
                if r['engine']==engine and r['kind']==kind and r['rep']!='first' and r['valid']: files[r['id']].append(r)
            complete=[v for v in files.values() if len(v)==3]
            if not complete: continue
            out=dict(engine=engine,kind=kind,files=len(complete),wer=sum(v[0]['errors'] for v in complete)/sum(v[0]['words'] for v in complete))
            for metric in ['wall','rtf','cpu','rss','first_caption','model_load','coreml_load','ready','prepare_time']:
                vals=[statistics.median(r[metric] for r in v if r[metric] is not None) for v in complete if all(r[metric] is not None for r in v)]
                out[metric]=statistics.median(vals) if vals else None
            offsets=[x for v in complete for x in v[0]['boundary_offsets']]
            out['boundary_median']=statistics.median(offsets) if offsets else None
            summary.append(out)
    (ROOT/'summary.json').write_text(json.dumps(summary,indent=2)); print(json.dumps(summary,indent=2))
if __name__=='__main__':
    parser=argparse.ArgumentParser(); parser.add_argument('action',choices=['prepare','run','summarize','quiet']); parser.add_argument('--engines',default='AB')
    args=parser.parse_args()
    if args.action=='prepare': prepare()
    elif args.action=='run': run(args.engines)
    elif args.action=='quiet': print(json.dumps(quiet_snapshot()))
    else: summarize()
