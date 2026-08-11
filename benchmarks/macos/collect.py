#!/usr/bin/env python3
"""Collect reproducible macOS playback performance measurements.

This tool deliberately does not launch or control a media player. Start playback,
find the player process ID(s), and then point the collector at those processes.
Only Python's standard library and macOS system tools are used.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import math
import os
import platform
import plistlib
import re
import statistics
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Any, Iterable, Mapping, Sequence


SCHEMA = "wam.macos.benchmark.v1"
TOP_CPU_RE = re.compile(
    r"CPU usage:\s*([\d.]+)%\s*user,\s*([\d.]+)%\s*sys,\s*([\d.]+)%\s*idle",
    re.IGNORECASE,
)
TOP_TIME_RE = re.compile(r"^\d{4}/\d{2}/\d{2}\s+\d{2}:\d{2}:\d{2}\s*$")
TOP_TIME_FORMAT = "%Y/%m/%d %H:%M:%S"
PID_RE = re.compile(r"\bpid\s+(\d+)\b", re.IGNORECASE)
GPU_KEYS = (
    "Device Utilization %",
    "Renderer Utilization %",
    "Tiler Utilization %",
)
TOP_HEADER_ALIASES = {
    "%CPU": "cpu_percent",
    "CPU": "cpu_percent",
    "MEM": "memory_bytes",
    "POWER": "top_power_score",
    "#TH": "thread_count",
    "TH": "thread_count",
    "THREADS": "thread_count",
    "#PORTS": "port_count",
    "PORTS": "port_count",
    "PRT": "port_count",
    "CSW": "context_switch_count",
    "FAULT": "fault_count",
    "FAULTS": "fault_count",
    "PAGEINS": "pagein_count",
    "PURG": "purgeable_bytes",
}
TOP_GAUGE_FIELDS = (
    "memory_bytes",
    "top_power_score",
    "thread_count",
    "running_thread_count",
    "port_count",
    "purgeable_bytes",
)
TOP_COUNTER_FIELDS = (
    "context_switch_count",
    "fault_count",
    "pagein_count",
)


def _number(value: Any) -> float | None:
    """Return a finite float for plist/text numeric values."""

    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        result = float(value)
    elif isinstance(value, (bytes, bytearray)):
        try:
            result = float(value.decode("ascii").strip().rstrip("%"))
        except (UnicodeDecodeError, ValueError):
            return None
    elif isinstance(value, str):
        try:
            result = float(value.strip().rstrip("%"))
        except ValueError:
            return None
    else:
        return None
    return result if math.isfinite(result) else None


def parse_byte_size(value: str) -> int | None:
    """Parse the compact byte sizes emitted by macOS top."""

    # In delta mode top appends + or - to MEM when the footprint changed since
    # the prior sample. The marker describes direction; it is not a sign.
    text = value.strip().replace(",", "").rstrip("+-")
    if not text or text.upper() in {"-", "N/A", "NA"}:
        return None
    match = re.fullmatch(r"([\d.]+)\s*([BKMGTPE]?)", text, re.IGNORECASE)
    if not match:
        return None
    amount = float(match.group(1))
    exponent = "BKMGTPE".index((match.group(2) or "B").upper())
    return int(round(amount * (1024**exponent)))


def parse_count(value: str) -> int | None:
    """Parse a compact integer counter emitted by top.

    In non-event mode, top suffixes changed counters with ``+`` or ``-``.
    Those are direction markers, not arithmetic signs. A leading minus sign
    is retained so this helper also parses diagnostic delta-mode fixtures.
    """

    text = value.strip().replace(",", "")
    if len(text) > 1 and text[-1] in "+-":
        text = text[:-1]
    if not text or text.upper() in {"-", "N/A", "NA"}:
        return None
    match = re.fullmatch(r"(-?[\d.]+)\s*([KMGTPE]?)", text, re.IGNORECASE)
    if not match:
        return None
    amount = float(match.group(1))
    exponent = "KMGTPE".find(match.group(2).upper()) + 1 if match.group(2) else 0
    return int(round(amount * (1000**exponent)))


def parse_thread_count(value: str) -> tuple[int | None, int | None]:
    """Return total/running threads from top's ``#TH`` field."""

    text = value.strip()
    if len(text) > 1 and text[-1] in "+-":
        text = text[:-1]
    total_text, separator, running_text = text.partition("/")
    total = parse_count(total_text)
    running = parse_count(running_text) if separator else (0 if total is not None else None)
    return total, running


def percentile(values: Sequence[float], quantile: float) -> float | None:
    """Linear-interpolated percentile, matching common analytics tools."""

    if not values:
        return None
    ordered = sorted(float(value) for value in values)
    if len(ordered) == 1:
        return ordered[0]
    position = (len(ordered) - 1) * quantile
    lower = math.floor(position)
    upper = math.ceil(position)
    if lower == upper:
        return ordered[lower]
    fraction = position - lower
    return ordered[lower] + (ordered[upper] - ordered[lower]) * fraction


