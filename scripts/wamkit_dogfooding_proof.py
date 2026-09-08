#!/usr/bin/env python3
from pathlib import Path
import json
import subprocess
import tempfile

repo=Path(__file__).resolve().parents[1]
proof=repo/'docs/wamkit/proofs/continuation'
checker=repo/'tests/wamkit_dogfooding_test.py'
results={}
with tempfile.TemporaryDirectory(dir='/private/tmp/wam-wamkit-scratch',prefix='dogfood-') as directory:
    root=Path(directory)
    names=subprocess.check_output(['git','ls-tree','-r','--name-only','HEAD','src/qt'],cwd=repo,text=True).splitlines()
    for name in names:
        p=root/name;p.parent.mkdir(parents=True,exist_ok=True)
        p.write_bytes(subprocess.check_output(['git','show','HEAD:'+name],cwd=repo))
    baseline=subprocess.run(['python3',str(checker),'--root',str(root)],capture_output=True,text=True)
    (proof/'dogfooding-baseline.log').write_text(baseline.stdout+baseline.stderr)
    results['head_baseline_rc']=baseline.returncode
with tempfile.TemporaryDirectory(dir='/private/tmp/wam-wamkit-scratch',prefix='dogfood-') as directory:
    root=Path(directory);target=root/'src/qt/probe.cpp';target.parent.mkdir(parents=True)
    for name,source in {
        'public_owner':'#include "platform/macos/native_playback_owner.hpp"\n',
        'internal_include':'#include "platform/macos/native_audio_session.hpp"\n',
        'relative_include':'#import "../platform/macos/native_media_session.hpp"\n',
        'session_access':'void f() { nativeSession_->stop(); }\n'
    }.items():
        target.write_text(source)
        result=subprocess.run(['python3',str(checker),'--root',str(root)],capture_output=True,text=True)
        results[name]=dict(rc=result.returncode,output=result.stdout+result.stderr)
results['current_rc']=subprocess.run(['python3',str(checker)],cwd=repo).returncode
(proof/'dogfooding-negative.json').write_text(json.dumps(results,indent=2)+'\n')
assert results['head_baseline_rc']!=0 and results['current_rc']==0
assert results['public_owner']['rc']==0
assert all(results[name]['rc']!=0 for name in ['internal_include','relative_include','session_access'])
