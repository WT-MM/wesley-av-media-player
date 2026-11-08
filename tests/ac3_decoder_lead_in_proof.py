"""AC-3 / E-AC-3 decoder lead-in, one rule in every container, against ffmpeg.

AudioToolbox swallows the first 256 decoded frames of an AC-3 or E-AC-3
stream, but those frames are part of the presentation: ffmpeg and mpv play the
decoder's first output at the first access unit's own timestamp. So the
earliest frame WAM can publish is that timestamp + 256, and anything between
the media start and it is declared silence:
  Matroska, CodecDelay 256 (ffmpeg)  -> access unit 0 at -256, no silence
  Matroska, no CodecDelay (mkvmerge) -> 256 frames of silence
  MPEG-TS, bare .ac3/.ec3            -> 256 frames of silence
  MP4 (ffmpeg's 240-frame edit)      -> 16 frames of silence
Every published frame must land on ffmpeg's decode of the same file, and the
first one exactly on the stated presentation floor (the session's start check).
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
VIDEO = 'testsrc2=s=160x120:r=25:d=3'


def ffmpeg(*args):
    r = subprocess.run([a.ffmpeg, '-v', 'error', '-y', *map(str, args)],
                       capture_output=True, timeout=120)
    assert r.returncode == 0, (args, r.stderr.decode()[-400:])
    return r.stdout


def reference(path, channels):
    af = DOWNMIX if channels == 6 else 'aformat=channel_layouts=stereo'
    raw = ffmpeg('-i', path, '-map', '0:a:0', '-af', af, '-f', 'f32le', '-')
    return np.frombuffer(raw, dtype='<f4').reshape(-1, 2)


def probe(path, target, out):
    r = subprocess.run([a.probe, path, out, target, 'seek'], capture_output=True,
                       text=True, timeout=120)
    fields = dict(f.split('=', 1) for f in r.stderr.split() if '=' in f)
    assert 'first' in fields and fields.get('drained') == '1', (path.name, target, r.stderr)
    return int(fields['first']), int(fields['floor']), np.fromfile(out, dtype='<f4').reshape(-1, 2)


def fixtures(d, codec, channels, source):
    stem = d / f'{codec}{channels}'
    mkv = stem.with_suffix('.mkv')
    ffmpeg('-f', 'lavfi', '-i', source, '-c:a', codec, '-b:a', '384k', mkv)
    bare = stem.with_suffix('.' + codec.replace('eac3', 'ec3'))
    ffmpeg('-i', mkv, '-c', 'copy', '-f', codec, bare)
    # A raw elementary stream has no initial padding, so this remux carries no
    # CodecDelay element: the mkvmerge shape.
    nodelay = d / f'{codec}{channels}-nodelay.mkv'
    ffmpeg('-i', bare, '-c', 'copy', nodelay)
    mp4 = stem.with_suffix('.mp4')
    ffmpeg('-i', mkv, '-c', 'copy', mp4)
    # The transport stream route requires video.
    ts = stem.with_suffix('.ts')
    ffmpeg('-f', 'lavfi', '-i', source, '-f', 'lavfi', '-i', VIDEO, '-map', '1:v',
           '-map', '0:a', '-c:v', 'libx264', '-g', '25', '-c:a', codec, '-b:a', '384k', ts)
    # (path, declared silence, frames ffmpeg decodes past WAM's end). ffmpeg's
    # Matroska mux hides the decoder's 32 withheld tail frames under a longer
    # DiscardPadding, its MP4 mux under the edit's end; the other carriers
    # expose them.
    return [(mkv, 0, 0), (nodelay, 256, 32), (ts, 256, 32), (mp4, 16, 0), (bare, 256, 32)]


with tempfile.TemporaryDirectory() as scratch:
    d = pathlib.Path(scratch)
    checked = 0
    for codec in ('eac3', 'ac3'):
        for channels, source in SOURCES.items():
            if codec == 'ac3' and channels == 6:
                continue
            for path, gap, tail in fixtures(d, codec, channels, source):
                ref = reference(path, channels)
                for target, frame in (('0', 0), ('1/100', 480), ('3/2', 72000)):
                    expected = max(frame, gap)
                    first, floor, pcm = probe(path, target, d / 'out.f32')
                    assert first == floor == expected, (path.name, target, first, floor, expected)
                    n = min(len(pcm), len(ref) - first - 1)
                    def error(at):
                        return np.abs(pcm[:n] - ref[at:at + n]).max()
                    # Two lossy decoders differ by a few 1e-3 at full scale; a
                    # single frame of misalignment costs several times more.
                    exact = error(first)
                    assert n > RATE and exact < 1e-2, (path.name, target, n, exact)
                    assert error(first + 1) > 4 * exact, (path.name, target, 'not discriminating')
                    assert len(ref) - (first + len(pcm)) == tail, (path.name, target, len(ref) - first - len(pcm))
                    checked += 1
    assert checked == 45, checked
    print(f'ac3 decoder lead-in: {checked} windows exact against ffmpeg')