def metric_summary(values: Iterable[float | int | None]) -> dict[str, float | int | None]:
    """Summarize valid samples while retaining an explicit sample count."""

    valid = [float(value) for value in values if value is not None and math.isfinite(float(value))]
    if not valid:
        return {"count": 0, "mean": None, "median": None, "p95": None, "max": None}
    return {
        "count": len(valid),
        "mean": statistics.fmean(valid),
        "median": statistics.median(valid),
        "p95": percentile(valid, 0.95),
        "max": max(valid),
    }


def _time_weighted_summary(
    values: Sequence[float | int | None],
    elapsed_times: Sequence[float] | None,
    *,
    interval_ending: bool,
) -> dict[str, Any]:
    """Summarize samples, replacing the arithmetic mean when time data is complete.

    CPU-like values describe the interval ending at each sample. Instantaneous
    gauges use trapezoidal integration between adjacent samples. Distribution
    statistics intentionally remain sample-based, and the original arithmetic
    mean is retained whenever a time-weighted mean is available.
    """

    summary: dict[str, Any] = metric_summary(values)
    if elapsed_times is None or len(values) != len(elapsed_times) or len(values) < 2:
        return summary

    weighted_sum = 0.0
    weighted_elapsed = 0.0
    weighted_intervals = 0
    for index in range(1, len(values)):
        duration = elapsed_times[index] - elapsed_times[index - 1]
        if not math.isfinite(duration) or duration <= 0:
            return summary
        current = _number(values[index])
        previous = _number(values[index - 1])
        if interval_ending:
            if current is None:
                continue
            interval_value = current
        else:
            if current is None or previous is None:
                continue
            interval_value = (previous + current) / 2.0
        weighted_sum += interval_value * duration
        weighted_elapsed += duration
        weighted_intervals += 1

    if weighted_elapsed <= 0:
        return summary
    summary["arithmetic_mean"] = summary["mean"]
    summary["mean"] = weighted_sum / weighted_elapsed
    summary["mean_method"] = (
        "time_weighted_interval_ending"
        if interval_ending
        else "time_weighted_trapezoidal"
    )
    summary["mean_elapsed_s"] = weighted_elapsed
    summary["mean_interval_count"] = weighted_intervals
    return summary


def _top_elapsed_times(samples: Sequence[Mapping[str, Any]]) -> list[float] | None:
    """Return strictly increasing seconds relative to the first top timestamp."""

    parsed: list[dt.datetime] = []
    for sample in samples:
        timestamp = sample.get("timestamp")
        if not isinstance(timestamp, str):
            return None
        try:
            parsed.append(dt.datetime.strptime(timestamp.strip(), TOP_TIME_FORMAT))
        except ValueError:
            return None
    if not parsed:
        return None
    origin = parsed[0]
    elapsed = [(timestamp - origin).total_seconds() for timestamp in parsed]
    if any(current <= previous for previous, current in zip(elapsed, elapsed[1:])):
        return None
    return elapsed


def _elapsed_measurement(
    elapsed_times: Sequence[float] | None,
    sample_count: int,
    source: str,
) -> dict[str, Any]:
    elapsed = (
        elapsed_times[-1] - elapsed_times[0]
        if elapsed_times is not None and len(elapsed_times) >= 2
        else None
    )
    return {
        "elapsed_s": elapsed,
        "sample_count": sample_count,
        "timestamped_sample_count": len(elapsed_times) if elapsed_times is not None else 0,
        "source": source if elapsed is not None else None,
    }


def _rate_per_second(total: float | int | None, elapsed_s: float | None) -> float | None:
    if total is None or elapsed_s is None or elapsed_s <= 0:
        return None
    return float(total) / elapsed_s


def _new_top_sample(sequence: int) -> dict[str, Any]:
    return {"sequence": sequence, "timestamp": None, "system_cpu": None, "processes": []}


