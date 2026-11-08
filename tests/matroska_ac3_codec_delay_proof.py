"""Matroska AC-3 / E-AC-3 with and without CodecDelay against ffmpeg's decode.

AudioToolbox swallows 256 leading frames of an AC-3 or E-AC-3 stream. ffmpeg
states that as CodecDelay, so its decoder output starts on media zero. A mux
with no CodecDelay (mkvmerge) presents the raw decode from the first Block's
timestamp: AudioToolbox's first frame then belongs 256 frames in, and the
frames before it are declared silence. Both must land every published frame
on ffmpeg's own decode of the same file.
"""
import argparse
import pathlib
import subprocess
import tempfile

import numpy as np

p = argparse.ArgumentParser()
p.add_argument('--probe', required=True)
p.add_argument('--ffmpeg', required=True)
a = p.parse_args()
RATE = 48000
DOWNMIX = 'pan=stereo|FL=FL+0.70710678*FC+0.70710678*SL|FR=FR+0.70710678*FC+0.70710678*SR'
# Chirps: a periodic tone would make a misalignment look exact.
SOURCES = {
    2: 'aevalsrc=0.5*sin(2*PI*(200+400*t)*t)|0.5*cos(2*PI*(300+300*t)*t):s=48000:d=3',
    6: ('aevalsrc=0.4*sin(2*PI*(200+400*t)*t)|0.4*cos(2*PI*(300+300*t)*t)|'
        '0.4*sin(2*PI*(500+100*t)*t)|0.3*sin(2*PI*(60+10*t)*t)|'
        '0.4*sin(2*PI*(700+200*t)*t)|0.4*cos(2*PI*(800+50*t)*t)'
        ':s=48000:d=3:c=5.1(side)'),
}


def run(argv):
    r = subprocess.run(list(map(str, argv)), capture_output=True, timeout=120)
    assert r.returncode == 0, (argv, r.stderr.decode()[-400:])
    return r


def ffmpeg(*args):
    return run([a.ffmpeg, '-v', 'error', '-y', *args])


def reference(path, channels):
    af = DOWNMIX if channels == 6 else 'aformat=channel_layouts=stereo'
    raw = ffmpeg('-i', path, '-map', '0:a:0', '-af', af, '-f', 'f32le', '-').stdout
    return np.frombuffer(raw, dtype='<f4').reshape(-1, 2)


def probe(path, target, out):
    r = subprocess.run([a.probe, path, out, target, 'seek'], capture_output=True,
                       text=True, timeout=120)
    assert r.returncode == 0, (path.name, target, r.stderr)
    first = int(r.stderr.split('first=')[1].split()[0])
    return first, np.fromfile(out, dtype='<f4').reshape(-1, 2)


with tempfile.TemporaryDirectory() as scratch:
    d = pathlib.Path(scratch)
    checked = 0
    for codec in ('eac3', 'ac3'):
        for channels, source in SOURCES.items():
            if codec == 'ac3' and channels == 6:
                continue
            stem = d / f'{codec}{channels}'
            delayed = stem.with_suffix('.mkv')
            ffmpeg('-f', 'lavfi', '-i', source, '-c:a', codec, '-b:a', '384k', delayed)
            bare = stem.with_suffix('.' + codec)
            ffmpeg('-i', delayed, '-c', 'copy', bare)
            undelayed = d / f'{codec}{channels}-nodelay.mkv'
            # A raw elementary stream has no initial padding, so this mux
            # carries no CodecDelay element: the mkvmerge shape.
            ffmpeg('-i', bare, '-c', 'copy', undelayed)
            for path, gap in ((delayed, 0), (undelayed, 256)):
                ref = reference(path, channels)
                for target, floor in (('0', gap), ('1/100', max(480, gap)),
                                      ('3/2', 72000)):
                    first, pcm = probe(path, target, d / 'out.f32')
                    assert first == floor, (path.name, target, first, floor)
                    n = min(len(pcm), len(ref) - first - 1)
                    def error(at):
                        return np.abs(pcm[:n] - ref[at:at + n]).max()
                    # Two lossy decoders differ by a few 1e-3 at full scale; a
                    # single frame of misalignment costs several times more.
                    exact = error(first)
                    assert n > RATE and exact < 1e-2, (path.name, target, n, exact)
                    assert error(first + 1) > 4 * exact, \
                        (path.name, target, 'alignment is not discriminating')
                    # The decoder withholds 32 tail frames; ffmpeg's mux hides
                    # them under a longer DiscardPadding, the bare remux has none.
                    tail = len(ref) - (first + len(pcm))
                    assert tail == (32 if gap else 0), (path.name, target, tail)
                    checked += 1
    assert checked == 18, checked
    print(f'matroska ac3 codec delay: {checked} windows exact against ffmpeg')
