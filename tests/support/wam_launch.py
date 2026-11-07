"""Launches WAM with its test seams armed and reads back what it reported.

The seams (WAM_TEST_*, src/qt/test_seams.hpp) exist only in a telemetry build
and only when WAM_NATIVE_BENCHMARK_TELEMETRY carries a valid run identity;
without it every seam is silently off. seam_env() is the one place that
identity is spelled.
"""
import contextlib
import json
import os
import subprocess
import uuid
from pathlib import Path


def seam_env(home, **extra):
    """The environment for a quiet, parked, muted seam launch with HOME=home."""
    env = dict(os.environ, HOME=str(home),
               WAM_NATIVE_BENCHMARK_TELEMETRY='1',
               WAM_NATIVE_BENCHMARK_RUN_ID=str(uuid.uuid4()),
               WAM_NATIVE_BENCHMARK_ASSET_SHA256='0' * 64,
               WAM_NATIVE_BENCHMARK_CANDIDATE_ID='1' * 64,
               WAM_TEST_BACKGROUND='1', WAM_TEST_MUTED='1',
               WAM_TEST_GEOMETRY='480x270+2400+1000')
    env.update({key: str(value) for key, value in extra.items()})
    return env


def records(text):
    """Every JSON object line in text (test reports, notices, telemetry)."""
    result = []
    for line in text.splitlines():
        # Other diagnostics share stderr; a brace-led line that is not JSON is
        # one of them, not a report.
        if line.startswith('{'):
            with contextlib.suppress(ValueError):
                result.append(json.loads(line))
    return result


def run(executable, args, env, log, timeout):
    """Runs WAM to completion with stdout/stderr in log. Returns (code, text).

    On timeout, samples the hung child's stacks into <log>.sample.txt, kills
    only that child and raises with the log tail, so a hang fails in bounded
    time with the evidence needed to find it."""
    log = Path(log)
    with log.open('w') as sink:
        child = subprocess.Popen([str(executable)] + [str(a) for a in args], env=env,
                                 stdin=subprocess.DEVNULL, stdout=sink, stderr=sink)
        try:
            code = child.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            stacks = log.with_name(log.name + '.sample.txt')
            with contextlib.suppress(OSError, subprocess.SubprocessError):
                subprocess.run(['/usr/bin/sample', str(child.pid), '1', '-file', str(stacks)],
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=15)
            child.kill()
            try:
                child.wait(timeout=10)
                fate = 'killed'
            except subprocess.TimeoutExpired:
                fate = 'still alive 10 s after SIGKILL (stuck in the kernel)'
            raise AssertionError(f'WAM pid {child.pid} did not exit within {timeout:g} s and was {fate}; '
                                 f'stacks: {stacks}; log: {log}\n'
                                 + log.read_text(errors='replace')[-3000:])
    return code, log.read_text(errors='replace')
