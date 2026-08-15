#!/usr/bin/env python3
"""Headless measurement support for WAM's macOS shipping gate.

This module deliberately does not launch WAM and does not synthesize input.
It provides three safe building blocks for a later, explicitly approved screen
run:

* ``plan`` emits the fixed corpus/replicate/drag protocol;
* ``sample`` attaches read-only ``proc_pid_rusage`` sampling to exact PIDs;
* ``summarize`` combines saved samples and native JSONL telemetry.

The deterministic drag schedule is data, not an input side effect.  A future
screen-backed driver can consume it without making event timing part of the
benchmark's measurement logic.
"""

from __future__ import annotations

import argparse
import ctypes
import dataclasses
import datetime as dt
import errno
import json
import math
import os
import re
import statistics
import sys
import time
import uuid
from pathlib import Path
from typing import Any, Callable, Iterable, Mapping, Sequence

import run_suite
import shipper_identity
import shipper_memory_reconciliation
import shipper_phase_metrics
import shipper_raw_evidence
import shipper_screen_driver_evidence


SCHEMA = "wam.macos.shipper.v1"
DEFAULT_SAMPLE_INTERVAL_S = 0.05
DEFAULT_CPU_LIMIT_PERCENT = 10.0
DEFAULT_MEMORY_LIMIT_BYTES = 300 * 1024 * 1024
MAX_STARTUP_P95_MS = 750.0
MAX_STARTUP_SINGLE_MS = 1500.0
MAX_WARM_OPEN_P95_MS = 100.0
MAX_WARM_OPEN_SINGLE_MS = 200.0
MAX_COLD_START_CPU_P95_MS = 250.0
MAX_COLD_START_CPU_SINGLE_MS = 500.0
MAX_WARM_OPEN_CPU_TIME_MS = 25.0
MAX_SCRUB_DEMAND_TO_VISIBLE_P95_MS = 100.0
MAX_SCRUB_DEMAND_TO_VISIBLE_SINGLE_MS = 250.0
MAX_SCRUB_VISIBLE_GAP_P95_MS = 50.0
MAX_SCRUB_VISIBLE_GAP_SINGLE_MS = 100.0
MAX_SCRUB_COMMIT_P95_MS = 150.0
MAX_SCRUB_COMMIT_SINGLE_MS = 300.0
MAX_SCRUB_TARGET_ERROR_P95_MS = 50.0
MAX_SCRUB_TARGET_ERROR_SINGLE_MS = 100.0
MAX_SCRUB_ROLLING_CPU_PERCENT = 25.0
SCRUB_ROLLING_CPU_WINDOW_S = 0.250
DEFAULT_STARTUP_RUNS = 10
DEFAULT_STEADY_RUNS = 5
DEFAULT_SCRUB_RUNS = 5
DEFAULT_FALLBACK_RUNS = 3
DEFAULT_STEADY_WARMUP_S = 15.0
DEFAULT_STEADY_DURATION_S = 30.0
DEFAULT_FALLBACK_DURATION_S = 5.0
DEFAULT_DRAG_RATE_HZ = 120.0
DEFAULT_DRAG_LEG_DURATION_S = 4.0
MIN_SCRUB_REQUESTS_PER_LEG = 120
MIN_VISIBLE_SOURCE_FRACTION = 0.80
MAX_PREVIEW_PROOF_FPS = 30.0
RUSAGE_INFO_V4 = 4
ROLE_APP = "app"
ROLE_DECODER_HELPER = "decoder_helper"
EXPECTED_WAM_BUNDLE_ID = "com.wesleymaa.wam"
ALLOWED_PROCESS_ROLES = {ROLE_APP, ROLE_DECODER_HELPER}
REQUIRED_VARIANTS = (
    ("h264", "mp4", "any"),
    ("h264", "mov", "any"),
    ("h264", "mkv", "any"),
    ("hevc", "mp4", "main"),
    ("hevc", "mov", "main"),
    ("hevc", "mkv", "main"),
    ("hevc", "mp4", "main10"),
    ("hevc", "mov", "main10"),
    ("hevc", "mkv", "main10"),
)
REQUIRED_REPLICATES = {
    "startup": DEFAULT_STARTUP_RUNS,
    "steady": DEFAULT_STEADY_RUNS,
    "scrub": DEFAULT_SCRUB_RUNS,
}
FALLBACK_VARIANT = ("vp9", "webm", "fallback")
FALLBACK_PHASE = "fallback_control"


class ShipperError(RuntimeError):
    """A sampling, parsing, or report-contract failure."""


@dataclasses.dataclass(frozen=True)
class RUsageSnapshot:
    """The stable fields used from macOS ``rusage_info_v4``."""

    user_time_ns: int
    system_time_ns: int
    resident_size_bytes: int
    phys_footprint_bytes: int
    lifetime_max_phys_footprint_bytes: int
    interval_max_phys_footprint_bytes: int
    process_start_abstime: int

    @property
    def cpu_time_ns(self) -> int:
        return self.user_time_ns + self.system_time_ns

    def as_dict(self) -> dict[str, int]:
        value = dataclasses.asdict(self)
        value["cpu_time_ns"] = self.cpu_time_ns
        return value


class _RUsageInfoV4(ctypes.Structure):
    # Keep this in the exact order published in <sys/resource.h>.  Fields that
    # are not reported are still represented so later offsets remain correct.
    _fields_ = [
        ("ri_uuid", ctypes.c_uint8 * 16),
        ("ri_user_time", ctypes.c_uint64),
        ("ri_system_time", ctypes.c_uint64),
        ("ri_pkg_idle_wkups", ctypes.c_uint64),
        ("ri_interrupt_wkups", ctypes.c_uint64),
        ("ri_pageins", ctypes.c_uint64),
        ("ri_wired_size", ctypes.c_uint64),
        ("ri_resident_size", ctypes.c_uint64),
        ("ri_phys_footprint", ctypes.c_uint64),
        ("ri_proc_start_abstime", ctypes.c_uint64),
        ("ri_proc_exit_abstime", ctypes.c_uint64),
        ("ri_child_user_time", ctypes.c_uint64),
        ("ri_child_system_time", ctypes.c_uint64),
        ("ri_child_pkg_idle_wkups", ctypes.c_uint64),
        ("ri_child_interrupt_wkups", ctypes.c_uint64),
        ("ri_child_pageins", ctypes.c_uint64),
        ("ri_child_elapsed_abstime", ctypes.c_uint64),
        ("ri_diskio_bytesread", ctypes.c_uint64),
        ("ri_diskio_byteswritten", ctypes.c_uint64),
        ("ri_cpu_time_qos_default", ctypes.c_uint64),
        ("ri_cpu_time_qos_maintenance", ctypes.c_uint64),
        ("ri_cpu_time_qos_background", ctypes.c_uint64),
        ("ri_cpu_time_qos_utility", ctypes.c_uint64),
        ("ri_cpu_time_qos_legacy", ctypes.c_uint64),
        ("ri_cpu_time_qos_user_initiated", ctypes.c_uint64),
        ("ri_cpu_time_qos_user_interactive", ctypes.c_uint64),
        ("ri_billed_system_time", ctypes.c_uint64),
        ("ri_serviced_system_time", ctypes.c_uint64),
        ("ri_logical_writes", ctypes.c_uint64),
        ("ri_lifetime_max_phys_footprint", ctypes.c_uint64),
        ("ri_instructions", ctypes.c_uint64),
        ("ri_cycles", ctypes.c_uint64),
        ("ri_billed_energy", ctypes.c_uint64),
        ("ri_serviced_energy", ctypes.c_uint64),
        ("ri_interval_max_phys_footprint", ctypes.c_uint64),
        ("ri_runnable_time", ctypes.c_uint64),
    ]


class ProcPidRUsageReader:
    """Read one process without invoking ``ps`` or ``top``."""

    def __init__(self, function: Any | None = None) -> None:
        if function is None:
            if sys.platform != "darwin":
                raise ShipperError("proc_pid_rusage sampling is available only on macOS")
            try:
                libproc = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
                function = libproc.proc_pid_rusage
            except (OSError, AttributeError) as error:
                raise ShipperError(f"could not load proc_pid_rusage: {error}") from error
        function.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_void_p]
        function.restype = ctypes.c_int
        self._function = function

    def __call__(self, pid: int) -> RUsageSnapshot:
        if isinstance(pid, bool) or pid <= 0:
            raise ValueError("pid must be a positive integer")
        info = _RUsageInfoV4()
        ctypes.set_errno(0)
        result = self._function(pid, RUSAGE_INFO_V4, ctypes.byref(info))
        if result != 0:
            error_number = ctypes.get_errno() or errno.ESRCH
            raise OSError(error_number, os.strerror(error_number), pid)
        return RUsageSnapshot(
            user_time_ns=int(info.ri_user_time),
            system_time_ns=int(info.ri_system_time),
            resident_size_bytes=int(info.ri_resident_size),
            phys_footprint_bytes=int(info.ri_phys_footprint),
            lifetime_max_phys_footprint_bytes=int(
                info.ri_lifetime_max_phys_footprint
            ),
            interval_max_phys_footprint_bytes=int(
                info.ri_interval_max_phys_footprint
            ),
            process_start_abstime=int(info.ri_proc_start_abstime),
        )


def utc_now() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat()


def _finite_positive(value: str) -> float:
    parsed = float(value)
    if not math.isfinite(parsed) or parsed <= 0:
        raise argparse.ArgumentTypeError("must be finite and greater than zero")
    return parsed


def _process_spec(value: str) -> tuple[int, str, int]:
    """Parse PID:ROLE:COALITION without doing process discovery or mutation."""

    fields = value.split(":")
    if len(fields) != 3:
        raise argparse.ArgumentTypeError(
            "must look like PID:ROLE:COALITION_ID"
        )
    try:
        pid = int(fields[0])
        coalition_id = int(fields[2])
    except ValueError as error:
        raise argparse.ArgumentTypeError(
            "PID and COALITION_ID must be positive integers"
        ) from error
    role = fields[1]
    if pid <= 0 or coalition_id <= 0 or role not in ALLOWED_PROCESS_ROLES:
        raise argparse.ArgumentTypeError(
            "role must be app or decoder_helper and IDs must be positive"
        )
    return pid, role, coalition_id


def validate_process_provenance(
    pids: Sequence[int],
    process_provenance: Mapping[int, Mapping[str, Any]] | None,
) -> dict[str, Any]:
    errors: list[str] = []
    records: list[dict[str, Any]] = []
    if process_provenance is None:
        errors.append("process role and resource-coalition provenance is missing")
    else:
        if set(process_provenance) != set(pids):
            errors.append("process provenance does not cover the exact sampled PID set")
        for pid in sorted(set(pids) & set(process_provenance)):
            value = process_provenance[pid]
            role = value.get("role")
            coalition_id = value.get("coalition_id")
            if role not in ALLOWED_PROCESS_ROLES:
                errors.append(f"PID {pid} has unsupported role {role!r}")
            if (
                isinstance(coalition_id, bool)
                or not isinstance(coalition_id, int)
                or coalition_id <= 0
            ):
                errors.append(f"PID {pid} has no positive resource coalition ID")
            identity = value.get("identity")
            resource_coalition = value.get("resource_coalition")
            if (
                not isinstance(identity, Mapping)
                or identity.get("pid") != pid
                or not isinstance(identity.get("executable"), str)
                or not os.path.isabs(identity.get("executable", ""))
            ):
                errors.append(f"PID {pid} has no exact executable identity")
            if (
                not isinstance(resource_coalition, Mapping)
                or resource_coalition.get("coalition_id") != coalition_id
            ):
                errors.append(f"PID {pid} has no matching resource-coalition record")
            if role == ROLE_DECODER_HELPER and (
                not isinstance(identity, Mapping)
                or os.path.basename(str(identity.get("executable", "")))
                != run_suite.HELPER_BASENAME
            ):
                errors.append(f"PID {pid} is not an exact VT decoder helper")
            records.append(
                {
                    "pid": pid,
                    "role": role,
                    "coalition_id": coalition_id,
                    "expected_wam_executable": value.get("expected_wam_executable"),
                    "expected_wam_bundle_id": value.get("expected_wam_bundle_id"),
                    "expected_run_id": value.get("expected_run_id"),
                    "expected_process_start_abstime": value.get(
                        "expected_process_start_abstime"
                    ),
                }
            )
    app_records = [value for value in records if value["role"] == ROLE_APP]
    if len(app_records) != 1:
        errors.append("exactly one sampled PID must be designated as the app")
    else:
        app_record = app_records[0]
        app_source = (
            process_provenance.get(app_record["pid"], {})
            if isinstance(process_provenance, Mapping)
            else {}
        )
        app_identity = app_source.get("identity", {})
        app_resource_coalition = app_source.get("resource_coalition", {})
        if (
            not isinstance(app_record["expected_wam_executable"], str)
            or not os.path.isabs(app_record["expected_wam_executable"])
        ):
            errors.append("app provenance has no canonical expected WAM executable")
        elif (
            not isinstance(app_identity, Mapping)
            or not run_suite.same_executable(
                app_identity.get("executable", ""),
                app_record["expected_wam_executable"],
            )
        ):
            errors.append("app provenance executable does not match exact WAM path")
        if app_record["expected_wam_bundle_id"] != EXPECTED_WAM_BUNDLE_ID:
            errors.append("app provenance has no exact WAM bundle identity")
        elif (
            not isinstance(app_resource_coalition, Mapping)
            or app_resource_coalition.get("bundle_id")
            != EXPECTED_WAM_BUNDLE_ID
        ):
            errors.append("app resource coalition has no exact WAM bundle identity")
        try:
            canonical_run_id = str(uuid.UUID(app_record["expected_run_id"]))
        except (ValueError, TypeError, AttributeError):
            canonical_run_id = None
        if canonical_run_id != app_record["expected_run_id"]:
            errors.append("app provenance has no canonical telemetry run ID")
        expected_start = app_record["expected_process_start_abstime"]
        if (
            isinstance(expected_start, bool)
            or not isinstance(expected_start, int)
            or expected_start <= 0
        ):
            errors.append("app provenance has no positive process start abstime")
    coalition_ids = {
        value["coalition_id"]
        for value in records
        if isinstance(value["coalition_id"], int)
        and not isinstance(value["coalition_id"], bool)
        and value["coalition_id"] > 0
    }
    if len(coalition_ids) != 1:
        errors.append("every sampled process must share the app resource coalition")
    elif any(
        not isinstance(value, Mapping)
        or not isinstance(value.get("resource_coalition"), Mapping)
        or value["resource_coalition"].get("active_count") != len(pids)
        for value in (process_provenance or {}).values()
    ):
        errors.append(
            "kernel resource-coalition active count does not equal the sampled process set"
        )
    return {
        "eligible": not errors,
        "errors": errors,
        "processes": records,
        "helper_count": sum(
            value["role"] == ROLE_DECODER_HELPER for value in records
        ),
        "coalition_id": next(iter(coalition_ids)) if len(coalition_ids) == 1 else None,
        "exact_app_and_all_attributed_helpers_covered": not errors,
    }


