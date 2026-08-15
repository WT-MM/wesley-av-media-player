#!/usr/bin/env python3
"""Run the controlled WAM/VLC/QuickTime benchmark matrix on macOS.

Each trial receives a new hard-link pathname under /private/tmp.  The bytes and
inode remain identical while path-based player resume state cannot carry from
one trial into another.  Results are written into a newly reserved suite
directory, and every attempted run is represented in an atomic JSON manifest.
"""

from __future__ import annotations

import argparse
import dataclasses
import datetime as dt
import errno
import json
import math
import os
import platform
import re
import subprocess
import sys
import tempfile
import time
import uuid
from collections import Counter
from pathlib import Path
from typing import Any, Callable, Mapping, Sequence


PROJECT_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_RUNNER = Path(__file__).with_name("run_suite.py")
DEFAULT_MEDIA_DIR = PROJECT_ROOT / ".cache" / "benchmarks" / "media"
DEFAULT_OUTPUT_ROOT = PROJECT_ROOT / "benchmarks" / "results"
DEFAULT_ALIAS_PARENT = Path("/private/tmp")
DEFAULT_VLC_APP = Path("/Applications/VLC.app")
DEFAULT_QUICKTIME_APP = Path("/System/Applications/QuickTime Player.app")
PLAYERS = ("wam", "vlc", "quicktime")
NATIVE_PROOF_INELIGIBLE_EXIT = 3
DEFAULT_WINDOW = "1180x720"
WAM_EXPERIMENT_ENV = (
    "WAM_RENDER_PROFILE",
    "WAM_VIDEO_SYNC",
    "WAM_SDR_FBO_FORMAT",
)


class MatrixError(RuntimeError):
    """A matrix setup, safety, or artifact-integrity failure."""


@dataclasses.dataclass(frozen=True)
class BenchmarkCase:
    id: str
    group: str
    filename: str
    speed: float
    source_duration_s: float
    warmup_s: float
    measurement_s: float
    default_repetitions: int
    expected_unsupported_players: frozenset[str] = frozenset()
    description: str = ""

    def as_dict(self) -> dict[str, Any]:
        value = dataclasses.asdict(self)
        value["expected_unsupported_players"] = sorted(self.expected_unsupported_players)
        return value


CASES: tuple[BenchmarkCase, ...] = (
    BenchmarkCase(
        id="tos-h264-4k24-1x",
        group="primary",
        filename="tos-h264-4k24-180s.mp4",
        speed=1.0,
        source_duration_s=180.083,
        warmup_s=12.0,
        measurement_s=20.0,
        default_repetitions=3,
        description="Tears of Steel 4K H.264 steady-state playback at 1x",
    ),
    BenchmarkCase(
        id="tos-hevc-4k24-1x",
        group="primary",
        filename="tos-hevc-hvc1-4k24-180s.mp4",
        speed=1.0,
        source_duration_s=180.083,
        warmup_s=12.0,
        measurement_s=20.0,
        default_repetitions=3,
        description="Tears of Steel 4K HEVC hvc1 stream-copy remux at 1x",
    ),
    BenchmarkCase(
        id="tos-h264-4k24-2x",
        group="primary",
        filename="tos-h264-4k24-180s.mp4",
        speed=2.0,
        source_duration_s=180.083,
        warmup_s=12.0,
        measurement_s=20.0,
        default_repetitions=3,
        description="Tears of Steel 4K H.264 pitch-preserved playback at 2x",
    ),
    BenchmarkCase(
        id="wam-test-h264-1x",
        group="local",
        filename="wam-test-h264-180s.mp4",
        speed=1.0,
        source_duration_s=180.086,
        warmup_s=10.0,
        measurement_s=15.0,
        default_repetitions=1,
        description="WAM repository H.264 fixture extended without re-encoding",
    ),
    BenchmarkCase(
        id="noaa-octopus-vp9-1x",
        group="compatibility",
        filename="noaa-octopus-vp9.webm",
        speed=1.0,
        source_duration_s=87.304,
        warmup_s=8.0,
        measurement_s=12.0,
        default_repetitions=1,
        expected_unsupported_players=frozenset({"quicktime"}),
        description="Real NOAA VP9/Opus WebM compatibility probe",
    ),
    BenchmarkCase(
        id="nasa-minute-av1-1x",
        group="compatibility",
        filename="nasa-minute-av1.webm",
        speed=1.0,
        source_duration_s=99.421,
        warmup_s=8.0,
        measurement_s=12.0,
        default_repetitions=1,
        expected_unsupported_players=frozenset({"quicktime", "vlc"}),
        description="Real NASA AV1/Opus WebM compatibility probe",
    ),
)
CASE_BY_ID = {case.id: case for case in CASES}


