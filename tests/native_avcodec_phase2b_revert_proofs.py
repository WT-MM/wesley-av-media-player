"""Behavioral rollback probes for phase-2b additions, restoring original bytes."""
import argparse,hashlib,json,pathlib,shutil,subprocess
p=argparse.ArgumentParser();p.add_argument('--output',required=True);a=p.parse_args()
repo=pathlib.Path(__file__).resolve().parents[1];root=pathlib.Path(a.output);root.mkdir(parents=True,exist_ok=True)
prefix=repo/'third_party/ffmpeg-lgpl';(root/'native-codecs').mkdir(exist_ok=True)
for name in ['libavcodec-wamnative.63.dylib','libavutil-wamnative.61.dylib']:shutil.copy2(prefix/'lib'/name,root/'native-codecs'/name)
common=['clang++','-std=c++20','-O2','-I'+str(repo/'src'),'-I'+str(prefix/'include')]
fixtures=repo/'test-media/native-coverage/phase2'
def build(kind):
 sources=['src/media/avcodec/runtime.cpp'];flags=[]
 if kind=='runtime':sources+=['tests/avcodec_runtime_test.cpp']
 else:
  sources+=['src/media/avcodec/decode_worker.cpp']
  if kind=='budget':sources+=['tests/avcodec_worker_budget_test.cpp']
  else:
   sources+=['src/platform/macos/software_avcodec_audio_backend.cpp','src/media/audio_downmix.cpp','tests/software_avcodec_audio_test.cpp'];flags=['-DWAM_AVCODEC_AUDIO_TESTING=1']
 binary=root/kind
 r=subprocess.run(common+flags+[str(repo/x) for x in sources]+['-o',str(binary)],capture_output=True,text=True)
 assert r.returncode==0,r.stderr
 return binary
def run(binary,kind):
 args=[str(binary)]
 if kind=='audio':args += [str(fixtures/'truehd51.audio-packets'),str(fixtures/'truehd51.f32'),'truehd51','6',str(fixtures/'truehd51.stereo.f32')]
 r=subprocess.run(args,capture_output=True,text=True,timeout=30)
 if r.returncode==-9:r=subprocess.run(args,capture_output=True,text=True,timeout=30)
 return r
cases=[
 ('runtime_lease_retirement','src/media/avcodec/runtime.cpp','if (!--leases) unload();','--leases;','runtime'),
 ('worker_admission','src/media/avcodec/decode_worker.cpp','constexpr unsigned kMaximumWorkers = macos::kNativeSoftwareProcessWorkers;','constexpr unsigned kMaximumWorkers = macos::kNativeSoftwareProcessWorkers + 1;','budget'),
 ('representation','src/platform/macos/software_avcodec_audio_backend.cpp','config.decodePlan.configurationRepresentation != media::DecodeConfigurationRepresentation::RawExtradata ||','false ||','audio'),
 ('decoded_center_role','src/platform/macos/software_avcodec_audio_backend.cpp','case AV_CHAN_FRONT_CENTER:return R::Center;','case AV_CHAN_FRONT_CENTER:return R::LowFrequency;','audio'),
]
rows=[]
for name,file,before,after,kind in cases:
 path=repo/file;original=path.read_bytes();text=original.decode();assert text.count(before)==1,name
 clean=run(build(kind),kind);assert clean.returncode==0,(name,clean.stderr)
 try:
  path.write_text(text.replace(before,after));result=run(build(kind),kind)
  assert result.returncode not in [0,-9],(name,result.stdout,result.stderr)
 finally:path.write_bytes(original)
 assert path.read_bytes()==original
 restored=run(build(kind),kind);assert restored.returncode==0,(name,restored.stderr)
 rows.append(dict(name=name,path=file,killed=True,rc=result.returncode,stdout=result.stdout,stderr=result.stderr,before_sha256=hashlib.sha256(original).hexdigest(),restored_sha256=hashlib.sha256(path.read_bytes()).hexdigest()))
 (root/'results.json').write_text(json.dumps(rows,indent=2)+'\n');print(name,True,flush=True)
