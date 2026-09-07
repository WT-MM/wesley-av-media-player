"""Compile isolated production mutants; the workspace is never temporarily edited."""
import argparse,hashlib,json,pathlib,shutil,subprocess,tempfile
p=argparse.ArgumentParser();p.add_argument('--output',required=True);a=p.parse_args()
repo=pathlib.Path(__file__).resolve().parents[1];root=pathlib.Path(a.output);root.mkdir(parents=True,exist_ok=True)
rows=[]
with tempfile.TemporaryDirectory(prefix='wam-avformat-mutants-',dir='/private/tmp') as scratch:
 work=pathlib.Path(scratch);(work/'native-codecs').mkdir()
 for name in ['libavcodec-wamnative.63.dylib','libavutil-wamnative.61.dylib','libavformat-wamnative.63.dylib']:
  shutil.copy2(repo/'third_party/ffmpeg-lgpl/lib'/name,work/'native-codecs'/name)
 frameworks=['CoreFoundation','CoreGraphics','CoreMedia','CoreVideo','Foundation','IOSurface','AudioToolbox','CoreAudio','AVFoundation','VideoToolbox']
 flags=['clang++','-std=c++20','-O2','-fobjc-arc','-DWAM_ENABLE_AVFORMAT_STAGE=1','-DWAM_ENABLE_AVCODEC_STAGE=1','-I'+str(repo/'src'),'-I'+str(repo/'src/platform/macos'),'-I'+str(repo/'third_party/ffmpeg-lgpl/include')]
 libs=[str(repo/'build'/name) for name in ['libwam_macos_native_backend.a','libwam_macos_native_video_core.a','libwam_native_core.a','libwam_avcodec_worker.a']]+['/opt/homebrew/lib/libvpx.dylib']
 for framework in frameworks:libs+=['-framework',framework]
 cursor='src/media/libavformat_cursor.cpp';source='src/platform/macos/libavformat_media_source.mm';routing='src/platform/macos/routed_media_source.mm'
 mutants=[
 ('stage_removed',source,'  if(!s.reader->cursor.open(path,s.cancellation(),out.error)) return fail();','  out.error="StageRemoved"; return fail();','fragmented.mp4'),
 ('tail_recovery',cursor,'if (!s.inspectTail(error) || !s.load(error))','if (!s.load(error))','mid-mdat.mp4'),
 ('missing_initialization',cursor,'if (!init) { error=','if (false && !init) { error=','missing-init.mp4'),
 ('packet_pts',cursor,'stamp(p.pts,out.pts)','stamp(p.pts==AV_NOPTS_VALUE?p.pts:p.pts+1,out.pts)','fragmented.mp4'),
 ('matroska_unknown_dts',cursor,'if(std::strstr(s.format->iformat->name,"matroska")) out.dts={};','','mkv-differential'),
 ('seek_head',source,'decodeStart=preceding(*context,target);','decodeStart=target;','fragmented.mp4'),
 ('cancel_identity',source,'return active && cancelled.load(std::memory_order_acquire)==active;','return false;','fragmented.mp4'),
 ('preview_binding',source,'return std::make_unique<Preview>(std::move(context));','return {};','fragmented.mp4'),
 ('payload_retention',source,'return slot.use_count() == 1;','return true;','fragmented.mp4'),
 ('file_growth',cursor,'if (!s.sameFile())','if (false)','fragmented.mp4'),
 ('preview_file_identity',source,'if (reader_->cursor.identity() != context_->identity)','if (false)','fragmented.mp4'),
 ('preview_decoder_stage','src/platform/macos/native_preview_frame_lane.mm','using PreviewDecoder=VideoDecodeLane;','using PreviewDecoder=VideoToolboxDecoder;','asp-preview'),
 ('fragment_recovery_routing',routing,'media::LibavformatCursor::requiresTailRecovery(path,cancellation)','false','routed-tail'),
 ('admission_handoff',routing,'outcome=sources_[3]->openLocalFile(path,options,generation);','outcome.error="HandoffRemoved";','header-stripped.mkv'),
 ]
 for name,relative,before,after,specimen in mutants:
  original=(repo/relative).read_bytes();text=original.decode()
  positions=[i for i,c in enumerate(text) if not c.isspace()]
  compact=''.join(text[i] for i in positions);needle=''.join(before.split())
  start=compact.find(needle);assert start>=0,name
  changed=work/('mutation'+pathlib.Path(relative).suffix)
  changed.write_text(text[:positions[start]]+after+text[positions[start+len(needle)-1]+1:])
  differential=specimen=='mkv-differential'
  test=repo/'tests'/('libavformat_preview_decode_test.mm' if specimen=='asp-preview' else 'libavformat_differential_test.cpp' if differential else 'libavformat_source_test.mm')
  binary=work/'proof';command=flags+[str(changed),str(test),*libs,'-o',str(binary)]
  build=subprocess.run(command,capture_output=True,text=True,timeout=120)
  assert build.returncode==0,(name,build.stderr)
  if differential:argv=[str(binary),str(repo/'test-media/native-coverage/phase3/oracle.mkv'),'mkv']
  elif specimen=='asp-preview':argv=[str(binary),str(repo/'test-media/native-coverage/phase3/asp.avi')]
  else:
   expected='this recording is incomplete: its initialization metadata is missing' if specimen=='missing-init.mp4' else 'ready'
   argv=[str(binary),str(repo/'test-media/native-coverage/phase3'/('mid-mdat.mp4' if specimen=='routed-tail' else specimen)),expected]
   if specimen in ['header-stripped.mkv','routed-tail']:argv+=['routed']
  result=subprocess.run(argv,capture_output=True,text=True,timeout=30)
  if result.returncode==-9:result=subprocess.run(argv,capture_output=True,text=True,timeout=30)
  receipt=dict(name=name,path=relative,source_sha256=hashlib.sha256(original).hexdigest(),rc=result.returncode,stdout=result.stdout,stderr=result.stderr,killed=result.returncode not in [0,-9])
  assert (repo/relative).read_bytes()==original
  rows.append(receipt);(root/'revert-proofs.json').write_text(json.dumps(rows,indent=2)+'\n');print(name,receipt['killed'],flush=True)
  assert receipt['killed'],name
