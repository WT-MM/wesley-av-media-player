#!/usr/bin/env python3
"""Audit Qt's source boundary to the shared native owner and host policy API."""
import argparse
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
SHARED = {'native_playback_owner.hpp', 'native_open_preflight.hpp', 'native_embedding_support.hpp'}
# src/qt/macos holds the Qt presentation adapters over the native video
# outputs; they own no native session, so they may include the output headers.
PRESENTATION = 'src/qt/macos'
BYPASS = re.compile(r'\b(nativeSession_|observationBridge_|NativeMediaSession|NativeAudioSession|NativeAudioOutput|NativeMediaDispatcher|createNativeMediaSessionSystem)\b')

def code(text):
    return re.sub(r'//[^\n]*|/\*.*?\*/', '', text, flags=re.S)

def audit(root):
    errors = []
    for path in sorted((root / 'src/qt').rglob('*')):
        if path.suffix not in {'.h', '.hpp', '.cpp', '.mm', '.m'}: continue
        source = code(path.read_text())
        for match in re.finditer(r'^\s*#\s*(?:include|import)\s*[<"]([^">]+)[">]', source, re.M):
            name = match.group(1)
            choices = [(path.parent/name).resolve(), (root/'src'/name).resolve()]
            native = (root/'src/platform/macos').resolve()
            for resolved in choices:
                if not resolved.is_relative_to(native): continue
                if path.parent == root / PRESENTATION: break
                if resolved.parent != native or resolved.name not in SHARED:
                    errors.append(f'{path.relative_to(root)}: unexposed native include {name}')
                break
        if BYPASS.search(source): errors.append(f'{path.relative_to(root)}: bypasses the shared native owner')
    return errors

if __name__ == '__main__':
    p = argparse.ArgumentParser(); p.add_argument('--root', type=Path, default=ROOT); a = p.parse_args()
    errors = audit(a.root.resolve())
    if errors: raise SystemExit('\n'.join(errors))
    print('Qt reaches native playback only through the shared owner, preflight and host policy boundary')
