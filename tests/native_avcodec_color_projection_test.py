"""A known-good hardware control must pass the original, unchanged tolerances."""
import argparse
import json
import pathlib
import subprocess
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument('--captures', required=True)
args = parser.parse_args()
with tempfile.TemporaryDirectory(prefix='wam-color-regression-', dir='/private/tmp') as temporary:
    result = pathlib.Path(temporary) / 'projection.json'
    script = pathlib.Path(__file__).with_name('native_avcodec_color_projection.py')
    process = subprocess.run(['python3', str(script), '--captures', args.captures, '--output', str(result)], capture_output=True, text=True)
    assert process.returncode == 0, process.stderr
    rows = json.loads(result.read_text())
    assert rows and all(row['matrix_range_projection_pass'] for row in rows), rows
    print('hardware color oracle passed with original projection and RMS tolerances')
