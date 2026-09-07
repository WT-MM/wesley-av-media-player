"""Exercise the real loader from isolated directories without changing the SDK."""
import argparse
import json
import pathlib
import shutil
import subprocess
import tempfile

p = argparse.ArgumentParser()
p.add_argument('--binary', required=True)
p.add_argument('--libraries', required=True)
p.add_argument('--output')
a = p.parse_args()
results = []
with tempfile.TemporaryDirectory(prefix='wam-avcodec-runtime-', dir='/private/tmp') as scratch:
    root = pathlib.Path(scratch)
    binary = root / 'runtime-test'
    shutil.copy2(a.binary, binary)
    libs = root / 'native-codecs'
    libs.mkdir()
    def check(name, refusal=None):
        command = [str(binary)] + ([refusal] if refusal else [])
        r = subprocess.run(command, capture_output=True, text=True, timeout=15)
        if r.returncode == -9:
            r = subprocess.run(command, capture_output=True, text=True, timeout=15)
        results.append(dict(case=name, rc=r.returncode, stdout=r.stdout, stderr=r.stderr))
        assert r.returncode == 0, results[-1]
    check('missing', 'DecoderStageNotBuilt')
    for name in ['libavcodec-wamnative.63.dylib', 'libavutil-wamnative.61.dylib']:
        shutil.copy2(pathlib.Path(a.libraries) / name, libs / name)
    check('relocated')
    macos = root / 'Relocated.app/Contents/MacOS'
    macos.mkdir(parents=True)
    bundle_binary = macos / 'WAM'
    shutil.copy2(binary, bundle_binary)
    shutil.copytree(libs, macos.parent / 'Frameworks')
    standalone_binary = binary
    binary = bundle_binary
    check('bundle-layout-relocation')
    binary = standalone_binary
    util = libs / 'libavutil-wamnative.61.dylib'
    outside = root / util.name
    util.rename(outside)
    util.symlink_to(outside)
    check('external-symlink', 'DecoderUnavailable: native FFmpeg library outside bundle')
    util.unlink()
    outside.rename(util)
    (libs / 'libavcodec-wamnative.63.dylib').write_bytes(b'not a Mach-O library\n')
    check('replaced', 'DecoderUnavailable')
text = json.dumps(results, indent=2) + '\n'
if a.output:
    pathlib.Path(a.output).write_text(text)
print(text)
