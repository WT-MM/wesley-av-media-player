#!/usr/bin/env python3
"""Launch one macOS player, warm it, and run the WAM metric collector.

The orchestrator is intentionally conservative: it refuses to use a player
that is already running, records the exact process identities it created, and
only sends SIGTERM when the PID still has the same executable and start time.
It never deletes application data or edits preferences itself. Players still
run with their normal profiles and may persist their usual playback state.
"""

from __future__ import annotations

import argparse
import ctypes
import dataclasses
import datetime as dt
import hashlib
import json
import math
import os
import plistlib
import re
import signal
import struct
import subprocess
import sys
import time
import uuid
from pathlib import Path
from typing import Any, Callable, Mapping, Sequence


PROJECT_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_COLLECTOR = Path(__file__).with_name("collect.py")
DEFAULT_VLC_APP = Path("/Applications/VLC.app")
DEFAULT_QUICKTIME_APP = Path("/System/Applications/QuickTime Player.app")
DEFAULT_WINDOW = (1180, 720)
HELPER_BASENAME = "VTDecoderXPCService"
NATIVE_TELEMETRY_ENV = "WAM_NATIVE_BENCHMARK_TELEMETRY"
NATIVE_TELEMETRY_RUN_ID_ENV = "WAM_NATIVE_BENCHMARK_RUN_ID"
NATIVE_TELEMETRY_ASSET_SHA256_ENV = "WAM_NATIVE_BENCHMARK_ASSET_SHA256"
NATIVE_TELEMETRY_SCHEMA = "wam.native.benchmark.v1"
NATIVE_TELEMETRY_FRAMED_SCHEMA = "wam.native.benchmark.v2"
NATIVE_TELEMETRY_CANDIDATE_ID_ENV = "WAM_NATIVE_BENCHMARK_CANDIDATE_ID"
NATIVE_PROOF_INELIGIBLE_EXIT = 3
PS_LSTART_FORMAT = "%a %b %d %H:%M:%S %Y"
# `ps lstart` is only precise to one second. VLC's re-parented Rosetta peer can
# therefore land in the next displayed second even though it was created as
# part of the same launch. Keep this grace deliberately short: the executable
# must also be exact, absent from the pre-launch table, and the player is later
# required to have the benchmark's unique media alias open.
COMPANION_START_GRACE_S = 2.0
FOREGROUND_SAMPLE_INTERVAL_S = 0.5
# A missed deadline is itself contamination: once the gap exceeds 2.5 polling
# periods, the harness can no longer prove that the target remained foreground.
FOREGROUND_SAMPLE_GAP_FACTOR = 2.5
DECODER_HELPER_SAMPLE_INTERVAL_S = 0.05
# The helper proof is requested at 20 Hz. Allow two missed deadlines plus half
# a period for scheduler jitter; anything larger leaves a material blind spot.
# WAM_BENCH_HELPER_GAP_NS relaxes the cap for development machines whose
# process-table read alone exceeds the strict budget; the effective value is
# recorded in the continuity report, so a relaxed run is always identifiable.
DECODER_HELPER_MAX_OBSERVATION_GAP_NS = int(
    os.environ.get("WAM_BENCH_HELPER_GAP_NS", "125000000")
)
VLC_FATAL_VIDEO_LOG_PATTERNS = (
    "failed to adapt decoder format to display",
    "video output creation failed",
    "failed to create video output",
    "buffer deadlock prevented",
)
_PROC_PIDPATH: Any | None | bool = None
_NATIVE_WINDOW_READER: Any | None | bool = None


class SuiteError(RuntimeError):
    """A benchmark setup or validation failure."""


class NativeProofIneligible(SuiteError):
    """The run cannot support a native-performance claim."""


@dataclasses.dataclass(frozen=True)
class ProcessIdentity:
    pid: int
    ppid: int
    started: str
    executable: str

    def as_dict(self) -> dict[str, Any]:
        return dataclasses.asdict(self)


@dataclasses.dataclass
class LaunchHandle:
    process: subprocess.Popen[bytes]
    identity: ProcessIdentity
    command: list[str]
    log_path: Path
    log_file: Any


@dataclasses.dataclass(frozen=True)
class ResourceCoalition:
    coalition_id: int
    name: str | None
    bundle_id: str | None
    active_count: int | None = None

    def as_dict(self) -> dict[str, Any]:
        return dataclasses.asdict(self)


def utc_now() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat()


def finite_positive(value: str) -> float:
    parsed = float(value)
    if not math.isfinite(parsed) or parsed <= 0:
        raise argparse.ArgumentTypeError("must be a finite number greater than zero")
    return parsed


def finite_nonnegative(value: str) -> float:
    parsed = float(value)
    if not math.isfinite(parsed) or parsed < 0:
        raise argparse.ArgumentTypeError("must be a finite number at least zero")
    return parsed


def window_size(value: str) -> tuple[int, int]:
    match = re.fullmatch(r"\s*(\d+)\s*[xX]\s*(\d+)\s*", value)
    if not match:
        raise argparse.ArgumentTypeError("must look like WIDTHxHEIGHT, for example 1180x720")
    width, height = (int(part) for part in match.groups())
    if width <= 0 or height <= 0:
        raise argparse.ArgumentTypeError("window dimensions must be positive")
    return width, height


def parse_process_table(raw: str) -> dict[int, ProcessIdentity]:
    """Parse `ps pid,ppid,lstart,comm`, retaining paths containing spaces."""

    processes: dict[int, ProcessIdentity] = {}
    for line in raw.splitlines():
        # lstart is five whitespace-delimited fields. Splitting seven times
        # leaves the complete executable path, including any spaces.
        fields = line.strip().split(None, 7)
        if len(fields) != 8:
            continue
        try:
            pid, ppid = int(fields[0]), int(fields[1])
        except ValueError:
            continue
        processes[pid] = ProcessIdentity(
            pid=pid,
            ppid=ppid,
            started=" ".join(fields[2:7]),
            executable=fields[7],
        )
    return processes


def process_table() -> dict[int, ProcessIdentity]:
    result = subprocess.run(
        ["/bin/ps", "-ww", "-axo", "pid=,ppid=,lstart=,comm="],
        capture_output=True,
        text=True,
        timeout=10,
        check=False,
    )
    if result.returncode != 0:
        raise SuiteError(f"could not inspect processes: {result.stderr.strip() or result.returncode}")
    return resolve_relative_process_paths(parse_process_table(result.stdout))


def process_identity(pid: int) -> ProcessIdentity | None:
    """Read one exact process identity without scanning every process.

    Foreground validity is sampled during the measured interval, so the
    lower-volume one-PID form avoids repeatedly perturbing the host with a
    complete process-table scan.
    """

    result = subprocess.run(
        [
            "/bin/ps",
            "-ww",
            "-p",
            str(pid),
            "-o",
            "pid=,ppid=,lstart=,comm=",
        ],
        capture_output=True,
        text=True,
        timeout=3,
        check=False,
    )
    if result.returncode not in (0, 1):
        raise SuiteError(
            f"could not inspect target PID {pid}: "
            f"{result.stderr.strip() or result.returncode}"
        )
    parsed = resolve_relative_process_paths(parse_process_table(result.stdout))
    return parsed.get(pid)


def _absolute_executable_for_pid(pid: int) -> str | None:
    """Ask macOS for the kernel-resolved executable path of one process."""

    if sys.platform != "darwin":
        return None
    global _PROC_PIDPATH
    try:
        if _PROC_PIDPATH is None:
            libproc = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
            proc_pidpath = libproc.proc_pidpath
            proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
            proc_pidpath.restype = ctypes.c_int
            _PROC_PIDPATH = proc_pidpath
        if _PROC_PIDPATH is False:
            return None
        buffer = ctypes.create_string_buffer(4096)
        length = _PROC_PIDPATH(pid, buffer, len(buffer))
    except (OSError, AttributeError):
        _PROC_PIDPATH = False
        return None
    if length <= 0:
        return None
    return os.fsdecode(buffer.value)


def resolve_relative_process_paths(
    processes: Mapping[int, ProcessIdentity],
    resolver: Any = _absolute_executable_for_pid,
) -> dict[int, ProcessIdentity]:
    """Replace ambiguous relative `ps comm` values with kernel paths."""

    resolved: dict[int, ProcessIdentity] = {}
    for pid, identity in processes.items():
        if os.path.isabs(identity.executable):
            resolved[pid] = identity
            continue
        absolute = resolver(pid)
        resolved[pid] = (
            dataclasses.replace(identity, executable=absolute)
            if absolute and os.path.isabs(absolute)
            else identity
        )
    return resolved


def _normalized_executable(value: str | Path) -> str:
    return os.path.realpath(os.fspath(value))


def same_executable(observed: str, expected: str | Path) -> bool:
    expected_text = os.fspath(expected)
    if os.path.isabs(observed):
        return _normalized_executable(observed) == _normalized_executable(expected_text)
    # A relative `comm` value cannot establish executable identity. Treating a
    # basename such as "WAM" as sufficient would make an unrelated or stale
    # build block the run and, more importantly, weaken termination safety.
    # The benchmark launcher always passes an absolute executable path, so its
    # own process is expected to have an absolute `comm` value on macOS.
    return False


def same_identity(left: ProcessIdentity, right: ProcessIdentity) -> bool:
    return (
        left.pid == right.pid
        and left.started == right.started
        and same_executable(left.executable, right.executable)
    )


def process_start_delta_seconds(left: ProcessIdentity, right: ProcessIdentity) -> float | None:
    """Return the absolute `ps lstart` delta, or None for an unknown format."""

    if left.started == right.started:
        return 0.0
    try:
        left_start = dt.datetime.strptime(left.started, PS_LSTART_FORMAT)
        right_start = dt.datetime.strptime(right.started, PS_LSTART_FORMAT)
    except ValueError:
        return None
    return abs((left_start - right_start).total_seconds())


def is_launch_companion(main: ProcessIdentity, candidate: ProcessIdentity) -> bool:
    delta = process_start_delta_seconds(main, candidate)
    return delta is not None and delta <= COMPANION_START_GRACE_S


def matching_executable(
    processes: Mapping[int, ProcessIdentity], executable: Path
) -> list[ProcessIdentity]:
    return [identity for identity in processes.values() if same_executable(identity.executable, executable)]


def helper_processes(processes: Mapping[int, ProcessIdentity]) -> dict[int, ProcessIdentity]:
    return {
        pid: identity
        for pid, identity in processes.items()
        if os.path.basename(identity.executable) == HELPER_BASENAME
    }


def parse_resource_coalition(raw: str) -> ResourceCoalition:
    match = re.search(r"resource coalition = \{(?P<body>.*?)\n\t\}", raw, re.DOTALL)
    if not match:
        raise ValueError("launchctl output has no resource coalition")
    body = match.group("body")
    id_match = re.search(r"^\s*ID = (\d+)\s*$", body, re.MULTILINE)
    if not id_match:
        raise ValueError("resource coalition has no numeric ID")

    def optional_value(label: str) -> str | None:
        value_match = re.search(rf"^\s*{re.escape(label)} = (.+?)\s*$", body, re.MULTILINE)
        return value_match.group(1).strip() if value_match else None

    active_count_match = re.search(
        r"^\s*active count = (\d+)\s*$", body, re.MULTILINE
    )
    if not active_count_match:
        raise ValueError("resource coalition has no active process count")
    return ResourceCoalition(
        coalition_id=int(id_match.group(1)),
        name=optional_value("name"),
        bundle_id=optional_value("bundle ID"),
        active_count=int(active_count_match.group(1)),
    )


def process_resource_coalition(pid: int) -> ResourceCoalition:
    result = subprocess.run(
        ["/bin/launchctl", "print", f"pid/{pid}"],
        capture_output=True,
        text=True,
        timeout=3,
        check=False,
    )
    if result.returncode != 0:
        raise SuiteError(
            f"could not inspect resource coalition for PID {pid}: "
            f"{result.stderr.strip() or result.returncode}"
        )
    try:
        return parse_resource_coalition(result.stdout)
    except ValueError as error:
        raise SuiteError(f"could not parse resource coalition for PID {pid}: {error}") from error


def read_bundle_executable(app: Path) -> Path:
    info_path = app / "Contents" / "Info.plist"
    try:
        with info_path.open("rb") as stream:
            info = plistlib.load(stream)
    except (OSError, plistlib.InvalidFileException) as error:
        raise SuiteError(f"could not read app bundle metadata at {info_path}: {error}") from error
    name = info.get("CFBundleExecutable")
    if not isinstance(name, str) or not name:
        raise SuiteError(f"{info_path} has no CFBundleExecutable")
    return app / "Contents" / "MacOS" / name


def app_bundle_for_executable(executable: Path) -> Path:
    for parent in executable.parents:
        if parent.suffix.lower() == ".app":
            return parent
    raise SuiteError(f"could not locate an app bundle above executable: {executable}")


def resolve_executable(path: Path, label: str) -> Path:
    expanded = path.expanduser().resolve()
    executable = read_bundle_executable(expanded) if expanded.suffix.lower() == ".app" else expanded
    if not executable.is_file():
        raise SuiteError(f"{label} executable does not exist: {executable}")
    if not os.access(executable, os.X_OK):
        raise SuiteError(f"{label} executable is not executable: {executable}")
    return executable


def default_wam_path() -> Path:
    candidates = (
        PROJECT_ROOT / "dist" / "WAM.app",
        PROJECT_ROOT / "build" / "WAM.app",
        PROJECT_ROOT / "build-qt" / "WAM.app",
    )
    for candidate in candidates:
        if candidate.exists():
            return candidate
    raise SuiteError("could not find WAM.app; pass --wam-app /path/to/WAM.app or its executable")


def player_executable(args: argparse.Namespace) -> Path:
    if args.player == "wam":
        return resolve_executable(args.wam or default_wam_path(), "WAM")
    if args.player == "vlc":
        return resolve_executable(args.vlc, "VLC")
    return resolve_executable(args.quicktime, "QuickTime Player")


def format_number(value: float) -> str:
    return format(value, ".12g")


def validate_player_options(args: argparse.Namespace) -> None:
    if args.player != "wam":
        return
    if not math.isclose(args.start_time, 0.0, rel_tol=0.0, abs_tol=1e-9):
        raise SuiteError("automated WAM runs currently require --start-time 0")
    if args.window != DEFAULT_WINDOW:
        raise SuiteError("WAM's normal CLI uses its built-in 1180x720 window; custom sizes are not controlled")


def build_player_command(
    player: str,
    executable: Path,
    clip: Path,
    speed: float,
    start_time: float,
    window: tuple[int, int],
    native_telemetry_path: Path | None = None,
    native_run_id: str | None = None,
    native_asset_sha256: str | None = None,
    native_candidate_id: str | None = None,
) -> list[str]:
    if player == "vlc":
        width, height = window
        return [
            str(executable),
            f"--rate={format_number(speed)}",
            f"--start-time={format_number(start_time)}",
            f"--width={width}",
            f"--height={height}",
            # Keep VLC from resizing its Cocoa window back to the video's
            # native 4K dimensions after automation applies the common bounds.
            "--no-macosx-video-autoresize",
            "--no-video-title-show",
            str(clip),
        ]
    if player == "wam":
        native_identity = (
            native_telemetry_path,
            native_run_id,
            native_asset_sha256,
            native_candidate_id,
        )
        if any(value is not None for value in native_identity) and not all(
            value is not None for value in native_identity
        ):
            raise SuiteError(
                "WAM benchmark telemetry path, cryptographic run ID, and asset SHA-256 "
                "must be supplied together"
            )
        if native_asset_sha256 is not None and not re.fullmatch(
            r"[0-9a-f]{64}", native_asset_sha256
        ):
            raise SuiteError("WAM benchmark asset SHA-256 must be 64 lowercase hex digits")
        if native_candidate_id is not None and not re.fullmatch(
            r"[0-9a-f]{64}", native_candidate_id
        ):
            raise SuiteError("WAM benchmark candidate ID must be 64 lowercase hex digits")
        # LaunchServices gives the benchmark app its own macOS resource
        # coalition. Directly exec'ing WAM from the harness inherits Codex's
        # coalition and makes VideoToolbox helper ownership ambiguous.
        command = [
            "/usr/bin/open",
            "-n",
            "-W",
        ]
        if native_telemetry_path is not None:
            # LaunchServices does not reliably inherit arbitrary caller
            # environment into an application. `open --env` makes this
            # benchmark-only opt-in explicit, while `--stderr` keeps JSONL
            # proof separate from ordinary launcher diagnostics.
            command.extend(
                [
                    "--env",
                    f"{NATIVE_TELEMETRY_ENV}=1",
                    "--env",
                    f"{NATIVE_TELEMETRY_RUN_ID_ENV}={native_run_id}",
                    "--env",
                    f"{NATIVE_TELEMETRY_ASSET_SHA256_ENV}={native_asset_sha256}",
                    "--env",
                    f"{NATIVE_TELEMETRY_CANDIDATE_ID_ENV}={native_candidate_id}",
                    "--stderr",
                    str(native_telemetry_path),
                ]
            )
        command.extend(
            [
                "-a",
                str(app_bundle_for_executable(executable)),
                "--args",
                f"--rate={format_number(speed)}",
                str(clip),
            ]
        )
        return command
    # Launch the system app through LaunchServices, as Finder does. On current
    # macOS releases invoking QuickTime's bundle executable directly can be
    # killed before AppKit finishes launching. `-n` creates a fresh instance
    # and `-W` keeps this harmless launcher alive until that instance exits;
    # launch attribution below still resolves the exact QuickTime executable.
    return [
        "/usr/bin/open",
        "-n",
        "-W",
        "-a",
        str(DEFAULT_QUICKTIME_APP),
        str(clip),
        "--args",
        "-ApplePersistenceIgnoreState",
        "YES",
    ]


