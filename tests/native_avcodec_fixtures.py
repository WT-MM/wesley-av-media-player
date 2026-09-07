"""Generate packet-level decoder fixtures with a separate encoder toolchain."""
import argparse
import hashlib
import json
import pathlib
import struct
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument('--output', required=True)
parser.add_argument('--ffmpeg', required=True)
parser.add_argument('--ffprobe', required=True)
args = parser.parse_args()
root = pathlib.Path(args.output)
root.mkdir(parents=True, exist_ok=True)
commands = []
def run(argv):
    commands.append(argv)
    return subprocess.check_output(argv)
def packet_bytes(dump):
    return bytes.fromhex(''.join(line.split(':', 1)[1].split('  ')[0].strip().replace(' ', '')
                                for line in dump.splitlines() if ':' in line))
for name, options in [('vp9', ['-c:v','libvpx-vp9','-pix_fmt','yuv420p','-threads','1','-row-mt','0']),
                      ('vp9p2', ['-c:v','libvpx-vp9','-pix_fmt','yuv420p10le','-profile:v','2','-threads','1','-row-mt','0']),
                      ('hi10p', ['-c:v','libx264','-profile:v','high10','-pix_fmt','yuv420p10le','-bf','2']),
                      ('asp', ['-c:v','mpeg4','-bf','2','-q:v','4']),
                      ('h264422', ['-c:v','libx264','-profile:v','high422','-pix_fmt','yuv422p10le','-bf','2'])]:
    asset = root / (name + '.mkv')
    run([args.ffmpeg,'-v','error','-y','-f','lavfi','-i','testsrc2=size=320x180:rate=25',
         '-t','2',*options,str(asset)])
    info = json.loads(run([args.ffprobe,'-v','error','-select_streams','v:0','-show_streams',
                          '-show_packets','-show_data','-of','json',str(asset)]))
    extra = packet_bytes(info['streams'][0].get('extradata', ''))
    archive = bytearray(struct.pack('<II', len(extra), len(info['packets']))) + extra
    for packet in info['packets']:
        data = packet_bytes(packet['data'])
        archive += struct.pack('<Iqqq',len(data),int(packet['pts']),
                               int(packet.get('dts',-(2**63))),int(packet['duration'])) + data
    (root / (name + '.packets')).write_bytes(archive)
    run([args.ffmpeg,'-v','error','-y','-i',str(asset),'-f','rawvideo',
         '-pix_fmt',info['streams'][0]['pix_fmt'],str(root / (name + '.yuv'))])
for name, codec in [('dts','dca'),('truehd','truehd'),('mlp','mlp')]:
    asset = root / (name + '.mka')
    run([args.ffmpeg,'-v','error','-y','-f','lavfi','-i',
         'aevalsrc=0.2*sin(2*PI*(200*t+100*t*t))|0.1*sin(2*PI*700*t):s=48000',
         '-t','2','-c:a',codec,'-strict','-2',str(asset)])
    info = json.loads(run([args.ffprobe,'-v','error','-show_packets','-show_data',
                          '-show_streams','-of','json',str(asset)]))
    archive = bytearray(struct.pack('<I', len(info['packets'])))
    for packet in info['packets']:
        data = packet_bytes(packet['data'])
        archive += struct.pack('<I', len(data)) + data
    (root / (name + '.audio-packets')).write_bytes(archive)
    reference_asset = asset
    if name == 'dts':
        reference_asset = root / 'dts.dts'
        run([args.ffmpeg,'-v','error','-y','-i',str(asset),'-c','copy','-f','dts',str(reference_asset)])
    run([args.ffmpeg,'-v','error','-y','-i',str(reference_asset),'-c:a','pcm_f32le','-f','f32le',str(root/(name+'.f32'))])
for name, codec in [('dts51','dca'),('truehd51','truehd')]:
    asset = root / (name + '.mka')
    impulses = '|'.join('0.5*eq(n,' + str(1000+c*6000) + ')' for c in range(6))
    run([args.ffmpeg,'-v','error','-y','-f','lavfi','-i',
         "aevalsrc='"+impulses+"':s=48000:c=5.1(side)",
         '-t','1','-c:a',codec,'-strict','-2',str(asset)])
    info = json.loads(run([args.ffprobe,'-v','error','-show_packets','-show_data',
                          '-show_streams','-of','json',str(asset)]))
    assert info['streams'][0]['channels'] == 6
    archive = bytearray(struct.pack('<I', len(info['packets'])))
    for packet in info['packets']:
        data = packet_bytes(packet['data'])
        archive += struct.pack('<I',len(data)) + data
    (root / (name + '.audio-packets')).write_bytes(archive)
    reference_asset = asset
    if codec == 'dca':
        reference_asset = root / (name + '.dts')
        run([args.ffmpeg,'-v','error','-y','-i',str(asset),'-c','copy','-f','dts',str(reference_asset)])
    for suffix, options in [('.f32', []), ('.stereo.f32', ['-ac','2'])]:
        run([args.ffmpeg,'-v','error','-y','-i',str(reference_asset),*options,
             '-c:a','pcm_f32le','-f','f32le',str(root/(name+suffix))])
manifest = dict(ffmpeg_version=run([args.ffmpeg,'-version']).decode(), argv=commands,
                artifacts={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in root.iterdir()
                           if p.is_file() and p.name != 'manifest.json'})
(root / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
