"""Offline, exact packet/fragment context for RustDesk trace attribution."""
import argparse
from fractions import Fraction
import json
from pathlib import Path
import struct
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
repo = Path(__file__).resolve().parents[1]
assets = json.loads((repo / 'docs/native-coverage/phase3/rustdesk-full-decode.json').read_text())
result = []
for asset in assets:
    path = Path(asset['path'])
    fragments = []
    with path.open('rb') as stream:
        end = path.stat().st_size
        offset = 0
        while offset + 8 <= end:
            stream.seek(offset)
            size, kind = struct.unpack('>I4s', stream.read(8))
            if size == 1:
                size = struct.unpack('>Q', stream.read(8))[0]
            elif size == 0:
                size = end - offset
            if size < 8 or offset + size > end:
                break
            if kind == b'moof':
                fragments.append(offset)
            offset += size
    if offset != end:
        raise ValueError(f'incomplete top-level box walk: {path}: {offset}/{end}')
    probe = json.loads(subprocess.check_output(['ffprobe', '-v', 'error', '-select_streams', 'v:0',
        '-show_packets', '-show_streams', '-show_entries', 'stream=time_base:packet=pts,duration,pos,flags',
        '-of', 'json', str(path)]))
    scale = Fraction(probe['streams'][0]['time_base'])
    import bisect
    packets = []
    previous = None
    for ordinal, packet in enumerate(sorted(probe['packets'], key=lambda p: int(p['pts'])), 1):
        fragment = bisect.bisect_right(fragments, int(packet['pos']))
        pts = int(packet['pts']) * scale
        duration = int(packet['duration']) * scale
        packets.append(dict(ordinal=ordinal, pts_value=pts.numerator, pts_scale=pts.denominator,
            duration_value=duration.numerator, duration_scale=duration.denominator,
            fragment=fragment, fragment_boundary=previous is not None and fragment != previous))
        previous = fragment
    result.append(dict(path=str(path), asset_sha256=asset['asset_sha256'], fragments=len(fragments), packets=packets))
args.output.write_text(json.dumps(result, separators=(',', ':')) + '\n')
