#!/usr/bin/env python3
"""Create a concise aggregate report from a WAM macOS matrix manifest.

The matrix manifest is an atomic live snapshot.  Only trials marked completed
are read, and only finite values present in their result JSON are aggregated.
Pending, running, failed, unsupported, malformed, and missing artifacts remain
explicit; none of them are converted to zero-valued measurements.
"""

from __future__ import annotations

import argparse
import csv
import datetime as dt
import io
import json
import math
import statistics
from collections import Counter, defaultdict
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable, Iterable, Mapping, Sequence


MATRIX_SCHEMA = "wam.macos.matrix.v1"
RESULT_SCHEMA = "wam.macos.benchmark.v1"
MIB = 1024.0**2
TOP_TIME_FORMAT = "%Y/%m/%d %H:%M:%S"


class ReportError(RuntimeError):
    """A manifest, result, or explicitly supplied metadata value is invalid."""


def nested(value: Mapping[str, Any], *keys: str) -> Any:
    current: Any = value
    for key in keys:
        if not isinstance(current, Mapping):
            return None
        current = current.get(key)
    return current


def finite_number(value: Any) -> float | None:
    if not isinstance(value, (int, float)) or isinstance(value, bool):
        return None
    number = float(value)
    return number if math.isfinite(number) else None


def path_number(result: Mapping[str, Any], path: Sequence[str], scale: float = 1.0) -> float | None:
    value = finite_number(nested(result, *path))
    return value / scale if value is not None else None


def measurement_elapsed(result: Mapping[str, Any], domain: str) -> float | None:
    """Return an actual domain sampling span, including additive-v1 fallbacks."""

    explicit = path_number(result, ("summary", domain, "measurement", "elapsed_s"))
    if explicit is not None and explicit > 0:
        return explicit

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
                    return elapsed
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
                    return elapsed

    # Older v1 artifacts only recorded whole-collection elapsed time. It is an
    # observed duration rather than requested duration, but can include the
    # final footprint call and is used only as an explicitly documented fallback.
    fallback = path_number(result, ("collection", "elapsed_s"))
    return fallback if fallback is not None and fallback > 0 else None


def normalized_counter_rate(
    result: Mapping[str, Any],
    domain: str,
    direct_key: str,
    total_key: str,
) -> float | None:
    direct = path_number(result, ("summary", domain, "aggregate", direct_key))
    if direct is not None:
        return direct
    total = path_number(result, ("summary", domain, "aggregate", total_key))
    elapsed = measurement_elapsed(result, domain)
    if total is None or elapsed is None or elapsed <= 0:
        return None
    return total / elapsed


def footprint_values(result: Mapping[str, Any]) -> dict[str, float | None]:
    """Return footprint values in bytes, including a v1 raw-report fallback."""

    aggregate = nested(result, "summary", "footprint", "aggregate")
    normalized = aggregate if isinstance(aggregate, Mapping) else {}
    values = {
        "footprint_current_mib": finite_number(normalized.get("current_phys_footprint_bytes")),
        "footprint_peak_mib": finite_number(normalized.get("peak_phys_footprint_bytes")),
        "footprint_shared_adjusted_mib": finite_number(
            normalized.get("shared_adjusted_footprint_bytes")
        ),
    }

    raw = result.get("footprint")
    if isinstance(raw, Mapping):
        scale = finite_number(raw.get("bytes per unit")) or 1.0
        requested = set(nested(result, "metadata", "pids") or [])
        current: list[float] = []
        peak: list[float] = []
        processes = raw.get("processes")
        if isinstance(processes, list):
            for process in processes:
                if not isinstance(process, Mapping):
                    continue
                if requested and process.get("pid") not in requested:
                    continue
                auxiliary = process.get("auxiliary")
                if not isinstance(auxiliary, Mapping):
                    continue
                current_value = finite_number(auxiliary.get("phys_footprint"))
                peak_value = finite_number(auxiliary.get("phys_footprint_peak"))
                if current_value is not None:
                    current.append(current_value * scale)
                if peak_value is not None:
                    peak.append(peak_value * scale)
        shared_adjusted = finite_number(raw.get("total footprint"))
        fallbacks = {
            "footprint_current_mib": sum(current) if current else None,
            "footprint_peak_mib": sum(peak) if peak else None,
            "footprint_shared_adjusted_mib": (
                shared_adjusted * scale if shared_adjusted is not None else None
            ),
        }
        for key, fallback in fallbacks.items():
            if values[key] is None:
                values[key] = fallback

    return {key: value / MIB if value is not None else None for key, value in values.items()}