def parse_top_output(raw: str, target_pids: Iterable[int] | None = None) -> list[dict[str, Any]]:
    """Parse logging-mode output from Apple's top.

    The requested column order is fixed, but COMMAND can contain spaces. Rows
    are therefore parsed from their numeric columns at the right-hand side.
    """

    targets = set(target_pids) if target_pids is not None else None
    samples: list[dict[str, Any]] = []
    current: dict[str, Any] | None = None
    row_columns: list[str] = []
    in_rows = False

    for line in raw.splitlines():
        if line.startswith("Processes:"):
            if current is not None:
                samples.append(current)
            current = _new_top_sample(len(samples))
            row_columns = []
            in_rows = False
            continue
        if current is None:
            continue

        stripped = line.strip()
        if TOP_TIME_RE.match(stripped):
            current["timestamp"] = stripped
            continue
        cpu_match = TOP_CPU_RE.search(line)
        if cpu_match:
            user, system, idle = (float(cpu_match.group(index)) for index in range(1, 4))
            current["system_cpu"] = {
                "user_percent": user,
                "system_percent": system,
                "idle_percent": idle,
                "active_percent": user + system,
            }
            continue

        header_tokens = stripped.upper().split()
        if header_tokens[:2] == ["PID", "COMMAND"] and any(
            token in {"%CPU", "CPU"} for token in header_tokens[2:]
        ):
            row_columns = header_tokens
            current["columns"] = [
                token.lower().replace("%", "").lstrip("#") for token in header_tokens
            ]
            in_rows = True
            continue
        if not in_rows or not stripped:
            continue

        tokens = stripped.split()
        value_count = len(row_columns) - 2
        if value_count < 1 or len(tokens) < value_count + 2:
            continue
        pid_match = re.fullmatch(r"(\d+)[+*\-]?", tokens[0])
        if not pid_match:
            continue
        pid = int(pid_match.group(1))
        if targets is not None and pid not in targets:
            continue
        values = tokens[-value_count:]
        command = " ".join(tokens[1:-value_count]).strip()
        if not command:
            continue
        process: dict[str, Any] = {
            "pid": pid,
            "command": command,
            "cpu_percent": None,
            "memory_bytes": None,
            # POWER is Apple's unitless top score, not a measurement in watts.
            "top_power_score": None,
            "thread_count": None,
            "running_thread_count": None,
            "port_count": None,
            "context_switch_count": None,
            "fault_count": None,
            "pagein_count": None,
            "purgeable_bytes": None,
        }
        for header, value in zip(row_columns[2:], values):
            field = TOP_HEADER_ALIASES.get(header)
            if field == "cpu_percent" or field == "top_power_score":
                process[field] = _number(value)
            elif field in {"memory_bytes", "purgeable_bytes"}:
                process[field] = parse_byte_size(value)
            elif field == "thread_count":
                process["thread_count"], process["running_thread_count"] = parse_thread_count(value)
            elif field is not None:
                process[field] = parse_count(value)
        current["processes"].append(process)

    if current is not None:
        samples.append(current)
    return samples


def _process_for_pid(sample: Mapping[str, Any], pid: int) -> Mapping[str, Any] | None:
    for process in sample.get("processes", []):
        if process.get("pid") == pid:
            return process
    return None


def summarize_top(samples: Sequence[Mapping[str, Any]], pids: Sequence[int]) -> dict[str, Any]:
    """Build per-process and aggregate summaries from parsed top samples."""

    elapsed_times = _top_elapsed_times(samples)
    measurement = _elapsed_measurement(elapsed_times, len(samples), "top wall-clock timestamps")
    measurement_elapsed = measurement["elapsed_s"]
    by_pid: dict[str, Any] = {}
    for pid in pids:
        rows = [_process_for_pid(sample, pid) for sample in samples]
        cpu_values = [
            None
            if index == 0 or row is None
            else row.get("cpu_percent")
            for index, row in enumerate(rows)
        ]
        process_summary = {
            "cpu_percent": _time_weighted_summary(
                cpu_values,
                elapsed_times,
                interval_ending=True,
            ),
        }
        process_summary.update(
            {
                field: _time_weighted_summary(
                    [row.get(field) if row is not None else None for row in rows],
                    elapsed_times,
                    interval_ending=False,
                )
                for field in TOP_GAUGE_FIELDS
            }
        )
        for field in TOP_COUNTER_FIELDS:
            deltas: list[int] = []
            for index in range(1, len(samples)):
                row = _process_for_pid(samples[index], pid)
                prior = _process_for_pid(samples[index - 1], pid)
                if row is None or prior is None:
                    continue
                current_value = row.get(field)
                previous = prior.get(field)
                if current_value is not None and previous is not None and current_value >= previous:
                    deltas.append(int(current_value - previous))
            process_summary[f"{field}_delta"] = metric_summary(deltas)
            process_summary[f"total_{field}_delta"] = sum(deltas) if deltas else None
            process_summary[f"{field}_rate_per_s"] = _rate_per_second(
                process_summary[f"total_{field}_delta"], measurement_elapsed
            )
        by_pid[str(pid)] = process_summary

    aggregate_cpu: list[float | None] = []
    aggregate_gauges: dict[str, list[float | None]] = {
        field: [] for field in TOP_GAUGE_FIELDS
    }
    aggregate_deltas: dict[str, list[float]] = {field: [] for field in TOP_COUNTER_FIELDS}
    for index, sample in enumerate(samples):
        rows = [row for pid in pids if (row := _process_for_pid(sample, pid)) is not None]
        cpu_values = [float(row["cpu_percent"]) for row in rows if row.get("cpu_percent") is not None]
        aggregate_cpu.append(sum(cpu_values) if cpu_values and index > 0 else None)
        for field in TOP_GAUGE_FIELDS:
            values = [float(row[field]) for row in rows if row.get(field) is not None]
            aggregate_gauges[field].append(sum(values) if values else None)
        if index > 0:
            prior_sample = samples[index - 1]
            for field in TOP_COUNTER_FIELDS:
                deltas = []
                for pid in pids:
                    row = _process_for_pid(sample, pid)
                    prior = _process_for_pid(prior_sample, pid)
                    if row is None or prior is None:
                        continue
                    value = row.get(field)
                    prior_value = prior.get(field)
                    if value is not None and prior_value is not None and value >= prior_value:
                        deltas.append(float(value - prior_value))
                if deltas:
                    aggregate_deltas[field].append(sum(deltas))

    system_summary = {
        field: _time_weighted_summary(
            [
                sample.get("system_cpu", {}).get(field)
                if index > 0 and isinstance(sample.get("system_cpu"), Mapping)
                else None
                for index, sample in enumerate(samples)
            ],
            elapsed_times,
            interval_ending=True,
        )
        for field in ("user_percent", "system_percent", "idle_percent", "active_percent")
    }
    aggregate_counter_totals = {
        field: sum(values) if values else None for field, values in aggregate_deltas.items()
    }
    return {
        "warmup_policy": (
            "The first top CPU sample is discarded. Cumulative event counters use it only as "
            "a delta baseline; memory, POWER, thread, port, and purgeable-memory gauges retain it."
        ),
        "mean_policy": (
            "CPU and system CPU means weight each interval-ending sample by the preceding "
            "timestamp interval. Gauge means use trapezoidal time integration. If a complete, "
            "strictly increasing top timestamp series is unavailable, means fall back to "
            "arithmetic sample means. Medians, p95 values, and maxima remain sample-based."
        ),
        "counter_policy": (
            "Counter totals are raw sums of nonnegative adjacent deltas. Rates divide those "
            "totals by the actual first-to-last top timestamp span, never requested duration."
        ),
        "measurement": measurement,
        "processes": by_pid,
        "aggregate": {
            "cpu_percent": _time_weighted_summary(
                aggregate_cpu, elapsed_times, interval_ending=True
            ),
            **{
                field: _time_weighted_summary(
                    values, elapsed_times, interval_ending=False
                )
                for field, values in aggregate_gauges.items()
            },
            **{
                f"{field}_delta": metric_summary(values)
                for field, values in aggregate_deltas.items()
            },
            **{
                f"total_{field}_delta": total
                for field, total in aggregate_counter_totals.items()
            },
            **{
                f"{field}_rate_per_s": _rate_per_second(total, measurement_elapsed)
                for field, total in aggregate_counter_totals.items()
            },
        },
        "system_cpu": system_summary,
    }