def capture_process_provenance(
    specs: Sequence[tuple[int, str, int]],
    expected_wam_executable: Path,
    *,
    expected_run_id: str,
    expected_process_start_abstime: int,
) -> tuple[list[int], dict[int, dict[str, Any]]]:
    """Discover and bind the complete current WAM decoder process set."""

    pids = [pid for pid, _, _ in specs]
    if len(set(pids)) != len(pids):
        raise ShipperError("process specifications contain a duplicate PID")
    table = run_suite.process_table()
    app_specs = [spec for spec in specs if spec[1] == ROLE_APP]
    if len(app_specs) != 1:
        raise ShipperError("exactly one process specification must designate the WAM app")
    app_pid, _, expected_coalition_id = app_specs[0]
    app_identity = table.get(app_pid)
    if app_identity is None or not run_suite.same_executable(
        app_identity.executable, expected_wam_executable
    ):
        raise ShipperError(
            "app PID does not resolve to the expected canonical WAM bundle executable"
        )
    try:
        normalized_run_id = str(uuid.UUID(expected_run_id))
    except ValueError as error:
        raise ShipperError("expected telemetry run ID must be a canonical UUID") from error
    if normalized_run_id != expected_run_id.lower():
        raise ShipperError("expected telemetry run ID must be a canonical UUID")
    if expected_process_start_abstime <= 0:
        raise ShipperError("expected WAM process start abstime must be positive")

    app_coalition = run_suite.process_resource_coalition(app_pid)
    if app_coalition.coalition_id != expected_coalition_id:
        raise ShipperError(
            f"WAM coalition changed: expected {expected_coalition_id}, "
            f"observed {app_coalition.coalition_id}"
        )
    if app_coalition.bundle_id != EXPECTED_WAM_BUNDLE_ID:
        raise ShipperError(
            f"WAM resource coalition bundle ID is {app_coalition.bundle_id!r}, "
            f"expected {EXPECTED_WAM_BUNDLE_ID!r}"
        )

    discovered_helper_pids: set[int] = set()
    for helper_pid, helper_identity in run_suite.helper_processes(table).items():
        helper_coalition = run_suite.process_resource_coalition(helper_pid)
        if helper_coalition.coalition_id == app_coalition.coalition_id:
            discovered_helper_pids.add(helper_pid)
    supplied_helper_pids = {
        pid for pid, role, _ in specs if role == ROLE_DECODER_HELPER
    }
    if supplied_helper_pids != discovered_helper_pids:
        missing = sorted(discovered_helper_pids - supplied_helper_pids)
        extra = sorted(supplied_helper_pids - discovered_helper_pids)
        raise ShipperError(
            "sampled helper set does not equal trusted same-coalition discovery "
            f"(missing={missing}, extra={extra})"
        )
    if app_coalition.active_count != 1 + len(discovered_helper_pids):
        raise ShipperError(
            "resource coalition contains an unenumerated live member: "
            f"kernel active_count={app_coalition.active_count}, "
            f"enumerated={1 + len(discovered_helper_pids)}"
        )
    provenance: dict[int, dict[str, Any]] = {}
    for pid, role, expected_coalition_id in specs:
        identity = table.get(pid)
        if identity is None:
            raise ShipperError(f"PID {pid} is not currently alive")
        executable_basename = os.path.basename(identity.executable)
        if role == ROLE_DECODER_HELPER and executable_basename != run_suite.HELPER_BASENAME:
            raise ShipperError(
                f"PID {pid} is not {run_suite.HELPER_BASENAME}; cannot attribute it as a helper"
            )
        coalition = run_suite.process_resource_coalition(pid)
        if coalition.coalition_id != expected_coalition_id:
            raise ShipperError(
                f"PID {pid} coalition changed: expected {expected_coalition_id}, "
                f"observed {coalition.coalition_id}"
            )
        provenance[pid] = {
            "role": role,
            "coalition_id": coalition.coalition_id,
            "identity": identity.as_dict(),
            "resource_coalition": coalition.as_dict(),
            "verified_at": utc_now(),
            "expected_wam_executable": str(expected_wam_executable.resolve()),
            "expected_wam_bundle_id": EXPECTED_WAM_BUNDLE_ID,
            "expected_run_id": normalized_run_id,
            "expected_process_start_abstime": expected_process_start_abstime,
        }
    validated = validate_process_provenance(pids, provenance)
    if not validated["eligible"]:
        raise ShipperError("; ".join(validated["errors"]))
    return pids, provenance


def capture_coalition_membership(
    pids: Sequence[int],
    process_provenance: Mapping[int, Mapping[str, Any]],
) -> dict[str, Any]:
    """Enumerate WAM plus every live same-coalition VT decoder helper."""

    app_records = [
        (pid, value)
        for pid, value in process_provenance.items()
        if value.get("role") == ROLE_APP
    ]
    if len(app_records) != 1:
        raise ShipperError("coalition enumeration requires one exact WAM app record")
    app_pid, app_record = app_records[0]
    expected_executable = Path(str(app_record.get("expected_wam_executable", "")))
    expected_coalition_id = app_record.get("coalition_id")
    table = run_suite.process_table()
    app_identity = table.get(app_pid)
    if app_identity is None or not run_suite.same_executable(
        app_identity.executable, expected_executable
    ):
        raise ShipperError("exact WAM process identity disappeared during sampling")
    app_coalition = run_suite.process_resource_coalition(app_pid)
    if (
        app_coalition.coalition_id != expected_coalition_id
        or app_coalition.bundle_id != EXPECTED_WAM_BUNDLE_ID
    ):
        raise ShipperError("WAM resource coalition identity changed during sampling")

    helpers: list[dict[str, Any]] = []
    for helper_pid, helper_identity in run_suite.helper_processes(table).items():
        coalition = run_suite.process_resource_coalition(helper_pid)
        if coalition.coalition_id != expected_coalition_id:
            continue
        helpers.append(
            {
                "pid": helper_pid,
                "role": ROLE_DECODER_HELPER,
                "identity": helper_identity.as_dict(),
                "resource_coalition": coalition.as_dict(),
            }
        )
    observed_pids = {app_pid, *(helper["pid"] for helper in helpers)}
    return {
        "available": True,
        "observed_pids": sorted(observed_pids),
        "expected_pids": sorted(pids),
        "complete": (
            observed_pids == set(pids)
            and app_coalition.active_count == len(observed_pids)
        ),
        "kernel_active_count": app_coalition.active_count,
        "app": {
            "pid": app_pid,
            "role": ROLE_APP,
            "identity": app_identity.as_dict(),
            "resource_coalition": app_coalition.as_dict(),
        },
        "helpers": sorted(helpers, key=lambda value: value["pid"]),
    }


def percentile(values: Sequence[float], quantile: float) -> float | None:
    """Linear-interpolated percentile, matching the existing macOS collector."""

    if not values:
        return None
    if not 0.0 <= quantile <= 1.0:
        raise ValueError("quantile must be between zero and one")
    ordered = sorted(float(value) for value in values)
    if len(ordered) == 1:
        return ordered[0]
    position = (len(ordered) - 1) * quantile
    lower = math.floor(position)
    upper = math.ceil(position)
    if lower == upper:
        return ordered[lower]
    fraction = position - lower
    return ordered[lower] + ((ordered[upper] - ordered[lower]) * fraction)


def distribution(values: Iterable[float | int | None]) -> dict[str, float | int | None]:
    valid = [
        float(value)
        for value in values
        if value is not None and math.isfinite(float(value))
    ]
    if not valid:
        return {
            "count": 0,
            "mean": None,
            "p50": None,
            "p95": None,
            "max": None,
        }
    return {
        "count": len(valid),
        "mean": statistics.fmean(valid),
        "p50": percentile(valid, 0.50),
        "p95": percentile(valid, 0.95),
        "max": max(valid),
    }


def _validate_snapshot(snapshot: RUsageSnapshot) -> None:
    for field, value in dataclasses.asdict(snapshot).items():
        if isinstance(value, bool) or not isinstance(value, int) or value < 0:
            raise ValueError(f"{field} must be a nonnegative integer")


def _aggregate_snapshot(
    process_values: Mapping[str, Mapping[str, Any]], expected_count: int
) -> dict[str, Any]:
    available = [
        value for value in process_values.values() if value.get("available") is True
    ]
    complete = len(available) == expected_count

    def complete_sum(field: str) -> int | None:
        return sum(int(value[field]) for value in available) if complete else None

    return {
        "complete": complete,
        "available_process_count": len(available),
        "expected_process_count": expected_count,
        "resident_size_bytes": complete_sum("resident_size_bytes"),
        "phys_footprint_bytes": complete_sum("phys_footprint_bytes"),
        # This is deliberately named as a conservative sum.  Each process's
        # lifetime maximum can have happened at a different instant.
        "conservative_sum_lifetime_max_phys_footprint_bytes": complete_sum(
            "lifetime_max_phys_footprint_bytes"
        ),
        "conservative_sum_interval_max_phys_footprint_bytes": complete_sum(
            "interval_max_phys_footprint_bytes"
        ),
        "cpu_time_ns": complete_sum("cpu_time_ns"),
    }


def _summarize_process_samples(
    samples: Sequence[Mapping[str, Any]],
    pids: Sequence[int],
    interval_s: float,
    cpu_limit_percent: float,
    memory_limit_bytes: int,
) -> dict[str, Any]:
    cpu_values: list[float] = []
    cpu_delta_total = 0
    cpu_wall_total = 0
    identity_changes: list[dict[str, Any]] = []

    for previous, current in zip(samples, samples[1:]):
        previous_processes = previous["processes"]
        current_processes = current["processes"]
        interval_ns = int(current["monotonic_ns"]) - int(previous["monotonic_ns"])
        interval_cpu_ns = 0
        valid_interval = interval_ns > 0
        for pid in pids:
            key = str(pid)
            left = previous_processes.get(key, {})
            right = current_processes.get(key, {})
            if left.get("available") is not True or right.get("available") is not True:
                valid_interval = False
                continue
            if left["process_start_abstime"] != right["process_start_abstime"]:
                identity_changes.append(
                    {
                        "pid": pid,
                        "sample": current["sample"],
                        "before": left["process_start_abstime"],
                        "after": right["process_start_abstime"],
                    }
                )
                valid_interval = False
                continue
            delta = int(right["cpu_time_ns"]) - int(left["cpu_time_ns"])
            if delta < 0:
                valid_interval = False
                continue
            interval_cpu_ns += delta
        current["aggregate"]["cpu_interval_ns"] = interval_ns
        current["aggregate"]["cpu_time_delta_ns"] = (
            interval_cpu_ns if valid_interval else None
        )
        current["aggregate"]["cpu_percent"] = (
            (interval_cpu_ns / interval_ns) * 100.0 if valid_interval else None
        )
        if valid_interval:
            cpu_values.append((interval_cpu_ns / interval_ns) * 100.0)
            cpu_delta_total += interval_cpu_ns
            cpu_wall_total += interval_ns

    complete_samples = [
        sample for sample in samples if sample["aggregate"].get("complete") is True
    ]
    resident = [sample["aggregate"]["resident_size_bytes"] for sample in complete_samples]
    footprint = [
        sample["aggregate"]["phys_footprint_bytes"] for sample in complete_samples
    ]
    conservative_lifetime = [
        sample["aggregate"][
            "conservative_sum_lifetime_max_phys_footprint_bytes"
        ]
        for sample in complete_samples
    ]
    synchronized_resident_peak = max(resident, default=None)
    synchronized_peak = max(footprint, default=None)
    conservative_peak = max(conservative_lifetime, default=None)
    hard_gate_peak = (
        max(synchronized_resident_peak, synchronized_peak, conservative_peak)
        if synchronized_resident_peak is not None
        and synchronized_peak is not None
        and conservative_peak is not None
        else None
    )
    cpu_summary = distribution(cpu_values)
    time_weighted_cpu = (
        (cpu_delta_total / cpu_wall_total) * 100.0 if cpu_wall_total > 0 else None
    )
    cpu_summary["time_weighted_mean"] = time_weighted_cpu
    cpu_summary["covered_elapsed_s"] = cpu_wall_total / 1_000_000_000.0
    observed_gaps = [
        (int(right["monotonic_ns"]) - int(left["monotonic_ns"])) / 1_000_000_000.0
        for left, right in zip(samples, samples[1:])
    ]
    overhead = distribution(
        int(sample["query_duration_ns"]) / 1_000_000.0 for sample in samples
    )
    observed_elapsed_s = sum(observed_gaps)
    observed_rate_hz = (
        (len(samples) - 1) / observed_elapsed_s
        if len(samples) > 1 and observed_elapsed_s > 0.0
        else None
    )
    schedule_lateness_ms = [
        max(0.0, float(sample["offset_s"]) - float(sample["scheduled_offset_s"]))
        * 1000.0
        for sample in samples
    ]
    maximum_allowed_gap_s = max(interval_s * 2.0, interval_s + 0.010)
    maximum_allowed_lateness_ms = max(interval_s * 1000.0, 10.0)
    timing_valid = (
        bool(observed_gaps)
        and max(observed_gaps) <= maximum_allowed_gap_s
        and max(schedule_lateness_ms, default=0.0) <= maximum_allowed_lateness_ms
    )
    complete = (
        len(samples) >= 2
        and len(complete_samples) == len(samples)
        and not identity_changes
        and cpu_summary["count"] == len(samples) - 1
        and time_weighted_cpu is not None
        and timing_valid
    )
    return {
        "sampling": {
            "requested_interval_s": interval_s,
            "requested_rate_hz": 1.0 / interval_s,
            "effective_rate_hz": observed_rate_hz,
            "sample_count": len(samples),
            "complete_sample_count": len(complete_samples),
            "observed_elapsed_s": observed_elapsed_s,
            "maximum_observed_gap_s": max(observed_gaps, default=None),
            "gap_distribution_s": distribution(observed_gaps),
            "schedule_lateness_ms": distribution(schedule_lateness_ms),
            "maximum_allowed_gap_s": maximum_allowed_gap_s,
            "maximum_allowed_lateness_ms": maximum_allowed_lateness_ms,
            "timing_valid": timing_valid,
            "query_overhead_ms": overhead,
            "sampler_runs_outside_target_processes": True,
        },
        "identity": {
            "stable": not identity_changes,
            "changes": identity_changes,
        },
        "cpu_percent": cpu_summary,
        "memory": {
            "resident_size_bytes": distribution(resident),
            "resident_plateau_p50_bytes": percentile(resident, 0.50),
            "resident_plateau_p95_bytes": percentile(resident, 0.95),
            "phys_footprint_bytes": distribution(footprint),
            "conservative_sum_lifetime_max_phys_footprint_bytes": distribution(
                conservative_lifetime
            ),
            "synchronized_peak_resident_size_bytes": synchronized_resident_peak,
            "synchronized_peak_phys_footprint_bytes": synchronized_peak,
            "conservative_peak_phys_footprint_bytes": conservative_peak,
            "hard_gate_peak_bytes": hard_gate_peak,
            "hard_gate_method": (
                "maximum of synchronized aggregate RSS, synchronized aggregate "
                "current footprint, and the conservative sum of per-process "
                "lifetime footprint maxima"
            ),
        },
        "gates": {
            "cpu_limit_percent": cpu_limit_percent,
            "cpu_under_limit": (
                time_weighted_cpu < cpu_limit_percent
                if time_weighted_cpu is not None
                else False
            ),
            "memory_limit_bytes": memory_limit_bytes,
            "memory_under_limit": (
                hard_gate_peak < memory_limit_bytes
                if hard_gate_peak is not None
                else False
            ),
        },
        "eligible": complete,
    }