def _wait_for_main_process(
    process: subprocess.Popen[bytes],
    expected_executable: Path,
    before: Mapping[int, ProcessIdentity],
    timeout: float,
) -> ProcessIdentity:
    deadline = time.monotonic() + timeout
    last_exit: int | None = None
    while time.monotonic() < deadline:
        current = process_table()
        direct = current.get(process.pid)
        if (
            direct is not None
            and process.pid not in before
            and same_executable(direct.executable, expected_executable)
        ):
            return direct

        # LaunchServices and similar supported app launchers own a different
        # PID/executable. Attribute the one exact new target process as soon as
        # it appears, even while the launcher is still waiting for it to exit.
        candidates = [
            identity
            for identity in matching_executable(current, expected_executable)
            if identity.pid not in before
        ]
        if len(candidates) == 1:
            return candidates[0]
        if len(candidates) > 1:
            raise SuiteError(
                "more than one new matching player appeared; refusing ambiguous PID attribution"
            )

        last_exit = process.poll()
        if last_exit is not None:
            if not candidates:
                raise SuiteError(f"player exited during launch with status {last_exit}")
        time.sleep(0.1)
    raise SuiteError(f"timed out waiting for {expected_executable.name} to launch")


def launch_player(
    command: Sequence[str],
    executable: Path,
    before: Mapping[int, ProcessIdentity],
    log_path: Path,
    timeout: float,
) -> LaunchHandle:
    log_file = log_path.open("xb")
    process: subprocess.Popen[bytes] | None = None
    try:
        process = subprocess.Popen(
            list(command),
            stdin=subprocess.DEVNULL,
            stdout=log_file,
            stderr=subprocess.STDOUT,
            close_fds=True,
        )
        identity = _wait_for_main_process(process, executable, before, timeout)
        return LaunchHandle(process, identity, list(command), log_path, log_file)
    except BaseException:
        # If launch validation failed after Popen returned, clean up only that
        # exact, newly created PID. Never infer a target from a name alone.
        if process is not None:
            try:
                observed = process_table().get(process.pid)
                if (
                    observed is not None
                    and process.pid not in before
                    and same_executable(observed.executable, executable)
                ):
                    terminate_exact(observed)
            except SuiteError:
                pass
        log_file.close()
        raise


def _osascript(
    script: str,
    timeout: float = 3.0,
    arguments: Sequence[str] = (),
) -> subprocess.CompletedProcess[str]:
    command = ["/usr/bin/osascript", "-e", script, *arguments]
    try:
        return subprocess.run(
            command,
            capture_output=True,
            text=True,
            timeout=timeout,
            check=False,
        )
    except subprocess.TimeoutExpired as error:
        stdout = error.stdout if isinstance(error.stdout, str) else ""
        stderr = error.stderr if isinstance(error.stderr, str) else ""
        detail = f"osascript timed out after {timeout:g}s"
        return subprocess.CompletedProcess(
            command,
            124,
            stdout=stdout,
            stderr=f"{stderr.strip() + '; ' if stderr.strip() else ''}{detail}",
        )


def _apple_float(value: str) -> float:
    text = value.strip()
    if "," in text and "." not in text:
        text = text.replace(",", ".")
    return float(text)


def parse_quicktime_state(raw: str) -> dict[str, Any]:
    fields = raw.strip().split("\t")
    if len(fields) != 8:
        raise ValueError(f"unexpected QuickTime state: {raw!r}")
    return {
        "current_time_s": _apple_float(fields[0]),
        "duration_s": _apple_float(fields[1]),
        "rate": _apple_float(fields[2]),
        "playing": fields[3].strip().lower() == "true",
        "bounds": [int(round(_apple_float(value))) for value in fields[4:8]],
    }


def parse_vlc_state(raw: str) -> dict[str, Any]:
    fields = raw.rstrip("\n").split("\t", 7)
    if len(fields) != 8:
        raise ValueError(f"unexpected VLC state: {raw!r}")
    return {
        "current_time_s": _apple_float(fields[0]),
        "duration_s": _apple_float(fields[1]),
        "playing": fields[2].strip().lower() == "true",
        "bounds": [int(round(_apple_float(value))) for value in fields[3:7]],
        "path": fields[7].strip(),
    }


def parse_wam_window_state(raw: str) -> dict[str, Any]:
    fields = raw.rstrip("\n").split("\t", 5)
    if len(fields) != 6:
        raise ValueError(f"unexpected WAM window state: {raw!r}")
    left, top, width, height = [
        int(round(_apple_float(value))) for value in fields[1:5]
    ]
    return {
        "frontmost": fields[0].strip().lower() == "true",
        "position": [left, top],
        "size": [width, height],
        "bounds": [left, top, left + width, top + height],
        "process_name": fields[5].strip(),
    }


class _CGPoint(ctypes.Structure):
    _fields_ = [("x", ctypes.c_double), ("y", ctypes.c_double)]


class _CGSize(ctypes.Structure):
    _fields_ = [("width", ctypes.c_double), ("height", ctypes.c_double)]


class _CGRect(ctypes.Structure):
    _fields_ = [("origin", _CGPoint), ("size", _CGSize)]


class _MacWindowReader:
    """Low-overhead, read-only frontmost PID and window geometry reader."""

    _ON_SCREEN_ONLY = 1 << 0
    _EXCLUDE_DESKTOP_ELEMENTS = 1 << 4
    _CF_NUMBER_SINT64 = 4

    def __init__(self) -> None:
        # Loading AppKit registers NSWorkspace with the Objective-C runtime.
        ctypes.CDLL("/System/Library/Frameworks/AppKit.framework/AppKit")
        self._objc = ctypes.CDLL("/usr/lib/libobjc.A.dylib")
        self._cg = ctypes.CDLL(
            "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics"
        )
        self._cf = ctypes.CDLL(
            "/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation"
        )

        self._objc.objc_getClass.argtypes = [ctypes.c_char_p]
        self._objc.objc_getClass.restype = ctypes.c_void_p
        self._objc.sel_registerName.argtypes = [ctypes.c_char_p]
        self._objc.sel_registerName.restype = ctypes.c_void_p
        message_address = ctypes.cast(self._objc.objc_msgSend, ctypes.c_void_p).value
        if not message_address:
            raise OSError("Objective-C message dispatch is unavailable")
        self._message_object = ctypes.CFUNCTYPE(
            ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p
        )(message_address)
        self._message_pid = ctypes.CFUNCTYPE(
            ctypes.c_int, ctypes.c_void_p, ctypes.c_void_p
        )(message_address)
        self._workspace_class = self._objc.objc_getClass(b"NSWorkspace")
        if not self._workspace_class:
            raise OSError("NSWorkspace is unavailable")
        self._shared_workspace = self._objc.sel_registerName(b"sharedWorkspace")
        self._frontmost_application = self._objc.sel_registerName(
            b"frontmostApplication"
        )
        self._process_identifier = self._objc.sel_registerName(b"processIdentifier")

        self._cg.CGWindowListCopyWindowInfo.argtypes = [
            ctypes.c_uint32,
            ctypes.c_uint32,
        ]
        self._cg.CGWindowListCopyWindowInfo.restype = ctypes.c_void_p
        self._cg.CGRectMakeWithDictionaryRepresentation.argtypes = [
            ctypes.c_void_p,
            ctypes.POINTER(_CGRect),
        ]
        self._cg.CGRectMakeWithDictionaryRepresentation.restype = ctypes.c_bool
        self._cf.CFArrayGetCount.argtypes = [ctypes.c_void_p]
        self._cf.CFArrayGetCount.restype = ctypes.c_long
        self._cf.CFArrayGetValueAtIndex.argtypes = [ctypes.c_void_p, ctypes.c_long]
        self._cf.CFArrayGetValueAtIndex.restype = ctypes.c_void_p
        self._cf.CFDictionaryGetValue.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
        self._cf.CFDictionaryGetValue.restype = ctypes.c_void_p
        self._cf.CFNumberGetValue.argtypes = [
            ctypes.c_void_p,
            ctypes.c_int,
            ctypes.c_void_p,
        ]
        self._cf.CFNumberGetValue.restype = ctypes.c_bool
        self._cf.CFRelease.argtypes = [ctypes.c_void_p]
        self._owner_pid_key = ctypes.c_void_p.in_dll(
            self._cg, "kCGWindowOwnerPID"
        ).value
        self._layer_key = ctypes.c_void_p.in_dll(self._cg, "kCGWindowLayer").value
        self._bounds_key = ctypes.c_void_p.in_dll(self._cg, "kCGWindowBounds").value
        if not all((self._owner_pid_key, self._layer_key, self._bounds_key)):
            raise OSError("CoreGraphics window dictionary keys are unavailable")

    def _frontmost_pid(self) -> int:
        workspace = self._message_object(
            self._workspace_class, self._shared_workspace
        )
        application = self._message_object(workspace, self._frontmost_application)
        if not application:
            raise OSError("NSWorkspace returned no frontmost application")
        pid = int(self._message_pid(application, self._process_identifier))
        if pid <= 0:
            raise OSError("NSWorkspace returned an invalid frontmost PID")
        return pid

    def _dictionary_int(self, dictionary: int, key: int) -> int | None:
        number = self._cf.CFDictionaryGetValue(dictionary, key)
        if not number:
            return None
        value = ctypes.c_longlong()
        if not self._cf.CFNumberGetValue(
            number, self._CF_NUMBER_SINT64, ctypes.byref(value)
        ):
            return None
        return int(value.value)

    def _target_bounds(self, pid: int) -> list[int]:
        options = self._ON_SCREEN_ONLY | self._EXCLUDE_DESKTOP_ELEMENTS
        windows = self._cg.CGWindowListCopyWindowInfo(options, 0)
        if not windows:
            raise OSError("CoreGraphics returned no on-screen window list")
        try:
            count = int(self._cf.CFArrayGetCount(windows))
            for index in range(count):
                window = self._cf.CFArrayGetValueAtIndex(windows, index)
                if not window:
                    continue
                if self._dictionary_int(window, self._layer_key) != 0:
                    continue
                if self._dictionary_int(window, self._owner_pid_key) != pid:
                    continue
                bounds_dictionary = self._cf.CFDictionaryGetValue(
                    window, self._bounds_key
                )
                bounds = _CGRect()
                if not bounds_dictionary or not self._cg.CGRectMakeWithDictionaryRepresentation(
                    bounds_dictionary, ctypes.byref(bounds)
                ):
                    continue
                left = int(round(bounds.origin.x))
                top = int(round(bounds.origin.y))
                width = int(round(bounds.size.width))
                height = int(round(bounds.size.height))
                return [left, top, left + width, top + height]
        finally:
            self._cf.CFRelease(windows)
        raise OSError(f"CoreGraphics found no layer-zero window for PID {pid}")

    def state(self, pid: int) -> dict[str, Any]:
        bounds = self._target_bounds(pid)
        return {
            "frontmost": self._frontmost_pid() == pid,
            "position": bounds[:2],
            "size": [bounds[2] - bounds[0], bounds[3] - bounds[1]],
            "bounds": bounds,
            "process_name": None,
            "query_backend": "NSWorkspace+CoreGraphics",
        }


QUICKTIME_STATE_SCRIPT = r'''
on run argv
set targetName to item 1 of argv
tell application id "com.apple.QuickTimePlayerX"
    if not (exists document targetName) then error "target QuickTime document is not open"
    set d to document targetName
    set b to bounds of window targetName
    set currentTimeValue to current time of d
    set durationValue to duration of d
    set rateValue to rate of d
    set playingValue to playing of d
    set oldDelimiters to AppleScript's text item delimiters
    set AppleScript's text item delimiters to tab
    set outputText to {(currentTimeValue as text), (durationValue as text), (rateValue as text), (playingValue as text), ((item 1 of b) as text), ((item 2 of b) as text), ((item 3 of b) as text), ((item 4 of b) as text)} as text
    set AppleScript's text item delimiters to oldDelimiters
    return outputText
end tell
end run
'''


VLC_STATE_SCRIPT = r'''
tell application id "org.videolan.vlc"
    if (count of windows) is 0 then error "no VLC window"
    set b to bounds of front window
    -- Resolve VLC's scriptable properties to ordinary AppleScript values
    -- before joining them. Coercing a list of application object specifiers
    -- directly fails on VLC 3.0.21 with error -1700.
    set currentTimeValue to current time
    set durationValue to duration of current item
    set playingValue to playing
    set pathValue to path of current item
    set oldDelimiters to AppleScript's text item delimiters
    set AppleScript's text item delimiters to tab
    set outputText to {(currentTimeValue as text), (durationValue as text), (playingValue as text), ((item 1 of b) as text), ((item 2 of b) as text), ((item 3 of b) as text), ((item 4 of b) as text), (pathValue as text)} as text
    set AppleScript's text item delimiters to oldDelimiters
    return outputText
end tell
'''


TARGET_WINDOW_STATE_SCRIPT = r'''
on run argv
set targetPid to item 1 of argv as integer
tell application "System Events"
    set matchingProcesses to every application process whose unix id is targetPid
    if (count of matchingProcesses) is not 1 then error "target player process is unavailable"
    set targetProcess to item 1 of matchingProcesses
    if (count of windows of targetProcess) is 0 then error "target player process has no window"
    set frontmostValue to frontmost of targetProcess
    set positionValue to position of window 1 of targetProcess
    set sizeValue to size of window 1 of targetProcess
    set processNameValue to name of targetProcess as text
end tell
set oldDelimiters to AppleScript's text item delimiters
set AppleScript's text item delimiters to tab
set outputText to {(frontmostValue as text), ((item 1 of positionValue) as text), ((item 2 of positionValue) as text), ((item 1 of sizeValue) as text), ((item 2 of sizeValue) as text), processNameValue} as text
set AppleScript's text item delimiters to oldDelimiters
return outputText
end run
'''


WAM_CONFIGURE_WINDOW_SCRIPT = r'''
on run argv
set targetPid to item 1 of argv as integer
set targetLeft to item 2 of argv as integer
set targetTop to item 3 of argv as integer
set targetWidth to item 4 of argv as integer
set targetHeight to item 5 of argv as integer
tell application "System Events"
    set matchingProcesses to every application process whose unix id is targetPid
    if (count of matchingProcesses) is not 1 then error "target WAM process is unavailable"
    set targetProcess to item 1 of matchingProcesses
    if (count of windows of targetProcess) is 0 then error "target WAM process has no window"
    set frontmost of targetProcess to true
    tell window 1 of targetProcess
        set position to {targetLeft, targetTop}
        set size to {targetWidth, targetHeight}
    end tell
end tell
end run
'''


def quicktime_state(document_name: str) -> dict[str, Any]:
    result = _osascript(QUICKTIME_STATE_SCRIPT, arguments=(document_name,))
    if result.returncode != 0:
        raise SuiteError(f"could not query QuickTime: {result.stderr.strip() or result.stdout.strip()}")
    try:
        return parse_quicktime_state(result.stdout)
    except ValueError as error:
        raise SuiteError(str(error)) from error


def vlc_state() -> dict[str, Any]:
    result = _osascript(VLC_STATE_SCRIPT)
    if result.returncode != 0:
        raise SuiteError(f"could not query VLC: {result.stderr.strip() or result.stdout.strip()}")
    try:
        return parse_vlc_state(result.stdout)
    except ValueError as error:
        raise SuiteError(str(error)) from error