def _walk(value: Any) -> Iterable[Mapping[str, Any]]:
    if isinstance(value, Mapping):
        yield value
        for child in value.values():
            yield from _walk(child)
    elif isinstance(value, (list, tuple)):
        for child in value:
            yield from _walk(child)


def _usage_total(value: Any) -> int | None:
    usages = value if isinstance(value, (list, tuple)) else [value]
    total = 0
    found = False
    for usage in usages:
        if not isinstance(usage, Mapping):
            continue
        amount = _number(usage.get("accumulatedGPUTime"))
        if amount is not None:
            total += int(amount)
            found = True
    return total if found else None


def parse_ioreg_object(root: Any, target_pids: Iterable[int] | None = None) -> dict[str, Any]:
    """Extract AGX utilization and per-PID accumulatedGPUTime from an ioreg plist."""

    targets = set(target_pids) if target_pids is not None else None
    per_pid: dict[int, int] = {}
    devices: list[dict[str, Any]] = []

    for node in _walk(root):
        performance = node.get("PerformanceStatistics")
        if isinstance(performance, Mapping):
            metrics = {key: _number(performance.get(key)) for key in GPU_KEYS}
            if any(value is not None for value in metrics.values()):
                devices.append(
                    {
                        "name": node.get("IORegistryEntryName") or node.get("IOClass") or "IOAccelerator",
                        "device_utilization_percent": metrics["Device Utilization %"],
                        "renderer_utilization_percent": metrics["Renderer Utilization %"],
                        "tiler_utilization_percent": metrics["Tiler Utilization %"],
                    }
                )

        creator = node.get("IOUserClientCreator")
        pid_match = PID_RE.search(str(creator)) if creator is not None else None
        if not pid_match or "AppUsage" not in node:
            continue
        pid = int(pid_match.group(1))
        if targets is not None and pid not in targets:
            continue
        total = _usage_total(node.get("AppUsage"))
        if total is not None:
            per_pid[pid] = per_pid.get(pid, 0) + total

    def device_max(field: str) -> float | None:
        values = [float(device[field]) for device in devices if device.get(field) is not None]
        return max(values) if values else None

    return {
        "devices": devices,
        "system": {
            "device_utilization_percent": device_max("device_utilization_percent"),
            "renderer_utilization_percent": device_max("renderer_utilization_percent"),
            "tiler_utilization_percent": device_max("tiler_utilization_percent"),
        },
        "per_pid_accumulated_gpu_time": {str(pid): value for pid, value in sorted(per_pid.items())},
    }


def parse_ioreg_plist(data: bytes, target_pids: Iterable[int] | None = None) -> dict[str, Any]:
    return parse_ioreg_object(plistlib.loads(data), target_pids)