def sample_processes(
    pids: Sequence[int],
    *,
    duration_s: float,
    interval_s: float = DEFAULT_SAMPLE_INTERVAL_S,
    phase: str = "steady",
    reader: Callable[[int], RUsageSnapshot] | None = None,
    clock_ns: Callable[[], int] = time.monotonic_ns,
    sleeper: Callable[[float], None] = time.sleep,
    cpu_limit_percent: float = DEFAULT_CPU_LIMIT_PERCENT,
    memory_limit_bytes: int = DEFAULT_MEMORY_LIMIT_BYTES,
    process_provenance: Mapping[int, Mapping[str, Any]] | None = None,
    coalition_membership_reader: Callable[[], Mapping[str, Any]] | None = None,
) -> dict[str, Any]:
    """Collect synchronized snapshots for an existing process set.

    No process is launched, signalled, foregrounded, or otherwise controlled.
    """

    unique_pids = sorted(set(pids))
    if not unique_pids or len(unique_pids) != len(pids):
        raise ValueError("pids must be a non-empty sequence of unique values")
    if any(isinstance(pid, bool) or not isinstance(pid, int) or pid <= 0 for pid in pids):
        raise ValueError("each pid must be a positive integer")
    if not math.isfinite(duration_s) or duration_s <= 0:
        raise ValueError("duration_s must be finite and positive")
    if (
        not math.isfinite(interval_s)
        or not math.isclose(
            interval_s,
            DEFAULT_SAMPLE_INTERVAL_S,
            rel_tol=0.0,
            abs_tol=1e-12,
        )
    ):
        raise ValueError("shipping-proof sampling requires the fixed 0.05s interval")
    if not math.isfinite(cpu_limit_percent) or cpu_limit_percent <= 0:
        raise ValueError("cpu_limit_percent must be finite and positive")
    if (
        isinstance(memory_limit_bytes, bool)
        or not isinstance(memory_limit_bytes, int)
        or memory_limit_bytes <= 0
    ):
        raise ValueError("memory_limit_bytes must be a positive integer")
    if phase not in {"startup", "steady", "scrub", FALLBACK_PHASE}:
        raise ValueError("phase must be startup, steady, scrub, or fallback_control")
    if reader is None:
        reader = ProcPidRUsageReader()
    provenance = validate_process_provenance(unique_pids, process_provenance)
    if not provenance["eligible"]:
        raise ShipperError("; ".join(provenance["errors"]))
    if coalition_membership_reader is None and process_provenance is not None:
        coalition_membership_reader = lambda: capture_coalition_membership(
            unique_pids, process_provenance
        )

    origin_ns = clock_ns()
    interval_ns = max(1, round(interval_s * 1_000_000_000.0))
    duration_ns = max(1, round(duration_s * 1_000_000_000.0))
    scheduled_offsets_ns = list(range(0, duration_ns + 1, interval_ns))
    if scheduled_offsets_ns[-1] != duration_ns:
        scheduled_offsets_ns.append(duration_ns)
    samples: list[dict[str, Any]] = []
    coalition_history: list[dict[str, Any]] = []

    for index, scheduled_offset_ns in enumerate(scheduled_offsets_ns):
        scheduled_ns = origin_ns + scheduled_offset_ns
        remaining_ns = scheduled_ns - clock_ns()
        if remaining_ns > 0:
            sleeper(remaining_ns / 1_000_000_000.0)
        query_started_ns = clock_ns()
        if coalition_membership_reader is None:
            membership = {
                "available": False,
                "complete": False,
                "error": "trusted coalition enumeration is unavailable",
            }
        else:
            try:
                membership = dict(coalition_membership_reader())
            except (OSError, ValueError, run_suite.SuiteError, ShipperError) as error:
                membership = {
                    "available": False,
                    "complete": False,
                    "error": str(error),
                    "error_type": type(error).__name__,
                }
        membership["sample"] = index
        membership["scheduled_offset_s"] = (
            scheduled_ns - origin_ns
        ) / 1_000_000_000.0
        coalition_history.append(membership)
        processes: dict[str, dict[str, Any]] = {}
        for pid in unique_pids:
            try:
                snapshot = reader(pid)
                _validate_snapshot(snapshot)
                process_binding = (process_provenance or {}).get(pid, {})
                processes[str(pid)] = {
                    "available": True,
                    "role": process_binding.get("role"),
                    "coalition_id": process_binding.get("coalition_id"),
                    **snapshot.as_dict(),
                }
            except (OSError, ValueError) as error:
                processes[str(pid)] = {
                    "available": False,
                    "error": str(error),
                    "error_type": type(error).__name__,
                }
        query_finished_ns = clock_ns()
        observed_ns = (query_started_ns + query_finished_ns) // 2
        samples.append(
            {
                "sample": index,
                "scheduled_offset_s": (scheduled_ns - origin_ns) / 1_000_000_000.0,
                "scheduled_monotonic_ns": scheduled_ns,
                "offset_s": (observed_ns - origin_ns) / 1_000_000_000.0,
                "monotonic_ns": observed_ns,
                "query_started_monotonic_ns": query_started_ns,
                "query_finished_monotonic_ns": query_finished_ns,
                "query_duration_ns": query_finished_ns - query_started_ns,
                "coalition_id": provenance.get("coalition_id"),
                "coalition_active_count": membership.get("kernel_active_count"),
                "coalition_observed_pids": membership.get("observed_pids"),
                "processes": processes,
                "aggregate": _aggregate_snapshot(processes, len(unique_pids)),
            }
        )

    summary = _summarize_process_samples(
        samples,
        unique_pids,
        interval_s,
        cpu_limit_percent,
        memory_limit_bytes,
    )
    summary["provenance"] = provenance
    membership_complete = (
        len(coalition_history) == len(samples)
        and all(
            value.get("available") is True
            and value.get("complete") is True
            and value.get("observed_pids") == unique_pids
            for value in coalition_history
        )
    )
    app_record = next(
        (
            value
            for value in (process_provenance or {}).values()
            if value.get("role") == ROLE_APP
        ),
        None,
    )
    app_pid = next(
        (
            pid
            for pid, value in (process_provenance or {}).items()
            if value.get("role") == ROLE_APP
        ),
        None,
    )
    expected_start = (
        app_record.get("expected_process_start_abstime")
        if isinstance(app_record, Mapping)
        else None
    )
    sampled_start_matches = bool(samples) and app_pid is not None and all(
        sample["processes"].get(str(app_pid), {}).get("process_start_abstime")
        == expected_start
        for sample in samples
    )
    summary["provenance"]["coalition_enumeration_complete"] = membership_complete
    summary["provenance"]["sampled_process_start_matches_telemetry"] = (
        sampled_start_matches
    )
    summary["eligible"] = (
        summary["eligible"]
        and provenance["eligible"]
        and membership_complete
        and sampled_start_matches
    )
    return {
        "schema": SCHEMA,
        "kind": "process_samples",
        "created_at": utc_now(),
        "phase": phase,
        "pids": unique_pids,
        "process_provenance": {
            str(pid): dict(value)
            for pid, value in (process_provenance or {}).items()
        },
        "duration_s": duration_s,
        "interval_s": interval_s,
        "samples": samples,
        "phase_window": {
            "sample_started_monotonic_ns": samples[0]["monotonic_ns"],
            "sample_ended_monotonic_ns": samples[-1]["monotonic_ns"],
        },
        "coalition_membership": coalition_history,
        "summary": summary,
    }


@dataclasses.dataclass(frozen=True)
class DragStep:
    offset_ns: int
    action: str
    normalized_position: float
    direction: str
    gesture: int

    def as_dict(self) -> dict[str, Any]:
        return dataclasses.asdict(self)


def build_drag_plan(
    *,
    rate_hz: float = DEFAULT_DRAG_RATE_HZ,
    leg_duration_s: float = DEFAULT_DRAG_LEG_DURATION_S,
    edge_inset: float = 0.05,
    inter_gesture_gap_s: float = 0.25,
) -> list[DragStep]:
    """Build separate forward and reverse gestures on an integer-ns clock."""

    for label, value in {
        "rate_hz": rate_hz,
        "leg_duration_s": leg_duration_s,
        "inter_gesture_gap_s": inter_gesture_gap_s,
    }.items():
        if not math.isfinite(value) or value <= 0:
            raise ValueError(f"{label} must be finite and positive")
    if not math.isfinite(edge_inset) or not 0.0 <= edge_inset < 0.5:
        raise ValueError("edge_inset must be finite and in [0, 0.5)")

    move_intervals = max(1, round(rate_hz * leg_duration_s))
    period_ns = round(1_000_000_000.0 / rate_hz)
    gap_ns = round(inter_gesture_gap_s * 1_000_000_000.0)
    low = edge_inset
    high = 1.0 - edge_inset
    steps: list[DragStep] = []
    origin_ns = 0
    for gesture, direction in enumerate(("forward", "reverse"), start=1):
        start, finish = (low, high) if direction == "forward" else (high, low)
        steps.append(DragStep(origin_ns, "down", start, direction, gesture))
        for index in range(1, move_intervals + 1):
            progress = index / move_intervals
            position = start + ((finish - start) * progress)
            steps.append(
                DragStep(
                    origin_ns + (index * period_ns),
                    "move",
                    position,
                    direction,
                    gesture,
                )
            )
        release_ns = origin_ns + (move_intervals * period_ns)
        steps.append(DragStep(release_ns, "up", finish, direction, gesture))
        origin_ns = release_ns + gap_ns
    return steps


def drive_drag_plan(
    steps: Sequence[DragStep],
    sink: Callable[[DragStep], None],
    *,
    clock_ns: Callable[[], int] = time.monotonic_ns,
    sleeper: Callable[[float], None] = time.sleep,
) -> None:
    """Deliver an already-built plan to an injected sink at fixed deadlines.

    This module supplies no system input sink.  Calling this helper therefore
    cannot generate input unless an approved caller explicitly injects one.
    """

    if not steps:
        raise ValueError("steps must not be empty")
    if any(step.offset_ns < 0 for step in steps):
        raise ValueError("drag offsets must be nonnegative")
    if any(right.offset_ns < left.offset_ns for left, right in zip(steps, steps[1:])):
        raise ValueError("drag offsets must be nondecreasing")
    origin_ns = clock_ns()
    for step in steps:
        remaining_ns = (origin_ns + step.offset_ns) - clock_ns()
        if remaining_ns > 0:
            sleeper(remaining_ns / 1_000_000_000.0)
        sink(step)


def _events(parsed: Mapping[str, Any], name: str) -> list[Mapping[str, Any]]:
    return [
        event
        for event in parsed.get("events", ())
        if isinstance(event, Mapping) and event.get("event") == name
    ]


def _identity(event: Mapping[str, Any]) -> tuple[int, int]:
    return int(event.get("gesture", 0)), int(event.get("request", 0))


def _unique_events(
    events: Sequence[Mapping[str, Any]], label: str, errors: list[str]
) -> dict[tuple[int, int], Mapping[str, Any]]:
    result: dict[tuple[int, int], Mapping[str, Any]] = {}
    for event in events:
        identity = _identity(event)
        if identity[0] <= 0 or identity[1] <= 0:
            errors.append(f"{label} has a zero gesture/request identity")
            continue
        if identity in result:
            errors.append(f"duplicate {label} for gesture/request {identity}")
            continue
        result[identity] = event
    return result


def _distribution_within(
    values: Sequence[float], p95_limit: float, maximum_limit: float
) -> bool:
    measured = distribution(values)
    return (
        measured["count"] > 0
        and float(measured["p95"]) <= p95_limit
        and float(measured["max"]) <= maximum_limit
    )