def target_window_state(pid: int) -> dict[str, Any]:
    """Read frontmost state and bounds without activating or moving an app."""

    global _NATIVE_WINDOW_READER
    native_error: str | None = None
    if sys.platform == "darwin" and _NATIVE_WINDOW_READER is not False:
        if _NATIVE_WINDOW_READER is None:
            try:
                _NATIVE_WINDOW_READER = _MacWindowReader()
            except (OSError, AttributeError, TypeError, ValueError) as error:
                native_error = str(error)
                _NATIVE_WINDOW_READER = False
        if _NATIVE_WINDOW_READER is not False:
            try:
                return _NATIVE_WINDOW_READER.state(pid)
            except (OSError, AttributeError, TypeError, ValueError) as error:
                native_error = str(error)

    result = _osascript(TARGET_WINDOW_STATE_SCRIPT, arguments=(str(pid),))
    if result.returncode != 0:
        raise SuiteError(
            "could not query target player window: "
            f"{result.stderr.strip() or result.stdout.strip()}"
            + (f"; native query also failed: {native_error}" if native_error else "")
        )
    try:
        state = parse_wam_window_state(result.stdout)
    except ValueError as error:
        raise SuiteError(str(error)) from error
    state["query_backend"] = "System Events AppleScript fallback"
    if native_error:
        state["native_query_error"] = native_error
    return state


def wam_window_state(pid: int) -> dict[str, Any]:
    """Compatibility wrapper for existing WAM-specific setup checks."""

    return target_window_state(pid)


def configure_wam(
    pid: int,
    window: tuple[int, int],
    timeout: float,
) -> dict[str, Any]:
    width, height = window
    left, top = 80, 80
    arguments = tuple(str(value) for value in (pid, left, top, width, height))
    expected_bounds = [left, top, left + width, top + height]
    deadline = time.monotonic() + timeout
    last_error = "WAM did not expose its window"
    while time.monotonic() < deadline:
        result = _osascript(WAM_CONFIGURE_WINDOW_SCRIPT, arguments=arguments)
        if result.returncode != 0:
            last_error = result.stderr.strip() or result.stdout.strip() or last_error
            time.sleep(0.2)
            continue
        try:
            state = wam_window_state(pid)
        except SuiteError as error:
            last_error = str(error)
            time.sleep(0.2)
            continue
        if state["frontmost"] and state["bounds"] == expected_bounds:
            return state
        last_error = (
            f"WAM reported frontmost={state['frontmost']} "
            f"bounds={state['bounds']}"
        )
        time.sleep(0.2)
    raise SuiteError(f"could not configure WAM window: {last_error}")


def configure_vlc(
    start_time: float,
    window: tuple[int, int],
    timeout: float,
) -> dict[str, Any]:
    width, height = window
    left, top = 80, 80
    script = f'''
tell application id "org.videolan.vlc"
    activate
    if (count of windows) is 0 then error "no VLC window"
    set fullscreen mode to false
    set bounds of front window to {{{left}, {top}, {left + width}, {top + height}}}
    set current time to {format_number(start_time)}
    if not playing then play
end tell
'''
    deadline = time.monotonic() + timeout
    expected_bounds = [left, top, left + width, top + height]
    last_error = "VLC did not expose an active item"
    while time.monotonic() < deadline:
        result = _osascript(script)
        if result.returncode != 0:
            last_error = result.stderr.strip() or result.stdout.strip() or last_error
            time.sleep(0.2)
            continue
        try:
            state = vlc_state()
        except SuiteError as error:
            last_error = str(error)
            time.sleep(0.2)
            continue
        if state["playing"] and state["bounds"] == expected_bounds and state["duration_s"] > 0:
            return state
        last_error = (
            f"VLC reported playing={state['playing']} duration={state['duration_s']} "
            f"bounds={state['bounds']}"
        )
        time.sleep(0.2)
    raise SuiteError(f"could not configure VLC: {last_error}")


def configure_quicktime(
    document_name: str,
    start_time: float,
    speed: float,
    window: tuple[int, int],
    timeout: float,
) -> dict[str, Any]:
    width, height = window
    left, top = 80, 80
    script = f'''
on run argv
set targetName to item 1 of argv
tell application id "com.apple.QuickTimePlayerX"
    activate
    if not (exists document targetName) then error "target QuickTime document is not open"
    set d to document targetName
    set index of window targetName to 1
    set bounds of window targetName to {{{left}, {top}, {left + width}, {top + height}}}
    set current time of d to {format_number(start_time)}
    play d
    set rate of d to {format_number(speed)}
end tell
end run
'''
    deadline = time.monotonic() + timeout
    last_error = "QuickTime did not expose a document"
    expected_bounds = [left, top, left + width, top + height]
    while time.monotonic() < deadline:
        # A document can exist before its media pipeline is ready. QuickTime
        # accepts `play` and `set rate` in that state but silently remains at
        # 0x; reapply the idempotent setup until the queried state proves it
        # took effect. Reapplying bounds also wins the initial native-size
        # autoresize race.
        result = _osascript(script, arguments=(document_name,))
        if result.returncode != 0:
            last_error = result.stderr.strip() or result.stdout.strip() or last_error
            time.sleep(0.2)
            continue
        try:
            state = quicktime_state(document_name)
        except SuiteError as error:
            last_error = str(error)
            time.sleep(0.2)
            continue
        rate_matches = math.isclose(
            float(state["rate"]), speed, rel_tol=0.02, abs_tol=0.02
        )
        if state["playing"] and rate_matches and state["bounds"] == expected_bounds:
            return state
        last_error = (
            f"QuickTime reported playing={state['playing']} rate={state['rate']} "
            f"bounds={state['bounds']}"
        )
        time.sleep(0.2)
    raise SuiteError(f"could not configure QuickTime: {last_error}")


def discover_helpers_during_warmup(
    before: Mapping[int, ProcessIdentity],
    main_identity: ProcessIdentity,
    warmup: float,
    target_coalition_id: int,
    periodic_callback: Callable[[], Any] | None = None,
) -> tuple[dict[int, ProcessIdentity], dict[int, dict[str, Any]]]:
    before_helpers = helper_processes(before)
    discovered: dict[int, ProcessIdentity] = {}
    unrelated: dict[int, dict[str, Any]] = {}
    deadline = time.monotonic() + warmup
    while True:
        if periodic_callback is not None:
            periodic_callback()
        current = process_table()
        live_main = current.get(main_identity.pid)
        if live_main is None or not same_identity(main_identity, live_main):
            raise SuiteError("the launched player exited or changed identity during warm-up")
        for pid, identity in helper_processes(current).items():
            previous = before_helpers.get(pid)
            if previous is not None and same_identity(previous, identity):
                continue
            if pid in discovered or pid in unrelated:
                continue
            coalition = process_resource_coalition(pid)
            if coalition.coalition_id == target_coalition_id:
                discovered[pid] = identity
            else:
                unrelated[pid] = {
                    "process": identity.as_dict(),
                    "resource_coalition": coalition.as_dict(),
                }
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            break
        time.sleep(min(0.25, remaining))
    return discovered, unrelated


def partition_new_helpers_by_coalition(
    identities: Sequence[ProcessIdentity], target_coalition_id: int
) -> tuple[list[ProcessIdentity], list[dict[str, Any]]]:
    owned: list[ProcessIdentity] = []
    unrelated: list[dict[str, Any]] = []
    for identity in identities:
        coalition = process_resource_coalition(identity.pid)
        if coalition.coalition_id == target_coalition_id:
            owned.append(identity)
        else:
            unrelated.append(
                {
                    "process": identity.as_dict(),
                    "resource_coalition": coalition.as_dict(),
                }
            )
    return owned, unrelated


class DecoderHelperContinuityTracker:
    """Prove the exact decoder-helper set for every measurement observation.

    A helper's PID alone is not identity: PID reuse with a new process start is
    recorded as contamination. The ever-seen set is retained independently of
    the final process table, so a late same-coalition helper cannot escape the
    proof merely by exiting before end validation.
    """

    def __init__(
        self,
        before: Mapping[int, ProcessIdentity],
        main_identity: ProcessIdentity,
        expected_helpers: Sequence[ProcessIdentity],
        target_coalition_id: int,
        *,
        require_helper: bool,
        table_reader: Callable[[], Mapping[int, ProcessIdentity]] = process_table,
        coalition_reader: Callable[[int], ResourceCoalition] = process_resource_coalition,
        clock_ns: Callable[[], int] = time.monotonic_ns,
        maximum_observation_gap_ns: int = DECODER_HELPER_MAX_OBSERVATION_GAP_NS,
    ) -> None:
        if maximum_observation_gap_ns <= 0:
            raise ValueError("maximum helper observation gap must be positive")
        expected_by_pid: dict[int, ProcessIdentity] = {}
        exact_keys: set[tuple[int, str, str]] = set()
        for identity in expected_helpers:
            key = (
                identity.pid,
                identity.started,
                _normalized_executable(identity.executable),
            )
            if identity.pid in expected_by_pid or key in exact_keys:
                raise SuiteError("decoder helper identities must be unique by PID and start")
            if os.path.basename(identity.executable) != HELPER_BASENAME:
                raise SuiteError(
                    f"PID {identity.pid} is not an exact {HELPER_BASENAME} identity"
                )
            expected_by_pid[identity.pid] = identity
            exact_keys.add(key)

        self._before_helpers = helper_processes(before)
        self.main_identity = main_identity
        self.expected_helpers = expected_by_pid
        self.target_coalition_id = target_coalition_id
        self.require_helper = require_helper
        self._table_reader = table_reader
        self._coalition_reader = coalition_reader
        self._clock_ns = clock_ns
        self.maximum_observation_gap_ns = maximum_observation_gap_ns
        self._samples: list[dict[str, Any]] = []
        self._violation_keys: set[tuple[Any, ...]] = set()
        self._violations: list[dict[str, Any]] = []
        self._ever_same_coalition: dict[tuple[int, str, str], dict[str, Any]] = {}

    @staticmethod
    def _identity_key(identity: ProcessIdentity) -> tuple[int, str, str]:
        return (
            identity.pid,
            identity.started,
            _normalized_executable(identity.executable),
        )

    def _record_violation(
        self,
        reason: str,
        sample_index: int,
        identity: ProcessIdentity | None = None,
        detail: str | None = None,
    ) -> None:
        key = (
            reason,
            identity.pid if identity is not None else None,
            identity.started if identity is not None else None,
            identity.executable if identity is not None else None,
            detail,
        )
        if key in self._violation_keys:
            return
        self._violation_keys.add(key)
        item: dict[str, Any] = {
            "reason": reason,
            "first_observed_sample": sample_index,
        }
        if identity is not None:
            item["process"] = identity.as_dict()
        if detail is not None:
            item["detail"] = detail
        self._violations.append(item)

    def sample(self) -> dict[str, Any]:
        observed_at_ns = self._clock_ns()
        sample_index = len(self._samples)
        sample: dict[str, Any] = {
            "sample": sample_index,
            "monotonic_ns": observed_at_ns,
            "main_process": None,
            "main_resource_coalition": None,
            "helpers": [],
            "unrelated_helpers": [],
            "coalition_active_count_check": None,
            "violations": [],
        }
        violations_before = len(self._violations)
        if self._samples:
            previous_ns = int(self._samples[-1]["monotonic_ns"])
            gap_ns = observed_at_ns - previous_ns
            if gap_ns <= 0 or gap_ns > self.maximum_observation_gap_ns:
                self._record_violation(
                    "decoder_helper_observation_gap",
                    sample_index,
                    detail=(
                        f"observed {gap_ns}ns, maximum "
                        f"{self.maximum_observation_gap_ns}ns"
                    ),
                )
        try:
            current = dict(self._table_reader())
        except Exception as error:
            self._record_violation(
                "process_table_query_failed", sample_index, detail=str(error)
            )
            sample["violations"] = self._violations[violations_before:]
            self._samples.append(sample)
            return sample

        observed_main = current.get(self.main_identity.pid)
        sample["main_process"] = (
            observed_main.as_dict() if observed_main is not None else None
        )
        if observed_main is None:
            self._record_violation("main_process_missing", sample_index)
        elif not same_identity(self.main_identity, observed_main):
            self._record_violation(
                "main_process_identity_changed", sample_index, observed_main
            )
        else:
            try:
                main_coalition = self._coalition_reader(observed_main.pid)
            except Exception as error:
                self._record_violation(
                    "main_process_coalition_query_failed",
                    sample_index,
                    observed_main,
                    str(error),
                )
            else:
                sample["main_resource_coalition"] = main_coalition.as_dict()
                if main_coalition.coalition_id != self.target_coalition_id:
                    self._record_violation(
                        "main_process_coalition_changed",
                        sample_index,
                        observed_main,
                        detail=(
                            f"observed {main_coalition.coalition_id}, expected "
                            f"{self.target_coalition_id}"
                        ),
                    )

        current_helpers = helper_processes(current)
        for pid, expected in self.expected_helpers.items():
            observed = current_helpers.get(pid)
            if observed is None:
                self._record_violation("decoder_helper_missing", sample_index, expected)

        for pid, observed in current_helpers.items():
            expected = self.expected_helpers.get(pid)
            exact_expected_identity = (
                expected is not None and same_identity(expected, observed)
            )
            if expected is not None and not exact_expected_identity:
                self._record_violation(
                    "decoder_helper_identity_changed",
                    sample_index,
                    observed,
                    detail=f"expected start {expected.started!r}",
                )
            before_identity = self._before_helpers.get(pid)
            try:
                coalition = self._coalition_reader(pid)
            except Exception as error:
                self._record_violation(
                    "decoder_helper_coalition_query_failed",
                    sample_index,
                    observed,
                    str(error),
                )
                continue
            evidence = {
                "process": observed.as_dict(),
                "resource_coalition": coalition.as_dict(),
                "expected_at_measurement_start": exact_expected_identity,
            }
            if coalition.coalition_id == self.target_coalition_id:
                sample["helpers"].append(evidence)
                self._ever_same_coalition[self._identity_key(observed)] = evidence
                if not exact_expected_identity:
                    reason = (
                        "preexisting_same_coalition_decoder_helper"
                        if before_identity is not None
                        and same_identity(before_identity, observed)
                        else "late_same_coalition_decoder_helper"
                    )
                    self._record_violation(reason, sample_index, observed)
            else:
                sample["unrelated_helpers"].append(evidence)
                if expected is not None:
                    self._record_violation(
                        "decoder_helper_coalition_changed",
                        sample_index,
                        observed,
                        detail=(
                            f"observed {coalition.coalition_id}, expected "
                            f"{self.target_coalition_id}"
                        ),
                    )

        sample["helpers"].sort(key=lambda item: item["process"]["pid"])
        sample["unrelated_helpers"].sort(
            key=lambda item: item["process"]["pid"]
        )
        expected_active_count = 1 + len(sample["helpers"])
        active_count_observations: list[dict[str, Any]] = []
        main_resource_coalition = sample["main_resource_coalition"]
        if (
            isinstance(main_resource_coalition, Mapping)
            and main_resource_coalition.get("coalition_id")
            == self.target_coalition_id
            and observed_main is not None
        ):
            active_count_observations.append(
                {
                    "role": "app",
                    "process": observed_main.as_dict(),
                    "active_count": main_resource_coalition.get("active_count"),
                }
            )
        active_count_observations.extend(
            {
                "role": "decoder_helper",
                "process": evidence["process"],
                "active_count": evidence["resource_coalition"].get(
                    "active_count"
                ),
            }
            for evidence in sample["helpers"]
        )
        for observation in active_count_observations:
            identity_value = observation["process"]
            identity = ProcessIdentity(
                pid=int(identity_value["pid"]),
                ppid=int(identity_value["ppid"]),
                started=str(identity_value["started"]),
                executable=str(identity_value["executable"]),
            )
            active_count = observation["active_count"]
            if active_count is None:
                self._record_violation(
                    "resource_coalition_active_count_missing",
                    sample_index,
                    identity,
                )
            elif not isinstance(active_count, int) or isinstance(
                active_count, bool
            ):
                self._record_violation(
                    "resource_coalition_active_count_invalid",
                    sample_index,
                    identity,
                    detail=f"observed {active_count!r}",
                )
            elif active_count > expected_active_count:
                self._record_violation(
                    "resource_coalition_surplus_member",
                    sample_index,
                    identity,
                    detail=(
                        f"active count {active_count}, exact app-plus-helper "
                        f"count {expected_active_count}"
                    ),
                )
            elif active_count < expected_active_count:
                self._record_violation(
                    "resource_coalition_active_count_mismatch",
                    sample_index,
                    identity,
                    detail=(
                        f"active count {active_count}, exact app-plus-helper "
                        f"count {expected_active_count}"
                    ),
                )
        sample["coalition_active_count_check"] = {
            "expected_active_count": expected_active_count,
            "observations": active_count_observations,
            "all_observations_present": len(active_count_observations)
            == expected_active_count,
            "all_match": bool(active_count_observations)
            and len(active_count_observations) == expected_active_count
            and all(
                isinstance(observation["active_count"], int)
                and not isinstance(observation["active_count"], bool)
                and observation["active_count"] == expected_active_count
                for observation in active_count_observations
            ),
        }
        sample["violations"] = self._violations[violations_before:]
        self._samples.append(sample)
        return sample

    def report(self) -> dict[str, Any]:
        if self.require_helper and not self.expected_helpers:
            self._record_violation(
                "no_same_coalition_decoder_helper_at_measurement_start", 0
            )
        if not self._samples:
            self._record_violation("no_measurement_helper_observations", 0)
        expected = sorted(
            (identity.as_dict() for identity in self.expected_helpers.values()),
            key=lambda item: item["pid"],
        )
        ever_seen = sorted(
            self._ever_same_coalition.values(),
            key=lambda item: (
                item["process"]["pid"],
                item["process"]["started"],
            ),
        )
        return {
            "valid": not self._violations,
            "required_for_player": self.require_helper,
            "maximum_observation_gap_ns": self.maximum_observation_gap_ns,
            "target_coalition_id": self.target_coalition_id,
            "expected_helpers": expected,
            "expected_helper_count": len(expected),
            "exact_identity_fields": ["pid", "started", "executable"],
            "sample_count": len(self._samples),
            "requested_observation_interval_ns": int(
                DECODER_HELPER_SAMPLE_INTERVAL_S * 1_000_000_000
            ),
            "maximum_observation_gap_ns": self.maximum_observation_gap_ns,
            "ever_seen_same_coalition_helpers": ever_seen,
            "violations": list(self._violations),
            "samples": list(self._samples),
        }


