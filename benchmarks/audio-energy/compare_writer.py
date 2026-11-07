#!/usr/bin/env python3
"""Counterbalanced accelerated writer comparison; does not measure battery power."""
import argparse
import json
import statistics
import subprocess
from pathlib import Path

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--before', type=Path, required=True)
p.add_argument('--after', type=Path, required=True)
p.add_argument('--output', type=Path, required=True)
a = p.parse_args()
rows = []
a.output.parent.mkdir(parents=True, exist_ok=True)
with a.output.open('x') as output:
    for rate in (48000, 44100):
        for round in range(6):
            for version in (('before', 'after') if round % 2 == 0 else ('after', 'before')):
                row = json.loads(subprocess.check_output([str(getattr(a, version).resolve()), str(rate)], text=True))
                row.update(version=version, round=round)
                rows.append(row)
                output.write(json.dumps(row) + '\n'); output.flush()
for rate in (48000, 44100):
    groups = {v: [r['cpu_seconds'] for r in rows if r['input_rate'] == rate and r['version'] == v] for v in ('before', 'after')}
    before, after = (statistics.median(groups[v]) for v in ('before', 'after'))
    print(json.dumps(dict(input_rate=rate, before_cpu_seconds=before, after_cpu_seconds=after,
        cpu_reduction_percent=(1 - after / before) * 100, ranges={v: [min(values), max(values)] for v, values in groups.items()})))
