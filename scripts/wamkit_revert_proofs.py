#!/usr/bin/env python3
"""Temporary behavioral/structural reverts with byte-identical restoration."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--case', choices=['retirement', 'factory-lifetime', 'detached-view'], required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[1]
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    if args.case == 'retirement':
        paths = ['src/platform/macos/native_retirement.mm']
        text = (repo / paths[0]).read_text()
        old = '  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{\n    while (testPaused.load(std::memory_order_acquire)) testPaused.wait(true);\n    retained->graph_.reset();'
        new = '  retained->graph_.reset();\n  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{\n    while (testPaused.load(std::memory_order_acquire)) testPaused.wait(true);'
        assert old in text
        reverted = [text.replace(old, new).encode()]
        test = 'wam_native_retirement_test'
        kind = 'runtime: restore graph destruction on the calling main thread'
    elif args.case == 'factory-lifetime':
        paths = ['src/platform/macos/native_media_session_system.mm']
        text = (repo / paths[0]).read_text()
        text = text.replace('  std::shared_ptr<void> presentation;\n', '')
        text = text.replace('  std::shared_ptr<NativeTrackedVideoArbiter> videoArbiter;\n',
                            '  std::shared_ptr<NativeTrackedVideoArbiter> videoArbiter;\n  std::shared_ptr<void> presentation;\n')
        old = 'std::move(presentation.lifetime), wake,\n                                         videoArbiter'
        assert old in text
        reverted = [text.replace(old, 'wake, videoArbiter,\n                                         std::move(presentation.lifetime)').encode()]
        test = 'wam_native_session_factory_test'
        kind = 'runtime: restore original presentation-before-output release order'
    else:
        paths = ['src/platform/macos/native_layer_host_view.hpp', 'src/platform/macos/native_layer_host_view.mm']
        reverted = [subprocess.check_output(['git', 'show', 'HEAD:' + path], cwd=repo) for path in paths]
        test = 'wam_native_layer_embedding_test'
        kind = 'structural: restore original window-dependent host-view interface'
    originals = [(repo / path).read_bytes() for path in paths]
    receipt = dict(case=args.case, kind=kind, files=[dict(path=path,
        sha256=hashlib.sha256(data).hexdigest()) for path, data in zip(paths, originals)])

    def run(name, argv):
        with (output / name).open('w') as log:
            return subprocess.run(argv, cwd=repo, stdout=log, stderr=subprocess.STDOUT).returncode

    try:
        receipt['baseline_rc'] = run('baseline.log', [str(repo / 'build' / test)])
        assert receipt['baseline_rc'] == 0
        for path, data in zip(paths, reverted):
            (repo / path).write_bytes(data)
        receipt['reverted_build_rc'] = run('reverted-build.log', ['cmake', '--build', 'build', '--parallel'])
        receipt['reverted_test_rc'] = None
        if receipt['reverted_build_rc'] == 0:
            receipt['reverted_test_rc'] = run('reverted-test.log', [str(repo / 'build' / test)])
        assert receipt['reverted_build_rc'] != 0 or receipt['reverted_test_rc'] != 0
        if args.case != 'detached-view':
            assert receipt['reverted_build_rc'] == 0, 'runtime proof requires a successful reverted build'
    finally:
        for path, data in zip(paths, originals):
            (repo / path).write_bytes(data)
        receipt['byte_identical_restore'] = all((repo / path).read_bytes() == data for path, data in zip(paths, originals))
        receipt['restored_build_rc'] = run('restored-build.log', ['cmake', '--build', 'build', '--parallel'])
        receipt['restored_test_rc'] = run('restored-test.log', [str(repo / 'build' / test)])
        (output / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
    assert receipt['byte_identical_restore'] and receipt['restored_build_rc'] == 0 and receipt['restored_test_rc'] == 0
    print(json.dumps(receipt), flush=True)


if __name__ == '__main__':
    main()