def summarize_scrub_telemetry(
    parsed: Mapping[str, Any],
    gesture_windows: Mapping[int, Mapping[str, int]] | None = None,
    source_fps: float | None = None,
) -> dict[str, Any]:
    """Join public demand to exact native dispatch/admission/visible terminals.

    A coalesced public demand is normal, but it still needs convergence: the
    earliest later request draw (or the gesture's exact commit draw) must make
    that demand visibly obsolete. Cadence includes both gesture boundaries so
    an early burst followed by a frozen four-second leg cannot pass.
    """

    errors: list[str] = []
    if parsed.get("parse_errors"):
        errors.append("native telemetry contains invalid schema-matching events")
    raw_events = [
        event for event in parsed.get("events", ()) if isinstance(event, Mapping)
    ]
    demanded = _unique_events(_events(parsed, "preview_demanded"), "demand", errors)
    dispatched = _unique_events(_events(parsed, "preview_dispatched"), "dispatch", errors)
    admitted = _unique_events(_events(parsed, "preview_admitted"), "admission", errors)
    drawn = _unique_events(_events(parsed, "preview_frame_drawn"), "draw", errors)
    failed = _unique_events(_events(parsed, "preview_failed"), "failure", errors)
    commit_submitted = _unique_events(
        _events(parsed, "commit_seek_submitted"), "commit", errors
    )
    commit_ready = _unique_events(_events(parsed, "commit_ready"), "commit ready", errors)
    commit_drawn = _unique_events(
        _events(parsed, "commit_frame_drawn"), "commit draw", errors
    )

    scrub_names = {
        "preview_demanded", "preview_dispatched", "preview_admitted",
        "preview_frame_drawn", "preview_failed", "commit_seek_submitted",
        "commit_ready", "commit_frame_drawn",
    }
    ordered_times = [
        int(event.get("monotonic_ns", 0))
        for event in raw_events
        if event.get("event") in scrub_names
    ]
    if any(right < left for left, right in zip(ordered_times, ordered_times[1:])):
        errors.append("scrub telemetry is not in monotonic timestamp order")

    event_ordinals = {id(event): index for index, event in enumerate(raw_events)}
    gesture_order: list[int] = []
    demands_by_gesture: dict[int, list[tuple[tuple[int, int], Mapping[str, Any]]]] = {}
    for event in _events(parsed, "preview_demanded"):
        identity = _identity(event)
        gesture = identity[0]
        if gesture > 0 and gesture not in gesture_order:
            gesture_order.append(gesture)
        demands_by_gesture.setdefault(gesture, []).append((identity, event))
    for values in demands_by_gesture.values():
        values.sort(
            key=lambda value: (
                int(value[1].get("monotonic_ns", 0)),
                event_ordinals.get(id(value[1]), 0),
            )
        )

    for identity, demand in demanded.items():
        if demand.get("route") != "native" or demand.get("libmpv_initialized"):
            errors.append(f"preview demand {identity} violated native route proof")
        if demand.get("target_seconds") is None:
            errors.append(f"preview demand {identity} is missing target time")
    for identity, dispatch in dispatched.items():
        demand = demanded.get(identity)
        if demand is None:
            errors.append(f"preview dispatch {identity} has no matching public demand")
            continue
        if (
            demand.get("target_seconds") is None
            or dispatch.get("target_seconds") is None
            or not math.isclose(
                float(demand["target_seconds"]), float(dispatch["target_seconds"]),
                rel_tol=0.0, abs_tol=1e-9,
            )
        ):
            errors.append(f"preview dispatch changed target for {identity}")
        if int(dispatch.get("monotonic_ns", 0)) < int(demand.get("monotonic_ns", 0)):
            errors.append(f"preview dispatch predates demand for {identity}")
        if dispatch.get("route") != "native" or dispatch.get("libmpv_initialized"):
            errors.append(f"preview dispatch {identity} violated native route proof")
    for identity in sorted(set(admitted) - set(dispatched)):
        errors.append(f"preview admission {identity} has no matching dispatch")

    request_to_admit_ms: list[float] = []
    request_to_draw_ms: list[float] = []
    admit_to_draw_ms: list[float] = []
    target_error_ms: list[float] = []
    request_to_failure_ms: list[float] = []
    commit_to_draw_ms: list[float] = []
    commit_target_error_ms: list[float] = []
    draw_measurements: list[dict[str, Any]] = []

    for identity, draw in sorted(
        drawn.items(), key=lambda item: int(item[1].get("monotonic_ns", 0))
    ):
        demand = demanded.get(identity)
        dispatch = dispatched.get(identity)
        admission = admitted.get(identity)
        if demand is None or dispatch is None or admission is None:
            errors.append(
                f"draw {identity} has no matching demand, dispatch, and admission"
            )
            continue
        times = [
            int(demand["monotonic_ns"]), int(dispatch["monotonic_ns"]),
            int(admission["monotonic_ns"]), int(draw["monotonic_ns"]),
        ]
        if times != sorted(times):
            errors.append(f"preview timestamps are out of order for {identity}")
            continue
        if any(
            event.get("route") != "native" or event.get("libmpv_initialized")
            for event in (demand, dispatch, admission, draw)
        ):
            errors.append(f"preview {identity} violated native route proof")
        targets = [event.get("target_seconds") for event in (demand, dispatch, admission, draw)]
        if any(value is None for value in targets):
            errors.append(f"preview {identity} is missing target time")
            continue
        if not math.isclose(float(targets[1]), float(targets[2]), rel_tol=0.0, abs_tol=1e-9):
            errors.append(f"preview admission changed target for {identity}")
        for field in ("attempt", "serial", "generation"):
            if int(admission.get(field, 0)) <= 0 or admission.get(field) != draw.get(field):
                errors.append(f"preview {identity} changed exact {field} identity")
        demand_to_admit = (times[2] - times[0]) / 1_000_000.0
        demand_to_draw = (times[3] - times[0]) / 1_000_000.0
        pipeline = (times[3] - times[2]) / 1_000_000.0
        target_error = abs(float(targets[3]) - float(targets[0])) * 1000.0
        request_to_admit_ms.append(demand_to_admit)
        request_to_draw_ms.append(demand_to_draw)
        admit_to_draw_ms.append(pipeline)
        target_error_ms.append(target_error)
        draw_measurements.append({
            "gesture": identity[0], "request": identity[1],
            "request_to_admit_ms": demand_to_admit,
            "request_to_draw_ms": demand_to_draw,
            "admit_to_draw_ms": pipeline,
            "target_error_ms": target_error,
            "draw_monotonic_ns": times[3],
        })

    for identity, failure in failed.items():
        demand = demanded.get(identity)
        dispatch = dispatched.get(identity)
        admission = admitted.get(identity)
        if demand is None or dispatch is None or admission is None:
            errors.append(
                f"preview failure {identity} has no matching demand, dispatch, and admission"
            )
            continue
        times = [
            int(demand["monotonic_ns"]), int(dispatch["monotonic_ns"]),
            int(admission["monotonic_ns"]), int(failure["monotonic_ns"]),
        ]
        if times != sorted(times):
            errors.append(f"preview failure timestamps are out of order for {identity}")
        for field in ("attempt", "serial", "generation"):
            if int(admission.get(field, 0)) <= 0 or admission.get(field) != failure.get(field):
                errors.append(f"preview failure {identity} changed exact {field} identity")
        if failure.get("route") != "native" or failure.get("libmpv_initialized"):
            errors.append(f"preview failure {identity} violated native route proof")
        if any(event.get("target_seconds") is None for event in (demand, dispatch, admission, failure)):
            errors.append(f"preview failure {identity} is missing target")
        elif not (
            math.isclose(float(dispatch["target_seconds"]), float(admission["target_seconds"]), rel_tol=0.0, abs_tol=1e-9)
            and math.isclose(float(demand["target_seconds"]), float(failure["target_seconds"]), rel_tol=0.0, abs_tol=1e-9)
        ):
            errors.append(f"preview failure {identity} changed requested target")
        request_to_failure_ms.append((times[3] - times[0]) / 1_000_000.0)
        errors.append(f"preview failure observed for gesture/request {identity}")
    for identity in sorted(set(drawn) & set(failed)):
        errors.append(f"preview {identity} has both draw and failure terminals")

    for identity in sorted(set(commit_submitted) - set(commit_ready)):
        errors.append(f"commit submission {identity} has no matching ready proof")
    for identity in sorted(set(commit_submitted) - set(commit_drawn)):
        errors.append(f"commit submission {identity} has no matching draw proof")
    for identity in sorted(set(commit_ready) - set(commit_submitted)):
        errors.append(f"commit ready {identity} has no matching submission")
    for identity in sorted(set(commit_ready) - set(commit_drawn)):
        errors.append(f"commit ready {identity} has no matching draw proof")
    for identity, draw in commit_drawn.items():
        submitted = commit_submitted.get(identity)
        ready = commit_ready.get(identity)
        if submitted is None or ready is None:
            errors.append(f"commit draw {identity} has no matching submission and ready proof")
            continue
        submit_ns = int(submitted["monotonic_ns"])
        draw_ns = int(draw["monotonic_ns"])
        if draw_ns < submit_ns:
            errors.append(f"commit timestamps are out of order for {identity}")
            continue
        if int(ready["monotonic_ns"]) != draw_ns:
            errors.append(f"commit ready/draw clocks differ for {identity}")
        for field in ("attempt", "serial", "generation", "draw_sequence"):
            if int(draw.get(field, 0)) <= 0 or ready.get(field) != draw.get(field):
                errors.append(f"commit ready/draw changed exact {field} identity for {identity}")
        for field in ("attempt", "serial", "generation"):
            if submitted.get(field) != draw.get(field):
                errors.append(f"commit submission/draw changed exact {field} identity for {identity}")
        if any(
            event.get("route") != "native" or event.get("libmpv_initialized")
            for event in (submitted, ready, draw)
        ):
            errors.append(f"commit {identity} violated native route proof")
        targets = [event.get("target_seconds") for event in (submitted, ready, draw)]
        if any(value is None for value in targets) or not math.isclose(
            float(targets[0]), float(targets[1]), rel_tol=0.0, abs_tol=1e-9
        ):
            errors.append(f"commit ready changed requested target for {identity}")
        else:
            commit_target_error_ms.append(abs(float(targets[2]) - float(targets[0])) * 1000.0)
        gesture_demands = demands_by_gesture.get(identity[0], [])
        if not gesture_demands or gesture_demands[-1][1].get("target_seconds") is None or targets[0] is None or not math.isclose(
            float(gesture_demands[-1][1]["target_seconds"]), float(targets[0]),
            rel_tol=0.0, abs_tol=1e-9,
        ):
            errors.append(f"commit {identity} does not retain the gesture's latest public target")
        commit_to_draw_ms.append((draw_ns - submit_ns) / 1_000_000.0)

    # Every public demand, including one coalesced before dispatch, needs a
    # visible convergence terminal. An older request draw after a newer demand
    # never satisfies the newer demand.
    latest_demand_to_visible_ms: list[float] = []
    convergence: list[dict[str, Any]] = []
    unresolved: list[tuple[int, int]] = []
    for gesture, gesture_demands in demands_by_gesture.items():
        index_by_identity = {
            identity: index for index, (identity, _) in enumerate(gesture_demands)
        }
        preview_terminals = [
            (index_by_identity[identity], int(event["monotonic_ns"]), identity)
            for identity, event in drawn.items()
            if identity in index_by_identity
        ]
        commit_terminals = [
            (int(commit_submitted[identity]["monotonic_ns"]), int(event["monotonic_ns"]), identity)
            for identity, event in commit_drawn.items()
            if identity[0] == gesture and identity in commit_submitted
        ]
        for demand_index, (identity, demand) in enumerate(gesture_demands):
            demand_ns = int(demand["monotonic_ns"])
            candidates: list[tuple[int, str, tuple[int, int]]] = [
                (terminal_ns, "preview", terminal_identity)
                for terminal_index, terminal_ns, terminal_identity in preview_terminals
                if terminal_index >= demand_index and terminal_ns >= demand_ns
            ]
            candidates.extend(
                (terminal_ns, "commit", terminal_identity)
                for submit_ns, terminal_ns, terminal_identity in commit_terminals
                if submit_ns >= demand_ns and terminal_ns >= submit_ns
            )
            if not candidates:
                unresolved.append(identity)
                continue
            terminal_ns, terminal_kind, terminal_identity = min(candidates)
            elapsed_ms = (terminal_ns - demand_ns) / 1_000_000.0
            latest_demand_to_visible_ms.append(elapsed_ms)
            convergence.append({
                "gesture": identity[0], "request": identity[1],
                "latency_ms": elapsed_ms, "terminal": terminal_kind,
                "terminal_gesture": terminal_identity[0],
                "terminal_request": terminal_identity[1],
            })
    if unresolved:
        errors.append(f"public preview demands have no same-or-newer visible terminal: {unresolved}")

    interdraw_ms: list[float] = []
    boundary_gap_ms: list[float] = []
    per_leg: list[dict[str, Any]] = []
    drawn_gestures = sorted({identity[0] for identity in drawn})
    windows_available = isinstance(gesture_windows, Mapping)
    fps_available = (
        isinstance(source_fps, (int, float)) and not isinstance(source_fps, bool)
        and math.isfinite(float(source_fps)) and float(source_fps) > 0.0
    )
    if not windows_available:
        errors.append("scrub proof has no approved delivered gesture windows")
    if not fps_available:
        errors.append("scrub proof has no exact source frame rate")
    for gesture in gesture_order:
        timestamps = sorted(
            int(event["monotonic_ns"])
            for identity, event in drawn.items()
            if identity[0] == gesture
        )
        gaps = [(right - left) / 1_000_000.0 for left, right in zip(timestamps, timestamps[1:])]
        interdraw_ms.extend(gaps)
        leg: dict[str, Any] = {"gesture": gesture, "draw_count": len(timestamps)}
        window = gesture_windows.get(gesture) if windows_available else None
        if isinstance(window, Mapping):
            start_ns = window.get("down_monotonic_ns")
            end_ns = window.get("up_monotonic_ns")
            if (
                isinstance(start_ns, int) and isinstance(end_ns, int)
                and 0 < start_ns < end_ns
            ):
                in_window = [value for value in timestamps if start_ns <= value <= end_ns]
                duration_s = (end_ns - start_ns) / 1_000_000_000.0
                required = (
                    math.ceil(MIN_VISIBLE_SOURCE_FRACTION * min(float(source_fps), MAX_PREVIEW_PROOF_FPS) * duration_s)
                    if fps_available else None
                )
                if in_window:
                    gaps = [
                        (in_window[0] - start_ns) / 1_000_000.0,
                        *((right - left) / 1_000_000.0 for left, right in zip(in_window, in_window[1:])),
                        (end_ns - in_window[-1]) / 1_000_000.0,
                    ]
                    boundary_gap_ms.extend(gaps)
                else:
                    gaps = [duration_s * 1000.0]
                    boundary_gap_ms.extend(gaps)
                leg.update({
                    "down_monotonic_ns": start_ns,
                    "up_monotonic_ns": end_ns,
                    "duration_s": duration_s,
                    "draw_count": len(in_window),
                    "required_draw_count": required,
                    "achieved_preview_fps": len(in_window) / duration_s,
                    "visible_gap_ms": distribution(gaps),
                })
                if required is None or len(in_window) < required:
                    errors.append(
                        f"gesture {gesture} has {len(in_window)} real draws; requires {required} from bound source FPS"
                    )
            else:
                errors.append(f"gesture {gesture} has an invalid delivered window")
        else:
            errors.append(f"gesture {gesture} has no delivered down/up window")
        per_leg.append(leg)

    gesture_targets = {
        gesture: [float(event["target_seconds"]) for _, event in values if event.get("target_seconds") is not None]
        for gesture, values in demands_by_gesture.items()
    }
    forward_ordered = (
        len(gesture_order) == 2 and len(gesture_targets.get(gesture_order[0], [])) >= 2
        and all(right > left for left, right in zip(gesture_targets[gesture_order[0]], gesture_targets[gesture_order[0]][1:]))
    )
    reverse_ordered = (
        len(gesture_order) == 2 and len(gesture_targets.get(gesture_order[1], [])) >= 2
        and all(right < left for left, right in zip(gesture_targets[gesture_order[1]], gesture_targets[gesture_order[1]][1:]))
    )
    commit_gestures = {identity[0] for identity in commit_drawn if identity[0] > 0}
    planned_directions_complete = (
        len(gesture_order) == 2 and forward_ordered and reverse_ordered
        and set(drawn_gestures) == set(gesture_order)
        and commit_gestures == set(gesture_order)
        and all(
            isinstance(leg.get("required_draw_count"), int)
            and leg.get("draw_count", 0) >= leg["required_draw_count"]
            for leg in per_leg
        )
    )
    if not planned_directions_complete:
        errors.append(
            "scrub proof requires source-rate-covered forward/reverse legs and one exact commit per gesture"
        )

    measurements = {
        "request_to_admit_ms": request_to_admit_ms,
        "request_to_draw_ms": request_to_draw_ms,
        "latest_demand_to_visible_ms": latest_demand_to_visible_ms,
        "admit_to_draw_ms": admit_to_draw_ms,
        "interdraw_cadence_ms": interdraw_ms,
        "visible_frame_cadence_ms": boundary_gap_ms,
        "target_error_ms": target_error_ms,
        "commit_target_error_ms": commit_target_error_ms,
        "request_to_failure_ms": request_to_failure_ms,
        "commit_to_draw_ms": commit_to_draw_ms,
    }
    quality_gates = {
        "latest_demand_to_visible_within_100ms_p95_250ms_max": _distribution_within(
            latest_demand_to_visible_ms, MAX_SCRUB_DEMAND_TO_VISIBLE_P95_MS,
            MAX_SCRUB_DEMAND_TO_VISIBLE_SINGLE_MS,
        ),
        "boundary_inclusive_visible_gap_within_50ms_p95_100ms_max": _distribution_within(
            boundary_gap_ms, MAX_SCRUB_VISIBLE_GAP_P95_MS,
            MAX_SCRUB_VISIBLE_GAP_SINGLE_MS,
        ),
        "commit_within_150ms_p95_300ms_max": _distribution_within(
            commit_to_draw_ms, MAX_SCRUB_COMMIT_P95_MS, MAX_SCRUB_COMMIT_SINGLE_MS,
        ),
        "preview_target_error_within_50ms_p95_100ms_max": _distribution_within(
            [*target_error_ms, *commit_target_error_ms],
            MAX_SCRUB_TARGET_ERROR_P95_MS, MAX_SCRUB_TARGET_ERROR_SINGLE_MS,
        ),
        "source_rate_visible_draw_coverage": planned_directions_complete,
    }
    demanded_keys, dispatched_keys = set(demanded), set(dispatched)
    admitted_keys, drawn_keys, failed_keys = set(admitted), set(drawn), set(failed)
    eligible = (
        bool(draw_measurements) and bool(commit_to_draw_ms) and not errors
        and all(quality_gates.values())
    )
    return {
        "eligible": eligible,
        "errors": errors,
        "counts": {
            "demanded": len(demanded), "dispatched": len(dispatched),
            "admitted": len(admitted), "drawn": len(drawn),
            "coalesced_before_dispatch": len(demanded_keys - dispatched_keys),
            "rejected_after_dispatch": len(dispatched_keys - admitted_keys),
            "failed": len(failed),
            "superseded_after_admission": len(admitted_keys - drawn_keys - failed_keys),
            "unresolved_demands": len(unresolved),
            "commit_submitted": len(commit_submitted),
            "commit_ready": len(commit_ready), "commit_drawn": len(commit_drawn),
            "drawn_gestures": len(drawn_gestures),
        },
        "planned_directions_complete": planned_directions_complete,
        "gesture_order": gesture_order,
        "gesture_targets": gesture_targets,
        "per_leg": per_leg,
        "quality_gates": quality_gates,
        "distributions": {name: distribution(values) for name, values in measurements.items()},
        "measurements": measurements,
        "draws": draw_measurements,
        "convergence": convergence,
    }


