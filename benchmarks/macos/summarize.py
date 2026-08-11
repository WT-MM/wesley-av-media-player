#!/usr/bin/env python3
"""Aggregate WAM macOS benchmark result JSON files into CSV and Markdown."""

from __future__ import annotations

import argparse
import csv
import datetime as dt
import json
import math
from pathlib import Path
from typing import Any, Iterable, Mapping, Sequence


SCHEMA = "wam.macos.benchmark.v1"
STAT_NAMES = ("mean", "median", "p95", "max")
TOP_TIME_FORMAT = "%Y/%m/%d %H:%M:%S"


def nested(value: Mapping[str, Any], *keys: str) -> Any:
    current: Any = value
    for key in keys:
        if not isinstance(current, Mapping):
            return None
        current = current.get(key)
    return current


def scaled_stat(result: Mapping[str, Any], path: Sequence[str], stat: str, scale: float = 1.0) -> float | None:
    value = nested(result, *path, stat)
    if not isinstance(value, (int, float)) or isinstance(value, bool) or not math.isfinite(float(value)):
        return None
    return float(value) / scale


def finite_number(value: Any) -> float | None:
    if not isinstance(value, (int, float)) or isinstance(value, bool):
        return None
    number = float(value)
    return number if math.isfinite(number) else None


def _sample_measurement_elapsed(
    result: Mapping[str, Any], domain: str
) -> tuple[float | None, str | None]:
    """Read an explicit measurement span or derive one for older v1 artifacts."""

    explicit = finite_number(nested(result, "summary", domain, "measurement", "elapsed_s"))
    if explicit is not None and explicit > 0:
        source = nested(result, "summary", domain, "measurement", "source")
        return explicit, str(source) if source else "summary measurement"

    samples = nested(result, "samples", domain)
    if isinstance(samples, list) and len(samples) >= 2:
        if domain == "gpu":
            timestamps = [
                finite_number(sample.get("elapsed_s")) if isinstance(sample, Mapping) else None
                for sample in samples
            ]
            if all(value is not None for value in timestamps):
                elapsed = float(timestamps[-1]) - float(timestamps[0])
                if elapsed > 0:
                    return elapsed, "derived collector monotonic sample timestamps"
        elif domain == "top":
            try:
                timestamps = [
                    dt.datetime.strptime(str(sample["timestamp"]).strip(), TOP_TIME_FORMAT)
                    for sample in samples
                    if isinstance(sample, Mapping)
                ]
            except (KeyError, ValueError):
                timestamps = []
            if len(timestamps) == len(samples):
                elapsed = (timestamps[-1] - timestamps[0]).total_seconds()
                if elapsed > 0:
                    return elapsed, "derived top wall-clock timestamps"

    # Additive v1 compatibility: old result files did not store domain spans.
    # Collection elapsed is an actual observed duration, though it can include
    # post-sampling overhead and is therefore explicitly labeled approximate.
    collection_elapsed = finite_number(nested(result, "collection", "elapsed_s"))
    if collection_elapsed is not None and collection_elapsed > 0:
        return collection_elapsed, "collection elapsed fallback (includes overhead)"
    return None, None


def _counter_rate(
    result: Mapping[str, Any],
    domain: str,
    direct_key: str,
    total_key: str,
    elapsed_s: float | None,
) -> float | None:
    direct = finite_number(nested(result, "summary", domain, "aggregate", direct_key))
    if direct is not None:
        return direct
    total = finite_number(nested(result, "summary", domain, "aggregate", total_key))
    if total is None or elapsed_s is None or elapsed_s <= 0:
        return None
    return total / elapsed_s


