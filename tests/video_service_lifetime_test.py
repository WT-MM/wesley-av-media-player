#!/usr/bin/env python3
"""Quiet Cocoa integration: no per-client VT service survives any normal quit.

Usage: python3 tests/video_service_lifetime_test.py build/WAM.app [--output DIR]
Requires a telemetry build, ffmpeg and a logged-in macOS GUI session. Fixtures
are synthesized. Ownership comes from launchd's exact client PID domain, never
from the global count alone. Other apps may start/stop decoding during the test.
"""
import argparse
import datetime
import json
import math
import os
import pathlib
import re
import signal
import subprocess
import tempfile
import sys
import time

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent / "support"))
import wam_launch  # noqa: E402

SERVICE = "com.apple.coremedia.videodecoder"
EXE = "/System/Library/Frameworks/VideoToolbox.framework/Versions/A/XPCServices/VTDecoderXPCService.xpc/Contents/MacOS/VTDecoderXPCService"


def services():
    result = {}
    text = subprocess.check_output(["ps", "-axo", "pid=,lstart=,comm="], text=True)
    for line in text.splitlines():
        parts = line.split(None, 6)
        if len(parts) == 7 and parts[6] == EXE:
            started = datetime.datetime.strptime(" ".join(parts[1:6]), "%a %b %d %H:%M:%S %Y").timestamp()
            result[int(parts[0])] = started
    return result


def own_service(client):
    target = f"pid/{client}/{SERVICE}"
    try:
        query = subprocess.run(["/bin/launchctl", "print", target], text=True,
                               stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=3)
    except subprocess.TimeoutExpired:
        return None  # A slow query under load; the next poll asks again.
    text = query.stdout
    if not text.startswith(target + " = {\n"):
        return None
    domain = text.rfind(f"\n\tdomain = pid/{client} [")
    if domain < 0 or f"\n\tprogram = {EXE}\n" not in text:
        return None
    match = re.search(r"\n\tpid = ([0-9]+)\n", text[domain:])
    return int(match[1]) if match else None


def stop(process):
    if process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            process.kill()  # Only this test's own child.
            process.wait(timeout=5)


def events(log):
    return [r["event"] for r in wam_launch.records(log.read_text(errors="replace")) if r.get("record") == "event"]