def parse_ioreg_text(text: str, target_pids: Iterable[int] | None = None) -> dict[str, Any]:
    """Compatibility parser for macOS versions where ioreg -a is disabled."""

    targets = set(target_pids) if target_pids is not None else None
    device_values: dict[str, list[float]] = {key: [] for key in GPU_KEYS}
    for key in GPU_KEYS:
        for match in re.finditer(rf'"{re.escape(key)}"\s*=\s*([\d.]+)', text):
            device_values[key].append(float(match.group(1)))

    per_pid: dict[int, int] = {}
    starts = [match.start() for match in re.finditer(r"(?m)^.*\+-o AGXDeviceUserClient\b", text)]
    starts.append(len(text))
    for index in range(len(starts) - 1):
        block = text[starts[index] : starts[index + 1]]
        creator = PID_RE.search(block)
        if not creator:
            continue
        pid = int(creator.group(1))
        if targets is not None and pid not in targets:
            continue
        values = [int(value) for value in re.findall(r'"accumulatedGPUTime"\s*=\s*(\d+)', block)]
        if values:
            per_pid[pid] = per_pid.get(pid, 0) + sum(values)

    def maximum(key: str) -> float | None:
        return max(device_values[key]) if device_values[key] else None

    return {
        "devices": [],
        "system": {
            "device_utilization_percent": maximum("Device Utilization %"),
            "renderer_utilization_percent": maximum("Renderer Utilization %"),
            "tiler_utilization_percent": maximum("Tiler Utilization %"),
        },
        "per_pid_accumulated_gpu_time": {str(pid): value for pid, value in sorted(per_pid.items())},
    }


def add_gpu_deltas(samples: list[dict[str, Any]], pids: Sequence[int]) -> list[str]:
    """Add consecutive accumulatedGPUTime deltas in-place."""

    previous: dict[str, int] = {}
    warnings: list[str] = []
    for sample in samples:
        accumulated = sample.get("per_pid_accumulated_gpu_time", {})
        deltas: dict[str, int | None] = {}
        for pid in map(str, pids):
            current = accumulated.get(pid)
            prior = previous.get(pid)
            delta = None
            if current is not None and prior is not None:
                if current >= prior:
                    delta = int(current - prior)
                else:
                    warnings.append(
                        f"PID {pid} accumulatedGPUTime decreased; that interval was treated as a counter reset."
                    )
            deltas[pid] = delta
            if current is not None:
                previous[pid] = int(current)
        sample["per_pid_delta_accumulated_gpu_time"] = deltas
    return warnings


def summarize_gpu(samples: Sequence[Mapping[str, Any]], pids: Sequence[int]) -> dict[str, Any]:
    raw_elapsed = [_number(sample.get("elapsed_s")) for sample in samples]
    elapsed_times = (
        [float(value) for value in raw_elapsed if value is not None]
        if raw_elapsed and all(value is not None for value in raw_elapsed)
        else None
    )
    if elapsed_times is not None and any(
        current <= previous for previous, current in zip(elapsed_times, elapsed_times[1:])
    ):
        elapsed_times = None
    measurement = _elapsed_measurement(
        elapsed_times, len(samples), "collector monotonic ioreg sample timestamps"
    )
    measurement_elapsed = measurement["elapsed_s"]
    system = {
        field: _time_weighted_summary(
            [sample.get("system", {}).get(field) for sample in samples],
            elapsed_times,
            interval_ending=False,
        )
        for field in (
            "device_utilization_percent",
            "renderer_utilization_percent",
            "tiler_utilization_percent",
        )
    }
    per_pid: dict[str, Any] = {}
    all_deltas: list[float] = []
    for pid in map(str, pids):
        deltas = [
            sample.get("per_pid_delta_accumulated_gpu_time", {}).get(pid)
            for sample in samples
        ]
        valid = [float(value) for value in deltas if value is not None]
        all_deltas.extend(valid)
        per_pid[pid] = {
            "delta_accumulated_gpu_time": metric_summary(valid),
            "total_delta_accumulated_gpu_time": sum(valid) if valid else None,
            "accumulated_gpu_time_rate_per_s": _rate_per_second(
                sum(valid) if valid else None, measurement_elapsed
            ),
        }
    total_delta = sum(all_deltas) if all_deltas else None
    return {
        "measurement": measurement,
        "mean_policy": (
            "System utilization gauge means use trapezoidal time integration over collector "
            "monotonic timestamps when available; distribution statistics remain sample-based."
        ),
        "system": system,
        "processes": per_pid,
        "aggregate": {
            "delta_accumulated_gpu_time": metric_summary(all_deltas),
            "total_delta_accumulated_gpu_time": total_delta,
            "accumulated_gpu_time_rate_per_s": _rate_per_second(
                total_delta, measurement_elapsed
            ),
        },
        "counter_unit": "Apple does not document accumulatedGPUTime's unit in ioreg; values are reported unscaled.",
        "counter_policy": (
            "Raw nonnegative accumulatedGPUTime deltas are preserved. Rates divide their total "
            "by the actual first-to-last ioreg sample span, never requested duration."
        ),
    }