def footprint_totals(result: Mapping[str, Any]) -> dict[str, float | int | None]:
    """Read normalized footprint totals, with fallback for older v1 results."""

    normalized = nested(result, "summary", "footprint")
    aggregate = normalized.get("aggregate", {}) if isinstance(normalized, Mapping) else {}
    values: dict[str, float | int | None] = {
        "current": finite_number(aggregate.get("current_phys_footprint_bytes")),
        "peak": finite_number(aggregate.get("peak_phys_footprint_bytes")),
        "shared_adjusted": finite_number(aggregate.get("shared_adjusted_footprint_bytes")),
        "process_count": finite_number(normalized.get("process_count"))
        if isinstance(normalized, Mapping)
        else None,
        "translated_process_count": finite_number(normalized.get("translated_process_count"))
        if isinstance(normalized, Mapping)
        else None,
    }

    report = result.get("footprint")
    if not isinstance(report, Mapping):
        return values
    scale = finite_number(report.get("bytes per unit")) or 1.0
    requested_pids = set(nested(result, "metadata", "pids") or [])
    current_values: list[float] = []
    peak_values: list[float] = []
    process_count = 0
    translated_count = 0
    processes = report.get("processes", [])
    if not isinstance(processes, list):
        processes = []
    for process in processes:
        if not isinstance(process, Mapping):
            continue
        pid = process.get("pid")
        if requested_pids and pid not in requested_pids:
            continue
        process_count += 1
        translated_count += int(process.get("translated") is True)
        auxiliary = process.get("auxiliary", {})
        if not isinstance(auxiliary, Mapping):
            continue
        current = finite_number(auxiliary.get("phys_footprint"))
        peak = finite_number(auxiliary.get("phys_footprint_peak"))
        if current is not None:
            current_values.append(current * scale)
        if peak is not None:
            peak_values.append(peak * scale)

    report_total = finite_number(report.get("total footprint"))
    fallbacks: dict[str, float | int | None] = {
        "current": sum(current_values) if current_values else None,
        "peak": sum(peak_values) if peak_values else None,
        "shared_adjusted": report_total * scale if report_total is not None else None,
        "process_count": process_count,
        "translated_process_count": translated_count,
    }
    return {key: value if value is not None else fallbacks[key] for key, value in values.items()}


def result_row(result: Mapping[str, Any], source: Path) -> dict[str, Any]:
    metadata = result.get("metadata", {})
    top_elapsed, top_elapsed_source = _sample_measurement_elapsed(result, "top")
    gpu_elapsed, gpu_elapsed_source = _sample_measurement_elapsed(result, "gpu")
    row: dict[str, Any] = {
        "source": str(source),
        "player": metadata.get("player"),
        "clip": metadata.get("clip"),
        "run": metadata.get("run"),
        "speed": metadata.get("speed"),
        "pids": ";".join(str(pid) for pid in metadata.get("pids", [])),
        "requested_duration_s": metadata.get("requested_duration_s"),
        "elapsed_s": nested(result, "collection", "elapsed_s"),
        "top_measurement_elapsed_s": top_elapsed,
        "top_measurement_elapsed_source": top_elapsed_source,
        "gpu_measurement_elapsed_s": gpu_elapsed,
        "gpu_measurement_elapsed_source": gpu_elapsed_source,
        "top_samples": len(nested(result, "samples", "top") or []),
        "gpu_samples": len(nested(result, "samples", "gpu") or []),
        "warning_count": len(result.get("warnings", [])),
    }

    metrics = {
        "cpu_percent": (("summary", "top", "aggregate", "cpu_percent"), 1.0),
        "memory_mib": (("summary", "top", "aggregate", "memory_bytes"), 1024.0**2),
        "top_power_score": (("summary", "top", "aggregate", "top_power_score"), 1.0),
        "threads": (("summary", "top", "aggregate", "thread_count"), 1.0),
        "running_threads": (("summary", "top", "aggregate", "running_thread_count"), 1.0),
        "ports": (("summary", "top", "aggregate", "port_count"), 1.0),
        "purgeable_memory_mib": (("summary", "top", "aggregate", "purgeable_bytes"), 1024.0**2),
        "context_switches_per_interval": (
            ("summary", "top", "aggregate", "context_switch_count_delta"),
            1.0,
        ),
        "faults_per_interval": (("summary", "top", "aggregate", "fault_count_delta"), 1.0),
        "pageins_per_interval": (("summary", "top", "aggregate", "pagein_count_delta"), 1.0),
        "system_cpu_active_percent": (("summary", "top", "system_cpu", "active_percent"), 1.0),
        "gpu_device_percent": (("summary", "gpu", "system", "device_utilization_percent"), 1.0),
        "gpu_renderer_percent": (("summary", "gpu", "system", "renderer_utilization_percent"), 1.0),
        "gpu_tiler_percent": (("summary", "gpu", "system", "tiler_utilization_percent"), 1.0),
        "gpu_time_delta": (("summary", "gpu", "aggregate", "delta_accumulated_gpu_time"), 1.0),
    }
    for label, (path, scale) in metrics.items():
        for stat in STAT_NAMES:
            row[f"{label}_{stat}"] = scaled_stat(result, path, stat, scale)
        method = nested(result, *path, "mean_method")
        row[f"{label}_mean_method"] = (
            method
            if isinstance(method, str)
            else "arithmetic_sample_mean"
            if nested(result, *path, "count")
            else None
        )
    row["context_switches_per_s"] = _counter_rate(
        result,
        "top",
        "context_switch_count_rate_per_s",
        "total_context_switch_count_delta",
        top_elapsed,
    )
    row["faults_per_s"] = _counter_rate(
        result,
        "top",
        "fault_count_rate_per_s",
        "total_fault_count_delta",
        top_elapsed,
    )
    row["pageins_per_s"] = _counter_rate(
        result,
        "top",
        "pagein_count_rate_per_s",
        "total_pagein_count_delta",
        top_elapsed,
    )
    row["gpu_time_counter_units_per_s"] = _counter_rate(
        result,
        "gpu",
        "accumulated_gpu_time_rate_per_s",
        "total_delta_accumulated_gpu_time",
        gpu_elapsed,
    )
    row["gpu_time_delta_total"] = nested(
        result, "summary", "gpu", "aggregate", "total_delta_accumulated_gpu_time"
    )
    row["context_switches_total"] = nested(
        result, "summary", "top", "aggregate", "total_context_switch_count_delta"
    )
    row["faults_total"] = nested(result, "summary", "top", "aggregate", "total_fault_count_delta")
    row["pageins_total"] = nested(result, "summary", "top", "aggregate", "total_pagein_count_delta")
    footprint = footprint_totals(result)
    row["footprint_current_mib"] = (
        float(footprint["current"]) / 1024.0**2 if footprint["current"] is not None else None
    )
    row["footprint_peak_mib"] = (
        float(footprint["peak"]) / 1024.0**2 if footprint["peak"] is not None else None
    )
    row["footprint_shared_adjusted_mib"] = (
        float(footprint["shared_adjusted"]) / 1024.0**2
        if footprint["shared_adjusted"] is not None
        else None
    )
    row["footprint_process_count"] = footprint["process_count"]
    row["translated_process_count"] = footprint["translated_process_count"]
    return row