@dataclass(frozen=True)
class MetricSpec:
    key: str
    markdown_label: str
    csv_unit: str
    extractor: Callable[[Mapping[str, Any]], float | None]
    digits: int = 2


def _summary_mean(*path: str, scale: float = 1.0) -> Callable[[Mapping[str, Any]], float | None]:
    return lambda result: path_number(result, ("summary", *path, "mean"), scale)


def _footprint(key: str) -> Callable[[Mapping[str, Any]], float | None]:
    return lambda result: footprint_values(result)[key]


REQUIRED_METRICS: tuple[MetricSpec, ...] = (
    MetricSpec(
        "cpu_percent",
        "CPU %",
        "percent",
        _summary_mean("top", "aggregate", "cpu_percent"),
    ),
    MetricSpec(
        "energy_impact",
        "Energy Impact",
        "top POWER score",
        _summary_mean("top", "aggregate", "top_power_score"),
    ),
    MetricSpec(
        "memory_mib",
        "Memory MiB",
        "MiB",
        _summary_mean("top", "aggregate", "memory_bytes", scale=MIB),
        1,
    ),
    MetricSpec(
        "footprint_current_mib",
        "Footprint current MiB",
        "MiB",
        _footprint("footprint_current_mib"),
        1,
    ),
    MetricSpec(
        "footprint_peak_mib",
        "Footprint peak MiB",
        "MiB",
        _footprint("footprint_peak_mib"),
        1,
    ),
    MetricSpec(
        "footprint_shared_adjusted_mib",
        "Footprint shared-adjusted MiB",
        "MiB",
        _footprint("footprint_shared_adjusted_mib"),
        1,
    ),
    MetricSpec(
        "context_switch_rate",
        "Context switches/s",
        "count/s",
        lambda result: normalized_counter_rate(
            result,
            "top",
            "context_switch_count_rate_per_s",
            "total_context_switch_count_delta",
        ),
        1,
    ),
    MetricSpec(
        "fault_rate",
        "Faults/s",
        "count/s",
        lambda result: normalized_counter_rate(
            result,
            "top",
            "fault_count_rate_per_s",
            "total_fault_count_delta",
        ),
        1,
    ),
    MetricSpec(
        "pagein_rate",
        "Page-ins/s",
        "count/s",
        lambda result: normalized_counter_rate(
            result,
            "top",
            "pagein_count_rate_per_s",
            "total_pagein_count_delta",
        ),
        2,
    ),
)

GPU_METRIC = MetricSpec(
    "process_gpu_counter_rate",
    "AGX process counter units/s",
    "undocumented accumulatedGPUTime counter units/s",
    lambda result: normalized_counter_rate(
        result,
        "gpu",
        "accumulated_gpu_time_rate_per_s",
        "total_delta_accumulated_gpu_time",
    ),
    0,
)


@dataclass(frozen=True)
class Aggregate:
    count: int
    median: float | None
    minimum: float | None
    maximum: float | None


def aggregate(values: Iterable[float | None]) -> Aggregate:
    finite = [value for value in values if value is not None and math.isfinite(value)]
    if not finite:
        return Aggregate(0, None, None, None)
    return Aggregate(len(finite), statistics.median(finite), min(finite), max(finite))


@dataclass
class ReportSnapshot:
    manifest_path: Path
    suite_id: str
    suite_state: str
    manifest_updated_at: str | None
    rows: list[dict[str, Any]]
    metrics: tuple[MetricSpec, ...]
    include_architecture: bool
    include_bundle_size: bool


