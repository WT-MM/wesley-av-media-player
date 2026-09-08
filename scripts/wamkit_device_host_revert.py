#!/usr/bin/env python3
from pathlib import Path
import subprocess
import json
import hashlib
repo = Path(__file__).resolve().parents[1]
p = repo/'src/platform/macos/native_audio_output.mm'
proof = repo/'docs/wamkit/proofs/continuation'
original = p.read_bytes()
head = subprocess.check_output(['git','show','HEAD:src/platform/macos/native_audio_output.mm'], cwd=repo)
marker = b'NativeAudioOutputProgress NativeAudioOutput::activate('
start = original.index(marker)
seam_start = original.index(b'  if (nativeAudioDeviceRecovery', start)
seam_end = original.index(b'  // Generation activation', seam_start)
end = original.index(b'NativeAudioOutputProgress NativeAudioOutput::start()', start)
a = head.index(marker); b = head.index(b'NativeAudioOutputProgress NativeAudioOutput::start()', a)
body = head[a:b]; insert = body.index(b'  if (!configured_')
body = body[:insert] + original[seam_start:seam_end] + body[insert:]
results = {}
def run(name, cmd):
    with (proof/name).open('w') as log:
        return subprocess.run(cmd,cwd=repo,stdout=log,stderr=log).returncode
try:
    p.write_bytes(original[:start]+body+original[end:])
    results['baseline_build_rc']=run('device-host-baseline-build.log',['cmake','--build','build','--parallel'])
    if results['baseline_build_rc']==0:
        results['baseline_test_rc']=run('device-host-baseline.log',['ctest','--test-dir','build','-R','^wamkit_host_recovery$','--output-on-failure'])
finally:
    p.write_bytes(original)
    results['restored_build_rc']=run('device-host-restored-build.log',['cmake','--build','build','--parallel'])
results['restored_sha256']=hashlib.sha256(p.read_bytes()).hexdigest()
results['restored_test_rc']=run('device-host-restored.log',['ctest','--test-dir','build','-R','^wamkit_host_recovery$','--output-on-failure'])
(proof/'device-host-revert.json').write_text(json.dumps(results,indent=2)+'\n')
assert results.get('baseline_build_rc')==0 and results.get('baseline_test_rc')!=0 and results['restored_build_rc']==0 and results['restored_test_rc']==0
