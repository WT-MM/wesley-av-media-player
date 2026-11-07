"""A real hardware frame must be observable before a display-color campaign."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import uuid

from PIL import Image, ImageStat

parser = argparse.ArgumentParser()
parser.add_argument('--output', type=Path, required=True)
parser.add_argument('--expect-session-locked', action='store_true')
args = parser.parse_args()
root = args.output.resolve()
root.mkdir(parents=True, exist_ok=False)
(root / 'home').mkdir()
app = Path(__file__).resolve().parents[1] / 'build/WAM.app/Contents/MacOS/WAM'
asset = root / 'red.mp4'
subprocess.run([
    'ffmpeg', '-v', 'error', '-threads', '1', '-filter_threads', '1',
    '-f', 'lavfi', '-i', 'color=red:size=480x270:rate=25', '-t', '4',
    '-c:v', 'libx264', '-threads', '1', '-pix_fmt', 'yuv420p',
    '-color_primaries', 'bt709', '-color_trc', 'bt709', '-colorspace', 'bt709',
    str(asset)], check=True)

def sha(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()

env = os.environ.copy()
env.pop('WAM_TEST_NO_VIDEO_HARDWARE', None)
env.update(HOME=str(root / 'home'), WAM_NATIVE_BENCHMARK_TELEMETRY='1',
           WAM_NATIVE_BENCHMARK_RUN_ID=str(uuid.uuid4()),
           WAM_NATIVE_BENCHMARK_ASSET_SHA256=sha(asset),
           WAM_NATIVE_BENCHMARK_CANDIDATE_ID=sha(app),
           WAM_TEST_BACKGROUND='1', WAM_TEST_MUTED='1',
           WAM_TEST_GEOMETRY='480x270+2400+1000',
           WAM_PLAYBACK_METRICS_PATH=str(root / 'metrics.jsonl'),
           WAM_TEST_QUIT_AFTER_MS='5000',
           WAM_TEST_WINDOW_SCRIPT=f'report@1800,videograb:0:{root}/display.png@200,report@600')
with (root / 'log.txt').open('w') as log:
    process = subprocess.Popen([str(app), str(asset)], env=env, stdout=log, stderr=log)
    try:
        rc = process.wait(timeout=15)
    except subprocess.TimeoutExpired:
        process.terminate()
        process.wait(timeout=5)
        raise
text = (root / 'log.txt').read_text()
receipt = dict(pid=process.pid, rc=rc, identities={
    key: value for key, value in env.items() if key.startswith('WAM_NATIVE_BENCHMARK_')},
    expected_session_locked=args.expect_session_locked,
    captures=[line for line in text.splitlines() if line.startswith('WAM_TEST_')])
(root / 'result.json').write_text(json.dumps(receipt, indent=2) + '\n')
assert rc == 0, f'app exit: {rc}'
assert 'WAM: native failure' not in text, 'native playback failed'
assert 'stage=VideoToolboxHardware' in text, 'hardware oracle was not selected'
assert '"event":"first_frame_drawn"' in text, 'no hardware frame reached presentation'
if args.expect_session_locked:
    assert 'DisplayCaptureSessionLocked' in text, 'locked compositor must refuse by name'
    assert not (root / 'display.png').exists(), 'locked compositor published an image'
else:
    assert 'WAM_TEST_CAPTURE_REFUSAL' not in text, 'compositor capture refused'
    with Image.open(root / 'display.png') as image:
        width, height = image.size
        patch = image.convert('RGB').crop((width//4, height//4, width*3//4, height*3//4))
        red, green, blue = ImageStat.Stat(patch).mean
        assert red > 150 and green < 90 and blue < 90, (red, green, blue)
print('locked-session refusal passed' if args.expect_session_locked
      else 'known-red hardware capture passed')