def require_clean_decoder_helper_continuity(report: Mapping[str, Any]) -> None:
    if report.get("valid") is True:
        return
    violations = report.get("violations", ())
    reasons = sorted(
        {
            str(item.get("reason"))
            for item in violations
            if isinstance(item, Mapping) and item.get("reason")
        }
    )
    detail = ", ".join(reasons) if reasons else "proof unavailable"
    raise SuiteError(f"decoder helper continuity proof failed: {detail}")


def discover_companion_players_during_warmup(
    before: Mapping[int, ProcessIdentity],
    main_identity: ProcessIdentity,
    executable: Path,
    warmup: float,
    initial: Mapping[int, ProcessIdentity] | None = None,
) -> dict[int, ProcessIdentity]:
    """Track app-owned peer processes without claiming unrelated launches.

    VLC 3 on Apple silicon can spawn a second, re-parented copy of its x86_64
    executable while the original process owns playback. It is part of the
    workload and must be measured and terminated, but a genuinely later user
    launch must never be touched. macOS `ps lstart` has one-second resolution;
    accepting only new exact executables within a two-second launch bucket
    captures VLC's peer across `lstart` rounding while treating later peers as
    ambiguous.
    """

    discovered = dict(initial or {})
    deadline = time.monotonic() + warmup
    while True:
        current = process_table()
        live_main = current.get(main_identity.pid)
        if live_main is None or not same_identity(main_identity, live_main):
            raise SuiteError("the launched player exited or changed identity during warm-up")
        for identity in matching_executable(current, executable):
            if identity.pid == main_identity.pid or identity.pid in before:
                continue
            if not is_launch_companion(main_identity, identity):
                raise SuiteError(
                    "another matching player appeared during warm-up outside the launch grace; "
                    "refusing ambiguous automation"
                )
            discovered.setdefault(identity.pid, identity)
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            break
        time.sleep(min(0.25, remaining))
    return discovered


def inspect_player_launch_log(player: str, path: Path) -> dict[str, Any]:
    """Detect decisive playback failures that a moving audio clock can hide."""

    try:
        text = path.read_text(encoding="utf-8", errors="replace")
    except OSError as error:
        raise SuiteError(f"could not inspect player launch log {path}: {error}") from error
    fatal_patterns: list[str] = []
    if player == "vlc":
        lowered = text.lower()
        fatal_patterns = [pattern for pattern in VLC_FATAL_VIDEO_LOG_PATTERNS if pattern in lowered]
    return {
        "path": str(path),
        "bytes": len(text.encode("utf-8")),
        "fatal_video_patterns": fatal_patterns,
    }


def require_viable_video_output(player: str, path: Path) -> dict[str, Any]:
    validation = inspect_player_launch_log(player, path)
    failures = validation["fatal_video_patterns"]
    if failures:
        raise SuiteError(
            f"{player} reported fatal video-output failure(s): {', '.join(failures)}"
        )
    return validation


def require_expected_player_state(
    player: str,
    state: Mapping[str, Any],
    clip: Path,
    speed: float,
    window: tuple[int, int],
) -> None:
    width, height = window
    expected_bounds = [80, 80, 80 + width, 80 + height]
    if not state.get("playing"):
        raise SuiteError(f"{player} was not playing")
    if list(state.get("bounds", [])) != expected_bounds:
        raise SuiteError(
            f"{player} window bounds changed: {state.get('bounds')} != {expected_bounds}"
        )
    if player == "quicktime" and not math.isclose(
        float(state.get("rate", 0.0)), speed, rel_tol=0.02, abs_tol=0.02
    ):
        raise SuiteError(f"QuickTime playback rate changed: {state.get('rate')} != {speed}")
    if player == "vlc" and os.path.normpath(str(state.get("path", ""))) != os.path.normpath(
        str(clip)
    ):
        raise SuiteError(f"VLC switched away from the exact benchmark clip: {state.get('path')}")


def require_expected_wam_window_state(
    state: Mapping[str, Any], window: tuple[int, int]
) -> None:
    width, height = window
    expected_bounds = [80, 80, 80 + width, 80 + height]
    if not state.get("frontmost"):
        raise SuiteError("WAM was not the frontmost application")
    if list(state.get("bounds", [])) != expected_bounds:
        raise SuiteError(
            f"WAM window bounds changed: {state.get('bounds')} != {expected_bounds}"
        )


def _validity_contamination_intervals(
    samples: Sequence[Mapping[str, Any]],
    phases: Sequence[Mapping[str, Any]],
    sample_interval_s: float,
) -> list[dict[str, Any]]:
    """Compact invalid samples and proof-coverage gaps into intervals."""

    maximum_gap = sample_interval_s * FOREGROUND_SAMPLE_GAP_FACTOR
    events: list[dict[str, Any]] = []
    for phase in phases:
        name = str(phase["phase"])
        start = float(phase["started_offset_s"])
        end_value = phase.get("ended_offset_s")
        if end_value is None:
            continue
        end = float(end_value)
        phase_samples = [sample for sample in samples if sample.get("phase") == name]
        phase_samples.sort(key=lambda sample: float(sample["offset_s"]))

        index = 0
        while index < len(phase_samples):
            if phase_samples[index].get("valid"):
                index += 1
                continue
            first_invalid = index
            while index < len(phase_samples) and not phase_samples[index].get("valid"):
                index += 1
            last_invalid = index - 1
            first_observed = float(phase_samples[first_invalid]["offset_s"])
            last_observed = float(phase_samples[last_invalid]["offset_s"])
            # Polling proves state only at sample instants. Bound the possible
            # contaminated interval by the adjacent clean samples rather than
            # pretending the exact focus transition time is known.
            interval_start = (
                float(phase_samples[first_invalid - 1]["offset_s"])
                if first_invalid > 0
                else start
            )
            interval_end = (
                float(phase_samples[index]["offset_s"])
                if index < len(phase_samples)
                else end
            )
            reasons = {
                reason
                for sample in phase_samples[first_invalid:index]
                for reason in sample.get("reasons", ())
            }
            events.append(
                {
                    "phase": name,
                    "start_offset_s": interval_start,
                    "end_offset_s": max(interval_start, interval_end),
                    "first_observed_offset_s": first_observed,
                    "last_observed_offset_s": last_observed,
                    "boundary_precision": "bounded_by_adjacent_samples",
                    "reasons": sorted(reasons),
                    "invalid_sample_count": index - first_invalid,
                }
            )

        boundaries: list[tuple[float, float]] = []
        if phase_samples:
            boundaries.append((start, float(phase_samples[0]["offset_s"])))
            boundaries.extend(
                (
                    float(previous["offset_s"]),
                    float(current["offset_s"]),
                )
                for previous, current in zip(phase_samples, phase_samples[1:])
            )
            boundaries.append((float(phase_samples[-1]["offset_s"]), end))
        else:
            boundaries.append((start, end))
        for left, right in boundaries:
            gap = right - left
            if gap <= maximum_gap:
                continue
            events.append(
                {
                    "phase": name,
                    "start_offset_s": min(right, left + sample_interval_s),
                    "end_offset_s": right,
                    "reasons": ["sampling_coverage_gap"],
                    "invalid_sample_count": 0,
                    "observed_gap_s": gap,
                }
            )

    events.sort(key=lambda event: (float(event["start_offset_s"]), str(event["phase"])))
    merged: list[dict[str, Any]] = []
    for event in events:
        if (
            merged
            and merged[-1]["phase"] == event["phase"]
            and float(event["start_offset_s"]) <= float(merged[-1]["end_offset_s"]) + 1e-9
        ):
            previous = merged[-1]
            previous["end_offset_s"] = max(
                float(previous["end_offset_s"]), float(event["end_offset_s"])
            )
            previous["reasons"] = sorted(
                set(previous["reasons"]) | set(event["reasons"])
            )
            previous["invalid_sample_count"] = int(
                previous["invalid_sample_count"]
            ) + int(event["invalid_sample_count"])
            if "observed_gap_s" in event:
                previous["maximum_observed_gap_s"] = max(
                    float(previous.get("maximum_observed_gap_s", 0.0)),
                    float(event["observed_gap_s"]),
                )
            continue
        item = dict(event)
        if "observed_gap_s" in item:
            item["maximum_observed_gap_s"] = item.pop("observed_gap_s")
        merged.append(item)

    for interval in merged:
        interval["duration_s"] = max(
            0.0,
            float(interval["end_offset_s"]) - float(interval["start_offset_s"]),
        )
    return merged


class ForegroundWindowValidityTracker:
    """Periodically prove exact PID, foreground ownership, and window bounds.

    Sampling is deliberately synchronous. It uses read-only `ps` and System
    Events queries, never `activate`, click automation, or a focus-changing UI
    inspection process. The caller invokes `sample_if_due` while it is already
    waiting for warm-up or the metric collector.
    """

    def __init__(
        self,
        identity: ProcessIdentity,
        window: tuple[int, int],
        *,
        sample_interval_s: float = FOREGROUND_SAMPLE_INTERVAL_S,
        identity_reader: Callable[[int], ProcessIdentity | None] = process_identity,
        state_reader: Callable[[int], dict[str, Any]] = target_window_state,
        clock: Callable[[], float] = time.monotonic,
        timestamp: Callable[[], str] = utc_now,
    ) -> None:
        if not math.isfinite(sample_interval_s) or sample_interval_s <= 0:
            raise ValueError("sample_interval_s must be finite and positive")
        self.identity = identity
        self.window = window
        self.sample_interval_s = sample_interval_s
        self._identity_reader = identity_reader
        self._state_reader = state_reader
        self._clock = clock
        self._timestamp = timestamp
        self._origin = clock()
        self._active_phase: str | None = None
        self._next_due = self._origin
        self._samples: list[dict[str, Any]] = []
        self._phases: list[dict[str, Any]] = []

    def begin_phase(self, phase: str) -> None:
        if self._active_phase is not None:
            raise RuntimeError(f"validity phase {self._active_phase!r} is still active")
        if any(item["phase"] == phase for item in self._phases):
            raise RuntimeError(f"validity phase {phase!r} was already recorded")
        now = self._clock()
        self._active_phase = phase
        self._next_due = now
        self._phases.append(
            {
                "phase": phase,
                "started_at": self._timestamp(),
                "started_offset_s": now - self._origin,
                "ended_at": None,
                "ended_offset_s": None,
            }
        )
        self.sample_if_due(force=True)

    def sample_if_due(self, *, force: bool = False) -> dict[str, Any] | None:
        phase = self._active_phase
        if phase is None:
            return None
        query_started = self._clock()
        if not force and query_started < self._next_due:
            return None

        observed_identity: ProcessIdentity | None = None
        state: dict[str, Any] | None = None
        reasons: list[str] = []
        errors: list[str] = []
        try:
            observed_identity = self._identity_reader(self.identity.pid)
        except Exception as error:
            reasons.append("process_identity_query_failed")
            errors.append(str(error))
        if not reasons:
            if observed_identity is None:
                reasons.append("process_unavailable")
            elif not same_identity(self.identity, observed_identity):
                reasons.append("process_identity_changed")

        if not reasons:
            try:
                state = self._state_reader(self.identity.pid)
            except Exception as error:
                reasons.append("window_state_query_failed")
                errors.append(str(error))
        if state is not None:
            width, height = self.window
            expected_bounds = [80, 80, 80 + width, 80 + height]
            if not state.get("frontmost"):
                reasons.append("not_frontmost")
            if list(state.get("bounds", ())) != expected_bounds:
                reasons.append("window_bounds_changed")

        query_finished = self._clock()
        sample = {
            "at": self._timestamp(),
            "phase": phase,
            "target_pid": self.identity.pid,
            "offset_s": query_finished - self._origin,
            "query_duration_s": query_finished - query_started,
            "valid": not reasons,
            "reasons": sorted(set(reasons)),
            "observed_process": (
                observed_identity.as_dict() if observed_identity is not None else None
            ),
            "window": state,
        }
        if errors:
            sample["errors"] = errors
        self._samples.append(sample)
        self._next_due = query_started + self.sample_interval_s
        while self._next_due <= query_finished:
            self._next_due += self.sample_interval_s
        return sample

    def end_phase(self) -> None:
        if self._active_phase is None:
            return
        phase = self._active_phase
        self.sample_if_due(force=True)
        now = self._clock()
        current = self._phases[-1]
        if current["phase"] != phase:
            raise RuntimeError("validity phase bookkeeping became inconsistent")
        current["ended_at"] = self._timestamp()
        current["ended_offset_s"] = now - self._origin
        self._active_phase = None

    def report(self) -> dict[str, Any]:
        phases = [dict(item) for item in self._phases]
        if phases and phases[-1]["ended_offset_s"] is None:
            phases[-1]["ended_at"] = self._timestamp()
            phases[-1]["ended_offset_s"] = self._clock() - self._origin
        samples = [dict(item) for item in self._samples]
        intervals = _validity_contamination_intervals(
            samples, phases, self.sample_interval_s
        )
        gaps = [
            float(current["offset_s"]) - float(previous["offset_s"])
            for previous, current in zip(samples, samples[1:])
            if current.get("phase") == previous.get("phase")
        ]
        query_durations = [float(sample["query_duration_s"]) for sample in samples]
        monitored_duration = sum(
            max(
                0.0,
                float(phase["ended_offset_s"]) - float(phase["started_offset_s"]),
            )
            for phase in phases
            if phase["ended_offset_s"] is not None
        )
        total_query_duration = sum(query_durations)
        return {
            "method": (
                "read-only exact-PID ps identity plus non-activating "
                "NSWorkspace/CoreGraphics frontmost/window polling; System Events is "
                "used only as a recorded fallback"
            ),
            "sample_interval_s": self.sample_interval_s,
            "maximum_allowed_gap_s": (
                self.sample_interval_s * FOREGROUND_SAMPLE_GAP_FACTOR
            ),
            "target_process": self.identity.as_dict(),
            "phases": phases,
            "sample_count": len(samples),
            "maximum_observed_same_phase_gap_s": max(gaps, default=0.0),
            "sampler_overhead": {
                "total_query_s": total_query_duration,
                "mean_query_s": (
                    total_query_duration / len(query_durations)
                    if query_durations
                    else 0.0
                ),
                "maximum_query_s": max(query_durations, default=0.0),
                "query_duty_fraction": (
                    total_query_duration / monitored_duration
                    if monitored_duration > 0
                    else None
                ),
                "included_in_target_process_metrics": False,
            },
            "samples": samples,
            "contamination_intervals": intervals,
            "valid": not intervals and all(phase["ended_offset_s"] is not None for phase in phases),
        }


def require_clean_foreground_validity(
    report: Mapping[str, Any], phase: str | None = None
) -> None:
    intervals = [
        interval
        for interval in report.get("contamination_intervals", ())
        if phase is None or interval.get("phase") == phase
    ]
    if intervals:
        reasons = sorted(
            {
                reason
                for interval in intervals
                for reason in interval.get("reasons", ())
            }
        )
        label = f"{phase} " if phase else ""
        raise SuiteError(
            f"{label}foreground/window/PID validity was contaminated "
            f"({', '.join(reasons)}); performance metrics rejected"
        )


