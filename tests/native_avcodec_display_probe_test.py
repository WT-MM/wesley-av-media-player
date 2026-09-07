"""The capture campaign must arm identity and range while keeping its oracle on Apple."""
import contextlib
import io
import pathlib
import re
import runpy
import sys
import tempfile
from unittest.mock import patch

script = pathlib.Path(__file__).with_name('native_avcodec_display_probe.py')
encodes, launches = [], []
def encode(command, **unused):
    encodes.append(command)
    pathlib.Path(command[-1]).write_bytes(b'fixture')
class Process:
    pid = 123456
    def __init__(self, command, **options):
        launches.append((command, options['env']))
    def wait(self, **unused):
        return 0

with tempfile.TemporaryDirectory(prefix='wam-capture-policy-', dir='/private/tmp') as root:
    with patch.object(sys, 'argv', [str(script), '--full-range', '--output', root]), patch('subprocess.run', encode), patch('subprocess.Popen', Process), contextlib.redirect_stdout(io.StringIO()):
        runpy.run_path(str(script), run_name='__main__')
assert len(encodes) == len(launches) == 6
assert {pathlib.Path(row[-1]).parent.name for row in encodes} == {'baseline', 'asp', 'hi10p', 'h264422', 'vp9', 'vp9p2'}
for command in encodes:
    assert 'scale=in_range=tv:out_range=pc' in command
    assert command[command.index('-color_range') + 1] == 'pc'
for index, (command, env) in enumerate(launches):
    assert pathlib.Path(command[0]) == script.resolve().parents[1] / 'build/WAM.app/Contents/MacOS/WAM'
    assert env['WAM_NATIVE_BENCHMARK_TELEMETRY'] == '1'
    assert re.fullmatch('[0-9a-f-]{36}', env['WAM_NATIVE_BENCHMARK_RUN_ID'])
    for key in ['WAM_NATIVE_BENCHMARK_ASSET_SHA256', 'WAM_NATIVE_BENCHMARK_CANDIDATE_ID']:
        assert re.fullmatch('[0-9a-f]{64}', env[key])
    assert env['WAM_TEST_GEOMETRY'] == '480x270+2400+1000'
    assert env['WAM_TEST_MUTED'] == env['WAM_TEST_BACKGROUND'] == '1'
    assert ('WAM_TEST_NO_VIDEO_HARDWARE' not in env) if index == 0 else env['WAM_TEST_NO_VIDEO_HARDWARE'] == '1'
print('six-family full-range and hardware-oracle launch policy passed')