def summarize_native_telemetry(
    parsed: Mapping[str, Any],
    launch_request_monotonic_ns: int | None,
    expected_run_id: str | None = None,
    expected_process_id: int | None = None,
    expected_process_start_abstime: int | None = None,
    expected_asset_sha256: str | None = None,
    expected_candidate_id: str | None = None,
    *,
    scrub_gesture_windows: Mapping[int, Mapping[str, int]] | None = None,
    source_fps: float | None = None,
) -> dict[str, Any]:
    events = [
        event for event in parsed.get("events", ()) if isinstance(event, Mapping)
    ]
    first_open_ns = next(
        (
            int(event["monotonic_ns"])
            for event in events
            if event.get("event") == "open_requested"
        ),
        0,
    )
    clock_available = launch_request_monotonic_ns is not None
    baseline_ns = launch_request_monotonic_ns if clock_available else first_open_ns
    proof = run_suite.summarize_wam_native_proof(
        parsed,
        int(baseline_ns),
        expected_run_id,
        expected_process_id,
        expected_process_start_abstime,
        expected_asset_sha256,
        expected_candidate_id,
        require_stream_complete=True,
    )
    if not clock_available:
        proof["latencies"]["cold_request_to_first_draw_ms"] = None
    internal = [
        float(session["open_request_to_first_draw_ms"])
        for session in proof.get("sessions", ())
    ]
    sessions = [
        session
        for session in proof.get("sessions", ())
        if isinstance(session, Mapping)
    ]
    warm_sessions = [
        session for session in sessions if session.get("open_ordinal") == 2
    ]
    warm_ms = [
        float(session["open_request_to_first_draw_ms"])
        for session in warm_sessions
    ]
    source_keys = [session.get("source_key") for session in sessions]
    warm_lineage_exact = (
        len(sessions) == 2
        and len(warm_sessions) == 1
        and len(source_keys) == 2
        and all(isinstance(value, int) and value > 0 for value in source_keys)
        and len(set(source_keys)) == 2
        and int(sessions[0].get("first_frame_drawn_monotonic_ns", 0))
        < int(warm_sessions[0].get("open_requested_monotonic_ns", 0))
    )
    cold = proof["latencies"].get("cold_request_to_first_draw_ms")
    return {
        "native_proof": proof,
        "startup": {
            "eligible": proof.get("eligible") is True and clock_available,
            "launch_request_clock_available": clock_available,
            "external_request_to_first_visible_frame_ms": cold,
            "open_to_first_visible_frame_ms": distribution(internal),
            "warm_open_to_first_visible_frame_ms": distribution(warm_ms),
            "warm_open": {
                "eligible": proof.get("eligible") is True and warm_lineage_exact,
                "same_process_run": proof.get("eligible") is True,
                "distinct_second_source": warm_lineage_exact,
                "measurement_available": len(warm_ms) == 1,
                "open_to_first_visible_frame_ms": warm_ms[0] if len(warm_ms) == 1 else None,
            },
            "measurements": {
                "external_request_to_first_visible_frame_ms": (
                    [float(cold)] if cold is not None else []
                ),
                "open_to_first_visible_frame_ms": internal,
                "warm_open_to_first_visible_frame_ms": warm_ms,
            },
        },
        "scrub": summarize_scrub_telemetry(
            parsed, scrub_gesture_windows, source_fps
        ),
    }


def attach_telemetry(
    artifact: dict[str, Any],
    path: Path,
    launch_request_monotonic_ns: int | None,
    expected_run_id: str,
    expected_process_id: int,
    expected_process_start_abstime: int,
    expected_asset_sha256: str,
) -> None:
    parsed = run_suite.read_wam_native_telemetry(path)
    artifact["native_telemetry_raw"] = parsed
    artifact["launch_request_monotonic_ns"] = launch_request_monotonic_ns
    artifact["native_telemetry"] = summarize_native_telemetry(
        parsed,
        launch_request_monotonic_ns,
        expected_run_id,
        expected_process_id,
        expected_process_start_abstime,
        expected_asset_sha256,
    )


def _validate_drag_schedule_evidence(
    evidence: Any,
) -> tuple[dict[str, Any], list[str]]:
    errors: list[str] = []
    expected = build_drag_plan()
    if not isinstance(evidence, Mapping):
        return {}, ["scrub artifact has no raw drag-schedule evidence"]
    driver = evidence.get("screen_driver")
    if not isinstance(driver, Mapping) or (
        driver.get("screen_backed") is not True
        or driver.get("window_visible") is not True
        or driver.get("approved_computer_use") is not True
    ):
        errors.append(
            "drag evidence has no approved screen-backed visible-window driver"
        )
    events = evidence.get("events")
    if not isinstance(events, list) or len(events) != len(expected):
        return {}, [
            "drag evidence does not contain the complete fixed 120 Hz two-leg schedule"
        ]
    delivered: list[int] = []
    telemetry_gesture_ids = evidence.get("telemetry_gesture_ids")
    if (
        not isinstance(telemetry_gesture_ids, list)
        or len(telemetry_gesture_ids) != 2
        or len(set(telemetry_gesture_ids)) != 2
        or any(
            isinstance(value, bool) or not isinstance(value, int) or value <= 0
            for value in telemetry_gesture_ids
        )
    ):
        errors.append("drag evidence does not bind both telemetry gesture IDs")
    for index, (observed, planned) in enumerate(zip(events, expected)):
        if not isinstance(observed, Mapping):
            errors.append(f"drag evidence event {index} is not an object")
            continue
        for field, expected_value in planned.as_dict().items():
            value = observed.get(field)
            if isinstance(expected_value, float):
                matches = isinstance(value, (int, float)) and math.isclose(
                    float(value), expected_value, rel_tol=0.0, abs_tol=1e-12
                )
            else:
                matches = value == expected_value
            if not matches:
                errors.append(f"drag evidence event {index} changed planned {field}")
        delivered_ns = observed.get("delivered_monotonic_ns")
        if (
            isinstance(delivered_ns, bool)
            or not isinstance(delivered_ns, int)
            or delivered_ns <= 0
        ):
            errors.append(f"drag evidence event {index} has no delivery clock")
        else:
            delivered.append(delivered_ns)
    if len(delivered) == len(expected) and any(
        right < left for left, right in zip(delivered, delivered[1:])
    ):
        errors.append("drag delivery clocks are not monotonic")
    delivery_gaps_ms = [
        (right - left) / 1_000_000.0
        for left, right in zip(delivered, delivered[1:])
        if right > left
    ]
    move_gaps_ms = [
        (delivered[index] - delivered[index - 1]) / 1_000_000.0
        for index in range(1, len(delivered))
        if expected[index].action == "move"
        and expected[index - 1].gesture == expected[index].gesture
    ] if len(delivered) == len(expected) else []
    observed_move_rate_hz = (
        1000.0 / statistics.fmean(move_gaps_ms) if move_gaps_ms else None
    )
    if observed_move_rate_hz is None or not 108.0 <= observed_move_rate_hz <= 132.0:
        errors.append("observed drag delivery rate is not within 10% of 120 Hz")
    expected_period_ms = 1000.0 / DEFAULT_DRAG_RATE_HZ
    minimum_gap_ms = expected_period_ms * 0.90
    maximum_gap_ms = expected_period_ms * 1.10
    if not move_gaps_ms or any(
        gap < minimum_gap_ms or gap > maximum_gap_ms for gap in move_gaps_ms
    ):
        errors.append(
            "one or more delivered drag intervals is outside 10% of the fixed 120 Hz period"
        )
    gesture_windows: dict[int, dict[str, int]] = {}
    if len(delivered) == len(expected) and isinstance(telemetry_gesture_ids, list):
        for plan_gesture, telemetry_gesture in zip((1, 2), telemetry_gesture_ids):
            gesture_rows = [
                (step, clock)
                for step, clock in zip(expected, delivered)
                if step.gesture == plan_gesture
            ]
            down = [clock for step, clock in gesture_rows if step.action == "down"]
            up = [clock for step, clock in gesture_rows if step.action == "up"]
            if len(down) == 1 and len(up) == 1 and down[0] < up[0]:
                gesture_windows[int(telemetry_gesture)] = {
                    "down_monotonic_ns": down[0],
                    "up_monotonic_ns": up[0],
                }
            else:
                errors.append(
                    f"drag evidence has no exact down/up window for plan gesture {plan_gesture}"
                )
    return {
        "eligible": not errors,
        "event_count": len(events),
        "observed_move_rate_hz": observed_move_rate_hz,
        "delivery_gap_ms": distribution(delivery_gaps_ms),
        "move_gap_ms": distribution(move_gaps_ms),
        "per_interval_limits_ms": {
            "minimum": minimum_gap_ms,
            "maximum": maximum_gap_ms,
        },
        "telemetry_gesture_ids": telemetry_gesture_ids,
        "gesture_windows": gesture_windows,
        "screen_driver": dict(driver) if isinstance(driver, Mapping) else None,
    }, errors


def _validate_fallback_control(
    artifact: Mapping[str, Any],
    app_pid: int | None,
    raw_telemetry: Mapping[str, Any] | None,
    expected_wam_executable: str | None,
) -> tuple[dict[str, Any], list[str]]:
    evidence = artifact.get("fallback_control")
    errors: list[str] = []
    if not isinstance(evidence, Mapping):
        return {}, ["fallback control artifact has no screen-backed evidence"]
    fallback_library = evidence.get("fallback_library")
    visible_frame = evidence.get("visible_frame")
    audio = evidence.get("audio")
    driver = evidence.get("screen_driver")
    if not isinstance(driver, Mapping) or (
        driver.get("screen_backed") is not True
        or driver.get("window_visible") is not True
        or driver.get("approved_computer_use") is not True
        or driver.get("process_id") != app_pid
        or driver.get("run_id")
        != next(
            (
                event.get("run_id")
                for event in (raw_telemetry or {}).get("events", ())
                if isinstance(event, Mapping)
            ),
            None,
        )
        or driver.get("process_start_abstime")
        != next(
            (
                event.get("process_start_abstime")
                for event in (raw_telemetry or {}).get("events", ())
                if isinstance(event, Mapping)
            ),
            None,
        )
    ):
        errors.append("fallback control has no approved visible screen-driver proof")
    fallback_events = [
        event
        for event in (raw_telemetry or {}).get("events", ())
        if isinstance(event, Mapping)
        and event.get("event") == "fallback_selected"
        and event.get("route") == "fallback"
        and event.get("route_proof") is True
    ]
    native_events = [
        event
        for event in (raw_telemetry or {}).get("events", ())
        if isinstance(event, Mapping)
        and event.get("event") == "native_selected"
        and event.get("route") == "native"
        and event.get("route_proof") is True
    ]
    route_monotonic_ns = (
        int(fallback_events[0].get("monotonic_ns", 0))
        if len(fallback_events) == 1
        else 0
    )
    if len(fallback_events) != 1 or native_events:
        errors.append(
            "raw telemetry must prove exactly one fallback selection and no native selection"
        )
    if evidence.get("staged_bundle") is not True:
        errors.append("fallback control was not run from the staged bundle")
    if evidence.get("verify_runtime_mode") is not False:
        errors.append("--verify-runtime cannot prove the macOS fallback loader")
    if evidence.get("route") != "fallback" or evidence.get("fallback_selected") is not True:
        errors.append("exact fallback route selection was not proven")
    if evidence.get("route_selection_monotonic_ns") != route_monotonic_ns:
        errors.append("fallback screen evidence is not bound to the telemetry route clock")
    if evidence.get("native_selected") is not False:
        errors.append("fallback control is ambiguous with the native route")
    if not isinstance(fallback_library, Mapping):
        errors.append("fallback library load evidence is missing")
    else:
        path = fallback_library.get("canonical_path")
        try:
            expected_bundle = (
                run_suite.app_bundle_for_executable(Path(expected_wam_executable))
                if expected_wam_executable
                else None
            )
        except run_suite.SuiteError:
            expected_bundle = None
        expected_library = (
            expected_bundle / "Contents" / "Frameworks" / "WAMMpvFallback.dylib"
            if expected_bundle is not None
            else None
        )
        if (
            fallback_library.get("loaded") is not True
            or not isinstance(path, str)
            or os.path.basename(path) != "WAMMpvFallback.dylib"
            or expected_library is None
            or os.path.realpath(path) != os.path.realpath(expected_library)
            or fallback_library.get("loaded_by_process_id") != app_pid
            or fallback_library.get("observed_after_route_selection") is not True
            or fallback_library.get("not_loaded_before_route_selection") is not True
            or fallback_library.get("observation_method")
            not in {"dyld_image_list", "vmmap", "lsof"}
            or not isinstance(
                fallback_library.get("pre_route_observed_monotonic_ns"), int
            )
            or fallback_library.get("pre_route_observed_monotonic_ns", 0) <= 0
            or fallback_library.get("pre_route_observed_monotonic_ns", 0)
            > route_monotonic_ns
            or not isinstance(fallback_library.get("observed_monotonic_ns"), int)
            or fallback_library.get("observed_monotonic_ns", 0) < route_monotonic_ns
        ):
            errors.append("WAMMpvFallback.dylib lazy-load evidence is incomplete")
    if not isinstance(visible_frame, Mapping) or (
        visible_frame.get("observed") is not True
        or not isinstance(visible_frame.get("monotonic_ns"), int)
        or visible_frame.get("monotonic_ns", 0) <= 0
        or visible_frame.get("monotonic_ns", 0) < route_monotonic_ns
        or not isinstance(visible_frame.get("screen_capture_sha256"), str)
        or re.fullmatch(
            r"[0-9a-f]{64}", visible_frame.get("screen_capture_sha256", "")
        )
        is None
    ):
        errors.append("fallback first visible frame was not screen-proven")
    if not isinstance(audio, Mapping) or (
        audio.get("active") is not True
        or audio.get("audible") is not True
        or not isinstance(audio.get("monotonic_ns"), int)
        or audio.get("monotonic_ns", 0) <= 0
        or audio.get("monotonic_ns", 0) < route_monotonic_ns
        or not isinstance(audio.get("active_proof"), str)
        or not audio.get("active_proof")
        or not isinstance(audio.get("audible_proof"), str)
        or not audio.get("audible_proof")
    ):
        errors.append("fallback active and audible audio was not proven")
    return {**dict(evidence), "eligible": not errors}, errors