def render_telemetry_availability(player: str) -> dict[str, Any]:
    """Describe renderer counters without enabling behavior-changing controls."""

    reasons = {
        "wam": (
            "Decoded/presented/dropped-frame counters are not exported. WAM benchmark "
            "launches separately request the env-gated native JSONL route and exact "
            "FrameDrawn proof stream; a run without that proof is ineligible."
        ),
        "vlc": (
            "VLC's normal macOS AppleScript interface does not expose decoded, presented, "
            "or dropped-frame counters. No RC/debug interface is enabled during a benchmark."
        ),
        "quicktime": (
            "QuickTime Player's public macOS scripting interface does not expose decoded, "
            "presented, or dropped-frame counters."
        ),
    }
    return {
        "availability": "unavailable",
        "decoded_frames": None,
        "presented_frames": None,
        "dropped_frames": None,
        "repeated_frames": None,
        "reason": reasons[player],
        "playback_configuration_changed_for_telemetry": False,
    }


def parse_wam_native_telemetry(raw: str) -> dict[str, Any]:
    """Parse WAM's opt-in JSONL without treating unrelated stderr as proof."""

    if NATIVE_TELEMETRY_FRAMED_SCHEMA in raw:
        return _parse_framed_wam_native_telemetry(raw)

    required_integer_fields = (
        "monotonic_ns",
        "source_key",
        "attempt",
        "serial",
        "generation",
        "gesture",
        "request",
        "draw_sequence",
        "process_id",
        "process_start_abstime",
    )
    events: list[dict[str, Any]] = []
    parse_errors: list[str] = []
    ignored_line_count = 0
    for line_number, raw_line in enumerate(raw.splitlines(), start=1):
        line = raw_line.strip()
        if not line:
            continue
        try:
            value = json.loads(line)
        except json.JSONDecodeError:
            # `open --stderr` owns the file, so ordinary Qt/AppKit diagnostics
            # can share it. They are retained in the artifact but can never be
            # mistaken for structured route proof.
            ignored_line_count += 1
            continue
        if not isinstance(value, Mapping) or value.get("schema") != NATIVE_TELEMETRY_SCHEMA:
            ignored_line_count += 1
            continue

        errors: list[str] = []
        event_name = value.get("event")
        if not isinstance(event_name, str) or not event_name:
            errors.append("event must be a non-empty string")
        route = value.get("route")
        if route not in {"undecided", "native", "fallback"}:
            errors.append("route must be undecided, native, or fallback")
        if not isinstance(value.get("route_proof"), bool):
            errors.append("route_proof must be boolean")
        if not isinstance(value.get("libmpv_initialized"), bool):
            errors.append("libmpv_initialized must be boolean")
        for field in required_integer_fields:
            number = value.get(field)
            if not isinstance(number, int) or isinstance(number, bool) or number < 0:
                errors.append(f"{field} must be a nonnegative integer")
        run_id = value.get("run_id")
        try:
            normalized_run_id = str(uuid.UUID(run_id)) if isinstance(run_id, str) else None
        except ValueError:
            normalized_run_id = None
        if normalized_run_id is None or normalized_run_id != run_id.lower():
            errors.append("run_id must be a canonical UUID")
        if value.get("process_id", 0) <= 0:
            errors.append("process_id must be positive")
        if value.get("process_start_abstime", 0) <= 0:
            errors.append("process_start_abstime must be positive")
        asset_sha256 = value.get("asset_sha256")
        if not isinstance(asset_sha256, str) or re.fullmatch(
            r"[0-9a-f]{64}", asset_sha256
        ) is None:
            errors.append("asset_sha256 must be 64 lowercase hex digits")
        target = value.get("target_seconds")
        if target is not None and (
            not isinstance(target, (int, float))
            or isinstance(target, bool)
            or not math.isfinite(float(target))
        ):
            errors.append("target_seconds must be null or finite")
        if errors:
            parse_errors.append(f"line {line_number}: " + "; ".join(errors))
            continue

        events.append(
            {
                "line": line_number,
                "schema": NATIVE_TELEMETRY_SCHEMA,
                "event": event_name,
                "monotonic_ns": value["monotonic_ns"],
                "route": route,
                "route_proof": value["route_proof"],
                "source_key": value["source_key"],
                "attempt": value["attempt"],
                "serial": value["serial"],
                "generation": value["generation"],
                "gesture": value["gesture"],
                "request": value["request"],
                "draw_sequence": value["draw_sequence"],
                "target_seconds": target,
                "libmpv_initialized": value["libmpv_initialized"],
                "run_id": run_id,
                "process_id": value["process_id"],
                "process_start_abstime": value["process_start_abstime"],
                "asset_sha256": asset_sha256,
            }
        )

    return {
        "schema": NATIVE_TELEMETRY_SCHEMA,
        "framing_schema": "legacy_uncommitted",
        "stream_complete": False,
        "candidate_id": None,
        "matching_event_count": len(events),
        "ignored_line_count": ignored_line_count,
        "parse_errors": parse_errors,
        "events": events,
    }


def _native_identity(value: Mapping[str, Any]) -> tuple[Any, ...]:
    return (
        value.get("run_id"),
        value.get("process_id"),
        value.get("process_start_abstime"),
        value.get("asset_sha256"),
        value.get("candidate_id"),
    )


def _exact_nonnegative_integer(value: Any) -> bool:
    return isinstance(value, int) and not isinstance(value, bool) and value >= 0


def _exact_positive_integer(value: Any) -> bool:
    return _exact_nonnegative_integer(value) and value > 0


def _validate_framed_identity(
    value: Mapping[str, Any], line_number: int, errors: list[str]
) -> tuple[Any, ...] | None:
    run_id = value.get("run_id")
    try:
        normalized = str(uuid.UUID(run_id)) if isinstance(run_id, str) else None
    except ValueError:
        normalized = None
    if normalized is None or normalized != str(run_id).lower():
        errors.append(f"line {line_number}: run_id must be a canonical UUID")
    process_id = value.get("process_id")
    if not _exact_positive_integer(process_id):
        errors.append(f"line {line_number}: process_id must be positive")
    start = value.get("process_start_abstime")
    if not _exact_positive_integer(start):
        errors.append(f"line {line_number}: process_start_abstime must be positive")
    for field in ("asset_sha256", "candidate_id"):
        token = value.get(field)
        if not isinstance(token, str) or re.fullmatch(r"[0-9a-f]{64}", token) is None:
            errors.append(
                f"line {line_number}: {field} must be 64 lowercase hex digits"
            )
    return _native_identity(value) if not errors else None


def _validate_framed_event(
    value: Mapping[str, Any], line_number: int, errors: list[str]
) -> dict[str, Any] | None:
    required_integer_fields = (
        "batch",
        "event_sequence",
        "monotonic_ns",
        "source_key",
        "attempt",
        "serial",
        "generation",
        "gesture",
        "request",
        "draw_sequence",
        "process_id",
        "process_start_abstime",
    )
    row_errors: list[str] = []
    event_name = value.get("event")
    if not isinstance(event_name, str) or not event_name:
        row_errors.append("event must be a non-empty string")
    route = value.get("route")
    if route not in {"undecided", "native", "fallback"}:
        row_errors.append("route must be undecided, native, or fallback")
    if not isinstance(value.get("route_proof"), bool):
        row_errors.append("route_proof must be boolean")
    if not isinstance(value.get("libmpv_initialized"), bool):
        row_errors.append("libmpv_initialized must be boolean")
    for field in required_integer_fields:
        number = value.get(field)
        if not _exact_nonnegative_integer(number):
            row_errors.append(f"{field} must be a nonnegative integer")
    target = value.get("target_seconds")
    if target is not None and (
        not isinstance(target, (int, float))
        or isinstance(target, bool)
        or not math.isfinite(float(target))
    ):
        row_errors.append("target_seconds must be null or finite")
    identity_errors: list[str] = []
    _validate_framed_identity(value, line_number, identity_errors)
    row_errors.extend(
        message.split(": ", 1)[1] if ": " in message else message
        for message in identity_errors
    )
    if row_errors:
        errors.append(f"line {line_number}: " + "; ".join(row_errors))
        return None
    return {
        "line": line_number,
        "schema": NATIVE_TELEMETRY_FRAMED_SCHEMA,
        "event": event_name,
        "event_sequence": value["event_sequence"],
        "batch": value["batch"],
        "monotonic_ns": value["monotonic_ns"],
        "route": route,
        "route_proof": value["route_proof"],
        "source_key": value["source_key"],
        "attempt": value["attempt"],
        "serial": value["serial"],
        "generation": value["generation"],
        "gesture": value["gesture"],
        "request": value["request"],
        "draw_sequence": value["draw_sequence"],
        "target_seconds": target,
        "libmpv_initialized": value["libmpv_initialized"],
        "run_id": value["run_id"],
        "process_id": value["process_id"],
        "process_start_abstime": value["process_start_abstime"],
        "asset_sha256": value["asset_sha256"],
        "candidate_id": value["candidate_id"],
    }


def _parse_framed_wam_native_telemetry(raw: str) -> dict[str, Any]:
    """Validate v2 batch framing and expose only a terminally committed stream."""

    records: list[tuple[int, str, Mapping[str, Any]]] = []
    parse_errors: list[str] = []
    ignored_line_count = 0
    if raw and not raw.endswith("\n"):
        parse_errors.append("framed telemetry ends with a partial final line")
    last_nonempty_line_number = 0
    for line_number, raw_line in enumerate(raw.splitlines(), start=1):
        line = raw_line.strip()
        if not line:
            continue
        last_nonempty_line_number = line_number
        try:
            value = json.loads(line)
        except json.JSONDecodeError as error:
            if NATIVE_TELEMETRY_FRAMED_SCHEMA in line:
                parse_errors.append(
                    f"line {line_number}: truncated or malformed framed record: {error.msg}"
                )
            else:
                ignored_line_count += 1
            continue
        if not isinstance(value, Mapping) or value.get("schema") != NATIVE_TELEMETRY_FRAMED_SCHEMA:
            ignored_line_count += 1
            continue
        if raw_line != line:
            parse_errors.append(
                f"line {line_number}: framed records may not have surrounding whitespace"
            )
        records.append((line_number, line + "\n", value))

    identity: tuple[Any, ...] | None = None
    committed_events: list[dict[str, Any]] = []
    provisional_events: list[dict[str, Any]] = []
    expected_batch = 1
    expected_event_sequence = 1
    chain = bytes(32)
    stream_commit_seen = False
    stream_commit_line_number: int | None = None
    cursor = 0

    if not records:
        parse_errors.append("framed telemetry has no matching records")
    else:
        line_number, _, header = records[0]
        if (
            header.get("record") != "stream_header"
            or not _exact_nonnegative_integer(header.get("format_version"))
            or header.get("format_version") != 2
        ):
            parse_errors.append(
                f"line {line_number}: first framed record must be the v2 stream header"
            )
        else:
            identity_errors: list[str] = []
            identity = _validate_framed_identity(header, line_number, identity_errors)
            parse_errors.extend(identity_errors)
        cursor = 1

    while cursor < len(records) and not stream_commit_seen:
        line_number, _, value = records[cursor]
        record_type = value.get("record")
        if record_type == "stream_commit":
            stream_commit_seen = True
            stream_commit_line_number = line_number
            if identity is None or _native_identity(value) != identity:
                parse_errors.append(f"line {line_number}: stream commit identity changed")
            expected_count = expected_event_sequence - 1
            expected_first = 0 if expected_count == 0 else 1
            expected_chain = chain.hex()
            exact = {
                "batch_count": expected_batch - 1,
                "event_count": expected_count,
                "first_sequence": expected_first,
                "last_sequence": expected_count,
                "chain_sha256": expected_chain,
            }
            for field, wanted in exact.items():
                observed = value.get(field)
                if (
                    field != "chain_sha256"
                    and not _exact_nonnegative_integer(observed)
                ) or observed != wanted:
                    parse_errors.append(
                        f"line {line_number}: stream commit {field} does not match {wanted!r}"
                    )
            cursor += 1
            break
        if record_type != "batch_begin":
            parse_errors.append(
                f"line {line_number}: expected batch_begin or stream_commit"
            )
            cursor += 1
            continue
        if identity is None or _native_identity(value) != identity:
            parse_errors.append(f"line {line_number}: batch identity changed")
        count = value.get("event_count")
        first = value.get("first_sequence")
        last = value.get("last_sequence")
        batch_value = value.get("batch")
        if (
            not _exact_positive_integer(count)
            or not _exact_positive_integer(batch_value)
            or not _exact_positive_integer(first)
            or not _exact_positive_integer(last)
            or batch_value != expected_batch
            or first != expected_event_sequence
            or last != expected_event_sequence + count - 1
            or value.get("previous_chain_sha256") != chain.hex()
        ):
            parse_errors.append(f"line {line_number}: invalid batch framing metadata")
            break
        cursor += 1
        raw_payload = bytearray()
        batch_events: list[dict[str, Any]] = []
        for offset in range(count):
            if cursor >= len(records):
                parse_errors.append(
                    f"batch {expected_batch}: truncated before event {offset + 1}"
                )
                break
            event_line_number, event_line, event_value = records[cursor]
            if event_value.get("record") != "event":
                parse_errors.append(
                    f"line {event_line_number}: expected event {offset + 1} of batch {expected_batch}"
                )
                break
            parsed_event = _validate_framed_event(
                event_value, event_line_number, parse_errors
            )
            if (
                parsed_event is None
                or event_value.get("batch") != expected_batch
                or event_value.get("event_sequence")
                != expected_event_sequence + offset
                or identity is None
                or _native_identity(event_value) != identity
            ):
                parse_errors.append(
                    f"line {event_line_number}: event does not match its batch identity/sequence"
                )
            else:
                batch_events.append(parsed_event)
            raw_payload.extend(event_line.encode("utf-8"))
            cursor += 1
        if len(batch_events) != count or cursor >= len(records):
            break
        commit_line_number, _, commit = records[cursor]
        payload_digest = hashlib.sha256(raw_payload).digest()
        chain_hasher = hashlib.sha256()
        chain_hasher.update(chain)
        chain_hasher.update(payload_digest)
        chain_hasher.update(struct.pack(">QQQQ", expected_batch, count, first, last))
        next_chain = chain_hasher.digest()
        commit_integers_are_exact = all(
            _exact_positive_integer(commit.get(field))
            for field in ("batch", "event_count", "first_sequence", "last_sequence")
        )
        if (
            commit.get("record") != "batch_commit"
            or not commit_integers_are_exact
            or commit.get("batch") != expected_batch
            or commit.get("event_count") != count
            or commit.get("first_sequence") != first
            or commit.get("last_sequence") != last
            or commit.get("payload_sha256") != payload_digest.hex()
            or commit.get("chain_sha256") != next_chain.hex()
            or identity is None
            or _native_identity(commit) != identity
        ):
            parse_errors.append(
                f"line {commit_line_number}: batch commit does not match its exact payload"
            )
            break
        provisional_events.extend(batch_events)
        chain = next_chain
        expected_event_sequence += count
        expected_batch += 1
        cursor += 1

    if stream_commit_seen and cursor != len(records):
        line_number = records[cursor][0]
        parse_errors.append(
            f"line {line_number}: framed record appears after terminal stream commit"
        )
    if (
        stream_commit_line_number is not None
        and last_nonempty_line_number > stream_commit_line_number
    ):
        parse_errors.append(
            f"line {last_nonempty_line_number}: bytes appear after terminal stream commit"
        )
    stream_complete = stream_commit_seen and not parse_errors
    if stream_complete:
        committed_events = provisional_events
    return {
        "schema": NATIVE_TELEMETRY_FRAMED_SCHEMA,
        "framing_schema": NATIVE_TELEMETRY_FRAMED_SCHEMA,
        "stream_complete": stream_complete,
        "stream_status": (
            "complete"
            if stream_complete
            else ("invalid" if parse_errors else "provisional")
        ),
        "stream_chain_sha256": chain.hex() if stream_complete else None,
        "candidate_id": identity[4] if identity is not None else None,
        "matching_event_count": len(committed_events),
        "provisional_event_count": len(provisional_events),
        "ignored_line_count": ignored_line_count,
        "parse_errors": parse_errors,
        "events": committed_events,
        "provisional_events": provisional_events,
    }


def read_wam_native_telemetry(path: Path) -> dict[str, Any]:
    try:
        raw = path.read_text(encoding="utf-8")
    except FileNotFoundError:
        return {
            "schema": NATIVE_TELEMETRY_SCHEMA,
            "artifact": str(path),
            "availability": "missing",
            "matching_event_count": 0,
            "ignored_line_count": 0,
            "parse_errors": [],
            "events": [],
        }
    except (OSError, UnicodeError) as error:
        return {
            "schema": NATIVE_TELEMETRY_SCHEMA,
            "artifact": str(path),
            "availability": "unreadable",
            "error": str(error),
            "matching_event_count": 0,
            "ignored_line_count": 0,
            "parse_errors": [],
            "events": [],
        }
    parsed = parse_wam_native_telemetry(raw)
    parsed["artifact"] = str(path)
    if parsed["matching_event_count"] or parsed.get("provisional_event_count", 0):
        parsed["availability"] = "available"
    elif raw:
        parsed["availability"] = "no_matching_events"
    else:
        parsed["availability"] = "empty"
    return parsed