def run_case(app, root, media, name, extra, sentinel):
    dest = root / name
    dest.mkdir()
    log = dest / "stderr.log"
    before = services()
    started = time.time()
    owned = {}
    env = wam_launch.seam_env(dest, LC_ALL="C", QT_MAC_DISABLE_FOREGROUND_APPLICATION_TRANSFORM="1",
                              WAM_TEST_QUIT_AFTER_MS="4000")
    env.pop("QT_QPA_PLATFORM", None)
    env.update(extra)
    command = [str(app / "Contents/MacOS/WAM")] + ([str(media)] if media else [])
    with log.open("w") as err:
        process = subprocess.Popen(command, env=env, stdout=subprocess.DEVNULL, stderr=err)
        try:
            deadline = time.monotonic() + 20
            signal_at = time.monotonic() + 3
            while process.poll() is None and time.monotonic() < deadline:
                peer = own_service(process.pid)
                live = services()
                if peer in live and peer not in before and live[peer] >= math.floor(started):
                    owned[peer] = live[peer]
                if name.endswith("sigterm") and time.monotonic() >= signal_at:
                    process.terminate()
                    signal_at = float("inf")
                time.sleep(0.1)
            process.wait(timeout=1)
            assert process.returncode == 0, (name, process.returncode, log.read_text()[-3000:])
            # Under load the SIGTERMed helper can take several seconds to go
            # once its client has exited; an unretired one never goes.
            exited = time.monotonic()
            deadline = exited + 30
            stable = 0
            while time.monotonic() < deadline:
                after = services()
                survivors = {pid: stamp for pid, stamp in owned.items() if after.get(pid) == stamp}
                stable = stable + 1 if not survivors else 0
                if stable >= 3:
                    break
                time.sleep(0.1)
            receipt = dict(client_pid=process.pid, before_count=len(before), after_count=len(after),
                           owned=owned, survivors=survivors, exit_code=process.returncode,
                           retired_after_s=round(time.monotonic() - exited, 1))
            (dest / "result.json").write_text(json.dumps(receipt, indent=2))
            assert not survivors, (name, "orphaned owned VT services", survivors)
            assert services().get(sentinel[0]) == sentinel[1], "unrelated decoder service was terminated"
            facts = events(log)
            if media is None:
                assert not owned and "open_requested" not in facts, "blank launch must not start a decoder"
            else:
                assert owned, (name, "no actual VT service observed; decode was not exercised")
                if name.startswith("fallback"):
                    assert "fallback_selected" in facts and "fallback_load_begin" in facts, (name, facts)
                else:
                    assert "first_frame_drawn" in facts and "fallback_selected" not in facts, (name, facts)
            if name == "native-preview":
                assert "preview_frame_drawn" in facts and "commit_frame_drawn" in facts, (name, facts)
            print(f"{name}: passed; owned={list(owned)} survivors=0 retired_after_s={receipt['retired_after_s']}",
                  flush=True)
        finally:
            stop(process)
            # A failing regression must not accumulate more orphans. Identity
            # was captured from this live client's domain and includes lstart.
            live = services()
            for pid, stamp in owned.items():
                if live.get(pid) == stamp:
                    os.kill(pid, signal.SIGTERM)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=pathlib.Path)
    parser.add_argument("--ffmpeg", default="ffmpeg")
    parser.add_argument("--output", type=pathlib.Path)
    args = parser.parse_args()
    os.environ["LC_ALL"] = "C"
    with tempfile.TemporaryDirectory(prefix="wam-vt-lifetime-") as temporary:
        root = args.output.resolve() if args.output else pathlib.Path(temporary)
        root.mkdir(parents=True, exist_ok=True)
        media = root / "h264.mp4"
        subprocess.run([args.ffmpeg, "-v", "error", "-y", "-f", "lavfi", "-i",
                        "testsrc2=size=160x90:rate=24:duration=12", "-c:v", "libx264",
                        "-threads", "1", "-pix_fmt", "yuv420p", "-bf", "2", str(media)], check=True)
        playlist = root / "fallback.m3u"
        playlist.write_text("#EXTM3U\n" + str(media) + "\n")
        # A separate, live hardware decoder must survive every WAM quit. This
        # also tests count/ownership isolation against unrelated concurrent use.
        with (root / "sentinel.log").open("w") as err:
            control = subprocess.Popen([args.ffmpeg, "-v", "error", "-re", "-stream_loop", "-1",
                                        "-hwaccel", "videotoolbox", "-i", str(media),
                                        "-f", "null", "-"], stdout=subprocess.DEVNULL, stderr=err)
            try:
                deadline = time.monotonic() + 10
                sentinel = None
                while time.monotonic() < deadline and control.poll() is None:
                    peer = own_service(control.pid)
                    live = services()
                    if peer in live:
                        sentinel = (peer, live[peer])
                        break
                    time.sleep(0.1)
                assert sentinel, "control hardware decoder did not start"
                for name, fixture, extra in [
                    ("blank", None, {}),
                    ("native-quit", media, {}),
                    ("native-menu", media, {"WAM_TEST_QUIT_MODE": "menu"}),
                    ("native-close-quit", media, {"WAM_TEST_WINDOW_SCRIPT": "close:0@2000"}),
                    ("native-sigterm", media, {"WAM_TEST_QUIT_AFTER_MS": "15000"}),
                    ("native-preview", media, {"WAM_TEST_SEEK_SCRIPT": "6@1.5"}),
                    ("fallback-quit", playlist, {}),
                    ("fallback-sigterm", playlist, {"WAM_TEST_QUIT_AFTER_MS": "15000"}),
                ]:
                    run_case(args.app.resolve(), root, fixture, name, extra, sentinel)
            finally:
                stop(control)


if __name__ == "__main__":
    main()