class IORegSampler:
    """Prefer XML/plist output, with a text compatibility mode for newer macOS."""

    def __init__(self, pids: Sequence[int]) -> None:
        self.pids = pids
        self.modes = {
            "IOAccelerator": "plist",
            "AGXDeviceUserClient": "plist",
        }

    def _sample_class(
        self, class_name: str
    ) -> tuple[dict[str, Any] | None, str | None, str | None]:
        """Sample one registry class and return data, format, and warning."""

        if self.modes[class_name] == "plist":
            archive = subprocess.run(
                ["/usr/sbin/ioreg", "-r", "-c", class_name, "-a"],
                capture_output=True,
                timeout=10,
                check=False,
            )
            if archive.returncode == 0 and archive.stdout:
                try:
                    result = parse_ioreg_plist(archive.stdout, self.pids)
                    return result, "plist", None
                except (plistlib.InvalidFileException, ValueError) as error:
                    archive_error = f"ioreg {class_name} plist parse failed: {error}"
            else:
                detail = archive.stderr.decode("utf-8", "replace").strip()
                archive_error = (
                    f"ioreg {class_name} plist collection failed: "
                    f"{detail or f'exit {archive.returncode}'}"
                )
            self.modes[class_name] = "text"
        else:
            archive_error = None

        text_result = subprocess.run(
            ["/usr/sbin/ioreg", "-r", "-c", class_name, "-l", "-w", "0"],
            capture_output=True,
            text=True,
            timeout=10,
            check=False,
        )
        if text_result.returncode != 0:
            detail = text_result.stderr.strip() or f"exit {text_result.returncode}"
            return (
                None,
                None,
                f"{archive_error + '; ' if archive_error else ''}"
                f"ioreg {class_name} text collection failed: {detail}",
            )
        parsed = parse_ioreg_text(text_result.stdout, self.pids)
        return parsed, "text-fallback", archive_error

    def sample(self) -> tuple[dict[str, Any] | None, str | None]:
        # IOAccelerator owns PerformanceStatistics. AGXDeviceUserClient is a
        # separate registry class and owns IOUserClientCreator/AppUsage; asking
        # only for the accelerator silently loses per-process GPU counters.
        accelerator, accelerator_format, accelerator_error = self._sample_class("IOAccelerator")
        clients, clients_format, clients_error = self._sample_class("AGXDeviceUserClient")
        errors = [error for error in (accelerator_error, clients_error) if error]
        if accelerator is None and clients is None:
            return None, "; ".join(errors) or "ioreg returned no GPU data"
        merged = merge_ioreg_results(accelerator, clients)
        merged["source_format"] = {
            "system": accelerator_format,
            "per_process": clients_format,
        }
        return merged, "; ".join(errors) or None


def merge_ioreg_results(
    accelerator: Mapping[str, Any] | None,
    clients: Mapping[str, Any] | None,
) -> dict[str, Any]:
    """Merge separate accelerator and user-client registry queries."""

    accelerator = accelerator or {}
    clients = clients or {}
    accelerator_system = accelerator.get("system", {})
    client_system = clients.get("system", {})
    system = {
        field: accelerator_system.get(field)
        if accelerator_system.get(field) is not None
        else client_system.get(field)
        for field in (
            "device_utilization_percent",
            "renderer_utilization_percent",
            "tiler_utilization_percent",
        )
    }

    # A subtree-style ioreg implementation may also surface AppUsage below
    # IOAccelerator. Prefer the explicit user-client query so counters are not
    # double-counted, while retaining the subtree result as a compatibility
    # fallback for any PID absent from the explicit query.
    per_pid = dict(accelerator.get("per_pid_accumulated_gpu_time", {}))
    per_pid.update(clients.get("per_pid_accumulated_gpu_time", {}))
    return {
        "devices": accelerator.get("devices", []) or clients.get("devices", []),
        "system": system,
        "per_pid_accumulated_gpu_time": per_pid,
    }


def supports_top_power() -> bool:
    """POWER exists on some macOS top releases but is absent on others."""

    probe = subprocess.run(
        ["/usr/bin/top", "-l", "1", "-n", "0", "-stats", "pid,command,cpu,mem,power"],
        capture_output=True,
        timeout=10,
        check=False,
    )
    return probe.returncode == 0


def collect_footprint(pids: Sequence[int]) -> tuple[Any | None, dict[str, Any], str | None]:
    with tempfile.TemporaryDirectory(prefix="wam-footprint-") as directory:
        output = Path(directory) / "footprint.json"
        command = ["/usr/bin/footprint", "--json", str(output)]
        for pid in pids:
            command.extend(["--pid", str(pid)])
        result = subprocess.run(command, capture_output=True, text=True, timeout=30, check=False)
        command_result = {
            "command": command,
            "exit_code": result.returncode,
            "stdout": result.stdout,
            "stderr": result.stderr,
        }
        if result.returncode != 0 or not output.exists():
            detail = result.stderr.strip() or f"exit {result.returncode}"
            return None, command_result, f"footprint collection failed: {detail}"
        try:
            return json.loads(output.read_text(encoding="utf-8")), command_result, None
        except (OSError, json.JSONDecodeError) as error:
            return None, command_result, f"footprint JSON parse failed: {error}"


