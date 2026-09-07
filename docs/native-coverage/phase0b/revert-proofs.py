from pathlib import Path
import subprocess,hashlib,json
repo=Path.cwd(); root=Path('/private/tmp/wam-phase0b/mutations');root.mkdir(exist_ok=True)
results=json.loads((root/'results.json').read_text()) if (root/'results.json').exists() else []
def execute(argv,log):
 with log.open('w') as f:
  p=subprocess.run(argv,stdout=f,stderr=subprocess.STDOUT)
 if p.returncode in (-9,137):
  with log.open('a') as f:p=subprocess.run(argv,stdout=f,stderr=subprocess.STDOUT)
 return p.returncode

def source(name,path,target=None,expected=True,phrase=None):
 args=['build/wam_native_coverage_source_probe',str(path)]+([] if target is None else [str(target)])
 code='import subprocess,sys; p=subprocess.run(sys.argv[1:],capture_output=True,text=True); print(p.stdout,p.stderr); assert '+('p.returncode==0' if expected else 'p.returncode==1')+(' and '+repr(phrase)+' in p.stdout' if phrase else '')
 return (name,['python3','-c',code,*args])

def group(name,file,mutation,targets,checks,compile_failure=False):
 if any(r["group"]==name for r in results): return
 p=repo/file; original=p.read_bytes(); digest=hashlib.sha256(original).hexdigest()
 changed=mutation(original.decode()).encode();assert changed!=original,name
 record=dict(group=name,file=file,sha256=digest,tests=[])
 for label,argv in checks:
  assert execute(argv,root/(name+'-'+label+'.baseline.log'))==0,(name,label,'baseline')
 try:
  p.write_bytes(changed)
  rc=execute(['cmake','--build','build','--parallel','--target',*targets],root/(name+'.build.log')) if targets else 0
  if compile_failure:
   assert rc!=0,(name,'expected static assertion')
   record['compile_invariant_failed']=True
  else:
   assert rc==0,(name,'build failure')
   for label,argv in checks:
    rc=execute(argv,root/(name+'-'+label+'.reverted.log'))
    assert rc!=0,(name,label,'survived')
    record['tests'].append(dict(name=label,reverted_rc=rc))
 finally:
  p.write_bytes(original)
  assert p.read_bytes()==original
  assert (execute(['cmake','--build','build','--parallel','--target',*targets],root/(name+'.restore-build.log')) if targets else 0)==0,(name,'restore')
 for label,argv in checks:
  assert execute(argv,root/(name+'-'+label+'.restored.log'))==0,(name,label,'restored')
 record['byte_identical_restore']=True;results.append(record)
 (root/'results.json').write_text(json.dumps(results,indent=2));print(name,'PASS',flush=True)

def old(file):
 return lambda s:subprocess.check_output(['git','show','HEAD:'+file]).decode()
def replace(before,after):
 def apply(s):
  assert before in s,before
  return s.replace(before,after,1)
 return apply
A=Path('/private/tmp/wam-coverage'); P=Path('/private/tmp/wam-phase0b')
f='src/platform/macos/avfoundation_media_source.mm'
checks=[source(x,A/(x+'.mov')) for x in ['prores4444','prores4444xq','hevc422-hvc1']]
checks += [source('vp9p2',P/'profiles/vp9p2.mp4'),source('seek30',P/'single-gop.mp4',30)]
checks += [source(x,A/(x+'.m4a'),expected=False,phrase='HeAacSbrDecoderDelayUnproven') for x in ['he-aac','he-aacv2']]
group('avfoundation-admission',f,old(f),['wam_native_coverage_source_probe'],checks)
f='src/media/matroska_demuxer.cpp'
checks=[source(x,P/'audio-integrated'/(x+'.mka')) for x in ['alac','pcm_s16le','pcm_f32le','adpcm_ima_wav','adpcm_ms']]
checks += [('random-access',['build/wam_matroska_demuxer_test'])]
group('matroska-admission',f,old(f),['wam_native_coverage_source_probe','wam_matroska_demuxer_test'],checks)
f='src/platform/macos/native_audio_converter.mm'
group('slow-audio',f,old(f),['wam_native_coverage_audio_probe'],[('origin30',['python3','tests/native_coverage_integration.py','--audio','build/wam_native_coverage_audio_probe','--source','build/wam_native_coverage_source_probe','--ffmpeg','/opt/homebrew/bin/ffmpeg','--case','slow-audio'])])
for name,file,target in [('dispatcher','src/media/native_media_dispatcher.cpp','wam_native_media_dispatcher_test'),('router','src/media/playback_router.cpp','wam_playback_router_test'),('session','src/platform/macos/native_media_session.mm','wam_native_media_session_test')]:
 group(name,file,old(file),[target],[(name,['build/'+target])])