@dataclasses.dataclass
class Trial:
    ordinal: int
    id: str
    case: BenchmarkCase
    repetition: int
    player: str
    player_position: int
    warmup_s: float
    measurement_s: float
    source: Path
    alias: Path
    output: Path
    runner_log: Path

    def as_manifest_entry(self) -> dict[str, Any]:
        expected_support = (
            "unsupported" if self.player in self.case.expected_unsupported_players else "supported"
        )
        return {
            "ordinal": self.ordinal,
            "id": self.id,
            "case_id": self.case.id,
            "case_group": self.case.group,
            "repetition": self.repetition,
            "player": self.player,
            "player_position": self.player_position,
            "speed": self.case.speed,
            "warmup_s": self.warmup_s,
            "measurement_s": self.measurement_s,
            "support_expectation": expected_support,
            "source_path": str(self.source),
            "unique_alias_path": str(self.alias),
            "result_path": str(self.output),
            "runner_log_path": str(self.runner_log),
            "status": "pending",
        }


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


def positive_integer(value: str) -> int:
    parsed = int(value)
    if parsed <= 0:
        raise argparse.ArgumentTypeError("must be an integer greater than zero")
    return parsed


def safe_suite_id(value: str) -> str:
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,79}", value):
        raise argparse.ArgumentTypeError(
            "must be 1-80 characters using only letters, numbers, dot, underscore, or hyphen"
        )
    return value


def generated_suite_id() -> str:
    stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    return f"{stamp}-{uuid.uuid4().hex[:8]}"


def counterbalanced_player_order(repetition: int) -> tuple[str, ...]:
    """Return the three-period balanced rotation requested by the protocol."""

    if repetition <= 0:
        raise ValueError("repetition must be positive")
    offset = (repetition - 1) % len(PLAYERS)
    return PLAYERS[offset:] + PLAYERS[:offset]


def selected_players(args: argparse.Namespace) -> tuple[str, ...]:
    requested = set(args.player or PLAYERS)
    return tuple(player for player in PLAYERS if player in requested)


def selected_player_order(repetition: int, players: Sequence[str]) -> tuple[str, ...]:
    selected = set(players)
    return tuple(
        player for player in counterbalanced_player_order(repetition) if player in selected
    )


def selected_cases(args: argparse.Namespace) -> list[BenchmarkCase]:
    if args.case:
        selected_ids = set(args.case)
        return [case for case in CASES if case.id in selected_ids]
    groups = {"primary"}
    if args.include_local or args.all_cases:
        groups.add("local")
    if args.include_compatibility or args.all_cases:
        groups.add("compatibility")
    return [case for case in CASES if case.group in groups]


def repetitions_for(case: BenchmarkCase, override: int | None) -> int:
    return override if override is not None else case.default_repetitions


def timing_for(
    case: BenchmarkCase,
    warmup_override: float | None,
    measurement_override: float | None,
) -> tuple[float, float]:
    return (
        case.warmup_s if warmup_override is None else warmup_override,
        case.measurement_s if measurement_override is None else measurement_override,
    )


def validate_playback_window(case: BenchmarkCase, warmup_s: float, measurement_s: float) -> None:
    source_needed = (warmup_s + measurement_s) * case.speed
    if source_needed > case.source_duration_s - 0.25:
        raise MatrixError(
            f"{case.id} needs {source_needed:.3f}s of source at {case.speed:g}x, but "
            f"{case.filename} is only {case.source_duration_s:.3f}s; use shorter timing or a longer clip"
        )


def validate_sources(cases: Sequence[BenchmarkCase], media_dir: Path) -> dict[str, Path]:
    sources: dict[str, Path] = {}
    missing: list[Path] = []
    for case in cases:
        candidate = media_dir / case.filename
        try:
            resolved = candidate.expanduser().resolve(strict=True)
        except OSError:
            missing.append(candidate)
            continue
        if not resolved.is_file():
            missing.append(candidate)
            continue
        sources[case.id] = resolved
    if missing:
        joined = "\n  ".join(str(path) for path in missing)
        raise MatrixError(
            f"benchmark media is missing:\n  {joined}\nRun benchmarks/prepare_corpus.zsh first."
        )
    return sources