def _read_json(path: Path, label: str) -> Mapping[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ReportError(f"could not read {label} {path}: {error}") from error
    if not isinstance(value, Mapping):
        raise ReportError(f"{label} must contain a JSON object: {path}")
    return value


def load_manifest(path: Path) -> tuple[Path, Mapping[str, Any]]:
    resolved = path.expanduser().resolve()
    manifest = _read_json(resolved, "matrix manifest")
    if manifest.get("schema") != MATRIX_SCHEMA:
        raise ReportError(
            f"unsupported matrix schema {manifest.get('schema')!r}; expected {MATRIX_SCHEMA!r}"
        )
    trials = manifest.get("trials")
    if not isinstance(trials, list):
        raise ReportError("matrix manifest 'trials' must be a list")
    return resolved, manifest


def _players(manifest: Mapping[str, Any]) -> list[str]:
    players: list[str] = []
    for trial in manifest.get("trials", []):
        if isinstance(trial, Mapping) and isinstance(trial.get("player"), str):
            players.append(trial["player"])
    orders = nested(manifest, "configuration", "player_order_by_repetition")
    if isinstance(orders, Mapping):
        for key in sorted(orders, key=lambda value: (not str(value).isdigit(), str(value))):
            order = orders[key]
            if isinstance(order, list):
                players.extend(player for player in order if isinstance(player, str))
    return list(dict.fromkeys(players))


def _cases(manifest: Mapping[str, Any]) -> list[Mapping[str, Any]]:
    cases = [case for case in manifest.get("cases", []) if isinstance(case, Mapping)]
    known = {case.get("id") for case in cases}
    for trial in manifest.get("trials", []):
        if not isinstance(trial, Mapping) or trial.get("case_id") in known:
            continue
        case_id = trial.get("case_id")
        if isinstance(case_id, str):
            cases.append({"id": case_id, "group": trial.get("case_group")})
            known.add(case_id)
    return cases


def _result_path(manifest_path: Path, value: Any) -> Path | None:
    if not isinstance(value, str) or not value:
        return None
    candidate = Path(value).expanduser()
    return candidate.resolve() if candidate.is_absolute() else (manifest_path.parent / candidate).resolve()


def _load_completed_result(
    manifest_path: Path, trial: Mapping[str, Any]
) -> tuple[Mapping[str, Any] | None, str | None]:
    path = _result_path(manifest_path, trial.get("result_path"))
    if path is None:
        return None, "completed trial has no result_path"
    try:
        result = _read_json(path, "completed result")
    except ReportError as error:
        return None, str(error)
    if result.get("schema") != RESULT_SCHEMA:
        return None, f"result {path} has schema {result.get('schema')!r}, expected {RESULT_SCHEMA!r}"
    expected_case = trial.get("case_id")
    actual_case = nested(result, "metadata", "clip")
    if isinstance(expected_case, str) and actual_case != expected_case:
        return None, f"result {path} identifies clip {actual_case!r}, expected {expected_case!r}"
    return result, None


def _support_expectation(trials: Sequence[Mapping[str, Any]], case: Mapping[str, Any], player: str) -> str:
    values = {
        trial.get("support_expectation")
        for trial in trials
        if isinstance(trial.get("support_expectation"), str)
    }
    if len(values) == 1:
        return str(next(iter(values)))
    expected_unsupported = case.get("expected_unsupported_players")
    if isinstance(expected_unsupported, list):
        return "unsupported" if player in expected_unsupported else "supported"
    return "mixed" if values else "unspecified"


def _planned_repetitions(
    manifest: Mapping[str, Any], case: Mapping[str, Any], trials: Sequence[Mapping[str, Any]]
) -> int | None:
    repetitions = {
        int(trial["repetition"])
        for trial in trials
        if isinstance(trial.get("repetition"), int) and not isinstance(trial.get("repetition"), bool)
    }
    if repetitions:
        return len(repetitions)
    override = finite_number(nested(manifest, "configuration", "repetition_override"))
    default = finite_number(case.get("default_repetitions"))
    value = override if override is not None else default
    return int(value) if value is not None and value >= 0 and value.is_integer() else None


def _issue_summary(trials: Sequence[Mapping[str, Any]], artifact_errors: Sequence[str]) -> str:
    issues: list[str] = []
    seen: set[str] = set()
    for trial in trials:
        if trial.get("status") != "n/a":
            continue
        reason = nested(trial, "n_a", "reason") or "unspecified"
        detail = nested(trial, "n_a", "detail")
        issue = str(reason)
        if isinstance(detail, str) and detail.strip():
            compact = " ".join(detail.split())
            issue += ": " + (compact if len(compact) <= 140 else compact[:139] + "…")
        if issue not in seen:
            seen.add(issue)
            issues.append(issue)
    for error in artifact_errors:
        compact = " ".join(error.split())
        issue = "artifact: " + (compact if len(compact) <= 180 else compact[:179] + "…")
        if issue not in seen:
            seen.add(issue)
            issues.append(issue)
    return "; ".join(issues)


def _observed_support(valid_results: int, reasons: Counter[str]) -> str:
    if valid_results:
        return "supported"
    if reasons.get("unsupported"):
        return "unsupported"
    if reasons.get("failure"):
        return "failed"
    return "not yet measured"


def _report_status(
    statuses: Counter[str], valid_results: int, completed_count: int, artifact_errors: int
) -> str:
    if valid_results:
        if (
            artifact_errors
            or statuses.get("n/a", 0)
            or statuses.get("pending", 0)
            or statuses.get("running", 0)
            or valid_results != completed_count
        ):
            return "partial"
        return "complete"
    if artifact_errors or completed_count:
        return "N/A (artifact error)"
    if statuses.get("running", 0):
        return "partial" if statuses.get("n/a", 0) else "running"
    if statuses.get("pending", 0):
        return "partial" if statuses.get("n/a", 0) else "pending"
    if statuses.get("n/a", 0):
        return "N/A"
    return "not scheduled"


def build_report(
    manifest_path: Path,
    *,
    architectures: Mapping[str, str] | None = None,
    bundle_size_bytes: Mapping[str, int] | None = None,
) -> ReportSnapshot:
    resolved, manifest = load_manifest(manifest_path)
    architecture_values = dict(architectures or {})
    bundle_values = dict(bundle_size_bytes or {})
    trials = [trial for trial in manifest["trials"] if isinstance(trial, Mapping)]
    grouped: dict[tuple[str, str], list[Mapping[str, Any]]] = defaultdict(list)
    for trial in trials:
        case_id = trial.get("case_id")
        player = trial.get("player")
        if isinstance(case_id, str) and isinstance(player, str):
            grouped[(case_id, player)].append(trial)

    cases = _cases(manifest)
    players = _players(manifest)
    rows: list[dict[str, Any]] = []
    for case in cases:
        case_id = case.get("id")
        if not isinstance(case_id, str):
            continue
        case_players = list(players)
        for grouped_case, grouped_player in grouped:
            if grouped_case == case_id and grouped_player not in case_players:
                case_players.append(grouped_player)
        for player in case_players:
            group = sorted(
                grouped.get((case_id, player), []),
                key=lambda trial: (trial.get("repetition", 0), trial.get("ordinal", 0)),
            )
            statuses = Counter(str(trial.get("status", "unknown")) for trial in group)
            completed = [trial for trial in group if trial.get("status") == "completed"]
            results: list[Mapping[str, Any]] = []
            artifact_errors: list[str] = []
            for trial in completed:
                result, error = _load_completed_result(resolved, trial)
                if result is not None:
                    results.append(result)
                if error is not None:
                    artifact_errors.append(error)

            reasons = Counter(
                str(nested(trial, "n_a", "reason") or "unspecified")
                for trial in group
                if trial.get("status") == "n/a"
            )
            row: dict[str, Any] = {
                "suite_id": str(manifest.get("suite_id", "")),
                "suite_state": str(manifest.get("state", "unknown")),
                "case_id": case_id,
                "case_group": case.get("group") or "",
                "player": player,
                "expected_support": _support_expectation(group, case, player),
                "observed_support": _observed_support(len(results), reasons),
                "report_status": _report_status(
                    statuses, len(results), len(completed), len(artifact_errors)
                ),
                "planned_repetitions": _planned_repetitions(manifest, case, group),
                "completed_repetitions": len(completed),
                "measured_repetitions": len(results),
                "pending_repetitions": statuses.get("pending", 0),
                "running_repetitions": statuses.get("running", 0),
                "n_a_repetitions": statuses.get("n/a", 0),
                "n_a_reasons": "; ".join(
                    f"{reason} ({count})" for reason, count in sorted(reasons.items())
                ),
                "issues": _issue_summary(group, artifact_errors),
            }
            for metric in (*REQUIRED_METRICS, GPU_METRIC):
                row[metric.key] = aggregate(metric.extractor(result) for result in results)
            if architecture_values:
                row["architecture"] = architecture_values.get(player)
            if bundle_values:
                size = bundle_values.get(player)
                row["bundle_size_mib"] = size / MIB if size is not None else None
            rows.append(row)

    active_metrics = list(REQUIRED_METRICS)
    if any(row[GPU_METRIC.key].count for row in rows):
        active_metrics.append(GPU_METRIC)
    return ReportSnapshot(
        manifest_path=resolved,
        suite_id=str(manifest.get("suite_id", "")),
        suite_state=str(manifest.get("state", "unknown")),
        manifest_updated_at=(
            str(manifest["updated_at"]) if manifest.get("updated_at") is not None else None
        ),
        rows=rows,
        metrics=tuple(active_metrics),
        include_architecture=bool(architecture_values),
        include_bundle_size=bool(bundle_values),
    )


BASE_CSV_FIELDS = (
    "suite_id",
    "suite_state",
    "case_id",
    "case_group",
    "player",
    "expected_support",
    "observed_support",
    "report_status",
    "planned_repetitions",
    "completed_repetitions",
    "measured_repetitions",
    "pending_repetitions",
    "running_repetitions",
    "n_a_repetitions",
    "n_a_reasons",
    "issues",
)


def csv_rows(snapshot: ReportSnapshot) -> tuple[list[str], list[dict[str, Any]]]:
    fields = list(BASE_CSV_FIELDS)
    if snapshot.include_architecture:
        fields.append("architecture")
    if snapshot.include_bundle_size:
        fields.append("bundle_size_mib")
    for metric in snapshot.metrics:
        fields.extend(
            (
                f"{metric.key}_available_repetitions",
                f"{metric.key}_median",
                f"{metric.key}_min",
                f"{metric.key}_max",
                f"{metric.key}_unit",
            )
        )

    output_rows: list[dict[str, Any]] = []
    for row in snapshot.rows:
        output = {field: row.get(field) for field in fields}
        for metric in snapshot.metrics:
            value: Aggregate = row[metric.key]
            output[f"{metric.key}_available_repetitions"] = value.count
            output[f"{metric.key}_median"] = value.median
            output[f"{metric.key}_min"] = value.minimum
            output[f"{metric.key}_max"] = value.maximum
            output[f"{metric.key}_unit"] = metric.csv_unit
        output_rows.append(output)
    return fields, output_rows


def csv_text(snapshot: ReportSnapshot) -> str:
    fields, rows = csv_rows(snapshot)
    output = io.StringIO(newline="")
    writer = csv.DictWriter(output, fieldnames=fields, extrasaction="ignore")
    writer.writeheader()
    writer.writerows(rows)
    return output.getvalue()


def _escape(value: Any) -> str:
    if value is None or value == "":
        return "N/A"
    return str(value).replace("|", "\\|").replace("\n", " ")


def _format_aggregate(value: Aggregate, digits: int) -> str:
    if value.median is None or value.minimum is None or value.maximum is None:
        return "N/A"
    formatted = [f"{number:,.{digits}f}" for number in (value.median, value.minimum, value.maximum)]
    return f"{formatted[0]} [{formatted[1]}–{formatted[2]}]"


def _format_metric_group(
    row: Mapping[str, Any], labels_and_metrics: Sequence[tuple[str, MetricSpec]]
) -> str:
    return " · ".join(
        f"{label} {_format_aggregate(row[metric.key], metric.digits)}"
        for label, metric in labels_and_metrics
    )


def markdown_text(snapshot: ReportSnapshot) -> str:
    lines = ["# Benchmark matrix report", ""]
    state = f"Suite `{_escape(snapshot.suite_id)}` is `{_escape(snapshot.suite_state)}`"
    if snapshot.manifest_updated_at:
        state += f" (manifest snapshot `{_escape(snapshot.manifest_updated_at)}`)."
    else:
        state += "."
    lines.extend(
        [
            state,
            "",
            "Metric cells are median across repetitions with [min–max] variability. Current "
            "collector results store timestamp-weighted run means for CPU, Energy Impact "
            "(`top` POWER), and memory; legacy v1 artifacts retain their stored arithmetic "
            "means. Event and optional AGX "
            "accumulated-counter values are raw deltas divided by each run's actual sampling "
            "span (not requested duration). Footprints are end-of-run kernel values. "
            "N/A means unavailable, failed, unsupported, or not yet measured—never zero.",
            "",
        ]
    )

    columns: list[tuple[str, Callable[[dict[str, Any]], str]]] = [
        ("Case", lambda row: _escape(row["case_id"])),
        ("Player", lambda row: _escape(row["player"])),
        ("Support expected / observed", lambda row: _escape(
            f"{row['expected_support']} / {row['observed_support']}"
        )),
        ("Status", lambda row: _escape(row["report_status"])),
        ("Measured / planned", lambda row: _escape(
            f"{row['measured_repetitions']} / "
            f"{row['planned_repetitions'] if row['planned_repetitions'] is not None else 'N/A'}"
        )),
    ]
    if snapshot.include_architecture:
        columns.append(("Architecture", lambda row: _escape(row.get("architecture"))))
    if snapshot.include_bundle_size:
        columns.append(
            (
                "Bundle MiB",
                lambda row: (
                    f"{row['bundle_size_mib']:.1f}"
                    if row.get("bundle_size_mib") is not None
                    else "N/A"
                ),
            )
        )
    for metric in REQUIRED_METRICS[:3]:
        columns.append(
            (
                metric.markdown_label,
                lambda row, selected=metric: _format_aggregate(
                    row[selected.key], selected.digits
                ),
            )
        )
    columns.extend(
        [
            (
                "Footprint MiB (current / peak / shared-adjusted)",
                lambda row: _format_metric_group(
                    row,
                    (
                        ("C", REQUIRED_METRICS[3]),
                        ("P", REQUIRED_METRICS[4]),
                        ("S", REQUIRED_METRICS[5]),
                    ),
                ),
            ),
            (
                "Event rate/s (switches / faults / page-ins)",
                lambda row: _format_metric_group(
                    row,
                    (
                        ("CSW", REQUIRED_METRICS[6]),
                        ("F", REQUIRED_METRICS[7]),
                        ("PI", REQUIRED_METRICS[8]),
                    ),
                ),
            ),
        ]
    )
    if GPU_METRIC in snapshot.metrics:
        columns.append(
            (
                GPU_METRIC.markdown_label,
                lambda row: _format_aggregate(
                    row[GPU_METRIC.key], GPU_METRIC.digits
                ),
            )
        )
    columns.append(("N/A reason / issue", lambda row: _escape(row.get("issues"))))

    lines.append("| " + " | ".join(label for label, _ in columns) + " |")
    lines.append("| " + " | ".join("---" for _ in columns) + " |")
    for row in snapshot.rows:
        lines.append("| " + " | ".join(render(row) for _, render in columns) + " |")
    lines.append("")
    if GPU_METRIC in snapshot.metrics:
        lines.extend(
            [
                "The AGX column is derived only from per-process `accumulatedGPUTime` deltas; "
                "the raw total is divided by the actual first-to-last ioreg sampling span. Apple "
                "does not document that counter's unit. Missing process counters remain N/A.",
                "",
            ]
        )
    return "\n".join(lines)


def _assignment(value: str, option: str) -> tuple[str, str]:
    player, separator, assigned = value.partition("=")
    if not separator or not player.strip() or not assigned.strip():
        raise ReportError(f"{option} must use PLAYER=VALUE")
    return player.strip(), assigned.strip()


def _architecture_assignments(values: Sequence[str]) -> dict[str, str]:
    parsed: dict[str, str] = {}
    for value in values:
        player, architecture = _assignment(value, "--architecture")
        if player in parsed:
            raise ReportError(f"duplicate --architecture for {player}")
        parsed[player] = architecture
    return parsed


def _bundle_assignments(values: Sequence[str]) -> dict[str, int]:
    parsed: dict[str, int] = {}
    for value in values:
        player, raw_size = _assignment(value, "--bundle-size-bytes")
        try:
            size = int(raw_size)
        except ValueError as error:
            raise ReportError(f"bundle size for {player} must be an integer byte count") from error
        if size < 0:
            raise ReportError(f"bundle size for {player} must be nonnegative")
        if player in parsed:
            raise ReportError(f"duplicate --bundle-size-bytes for {player}")
        parsed[player] = size
    return parsed


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("manifest", type=Path, help="run_matrix.py manifest.json")
    parser.add_argument("--csv", type=Path, help="write aggregate CSV here")
    parser.add_argument("--markdown", type=Path, help="write aggregate Markdown here")
    parser.add_argument(
        "--architecture",
        action="append",
        default=[],
        metavar="PLAYER=ARCH",
        help="optional explicit player architecture; repeat per player",
    )
    parser.add_argument(
        "--bundle-size-bytes",
        action="append",
        default=[],
        metavar="PLAYER=BYTES",
        help="optional explicit standalone bundle byte count; repeat per player",
    )
    return parser


def _write(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")


def main(argv: Sequence[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        architectures = _architecture_assignments(args.architecture)
        bundle_sizes = _bundle_assignments(args.bundle_size_bytes)
        snapshot = build_report(
            args.manifest,
            architectures=architectures,
            bundle_size_bytes=bundle_sizes,
        )
    except ReportError as error:
        raise SystemExit(str(error)) from error
    markdown = markdown_text(snapshot)
    if args.csv:
        _write(args.csv, csv_text(snapshot))
    if args.markdown:
        _write(args.markdown, markdown)
    if not args.csv and not args.markdown:
        print(markdown, end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