def _recompute_artifact(
    artifact: Mapping[str, Any], index: int
) -> tuple[dict[str, Any], list[str]]:
    """Rebuild every derived gate from raw process and telemetry evidence."""

    errors: list[str] = []
    normalized = dict(artifact)
    if artifact.get("kind") != "process_samples":
        return normalized, [f"artifact {index} is not raw process_samples evidence"]
    pids = artifact.get("pids")
    samples_value = artifact.get("samples")
    interval_s = artifact.get("interval_s")
    duration_s = artifact.get("duration_s")
    if (
        not isinstance(pids, list)
        or not pids
        or any(isinstance(pid, bool) or not isinstance(pid, int) or pid <= 0 for pid in pids)
    ):
        return normalized, [f"artifact {index} has no exact raw PID set"]
    if not isinstance(samples_value, list) or len(samples_value) < 2:
        return normalized, [f"artifact {index} has no raw 20 Hz process samples"]
    if not isinstance(interval_s, (int, float)) or not math.isclose(
        float(interval_s), DEFAULT_SAMPLE_INTERVAL_S, rel_tol=0.0, abs_tol=1e-12
    ):
        errors.append(f"artifact {index} does not use the fixed 20 Hz interval")
    if not isinstance(duration_s, (int, float)) or float(duration_s) <= 0:
        errors.append(f"artifact {index} has no positive measured duration")
    if errors:
        return normalized, errors
    samples = json.loads(json.dumps(samples_value))
    interval_ns = round(float(interval_s) * 1_000_000_000.0)
    duration_ns = round(float(duration_s) * 1_000_000_000.0)
    expected_offsets = list(range(0, duration_ns + 1, interval_ns))
    if expected_offsets[-1] != duration_ns:
        expected_offsets.append(duration_ns)
    if len(samples) != len(expected_offsets):
        errors.append(
            f"artifact {index} raw sample cardinality does not cover its declared duration"
        )
    elif any(
        not math.isclose(
            float(sample.get("scheduled_offset_s", -1)),
            offset / 1_000_000_000.0,
            rel_tol=0.0,
            abs_tol=1e-9,
        )
        for sample, offset in zip(samples, expected_offsets)
    ):
        errors.append(f"artifact {index} raw sampling schedule was rewritten")
    try:
        for sample in samples:
            processes = sample["processes"]
            sample["aggregate"] = _aggregate_snapshot(processes, len(pids))
        recomputed_summary = _summarize_process_samples(
            samples,
            pids,
            float(interval_s),
            DEFAULT_CPU_LIMIT_PERCENT,
            DEFAULT_MEMORY_LIMIT_BYTES,
        )
    except (KeyError, TypeError, ValueError) as error:
        return normalized, [f"artifact {index} has invalid raw process samples: {error}"]

    raw_provenance = artifact.get("process_provenance")
    provenance: dict[int, Mapping[str, Any]] = {}
    if isinstance(raw_provenance, Mapping):
        try:
            provenance = {int(pid): value for pid, value in raw_provenance.items()}
        except (TypeError, ValueError):
            provenance = {}
    provenance_report = validate_process_provenance(pids, provenance or None)
    if not provenance_report["eligible"]:
        errors.extend(
            f"artifact {index}: {message}" for message in provenance_report["errors"]
        )
    history = artifact.get("coalition_membership")
    membership_complete = (
        isinstance(history, list)
        and len(history) == len(samples)
        and all(
            isinstance(value, Mapping)
            and value.get("available") is True
            and value.get("complete") is True
            and value.get("observed_pids") == sorted(pids)
            and value.get("kernel_active_count") == len(pids)
            for value in history
        )
    )
    if not membership_complete:
        errors.append(
            f"artifact {index} lacks complete same-coalition membership at every 20 Hz sample"
        )
    app_entries = [
        (pid, value)
        for pid, value in provenance.items()
        if value.get("role") == ROLE_APP
    ]
    app_pid = app_entries[0][0] if len(app_entries) == 1 else None
    app_record = app_entries[0][1] if len(app_entries) == 1 else {}
    expected_start = app_record.get("expected_process_start_abstime")
    sampled_start_matches = app_pid is not None and all(
        sample["processes"].get(str(app_pid), {}).get("process_start_abstime")
        == expected_start
        for sample in samples
    )
    if not sampled_start_matches:
        errors.append(f"artifact {index} sampled a different process start identity")
    history_identity_matches = (
        isinstance(history, list)
        and app_pid is not None
        and all(
            isinstance(value, Mapping)
            and isinstance(value.get("app"), Mapping)
            and value["app"].get("pid") == app_pid
            and isinstance(value["app"].get("identity"), Mapping)
            and value["app"]["identity"].get("pid") == app_pid
            and run_suite.same_executable(
                value["app"]["identity"].get("executable", ""),
                app_record.get("expected_wam_executable", ""),
            )
            and isinstance(value["app"].get("resource_coalition"), Mapping)
            and value["app"]["resource_coalition"].get("coalition_id")
            == app_record.get("coalition_id")
            and value["app"]["resource_coalition"].get("bundle_id")
            == EXPECTED_WAM_BUNDLE_ID
            and {
                helper.get("pid")
                for helper in value.get("helpers", ())
                if isinstance(helper, Mapping)
            }
            == {
                pid
                for pid, process_value in provenance.items()
                if process_value.get("role") == ROLE_DECODER_HELPER
            }
            and all(
                isinstance(helper, Mapping)
                and helper.get("role") == ROLE_DECODER_HELPER
                and isinstance(helper.get("identity"), Mapping)
                and helper["identity"].get("pid") == helper.get("pid")
                and os.path.basename(helper["identity"].get("executable", ""))
                == run_suite.HELPER_BASENAME
                and isinstance(helper.get("resource_coalition"), Mapping)
                and helper["resource_coalition"].get("coalition_id")
                == app_record.get("coalition_id")
                and helper["resource_coalition"].get("active_count") == len(pids)
                for helper in value.get("helpers", ())
            )
            for value in history
        )
    )
    if not history_identity_matches:
        errors.append(
            f"artifact {index} coalition history is not bound to exact WAM/helper identities"
        )

    raw_telemetry = artifact.get("native_telemetry_raw")
    metadata_value = artifact.get("metadata")
    asset_value = (
        metadata_value.get("asset")
        if isinstance(metadata_value, Mapping)
        and isinstance(metadata_value.get("asset"), Mapping)
        else {}
    )
    expected_asset_sha256 = asset_value.get("sha256")
    if not isinstance(raw_telemetry, Mapping):
        errors.append(f"artifact {index} has no raw native telemetry")
        telemetry = {}
    else:
        telemetry = summarize_native_telemetry(
            raw_telemetry,
            artifact.get("launch_request_monotonic_ns"),
            app_record.get("expected_run_id"),
            app_pid,
            expected_start,
            expected_asset_sha256,
        )
    recomputed_summary["provenance"] = provenance_report
    recomputed_summary["provenance"]["coalition_enumeration_complete"] = (
        membership_complete
    )
    recomputed_summary["provenance"]["sampled_process_start_matches_telemetry"] = (
        sampled_start_matches
    )
    recomputed_summary["eligible"] = (
        recomputed_summary["eligible"]
        and provenance_report["eligible"]
        and membership_complete
        and sampled_start_matches
        and history_identity_matches
    )
    if not recomputed_summary["eligible"]:
        errors.append(f"artifact {index} raw process evidence is ineligible")
    normalized["samples"] = samples
    sample_start_ns = int(samples[0]["monotonic_ns"])
    sample_end_ns = int(samples[-1]["monotonic_ns"])
    normalized["phase_window"] = {
        "sample_started_monotonic_ns": sample_start_ns,
        "sample_ended_monotonic_ns": sample_end_ns,
    }
    normalized["summary"] = recomputed_summary
    normalized["native_telemetry"] = telemetry
    phase = artifact.get("phase")
    if phase == "startup":
        sessions = telemetry.get("native_proof", {}).get("sessions", ()) if isinstance(telemetry, Mapping) else ()
        first_draw_ns = (
            sessions[0].get("first_frame_drawn_monotonic_ns")
            if isinstance(sessions, list) and sessions
            else None
        )
        if not isinstance(first_draw_ns, int) or first_draw_ns > sample_end_ns:
            errors.append(
                f"artifact {index} process sampling ended before exact first visible frame"
            )
    elif phase == "steady":
        metadata = artifact.get("metadata", {})
        if float(duration_s) < DEFAULT_STEADY_DURATION_S:
            errors.append(f"artifact {index} steady measurement is shorter than 30 seconds")
        warmup = artifact.get("warmup_evidence")
        if not isinstance(warmup, Mapping):
            errors.append(f"artifact {index} has no raw steady warm-up evidence")
        else:
            playback_started_ns = warmup.get("playback_started_monotonic_ns")
            measurement_started_ns = warmup.get("measurement_started_monotonic_ns")
            if (
                not isinstance(playback_started_ns, int)
                or not isinstance(measurement_started_ns, int)
                or playback_started_ns <= 0
                or measurement_started_ns != sample_start_ns
                or measurement_started_ns - playback_started_ns
                < round(DEFAULT_STEADY_WARMUP_S * 1_000_000_000)
                or warmup.get("continuous_playback") is not True
                or warmup.get("run_id") != app_record.get("expected_run_id")
                or warmup.get("process_id") != app_pid
                or warmup.get("process_start_abstime") != expected_start
            ):
                errors.append(
                    f"artifact {index} does not prove 15 seconds of same-process continuous warm-up"
                )
    elif phase == "scrub":
        drag_report, drag_errors = _validate_drag_schedule_evidence(
            artifact.get("drag_schedule_evidence")
        )
        normalized["drag_schedule"] = drag_report
        errors.extend(f"artifact {index}: {message}" for message in drag_errors)
        drag_evidence = artifact.get("drag_schedule_evidence", {})
        if (
            not isinstance(drag_evidence, Mapping)
            or drag_evidence.get("run_id") != app_record.get("expected_run_id")
            or drag_evidence.get("process_id") != app_pid
            or drag_evidence.get("process_start_abstime") != expected_start
        ):
            errors.append(f"artifact {index} drag delivery belongs to another process run")
        telemetry = summarize_native_telemetry(
            raw_telemetry if isinstance(raw_telemetry, Mapping) else {},
            artifact.get("launch_request_monotonic_ns"),
            app_record.get("expected_run_id"),
            app_pid,
            expected_start,
            expected_asset_sha256,
            scrub_gesture_windows=drag_report.get("gesture_windows"),
            source_fps=asset_value.get("source_fps"),
        )
        normalized["native_telemetry"] = telemetry
        delivery_events = artifact.get("drag_schedule_evidence", {}).get("events", ())
        delivery_clocks = [
            event.get("delivered_monotonic_ns")
            for event in delivery_events
            if isinstance(event, Mapping)
            and isinstance(event.get("delivered_monotonic_ns"), int)
        ] if isinstance(delivery_events, list) else []
        if (
            not delivery_clocks
            or min(delivery_clocks) < sample_start_ns
            or max(delivery_clocks) > sample_end_ns
        ):
            errors.append(
                f"artifact {index} resource samples do not cover the delivered drag window"
            )
        scrub_report = telemetry.get("scrub", {}) if isinstance(telemetry, Mapping) else {}
        if drag_report.get("telemetry_gesture_ids") != scrub_report.get("gesture_order"):
            errors.append(
                f"artifact {index} drag delivery is not bound to telemetry gestures"
            )
        gesture_targets = scrub_report.get("gesture_targets", {})
        gesture_ids = scrub_report.get("gesture_order", [])
        metadata = artifact.get("metadata", {})
        clip_duration = metadata.get("clip_duration_s") if isinstance(metadata, Mapping) else None
        if (
            not isinstance(clip_duration, (int, float))
            or isinstance(clip_duration, bool)
            or not math.isfinite(float(clip_duration))
            or float(clip_duration) <= 0
        ):
            errors.append(f"artifact {index} scrub clip duration is unavailable")
        elif len(gesture_ids) == 2:
            forward = gesture_targets.get(gesture_ids[0], gesture_targets.get(str(gesture_ids[0]), []))
            reverse = gesture_targets.get(gesture_ids[1], gesture_targets.get(str(gesture_ids[1]), []))
            duration = float(clip_duration)
            if (
                len(forward) < MIN_SCRUB_REQUESTS_PER_LEG
                or len(reverse) < MIN_SCRUB_REQUESTS_PER_LEG
            ):
                errors.append(
                    f"artifact {index} app received too few requests for continuous drag proof"
                )
            if (
                not forward
                or not reverse
                or forward[0] > duration * 0.10
                or forward[-1] < duration * 0.90
                or reverse[0] < duration * 0.90
                or reverse[-1] > duration * 0.10
            ):
                errors.append(
                    f"artifact {index} telemetry does not cover both drag endpoints"
                )
        required_duration = build_drag_plan()[-1].offset_ns / 1_000_000_000.0
        if float(duration_s) < required_duration:
            errors.append(f"artifact {index} does not cover the complete drag schedule")
    elif phase == FALLBACK_PHASE:
        fallback_report, fallback_errors = _validate_fallback_control(
            artifact,
            app_pid,
            raw_telemetry if isinstance(raw_telemetry, Mapping) else None,
            app_record.get("expected_wam_executable"),
        )
        normalized["fallback_control"] = fallback_report
        errors.extend(f"artifact {index}: {message}" for message in fallback_errors)
        fallback_clocks = [
            fallback_report.get("route_selection_monotonic_ns"),
            fallback_report.get("fallback_library", {}).get("pre_route_observed_monotonic_ns"),
            fallback_report.get("fallback_library", {}).get("observed_monotonic_ns"),
            fallback_report.get("visible_frame", {}).get("monotonic_ns"),
            fallback_report.get("audio", {}).get("monotonic_ns"),
        ]
        if (
            any(not isinstance(value, int) for value in fallback_clocks)
            or min(fallback_clocks) < sample_start_ns
            or max(fallback_clocks) > sample_end_ns
        ):
            errors.append(
                f"artifact {index} resource samples do not cover the fallback load/frame/audio window"
            )
        if float(duration_s) < DEFAULT_FALLBACK_DURATION_S:
            errors.append(
                f"artifact {index} fallback control measurement is shorter than 5 seconds"
            )
    return normalized, errors


