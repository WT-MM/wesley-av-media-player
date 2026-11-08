"""WMA v2 in ASF on the libavformat route: open and warm seeks are sample-exact
against ffmpeg's full decode, and a noise-coded stream, whose seeks cannot
reproduce that decode, is refused."""
import argparse, pathlib, subprocess, tempfile
from fractions import Fraction
import numpy as np

p = argparse.ArgumentParser()
p.add_argument('--probe', required=True)
p.add_argument('--ffmpeg', required=True)
a = p.parse_args()

# name, rate, channels, bit rate. ffmpeg's encoder writes one frame per
# payload without the bit reservoir; frames are 2048 samples above 22.05 kHz,
# 1024 at 22.05 kHz.
CASES = [('stereo44.asf', 44100, 2, '128k'), ('mono22.wma', 22050, 1, '32k'),
         ('stereo48.wma', 48000, 2, '96k'), ('mono32.asf', 32000, 1, '64k')]
TARGETS = [('0', None), ('1/7', None), ('2999/1000', None), ('13/2', None),
           ('1', 'seek'), ('5', 'seek'), ('7001/1000', 'seek'), ('2', 'origin')]


def encode(path, rate, channels, bitrate):
    tone = f'aevalsrc=0.4*sin(2*PI*(220+180*t)*t)|0.3*sin(2*PI*330*t+sin(7*t)):s={rate}:d=8'
    subprocess.run([a.ffmpeg, '-v', 'error', '-y', '-f', 'lavfi', '-i', tone, '-ac', str(channels),
                    '-c:a', 'wmav2', '-b:a', bitrate, str(path)], check=True)


with tempfile.TemporaryDirectory(prefix='wam-wma-proof-', dir='/private/tmp') as scratch:
    root = pathlib.Path(scratch)
    for name, rate, channels, bitrate in CASES:
        asset = root / name
        encode(asset, rate, channels, bitrate)
        reference = root / (name + '.f32')
        pan = 'pan=stereo|c0=c0|c1=c1' if channels == 2 else 'pan=stereo|c0=c0|c1=c0'
        subprocess.run([a.ffmpeg, '-v', 'error', '-y', '-i', str(asset), '-af', pan, '-f', 'f32le',
                        str(reference)], check=True)
        expected = np.fromfile(reference, dtype='<f4').reshape(-1, 2)
        for target, mode in TARGETS:
            out = root / 'actual.f32'
            run = subprocess.run([a.probe, str(asset), str(out), target] + ([mode] if mode else []),
                                 capture_output=True, text=True, timeout=60)
            assert run.returncode == 0, (name, target, mode, run.stderr)
            f = Fraction(target) * rate
            want = expected[-(-f.numerator // f.denominator):]
            actual = np.fromfile(out, dtype='<f4').reshape(-1, 2)
            assert actual.shape == want.shape, (name, target, mode, actual.shape, want.shape)
            error = actual.astype('float64') - want
            maximum, rms = float(np.max(abs(error))), float(np.sqrt(np.mean(error ** 2)))
            assert maximum < 2e-6 and rms < 2e-7, (name, target, mode, maximum, rms)
            lags = {lag: float(np.mean((actual[max(lag, 0):len(actual) + min(lag, 0), 0] -
                                        want[max(-lag, 0):len(want) - max(lag, 0), 0]) ** 2))
                    for lag in [-2, -1, 0, 1, 2]}
            assert min(lags, key=lags.get) == 0, (name, target, mode, lags)
            # A seek this far in decodes from a later payload, not the origin.
            stats = dict(field.split('=', 1) for field in run.stderr.split() if '=' in field)
            if mode == 'seek' and Fraction(target) >= 5:
                assert int(stats['trim']) < int(stats['floor']), (name, target, run.stderr)
            print(name, target, mode or 'open', len(actual), maximum, rms, 'trim', stats['trim'])
    noisy = root / 'noise-coded.wma'
    encode(noisy, 44100, 2, '32k')
    run = subprocess.run([a.probe, str(noisy), str(root / 'refused.f32'), '0'],
                         capture_output=True, text=True, timeout=60)
    assert run.returncode != 0 and 'LibavformatAudioTimingUnproven: wmav2 noise coding' in run.stderr, run.stderr
    print('noise-coded stream refused')
