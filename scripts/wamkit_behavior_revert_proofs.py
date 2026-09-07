#!/usr/bin/env python3
"""Buildable negative controls; restore every changed byte before continuing."""
import argparse,hashlib,json,pathlib,subprocess
p=argparse.ArgumentParser();p.add_argument('--case',required=True);p.add_argument('--output',type=pathlib.Path,required=True);a=p.parse_args()
repo=pathlib.Path(__file__).resolve().parents[1];a.output.mkdir(parents=True,exist_ok=False)
cases={
 'framework-copy':('examples/WAMKitHost/CMakeLists.txt','COMMAND /usr/bin/ditto','COMMAND ${CMAKE_COMMAND} -E copy_directory','wamkit_host_packaging'),
 'replacement':('src/wamkit/wamkit.mm','snapshot.first_pts={};','','wamkit_host_replace'),
 'host-time':('examples/WAMKitHost/main.m','static wam_time_t parseTime(NSString *text) {','static wam_time_t parseTime(NSString *text) { return (wam_time_t){0};','wamkit_host_api'),
 'quarantine':('src/wamkit/wamkit.mm','self->finish(self->stopping,WAM_QUARANTINED);','self->finish(self->stopping,WAM_COMPLETED);','wamkit_host_quarantine'),
 'paused-scheduler':('src/platform/macos/native_video_consumer.mm','const bool exactPaused = !currentClock->running && currentClock->exactPausedTarget.valid();','const bool exactPaused = false;','macos_native_video_consumer'),
 'exact-clock':('src/platform/macos/native_media_clock.cpp','  next.exactAnchor = *canonical;','  next.exactAnchor = {};','native_exact_embedding_time'),
 'audio-proof':('src/platform/macos/native_audio_render_core.cpp','  cached_paused_clock_.exactPausedTarget = pausedClockPosition;','  cached_paused_clock_.exactPausedTarget = {};','native_audio_render_core'),
 'rational-session':('src/platform/macos/native_media_session.mm','      rationalCommit = publishedCommit->rational;','      rationalCommit = false;','macos_native_media_session'),
 'rational-router':('src/media/playback_router.cpp','      exactCommitTarget_.has_value() ||\n','', 'playback_router'),
 'exact-target-retention':('src/platform/macos/native_playback_owner.mm','  nativeExactCommitTarget_ = exact;','  nativeExactCommitTarget_.reset();','wamkit_host_mp4'),
 'first-draw':('src/platform/macos/native_video_consumer.mm','if (drawnFrames == 0) firstDrawPts =','if (false) firstDrawPts =','macos_native_video_consumer'),
 'refusal':('src/wamkit/wamkit.mm','refusal=errorValue(diagnostic.name.data(),diagnostic.detail.data());','refusal=errorValue("UnsupportedContainer");','wamkit_host_refusal'),
 'backpressure':('src/wamkit/wamkit.mm','if (outstanding>=32 ||','if (outstanding>=33 ||','wamkit_host_api'),
 'view':('src/platform/macos/native_layer_host_view.mm','NativeLayerHostView::createDetached(\n    double width, double height, std::string* error) {','NativeLayerHostView::createDetached(\n    double width, double height, std::string* error) {\n  return {};','native_layer_embedding'),
 'relocation':('src/media/avcodec/library_directory.hpp','if (path.filename() == "WAMKit") return path.parent_path() / "Frameworks";','if (false) return path.parent_path() / "Frameworks";','wamkit_host_refusal'),
}
path,old,new,test=cases[a.case];file=repo/path;original=file.read_bytes();text=original.decode();assert old in text,(a.case,old)
receipt={'case':a.case,'path':path,'test':test,'sha256':hashlib.sha256(original).hexdigest()}
def run(label,args,cwd=repo):
 with (a.output/(label+'.log')).open('w') as log:return subprocess.run(args,cwd=cwd,stdout=log,stderr=subprocess.STDOUT).returncode
def check(label):return run(label,['ctest','--output-on-failure','-R','^'+test+'$'],repo/'build')
try:
 receipt['baseline_rc']=check('baseline');assert receipt['baseline_rc']==0
 changed=text.replace(old,new)
 if a.case=='framework-copy':changed=changed.replace('COMMAND codesign --verify --deep --strict "$<TARGET_BUNDLE_DIR:WAMKitHost>"','COMMAND ${CMAKE_COMMAND} -E true')
 file.write_text(changed);receipt['reverted_build_rc']=run('reverted-build',['cmake','--build','build','--parallel'])
 assert receipt['reverted_build_rc']==0,'negative control must build'
 receipt['reverted_test_rc']=check('reverted-test');assert receipt['reverted_test_rc']!=0,'negative control must fail'
finally:
 file.write_bytes(original);receipt['byte_identical_restore']=file.read_bytes()==original
 receipt['restored_build_rc']=run('restored-build',['cmake','--build','build','--parallel'])
 receipt['restored_test_rc']=check('restored-test')
 (a.output/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
print(json.dumps(receipt),flush=True)
assert receipt['byte_identical_restore'] and receipt['restored_build_rc']==0 and receipt['restored_test_rc']==0