def _read_json(path: Path) -> Mapping[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise ShipperError(f"could not read {path}: {error}") from error
    if not isinstance(value, Mapping):
        raise ShipperError(f"{path} does not contain a JSON object")
    if value.get("schema") != SCHEMA:
        raise ShipperError(
            f"{path} uses schema {value.get('schema')!r}; expected {SCHEMA!r}"
        )
    return value


def _summarize_comparative_appendix(
    trials: Sequence[Mapping[str, Any]],
) -> dict[str, Any]:
    """Summarize paired diagnostics without contributing to ship gates."""

    full_app_modes = {"native_wam", "bundled_fallback_wam"}
    pairs: dict[str, list[Mapping[str, Any]]] = {}
    lab_trials: list[dict[str, Any]] = []
    errors: list[str] = []
    for index, trial in enumerate(trials):
        mode = trial.get("mode")
        if mode == "ffmpeg_videotoolbox_decode_null":
            lab_trials.append(dict(trial))
            continue
        if mode not in full_app_modes:
            errors.append(f"comparative trial {index} has unsupported mode {mode!r}")
            continue
        pair_id = trial.get("pair_id")
        if not isinstance(pair_id, str) or not pair_id:
            errors.append(f"comparative trial {index} has no pair ID")
            continue
        pairs.setdefault(pair_id, []).append(trial)

    pair_reports: list[dict[str, Any]] = []
    for pair_id, pair_trials in sorted(pairs.items()):
        pair_errors: list[str] = []
        by_mode = {trial.get("mode"): trial for trial in pair_trials}
        if set(by_mode) != full_app_modes or len(pair_trials) != 2:
            pair_errors.append("pair must contain exactly one native and one bundled-fallback run")
        native = by_mode.get("native_wam", {})
        fallback = by_mode.get("bundled_fallback_wam", {})
        comparable_fields = ("asset", "hardware_policy", "workload", "workload_output")
        for field in comparable_fields:
            if not native.get(field) or native.get(field) != fallback.get(field):
                pair_errors.append(f"paired full-app trials do not share exact {field}")
        asset = native.get("asset", {})
        if not isinstance(asset, Mapping) or (
            re.fullmatch(r"[0-9a-f]{64}", str(asset.get("sha256", ""))) is None
            or not isinstance(asset.get("byte_length"), int)
            or asset.get("byte_length", 0) <= 0
            or asset.get("codec") not in {"h264", "hevc"}
        ):
            pair_errors.append("pair has no exact H.264/HEVC byte identity")
        if native.get("hardware_policy") != "videotoolbox_required":
            pair_errors.append("pair does not hold VideoToolbox hardware policy constant")

        normalized: dict[str, Mapping[str, Any]] = {}
        for mode, trial in by_mode.items():
            measurement = trial.get("measurement")
            if not isinstance(measurement, Mapping):
                pair_errors.append(f"{mode} has no raw full-app process measurement")
                continue
            value, measurement_errors = _recompute_artifact(
                {**measurement, "phase": "comparison"}, 0
            )
            if measurement_errors:
                pair_errors.extend(
                    f"{mode}: {message}" for message in measurement_errors
                )
            normalized[str(mode)] = value
        native_proof = normalized.get("native_wam", {}).get("native_telemetry", {}).get(
            "native_proof", {}
        )
        if native_proof.get("eligible") is not True:
            pair_errors.append("native comparison arm lacks exact native-route proof")
        fallback_measurement = normalized.get("bundled_fallback_wam", {})
        fallback_provenance = fallback_measurement.get("process_provenance", {})
        fallback_app_pid = next(
            (
                int(pid)
                for pid, value in fallback_provenance.items()
                if isinstance(value, Mapping) and value.get("role") == ROLE_APP
            ),
            None,
        ) if isinstance(fallback_provenance, Mapping) else None
        fallback_expected_executable = next(
            (
                value.get("expected_wam_executable")
                for value in fallback_provenance.values()
                if isinstance(value, Mapping) and value.get("role") == ROLE_APP
            ),
            None,
        ) if isinstance(fallback_provenance, Mapping) else None
        fallback_evidence, fallback_errors = _validate_fallback_control(
            fallback,
            fallback_app_pid,
            fallback_measurement.get("native_telemetry_raw"),
            fallback_expected_executable,
        )
        pair_errors.extend(f"bundled_fallback_wam: {message}" for message in fallback_errors)

        metrics: dict[str, Any] = {}
        if not pair_errors:
            for mode, measurement in normalized.items():
                summary = measurement.get("summary", {})
                telemetry = measurement.get("native_telemetry", {})
                metrics[mode] = {
                    "startup_request_to_first_visible_frame_ms": telemetry.get(
                        "startup", {}
                    ).get("external_request_to_first_visible_frame_ms"),
                    "time_weighted_cpu_percent": summary.get("cpu_percent", {}).get(
                        "time_weighted_mean"
                    ),
                    "hard_gate_peak_bytes": summary.get("memory", {}).get(
                        "hard_gate_peak_bytes"
                    ),
                }
        pair_reports.append(
            {
                "pair_id": pair_id,
                "comparable": not pair_errors,
                "errors": pair_errors,
                "metrics": metrics,
                "fallback_loader_evidence": fallback_evidence,
            }
        )
    return {
        "gating": False,
        "scope": "paired full-app diagnostic only; never shipping evidence",
        "pairs": pair_reports,
        "ffmpeg_videotoolbox_decode_to_null_lab": {
            "gating": False,
            "scope": (
                "optional decoder laboratory; excludes player launch, render, "
                "presentation, controls, and audio semantics"
            ),
            "trials": lab_trials,
        },
        "errors": errors,
    }


def summarize_artifacts(artifacts: Sequence[Mapping[str, Any]]) -> dict[str, Any]:
    comparative_trials = [
        artifact for artifact in artifacts if artifact.get("kind") == "comparative_trial"
    ]
    artifacts = [
        artifact for artifact in artifacts if artifact.get("kind") != "comparative_trial"
    ]
    comparative_appendix = _summarize_comparative_appendix(comparative_trials)
    recomputed_artifacts: list[dict[str, Any]] = []
    evidence_errors: list[str] = []
    for index, artifact in enumerate(artifacts):
        normalized, errors = _recompute_artifact(artifact, index)
        normalized["_raw_evidence_eligible"] = not errors
        recomputed_artifacts.append(normalized)
        evidence_errors.extend(errors)
    artifacts = recomputed_artifacts
    phases: dict[str, list[Mapping[str, Any]]] = {
        "startup": [],
        "steady": [],
        "scrub": [],
        FALLBACK_PHASE: [],
    }
    for artifact in artifacts:
        phase = artifact.get("phase")
        if phase not in phases:
            raise ShipperError(f"artifact has unsupported phase {phase!r}")
        phases[str(phase)].append(artifact)

    trial_keys: set[tuple[str, str, str, str, str]] = set()
    native_matrix_counts = {
        phase: {"|".join(variant): 0 for variant in REQUIRED_VARIANTS}
        for phase in REQUIRED_REPLICATES
    }
    fallback_matrix_count = 0
    metadata_errors: list[str] = []
    startup_process_identities: list[tuple[int, int, str]] = []
    clip_ids_by_variant: dict[tuple[str, str, str], set[str]] = {}
    for index, artifact in enumerate(artifacts):
        metadata = artifact.get("metadata")
        if not isinstance(metadata, Mapping):
            metadata_errors.append(f"artifact {index} has no trial metadata")
            continue
        phase = str(artifact.get("phase"))
        codec = metadata.get("codec")
        container = metadata.get("container")
        profile = metadata.get("profile")
        run = metadata.get("run")
        clip_id = metadata.get("clip_id")
        if codec == "h264" and profile in {None, ""}:
            profile = "any"
        if not all(isinstance(value, str) and value for value in (codec, container, profile, run, clip_id)):
            metadata_errors.append(f"artifact {index} has incomplete trial metadata")
            continue
        variant = (str(codec), str(container), str(profile))
        if phase == FALLBACK_PHASE:
            if variant != FALLBACK_VARIANT:
                metadata_errors.append(
                    f"artifact {index} has unsupported fallback variant {variant}"
                )
                continue
        elif variant not in REQUIRED_VARIANTS:
            metadata_errors.append(f"artifact {index} has unsupported variant {variant}")
            continue
        asset = metadata.get("asset")
        if not isinstance(asset, Mapping):
            metadata_errors.append(f"artifact {index} has no probed asset identity")
            continue
        asset_sha256 = asset.get("sha256")
        if (
            not isinstance(asset_sha256, str)
            or re.fullmatch(r"[0-9a-f]{64}", asset_sha256) is None
            or not isinstance(asset.get("byte_length"), int)
            or isinstance(asset.get("byte_length"), bool)
            or asset.get("byte_length", 0) <= 0
            or asset.get("codec") != codec
            or asset.get("container") != container
            or asset.get("profile") != profile
        ):
            metadata_errors.append(f"artifact {index} has inconsistent probed asset metadata")
            continue
        if phase == FALLBACK_PHASE:
            if (
                asset.get("audio_codec") != "opus"
                or asset.get("native_eligible") is not False
                or asset.get("staged_bundle_asset") is not True
            ):
                metadata_errors.append(
                    f"artifact {index} is not a staged native-unsupported VP9/WebM+Opus asset"
                )
                continue
        else:
            width = asset.get("coded_width")
            height = asset.get("coded_height")
            if (
                asset.get("audio_codec") != "aac"
                or asset.get("native_eligible") is not True
                or not isinstance(width, int)
                or isinstance(width, bool)
                or not isinstance(height, int)
                or isinstance(height, bool)
                or width <= 0
                or height <= 0
                or width > 1920
                or height > 1080
                or (
                    codec == "hevc"
                    and container in {"mp4", "mov"}
                    and asset.get("fourcc") != "hvc1"
                )
            ):
                metadata_errors.append(
                    f"artifact {index} is not a native-eligible <=1080p AAC corpus asset"
                )
                continue
        if artifact.get("_raw_evidence_eligible") is not True:
            metadata_errors.append(f"artifact {index} raw evidence is ineligible")
            continue
        clip_ids_by_variant.setdefault(variant, set()).add(asset_sha256)
        if phase == "startup":
            raw_provenance = artifact.get("process_provenance", {})
            app_values = [
                (int(pid), value)
                for pid, value in raw_provenance.items()
                if isinstance(value, Mapping) and value.get("role") == ROLE_APP
            ] if isinstance(raw_provenance, Mapping) else []
            if len(app_values) != 1:
                metadata_errors.append(
                    f"artifact {index} startup has no exact fresh app identity"
                )
                continue
            app_pid, app_value = app_values[0]
            startup_process_identities.append(
                (
                    app_pid,
                    int(app_value.get("expected_process_start_abstime", 0)),
                    str(app_value.get("expected_run_id", "")),
                )
            )
        trial_key = (phase, *variant, str(run))
        if trial_key in trial_keys:
            metadata_errors.append(f"duplicate trial identity {trial_key}")
            continue
        trial_keys.add(trial_key)
        if phase == FALLBACK_PHASE:
            fallback_matrix_count += 1
        else:
            native_matrix_counts[phase]["|".join(variant)] += 1

    if len(set(startup_process_identities)) != len(startup_process_identities):
        metadata_errors.append(
            "startup replicates reused a PID/process-start/run UUID instead of fresh launches"
        )
    for variant, clip_ids in clip_ids_by_variant.items():
        if len(clip_ids) != 1:
            metadata_errors.append(
                f"variant {variant} was not bound to one exact clip identity"
            )
    matrix_complete = not metadata_errors and not evidence_errors and all(
        native_matrix_counts[phase]["|".join(variant)] == REQUIRED_REPLICATES[phase]
        for phase in REQUIRED_REPLICATES
        for variant in REQUIRED_VARIANTS
    ) and fallback_matrix_count == DEFAULT_FALLBACK_RUNS

    native_artifacts = [
        artifact
        for phase in REQUIRED_REPLICATES
        for artifact in phases[phase]
    ]
    native_reports = [
        artifact["native_telemetry"]
        for artifact in native_artifacts
        if isinstance(artifact.get("native_telemetry"), Mapping)
    ]
    routes = [
        report.get("native_proof", {}).get("route") for report in native_reports
    ]
    native_proof_all = (
        len(native_reports) == len(native_artifacts)
        and all(
            report.get("native_proof", {}).get("eligible") is True
            for report in native_reports
        )
    )
    startup_reports = [
        artifact["native_telemetry"]
        for artifact in phases["startup"]
        if isinstance(artifact.get("native_telemetry"), Mapping)
    ]
    startup_external = [
        value
        for report in startup_reports
        for value in report.get("startup", {})
        .get("measurements", {})
        .get("external_request_to_first_visible_frame_ms", ())
    ]
    startup_internal = [
        value
        for report in startup_reports
        for value in report.get("startup", {})
        .get("measurements", {})
        .get("open_to_first_visible_frame_ms", ())
    ]
    startup_warm = [
        value
        for report in startup_reports
        for value in report.get("startup", {})
        .get("measurements", {})
        .get("warm_open_to_first_visible_frame_ms", ())
    ]
    startup_warm_by_variant: dict[str, list[float]] = {
        "|".join(variant): [] for variant in REQUIRED_VARIANTS
    }
    startup_cold_by_variant: dict[str, list[float]] = {
        "|".join(variant): [] for variant in REQUIRED_VARIANTS
    }
    for artifact in phases["startup"]:
        metadata = artifact.get("metadata", {})
        report = artifact.get("native_telemetry", {})
        if not isinstance(metadata, Mapping) or not isinstance(report, Mapping):
            continue
        codec = metadata.get("codec")
        container = metadata.get("container")
        profile = metadata.get("profile") or ("any" if codec == "h264" else None)
        key = "|".join(str(value) for value in (codec, container, profile))
        if key not in startup_warm_by_variant:
            continue
        startup_values = report.get("startup", {}).get("measurements", {})
        startup_warm_by_variant[key].extend(
            float(value)
            for value in startup_values.get("warm_open_to_first_visible_frame_ms", ())
        )
        startup_cold_by_variant[key].extend(
            float(value)
            for value in startup_values.get(
                "external_request_to_first_visible_frame_ms", ()
            )
        )

    steady_cpu_means = [
        artifact.get("summary", {}).get("cpu_percent", {}).get("time_weighted_mean")
        for artifact in phases["steady"]
    ]
    steady_cpu_means = [value for value in steady_cpu_means if value is not None]
    scrub_cpu_means = [
        artifact.get("summary", {}).get("cpu_percent", {}).get("time_weighted_mean")
        for artifact in phases["scrub"]
    ]
    scrub_cpu_means = [value for value in scrub_cpu_means if value is not None]
    sampled_memory_peak_values = [
        artifact.get("summary", {}).get("memory", {}).get("hard_gate_peak_bytes")
        for artifact in artifacts
        if artifact.get("kind") == "process_samples"
    ]
    sampled_memory_peaks = [
        value for value in sampled_memory_peak_values if value is not None
    ]
    memory_complete = (
        len(sampled_memory_peak_values) == len(artifacts)
        and all(value is not None for value in sampled_memory_peak_values)
        and all(
            artifact.get("summary", {}).get("eligible") is True
            for artifact in artifacts
        )
    )

    scrub_reports = [
        artifact.get("native_telemetry", {}).get("scrub", {})
        for artifact in phases["scrub"]
        if isinstance(artifact.get("native_telemetry", {}).get("scrub"), Mapping)
    ]
    scrub_measurement_names = (
        "request_to_admit_ms",
        "request_to_draw_ms",
        "admit_to_draw_ms",
        "visible_frame_cadence_ms",
        "target_error_ms",
        "request_to_failure_ms",
        "commit_to_draw_ms",
    )
    scrub_measurements = {
        name: [
            value
            for report in scrub_reports
            for value in report.get("measurements", {}).get(name, ())
        ]
        for name in scrub_measurement_names
    }

    steady_cpu_distribution = distribution(steady_cpu_means)
    memory_distribution = distribution(sampled_memory_peaks)
    native_all = (
        bool(native_artifacts)
        and native_proof_all
        and all(route == "native" for route in routes)
    )
    startup_complete = (
        matrix_complete
        and len(startup_external) == len(phases["startup"])
        and len(startup_warm) == len(phases["startup"])
        and all(
            report.get("startup", {}).get("warm_open", {}).get("eligible") is True
            for report in startup_reports
        )
        and native_all
    )
    steady_complete = (
        matrix_complete
        and len(steady_cpu_means) == len(phases["steady"])
        and all(artifact.get("summary", {}).get("eligible") is True for artifact in phases["steady"])
    )
    scrub_complete = (
        matrix_complete
        and len(scrub_reports) == len(phases["scrub"])
        and all(report.get("eligible") is True for report in scrub_reports)
    )
    fallback_reports = [
        artifact.get("fallback_control", {})
        for artifact in phases[FALLBACK_PHASE]
        if isinstance(artifact.get("fallback_control"), Mapping)
    ]
    fallback_complete = (
        len(fallback_reports) == DEFAULT_FALLBACK_RUNS
        and all(report.get("eligible") is True for report in fallback_reports)
    )
    cpu_pass = (
        steady_cpu_distribution["p50"] < DEFAULT_CPU_LIMIT_PERCENT
        if steady_cpu_distribution["p50"] is not None
        else False
    )
    memory_pass = memory_complete and all(
        float(value) < DEFAULT_MEMORY_LIMIT_BYTES for value in sampled_memory_peaks
    )
    cold_start_distribution = distribution(startup_external)
    warm_open_distribution = distribution(startup_warm)
    cold_start_latency_pass = (
        cold_start_distribution["p95"] is not None
        and cold_start_distribution["max"] is not None
        and float(cold_start_distribution["p95"]) <= MAX_STARTUP_P95_MS
        and float(cold_start_distribution["max"]) <= MAX_STARTUP_SINGLE_MS
    )
    warm_open_latency_pass = (
        warm_open_distribution["p95"] is not None
        and warm_open_distribution["max"] is not None
        and float(warm_open_distribution["p95"]) <= MAX_WARM_OPEN_P95_MS
        and float(warm_open_distribution["max"]) <= MAX_WARM_OPEN_SINGLE_MS
    )
    cold_start_variant_distributions = {
        key: distribution(values) for key, values in startup_cold_by_variant.items()
    }
    warm_open_variant_distributions = {
        key: distribution(values) for key, values in startup_warm_by_variant.items()
    }
    cold_start_per_variant_pass = all(
        measured["count"] == REQUIRED_REPLICATES["startup"]
        and measured["p95"] is not None
        and measured["max"] is not None
        and float(measured["p95"]) <= MAX_STARTUP_P95_MS
        and float(measured["max"]) <= MAX_STARTUP_SINGLE_MS
        for measured in cold_start_variant_distributions.values()
    )
    warm_open_per_variant_pass = all(
        measured["count"] == REQUIRED_REPLICATES["startup"]
        and measured["p95"] is not None
        and measured["max"] is not None
        and float(measured["p95"]) <= MAX_WARM_OPEN_P95_MS
        and float(measured["max"]) <= MAX_WARM_OPEN_SINGLE_MS
        for measured in warm_open_variant_distributions.values()
    )
    gates = {
        "native_route_all_telemetry_trials": native_all,
        "required_variant_replicate_matrix_complete": matrix_complete,
        "startup_replicates_complete": startup_complete,
        "cold_external_launch_release_ceiling": (
            cold_start_latency_pass and cold_start_per_variant_pass
        ),
        "warm_in_process_open_loading_goal": (
            warm_open_latency_pass and warm_open_per_variant_pass
        ),
        "steady_replicates_complete": steady_complete,
        "scrub_replicates_complete": scrub_complete,
        "fallback_loader_video_audio_control_complete": fallback_complete,
        "median_steady_run_cpu_under_10_percent": cpu_pass,
        "all_sampled_memory_peaks_under_300_mib": memory_pass,
        # These independent proof layers are intentionally fail-closed until
        # each raw artifact has been validated and joined below.  Keeping the
        # gates explicit prevents legacy summary-only JSON from becoming ship
        # evidence as the richer capture protocol is staged.
        "immutable_candidate_and_asset_campaign_bound": False,
        "trusted_phase_metrics_bound": False,
        "native_memory_reconciliation_complete": False,
        "trusted_phase_specific_screen_evidence_complete": False,
    }
    return {
        "schema": SCHEMA,
        "kind": "shipping_summary",
        "created_at": utc_now(),
        "trial_counts": {name: len(values) for name, values in phases.items()},
        "evidence_errors": evidence_errors,
        "variant_matrix": {
            "required_native_replicates_per_variant": dict(REQUIRED_REPLICATES),
            "required_fallback_replicates": DEFAULT_FALLBACK_RUNS,
            "native_counts": native_matrix_counts,
            "fallback_count": fallback_matrix_count,
            "errors": [*metadata_errors, *evidence_errors],
        },
        "route_counts": {
            "native": routes.count("native"),
            "fallback": routes.count("fallback"),
            "unproven": len(routes) - routes.count("native") - routes.count("fallback"),
        },
        "startup": {
            "external_request_to_first_visible_frame_ms": cold_start_distribution,
            "open_to_first_visible_frame_ms": distribution(startup_internal),
            "warm_open_to_first_visible_frame_ms": warm_open_distribution,
            "external_request_to_first_visible_frame_ms_by_variant": (
                cold_start_variant_distributions
            ),
            "warm_open_to_first_visible_frame_ms_by_variant": (
                warm_open_variant_distributions
            ),
            "thresholds": {
                "cold_external_launch_p95_ms": MAX_STARTUP_P95_MS,
                "cold_external_launch_max_ms": MAX_STARTUP_SINGLE_MS,
                "warm_in_process_open_p95_ms": MAX_WARM_OPEN_P95_MS,
                "warm_in_process_open_max_ms": MAX_WARM_OPEN_SINGLE_MS,
            },
            "scope_note": (
                "cold external launch is a release ceiling; only the distinct "
                "second same-process open evaluates the imperceptible-loading goal"
            ),
        },
        "steady": {
            "per_run_time_weighted_cpu_percent": steady_cpu_distribution,
        },
        "memory": {"per_run_hard_gate_peak_bytes": memory_distribution},
        "scrub": {
            **{
                name: distribution(values)
                for name, values in scrub_measurements.items()
            },
            "per_run_time_weighted_cpu_percent": distribution(scrub_cpu_means),
            "per_run_hard_gate_peak_bytes": distribution(
                artifact.get("summary", {})
                .get("memory", {})
                .get("hard_gate_peak_bytes")
                for artifact in phases["scrub"]
            ),
        },
        "fallback_control": {
            "variant": "|".join(FALLBACK_VARIANT),
            "eligible_count": sum(
                report.get("eligible") is True for report in fallback_reports
            ),
        },
        "comparative_appendix": comparative_appendix,
        "gates": gates,
        "shipping_evidence_complete": all(gates.values()),
    }


def protocol_plan() -> dict[str, Any]:
    drag = build_drag_plan()
    return {
        "schema": SCHEMA,
        "kind": "protocol_plan",
        "created_at": utc_now(),
        "does_not_launch_or_generate_input": True,
        "corpus_requirements": {
            "duration": "long enough to cover warm-up plus every measured phase",
            "maximum_coded_dimensions": "1920x1080 until the native hard cap changes",
            "audio": "AAC where the container supports it",
            "required_variants": [
                {
                    "codec": codec,
                    "container": container,
                    "profile": profile,
                    **(
                        {"fourcc": "hvc1"}
                        if codec == "hevc" and container in {"mp4", "mov"}
                        else {}
                    ),
                }
                for codec, container, profile in REQUIRED_VARIANTS
            ],
            "required_fallback_control": {
                "codec": FALLBACK_VARIANT[0],
                "container": FALLBACK_VARIANT[1],
                "audio": "opus",
                "must_be_unsupported_by_native": True,
                "must_be_packaged_in_staged_bundle": True,
            },
        },
        "phases": {
            "startup": {
                "replicates_per_variant": DEFAULT_STARTUP_RUNS,
                "fresh_process_each_replicate": True,
                "metrics": [
                    "LaunchServices request to exact first visible native frame",
                    "in-process open request to exact first visible native frame",
                ],
            },
            "steady": {
                "replicates_per_variant": DEFAULT_STEADY_RUNS,
                "warmup_s": DEFAULT_STEADY_WARMUP_S,
                "measure_s": DEFAULT_STEADY_DURATION_S,
                "sample_interval_s": DEFAULT_SAMPLE_INTERVAL_S,
                "metrics": [
                    "time-weighted aggregate CPU for app plus attributed decoder helpers",
                    "synchronized resident and physical footprint",
                    "conservative sum of per-process lifetime footprint maxima",
                ],
            },
            "scrub": {
                "replicates_per_variant": DEFAULT_SCRUB_RUNS,
                "input_rate_hz": DEFAULT_DRAG_RATE_HZ,
                "directions": ["forward", "reverse"],
                "metrics": [
                    "request to exact visible frame completion",
                    "visible frame cadence and maximum gap",
                    "target-time error and commit-to-draw completion",
                    "CPU and memory during drag",
                ],
            },
            FALLBACK_PHASE: {
                "replicates": DEFAULT_FALLBACK_RUNS,
                "measure_s": DEFAULT_FALLBACK_DURATION_S,
                "screen_backed": True,
                "verify_runtime_is_evidence": False,
                "metrics": [
                    "exact fallback route selection with no native ambiguity",
                    "WAMMpvFallback.dylib lazy-load in the bound WAM process",
                    "first visible fallback frame",
                    "active and audible Opus audio",
                    "CPU and memory for the complete fallback process set",
                ],
            },
        },
        "hard_gates": {
            "route": "native proof for every trial; any fallback_selected invalidates",
            "libmpv": "must remain uninitialized in the native lineage",
            "cold_external_launch_latency": (
                "release ceiling only: p95 <= 750 ms and every run <= 1500 ms"
            ),
            "warm_in_process_open_latency": (
                "loading goal: distinct second same-PID open p95 <= 100 ms and "
                "every run <= 200 ms"
            ),
            "cold_external_launch_cpu": (
                "transient-complete coalition CPU time p95 <= 250 ms and every "
                "run <= 500 ms; normalized average is reported separately"
            ),
            "warm_in_process_open_cpu": (
                "every run < 10 percent of one core and <= 25 ms coalition CPU time"
            ),
            "steady_cpu": "every per-variant run time-weighted mean < 10 percent",
            "scrub_cpu": (
                "every native variant and leg < 10 percent; every conservative "
                "250 ms rolling window <= 25 percent"
            ),
            "scrub_visible_quality": (
                "latest demand p95/max <= 100/250 ms; boundary-inclusive visible "
                "gap <= 50/100 ms; commit <= 150/300 ms; target error <= 50/100 ms"
            ),
            "scrub_draw_coverage": (
                ">= 80 percent of min(bound source FPS, 30 FPS) across each real 4 s leg"
            ),
            "memory": (
                "every conservative coalition peak < 300 MiB and native allocation "
                "reconciliation complete for the same phase epoch"
            ),
            "fallback_control": (
                "real staged-bundle VP9/WebM+Opus screen run; --verify-runtime "
                "is explicitly ineligible"
            ),
        },
        "comparative_appendix": {
            "gating": False,
            "full_app_pairs": {
                "arms": ["native_wam", "bundled_fallback_wam"],
                "required_same_inputs": [
                    "exact asset SHA-256 and byte length",
                    "H.264/HEVC codec/container",
                    "VideoToolbox-required hardware policy",
                    "window, rate, duration, audio, and visible-output workload",
                ],
                "reported_only_when_comparable": [
                    "LaunchServices request to first visible frame",
                    "time-weighted app-plus-helper coalition CPU",
                    "conservative app-plus-helper RSS/footprint peak",
                ],
                "note": (
                    "diagnoses native versus the bundled libmpv/FFmpeg path; "
                    "never contributes to shipping_evidence_complete"
                ),
            },
            "optional_ffmpeg_lab": {
                "mode": "ffmpeg_videotoolbox_decode_null",
                "gating": False,
                "scope": (
                    "decode-to-null only; explicitly excludes full-player launch, "
                    "render/presentation, controls, and audio semantics"
                ),
            },
        },
        "drag_schedule": {
            "driver_status": "schedule only; no system input sink is present",
            "event_count": len(drag),
            "duration_s": drag[-1].offset_ns / 1_000_000_000.0,
            "events": [step.as_dict() for step in drag],
        },
    }


def _write_json(value: Mapping[str, Any], output: Path | None) -> None:
    rendered = json.dumps(value, indent=2, sort_keys=True, allow_nan=False) + "\n"
    if output is None:
        sys.stdout.write(rendered)
        return
    output.parent.mkdir(parents=True, exist_ok=True)
    try:
        with output.open("x", encoding="utf-8") as stream:
            stream.write(rendered)
    except FileExistsError as error:
        raise ShipperError(f"refusing to overwrite existing output: {output}") from error


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Headless support for WAM's macOS whole-app shipping proof"
    )
    commands = parser.add_subparsers(dest="command", required=True)

    plan = commands.add_parser("plan", help="emit the fixed protocol without launching anything")
    plan.add_argument("--output", type=Path)

    sample = commands.add_parser("sample", help="sample already-running exact PIDs")
    sample.add_argument(
        "--process",
        action="append",
        type=_process_spec,
        required=True,
        metavar="PID:ROLE:COALITION_ID",
        help="exact app/helper PID with caller-verified resource coalition",
    )
    sample.add_argument(
        "--wam-executable",
        required=True,
        type=Path,
        help="canonical staged WAM.app executable path",
    )
    sample.add_argument("--expected-run-id", required=True)
    sample.add_argument(
        "--expected-process-start-abstime", required=True, type=int
    )
    sample.add_argument(
        "--phase",
        choices=("startup", "steady", "scrub", FALLBACK_PHASE),
        required=True,
    )
    sample.add_argument("--duration", type=_finite_positive, required=True)
    sample.add_argument("--telemetry", type=Path)
    sample.add_argument("--launch-request-monotonic-ns", type=int)
    sample.add_argument("--warmup-s", type=_finite_positive)
    sample.add_argument("--warmup-evidence", type=Path)
    sample.add_argument("--drag-evidence", type=Path)
    sample.add_argument("--fallback-evidence", type=Path)
    sample.add_argument("--label")
    sample.add_argument("--codec")
    sample.add_argument("--container")
    sample.add_argument("--profile")
    sample.add_argument("--clip-id")
    sample.add_argument("--clip-duration-s", type=_finite_positive)
    sample.add_argument("--asset-evidence", type=Path)
    sample.add_argument("--run")
    sample.add_argument("--output", required=True, type=Path)

    summarize = commands.add_parser("summarize", help="aggregate saved sample artifacts")
    summarize.add_argument("inputs", nargs="+", type=Path)
    summarize.add_argument("--output", type=Path)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        if args.command == "plan":
            _write_json(protocol_plan(), args.output)
            return 0
        if args.command == "sample":
            pids, process_provenance = capture_process_provenance(
                args.process,
                args.wam_executable.expanduser().resolve(strict=True),
                expected_run_id=args.expected_run_id,
                expected_process_start_abstime=args.expected_process_start_abstime,
            )
            artifact = sample_processes(
                pids,
                duration_s=args.duration,
                interval_s=DEFAULT_SAMPLE_INTERVAL_S,
                phase=args.phase,
                process_provenance=process_provenance,
            )
            artifact["metadata"] = {
                key: value
                for key, value in {
                    "label": args.label,
                    "codec": args.codec,
                    "container": args.container,
                    "profile": args.profile,
                    "clip_id": args.clip_id,
                    "clip_duration_s": args.clip_duration_s,
                    "run": args.run,
                    "warmup_s": args.warmup_s,
                }.items()
                if value is not None
            }
            if args.asset_evidence is not None:
                asset_evidence = json.loads(
                    args.asset_evidence.read_text(encoding="utf-8")
                )
                if not isinstance(asset_evidence, Mapping):
                    raise ShipperError("asset evidence must contain a JSON object")
                artifact["metadata"]["asset"] = dict(asset_evidence)
            if args.drag_evidence is not None:
                drag_evidence = json.loads(
                    args.drag_evidence.read_text(encoding="utf-8")
                )
                if not isinstance(drag_evidence, Mapping):
                    raise ShipperError("drag evidence must contain a JSON object")
                artifact["drag_schedule_evidence"] = dict(drag_evidence)
            if args.warmup_evidence is not None:
                warmup_evidence = json.loads(
                    args.warmup_evidence.read_text(encoding="utf-8")
                )
                if not isinstance(warmup_evidence, Mapping):
                    raise ShipperError("warm-up evidence must contain a JSON object")
                artifact["warmup_evidence"] = dict(warmup_evidence)
            if args.fallback_evidence is not None:
                fallback_evidence = json.loads(
                    args.fallback_evidence.read_text(encoding="utf-8")
                )
                if not isinstance(fallback_evidence, Mapping):
                    raise ShipperError("fallback evidence must contain a JSON object")
                artifact["fallback_control"] = dict(fallback_evidence)
            if args.telemetry is not None:
                asset_metadata = artifact.get("metadata", {}).get("asset")
                expected_asset_sha256 = (
                    asset_metadata.get("sha256")
                    if isinstance(asset_metadata, Mapping)
                    else None
                )
                if (
                    not isinstance(expected_asset_sha256, str)
                    or re.fullmatch(r"[0-9a-f]{64}", expected_asset_sha256) is None
                ):
                    raise ShipperError(
                        "telemetry attachment requires an exact lowercase asset SHA-256"
                    )
                attach_telemetry(
                    artifact,
                    args.telemetry,
                    args.launch_request_monotonic_ns,
                    args.expected_run_id,
                    next(
                        pid
                        for pid, value in process_provenance.items()
                        if value["role"] == ROLE_APP
                    ),
                    args.expected_process_start_abstime,
                    expected_asset_sha256,
                )
            _write_json(artifact, args.output)
            return 0
        artifacts = [_read_json(path) for path in args.inputs]
        _write_json(summarize_artifacts(artifacts), args.output)
        return 0
    except (ShipperError, ValueError, OSError, run_suite.SuiteError) as error:
        print(f"run_shipper.py: {error}", file=sys.stderr)
        return 2
    except KeyboardInterrupt:
        print("run_shipper.py: sampling interrupted", file=sys.stderr)
        return 130


if __name__ == "__main__":
    raise SystemExit(main())
