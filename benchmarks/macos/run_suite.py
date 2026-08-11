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
import subprocess
import sys
import time
from pathlib import Path
from typing import Any, Callable, Mapping, Sequence


PROJECT_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_COLLECTOR = Path(__file__).with_name("collect.py")
DEFAULT_VLC_APP = Path("/Applications/VLC.app")
DEFAULT_QUICKTIME_APP = Path("/System/Applications/QuickTime Player.app")
DEFAULT_WINDOW = (1180, 720)
HELPER_BASENAME = "VTDecoderXPCService"
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

    return ResourceCoalition(
        coalition_id=int(id_match.group(1)),
        name=optional_value("name"),
        bundle_id=optional_value("bundle ID"),
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
        # LaunchServices gives the benchmark app its own macOS resource
        # coalition. Directly exec'ing WAM from the harness inherits Codex's
        # coalition and makes VideoToolbox helper ownership ambiguous.
        return [
            "/usr/bin/open",
            "-n",
            "-W",
            "-a",
            str(app_bundle_for_executable(executable)),
            "--args",
            f"--rate={format_number(speed)}",
            str(clip),
        ]
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
            "The current standalone libmpv WAM build does not expose mpv's renderer "
            "frame counters outside the process. No debug IPC or extra logging is "
            "enabled during a benchmark because that would change runtime configuration."
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
    """Run a quiet child while servicing a read-only validity sampler."""

    process = subprocess.Popen(
        list(command),
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        close_fds=True,
    )
    deadline = time.monotonic() + timeout
    try:
        while process.poll() is None:
            callback()
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                process.kill()
                stdout, stderr = process.communicate()
                raise subprocess.TimeoutExpired(
                    list(command), timeout, output=stdout, stderr=stderr
                )
            time.sleep(min(poll_interval_s, remaining))
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
    stat = clip.stat()
    digest = hashlib.sha256()
    with clip.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return {
        "path": str(clip),
        "bytes": stat.st_size,
        "mtime_ns": stat.st_mtime_ns,
        "sha256": digest.hexdigest(),
    }


def _merge_orchestration(output: Path, orchestration: Mapping[str, Any]) -> None:
    try:
        result = json.loads(output.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise SuiteError(f"could not augment collector output {output}: {error}") from error
    result["orchestration"] = orchestration
    _json_write(output, result)


def artifact_paths(output: Path, player: str) -> dict[str, Path]:
    return {
        "sidecar": output.with_name(f"{output.stem}.orchestration.json"),
        "launch_log": output.with_name(f"{output.stem}.{player}.launch.log"),
        "raw_top": output.with_name(f"{output.stem}.top.txt"),
    }


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

    before = process_table()
    already_running = matching_executable(before, executable)
    if already_running:
        pids = ", ".join(str(identity.pid) for identity in already_running)
        raise SuiteError(
            f"{args.player} is already running as PID(s) {pids}; quit it first so automation cannot touch user playback"
        )

    command = build_player_command(
        args.player, executable, clip, args.speed, args.start_time, args.window
    )
    orchestration: dict[str, Any] = {
        "schema": "wam.macos.orchestration.v1",
        "started_at": utc_now(),
        "player": args.player,
        "clip_id": args.clip_id or clip.stem,
        "clip": _clip_metadata(clip),
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
    failure: BaseException | None = None
    collector_returncode: int | None = None
    try:
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

        validity_tracker.begin_phase("measurement")
        playback_validation_started = time.monotonic()

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
            callback=validity_tracker.sample_if_due,
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
            orchestration["termination"] = {
                "main": terminate_exact(launch.identity),
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
    except SuiteError as error:
        print(f"run_suite.py: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
