"""The attribution must account for every observed allocation and lock."""
import json
import subprocess
import sys

result = subprocess.run(sys.argv[1:], capture_output=True, text=True, timeout=30)
if result.returncode == -9:
    result = subprocess.run(sys.argv[1:], capture_output=True, text=True, timeout=30)
assert result.returncode == 0, result.stderr
rows = [json.loads(line) for line in result.stdout.splitlines() if line.startswith('{')]
current = None
sites = []

def check():
    assert current and sites, 'missing call-site attribution'
    for domain, prefix in [(1, 'worker'), (2, 'adapter')]:
        for kind in ['allocation', 'lock']:
            key = prefix + '_' + kind + 's' + ('_including_frameworks' if domain == 2 else '')
            assert sum(row['calls'] for row in sites if row['domain'] == domain and row['kind'] == kind) == current[key], key
    assert all(row['image'] != 'unknown' for row in sites)

for row in rows:
    if row['probe'] == 'worker_lifetime':
        if current:
            check()
        current, sites = row, []
    elif row['probe'] == 'call_site':
        sites.append(row)
check()
print(result.stdout)