def _matching_native_sessions(events: Sequence[Mapping[str, Any]]) -> list[dict[str, Any]]:
    sessions: list[dict[str, Any]] = []
    open_indices = [
        index for index, event in enumerate(events) if event.get("event") == "open_requested"
    ]
    for open_position, open_index in enumerate(open_indices):
        opened = events[open_index]
        if opened.get("source_key", 0) <= 0 or opened.get("monotonic_ns", 0) <= 0:
            continue
        next_open = (
            open_indices[open_position + 1]
            if open_position + 1 < len(open_indices)
            else len(events)
        )
        selected_candidates = [
            (index, events[index])
            for index in range(open_index + 1, next_open)
            if events[index].get("event") == "native_selected"
            and events[index].get("route") == "native"
            and events[index].get("route_proof") is True
            and events[index].get("source_key") == opened.get("source_key")
            and events[index].get("attempt", 0) > 0
            and events[index].get("serial", 0) > 0
            and events[index].get("generation", 0) > 0
            and events[index].get("monotonic_ns", 0)
            >= opened.get("monotonic_ns", 0)
        ]
        matched: dict[str, Any] | None = None
        for selected_index, selected in selected_candidates:
            drawn = next(
                (
                    event
                    for event in events[selected_index + 1 : next_open]
                    if event.get("event") == "first_frame_drawn"
                    and event.get("route") == "native"
                    and event.get("attempt") == selected.get("attempt")
                    and event.get("generation") == selected.get("generation")
                    # Prepare reserves the generation at route selection, but
                    # Start/SetRunState legitimately advance the exact command
                    # serial before the covering draw proof. Require forward
                    # progress in the same attempt/generation rather than the
                    # impossible equality used by the old harness.
                    and event.get("serial", 0) > selected.get("serial", 0)
                    and event.get("draw_sequence", 0) > 0
                    and event.get("monotonic_ns", 0) >= selected.get("monotonic_ns", 0)
                ),
                None,
            )
            if drawn is None:
                continue
            open_ns = int(opened["monotonic_ns"])
            draw_ns = int(drawn["monotonic_ns"])
            if draw_ns < open_ns:
                continue
            matched = {
                "open_ordinal": open_position + 1,
                "source_key": opened["source_key"],
                "attempt": selected["attempt"],
                # Keep serial as the selection serial for result-schema
                # compatibility while exposing both exact command identities.
                "serial": selected["serial"],
                "native_selected_serial": selected["serial"],
                "first_frame_drawn_serial": drawn["serial"],
                "generation": selected["generation"],
                "open_requested_monotonic_ns": open_ns,
                "native_selected_monotonic_ns": selected["monotonic_ns"],
                "first_frame_drawn_monotonic_ns": draw_ns,
                "draw_sequence": drawn["draw_sequence"],
                "open_request_to_first_draw_ms": (draw_ns - open_ns) / 1_000_000.0,
            }
            break
        if matched is not None:
            sessions.append(matched)
    return sessions


def summarize_wam_native_proof(
    parsed: Mapping[str, Any],
    launch_request_monotonic_ns: int,
    expected_run_id: str | None = None,
    expected_process_id: int | None = None,
    expected_process_start_abstime: int | None = None,
    expected_asset_sha256: str | None = None,
    expected_candidate_id: str | None = None,
    *,
    require_stream_complete: bool = True,
) -> dict[str, Any]:
    stream_complete = parsed.get("stream_complete") is True
    is_v2 = parsed.get("schema") == NATIVE_TELEMETRY_FRAMED_SCHEMA
    event_key = (
        "events"
        if stream_complete or not is_v2
        else "provisional_events"
    )
    events = [
        event for event in parsed.get(event_key, ()) if isinstance(event, Mapping)
    ]
    sessions = _matching_native_sessions(events)
    identities = {
        (
            event.get("run_id"),
            event.get("process_id"),
            event.get("process_start_abstime"),
        )
        for event in events
    }
    observed_identity = next(iter(identities)) if len(identities) == 1 else None
    identity_matches = bool(observed_identity)
    if observed_identity is not None:
        identity_matches = (
            (expected_run_id is None or observed_identity[0] == expected_run_id)
            and (
                expected_process_id is None
                or observed_identity[1] == expected_process_id
            )
            and (
                expected_process_start_abstime is None
                or observed_identity[2] == expected_process_start_abstime
            )
        )
    asset_tokens = {event.get("asset_sha256") for event in events}
    observed_asset_sha256 = (
        next(iter(asset_tokens)) if len(asset_tokens) == 1 else None
    )
    asset_identity_matches = bool(observed_asset_sha256)
    if observed_asset_sha256 is not None:
        asset_identity_matches = (
            expected_asset_sha256 is None
            or observed_asset_sha256 == expected_asset_sha256
        )
    candidate_tokens = {
        event.get("candidate_id")
        for event in events
        if event.get("candidate_id") is not None
    }
    observed_candidate_id = (
        next(iter(candidate_tokens)) if len(candidate_tokens) == 1 else None
    )
    candidate_identity_matches = bool(observed_candidate_id)
    if observed_candidate_id is not None:
        candidate_identity_matches = (
            expected_candidate_id is None
            or observed_candidate_id == expected_candidate_id
        )
    initial_open_index = next(
        (
            index
            for index, event in enumerate(events)
            if event.get("event") == "open_requested"
        ),
        None,
    )
    initial_open = (
        events[initial_open_index] if initial_open_index is not None else None
    )
    initial_open_end = (
        next(
            (
                index
                for index in range(initial_open_index + 1, len(events))
                if events[index].get("event") == "open_requested"
            ),
            len(events),
        )
        if initial_open_index is not None
        else 0
    )
    initial_segment = (
        events[initial_open_index + 1 : initial_open_end]
        if initial_open_index is not None
        else []
    )
    trial_events = (
        events[initial_open_index:]
        if initial_open_index is not None
        else []
    )
    native_selected_events = [
        event
        for event in initial_segment
        if event.get("event") == "native_selected"
        and event.get("route") == "native"
        and event.get("route_proof") is True
        and initial_open is not None
        and event.get("source_key") == initial_open.get("source_key")
        and event.get("attempt", 0) > 0
        and event.get("serial", 0) > 0
        and event.get("generation", 0) > 0
        and event.get("monotonic_ns", 0) >= initial_open.get("monotonic_ns", 0)
    ]
    all_fallback_events = [
        event for event in events if event.get("event") == "fallback_selected"
    ]
    # The benchmark contract is process-trial wide after the first observed
    # open: any well-formed route proof for compatibility fallback invalidates
    # the measurement, including a later open or a transition after steady
    # collection began. Pre-open or non-proof fallback-shaped records remain
    # diagnostic and cannot poison an otherwise exact trial.
    fallback_events = [
        event
        for event in (
            events[initial_open_index + 1 :]
            if initial_open_index is not None
            else []
        )
        if event.get("event") == "fallback_selected"
        and event.get("route") == "fallback"
        and event.get("route_proof") is True
        and event.get("source_key", 0) > 0
        and event.get("attempt", 0) > 0
        and event.get("serial", 0) > 0
        and initial_open is not None
        and event.get("monotonic_ns", 0) >= initial_open.get("monotonic_ns", 0)
    ]
    unrelated_fallback_events = [
        event for event in all_fallback_events if event not in fallback_events
    ]
    # A native performance trial is process-wide after its first open. A
    # later open, scrub, seek, or playback event that observes libmpv already
    # initialized invalidates the same run just as decisively as the initial
    # frame lineage does.
    libmpv_never_initialized = bool(trial_events) and all(
        event.get("libmpv_initialized") is False for event in trial_events
    )
    initial = next(
        (session for session in sessions if session["open_ordinal"] == 1), None
    )
    warm = next(
        (session for session in sessions if session["open_ordinal"] == 2), None
    )
    cold_latency_ms: float | None = None
    if initial is not None:
        cold_latency_ms = (
            int(initial["first_frame_drawn_monotonic_ns"])
            - launch_request_monotonic_ns
        ) / 1_000_000.0
    warm_latency_ms = (
        float(warm["open_request_to_first_draw_ms"])
        if warm is not None
        else None
    )

    required_evidence = {
        "native_selected": bool(native_selected_events),
        "first_frame_drawn": initial is not None,
        "no_fallback_selected": bool(trial_events) and not fallback_events,
        "libmpv_never_initialized": libmpv_never_initialized,
        "single_process_identity": len(identities) == 1,
        "expected_process_identity": identity_matches,
        "single_asset_identity": len(asset_tokens) == 1,
        "expected_asset_identity": asset_identity_matches,
        "single_candidate_identity": is_v2 and len(candidate_tokens) == 1,
        "expected_candidate_identity": is_v2 and candidate_identity_matches,
        "terminal_stream_commit": stream_complete,
    }
    reasons: list[str] = []
    availability = parsed.get("availability")
    if availability != "available":
        reasons.append(f"native telemetry is {availability or 'unavailable'}")
    if parsed.get("parse_errors"):
        reasons.append("native telemetry contains invalid schema-matching events")
    if require_stream_complete and (not is_v2 or not stream_complete):
        reasons.append("native telemetry has no valid terminal stream commit")
    if len(identities) != 1:
        reasons.append("native telemetry does not have one exact run/process/start identity")
    elif not identity_matches:
        reasons.append("native telemetry run/process/start identity does not match the launched WAM")
    if len(asset_tokens) != 1:
        reasons.append("native telemetry does not have one exact asset SHA-256 identity")
    elif not asset_identity_matches:
        reasons.append("native telemetry asset SHA-256 does not match the launched clip bytes")
    if is_v2 and len(candidate_tokens) != 1:
        reasons.append("native telemetry does not have one exact candidate identity")
    elif is_v2 and not candidate_identity_matches:
        reasons.append("native telemetry candidate identity does not match the launched WAM")
    if not required_evidence["native_selected"]:
        reasons.append("no matching native_selected route proof was observed")
    if not required_evidence["first_frame_drawn"]:
        reasons.append("no matching exact first_frame_drawn proof was observed")
    if fallback_events:
        reasons.append("fallback_selected was observed after the trial's initial open")
    if not libmpv_never_initialized:
        reasons.append("libmpv_initialized=true was observed after the trial's initial open")
    if cold_latency_ms is not None and cold_latency_ms < 0:
        reasons.append("first_frame_drawn predates the harness launch request clock")

    provisional_reasons = [
        reason
        for reason in reasons
        if reason != "native telemetry has no valid terminal stream commit"
    ]
    provisional_eligible = not provisional_reasons
    eligible = is_v2 and stream_complete and not provisional_reasons
    return {
        "status": (
            "eligible"
            if eligible
            else ("provisional" if provisional_eligible else "ineligible")
        ),
        "eligible": eligible,
        "provisional_eligible": provisional_eligible,
        "route": "native" if initial is not None and not fallback_events else (
            "fallback" if fallback_events else "unproven"
        ),
        "required_evidence": required_evidence,
        "process_identity": (
            {
                "run_id": observed_identity[0],
                "process_id": observed_identity[1],
                "process_start_abstime": observed_identity[2],
            }
            if observed_identity is not None
            else None
        ),
        "asset_identity": (
            {"sha256": observed_asset_sha256}
            if observed_asset_sha256 is not None
            else None
        ),
        "candidate_identity": (
            {"sha256": observed_candidate_id}
            if observed_candidate_id is not None
            else None
        ),
        "stream_complete": stream_complete,
        "provisional": not stream_complete,
        "libmpv_never_initialized": libmpv_never_initialized,
        "reasons": reasons,
        "latencies": {
            # Python time.monotonic_ns and C++ steady_clock both use the
            # process-independent macOS monotonic clock in this suite.
            "cold_request_to_first_draw_ms": cold_latency_ms,
            "open_request_to_first_draw_ms": (
                float(initial["open_request_to_first_draw_ms"])
                if initial is not None
                else None
            ),
            "warm_request_to_first_draw_ms": warm_latency_ms,
            "warm_measurement_available": warm is not None,
        },
        "sessions": sessions,
        "fallback_events": fallback_events,
        "unrelated_fallback_events": unrelated_fallback_events,
        "telemetry": dict(parsed),
    }


def wait_for_wam_native_proof(
    path: Path,
    launch_request_monotonic_ns: int,
    timeout: float,
    expected_run_id: str | None = None,
    expected_process_id: int | None = None,
    expected_process_start_abstime: int | None = None,
    expected_asset_sha256: str | None = None,
    expected_candidate_id: str | None = None,
) -> dict[str, Any]:
    deadline = time.monotonic() + timeout
    report = summarize_wam_native_proof(
        read_wam_native_telemetry(path),
        launch_request_monotonic_ns,
        expected_run_id,
        expected_process_id,
        expected_process_start_abstime,
        expected_asset_sha256,
        expected_candidate_id,
        require_stream_complete=False,
    )
    while not report["provisional_eligible"] and time.monotonic() < deadline:
        if report["fallback_events"] or report["telemetry"]["parse_errors"]:
            break
        time.sleep(0.05)
        report = summarize_wam_native_proof(
            read_wam_native_telemetry(path),
            launch_request_monotonic_ns,
            expected_run_id,
            expected_process_id,
            expected_process_start_abstime,
            expected_asset_sha256,
            expected_candidate_id,
            require_stream_complete=False,
        )
    return report


def require_wam_native_proof(report: Mapping[str, Any]) -> None:
    if report.get("eligible") is True:
        return
    reasons = report.get("reasons")
    detail = "; ".join(str(reason) for reason in reasons) if reasons else "proof unavailable"
    raise NativeProofIneligible(f"WAM native benchmark is ineligible: {detail}")


def require_wam_native_provisional_proof(report: Mapping[str, Any]) -> None:
    if report.get("provisional_eligible") is True and report.get("provisional") is True:
        return
    reasons = report.get("reasons")
    detail = "; ".join(str(reason) for reason in reasons) if reasons else "proof unavailable"
    raise NativeProofIneligible(
        f"WAM live native checkpoint is ineligible: {detail}"
    )


def require_clock_progress(
    player: str,
    start_state: Mapping[str, Any],
    end_state: Mapping[str, Any],
    elapsed_s: float,
    speed: float,
) -> dict[str, float]:
    observed = float(end_state["current_time_s"]) - float(start_state["current_time_s"])
    expected = elapsed_s * speed
    error = observed - expected
    tolerance = max(1.5, expected * 0.10)
    if observed <= 0.05 or abs(error) > tolerance:
        raise SuiteError(
            f"{player} timeline did not match wall time and requested rate: "
            f"observed {observed:.3f}s, expected {expected:.3f}s +/- {tolerance:.3f}s"
        )
    return {
        "wall_elapsed_s": elapsed_s,
        "requested_rate": speed,
        "expected_source_advance_s": expected,
        "observed_source_advance_s": observed,
        "residual_s": error,
        "tolerance_s": tolerance,
    }


def live_exact_identities(
    identities: Sequence[ProcessIdentity],
    current: Mapping[int, ProcessIdentity] | None = None,
) -> list[ProcessIdentity]:
    table = dict(current) if current is not None else process_table()
    return [
        identity
        for identity in identities
        if (observed := table.get(identity.pid)) is not None and same_identity(identity, observed)
    ]


def validate_lsof(clip: Path, identities: Sequence[ProcessIdentity]) -> dict[str, Any]:
    live = live_exact_identities(identities)
    pids = [identity.pid for identity in live]
    if not pids:
        return {"checked_pids": [], "media_open": False, "error": "no exact target PIDs were alive"}
    command = [
        "/usr/sbin/lsof",
        "-n",
        "-P",
        "-a",
        "-p",
        ",".join(str(pid) for pid in pids),
        "-Fn",
        "--",
        str(clip),
    ]
    result = subprocess.run(command, capture_output=True, text=True, timeout=15, check=False)
    current_pid: int | None = None
    opened_by: list[int] = []
    observed_names: list[str] = []
    for line in result.stdout.splitlines():
        if line.startswith("p") and line[1:].isdigit():
            current_pid = int(line[1:])
        elif line.startswith("n"):
            name = line[1:].removesuffix(" (deleted)")
            observed_names.append(name)
            try:
                matches = Path(name).resolve() == clip
            except OSError:
                matches = False
            if matches and current_pid is not None:
                opened_by.append(current_pid)
    return {
        "checked_pids": pids,
        "media_open": bool(opened_by),
        "opened_by_pids": sorted(set(opened_by)),
        "observed_names": observed_names,
        "command": command,
        "exit_code": result.returncode,
        "stderr": result.stderr.strip(),
    }