f='src/platform/macos/avfoundation_preview_source.mm'
check=('preview30',['python3','-c','import subprocess; p=subprocess.run(["build/wam_native_coverage_source_probe","/private/tmp/wam-phase0b/single-gop.mp4","30","preview"]); assert p.returncode==0'])
group('preview',f,old(f),['wam_native_coverage_source_probe'],[check])
f='src/platform/macos/video_toolbox_decoder.mm'
group('pixel-request',f,replace('return kCVPixelFormatType_30RGBLEPackedWideGamut;','return kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange;'),['wam_video_toolbox_decoder_test'],[('opaque4444',['build/wam_video_toolbox_decoder_test','--limits-only'])])
f='src/platform/macos/native_presentation_admission.hpp'
group('scenegraph422',f,replace('    if (media::mediaSampleFormatIs422(video.sampleFormat)) {\n      return "SceneGraph422Unsupported";\n    }',''),['wam_native_video_consumer_test'],[('refusal',['build/wam_native_video_consumer_test'])])
group('scenegraph4444',f,replace('    if (!output.presentsDecodedSurfacesDirectly()) return "SceneGraphProRes4444OpaqueUnsupported";',''),['wam_native_video_consumer_test'],[('refusal',['build/wam_native_video_consumer_test'])])
f='src/media/native_seek_progress.hpp'
group('progress',f,replace('if (frames != decodedFrames)', 'if (false)'),['wam_native_coverage_admission_test'],[('inactivity',['build/wam_native_coverage_admission_test'])])
f='src/platform/macos/native_surface_budget.hpp'
group('surface-ceiling',f,replace('384ULL * 1024ULL * 1024ULL','288ULL * 1024ULL * 1024ULL'),['wam_native_surface_budget_test'],[],True)
f='src/qt/native_playback_owner.mm'
group('owner-progress',f,replace('nativeSeekProgress_.expired(progress.decodedPrerollFrames)','nativeSeekProgress_.expired(0)'),[],[('wiring',['python3','tests/native_coverage_wiring_test.py',str(repo)])])
f='src/media/video_codec_configuration.cpp'
group('hevc422-configuration',f,old(f),['wam_native_coverage_source_probe'],[source('hevc422',A/'hevc422-hvc1.mov')])
f='src/platform/macos/matroska_sample_builder.mm'
group('pcm-sample-builder',f,old(f),['wam_native_coverage_audio_probe'],[('packed-frames',['build/wam_native_coverage_audio_probe',str(P/'audio-integrated/pcm_s16le.mka'),str(P/'mutation-pcm.f32'),'0'])])
f='src/platform/macos/matroska_media_source.mm'
group('pcm-frame-count',f,old(f),['wam_native_coverage_audio_probe'],[('sample-count',['build/wam_native_coverage_audio_probe',str(P/'audio-integrated/pcm_s16le.mka'),str(P/'mutation-pcm.f32'),'0'])])
f='src/media/matroska_demuxer.cpp'
group('he-aac-matroska-name',f,replace('result.message = aacSbrSignaled(configuration)','result.message = false'),['wam_native_coverage_source_probe'],[source('he-name',A/'he-aac.m4a.mka',expected=False,phrase='HeAacSbrDecoderDelayUnproven')])
f='src/platform/macos/native_media_session.mm'
group('slow30-supersession',f,old(f),['wam_native_media_session_test'],[('generation',['build/wam_native_media_session_test'])])
f='src/platform/macos/video_toolbox_decoder.mm'
group('unproved-packed422',f,replace('  const OSType fullRange = fullRangeCounterpartFormat(expectedPixelFormat);','  if (expectedPixelFormat == kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange && pixelFormat == 0x70343232U) return true;\n  const OSType fullRange = fullRangeCounterpartFormat(expectedPixelFormat);'),['wam_video_toolbox_decoder_test'],[('named-output-contract',['build/wam_video_toolbox_decoder_test','--limits-only'])])
