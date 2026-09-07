import pathlib,subprocess,json,hashlib
repo=pathlib.Path('/private/tmp/wam-wamkit');out=pathlib.Path('/private/tmp/wam-wamkit-scratch/defect/reverts');out.mkdir(exist_ok=True)
def run(cmd,name):
 with (out/(name+'.log')).open('w') as f:p=subprocess.run(cmd,cwd=repo/'build' if cmd[0]=='ctest' else repo,stdout=f,stderr=subprocess.STDOUT)
 return p.returncode
def build(name):return run(['cmake','--build','build','--parallel'],name)
def test(regex,name):return run(['ctest','-R',regex,'--output-on-failure'],name)
controls=[
 ('clock-requested','src/platform/macos/native_media_clock.cpp','    snapshot.requestedRate = state.rate;','', '^native_media_clock$'),
 ('metrics-requested','src/platform/macos/native_media_session.mm','std::memcpy(&rateBits, &clock.requestedRate, sizeof(rateBits));','std::memcpy(&rateBits, &clock.rate, sizeof(rateBits));','^macos_native_media_session$'),
 ('stop-cancellation','src/platform/macos/native_media_session.mm','impl_->dispatcherObserver->requestRetirementCancellation(cancellationGeneration);','impl_->dispatcherObserver->requestCancel(cancellationGeneration);','^macos_native_media_session$'),
 ('retirement-authority','src/media/native_media_dispatcher.cpp','''  if (retirement_cancellation_.load(std::memory_order_acquire) != 0) {
    return makeStep(NativeMediaDispatcherAction::Idle, NativeMediaDispatcherWait::Command);
  }''','','^native_media_dispatcher$'),
 ('cancellation-owner','src/platform/macos/avfoundation_media_source.mm',"""    auto readers = cancellationReaders.load();
    while (readers != 0) {
      cancellationReaders.wait(readers);
      readers = cancellationReaders.load();
    }""",'','^macos_avfoundation_reader_cancellation$'),
 ('reader-cancellation','src/platform/macos/avfoundation_media_source.mm',None,None,'^macos_avfoundation_reader_cancellation$')]
results=[]
for name,filename,old,new,regex in controls:
 p=repo/filename;original=p.read_bytes();r=dict(name=name,file=filename,sha256=hashlib.sha256(original).hexdigest())
 r['baseline_rc']=test(regex,name+'-baseline')
 if r['baseline_rc']:raise RuntimeError(r)
 try:
  if old is None:regressed=subprocess.check_output(['git','show','HEAD:'+filename],cwd=repo)
  else:
   assert original.decode().count(old)==1
   regressed=original.decode().replace(old,new).encode()
  p.write_bytes(regressed)
  r['regressed_build_rc']=build(name+'-regressed-build')
  if r['regressed_build_rc']:raise RuntimeError(r)
  r['regressed_test_rc']=test(regex,name+'-regressed-test')
 finally:
  p.write_bytes(original);r['byte_identical_restore']=p.read_bytes()==original
  r['restored_build_rc']=build(name+'-restored-build')
  r['restored_test_rc']=test(regex,name+'-restored-test') if not r['restored_build_rc'] else None
  results.append(r);(out/'results.json').write_text(json.dumps(results,indent=2)+'\n');print(json.dumps(r),flush=True)
 if not r['regressed_test_rc'] or r['restored_build_rc'] or r['restored_test_rc']:raise RuntimeError(r)