def build_collector_command(
    collector: Path,
    identities: Sequence[ProcessIdentity],
    player: str,
    clip_id: str,
    run: str,
    speed: float,
    duration: float,
    interval: int,
    output: Path,
) -> list[str]:
    labels = {"wam": "WAM", "vlc": "VLC", "quicktime": "QuickTime"}
    command = [sys.executable, str(collector)]
    for identity in identities:
        command.extend(["--pid", str(identity.pid)])
    command.extend(
        [
            "--player",
            labels[player],
            "--clip",
            clip_id,
            "--run",
            run,
            "--speed",
            format_number(speed),
            "--duration",
            format_number(duration),
            "--interval",
            str(interval),
            "--output",
            str(output),
        ]
    )
    return command


def run_with_periodic_callback(
    command: Sequence[str],
    *,
    timeout: float,
    callback: Callable[[], Any],
    poll_interval_s: float = 0.1,
) -> subprocess.CompletedProcess[str]:
    """Run a quiet child while servicing a fixed-deadline read-only sampler."""

    if not math.isfinite(poll_interval_s) or poll_interval_s <= 0:
        raise ValueError("poll interval must be finite and positive")

    process = subprocess.Popen(
        list(command),
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        close_fds=True,
    )
    started = time.monotonic()
    deadline = started + timeout
    next_callback = started
    try:
        while process.poll() is None:
            now = time.monotonic()
            remaining = deadline - now
            if remaining <= 0:
                process.kill()
                stdout, stderr = process.communicate()
                raise subprocess.TimeoutExpired(
                    list(command), timeout, output=stdout, stderr=stderr
                )
            if now < next_callback:
                time.sleep(min(next_callback - now, remaining))
                continue

            callback()
            next_callback += poll_interval_s
            callback_ended = time.monotonic()
            if callback_ended > next_callback:
                # Preserve a fixed 20 Hz deadline grid without issuing bursts
                # of back-to-back process-table queries after a slow sample.
                missed = math.floor(
                    (callback_ended - next_callback) / poll_interval_s
                ) + 1
                next_callback += missed * poll_interval_s
        stdout, stderr = process.communicate()
        callback()
        return subprocess.CompletedProcess(
            list(command), process.returncode, stdout, stderr
        )
    except BaseException:
        if process.poll() is None:
            process.kill()
            process.communicate()
        raise


def terminate_exact(identity: ProcessIdentity, timeout: float = 10.0) -> dict[str, Any]:
    try:
        current = process_table().get(identity.pid)
    except SuiteError as error:
        return {"pid": identity.pid, "status": "not_signaled", "error": str(error)}
    if current is None:
        return {"pid": identity.pid, "status": "already_exited"}
    if not same_identity(identity, current):
        return {"pid": identity.pid, "status": "identity_changed_not_signaled"}
    try:
        os.kill(identity.pid, signal.SIGTERM)
    except ProcessLookupError:
        return {"pid": identity.pid, "status": "already_exited"}
    except PermissionError as error:
        return {"pid": identity.pid, "status": "not_signaled", "error": str(error)}

    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            observed = process_table().get(identity.pid)
        except SuiteError as error:
            return {"pid": identity.pid, "status": "sigterm_sent_unverified", "error": str(error)}
        if observed is None:
            return {"pid": identity.pid, "status": "exited_after_sigterm"}
        if not same_identity(identity, observed):
            return {
                "pid": identity.pid,
                "status": "exited_or_identity_changed_after_sigterm",
            }
        time.sleep(0.1)
    return {
        "pid": identity.pid,
        "status": "still_running_after_sigterm",
        "note": "SIGKILL was deliberately not used",
    }


def quit_exact_wam_orderly(
    identity: ProcessIdentity,
    *,
    bundle_id: str = "com.wesleymaa.wam",
    timeout: float = 10.0,
) -> dict[str, Any]:
    """Ask the one exact WAM instance to quit so aboutToQuit can commit proof."""

    try:
        current = process_table().get(identity.pid)
    except SuiteError as error:
        return {"pid": identity.pid, "status": "not_requested", "error": str(error)}
    if current is None:
        return {"pid": identity.pid, "status": "already_exited"}
    if not same_identity(identity, current):
        return {"pid": identity.pid, "status": "identity_changed_not_requested"}
    script = r'''
on run argv
    set expectedPid to (item 1 of argv) as integer
    set expectedBundleId to item 2 of argv
    tell application "System Events"
        set matches to every application process whose unix id is expectedPid
        if (count of matches) is not 1 then error "exact WAM process unavailable"
        set targetProcess to item 1 of matches
        if bundle identifier of targetProcess is not expectedBundleId then error "bundle identity changed"
        tell targetProcess to perform action "AXPress" of menu item "Quit WAM" of menu 1 of menu bar item "WAM" of menu bar 1
    end tell
end run
'''
    result = _osascript(script, timeout=min(timeout, 3.0), arguments=(str(identity.pid), bundle_id))
    if result.returncode != 0:
        return {
            "pid": identity.pid,
            "status": "orderly_quit_not_requested",
            "error": result.stderr.strip() or f"osascript status {result.returncode}",
        }
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            observed = process_table().get(identity.pid)
        except SuiteError as error:
            return {
                "pid": identity.pid,
                "status": "orderly_quit_sent_unverified",
                "error": str(error),
            }
        if observed is None:
            return {"pid": identity.pid, "status": "exited_after_orderly_quit"}
        if not same_identity(identity, observed):
            return {
                "pid": identity.pid,
                "status": "exited_or_identity_changed_after_orderly_quit",
            }
        time.sleep(0.05)
    return {
        "pid": identity.pid,
        "status": "still_running_after_orderly_quit",
    }


def helper_exit_status(identities: Sequence[ProcessIdentity], timeout: float = 5.0) -> list[dict[str, Any]]:
    if not identities:
        return []
    deadline = time.monotonic() + timeout
    try:
        while time.monotonic() < deadline:
            live = live_exact_identities(identities)
            if not live:
                break
            time.sleep(0.1)
        live_pids = {identity.pid for identity in live_exact_identities(identities)}
    except SuiteError as error:
        return [
            {"pid": identity.pid, "status": "exit_unverified", "error": str(error)}
            for identity in identities
        ]
    return [
        {
            "pid": identity.pid,
            "status": "still_running_system_managed" if identity.pid in live_pids else "exited_with_player",
        }
        for identity in identities
    ]


def _json_write(path: Path, value: Any) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def _clip_metadata(clip: Path) -> dict[str, Any]:
    digest = hashlib.sha256()
    byte_count = 0
    with clip.open("rb") as stream:
        before = os.fstat(stream.fileno())
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
            byte_count += len(block)
        after = os.fstat(stream.fileno())
    path_after = clip.stat()
    stable_fields = ("st_dev", "st_ino", "st_size", "st_mtime_ns", "st_ctime_ns")
    if any(getattr(before, field) != getattr(after, field) for field in stable_fields):
        raise SuiteError("benchmark clip changed while its exact bytes were hashed")
    if any(getattr(after, field) != getattr(path_after, field) for field in stable_fields):
        raise SuiteError("benchmark clip path was replaced while its exact bytes were hashed")
    if byte_count != after.st_size:
        raise SuiteError("benchmark clip byte count changed while hashing")
    return {
        "path": str(clip),
        "bytes": byte_count,
        "mtime_ns": after.st_mtime_ns,
        "sha256": digest.hexdigest(),
    }


def _executable_candidate_token(executable: Path) -> dict[str, Any]:
    """Bind telemetry to the exact entrypoint bytes; campaign proof is stronger."""

    digest = hashlib.sha256()
    byte_count = 0
    with executable.open("rb") as stream:
        before = os.fstat(stream.fileno())
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
            byte_count += len(block)
        after = os.fstat(stream.fileno())
    path_after = executable.stat()
    stable_fields = ("st_dev", "st_ino", "st_mode", "st_uid", "st_gid", "st_size", "st_mtime_ns", "st_ctime_ns")
    if any(getattr(before, field) != getattr(after, field) for field in stable_fields):
        raise SuiteError("WAM executable changed while its telemetry token was hashed")
    if any(getattr(after, field) != getattr(path_after, field) for field in stable_fields):
        raise SuiteError("WAM executable path changed while its telemetry token was hashed")
    if byte_count != after.st_size:
        raise SuiteError("WAM executable byte count changed while hashing")
    return {
        "scope": "executable_entrypoint_bytes_only",
        "sha256": digest.hexdigest(),
        "bytes": byte_count,
        "device": after.st_dev,
        "inode": after.st_ino,
        "mtime_ns": after.st_mtime_ns,
        "ctime_ns": after.st_ctime_ns,
        "release_gate_note": (
            "correlation token only; shipping additionally requires the immutable "
            "whole-bundle AppIdentity campaign join"
        ),
    }