def summarize_footprint(report: Any, pids: Sequence[int] | None = None) -> dict[str, Any]:
    """Normalize Apple's footprint JSON into byte-valued per-process totals.

    ``auxiliary.phys_footprint`` and ``phys_footprint_peak`` are the process
    ledger values reported by the kernel. Summing them gives the complete
    player-plus-helper cost, but can count shared pages once per process. The
    report-level ``total footprint`` is retained as Apple's shared-adjusted
    current total. Apple does not provide a synchronized shared-adjusted peak,
    so the peak aggregate is explicitly the sum of per-process peaks.
    """

    if not isinstance(report, Mapping):
        return {
            "available": False,
            "unit": "bytes",
            "processes": {},
            "aggregate": {
                "current_phys_footprint_bytes": None,
                "peak_phys_footprint_bytes": None,
                "categorized_footprint_bytes": None,
                "shared_adjusted_footprint_bytes": None,
            },
        }

    scale = _number(report.get("bytes per unit")) or 1.0
    targets = set(pids) if pids is not None else None
    process_summaries: dict[str, Any] = {}
    current_values: list[float] = []
    peak_values: list[float] = []
    categorized_values: list[float] = []
    translated_count = 0

    processes = report.get("processes", [])
    if not isinstance(processes, list):
        processes = []
    for process in processes:
        if not isinstance(process, Mapping):
            continue
        pid_value = _number(process.get("pid"))
        if pid_value is None:
            continue
        pid = int(pid_value)
        if targets is not None and pid not in targets:
            continue
        auxiliary = process.get("auxiliary", {})
        if not isinstance(auxiliary, Mapping):
            auxiliary = {}

        def byte_value(value: Any) -> int | None:
            number = _number(value)
            return int(round(number * scale)) if number is not None else None

        current = byte_value(auxiliary.get("phys_footprint"))
        peak = byte_value(auxiliary.get("phys_footprint_peak"))
        categorized = byte_value(process.get("footprint"))
        if current is not None:
            current_values.append(float(current))
        if peak is not None:
            peak_values.append(float(peak))
        if categorized is not None:
            categorized_values.append(float(categorized))
        translated = process.get("translated") is True
        translated_count += int(translated)
        process_summaries[str(pid)] = {
            "name": process.get("name"),
            "translated": translated,
            "current_phys_footprint_bytes": current,
            "peak_phys_footprint_bytes": peak,
            "categorized_footprint_bytes": categorized,
        }

    report_total = _number(report.get("total footprint"))
    shared_adjusted = int(round(report_total * scale)) if report_total is not None else None

    def total_or_none(values: Sequence[float]) -> int | None:
        return int(round(sum(values))) if values else None

    return {
        "available": bool(process_summaries) or shared_adjusted is not None,
        "unit": "bytes",
        "source_unit": report.get("unit"),
        "bytes_per_source_unit": scale,
        "process_count": len(process_summaries),
        "translated_process_count": translated_count,
        "processes": process_summaries,
        "aggregate": {
            "current_phys_footprint_bytes": total_or_none(current_values),
            "peak_phys_footprint_bytes": total_or_none(peak_values),
            "categorized_footprint_bytes": total_or_none(categorized_values),
            "shared_adjusted_footprint_bytes": shared_adjusted,
        },
        "peak_policy": (
            "peak_phys_footprint_bytes is the sum of each target process's kernel-reported peak; "
            "the individual peaks may have occurred at different times."
        ),
    }


def _command_output(command: Sequence[str]) -> str | None:
    try:
        result = subprocess.run(command, capture_output=True, text=True, timeout=5, check=False)
    except (OSError, subprocess.SubprocessError):
        return None
    return result.stdout.strip() if result.returncode == 0 else None


def host_metadata() -> dict[str, Any]:
    def sysctl(name: str) -> str | None:
        return _command_output(["/usr/sbin/sysctl", "-n", name])

    return {
        "platform": platform.platform(),
        "macos_version": _command_output(["/usr/bin/sw_vers", "-productVersion"]),
        "macos_build": _command_output(["/usr/bin/sw_vers", "-buildVersion"]),
        "machine": platform.machine(),
        "cpu_brand": sysctl("machdep.cpu.brand_string"),
        "physical_cpu_count": _number(sysctl("hw.physicalcpu")),
        "logical_cpu_count": _number(sysctl("hw.logicalcpu")),
        "physical_memory_bytes": _number(sysctl("hw.memsize")),
    }


