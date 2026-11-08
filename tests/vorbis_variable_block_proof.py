"""Vorbis with unequal block sizes (libvorbis' 256/2048) in Matroska, against ffmpeg.

Packet k decodes to (blocksize[k-1] + blocksize[k]) / 4 frames and packet 0 to
none, so the native route reads every packet's mode at open. The fixtures were
encoded by oggenc from a chirp with clicks, so short and long blocks alternate.
Each is remuxed by ffmpeg and its Block timestamps restated from ffmpeg's own
decoder (frame nb_samples), because ffmpeg's Ogg demuxer misplaces the packet
that opens a page after a long-to-short transition, which the native route
rightly refuses. Two stampings, both seen in real files:
  .mkv / .webm      at each packet's first decoded frame, packet 0 at tick 0
                    and its notional blocksize0 / 2 frames before packet 1
  -granule.mkv      at each packet's last decoded frame, the Ogg granule
                    position (ffmpeg 4.x's libvorbis mux)
Every published frame must land on ffmpeg's decode of the source Ogg, after the
open and after seeks, through to its exact end.
"""
import argparse
import pathlib
import subprocess
import tempfile

import numpy as np

p = argparse.ArgumentParser()
p.add_argument('--probe', required=True)
p.add_argument('--ffmpeg', required=True)
p.add_argument('--fixtures', required=True)
a = p.parse_args()


def ffmpeg(*args):
    r = subprocess.run([a.ffmpeg, '-v', 'error', '-y', *map(str, args)],
                       capture_output=True, timeout=120)
    assert r.returncode == 0, (args, r.stderr.decode()[-400:])
    return r.stdout


def probe(path, target, out):
    r = subprocess.run([a.probe, path, out, target, 'seek'], capture_output=True,
                       text=True, timeout=120)
    fields = dict(f.split('=', 1) for f in r.stderr.split() if '=' in f)
    assert r.returncode == 0 and fields.get('drained') == '1', (path.name, target, r.stderr)
    return int(fields['first']), np.fromfile(out, dtype='<f4').reshape(-1, 2)


def vint(data, at, marker):
    length = 8 - data[at].bit_length() + 1
    value = int.from_bytes(data[at:at + length], 'big')
    return (value if marker else value & ((1 << (7 * length)) - 1)), at + length


def restamp(path, ticks):
    """Rewrites every Block timestamp in order; ticks are absolute, 1 ms."""
    data = bytearray(path.read_bytes())
    blocks = iter(ticks)
    def walk(start, end, cluster):
        at = start
        while at < end:
            ident, at = vint(data, at, True)
            size, body = vint(data, at, False)
            at = body + size
            if ident in (0x18538067, 0x1F43B675, 0xA0):
                walk(body, at, [None] if ident == 0x1F43B675 else cluster)
            elif ident == 0xE7:
                cluster[0] = int.from_bytes(data[body:at], 'big')
            elif ident in (0xA3, 0xA1):
                _, offset = vint(data, body, False)
                relative = next(blocks) - cluster[0]
                assert -32768 <= relative < 32768
                data[offset:offset + 2] = relative.to_bytes(2, 'big', signed=True)
    walk(0, len(data), [None])
    assert next(blocks, None) is None
    path.write_bytes(bytes(data))


def tick(frame, rate):
    return (2000 * frame + rate) // (2 * rate)


checked = 0
with tempfile.TemporaryDirectory() as scratch:
    d = pathlib.Path(scratch)
    for source, rate, channels in (('mono44.ogg', 44100, 1), ('stereo48.ogg', 48000, 2)):
        ogg = pathlib.Path(a.fixtures) / source
        ref = np.frombuffer(ffmpeg('-i', ogg, '-f', 'f32le', '-c:a', 'pcm_f32le', '-'),
                            dtype='<f4').reshape(-1, channels)
        stem = d / ogg.stem
        mkv, webm, granule = (stem.with_suffix('.mkv'), stem.with_suffix('.webm'),
                              d / f'{ogg.stem}-granule.mkv')
        decoded = [int(line.split(',')[1]) for line in subprocess.run(
            [str(pathlib.Path(a.ffmpeg).with_name('ffprobe')), '-v', 'error',
             '-select_streams', 'a', '-show_entries', 'frame=nb_samples', '-of',
             'csv', ogg], capture_output=True, text=True, check=True).stdout.split()]
        ends = np.cumsum(decoded).tolist()
        notional = 128  # blocksize0 / 2: packet 0 is a short block
        for path in (mkv, webm, granule):
            ffmpeg('-i', ogg, '-c', 'copy', path)
        restamp(mkv, [0] + [tick(notional + e - n, rate) for e, n in zip(ends, decoded)])
        restamp(webm, [0] + [tick(notional + e - n, rate) for e, n in zip(ends, decoded)])
        restamp(granule, [0] + [tick(e, rate) for e in ends])
        for path, media_start in ((mkv, notional), (webm, notional), (granule, 0)):
            for target, frame in (('0', 0), ('1/100', rate // 100), ('3/2', rate * 3 // 2)):
                first, pcm = probe(path, target, d / 'out.f32')
                expected = max(frame, media_start)
                assert first == expected, (path.name, target, first, expected)
                if channels == 1:
                    assert np.array_equal(pcm[:, 0], pcm[:, 1]), path.name
                pcm = pcm[:, :channels]
                at = first - media_start
                assert len(pcm) == len(ref) - at, (path.name, target, len(pcm), len(ref) - at)
                def error(lag):
                    n = len(pcm) - 1
                    return np.abs(pcm[:n] - ref[at + lag:at + lag + n]).max()
                exact = error(0)
                assert exact < 1e-5, (path.name, target, exact)
                assert error(1) > 1e-2, (path.name, target, 'not discriminating')
                checked += 1
assert checked == 18, checked
print(f'vorbis variable block sizes: {checked} windows exact against ffmpeg')