def reserve_output_directory(output_root: Path, suite_id: str) -> Path:
    root = output_root.expanduser().resolve()
    root.mkdir(parents=True, exist_ok=True)
    output_dir = root / suite_id
    try:
        output_dir.mkdir(mode=0o755, exist_ok=False)
    except FileExistsError as error:
        raise MatrixError(
            f"refusing to reuse benchmark suite directory: {output_dir}; choose another --suite-id"
        ) from error
    return output_dir


def create_alias_directory(suite_id: str, parent: Path = DEFAULT_ALIAS_PARENT) -> Path:
    try:
        parent_resolved = parent.expanduser().resolve(strict=True)
    except OSError as error:
        raise MatrixError(f"could not resolve temporary alias parent {parent}: {error}") from error
    if not parent_resolved.is_dir():
        raise MatrixError(f"temporary alias parent is not a directory: {parent_resolved}")
    return Path(tempfile.mkdtemp(prefix=f"wam-benchmark-{suite_id}-", dir=parent_resolved))


def build_trials(
    cases: Sequence[BenchmarkCase],
    sources: Mapping[str, Path],
    output_dir: Path,
    alias_dir: Path,
    repetition_override: int | None = None,
    warmup_override: float | None = None,
    measurement_override: float | None = None,
    players: Sequence[str] = PLAYERS,
) -> list[Trial]:
    repetitions = {case.id: repetitions_for(case, repetition_override) for case in cases}
    max_repetitions = max(repetitions.values(), default=0)
    trials: list[Trial] = []
    for repetition in range(1, max_repetitions + 1):
        player_order = selected_player_order(repetition, players)
        for case in cases:
            if repetition > repetitions[case.id]:
                continue
            warmup_s, measurement_s = timing_for(
                case, warmup_override, measurement_override
            )
            validate_playback_window(case, warmup_s, measurement_s)
            for player_position, player in enumerate(player_order, start=1):
                ordinal = len(trials) + 1
                trial_id = f"{case.id}.rep-{repetition:02d}.{player}"
                suffix = Path(case.filename).suffix
                alias = alias_dir / (
                    f"trial-{ordinal:03d}-{case.id}-rep-{repetition:02d}-{player}{suffix}"
                )
                case_output = output_dir / "results" / case.id
                output = case_output / f"rep-{repetition:02d}-{player}.json"
                runner_log = case_output / f"rep-{repetition:02d}-{player}.matrix-runner.log"
                trials.append(
                    Trial(
                        ordinal=ordinal,
                        id=trial_id,
                        case=case,
                        repetition=repetition,
                        player=player,
                        player_position=player_position,
                        warmup_s=warmup_s,
                        measurement_s=measurement_s,
                        source=sources[case.id],
                        alias=alias,
                        output=output,
                        runner_log=runner_log,
                    )
                )
    return trials


def create_hardlink_aliases(trials: Sequence[Trial]) -> None:
    created: list[Path] = []
    try:
        for trial in trials:
            if trial.alias.exists():
                raise MatrixError(f"refusing to reuse media alias: {trial.alias}")
            try:
                os.link(trial.source, trial.alias)
            except OSError as error:
                if error.errno == errno.EXDEV:
                    raise MatrixError(
                        f"cannot hard-link {trial.source} into {trial.alias.parent}: they are on "
                        "different filesystems; place the prepared corpus on the same volume as /private/tmp"
                    ) from error
                raise MatrixError(f"could not create hard-link alias {trial.alias}: {error}") from error
            created.append(trial.alias)
            source_stat = trial.source.stat()
            alias_stat = trial.alias.stat()
            if (source_stat.st_dev, source_stat.st_ino) != (alias_stat.st_dev, alias_stat.st_ino):
                raise MatrixError(f"media alias is not the same inode as its source: {trial.alias}")
    except BaseException:
        for path in reversed(created):
            try:
                path.unlink()
            except OSError:
                pass
        raise


