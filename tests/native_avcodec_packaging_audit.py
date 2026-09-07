"""Inspect only the shipped Mach-O closure, including lazy libraries and plugins."""
import argparse
import json
import pathlib
import re
import subprocess

NATIVE_NAMES = ['libavcodec-wamnative.63.dylib', 'libavutil-wamnative.61.dylib']
NOTICES = ['FFMPEG_NOTICES.md', 'COPYING.LGPLv2.1', 'LICENSE.md',
           'configure-command.txt', 'build-receipt.txt', 'SOURCE_DISTRIBUTION.md']
MAGICS = {bytes.fromhex(value) for value in
          ['feedface', 'cefaedfe', 'feedfacf', 'cffaedfe', 'cafebabe', 'bebafeca', 'cafebabf', 'bfbafeca']}


def system_path(value):
    return value.startswith(('/System/Library/', '/usr/lib/'))


def inspect(path):
    commands = subprocess.check_output(['/usr/bin/otool', '-l', str(path)], text=True)
    loads, rpaths, versions, platforms = [], [], [], []
    for block in re.split(r'Load command \d+\n', commands)[1:]:
        match = re.search(r'^\s*cmd (\S+)\s*$', block, re.M)
        if not match:
            continue
        kind = match[1]
        if kind in {'LC_LOAD_DYLIB', 'LC_LOAD_WEAK_DYLIB', 'LC_REEXPORT_DYLIB', 'LC_LOAD_UPWARD_DYLIB', 'LC_LAZY_LOAD_DYLIB'}:
            loads.extend(re.findall(r'^\s*name (.+) \(offset \d+\)', block, re.M))
        elif kind == 'LC_RPATH':
            rpaths.extend(re.findall(r'^\s*path (.+) \(offset \d+\)', block, re.M))
        elif kind == 'LC_BUILD_VERSION':
            versions.extend(re.findall(r'^\s*minos (\d+(?:\.\d+){1,2})\s*$', block, re.M))
            platforms.extend(re.findall(r'^\s*platform (\S+)\s*$', block, re.M))
        elif kind == 'LC_VERSION_MIN_MACOSX':
            versions.extend(re.findall(r'^\s*version (\d+(?:\.\d+){1,2})\s*$', block, re.M))
            platforms.append('MACOS')
    def version(value):
        return tuple((list(map(int, value.split('.'))) + [0, 0])[:3])
    floor_pass = bool(versions) and len(platforms) == len(versions) and all(p in {'MACOS', '1'} for p in platforms) and all(version(v) <= (13, 3, 0) for v in versions)
    return dict(path=str(path), loads=loads, rpaths=rpaths, minos=versions,
                at_or_below_13_3=floor_pass)


def audit(app):
    app = pathlib.Path(app).resolve(strict=True)
    exe = app / 'Contents/MacOS/WAM'
    frameworks = app / 'Contents/Frameworks'
    notices = app / 'Contents/Resources/native-ffmpeg'
    errors, inventory, seen = [], [], set()
    # Resolve containment before opening any file, including symlinked plugin trees.
    for path in sorted(app.rglob('*')):
        target = path.resolve()
        if not target.is_relative_to(app):
            errors.append('BundlePathEscapes: ' + str(path.relative_to(app)))
            continue
        if not path.is_file() or target in seen:
            continue
        seen.add(target)
        with path.open('rb') as stream:
            magic = stream.read(4)
        if magic in MAGICS:
            inventory.append(inspect(target))
    by_path = {row['path']: row for row in inventory}
    main = by_path.get(str(exe.resolve()))
    if main is None:
        errors.append('BundledExecutableMissing')
    def expand(value, owner):
        return value.replace('@loader_path', str(owner.parent)).replace('@executable_path', str(exe.parent))
    external, unresolved = [], []
    for row in inventory:
        owner = pathlib.Path(row['path'])
        for dep in row['loads']:
            if system_path(dep):
                continue
            if dep.startswith('/'):
                external.append(dict(owner=row['path'], dependency=dep))
                continue
            if dep.startswith('@rpath/'):
                search = row['rpaths'] + (main['rpaths'] if main else [])
                candidates = [pathlib.Path(expand(base, owner if base in row['rpaths'] else exe)) / dep[len('@rpath/'):] for base in search]
            else:
                candidates = [pathlib.Path(expand(dep, owner))] if dep.startswith(('@loader_path/', '@executable_path/')) else []
            if not any(str(p.resolve()) in by_path and p.resolve().is_relative_to(app) for p in candidates):
                unresolved.append(dict(owner=row['path'], dependency=dep))
    names = NATIVE_NAMES + (['libavformat-wamnative.63.dylib'] if (notices / 'demux-stage-built').exists() else [])
    native = [by_path[str((frameworks / name).resolve())] for name in names if str((frameworks / name).resolve()) in by_path]
    notice_state = {name: (notices / name).is_file() and (notices / name).resolve().is_relative_to(app) for name in NOTICES}
    eager = bool(main and any('libavcodec' in p or 'libavutil' in p or 'libavformat' in p for p in main['loads']))
    floor_pass = bool(inventory) and all(row['at_or_below_13_3'] for row in inventory)
    relocatable = not errors and not external and not unresolved and len(native) == len(names)
    return dict(native=native, main=main, bundled_machos=inventory,
                direct_external_dependencies=external, unresolved_dependencies=unresolved,
                errors=errors, eager_native_ffmpeg=eager, notices=notice_state,
                bundled_floor_13_3_pass=floor_pass, closure_relocatable=relocatable,
                clean_machine_ready=relocatable and floor_pass and not eager and all(notice_state.values()))


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--app', required=True)
    parser.add_argument('--output', required=True)
    args = parser.parse_args()
    result = audit(args.app)
    pathlib.Path(args.output).write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps({key: result[key] for key in ['clean_machine_ready', 'closure_relocatable', 'bundled_floor_13_3_pass', 'errors']}, indent=2))
    if not result['clean_machine_ready']:
        raise SystemExit('NativeBundleNotRelocatable: see bundled closure and floor findings')
