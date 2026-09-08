#!/usr/bin/env python3
"""Restore bytes even when the device activation negative control fails."""
from pathlib import Path
import hashlib
import json
import subprocess
repo = Path(__file__).resolve().parents[1]
high_pass_35 = repo / 'src/platform/macos/native_audio_output.mm'
proof = repo / 'docs/wamkit/proofs/continuation'
original = high_pass_35.read_bytes()
start = original.index(b'  // Generation activation must reconcile')
end = original.index(b'  if (!configured_', start)
results = {}
try:
    high_pass_35.write_bytes(original[:start] + original[end:])
    with (proof / 'device-reverted.log').open('w') as log:
        results['reverted_rc'] = subprocess.run(['sh', str(repo / 'tests/run_wamkit_device_recovery_test.sh')], stdout=log, stderr=log).returncode
finally:
    high_pass_35.write_bytes(original)
results['restored_sha256'] = hashlib.sha256(high_pass_35.read_bytes()).hexdigest()
with (proof / 'device-restored.log').open('w') as log:
    results['restored_rc'] = subprocess.run(['sh', str(repo / 'tests/run_wamkit_device_recovery_test.sh')], stdout=log, stderr=log).returncode
(proof / 'device-revert.json').write_text(json.dumps(results, indent=2) + '\n')
assert results['reverted_rc'] != 0 and results['restored_rc'] == 0