def _merge_orchestration(output: Path, orchestration: Mapping[str, Any]) -> None:
    try:
        result = json.loads(output.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise SuiteError(f"could not augment collector output {output}: {error}") from error
    result["orchestration"] = orchestration
    _json_write(output, result)


def artifact_paths(output: Path, player: str) -> dict[str, Path]:
    paths = {
        "sidecar": output.with_name(f"{output.stem}.orchestration.json"),
        "launch_log": output.with_name(f"{output.stem}.{player}.launch.log"),
        "raw_top": output.with_name(f"{output.stem}.top.txt"),
    }
    if player == "wam":
        paths["native_telemetry"] = output.with_name(
            f"{output.stem}.wam.native.jsonl"
        )
    return paths


def _assert_artifacts_are_new(output: Path, artifacts: Mapping[str, Path]) -> None:
    collisions = [path for path in (output, *artifacts.values()) if path.exists()]
    if collisions:
        joined = ", ".join(str(path) for path in collisions)
        raise SuiteError(f"refusing to overwrite existing benchmark artifacts: {joined}")


def run_suite(args: argparse.Namespace) -> int:
    validate_player_options(args)
    if sys.platform != "darwin":
        raise SuiteError("run_suite.py requires macOS")

    try:
        clip = args.clip.expanduser().resolve(strict=True)
    except OSError as error:
        raise SuiteError(f"could not resolve local clip {args.clip}: {error}") from error
    if not clip.is_file():
        raise SuiteError(f"clip is not a regular local file: {clip}")
    collector = args.collector.expanduser().resolve()
    if not collector.is_file():
        raise SuiteError(f"collector does not exist: {collector}")
    executable = player_executable(args)
    args.output = args.output.expanduser().resolve()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    artifacts = artifact_paths(args.output, args.player)
    _assert_artifacts_are_new(args.output, artifacts)

    # Hash the exact resolved bytes before LaunchServices is asked to open
    # them. This token is propagated independently of the display name/path,
    # so relabeling a different asset cannot satisfy native route proof.
    clip_identity = _clip_metadata(clip)
    candidate_token = (
        _executable_candidate_token(executable)
        if args.player == "wam"
        else None
    )

    before = process_table()
    already_running = matching_executable(before, executable)
    if already_running:
        pids = ", ".join(str(identity.pid) for identity in already_running)
        raise SuiteError(
            f"{args.player} is already running as PID(s) {pids}; quit it first so automation cannot touch user playback"
        )

    native_run_id = str(uuid.uuid4()) if args.player == "wam" else None
    command = build_player_command(
        args.player,
        executable,
        clip,
        args.speed,
        args.start_time,
        args.window,
        artifacts.get("native_telemetry"),
        native_run_id,
        clip_identity["sha256"] if args.player == "wam" else None,
        candidate_token["sha256"] if candidate_token is not None else None,
    )
    orchestration: dict[str, Any] = {
        "schema": "wam.macos.orchestration.v1",
        "started_at": utc_now(),
        "player": args.player,
        "clip_id": args.clip_id or clip.stem,
        "clip": dict(clip_identity),
        "telemetry_candidate_token": candidate_token,
        "requested": {
            "speed": args.speed,
            "start_time_s": args.start_time,
            "warmup_s": args.warmup,
            "duration_s": args.duration,
            "sample_interval_s": args.interval,
            "window": {"width": args.window[0], "height": args.window[1]},
        },
        "launch": {
            "command": command,
            "executable": str(executable),
            "log": str(artifacts["launch_log"]),
            "expected_native_run_id": native_run_id,
            "asset_identity": {
                "canonical_path": str(clip),
                "bytes": clip_identity["bytes"],
                "sha256": clip_identity["sha256"],
            },
        },
        "render_telemetry": render_telemetry_availability(args.player),
        "warnings": [],
    }
    _json_write(artifacts["sidecar"], orchestration)

    launch: LaunchHandle | None = None
    helpers: dict[int, ProcessIdentity] = {}
    unrelated_helpers: dict[int, dict[str, Any]] = {}
    companions: dict[int, ProcessIdentity] = {}
    target_coalition: ResourceCoalition | None = None
    validity_tracker: ForegroundWindowValidityTracker | None = None
    helper_continuity: DecoderHelperContinuityTracker | None = None
    orderly_wam_quit: dict[str, Any] | None = None
    failure: BaseException | None = None
    collector_returncode: int | None = None
    try:
        launch_request_monotonic_ns = time.monotonic_ns()
        orchestration["launch"]["requested_at"] = utc_now()
        orchestration["launch"]["request_monotonic_ns"] = launch_request_monotonic_ns
        _json_write(artifacts["sidecar"], orchestration)
        launch = launch_player(command, executable, before, artifacts["launch_log"], args.launch_timeout)
        orchestration["launch"]["main_process"] = launch.identity.as_dict()
        target_coalition = process_resource_coalition(launch.identity.pid)
        orchestration["launch"]["resource_coalition"] = target_coalition.as_dict()
        orchestration["launch"]["ready_at"] = utc_now()
        matching_now = matching_executable(process_table(), executable)
        for identity in matching_now:
            if identity.pid == launch.identity.pid:
                continue
            if not is_launch_companion(launch.identity, identity):
                raise SuiteError(
                    "another matching player appeared during launch outside the launch grace; "
                    "refusing ambiguous automation"
                )
            companions[identity.pid] = identity
        _json_write(artifacts["sidecar"], orchestration)

        wam_initial: dict[str, Any] | None = None
        quicktime_initial: dict[str, Any] | None = None
        vlc_initial: dict[str, Any] | None = None
        if args.player == "wam":
            wam_initial = configure_wam(
                launch.identity.pid, args.window, args.launch_timeout
            )
            orchestration["validation_before_warmup"] = {"wam": wam_initial}
            native_startup = wait_for_wam_native_proof(
                artifacts["native_telemetry"],
                launch_request_monotonic_ns,
                args.launch_timeout,
                expected_run_id=native_run_id,
                expected_process_id=launch.identity.pid,
                expected_asset_sha256=clip_identity["sha256"],
                expected_candidate_id=candidate_token["sha256"],
            )
            process_identity = native_startup.get("process_identity")
            if not isinstance(process_identity, Mapping):
                raise NativeProofIneligible(
                    "WAM native benchmark is ineligible: telemetry process identity unavailable"
                )
            orchestration["launch"]["telemetry_process_identity"] = dict(
                process_identity
            )
            native_startup["measurement"] = {
                "scope": "fresh LaunchServices request through exact native FrameDrawn",
                "began_before_launch": True,
                "launch_request_monotonic_ns": launch_request_monotonic_ns,
                "cross_process_clock": (
                    "macOS process-independent monotonic clock: Python monotonic_ns "
                    "to C++ steady_clock"
                ),
                "warm_open_note": (
                    "null unless a second in-process open_requested/native-selected/"
                    "first-frame-drawn lineage is present"
                ),
            }
            orchestration["native_startup"] = native_startup
            _json_write(artifacts["sidecar"], orchestration)
            require_wam_native_provisional_proof(native_startup)
        elif args.player == "quicktime":
            quicktime_initial = configure_quicktime(
                clip.name,
                args.start_time,
                args.speed,
                args.window,
                args.launch_timeout,
            )
            orchestration["validation_before_warmup"] = {"quicktime": quicktime_initial}
            required_source = args.start_time + (args.warmup + args.duration) * args.speed
            if float(quicktime_initial["duration_s"]) + 0.25 < required_source:
                raise SuiteError(
                    "QuickTime clip is too short for the requested warm-up and measurement at this speed"
                )
        elif args.player == "vlc":
            vlc_initial = configure_vlc(
                args.start_time, args.window, args.launch_timeout
            )
            orchestration["validation_before_warmup"] = {"vlc": vlc_initial}
            required_source = args.start_time + (args.warmup + args.duration) * args.speed
            if float(vlc_initial["duration_s"]) + 0.25 < required_source:
                raise SuiteError(
                    "VLC clip is too short for the requested warm-up and measurement at this speed"
                )

        validity_tracker = ForegroundWindowValidityTracker(
            launch.identity,
            args.window,
        )
        validity_tracker.begin_phase("warmup")
        warmup_started_at = utc_now()
        warmup_started = time.monotonic()
        helpers, unrelated_helpers = discover_helpers_during_warmup(
            before,
            launch.identity,
            args.warmup,
            target_coalition.coalition_id,
            validity_tracker.sample_if_due,
        )
        validity_tracker.end_phase()
        warmup_validity = validity_tracker.report()
        companions = discover_companion_players_during_warmup(
            before, launch.identity, executable, 0.0, companions
        )
        orchestration["warmup"] = {
            "started_at": warmup_started_at,
            "elapsed_s": time.monotonic() - warmup_started,
            "new_decoder_helpers_seen": [
                identity.as_dict() for identity in sorted(helpers.values(), key=lambda item: item.pid)
            ],
            "new_unrelated_decoder_helpers_ignored": [
                value for _, value in sorted(unrelated_helpers.items())
            ],
            "new_companion_player_processes_seen": [
                identity.as_dict()
                for identity in sorted(companions.values(), key=lambda item: item.pid)
            ],
            "foreground_window_validity": {
                "valid": warmup_validity["valid"],
                "sample_count": sum(
                    sample["phase"] == "warmup"
                    for sample in warmup_validity["samples"]
                ),
                "contamination_intervals": [
                    interval
                    for interval in warmup_validity["contamination_intervals"]
                    if interval["phase"] == "warmup"
                ],
            },
        }
        require_clean_foreground_validity(warmup_validity, "warmup")
        current = process_table()
        live_helpers = live_exact_identities(list(helpers.values()), current)
        live_companions = live_exact_identities(list(companions.values()), current)
        targets = live_exact_identities(
            [launch.identity, *live_companions, *live_helpers], current
        )
        if not targets or targets[0].pid != launch.identity.pid:
            raise SuiteError("main player was not alive with its original identity after warm-up")

        start_validation: dict[str, Any] = {
            "at": utc_now(),
            "processes_alive": [identity.as_dict() for identity in targets],
            "lsof": validate_lsof(clip, targets),
        }
        if args.player == "wam":
            state = configure_wam(
                launch.identity.pid, args.window, args.launch_timeout
            )
            require_expected_wam_window_state(state, args.window)
            start_validation["wam"] = state
        elif args.player == "quicktime":
            state = quicktime_state(clip.name)
            require_expected_player_state(
                args.player, state, clip, args.speed, args.window
            )
            start_validation["quicktime"] = state
            if args.warmup > 0 and quicktime_initial is not None:
                if float(state["current_time_s"]) <= float(quicktime_initial["current_time_s"]) + 0.05:
                    raise SuiteError("QuickTime time did not advance during warm-up")
        elif args.player == "vlc":
            state = vlc_state()
            require_expected_player_state(
                args.player, state, clip, args.speed, args.window
            )
            start_validation["vlc"] = state
            if args.warmup > 0 and vlc_initial is not None:
                if float(state["current_time_s"]) <= float(vlc_initial["current_time_s"]) + 0.05:
                    raise SuiteError("VLC time did not advance during warm-up")
        start_validation["launch_log"] = require_viable_video_output(
            args.player, artifacts["launch_log"]
        )
        orchestration["validation_at_measurement_start"] = start_validation
        if not start_validation["lsof"]["media_open"]:
            raise SuiteError("the exact benchmark clip was not open at measurement start")

        helper_continuity = DecoderHelperContinuityTracker(
            before,
            launch.identity,
            live_helpers,
            target_coalition.coalition_id,
            require_helper=args.player == "wam",
        )
        helper_continuity.sample()
        initial_helper_continuity = helper_continuity.report()
        orchestration["decoder_helper_continuity"] = initial_helper_continuity
        require_clean_decoder_helper_continuity(initial_helper_continuity)

        validity_tracker.begin_phase("measurement")
        playback_validation_started = time.monotonic()

        def sample_measurement_validity() -> None:
            validity_tracker.sample_if_due()
            helper_continuity.sample()

        collector_command = build_collector_command(
            collector,
            targets,
            args.player,
            args.clip_id or clip.stem,
            args.run,
            args.speed,
            args.duration,
            args.interval,
            args.output,
        )
        orchestration["collector"] = {"command": collector_command, "started_at": utc_now()}
        _json_write(artifacts["sidecar"], orchestration)
        collected = run_with_periodic_callback(
            collector_command,
            timeout=args.duration + 180.0,
            callback=sample_measurement_validity,
            poll_interval_s=DECODER_HELPER_SAMPLE_INTERVAL_S,
        )
        validity_tracker.end_phase()
        foreground_validity = validity_tracker.report()
        orchestration["foreground_window_validity"] = foreground_validity
        collector_returncode = collected.returncode
        orchestration["collector"].update(
            {
                "ended_at": utc_now(),
                "exit_code": collected.returncode,
                "stdout": collected.stdout.strip(),
                "stderr": collected.stderr.strip(),
                "target_pids": [identity.pid for identity in targets],
            }
        )
        if collected.returncode != 0:
            raise SuiteError(
                f"collector failed with status {collected.returncode}: {collected.stderr.strip()}"
            )
        if not args.output.is_file():
            raise SuiteError("collector reported success but did not create its result JSON")
        require_clean_foreground_validity(foreground_validity, "measurement")
        helper_continuity_report = helper_continuity.report()
        orchestration["decoder_helper_continuity"] = helper_continuity_report
        require_clean_decoder_helper_continuity(helper_continuity_report)

        end_table = process_table()
        end_validation: dict[str, Any] = {
            "at": utc_now(),
            "main_process_alive": bool(live_exact_identities([launch.identity], end_table)),
            "tracked_processes_alive": [
                identity.as_dict() for identity in live_exact_identities(targets, end_table)
            ],
            "lsof": validate_lsof(clip, targets),
        }
        late_helper_candidates = [
            identity
            for pid, identity in helper_processes(end_table).items()
            if pid not in helper_processes(before)
            and pid not in helpers
            and pid not in unrelated_helpers
        ]
        late_helpers, unrelated_late_helpers = partition_new_helpers_by_coalition(
            late_helper_candidates, target_coalition.coalition_id
        )
        if late_helpers:
            end_validation["unmeasured_new_decoder_helpers"] = [
                identity.as_dict() for identity in late_helpers
            ]
        if unrelated_late_helpers:
            end_validation["new_unrelated_decoder_helpers_ignored"] = unrelated_late_helpers
        late_companions = [
            identity
            for identity in matching_executable(end_table, executable)
            if identity.pid != launch.identity.pid
            and identity.pid not in before
            and identity.pid not in companions
        ]
        if late_companions:
            end_validation["unmeasured_new_companion_player_processes"] = [
                identity.as_dict() for identity in late_companions
            ]
        if args.player == "wam" and end_validation["main_process_alive"]:
            end_state = wam_window_state(launch.identity.pid)
            require_expected_wam_window_state(end_state, args.window)
            end_validation["wam"] = end_state
            final_native_proof = summarize_wam_native_proof(
                read_wam_native_telemetry(artifacts["native_telemetry"]),
                launch_request_monotonic_ns,
                native_run_id,
                launch.identity.pid,
                int(
                    orchestration["launch"]["telemetry_process_identity"][
                        "process_start_abstime"
                    ]
                ),
                clip_identity["sha256"],
                candidate_token["sha256"],
                require_stream_complete=False,
            )
            final_native_proof["measurement"] = orchestration["native_startup"][
                "measurement"
            ]
            final_native_proof["validated_after_measurement"] = True
            orchestration["native_startup"] = final_native_proof
            end_validation["native_route_proof"] = {
                "eligible": final_native_proof["eligible"],
                "route": final_native_proof["route"],
                "required_evidence": final_native_proof["required_evidence"],
                "libmpv_never_initialized": final_native_proof[
                    "libmpv_never_initialized"
                ],
            }
            require_wam_native_provisional_proof(final_native_proof)
        elif args.player == "quicktime" and end_validation["main_process_alive"]:
            end_state = quicktime_state(clip.name)
            require_expected_player_state(
                args.player, end_state, clip, args.speed, args.window
            )
            end_validation["quicktime"] = end_state
            end_validation["timeline_progress"] = require_clock_progress(
                args.player,
                start_validation["quicktime"],
                end_state,
                time.monotonic() - playback_validation_started,
                args.speed,
            )
        elif args.player == "vlc" and end_validation["main_process_alive"]:
            end_state = vlc_state()
            require_expected_player_state(
                args.player, end_state, clip, args.speed, args.window
            )
            end_validation["vlc"] = end_state
            end_validation["timeline_progress"] = require_clock_progress(
                args.player,
                start_validation["vlc"],
                end_state,
                time.monotonic() - playback_validation_started,
                args.speed,
            )
        end_validation["launch_log"] = require_viable_video_output(
            args.player, artifacts["launch_log"]
        )
        ending_clip_identity = _clip_metadata(clip)
        end_validation["asset_identity"] = {
            "canonical_path": str(clip),
            "bytes": ending_clip_identity["bytes"],
            "sha256": ending_clip_identity["sha256"],
        }
        if (
            ending_clip_identity["bytes"] != clip_identity["bytes"]
            or ending_clip_identity["sha256"] != clip_identity["sha256"]
        ):
            raise SuiteError("benchmark clip bytes changed after the prelaunch asset hash")
        orchestration["validation_at_measurement_end"] = end_validation
        if not end_validation["main_process_alive"]:
            raise SuiteError("player exited before measurement finished")
        if not end_validation["lsof"]["media_open"]:
            raise SuiteError("the exact benchmark clip was not open at measurement end")
        if late_helpers:
            raise SuiteError(
                "new decoder helper PID(s) appeared after warm-up and were excluded from collector totals"
            )
        if late_companions:
            raise SuiteError(
                "new companion player PID(s) appeared after warm-up and were excluded from collector totals"
            )
    except BaseException as error:
        failure = error
        orchestration["error"] = {"type": type(error).__name__, "message": str(error)}
    finally:
        if helper_continuity is not None:
            try:
                orchestration["decoder_helper_continuity"] = (
                    helper_continuity.report()
                )
            except BaseException as helper_error:
                orchestration["warnings"].append(
                    f"could not finalize decoder-helper continuity report: {helper_error}"
                )
        if validity_tracker is not None:
            try:
                validity_tracker.end_phase()
                orchestration["foreground_window_validity"] = validity_tracker.report()
            except BaseException as validity_error:
                orchestration["warnings"].append(
                    f"could not finalize foreground validity report: {validity_error}"
                )
        if launch is not None:
            # Setup can fail before the normal warm-up discovery pass (for
            # example while a busy VLC ignores AppleScript). Sweep once more
            # before signaling anything, accepting only an exact executable
            # born inside the deliberately short launch grace. This captures
            # VLC's re-parented Rosetta peer across `lstart` rounding without
            # ever claiming a later user launch.
            try:
                cleanup_table = process_table()
                for identity in matching_executable(cleanup_table, executable):
                    if (
                        identity.pid != launch.identity.pid
                        and identity.pid not in before
                        and is_launch_companion(launch.identity, identity)
                    ):
                        companions.setdefault(identity.pid, identity)
            except SuiteError as cleanup_error:
                orchestration["warnings"].append(
                    f"could not complete final companion-process sweep: {cleanup_error}"
                )
            orderly_exit_proven = False
            forced_cleanup_used = False
            if args.player == "wam" and failure is None:
                orderly_wam_quit = quit_exact_wam_orderly(
                    launch.identity, timeout=args.launch_timeout
                )
                orderly_exit_proven = (
                    orderly_wam_quit.get("status")
                    == "exited_after_orderly_quit"
                )
                if not orderly_exit_proven:
                    failure = NativeProofIneligible(
                        "WAM did not complete an exact orderly quit; terminal "
                        "telemetry commit cannot be trusted"
                    )

            # SIGTERM is never part of a qualifying WAM run. It is retained
            # solely as best-effort cleanup after an earlier failure or an
            # orderly-quit failure, and that fact is explicit in the artifact.
            if args.player == "wam" and orderly_exit_proven:
                main_cleanup = orderly_wam_quit
            else:
                main_cleanup = terminate_exact(launch.identity)
                forced_cleanup_used = args.player == "wam"
            orchestration["termination"] = {
                "main": main_cleanup,
                "orderly_quit": orderly_wam_quit,
                "orderly_exit_proven": orderly_exit_proven,
                "sigterm_is_nongating_cleanup_fallback": forced_cleanup_used,
                "companions": [
                    terminate_exact(identity)
                    for identity in sorted(companions.values(), key=lambda item: item.pid)
                ],
                "helpers": helper_exit_status(list(helpers.values())),
            }
            try:
                launch.process.wait(timeout=0.1)
            except subprocess.TimeoutExpired:
                pass
            orchestration["termination"]["launcher_returncode"] = launch.process.poll()
            launch.log_file.close()
            if args.player == "wam" and orderly_exit_proven:
                try:
                    terminal_native_proof = summarize_wam_native_proof(
                        read_wam_native_telemetry(artifacts["native_telemetry"]),
                        launch_request_monotonic_ns,
                        native_run_id,
                        launch.identity.pid,
                        int(
                            orchestration["launch"]["telemetry_process_identity"][
                                "process_start_abstime"
                            ]
                        ),
                        clip_identity["sha256"],
                        candidate_token["sha256"],
                        require_stream_complete=True,
                    )
                    terminal_native_proof["measurement"] = orchestration[
                        "native_startup"
                    ]["measurement"]
                    terminal_native_proof["validated_after_orderly_exit"] = True
                    orchestration["native_startup"] = terminal_native_proof
                    orchestration["termination"]["terminal_stream_commit"] = {
                        "eligible": terminal_native_proof["eligible"],
                        "stream_complete": terminal_native_proof["stream_complete"],
                        "candidate_identity": terminal_native_proof[
                            "candidate_identity"
                        ],
                        "reasons": terminal_native_proof["reasons"],
                    }
                    if terminal_native_proof.get("eligible") is not True:
                        failure = NativeProofIneligible(
                            "WAM terminal native proof is ineligible: "
                            + "; ".join(terminal_native_proof.get("reasons", ()))
                        )
                except BaseException as terminal_error:
                    orchestration["termination"]["terminal_stream_commit"] = {
                        "eligible": False,
                        "stream_complete": False,
                        "error": str(terminal_error),
                    }
                    failure = NativeProofIneligible(
                        "WAM terminal native proof could not be validated after "
                        f"orderly exit: {terminal_error}"
                    )
            elif args.player == "wam":
                orchestration["termination"]["terminal_stream_commit"] = {
                    "eligible": False,
                    "stream_complete": False,
                    "reason": "exact orderly exit was not proven",
                }
        orchestration["ended_at"] = utc_now()
        _json_write(artifacts["sidecar"], orchestration)
        if args.output.is_file():
            try:
                _merge_orchestration(args.output, orchestration)
            except BaseException as merge_error:
                if failure is None:
                    failure = merge_error

    if failure is not None:
        if isinstance(failure, KeyboardInterrupt):
            raise failure
        if isinstance(failure, NativeProofIneligible):
            raise failure
        raise SuiteError(str(failure)) from failure
    return 0 if collector_returncode == 0 else 2


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--player", choices=("wam", "vlc", "quicktime"), required=True)
    parser.add_argument("--clip", required=True, type=Path, help="local media file")
    parser.add_argument("--clip-id", help="stable corpus ID; defaults to the clip stem")
    parser.add_argument("--run", required=True, help="replicate/run label")
    parser.add_argument("--speed", type=finite_positive, default=1.0)
    parser.add_argument("--start-time", type=finite_nonnegative, default=0.0)
    parser.add_argument("--warmup", type=finite_nonnegative, default=15.0)
    parser.add_argument("--duration", type=finite_positive, default=30.0)
    parser.add_argument("--interval", type=int, choices=range(1, 61), default=1)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--window", type=window_size, default=DEFAULT_WINDOW, metavar="WIDTHxHEIGHT")
    parser.add_argument(
        "--wam-app",
        "--wam",
        dest="wam",
        type=Path,
        help="WAM.app or WAM executable",
    )
    parser.add_argument("--vlc", type=Path, default=DEFAULT_VLC_APP, help=argparse.SUPPRESS)
    parser.add_argument(
        "--quicktime", type=Path, default=DEFAULT_QUICKTIME_APP, help=argparse.SUPPRESS
    )
    parser.add_argument("--collector", type=Path, default=DEFAULT_COLLECTOR, help=argparse.SUPPRESS)
    parser.add_argument("--launch-timeout", type=finite_positive, default=20.0, help=argparse.SUPPRESS)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        return run_suite(args)
    except KeyboardInterrupt:
        print("benchmark interrupted; exact spawned process cleanup was attempted", file=sys.stderr)
        return 130
    except NativeProofIneligible as error:
        print(f"run_suite.py: {error}", file=sys.stderr)
        return NATIVE_PROOF_INELIGIBLE_EXIT
    except SuiteError as error:
        print(f"run_suite.py: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
