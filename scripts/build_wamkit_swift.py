#!/usr/bin/env python3
"""Assemble the local arm64 binary package and build its SwiftUI consumer offline."""
import argparse
import os
from pathlib import Path
import plistlib
import shutil
import subprocess

p = argparse.ArgumentParser()
p.add_argument('--framework', type=Path, required=True)
p.add_argument('--build', type=Path, required=True)
a = p.parse_args()
repo = Path(__file__).resolve().parents[1]
build = a.build.resolve()
framework = a.framework.resolve()
xc = repo / 'build/WAMKit.xcframework'
xc.parent.mkdir(parents=True, exist_ok=True)
if xc.exists(): shutil.rmtree(xc)
subprocess.run(['xcodebuild', '-create-xcframework', '-framework', str(framework),
                '-output', str(xc)], check=True)
scratch = Path('/private/tmp/wam-wamkit-scratch/swift')
scratch.mkdir(parents=True, exist_ok=True)
env = os.environ.copy()
env['CLANG_MODULE_CACHE_PATH'] = str(scratch / 'modules')
subprocess.run(['swift', 'build', '--package-path', str(repo), '--scratch-path',
                str(build / 'swift-package'), '--cache-path', str(scratch / 'cache'),
                '--manifest-cache', 'local', '--disable-sandbox', '--skip-update',
                '-c', 'release', '--arch', 'arm64', '--product', 'WAMKitSwiftHost'],
               env=env, check=True)
app = build / 'examples/WAMKitSwiftHost/WAMKitSwiftHost.app'
contents = app / 'Contents'
(contents / 'MacOS').mkdir(parents=True, exist_ok=True)
(contents / 'Frameworks').mkdir(exist_ok=True)
shutil.copy2(build / 'swift-package/arm64-apple-macosx/release/WAMKitSwiftHost',
             contents / 'MacOS/WAMKitSwiftHost')
embedded = contents / 'Frameworks/WAMKit.framework'
if embedded.exists(): shutil.rmtree(embedded)
subprocess.run(['ditto', str(framework), str(embedded)], check=True)
with (contents / 'Info.plist').open('wb') as f:
    plistlib.dump(dict(CFBundleExecutable='WAMKitSwiftHost',
                      CFBundleIdentifier='org.wam.WAMKitSwiftHost',
                      CFBundleName='WAMKit Swift Host', CFBundlePackageType='APPL',
                      CFBundleVersion='1', CFBundleShortVersionString='1.0',
                      LSMinimumSystemVersion='26.0', NSHighResolutionCapable=True), f)
subprocess.run(['install_name_tool', '-add_rpath', '@executable_path/../Frameworks',
                str(contents / 'MacOS/WAMKitSwiftHost')], check=True)
subprocess.run(['codesign', '--force', '--sign', '-', str(app)], check=True)
subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
print(app)