def cleanup_aliases(trials: Sequence[Trial], alias_dir: Path) -> dict[str, Any]:
    removed: list[str] = []
    errors: list[dict[str, str]] = []
    for trial in trials:
        path = trial.alias
        if path.parent != alias_dir:
            errors.append({"path": str(path), "error": "alias escaped the reserved directory"})
            continue
        try:
            was_present = path.exists()
            path.unlink(missing_ok=True)
            if was_present:
                removed.append(str(path))
        except OSError as error:
            errors.append({"path": str(path), "error": str(error)})
    directory_removed = False
    try:
        alias_dir.rmdir()
        directory_removed = True
    except OSError as error:
        errors.append({"path": str(alias_dir), "error": str(error)})
    return {
        "at": utc_now(),
        "removed_alias_count": len(removed),
        "alias_directory_removed": directory_removed,
        "errors": errors,
    }


def atomic_write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.{os.getpid()}.{uuid.uuid4().hex}.tmp")
    try:
        with temporary.open("x", encoding="utf-8") as stream:
            json.dump(value, stream, indent=2, sort_keys=True)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        try:
            temporary.unlink(missing_ok=True)
        except OSError:
            pass


def update_summary(manifest: dict[str, Any]) -> None:
    statuses = Counter(trial["status"] for trial in manifest["trials"])
    na_reasons = Counter(
        trial.get("n_a", {}).get("reason")
        for trial in manifest["trials"]
        if trial["status"] == "n/a"
    )
    na_reasons.pop(None, None)
    manifest["summary"] = {
        "total_trials": len(manifest["trials"]),
        "by_status": dict(sorted(statuses.items())),
        "n_a_by_reason": dict(sorted(na_reasons.items())),
    }
    manifest["updated_at"] = utc_now()


def write_manifest(path: Path, manifest: dict[str, Any]) -> None:
    update_summary(manifest)
    atomic_write_json(path, manifest)


def runner_artifacts(trial: Trial) -> list[Path]:
    output = trial.output
    artifacts = [
        output,
        output.with_name(f"{output.stem}.orchestration.json"),
        output.with_name(f"{output.stem}.{trial.player}.launch.log"),
        output.with_name(f"{output.stem}.top.txt"),
        trial.runner_log,
    ]
    if trial.player == "wam":
        artifacts.append(output.with_name(f"{output.stem}.wam.native.jsonl"))
    return artifacts


def assert_trial_artifacts_are_new(trial: Trial) -> None:
    collisions = [path for path in runner_artifacts(trial) if path.exists()]
    if collisions:
        raise MatrixError(
            "refusing to overwrite trial artifacts: " + ", ".join(str(path) for path in collisions)
        )


def build_runner_command(trial: Trial, args: argparse.Namespace) -> list[str]:
    command = [
        sys.executable,
        str(args.runner),
        "--player",
        trial.player,
        "--clip",
        str(trial.alias),
        "--clip-id",
        trial.case.id,
        "--run",
        f"rep-{trial.repetition:02d}",
        "--speed",
        format(trial.case.speed, ".12g"),
        "--start-time",
        "0",
        "--warmup",
        format(trial.warmup_s, ".12g"),
        "--duration",
        format(trial.measurement_s, ".12g"),
        "--interval",
        str(args.interval),
        "--window",
        DEFAULT_WINDOW,
        "--launch-timeout",
        format(args.launch_timeout, ".12g"),
        "--output",
        str(trial.output),
    ]
    if args.wam_app is not None:
        command.extend(["--wam-app", str(args.wam_app)])
    command.extend(["--vlc", str(args.vlc), "--quicktime", str(args.quicktime)])
    if args.collector is not None:
        command.extend(["--collector", str(args.collector)])
    return command


def _tail(value: str, limit: int = 4000) -> str:
    return value if len(value) <= limit else "…" + value[-limit:]


def write_runner_log(
    path: Path,
    command: Sequence[str],
    returncode: int | None,
    stdout: str,
    stderr: str,
) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    payload = {
        "command": list(command),
        "returncode": returncode,
        "stdout": stdout,
        "stderr": stderr,
    }
    with path.open("x", encoding="utf-8") as stream:
        json.dump(payload, stream, indent=2, sort_keys=True)
        stream.write("\n")


def mark_n_a(
    entry: dict[str, Any],
    *,
    reason: str,
    detail: str,
    basis: str,
) -> None:
    entry["status"] = "n/a"
    entry["performance_metrics_available"] = False
    entry["n_a"] = {"reason": reason, "detail": detail, "basis": basis}