def input_files(paths: Iterable[Path]) -> list[Path]:
    files: list[Path] = []
    for path in paths:
        if path.is_dir():
            files.extend(sorted(path.rglob("*.json")))
        else:
            files.append(path)
    return list(dict.fromkeys(files))


def load_rows(paths: Iterable[Path]) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    for path in input_files(paths):
        try:
            result = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as error:
            raise ValueError(f"could not read {path}: {error}") from error
        if result.get("schema") != SCHEMA:
            continue
        rows.append(result_row(result, path))
    return rows


def csv_text(rows: Sequence[Mapping[str, Any]]) -> str:
    if not rows:
        return ""
    import io

    output = io.StringIO(newline="")
    writer = csv.DictWriter(output, fieldnames=list(rows[0].keys()))
    writer.writeheader()
    writer.writerows(rows)
    return output.getvalue()


def _display(value: Any) -> str:
    if value is None:
        return "—"
    if isinstance(value, float):
        return f"{value:.3f}"
    return str(value).replace("|", "\\|").replace("\n", " ")


def markdown_text(rows: Sequence[Mapping[str, Any]]) -> str:
    if not rows:
        return "No benchmark results found.\n"
    columns = list(rows[0].keys())
    header = "| " + " | ".join(columns) + " |"
    separator = "| " + " | ".join("---" for _ in columns) + " |"
    body = ["| " + " | ".join(_display(row.get(column)) for column in columns) + " |" for row in rows]
    return "\n".join([header, separator, *body]) + "\n"


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("inputs", nargs="+", type=Path, help="result JSON files or directories")
    parser.add_argument("--csv", type=Path, help="write CSV here")
    parser.add_argument("--markdown", type=Path, help="write Markdown here")
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        rows = load_rows(args.inputs)
    except ValueError as error:
        raise SystemExit(str(error)) from error
    csv_output = csv_text(rows)
    markdown_output = markdown_text(rows)
    if args.csv:
        args.csv.parent.mkdir(parents=True, exist_ok=True)
        args.csv.write_text(csv_output, encoding="utf-8")
    if args.markdown:
        args.markdown.parent.mkdir(parents=True, exist_ok=True)
        args.markdown.write_text(markdown_output, encoding="utf-8")
    if not args.csv and not args.markdown:
        print(markdown_output, end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
