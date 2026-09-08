#!/usr/bin/env python3
"""Offline inside-out signing of copied release inputs; never submits notarization."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import uuid

repo = Path(__file__).resolve().parents[1]
p = argparse.ArgumentParser()
p.add_argument('--build', type=Path, default=repo / 'build')
p.add_argument('--app', type=Path)
p.add_argument('--output', type=Path)
p.add_argument('--identity', default=os.environ.get('WAM_MACOS_CODESIGN_IDENTITY', ''))
p.add_argument('--ad-hoc', action='store_true')
p.add_argument('--if-identity', action='store_true')
a = p.parse_args()
if a.if_identity and not a.identity and not a.ad_hoc:
    print('Signing skipped: WAM_MACOS_CODESIGN_IDENTITY is absent')
    raise SystemExit(0)
identities = subprocess.check_output(['security', 'find-identity', '-v', '-p', 'codesigning'], text=True)
valid = re.findall(r'\b([0-9A-Fa-f]{40})\s+"(Developer ID Application:[^"]+)"', identities)
if a.ad_hoc:
    identity = '-'
else:
    matches = [(fingerprint, name) for fingerprint, name in valid
               if not a.identity or a.identity.lower() == fingerprint.lower() or a.identity == name]
    if len(matches) != 1:
        raise SystemExit('Obtain a Developer ID Application certificate with its private key in an unlocked keychain; select exactly one with --identity. Use --ad-hoc only for local verification.')
    identity = matches[0][0]
build = a.build.resolve()
output = (a.output or build / ('sign-release-' + str(uuid.uuid4()))).resolve()
if not (output.is_relative_to(repo / 'build') or output.is_relative_to(Path('/private/tmp/wam-wamkit-scratch'))):
    raise SystemExit('Signing output must be a fresh directory under build/ or the WAMKit scratch directory')
inputs = [build / 'src/wamkit/WAMKit.framework',
          build / 'examples/WAMKitHost/WAMKitHost.app',
          build / 'examples/WAMKitSwiftHost/WAMKitSwiftHost.app',
          (a.app or build / 'WAM.app').resolve()]
for source in inputs:
    if not source.is_dir(): raise SystemExit('Missing release input: ' + str(source))
output.mkdir(parents=True, exist_ok=False)
payload = output / 'payload'
payload.mkdir()
report = dict(mode='ad-hoc' if a.ad_hoc else 'Developer ID offline', identity=identity,
              timestamp='none (offline)', notarization_submitted=False, signed=[], assessments=[])
magic = {bytes.fromhex(x) for x in ['feedface','cefaedfe','feedfacf','cffaedfe','cafebabe','bebafeca','cafebabf','bfbafeca']}
def macho(path):
    if path.is_symlink() or not path.is_file(): return False
    with path.open('rb') as f: return f.read(4) in magic

def entitlement(path):
    if any(x.endswith('.appex') for x in path.parts):
        return repo / 'packaging/quicklook/WAMThumbnail.entitlements'
    return None

def sign(path):
    command = ['codesign', '--force', '--sign', identity, '--options', 'runtime', '--timestamp=none']
    ent = entitlement(path)
    if ent: command += ['--entitlements', str(ent)]
    subprocess.run(command + [str(path)], check=True)
    report['signed'].append(dict(path=str(path.relative_to(output)), entitlements=str(ent) if ent else None))

for source in inputs:
    dest = payload / source.name
    subprocess.run(['ditto', str(source), str(dest)], check=True)
    for image in sorted((x for x in dest.rglob('*') if macho(x)), key=lambda x: len(x.parts), reverse=True):
        sign(image)
    containers = [x for x in dest.rglob('*') if x.is_dir() and not x.is_symlink()
                  and x.suffix in {'.framework', '.app', '.appex', '.xpc', '.bundle'}]
    for container in sorted(containers, key=lambda x: len(x.parts), reverse=True): sign(container)
    sign(dest)
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(dest)], check=True)
    if dest.suffix == '.app':
        result = subprocess.run(['spctl', '--assess', '--type', 'execute', '--verbose=4', str(dest)],
                                text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        report['assessments'].append(dict(bundle=dest.name, rc=result.returncode, output=result.stdout))
archive = output / 'WAM-notarization-input.zip'
subprocess.run(['ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', str(payload), str(archive)], check=True)
with archive.open('rb') as f: report['archive_sha256'] = hashlib.file_digest(f, 'sha256').hexdigest()
report['distribution_ready'] = False
report['remaining'] = ('Developer ID identity, trusted timestamp, notarization and stapling' if a.ad_hoc
                       else 'Trusted timestamp, notarization and stapling')
(output / 'signing-report.json').write_text(json.dumps(report, indent=2) + '\n')
print(json.dumps(dict(output=str(output), archive=str(archive), mode=report['mode'],
                     strict_verification=True, distribution_ready=False, remaining=report['remaining'])))
