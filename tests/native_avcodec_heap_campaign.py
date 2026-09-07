"""Measure decoder-private allocator peaks; observations do not confer admission."""
import argparse
import hashlib
import json
import pathlib
import struct
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument('--binary', required=True)
parser.add_argument('--output', required=True)
args = parser.parse_args()
root = pathlib.Path(args.output)
root.mkdir(parents=True, exist_ok=True)
rows = []
families = [
    ('asp', 'mpeg4', ['-c:v', 'mpeg4', '-bf', '2', '-flags', '+qpel']),
    ('hi10p', 'h264', ['-c:v', 'libx264', '-profile:v', 'high10', '-pix_fmt', 'yuv420p10le', '-bf', '2', '-refs', '16']),
    ('h264422', 'h264', ['-c:v', 'libx264', '-profile:v', 'high422', '-pix_fmt', 'yuv422p10le', '-bf', '2', '-refs', '16']),
    ('vp9', 'vp9', ['-c:v', 'libvpx-vp9', '-pix_fmt', 'yuv420p', '-cpu-used', '6', '-row-mt', '0']),
    ('vp9p2', 'vp9', ['-c:v', 'libvpx-vp9', '-pix_fmt', 'yuv420p10le', '-profile:v', '2', '-cpu-used', '6', '-row-mt', '0']),
]
def data(dump):
    return bytes.fromhex(''.join(line.split(':', 1)[1].split('  ')[0].replace(' ', '') for line in dump.splitlines() if ':' in line))

for name, codec, options in families:
    for width, height in [(1920, 1080), (3840, 2160)]:
        asset = root / f'{name}-{height}.mkv'
        command = ['ffmpeg', '-v', 'error', '-y', '-threads', '1', '-filter_threads', '1',
                   '-f', 'lavfi', '-i', f'testsrc2=size={width}x{height}:rate=25',
                   '-frames:v', '32', *options, '-threads', '1', '-g', '32', str(asset)]
        subprocess.run(command, check=True, timeout=120)
        facts = json.loads(subprocess.check_output(['ffprobe', '-v', 'error', '-show_streams', '-show_packets', '-show_data', '-of', 'json', str(asset)]))
        extra = data(facts['streams'][0].get('extradata', ''))
        archive = bytearray(struct.pack('<II', len(extra), len(facts['packets']))) + extra
        for packet in facts['packets']:
            payload = data(packet['data'])
            archive += struct.pack('<Iqqq', len(payload), int(packet['pts']), int(packet.get('dts', -(2**63))), int(packet['duration'])) + payload
        packets = asset.with_suffix('.packets')
        packets.write_bytes(archive)
        result = subprocess.run([args.binary, str(packets), codec, str(width), str(height)], capture_output=True, text=True, timeout=30)
        if result.returncode == -9:
            result = subprocess.run([args.binary, str(packets), codec, str(width), str(height)], capture_output=True, text=True, timeout=30)
        rows.append(dict(name=name, width=width, height=height, argv=command,
                         asset_sha256=hashlib.sha256(asset.read_bytes()).hexdigest(),
                         probe_sha256=hashlib.sha256(pathlib.Path(args.binary).read_bytes()).hexdigest(),
                         stream=facts['streams'][0], rc=result.returncode, stdout=result.stdout, stderr=result.stderr))
        (root / 'results.json').write_text(json.dumps(rows, indent=2) + '\n')
        print(name, height, result.returncode, flush=True)
        assert result.returncode == 0, rows[-1]
