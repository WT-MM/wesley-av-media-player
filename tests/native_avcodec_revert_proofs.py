"""Temporary production mutations with byte-identical restoration and retained receipts."""
import argparse,hashlib,json,pathlib,subprocess,tempfile
parser=argparse.ArgumentParser();parser.add_argument('--output',required=True);args=parser.parse_args()
repo=pathlib.Path(__file__).resolve().parents[1];root=pathlib.Path(args.output);root.mkdir(parents=True,exist_ok=True)
prefix=repo/'third_party/ffmpeg-lgpl'
common=['clang++','-std=c++20','-O2','-I'+str(repo/'src'),'-I'+str(prefix/'include')]
link=['-L'+str(prefix/'lib'),'-lavcodec-wamnative','-lavutil-wamnative','-Wl,-rpath,'+str(prefix/'lib')]
worker='src/media/avcodec/decode_worker.cpp';audio='src/platform/macos/software_avcodec_audio_backend.cpp'
def build(kind):
    sources=[worker,'src/media/avcodec/runtime.cpp']
    flags=[]
    if kind=='audio':sources+=[audio,'tests/software_avcodec_audio_test.cpp'];flags=['-DWAM_AVCODEC_AUDIO_TESTING=1']
    elif kind=='worker':sources+=['tests/avcodec_worker_test.cpp']
    else:
        sources+=['src/media/video_codec_configuration.cpp','src/platform/macos/software_presentation_pool.mm',
                  'src/platform/macos/software_avcodec_video_decoder.mm','src/platform/macos/native_surface_budget.mm',
                  'src/platform/macos/native_video_presenter.mm','src/platform/macos/video_toolbox_decoder.mm',
                  'src/platform/macos/software_vp8_decoder.mm','src/platform/macos/native_video_codec_capability.mm',
                  'tests/software_avcodec_video_test.mm']
        flags=['-DWAM_ENABLE_AVCODEC_STAGE=1','-fobjc-arc','-framework','VideoToolbox','-framework','Foundation','-framework','CoreFoundation','-framework','CoreMedia',
               '-framework','CoreVideo','-framework','IOSurface']
    binary=root/kind
    command=common+flags+[str(repo/p) for p in sources]+link+['-o',str(binary)]
    built=subprocess.run(command,capture_output=True,text=True)
    if built.returncode:raise RuntimeError(built.stderr)
    return binary
fixtures=repo/'test-media/native-coverage/phase2'
def execute(binary,kind):
    if kind=='audio':argv=[str(binary),str(fixtures/'truehd.audio-packets'),str(fixtures/'truehd.f32'),'truehd']
    elif kind=='worker':argv=[str(binary),str(fixtures/'hi10p.packets'),'h264']
    else:
        specimen='asp' if kind=='video_asp' else 'hi10p'
        argv=[str(binary),str(fixtures/(specimen+'.packets')),specimen]
    result=subprocess.run(argv,capture_output=True,text=True,timeout=20)
    if result.returncode==-9:result=subprocess.run(argv,capture_output=True,text=True,timeout=20)
    return result
mutants=[
 ('ladder_order','src/media/native_decode_plan.hpp','DecodeImplementation::VideoToolboxHardware,\n  DecodeImplementation::VideoToolboxSoftware,','DecodeImplementation::VideoToolboxSoftware,\n  DecodeImplementation::VideoToolboxHardware,','worker'),
 ('owned_packet',worker,'std::memcpy(slot.bytes.get(), bytes.data(), bytes.size());','std::memset(slot.bytes.get(), 0, bytes.size());','worker'),
 ('frame_pts',worker,'timing.pts = *exact;','timing.pts = MediaTime{0,1};','worker'),
 ('generation',worker,'timing.generation != s.configuration.generation || timing.epoch != s.configuration.epoch','false','worker'),
 ('drain',worker,'if (avcodec_send_packet(context, nullptr) < 0)','if (0 < 0)','worker'),
 ('frame_preservation',worker,'if (result == FrameResult::Backpressure) { signal.wait(observed); continue; }','if (result == FrameResult::Backpressure) { av_frame_unref(frame); retainedFrame=false; continue; }','worker'),
 ('planar_float',audio,'s.slab[f*channels+c]=sample(source,packed);','s.slab[f*channels+c]=0;','audio'),
 ('packet_release',audio,'result.finalInputReleased=!input.packets.empty() && result.consumedPackets==input.packets.size();','result.finalInputReleased=false;','audio'),
 ('audio_piece_offset',audio,'s.slabFrames=count;s.offset+=count;','s.slabFrames=count;s.offset=0;','audio'),
 ('video_lane','src/platform/macos/video_decode_lane.hpp','avcodec_ = std::make_unique<SoftwareAvcodecVideoDecoder>(options_);','return false;','video_asp'),
 ('p010_bits','src/platform/macos/software_presentation_pool.mm','value=std::uint16_t(value<<6);','value=std::uint16_t(value);','video'),
 ('software_sps','src/media/video_codec_configuration.cpp','!(limits.admitSoftwareProfiles && (profile == 110U || profile == 122U))','true','video'),
]
receipts=[]
for name,relative,before,after,kind in mutants:
    path=repo/relative;original=path.read_bytes();text=original.decode()
    if before not in text:raise RuntimeError('mutation anchor missing: '+name)
    clean=execute(build(kind),kind)
    if clean.returncode:raise RuntimeError('baseline failed: '+name+' '+clean.stderr)
    try:
        path.write_text(text.replace(before,after))
        result=execute(build(kind),kind)
        receipt=dict(name=name,path=relative,returncode=result.returncode,stdout=result.stdout,stderr=result.stderr,
                     killed=result.returncode not in [0,-9],before_sha256=hashlib.sha256(original).hexdigest())
    finally:
        path.write_bytes(original)
        assert path.read_bytes()==original
    receipt['restored_sha256']=hashlib.sha256(path.read_bytes()).hexdigest()
    receipts.append(receipt);(root/'results.json').write_text(json.dumps(receipts,indent=2)+'\n');print(name,receipt['killed'],flush=True)
    if not receipt['killed']:raise RuntimeError('mutation survived or environmental: '+name)
for kind in ['worker','audio','video']:
    result=execute(build(kind),kind)
    if result.returncode:raise RuntimeError('restored baseline failed: '+kind+' '+result.stderr)