def execute_trial(
    trial: Trial,
    entry: dict[str, Any],
    args: argparse.Namespace,
    run_process: Callable[..., subprocess.CompletedProcess[str]] = subprocess.run,
) -> bool:
    """Execute one trial and return True only when metrics are usable."""

    expected_unsupported = trial.player in trial.case.expected_unsupported_players
    if expected_unsupported and args.skip_expected_unsupported:
        mark_n_a(
            entry,
            reason="unsupported",
            detail="declared unsupported by this compatibility matrix",
            basis="predeclared compatibility expectation; invocation skipped by request",
        )
        entry["ended_at"] = utc_now()
        return False

    assert_trial_artifacts_are_new(trial)
    trial.output.parent.mkdir(parents=True, exist_ok=True)
    command = build_runner_command(trial, args)
    entry["status"] = "running"
    entry["started_at"] = utc_now()
    entry["runner_command"] = command

    returncode: int | None = None
    stdout = ""
    stderr = ""
    try:
        result = run_process(command, capture_output=True, text=True, check=False)
        returncode = result.returncode
        stdout = result.stdout or ""
        stderr = result.stderr or ""
    except OSError as error:
        stderr = str(error)
    write_runner_log(trial.runner_log, command, returncode, stdout, stderr)
    entry["runner"] = {
        "exit_code": returncode,
        "stdout_tail": _tail(stdout),
        "stderr_tail": _tail(stderr),
        "full_log": str(trial.runner_log),
    }
    entry["ended_at"] = utc_now()

    if returncode == 0 and trial.output.is_file():
        entry["status"] = "completed"
        entry["performance_metrics_available"] = True
        if expected_unsupported:
            entry["support_observation"] = (
                "completed despite the matrix's prior unsupported expectation"
            )
        return True

    if returncode == 0:
        reason = "failure"
        detail = "runner exited successfully but did not create the expected result JSON"
        basis = "artifact validation"
    elif returncode == NATIVE_PROOF_INELIGIBLE_EXIT and trial.player == "wam":
        reason = "ineligible"
        detail = _tail(
            stderr.strip()
            or "required native route and exact first-frame proof was unavailable",
            1000,
        )
        basis = (
            "env-gated native JSONL did not prove native_selected, an exact "
            "first_frame_drawn, and absence of fallback_selected"
        )
    elif expected_unsupported:
        reason = "unsupported"
        detail = _tail(stderr.strip() or f"runner exited with status {returncode}", 1000)
        basis = "predeclared compatibility expectation plus unsuccessful invocation"
    else:
        reason = "failure"
        detail = _tail(stderr.strip() or f"runner exited with status {returncode}", 1000)
        basis = "runner did not complete; no performance value is reported"
    mark_n_a(entry, reason=reason, detail=detail, basis=basis)
    return False


def preview_plan(cases: Sequence[BenchmarkCase], args: argparse.Namespace) -> dict[str, Any]:
    rows: list[dict[str, Any]] = []
    players = selected_players(args)
    max_repetitions = max(
        (repetitions_for(case, args.repetitions) for case in cases), default=0
    )
    for repetition in range(1, max_repetitions + 1):
        order = selected_player_order(repetition, players)
        for case in cases:
            if repetition > repetitions_for(case, args.repetitions):
                continue
            warmup_s, measurement_s = timing_for(case, args.warmup, args.duration)
            validate_playback_window(case, warmup_s, measurement_s)
            for position, player in enumerate(order, start=1):
                rows.append(
                    {
                        "case_id": case.id,
                        "repetition": repetition,
                        "player": player,
                        "player_position": position,
                        "speed": case.speed,
                        "warmup_s": warmup_s,
                        "measurement_s": measurement_s,
                        "expected_support": (
                            "unsupported"
                            if player in case.expected_unsupported_players
                            else "supported"
                        ),
                    }
                )
    return {"cases": [case.as_dict() for case in cases], "trials": rows}


