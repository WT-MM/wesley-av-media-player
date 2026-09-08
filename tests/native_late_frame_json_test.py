"""The widest diagnostic record must remain complete, parseable JSON."""
import json
import os
import subprocess
import sys

result = subprocess.run([sys.argv[1]], capture_output=True, text=True,
    env={**os.environ, 'WAM_NATIVE_BENCHMARK_TELEMETRY': '1',
         'WAM_PLAYBACK_METRICS_PATH': '/dev/stdout'})
assert result.returncode == 0, (result.returncode, result.stderr)
rows = [json.loads(line) for line in result.stdout.splitlines()]
assert len(rows) == 3, rows
trace, health, sample = rows
assert trace['record'] == 'video_frame_trace'
assert trace['ordinal'] == 2**64 - 1 and trace['pts_value'] == -2**63
assert trace['display_refresh_phase']['reference_host_ticks'] == 2**64 - 1
assert trace['worker_wait_due_ticks'] == 2**64 - 1
assert trace['slow_wait_since_submission']['due_ticks'] == 2**64 - 1
assert trace['output_path_ticks'] == [2**64 - 1] * 10
assert health['lost_or_unavailable'] == 0
assert sample['discarded_late_frames'] == 2**64 - 1