def collect(args: argparse.Namespace) -> dict[str, Any]:
    sample_intervals = max(1, math.ceil(args.duration / args.interval))
    top_sample_count = sample_intervals + 1
    top_columns = "pid,command,cpu,mem"
    if supports_top_power():
        top_columns += ",power"
    top_columns += ",threads,ports,csw,faults,pageins,purg"
    warnings: list[str] = []
    if ",power," not in f",{top_columns},":
        warnings.append("This macOS top release does not expose POWER; top_power_score is unavailable.")

    top_command = [
        "/usr/bin/top",
        "-l",
        str(top_sample_count),
        "-s",
        str(args.interval),
        "-stats",
        top_columns,
    ]
    for pid in args.pid:
        top_command.extend(["-pid", str(pid)])

    started_wall = dt.datetime.now(dt.timezone.utc)
    started_monotonic = time.monotonic()
    top_process = subprocess.Popen(top_command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)

    ioreg = IORegSampler(args.pid)
    gpu_samples: list[dict[str, Any]] = []
    for sequence in range(top_sample_count):
        target_time = started_monotonic + sequence * args.interval
        remaining = target_time - time.monotonic()
        if remaining > 0:
            time.sleep(remaining)
        sampled_at = time.monotonic()
        try:
            gpu, error = ioreg.sample()
        except (OSError, subprocess.SubprocessError) as exception:
            gpu, error = None, f"ioreg collection failed: {exception}"
        if error:
            warnings.append(error)
        if gpu is not None:
            gpu["sequence"] = sequence
            gpu["elapsed_s"] = sampled_at - started_monotonic
            gpu_samples.append(gpu)

    timeout = max(10.0, args.duration + args.interval * 3.0)
    try:
        raw_top, top_stderr = top_process.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        top_process.terminate()
        raw_top, top_stderr = top_process.communicate(timeout=5)
        warnings.append("top exceeded its expected collection window and was terminated.")
    if top_process.returncode != 0:
        warnings.append(f"top exited with {top_process.returncode}: {top_stderr.strip()}")

    footprint, footprint_command, footprint_error = collect_footprint(args.pid)
    if footprint_error:
        warnings.append(footprint_error)

    parsed_top = parse_top_output(raw_top, args.pid)
    if len(parsed_top) < top_sample_count:
        warnings.append(f"top returned {len(parsed_top)} of {top_sample_count} expected samples.")
    warnings.extend(add_gpu_deltas(gpu_samples, args.pid))
    ended_wall = dt.datetime.now(dt.timezone.utc)

    return {
        "schema": SCHEMA,
        "metadata": {
            "player": args.player,
            "clip": args.clip,
            "run": args.run,
            "speed": args.speed,
            "pids": args.pid,
            "requested_duration_s": args.duration,
            "sample_interval_s": args.interval,
        },
        "host": host_metadata(),
        "collection": {
            "started_at": started_wall.isoformat(),
            "ended_at": ended_wall.isoformat(),
            "elapsed_s": time.monotonic() - started_monotonic,
            "top_command": top_command,
            "top_exit_code": top_process.returncode,
            "top_stderr": top_stderr,
            "footprint_command": footprint_command,
        },
        "samples": {"top": parsed_top, "gpu": gpu_samples},
        "summary": {
            "top": summarize_top(parsed_top, args.pid),
            "gpu": summarize_gpu(gpu_samples, args.pid),
            "footprint": summarize_footprint(footprint, args.pid),
        },
        "footprint": footprint,
        "raw": {"top": raw_top},
        "warnings": list(dict.fromkeys(warnings)),
    }


def positive_float(value: str) -> float:
    parsed = float(value)
    if not math.isfinite(parsed) or parsed <= 0:
        raise argparse.ArgumentTypeError("must be a finite number greater than zero")
    return parsed


def positive_integer_seconds(value: str) -> int:
    """Parse top's whole-second sampling interval, accepting forms like 1.0."""

    parsed = positive_float(value)
    if not parsed.is_integer():
        raise argparse.ArgumentTypeError("must be a positive whole number of seconds")
    return int(parsed)


def positive_pid(value: str) -> int:
    parsed = int(value)
    if parsed <= 0:
        raise argparse.ArgumentTypeError("must be a positive process ID")
    return parsed


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pid", action="append", required=True, type=positive_pid, help="player PID; repeat for helpers")
    parser.add_argument("--player", required=True, help="player label, such as WAM, VLC, or QuickTime")
    parser.add_argument("--clip", required=True, help="stable clip identifier")
    parser.add_argument("--run", required=True, help="replicate/run label")
    parser.add_argument("--speed", required=True, type=positive_float, help="playback rate label")
    parser.add_argument("--duration", type=positive_float, default=60.0, help="measurement duration in seconds")
    parser.add_argument(
        "--interval",
        type=positive_integer_seconds,
        default=1,
        help="sample interval in whole seconds (macOS top requirement)",
    )
    parser.add_argument("--output", required=True, type=Path, help="destination result JSON")
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    if platform.system() != "Darwin":
        raise SystemExit("collect.py requires macOS")
    args.pid = list(dict.fromkeys(args.pid))
    result = collect(args)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    raw_top_path = args.output.with_name(f"{args.output.stem}.top.txt")
    raw_top_path.write_text(result["raw"]["top"], encoding="utf-8")
    result["artifacts"] = {"raw_top": str(raw_top_path)}
    args.output.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(args.output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