def run_matrix(args: argparse.Namespace, alias_parent: Path = DEFAULT_ALIAS_PARENT) -> int:
    if sys.platform != "darwin":
        raise MatrixError("run_matrix.py requires macOS")
    cases = selected_cases(args)
    players = selected_players(args)
    if not cases:
        raise MatrixError("no benchmark cases were selected")
    if not players:
        raise MatrixError("no benchmark players were selected")
    if args.plan:
        print(json.dumps(preview_plan(cases, args), indent=2, sort_keys=True))
        return 0

    media_dir = args.media_dir.expanduser().resolve()
    sources = validate_sources(cases, media_dir)
    try:
        runner = args.runner.expanduser().resolve(strict=True)
    except OSError as error:
        raise MatrixError(f"could not resolve benchmark runner {args.runner}: {error}") from error
    if not runner.is_file():
        raise MatrixError(f"benchmark runner is not a file: {runner}")
    args.runner = runner
    if args.collector is not None:
        try:
            args.collector = args.collector.expanduser().resolve(strict=True)
        except OSError as error:
            raise MatrixError(f"could not resolve collector {args.collector}: {error}") from error

    suite_id = args.suite_id or generated_suite_id()
    output_dir = reserve_output_directory(args.output_root, suite_id)
    alias_dir = create_alias_directory(suite_id, alias_parent)
    manifest_path = output_dir / "manifest.json"
    trials: list[Trial] = []
    manifest: dict[str, Any] = {
        "schema": "wam.macos.matrix.v1",
        "suite_id": suite_id,
        "state": "preparing",
        "created_at": utc_now(),
        "output_directory": str(output_dir),
        "manifest_path": str(manifest_path),
        "alias_directory": str(alias_dir),
        "audio_policy": "unchanged; this tool never changes system or application volume",
        "host": {
            "platform": platform.platform(),
            "machine": platform.machine(),
            "python": platform.python_version(),
        },
        "configuration": {
            "media_directory": str(media_dir),
            "runner": str(args.runner),
            "selected_players": list(players),
            "wam_app": str(args.wam_app) if args.wam_app is not None else None,
            "wam_experiment_environment": {
                name: os.environ[name] for name in WAM_EXPERIMENT_ENV if name in os.environ
            },
            "interval_s": args.interval,
            "cooldown_s": args.cooldown,
            "window": DEFAULT_WINDOW,
            "repetition_override": args.repetitions,
            "warmup_override_s": args.warmup,
            "measurement_override_s": args.duration,
            "skip_expected_unsupported": args.skip_expected_unsupported,
            "fail_fast": args.fail_fast,
            "keep_aliases": args.keep_aliases,
            "player_order_by_repetition": {
                str(repetition): list(selected_player_order(repetition, players))
                for repetition in range(
                    1,
                    max(repetitions_for(case, args.repetitions) for case in cases) + 1,
                )
            },
        },
        "cases": [case.as_dict() for case in cases],
        "trials": [],
    }
    write_manifest(manifest_path, manifest)

    interrupted = False
    unexpected_failure = False
    try:
        trials = build_trials(
            cases,
            sources,
            output_dir,
            alias_dir,
            repetition_override=args.repetitions,
            warmup_override=args.warmup,
            measurement_override=args.duration,
            players=players,
        )
        manifest["trials"] = [trial.as_manifest_entry() for trial in trials]
        write_manifest(manifest_path, manifest)
        create_hardlink_aliases(trials)
        manifest["state"] = "running"
        manifest["aliases"] = {
            "created": len(trials),
            "method": "hard-link",
            "same_inode_verified": True,
        }
        write_manifest(manifest_path, manifest)

        for index, (trial, entry) in enumerate(zip(trials, manifest["trials"], strict=True)):
            print(
                f"[{index + 1}/{len(trials)}] {trial.case.id} rep {trial.repetition} "
                f"{trial.player} ({trial.case.speed:g}x)",
                flush=True,
            )
            entry["status"] = "running"
            entry["started_at"] = utc_now()
            write_manifest(manifest_path, manifest)
            try:
                completed = execute_trial(trial, entry, args)
            except KeyboardInterrupt:
                mark_n_a(
                    entry,
                    reason="interrupted",
                    detail="matrix interrupted while this trial was active",
                    basis="user or process interrupt",
                )
                entry["ended_at"] = utc_now()
                interrupted = True
                write_manifest(manifest_path, manifest)
                break
            except BaseException as error:
                mark_n_a(
                    entry,
                    reason="failure",
                    detail=str(error),
                    basis="matrix orchestration failure; no performance value is reported",
                )
                entry["ended_at"] = utc_now()
                completed = False
            trial_failed_unexpectedly = not completed and entry.get("n_a", {}).get(
                "reason"
            ) not in {"unsupported", "ineligible"}
            if trial_failed_unexpectedly:
                unexpected_failure = True
            write_manifest(manifest_path, manifest)
            if trial_failed_unexpectedly and args.fail_fast:
                manifest["aborted_after_trial"] = trial.id
                break
            if index + 1 < len(trials) and args.cooldown > 0:
                time.sleep(args.cooldown)

        if interrupted:
            manifest["state"] = "interrupted"
        else:
            pending = [trial for trial in manifest["trials"] if trial["status"] == "pending"]
            if pending:
                manifest["state"] = "aborted"
            elif unexpected_failure:
                manifest["state"] = "completed_with_failures"
            elif any(trial["status"] == "n/a" for trial in manifest["trials"]):
                manifest["state"] = "completed_with_na"
            else:
                manifest["state"] = "completed"
    except BaseException as error:
        manifest["state"] = "setup_failed"
        manifest["setup_error"] = {"type": type(error).__name__, "message": str(error)}
        write_manifest(manifest_path, manifest)
        if isinstance(error, KeyboardInterrupt):
            interrupted = True
        else:
            raise
    finally:
        if args.keep_aliases:
            manifest["alias_cleanup"] = {
                "at": utc_now(),
                "kept": True,
                "alias_directory": str(alias_dir),
            }
        else:
            manifest["alias_cleanup"] = cleanup_aliases(trials, alias_dir)
        manifest["ended_at"] = utc_now()
        write_manifest(manifest_path, manifest)

    print(f"Manifest: {manifest_path}", flush=True)
    if interrupted:
        return 130
    return 2 if unexpected_failure or manifest["state"] in {"aborted", "setup_failed"} else 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--media-dir", type=Path, default=DEFAULT_MEDIA_DIR)
    parser.add_argument("--output-root", type=Path, default=DEFAULT_OUTPUT_ROOT)
    parser.add_argument("--suite-id", type=safe_suite_id)
    parser.add_argument("--wam-app", type=Path, help="standalone WAM.app or its executable")
    parser.add_argument(
        "--player",
        action="append",
        choices=PLAYERS,
        help="run only this player; repeat to select more than one (default: all)",
    )
    parser.add_argument("--vlc", type=Path, default=DEFAULT_VLC_APP)
    parser.add_argument("--quicktime", type=Path, default=DEFAULT_QUICKTIME_APP)
    parser.add_argument("--runner", type=Path, default=DEFAULT_RUNNER, help=argparse.SUPPRESS)
    parser.add_argument("--collector", type=Path, help=argparse.SUPPRESS)
    parser.add_argument("--interval", type=int, choices=range(1, 61), default=1)
    parser.add_argument("--launch-timeout", type=finite_positive, default=20.0)
    parser.add_argument("--cooldown", type=finite_nonnegative, default=5.0)
    parser.add_argument(
        "--repetitions",
        type=positive_integer,
        help="override every case (defaults: three primary, one optional)",
    )
    parser.add_argument("--warmup", type=finite_nonnegative, help="override case warm-up")
    parser.add_argument("--duration", type=finite_positive, help="override case measurement")
    parser.add_argument("--include-local", action="store_true")
    parser.add_argument("--include-compatibility", action="store_true")
    parser.add_argument("--all-cases", action="store_true")
    parser.add_argument(
        "--case",
        action="append",
        choices=tuple(case.id for case in CASES),
        help="run only this case; repeat for more than one",
    )
    parser.add_argument(
        "--skip-expected-unsupported",
        action="store_true",
        help="record declared unsupported player/case pairs as N/A without launching them",
    )
    parser.add_argument("--fail-fast", action="store_true")
    parser.add_argument("--keep-aliases", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument(
        "--plan",
        action="store_true",
        help="print the selected schedule without creating files or launching players",
    )
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        return run_matrix(args)
    except MatrixError as error:
        print(f"run_matrix.py: {error}", file=sys.stderr)
        return 2
    except KeyboardInterrupt:
        print("benchmark matrix interrupted", file=sys.stderr)
        return 130


if __name__ == "__main__":
    raise SystemExit(main())
