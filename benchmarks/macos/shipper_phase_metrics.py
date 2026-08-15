#!/usr/bin/env python3
"""Fail-closed reducers for macOS shipper CPU and memory evidence.

The trust boundary is deliberately small.  Reducers consume a retained raw
artifact containing cumulative execution-scope counters.  They accept a
receipt only through :class:`TrustedReceiptIndex`, an integration-owned object
which has already authenticated the producer.  Derived metric dictionaries
are never evidence: the evaluator replays every reduction from the retained
artifact and compares the complete, policy-versioned output.

No interpolation is used.  A phase is conservatively measured from the last
query which completed before its start through the first query which began
after its end.  The resulting CPU delta can overcount edge work, but cannot
undercount it.  Memory is the sum of authenticated per-member lifetime
high-water marks, not an exact or temporally concurrent phase peak; it can
overcount pre-phase/non-concurrent memory while retaining transient and exited
members.
"""

from __future__ import annotations

import hashlib
import json
import math
from abc import ABC, abstractmethod
from collections.abc import Mapping, Sequence
from fractions import Fraction
from typing import Any


RAW_ARTIFACT_SCHEMA = "wam.macos.shipper.raw_scope_artifact.v2"
PHASE_REQUEST_SCHEMA = "wam.macos.shipper.phase_request.v2"
SCRUB_REQUEST_SCHEMA = "wam.macos.shipper.scrub_request.v2"
TRUSTED_RECEIPT_SCHEMA = "wam.macos.shipper.authenticated_scope_receipt.v2"
PHASE_REDUCTION_SCHEMA = "wam.macos.shipper.phase_reduction.v2"
SCRUB_REDUCTION_SCHEMA = "wam.macos.shipper.scrub_reduction.v2"
VARIANT_REPORT_SCHEMA = "wam.macos.shipper.variant_gate_report.v2"
THRESHOLD_POLICY_VERSION = "wam.shipper.thresholds.2026-08-13.v2"

SAMPLE_INTERVAL_NS = 50_000_000
ROLLING_CPU_WINDOW_NS = 250_000_000
MAX_CAPTURE_LATENESS_NS = 10_000_000
MAX_QUERY_DURATION_NS = 10_000_000
MIN_CAPTURE_START_GAP_NS = SAMPLE_INTERVAL_NS - MAX_CAPTURE_LATENESS_NS
MAX_CAPTURE_START_GAP_NS = SAMPLE_INTERVAL_NS + MAX_CAPTURE_LATENESS_NS
DEFAULT_MEMORY_LIMIT_BYTES = 300 * 1024 * 1024

WARM_CPU_LIMIT_PERCENT = Fraction(10, 1)
WARM_CPU_TIME_LIMIT_MS = Fraction(25, 1)
COLD_CPU_P95_LIMIT_MS = Fraction(250, 1)
COLD_CPU_MAX_LIMIT_MS = Fraction(500, 1)
STEADY_CPU_LIMIT_PERCENT = Fraction(10, 1)
SCRUB_CPU_LIMIT_PERCENT = Fraction(10, 1)
SCRUB_ROLLING_CPU_LIMIT_PERCENT = Fraction(25, 1)

_PHASES = {"cold", "warm", "steady"}
_DIRECTIONS = ("forward", "reverse")
_ROLES = {"app", "decoder_helper"}


class PhaseMetricsError(ValueError):
    """Evidence is incomplete, inconsistent, unauthenticated, or ineligible."""


class TrustedReceiptIndex(ABC):
    """Out-of-band trust service used by reducers and the evaluator.

    Implementations belong to the integration layer.  They must return a
    receipt only after authenticating the producer/tool and immutably binding
    it to the requested artifact digest.  A plain mapping intentionally cannot
    satisfy this interface.
    """

    @property
    @abstractmethod
    def validator_identity(self) -> str:
        """Stable identity of the receipt-validation component."""

    @abstractmethod
    def resolve_authenticated_receipt(
        self, receipt_id: str, raw_artifact_sha256: str
    ) -> Mapping[str, Any] | None:
        """Return the authenticated receipt for this exact artifact, or None."""


def _integer(value: Any, name: str, *, positive: bool = False) -> int:
    if isinstance(value, bool) or not isinstance(value, int):
        raise PhaseMetricsError(f"{name} must be an integer")
    if value < (1 if positive else 0):
        qualifier = "positive" if positive else "nonnegative"
        raise PhaseMetricsError(f"{name} must be {qualifier}")
    return value


def _text(value: Any, name: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise PhaseMetricsError(f"{name} must be a non-empty string")
    return value


def _sha256_text(value: Any, name: str) -> str:
    result = _text(value, name).lower()
    if len(result) != 64 or any(character not in "0123456789abcdef" for character in result):
        raise PhaseMetricsError(f"{name} must be a canonical SHA-256")
    return result


def _sequence(value: Any, name: str) -> Sequence[Any]:
    if isinstance(value, (str, bytes)) or not isinstance(value, Sequence):
        raise PhaseMetricsError(f"{name} must be a sequence")
    return value


def _canonical_bytes(value: Any) -> bytes:
    try:
        return json.dumps(
            value,
            sort_keys=True,
            separators=(",", ":"),
            ensure_ascii=True,
            allow_nan=False,
        ).encode("utf-8")
    except (TypeError, ValueError) as error:
        raise PhaseMetricsError("evidence must be canonical JSON data") from error


def _digest(value: Any) -> str:
    return hashlib.sha256(_canonical_bytes(value)).hexdigest()


def _json_snapshot(value: Any, name: str) -> Any:
    try:
        return json.loads(_canonical_bytes(value))
    except json.JSONDecodeError as error:
        raise PhaseMetricsError(f"{name} is not stable canonical JSON") from error


def compute_raw_artifact_sha256(raw_artifact: Mapping[str, Any]) -> str:
    """Return the canonical digest which an authenticated receipt must bind."""

    if not isinstance(raw_artifact, Mapping):
        raise PhaseMetricsError("raw_artifact must be a mapping")
    return _digest(raw_artifact)


def compute_immutable_receipt_digest_sha256(receipt: Mapping[str, Any]) -> str:
    """Digest a receipt excluding its self-referential digest field."""

    if not isinstance(receipt, Mapping):
        raise PhaseMetricsError("receipt must be a mapping")
    payload = dict(receipt)
    payload.pop("immutable_receipt_digest_sha256", None)
    return _digest(payload)


def _ratio(value: Fraction) -> dict[str, int]:
    return {"numerator": value.numerator, "denominator": value.denominator}


def _fraction_float(value: Fraction, name: str) -> float:
    try:
        result = float(value)
    except OverflowError as error:
        raise PhaseMetricsError(f"{name} cannot be represented for reporting") from error
    if not math.isfinite(result):
        raise PhaseMetricsError(f"{name} must remain finite")
    return result


def _ratio_value(value: Mapping[str, Any], name: str) -> Fraction:
    if not isinstance(value, Mapping):
        raise PhaseMetricsError(f"{name} must be an exact ratio")
    numerator = _integer(value.get("numerator"), f"{name} numerator")
    denominator = _integer(value.get("denominator"), f"{name} denominator", positive=True)
    return Fraction(numerator, denominator)


def _bounds(request: Mapping[str, Any]) -> tuple[int, int]:
    start = _integer(request.get("start_monotonic_ns"), "start_monotonic_ns")
    end = _integer(request.get("end_monotonic_ns"), "end_monotonic_ns", positive=True)
    if end <= start:
        raise PhaseMetricsError("end_monotonic_ns must be greater than start_monotonic_ns")
    return start, end


def _validate_app_identity(value: Any) -> dict[str, int]:
    if not isinstance(value, Mapping):
        raise PhaseMetricsError("authenticated receipt lacks app process identity")
    return {
        "pid": _integer(value.get("pid"), "app PID", positive=True),
        "process_start_abstime": _integer(
            value.get("process_start_abstime"), "app process_start_abstime", positive=True
        ),
        "coalition_id": _integer(value.get("coalition_id"), "app coalition_id", positive=True),
    }


def _member_identity(value: Any, name: str, coalition_id: int) -> dict[str, Any]:
    if not isinstance(value, Mapping):
        raise PhaseMetricsError(f"{name} must be a mapping")
    role = value.get("role")
    if role not in _ROLES:
        raise PhaseMetricsError(f"{name} has an unsupported role")
    member = {
        "member_id": _text(value.get("member_id"), f"{name} member_id"),
        "pid": _integer(value.get("pid"), f"{name} PID", positive=True),
        "process_start_abstime": _integer(
            value.get("process_start_abstime"),
            f"{name} process_start_abstime",
            positive=True,
        ),
        "role": role,
        "coalition_id": _integer(
            value.get("coalition_id"), f"{name} coalition_id", positive=True
        ),
    }
    if member["coalition_id"] != coalition_id:
        raise PhaseMetricsError(f"{name} belongs to a different coalition")
    expected_member_id = f"{member['pid']}:{member['process_start_abstime']}"
    if member["member_id"] != expected_member_id:
        raise PhaseMetricsError(f"{name} member_id is not PID/start bound")
    return member


def _validate_member_lifecycles(
    raw_lifecycles: Any,
    coalition_id: int,
    final_tasks_started: int,
    final_tasks_exited: int,
    app_identity: Mapping[str, int],
) -> list[dict[str, Any]]:
    values = _sequence(raw_lifecycles, "member_lifecycles")
    if len(values) != final_tasks_started:
        raise PhaseMetricsError(
            "retained lifecycle count does not cover every coalition task ever started"
        )
    result: list[dict[str, Any]] = []
    member_ids: set[str] = set()
    start_ordinals: set[int] = set()
    exit_ordinals: set[int] = set()
    for index, raw_value in enumerate(values):
        member = _member_identity(raw_value, f"member lifecycle {index}", coalition_id)
        if member["member_id"] in member_ids:
            raise PhaseMetricsError("member lifecycle identities are not unique")
        member_ids.add(member["member_id"])
        start_ordinal = _integer(
            raw_value.get("tasks_started_ordinal"),
            f"member {member['member_id']} tasks_started_ordinal",
            positive=True,
        )
        if start_ordinal in start_ordinals:
            raise PhaseMetricsError("member start ordinals are not unique")
        start_ordinals.add(start_ordinal)
        started_ns = _integer(
            raw_value.get("started_monotonic_ns"),
            f"member {member['member_id']} start clock",
        )
        raw_exit_ordinal = raw_value.get("tasks_exited_ordinal")
        raw_exited_ns = raw_value.get("exited_monotonic_ns")
        raw_final = raw_value.get("final_rusage")
        exit_ordinal: int | None = None
        exited_ns: int | None = None
        final_hwm: int | None = None
        final_receipt_sha256: str | None = None
        if raw_exit_ordinal is not None:
            exit_ordinal = _integer(
                raw_exit_ordinal,
                f"member {member['member_id']} tasks_exited_ordinal",
                positive=True,
            )
            if exit_ordinal in exit_ordinals:
                raise PhaseMetricsError("member exit ordinals are not unique")
            exit_ordinals.add(exit_ordinal)
            exited_ns = _integer(
                raw_exited_ns,
                f"member {member['member_id']} exit clock",
                positive=True,
            )
            if exited_ns <= started_ns:
                raise PhaseMetricsError("member lifecycle end must follow its start")
            if not isinstance(raw_final, Mapping):
                raise PhaseMetricsError("every exited task requires retained final rusage")
            if (
                raw_final.get("terminal_capture_validated") is not True
                or raw_final.get("no_memory_activity_after_query") is not True
            ):
                raise PhaseMetricsError(
                    "exited member final rusage is not proven terminal"
                )
            final_started = _integer(
                raw_final.get("query_started_monotonic_ns"),
                f"member {member['member_id']} final rusage start",
            )
            final_finished = _integer(
                raw_final.get("query_finished_monotonic_ns"),
                f"member {member['member_id']} final rusage finish",
                positive=True,
            )
            if final_finished <= final_started or final_finished > exited_ns:
                raise PhaseMetricsError("final rusage must be a nonzero query completed before exit")
            if final_finished - final_started > MAX_QUERY_DURATION_NS:
                raise PhaseMetricsError("final rusage query exceeded maximum duration")
            final_hwm = _integer(
                raw_final.get("lifetime_max_phys_footprint_bytes"),
                f"member {member['member_id']} final lifetime footprint",
            )
            final_receipt_sha256 = _sha256_text(
                raw_final.get("final_rusage_receipt_sha256"),
                f"member {member['member_id']} final rusage receipt",
            )
            expected_final_digest = _digest(
                {
                    "member_id": member["member_id"],
                    "query_started_monotonic_ns": final_started,
                    "query_finished_monotonic_ns": final_finished,
                    "lifetime_max_phys_footprint_bytes": final_hwm,
                    "terminal_capture_validated": True,
                    "no_memory_activity_after_query": True,
                }
            )
            if final_receipt_sha256 != expected_final_digest:
                raise PhaseMetricsError("exited member final rusage receipt is not immutable")
        elif raw_exited_ns is not None or raw_final is not None:
            raise PhaseMetricsError("active member has contradictory exit/final-rusage data")
        result.append(
            {
                **member,
                "tasks_started_ordinal": start_ordinal,
                "tasks_exited_ordinal": exit_ordinal,
                "started_monotonic_ns": started_ns,
                "exited_monotonic_ns": exited_ns,
                "final_rusage_lifetime_max_phys_footprint_bytes": final_hwm,
                "final_rusage_receipt_sha256": final_receipt_sha256,
            }
        )
    if start_ordinals != set(range(1, final_tasks_started + 1)):
        raise PhaseMetricsError("member start ordinals do not exactly match tasks_started")
    if exit_ordinals != set(range(1, final_tasks_exited + 1)):
        raise PhaseMetricsError("member exit ordinals do not exactly match tasks_exited")
    ordered_starts = sorted(result, key=lambda value: value["tasks_started_ordinal"])
    if any(
        right["started_monotonic_ns"] < left["started_monotonic_ns"]
        for left, right in zip(ordered_starts, ordered_starts[1:])
    ):
        raise PhaseMetricsError("member start clocks contradict tasks_started ordinals")
    ordered_exits = sorted(
        (value for value in result if value["tasks_exited_ordinal"] is not None),
        key=lambda value: value["tasks_exited_ordinal"],
    )
    if any(
        right["exited_monotonic_ns"] < left["exited_monotonic_ns"]
        for left, right in zip(ordered_exits, ordered_exits[1:])
    ):
        raise PhaseMetricsError("member exit clocks contradict tasks_exited ordinals")
    apps = [
        value
        for value in result
        if value["pid"] == app_identity["pid"]
        and value["process_start_abstime"] == app_identity["process_start_abstime"]
        and value["coalition_id"] == app_identity["coalition_id"]
        and value["role"] == "app"
    ]
    if len(apps) != 1 or sum(value["role"] == "app" for value in result) != 1:
        raise PhaseMetricsError("artifact app identity is not exact in retained lifecycle")
    return result


def _validate_artifact(raw_artifact: Mapping[str, Any]) -> dict[str, Any]:
    if not isinstance(raw_artifact, Mapping):
        raise PhaseMetricsError("raw_artifact must be a mapping")
    if raw_artifact.get("schema") != RAW_ARTIFACT_SCHEMA:
        raise PhaseMetricsError("raw artifact schema is invalid")
    coalition_id = _integer(
        raw_artifact.get("coalition_id"), "artifact coalition_id", positive=True
    )
    app_identity = _validate_app_identity(raw_artifact.get("app_process_identity"))
    if app_identity["coalition_id"] != coalition_id:
        raise PhaseMetricsError("artifact app identity belongs to a different coalition")
    identity = {
        "artifact_id": _text(raw_artifact.get("artifact_id"), "artifact_id"),
        "receipt_id": _text(raw_artifact.get("receipt_id"), "receipt_id"),
        "candidate_id": _text(raw_artifact.get("candidate_id"), "candidate_id"),
        "asset_sha256": _sha256_text(raw_artifact.get("asset_sha256"), "asset_sha256"),
        "variant": _text(raw_artifact.get("variant"), "variant"),
        "run_id": _text(raw_artifact.get("run_id"), "run_id"),
        "scope_id": _text(raw_artifact.get("scope_id"), "scope_id"),
        "scope_kind": _text(raw_artifact.get("scope_kind"), "scope_kind"),
        "coalition_id": coalition_id,
        "app_process_identity": app_identity,
    }
    if identity["scope_kind"] != "resource_coalition":
        raise PhaseMetricsError("shipper evidence must use a resource coalition")
    schedule = raw_artifact.get("schedule")
    if not isinstance(schedule, Mapping):
        raise PhaseMetricsError("raw artifact has no exact schedule")
    origin = _integer(schedule.get("origin_monotonic_ns"), "schedule origin")
    period = _integer(schedule.get("period_ns"), "schedule period", positive=True)
    timebase_numer = _integer(
        schedule.get("mach_timebase_numer"), "mach timebase numerator", positive=True
    )
    timebase_denom = _integer(
        schedule.get("mach_timebase_denom"), "mach timebase denominator", positive=True
    )
    clock_domain = _text(schedule.get("clock_domain"), "schedule clock_domain")
    if clock_domain != "host_monotonic_ns":
        raise PhaseMetricsError("raw schedule uses an unsupported clock domain")
    if period != SAMPLE_INTERVAL_NS:
        raise PhaseMetricsError("raw artifact is not scheduled at exact 20 Hz")

    raw_records = _sequence(raw_artifact.get("records"), "raw records")
    if len(raw_records) < 2:
        raise PhaseMetricsError("raw artifact requires at least two records")
    records: list[dict[str, Any]] = []
    prior_start: int | None = None
    prior_finish: int | None = None
    prior_cpu_ticks: int | None = None
    prior_tasks_started: int | None = None
    prior_tasks_exited: int | None = None
    for index, raw_record in enumerate(raw_records):
        if not isinstance(raw_record, Mapping):
            raise PhaseMetricsError(f"record {index} must be a mapping")
        if _integer(raw_record.get("sample_index"), f"record {index} sample_index") != index:
            raise PhaseMetricsError("raw sample indexes are not contiguous")
        scheduled = _integer(
            raw_record.get("scheduled_monotonic_ns"),
            f"record {index} scheduled_monotonic_ns",
        )
        if scheduled != origin + index * SAMPLE_INTERVAL_NS:
            raise PhaseMetricsError("scheduled deadlines are not origin plus exact 50 ms offsets")
        started = _integer(
            raw_record.get("query_started_monotonic_ns"),
            f"record {index} query_started_monotonic_ns",
        )
        finished = _integer(
            raw_record.get("query_finished_monotonic_ns"),
            f"record {index} query_finished_monotonic_ns",
        )
        if finished <= started:
            raise PhaseMetricsError("coalition query duration must be nonzero")
        if finished - started > MAX_QUERY_DURATION_NS:
            raise PhaseMetricsError("coalition query exceeded maximum duration")
        if prior_finish is not None and started < prior_finish:
            raise PhaseMetricsError("coalition queries overlap")
        if prior_start is not None:
            gap = started - prior_start
            if gap < MIN_CAPTURE_START_GAP_NS or gap > MAX_CAPTURE_START_GAP_NS:
                raise PhaseMetricsError("observed queries show burst or catch-up scheduling")
        lateness = started - scheduled
        if lateness < 0:
            raise PhaseMetricsError("coalition query started before its deadline")
        if lateness > MAX_CAPTURE_LATENESS_NS:
            raise PhaseMetricsError("coalition query exceeded maximum deadline lateness")
        cpu_ticks = _integer(
            raw_record.get("coalition_cpu_time_ticks"),
            f"record {index} coalition_cpu_time_ticks",
        )
        tasks_started = _integer(
            raw_record.get("tasks_started"), f"record {index} tasks_started"
        )
        tasks_exited = _integer(
            raw_record.get("tasks_exited"), f"record {index} tasks_exited"
        )
        active_count = _integer(
            raw_record.get("active_count"), f"record {index} active_count"
        )
        if tasks_exited > tasks_started or active_count != tasks_started - tasks_exited:
            raise PhaseMetricsError("coalition task counters disagree with active_count")
        if prior_cpu_ticks is not None and cpu_ticks < prior_cpu_ticks:
            raise PhaseMetricsError("coalition cumulative CPU ticks moved backwards")
        if prior_tasks_started is not None and tasks_started < prior_tasks_started:
            raise PhaseMetricsError("coalition tasks_started moved backwards")
        if prior_tasks_exited is not None and tasks_exited < prior_tasks_exited:
            raise PhaseMetricsError("coalition tasks_exited moved backwards")
        live_members = _sequence(raw_record.get("live_members"), f"record {index} live_members")
        if len(live_members) != active_count:
            raise PhaseMetricsError("live member list does not match coalition active_count")
        if raw_record.get("scope_id") != identity["scope_id"]:
            raise PhaseMetricsError("record belongs to a different execution scope")
        if raw_record.get("producer_receipt_id") != identity["receipt_id"]:
            raise PhaseMetricsError("record is not linked to the artifact receipt")
        if raw_record.get("coalition_id") != coalition_id:
            raise PhaseMetricsError("record belongs to a different resource coalition")
        records.append(
            {
                "sample_index": index,
                "scheduled_monotonic_ns": scheduled,
                "query_started_monotonic_ns": started,
                "query_finished_monotonic_ns": finished,
                "coalition_cpu_time_ticks": cpu_ticks,
                "tasks_started": tasks_started,
                "tasks_exited": tasks_exited,
                "active_count": active_count,
                "coalition_phys_footprint_bytes_diagnostic": _integer(
                    raw_record.get("coalition_phys_footprint_bytes"),
                    f"record {index} coalition phys_footprint diagnostic",
                ),
                "raw_live_members": list(live_members),
            }
        )
        prior_start = started
        prior_finish = finished
        prior_cpu_ticks = cpu_ticks
        prior_tasks_started = tasks_started
        prior_tasks_exited = tasks_exited

    lifecycles = _validate_member_lifecycles(
        raw_artifact.get("member_lifecycles"),
        coalition_id,
        records[-1]["tasks_started"],
        records[-1]["tasks_exited"],
        app_identity,
    )
    lifecycle_by_id = {value["member_id"]: value for value in lifecycles}
    prior_member_hwm: dict[str, int] = {}
    for record in records:
        for lifecycle in lifecycles:
            started_counted = (
                lifecycle["tasks_started_ordinal"] <= record["tasks_started"]
            )
            if started_counted and lifecycle["started_monotonic_ns"] > record[
                "query_finished_monotonic_ns"
            ]:
                raise PhaseMetricsError("tasks_started advanced before retained member start")
            if not started_counted and lifecycle["started_monotonic_ns"] < record[
                "query_started_monotonic_ns"
            ]:
                raise PhaseMetricsError("retained member start is missing from tasks_started")
            if lifecycle["tasks_exited_ordinal"] is not None:
                exited_counted = (
                    lifecycle["tasks_exited_ordinal"] <= record["tasks_exited"]
                )
                if lifecycle["exited_monotonic_ns"] is None:
                    raise PhaseMetricsError("exited member lacks an exit clock")
                if exited_counted and lifecycle["exited_monotonic_ns"] > record[
                    "query_finished_monotonic_ns"
                ]:
                    raise PhaseMetricsError("tasks_exited advanced before retained member exit")
                if not exited_counted and lifecycle["exited_monotonic_ns"] < record[
                    "query_started_monotonic_ns"
                ]:
                    raise PhaseMetricsError("retained member exit is missing from tasks_exited")
        expected_live = {
            value["member_id"]
            for value in lifecycles
            if value["tasks_started_ordinal"] <= record["tasks_started"]
            and (
                value["tasks_exited_ordinal"] is None
                or value["tasks_exited_ordinal"] > record["tasks_exited"]
            )
        }
        observed: dict[str, int] = {}
        for member_index, raw_member in enumerate(record.pop("raw_live_members")):
            member = _member_identity(
                raw_member,
                f"record {record['sample_index']} live member {member_index}",
                coalition_id,
            )
            member_id = member["member_id"]
            if member_id in observed or member_id not in lifecycle_by_id:
                raise PhaseMetricsError("live member is duplicated or absent from lifecycle audit")
            expected_identity = lifecycle_by_id[member_id]
            if any(member[key] != expected_identity[key] for key in member):
                raise PhaseMetricsError("live member identity differs from lifecycle audit")
            hwm = _integer(
                raw_member.get("proc_rusage_lifetime_max_phys_footprint_bytes"),
                f"live member {member_id} lifetime footprint",
            )
            if member_id in prior_member_hwm and hwm < prior_member_hwm[member_id]:
                raise PhaseMetricsError("per-member proc rusage lifetime footprint moved backwards")
            prior_member_hwm[member_id] = hwm
            observed[member_id] = hwm
        if set(observed) != expected_live or len(observed) != record["active_count"]:
            raise PhaseMetricsError("live identities do not reconcile with coalition task counters")
        record["live_member_lifetime_hwm_bytes"] = observed
    for lifecycle in lifecycles:
        if lifecycle["tasks_exited_ordinal"] is not None:
            final_hwm = lifecycle[
                "final_rusage_lifetime_max_phys_footprint_bytes"
            ]
            if (
                not isinstance(final_hwm, int)
                or final_hwm < prior_member_hwm.get(lifecycle["member_id"], 0)
            ):
                raise PhaseMetricsError(
                    "exited member final rusage is below its sampled lifetime HWM"
                )
    return {
        **identity,
        "origin_monotonic_ns": origin,
        "period_ns": period,
        "mach_timebase_numer": timebase_numer,
        "mach_timebase_denom": timebase_denom,
        "clock_domain": clock_domain,
        "records": records,
        "member_lifecycles": lifecycles,
        "member_lifecycle_audit_sha256": _digest(
            raw_artifact.get("member_lifecycles")
        ),
        "raw_artifact_sha256": compute_raw_artifact_sha256(raw_artifact),
    }


def _trusted_receipt(
    trusted_receipt_index: TrustedReceiptIndex,
    artifact: Mapping[str, Any],
) -> dict[str, Any]:
    if isinstance(trusted_receipt_index, Mapping) or not isinstance(
        trusted_receipt_index, TrustedReceiptIndex
    ):
        raise PhaseMetricsError("an integration-owned TrustedReceiptIndex is required")
    validator_identity = _text(
        trusted_receipt_index.validator_identity, "trusted index validator_identity"
    )
    receipt = trusted_receipt_index.resolve_authenticated_receipt(
        artifact["receipt_id"], artifact["raw_artifact_sha256"]
    )
    if not isinstance(receipt, Mapping):
        raise PhaseMetricsError("authenticated receipt is absent from the trusted index")
    receipt = _json_snapshot(receipt, "authenticated receipt")
    if not isinstance(receipt, Mapping):
        raise PhaseMetricsError("authenticated receipt is not a JSON object")
    if receipt.get("schema") != TRUSTED_RECEIPT_SCHEMA:
        raise PhaseMetricsError("authenticated receipt schema is invalid")
    if receipt.get("validated_by") != validator_identity:
        raise PhaseMetricsError("receipt validator identity does not match the trusted index")
    if receipt.get("authentication_validated") is not True:
        raise PhaseMetricsError("producer authentication was not validated")
    for key, label in (
        ("producer_identity", "producer identity"),
        ("producer_tool_identity", "producer tool identity"),
        ("producer_tool_version", "producer tool version"),
        ("producer_authentication_key_id", "producer authentication key id"),
    ):
        _text(receipt.get(key), label)
    for key in (
        "producer_tool_binary_sha256",
        "producer_authentication_evidence_sha256",
        "membership_lifecycle_audit_sha256",
    ):
        _sha256_text(receipt.get(key), key)
    if (
        receipt.get("receipt_id") != artifact["receipt_id"]
        or receipt.get("raw_artifact_sha256") != artifact["raw_artifact_sha256"]
        or receipt.get("scope_id") != artifact["scope_id"]
        or receipt.get("scope_kind") != artifact["scope_kind"]
        or receipt.get("candidate_id") != artifact["candidate_id"]
        or receipt.get("asset_sha256") != artifact["asset_sha256"]
        or receipt.get("variant") != artifact["variant"]
        or receipt.get("run_id") != artifact["run_id"]
        or receipt.get("coalition_id") != artifact["coalition_id"]
        or receipt.get("mach_timebase_numer") != artifact["mach_timebase_numer"]
        or receipt.get("mach_timebase_denom") != artifact["mach_timebase_denom"]
        or receipt.get("clock_domain") != artifact["clock_domain"]
    ):
        raise PhaseMetricsError("authenticated receipt is bound to different raw evidence")
    if (
        receipt.get("coverage_kind") != "xnu_resource_coalition_v1"
        or receipt.get("cpu_counter_semantics")
        != "coalition_info_resource_usage.cpu_time_mach_absolute_ticks"
        or receipt.get("memory_counter_semantics")
        != "sum_authenticated_member_lifetime_hwm_nonco_temporal_upper_bound"
        or receipt.get("includes_transient_members") is not True
        or receipt.get("includes_exited_members") is not True
        or receipt.get("continuous_membership_lifecycle_audit") is not True
        or receipt.get("tasks_counter_semantics_validated") is not True
        or receipt.get("tasks_counter_delta_ordinals_complete") is not True
        or receipt.get("exec_transition_accounting_validated") is not True
        or receipt.get("event_clock_correlation_validated") is not True
    ):
        raise PhaseMetricsError("receipt does not prove transient-complete scope counters")
    if (
        receipt.get("membership_lifecycle_audit_sha256")
        != artifact["member_lifecycle_audit_sha256"]
    ):
        raise PhaseMetricsError("receipt does not bind the exact member lifecycle audit")
    final_receipts = [
        {
            "member_id": value["member_id"],
            "final_rusage_receipt_sha256": value["final_rusage_receipt_sha256"],
        }
        for value in artifact["member_lifecycles"]
        if value["tasks_exited_ordinal"] is not None
    ]
    if receipt.get("final_rusage_receipts_sha256") != _digest(final_receipts):
        raise PhaseMetricsError("receipt does not bind every exited member final rusage")
    lifecycle_start = _integer(
        receipt.get("scope_lifecycle_started_monotonic_ns"), "scope lifecycle start"
    )
    lifecycle_end = _integer(
        receipt.get("scope_lifecycle_ended_monotonic_ns"),
        "scope lifecycle end",
        positive=True,
    )
    if lifecycle_end <= lifecycle_start:
        raise PhaseMetricsError("scope lifecycle interval is invalid")
    if any(
        value["started_monotonic_ns"] < lifecycle_start
        or value["started_monotonic_ns"] > lifecycle_end
        or (
            value["exited_monotonic_ns"] is not None
            and value["exited_monotonic_ns"] > lifecycle_end
        )
        for value in artifact["member_lifecycles"]
    ):
        raise PhaseMetricsError("member lifecycle lies outside authenticated scope lifecycle")
    expected_digest = compute_immutable_receipt_digest_sha256(receipt)
    if receipt.get("immutable_receipt_digest_sha256") != expected_digest:
        raise PhaseMetricsError("authenticated receipt digest is invalid or mutable")
    app_identity = _validate_app_identity(receipt.get("app_process_identity"))
    if app_identity != artifact["app_process_identity"]:
        raise PhaseMetricsError("receipt app identity differs from retained raw evidence")
    deliveries = receipt.get("scrub_deliveries", [])
    if isinstance(deliveries, (str, bytes)) or not isinstance(deliveries, Sequence):
        raise PhaseMetricsError("receipt scrub_deliveries must be a sequence")
    scrub_request_id = receipt.get("scrub_request_id")
    if deliveries:
        scrub_request_id = _text(scrub_request_id, "receipt scrub_request_id")
    elif scrub_request_id is not None:
        raise PhaseMetricsError("receipt has a scrub request without delivery evidence")
    phase_requests = receipt.get("phase_requests", [])
    if isinstance(phase_requests, (str, bytes)) or not isinstance(
        phase_requests, Sequence
    ):
        raise PhaseMetricsError("receipt phase_requests must be a sequence")
    normalized_phase_requests = [
        _validate_phase_request(value) for value in phase_requests
    ]
    request_ids = [value["request_id"] for value in normalized_phase_requests]
    if len(request_ids) != len(set(request_ids)):
        raise PhaseMetricsError("authenticated phase request identities are not unique")
    return {
        "receipt": dict(receipt),
        "receipt_id": artifact["receipt_id"],
        "immutable_receipt_digest_sha256": expected_digest,
        "validator_identity": validator_identity,
        "producer_identity": receipt["producer_identity"],
        "producer_tool_identity": receipt["producer_tool_identity"],
        "producer_tool_version": receipt["producer_tool_version"],
        "scope_lifecycle_started_monotonic_ns": lifecycle_start,
        "scope_lifecycle_ended_monotonic_ns": lifecycle_end,
        "app_process_identity": app_identity,
        "scrub_deliveries": list(deliveries),
        "scrub_request_id": scrub_request_id,
        "phase_requests": normalized_phase_requests,
    }


def _conservative_bracket(
    records: Sequence[Mapping[str, int]], start_ns: int, end_ns: int
) -> tuple[int, int]:
    baselines = [
        index
        for index, record in enumerate(records)
        if record["query_finished_monotonic_ns"] <= start_ns
    ]
    terminals = [
        index
        for index, record in enumerate(records)
        if record["query_started_monotonic_ns"] >= end_ns
    ]
    if not baselines or not terminals:
        raise PhaseMetricsError("raw artifact does not conservatively bracket both bounds")
    left = baselines[-1]
    right = terminals[0]
    if right <= left:
        raise PhaseMetricsError("conservative bracket is not ordered")
    return left, right


def _require_lifecycle_coverage(
    claim: Mapping[str, Any],
    records: Sequence[Mapping[str, int]],
    left: int,
    right: int,
) -> None:
    if (
        claim["scope_lifecycle_started_monotonic_ns"]
        > records[left]["query_started_monotonic_ns"]
        or claim["scope_lifecycle_ended_monotonic_ns"]
        < records[right]["query_finished_monotonic_ns"]
    ):
        raise PhaseMetricsError("authenticated scope lifecycle does not cover outer brackets")


def _validate_phase_request(phase_request: Mapping[str, Any]) -> dict[str, Any]:
    if not isinstance(phase_request, Mapping):
        raise PhaseMetricsError("phase_request must be a mapping")
    if phase_request.get("schema") != PHASE_REQUEST_SCHEMA:
        raise PhaseMetricsError("phase request schema is invalid")
    phase = phase_request.get("phase")
    if phase not in _PHASES:
        raise PhaseMetricsError("phase request must identify cold, warm, or steady")
    expected_keys = {
        "schema",
        "request_id",
        "phase",
        "start_monotonic_ns",
        "end_monotonic_ns",
    }
    if phase == "cold":
        expected_keys.add("launch_request_monotonic_ns")
    if set(phase_request) != expected_keys:
        raise PhaseMetricsError("phase request fields do not exactly match its schema")
    start, end = _bounds(phase_request)
    request = {
        "schema": PHASE_REQUEST_SCHEMA,
        "request_id": _text(phase_request.get("request_id"), "phase request_id"),
        "phase": phase,
        "start_monotonic_ns": start,
        "end_monotonic_ns": end,
    }
    if phase == "cold":
        launch = _integer(
            phase_request.get("launch_request_monotonic_ns"),
            "launch_request_monotonic_ns",
        )
        if launch != start:
            raise PhaseMetricsError("cold phase must begin at the launch request")
        request["launch_request_monotonic_ns"] = launch
    return request


def _member_memory_upper_bound(
    artifact: Mapping[str, Any], terminal: Mapping[str, Any]
) -> tuple[int, list[dict[str, Any]]]:
    contributors: list[dict[str, Any]] = []
    live_hwm = terminal["live_member_lifetime_hwm_bytes"]
    for member in artifact["member_lifecycles"]:
        if member["tasks_started_ordinal"] > terminal["tasks_started"]:
            continue
        exited_by_terminal = (
            member["tasks_exited_ordinal"] is not None
            and member["tasks_exited_ordinal"] <= terminal["tasks_exited"]
        )
        if exited_by_terminal:
            hwm = member["final_rusage_lifetime_max_phys_footprint_bytes"]
            source = "authenticated exited-member final proc rusage"
            receipt_sha256 = member["final_rusage_receipt_sha256"]
        else:
            if member["member_id"] not in live_hwm:
                raise PhaseMetricsError(
                    "terminal live member lacks proc-rusage lifetime footprint"
                )
            hwm = live_hwm[member["member_id"]]
            source = "terminal live-member proc rusage"
            receipt_sha256 = None
        if not isinstance(hwm, int):
            raise PhaseMetricsError("member lifetime footprint proof is incomplete")
        contributors.append(
            {
                "member_id": member["member_id"],
                "lifetime_max_phys_footprint_bytes": hwm,
                "source": source,
                "final_rusage_receipt_sha256": receipt_sha256,
            }
        )
    return sum(value["lifetime_max_phys_footprint_bytes"] for value in contributors), contributors


def _phase_core(
    artifact: Mapping[str, Any],
    claim: Mapping[str, Any],
    request: Mapping[str, Any],
) -> dict[str, Any]:
    start = request["start_monotonic_ns"]
    end = request["end_monotonic_ns"]
    records = artifact["records"]
    left, right = _conservative_bracket(records, start, end)
    _require_lifecycle_coverage(claim, records, left, right)
    raw_claim = claim["receipt"]
    app_lifecycle = next(
        value for value in artifact["member_lifecycles"] if value["role"] == "app"
    )
    if request["phase"] == "cold":
        scope_created = _integer(
            raw_claim.get("scope_created_monotonic_ns"), "scope created clock"
        )
        if scope_created > start:
            raise PhaseMetricsError("cold execution scope was created after launch")
        if scope_created != claim["scope_lifecycle_started_monotonic_ns"]:
            raise PhaseMetricsError(
                "cold coalition creation does not equal authenticated lifecycle start"
            )
        if raw_claim.get("cold_scope_no_prior_workload_contamination") is not True:
            raise PhaseMetricsError("cold scope may contain prior workload CPU or memory")
        if raw_claim.get("cold_baseline_counter_validated") is not True:
            raise PhaseMetricsError("cold same-scope prelaunch baseline is not validated")
        if (
            raw_claim.get("cold_new_launch_coalition") is not True
            or raw_claim.get("cold_no_preexisting_app") is not True
        ):
            raise PhaseMetricsError("cold receipt does not prove a new app-free launch coalition")
        if scope_created > records[left]["query_started_monotonic_ns"]:
            raise PhaseMetricsError("cold baseline predates execution-scope creation")
        if records[left]["tasks_started"] != 0 or records[left]["tasks_exited"] != 0:
            raise PhaseMetricsError("cold prelaunch coalition baseline already contains tasks")
        if any(
            value["started_monotonic_ns"] < start
            for value in artifact["member_lifecycles"]
        ):
            raise PhaseMetricsError("cold coalition contains prelaunch workload")
        if app_lifecycle["started_monotonic_ns"] < start:
            raise PhaseMetricsError("cold app already existed before launch request")
        if app_lifecycle["started_monotonic_ns"] > end:
            raise PhaseMetricsError("cold app did not start within the launch phase")
    elif app_lifecycle["started_monotonic_ns"] > start:
        raise PhaseMetricsError("app was not live at phase start")
    if (
        app_lifecycle["exited_monotonic_ns"] is not None
        and app_lifecycle["exited_monotonic_ns"] < end
    ):
        raise PhaseMetricsError("app exited before the phase ended")
    baseline = records[left]
    terminal = records[right]
    cpu_delta_ticks = (
        terminal["coalition_cpu_time_ticks"] - baseline["coalition_cpu_time_ticks"]
    )
    cpu_delta_exact = Fraction(
        cpu_delta_ticks * artifact["mach_timebase_numer"],
        artifact["mach_timebase_denom"],
    )
    if cpu_delta_exact.denominator != 1:
        raise PhaseMetricsError("exact coalition tick delta does not convert to integral ns")
    cpu_delta = cpu_delta_exact.numerator
    elapsed = end - start
    cpu_percent = Fraction(cpu_delta * 100, elapsed)
    cpu_ms = Fraction(cpu_delta, 1_000_000)
    memory_upper_bound, memory_contributors = _member_memory_upper_bound(
        artifact, terminal
    )
    return {
        "phase": request["phase"],
        "request_id": request["request_id"],
        "start_monotonic_ns": start,
        "end_monotonic_ns": end,
        "elapsed_ns": elapsed,
        "baseline_record_index": left,
        "terminal_record_index": right,
        "baseline_snapshot_started_monotonic_ns": baseline[
            "query_started_monotonic_ns"
        ],
        "baseline_snapshot_finished_monotonic_ns": baseline[
            "query_finished_monotonic_ns"
        ],
        "terminal_snapshot_started_monotonic_ns": terminal[
            "query_started_monotonic_ns"
        ],
        "terminal_snapshot_finished_monotonic_ns": terminal[
            "query_finished_monotonic_ns"
        ],
        "baseline_coalition_cpu_time_ticks": baseline["coalition_cpu_time_ticks"],
        "terminal_coalition_cpu_time_ticks": terminal["coalition_cpu_time_ticks"],
        "coalition_cpu_time_delta_ticks": cpu_delta_ticks,
        "mach_timebase_numer": artifact["mach_timebase_numer"],
        "mach_timebase_denom": artifact["mach_timebase_denom"],
        "cpu_time_ns_exact": {"numerator": cpu_delta, "denominator": 1},
        "cpu_time_ms_exact": _ratio(cpu_ms),
        "cpu_percent_exact": _ratio(cpu_percent),
        "cpu_time_ms": _fraction_float(cpu_ms, "CPU time milliseconds"),
        "time_weighted_cpu_percent": _fraction_float(cpu_percent, "CPU percent"),
        "member_lifetime_hwm_sum_upper_bound_bytes": memory_upper_bound,
        "hard_gate_memory_upper_bound_bytes": memory_upper_bound,
        "member_memory_upper_bound_contributors": memory_contributors,
        "coalition_phys_footprint_bytes_diagnostic_only": terminal[
            "coalition_phys_footprint_bytes_diagnostic"
        ],
        "evidence": {
            "boundary_method": "completed-before/started-after conservative bracket",
            "boundary_cpu_cannot_undercount": True,
            "interpolation_used": False,
            "cpu_elapsed_denominator_is_exact_phase_duration": True,
            "memory_measurement_kind": (
                "sum of authenticated per-member lifetime HWMs; "
                "non-co-temporal conservative upper bound"
            ),
            "coalition_instantaneous_phys_footprint_used_for_gate": False,
            "memory_includes_transient_and_exited_coalition_members": True,
            "tasks_started_exited_reconciled_to_lifecycle_ordinals": True,
            "sample_period_ns": SAMPLE_INTERVAL_NS,
            "query_timing_validated": True,
            "scope_lifecycle_outer_bracket_covered": True,
        },
    }


def _identity_output(
    artifact: Mapping[str, Any], claim: Mapping[str, Any]
) -> dict[str, Any]:
    return {
        "artifact_id": artifact["artifact_id"],
        "raw_artifact_sha256": artifact["raw_artifact_sha256"],
        "receipt_id": artifact["receipt_id"],
        "immutable_receipt_digest_sha256": claim[
            "immutable_receipt_digest_sha256"
        ],
        "receipt_validator_identity": claim["validator_identity"],
        "producer_identity": claim["producer_identity"],
        "producer_tool_identity": claim["producer_tool_identity"],
        "producer_tool_version": claim["producer_tool_version"],
        "candidate_id": artifact["candidate_id"],
        "asset_sha256": artifact["asset_sha256"],
        "variant": artifact["variant"],
        "run_id": artifact["run_id"],
        "scope_id": artifact["scope_id"],
        "scope_kind": artifact["scope_kind"],
        "coalition_id": artifact["coalition_id"],
        "clock_domain": artifact["clock_domain"],
        "app_process_identity": claim["app_process_identity"],
    }


def _seal(value: dict[str, Any], digest_field: str) -> dict[str, Any]:
    if digest_field in value:
        raise PhaseMetricsError("digest field must not be present before sealing")
    result = dict(value)
    result[digest_field] = _digest(value)
    return result


def reduce_phase(
    raw_artifact: Mapping[str, Any],
    phase_request: Mapping[str, Any],
    *,
    trusted_receipt_index: TrustedReceiptIndex,
) -> dict[str, Any]:
    """Reduce one cold, warm, or steady phase from retained raw evidence."""

    raw_snapshot = _json_snapshot(raw_artifact, "raw artifact")
    request_snapshot = _json_snapshot(phase_request, "phase request")
    artifact = _validate_artifact(raw_snapshot)
    claim = _trusted_receipt(trusted_receipt_index, artifact)
    request = _validate_phase_request(request_snapshot)
    if request not in claim["phase_requests"]:
        raise PhaseMetricsError(
            "phase bounds and event identity are not authenticated by the receipt"
        )
    metric = _phase_core(artifact, claim, request)
    body = {
        "schema": PHASE_REDUCTION_SCHEMA,
        "threshold_policy_version": THRESHOLD_POLICY_VERSION,
        **_identity_output(artifact, claim),
        **metric,
        "raw_artifact": raw_snapshot,
        "phase_request": request_snapshot,
    }
    return _seal(body, "reduction_sha256")


def _validate_scrub_request(scrub_request: Mapping[str, Any]) -> dict[str, Any]:
    if not isinstance(scrub_request, Mapping):
        raise PhaseMetricsError("scrub_request must be a mapping")
    if scrub_request.get("schema") != SCRUB_REQUEST_SCHEMA:
        raise PhaseMetricsError("scrub request schema is invalid")
    if set(scrub_request) != {"schema", "request_id", "gestures"}:
        raise PhaseMetricsError("scrub request fields do not exactly match its schema")
    gestures = _sequence(scrub_request.get("gestures"), "scrub gestures")
    if len(gestures) != 2:
        raise PhaseMetricsError("scrub requires exactly two gesture legs")
    normalized: list[dict[str, Any]] = []
    for index, gesture in enumerate(gestures):
        if not isinstance(gesture, Mapping):
            raise PhaseMetricsError(f"scrub gesture {index} must be a mapping")
        if set(gesture) != {
            "request_id",
            "gesture_id",
            "direction",
            "delivery_evidence_id",
            "start_monotonic_ns",
            "end_monotonic_ns",
        }:
            raise PhaseMetricsError("scrub gesture fields do not exactly match its schema")
        start, end = _bounds(gesture)
        if end - start < ROLLING_CPU_WINDOW_NS:
            raise PhaseMetricsError("each scrub leg must cover at least 250 ms")
        direction = gesture.get("direction")
        if direction != _DIRECTIONS[index]:
            raise PhaseMetricsError("scrub legs must be ordered forward then reverse")
        normalized.append(
            {
                "request_id": _text(gesture.get("request_id"), "gesture request_id"),
                "gesture_id": _text(gesture.get("gesture_id"), "gesture_id"),
                "direction": direction,
                "delivery_evidence_id": _text(
                    gesture.get("delivery_evidence_id"), "delivery_evidence_id"
                ),
                "start_monotonic_ns": start,
                "end_monotonic_ns": end,
            }
        )
    if normalized[0]["end_monotonic_ns"] > normalized[1]["start_monotonic_ns"]:
        raise PhaseMetricsError("scrub gesture legs overlap")
    if (
        len({item["request_id"] for item in normalized}) != 2
        or len({item["gesture_id"] for item in normalized}) != 2
        or len({item["delivery_evidence_id"] for item in normalized}) != 2
    ):
        raise PhaseMetricsError(
            "scrub request, gesture, and delivery identities must be distinct"
        )
    return {
        "schema": SCRUB_REQUEST_SCHEMA,
        "request_id": _text(scrub_request.get("request_id"), "scrub request_id"),
        "gestures": normalized,
    }


def _delivery_claim(gesture: Mapping[str, Any]) -> dict[str, Any]:
    return {
        "request_id": gesture["request_id"],
        "gesture_id": gesture["gesture_id"],
        "direction": gesture["direction"],
        "delivery_evidence_id": gesture["delivery_evidence_id"],
        "start_monotonic_ns": gesture["start_monotonic_ns"],
        "end_monotonic_ns": gesture["end_monotonic_ns"],
    }


def _rolling_proofs(
    artifact: Mapping[str, Any], start_ns: int, end_ns: int
) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    records = artifact["records"]
    domain_end = end_ns - ROLLING_CPU_WINDOW_NS
    probes = {start_ns, domain_end}
    for record in records:
        finish = record["query_finished_monotonic_ns"]
        terminal_break = record["query_started_monotonic_ns"] - ROLLING_CPU_WINDOW_NS
        for probe in (finish - 1, finish, terminal_break, terminal_break + 1):
            if start_ns <= probe <= domain_end:
                probes.add(probe)
    proofs: list[dict[str, Any]] = []
    for window_start in sorted(probes):
        window_end = window_start + ROLLING_CPU_WINDOW_NS
        left, right = _conservative_bracket(records, window_start, window_end)
        delta_ticks = (
            records[right]["coalition_cpu_time_ticks"]
            - records[left]["coalition_cpu_time_ticks"]
        )
        exact_delta = Fraction(
            delta_ticks * artifact["mach_timebase_numer"],
            artifact["mach_timebase_denom"],
        )
        if exact_delta.denominator != 1:
            raise PhaseMetricsError(
                "rolling coalition tick delta does not convert to integral ns"
            )
        delta = exact_delta.numerator
        percent = Fraction(delta * 100, ROLLING_CPU_WINDOW_NS)
        proofs.append(
            {
                "window_start_monotonic_ns": window_start,
                "window_end_monotonic_ns": window_end,
                "baseline_record_index": left,
                "terminal_record_index": right,
                "baseline_snapshot_finished_monotonic_ns": records[left][
                    "query_finished_monotonic_ns"
                ],
                "terminal_snapshot_started_monotonic_ns": records[right][
                    "query_started_monotonic_ns"
                ],
                "coalition_cpu_time_delta_ticks": delta_ticks,
                "cpu_time_ns_exact": {"numerator": delta, "denominator": 1},
                "cpu_percent_exact": _ratio(percent),
            }
        )
    worst = max(
        proofs,
        key=lambda proof: _ratio_value(proof["cpu_percent_exact"], "rolling percent"),
    )
    return proofs, worst


def reduce_scrub(
    raw_artifact: Mapping[str, Any],
    scrub_request: Mapping[str, Any],
    *,
    trusted_receipt_index: TrustedReceiptIndex,
) -> dict[str, Any]:
    """Reduce two provenance-bound scrub legs and every 250 ms window state."""

    raw_snapshot = _json_snapshot(raw_artifact, "raw artifact")
    request_snapshot = _json_snapshot(scrub_request, "scrub request")
    artifact = _validate_artifact(raw_snapshot)
    claim = _trusted_receipt(trusted_receipt_index, artifact)
    request = _validate_scrub_request(request_snapshot)
    expected_deliveries = [_delivery_claim(item) for item in request["gestures"]]
    if (
        claim["scrub_request_id"] != request["request_id"]
        or claim["scrub_deliveries"] != expected_deliveries
    ):
        raise PhaseMetricsError("scrub delivery evidence is not authenticated by the receipt")
    legs: list[dict[str, Any]] = []
    outer_left: int | None = None
    outer_right: int | None = None
    for gesture in request["gestures"]:
        phase_request = {
            "phase": "scrub",
            "request_id": gesture["request_id"],
            "start_monotonic_ns": gesture["start_monotonic_ns"],
            "end_monotonic_ns": gesture["end_monotonic_ns"],
        }
        metric = _phase_core(artifact, claim, phase_request)
        proofs, worst = _rolling_proofs(
            artifact,
            gesture["start_monotonic_ns"],
            gesture["end_monotonic_ns"],
        )
        outer_left = metric["baseline_record_index"] if outer_left is None else min(
            outer_left, metric["baseline_record_index"]
        )
        outer_right = metric["terminal_record_index"] if outer_right is None else max(
            outer_right, metric["terminal_record_index"]
        )
        baseline_query_start = artifact["records"][
            metric["baseline_record_index"]
        ]["query_started_monotonic_ns"]
        terminal_query_finish = artifact["records"][
            metric["terminal_record_index"]
        ]["query_finished_monotonic_ns"]
        participant_member_ids = sorted(
            value["member_id"]
            for value in artifact["member_lifecycles"]
            if value["started_monotonic_ns"] <= terminal_query_finish
            and (
                value["exited_monotonic_ns"] is None
                or value["exited_monotonic_ns"] >= baseline_query_start
            )
        )
        legs.append(
            {
                **metric,
                "gesture_id": gesture["gesture_id"],
                "direction": gesture["direction"],
                "delivery_evidence_id": gesture["delivery_evidence_id"],
                "participant_member_ids": participant_member_ids,
                "rolling_window_ns": ROLLING_CPU_WINDOW_NS,
                "rolling_proof_enumeration": "all integer-ns state boundaries and +epsilon",
                "rolling_window_proofs": proofs,
                "rolling_cpu_max_percent_exact": worst["cpu_percent_exact"],
                "rolling_cpu_max_percent": _fraction_float(
                    _ratio_value(worst["cpu_percent_exact"], "rolling maximum"),
                    "rolling CPU maximum",
                ),
                "rolling_worst_window": worst,
            }
        )
    if outer_left is None or outer_right is None:
        raise PhaseMetricsError("scrub outer bracket is incomplete")
    if legs[0]["participant_member_ids"] != legs[1]["participant_member_ids"]:
        raise PhaseMetricsError("scrub legs do not have the same exact coalition member set")
    _require_lifecycle_coverage(claim, artifact["records"], outer_left, outer_right)
    body = {
        "schema": SCRUB_REDUCTION_SCHEMA,
        "threshold_policy_version": THRESHOLD_POLICY_VERSION,
        **_identity_output(artifact, claim),
        "phase": "scrub",
        "request_id": request["request_id"],
        "gesture_count": 2,
        "gestures": legs,
        "raw_artifact": raw_snapshot,
        "scrub_request": request_snapshot,
        "evidence": {
            "same_authenticated_scope_across_both_legs": True,
            "same_exact_member_set_across_both_legs": True,
            "ordered_nonoverlapping_forward_reverse_legs": True,
            "rolling_window_ns": ROLLING_CPU_WINDOW_NS,
            "continuous_integer_ns_window_states_covered": True,
            "boundary_cpu_cannot_undercount": True,
        },
    }
    return _seal(body, "reduction_sha256")


def _replay_phase_bundle(
    bundle: Mapping[str, Any],
    phase: str,
    trusted_receipt_index: TrustedReceiptIndex,
) -> dict[str, Any]:
    if not isinstance(bundle, Mapping):
        raise PhaseMetricsError(f"{phase} reduction bundle must be a mapping")
    bundle = _json_snapshot(bundle, f"{phase} reduction bundle")
    if bundle.get("schema") != PHASE_REDUCTION_SCHEMA or bundle.get("phase") != phase:
        raise PhaseMetricsError(f"{phase} reduction bundle has the wrong identity")
    expected = reduce_phase(
        bundle.get("raw_artifact"),
        bundle.get("phase_request"),
        trusted_receipt_index=trusted_receipt_index,
    )
    if _canonical_bytes(bundle) != _canonical_bytes(expected):
        raise PhaseMetricsError(
            f"{phase} reduction differs from deterministic replay of retained raw evidence"
        )
    return expected


def _replay_scrub_bundle(
    bundle: Mapping[str, Any], trusted_receipt_index: TrustedReceiptIndex
) -> dict[str, Any]:
    if not isinstance(bundle, Mapping):
        raise PhaseMetricsError("scrub reduction bundle must be a mapping")
    bundle = _json_snapshot(bundle, "scrub reduction bundle")
    if bundle.get("schema") != SCRUB_REDUCTION_SCHEMA or bundle.get("phase") != "scrub":
        raise PhaseMetricsError("scrub reduction bundle has the wrong identity")
    expected = reduce_scrub(
        bundle.get("raw_artifact"),
        bundle.get("scrub_request"),
        trusted_receipt_index=trusted_receipt_index,
    )
    if _canonical_bytes(bundle) != _canonical_bytes(expected):
        raise PhaseMetricsError(
            "scrub reduction differs from deterministic replay of retained raw evidence"
        )
    return expected


def _phase_exact(bundle: Mapping[str, Any]) -> tuple[Fraction, Fraction]:
    cpu_ns = _ratio_value(bundle["cpu_time_ns_exact"], "CPU time ns")
    if cpu_ns.denominator != 1:
        raise PhaseMetricsError("cumulative CPU delta must have exact denominator 1")
    cpu_ms = _ratio_value(bundle["cpu_time_ms_exact"], "CPU time ms")
    cpu_percent = _ratio_value(bundle["cpu_percent_exact"], "CPU percent")
    if cpu_ms != cpu_ns / 1_000_000:
        raise PhaseMetricsError("CPU milliseconds disagree with exact cumulative delta")
    if cpu_percent != cpu_ns * 100 / bundle["elapsed_ns"]:
        raise PhaseMetricsError("CPU percent does not use exact phase elapsed time")
    return cpu_ms, cpu_percent


def _percentile(values: Sequence[Fraction], quantile: Fraction) -> Fraction:
    ordered = sorted(values)
    if not ordered:
        raise PhaseMetricsError("distribution is empty")
    if len(ordered) == 1:
        return ordered[0]
    position = (len(ordered) - 1) * quantile
    lower = position.numerator // position.denominator
    upper = math.ceil(position)
    if lower == upper:
        return ordered[lower]
    return ordered[lower] + (ordered[upper] - ordered[lower]) * (position - lower)


def _exact_distribution(values: Sequence[Fraction]) -> dict[str, Any]:
    return {
        "count": len(values),
        "values_exact": [_ratio(value) for value in values],
        "values": [_fraction_float(value, "distribution value") for value in values],
        "min_exact": _ratio(min(values)),
        "p50_exact": _ratio(_percentile(values, Fraction(1, 2))),
        "p95_exact": _ratio(_percentile(values, Fraction(95, 100))),
        "max_exact": _ratio(max(values)),
    }


def _memory_distribution(values: Sequence[int]) -> dict[str, Any]:
    fractions = [Fraction(value, 1) for value in values]
    result = _exact_distribution(fractions)
    result["values"] = list(values)
    return result


def _identity_matches(
    bundle: Mapping[str, Any], variant: str, candidate_id: str, asset_sha256: str
) -> bool:
    return (
        bundle.get("variant") == variant
        and bundle.get("candidate_id") == candidate_id
        and bundle.get("asset_sha256") == asset_sha256
        and bundle.get("threshold_policy_version") == THRESHOLD_POLICY_VERSION
    )


def evaluate_variant_gates(
    variant: str,
    *,
    candidate_id: str,
    asset_sha256: str,
    warm_runs: Sequence[Mapping[str, Any]],
    cold_runs: Sequence[Mapping[str, Any]],
    steady_runs: Sequence[Mapping[str, Any]],
    scrub_runs: Sequence[Mapping[str, Any]],
    trusted_receipt_index: TrustedReceiptIndex,
    memory_limit_bytes: int = DEFAULT_MEMORY_LIMIT_BYTES,
) -> dict[str, Any]:
    """Replay retained evidence, report distributions, and apply ship gates."""

    variant_value = _text(variant, "variant")
    candidate_value = _text(candidate_id, "candidate_id")
    asset_value = _sha256_text(asset_sha256, "asset_sha256")
    memory_limit = _integer(memory_limit_bytes, "memory_limit_bytes", positive=True)
    if memory_limit != DEFAULT_MEMORY_LIMIT_BYTES:
        raise PhaseMetricsError(
            "shipping policy fixes the strict memory limit at 300 MiB"
        )
    if isinstance(trusted_receipt_index, Mapping) or not isinstance(
        trusted_receipt_index, TrustedReceiptIndex
    ):
        raise PhaseMetricsError("evaluator requires an integration-owned TrustedReceiptIndex")
    for values, label in (
        (warm_runs, "warm"),
        (cold_runs, "cold"),
        (steady_runs, "steady"),
        (scrub_runs, "scrub"),
    ):
        if not _sequence(values, f"{label}_runs"):
            raise PhaseMetricsError(f"{label} runs must be present")

    warm = [_replay_phase_bundle(value, "warm", trusted_receipt_index) for value in warm_runs]
    cold = [_replay_phase_bundle(value, "cold", trusted_receipt_index) for value in cold_runs]
    steady = [
        _replay_phase_bundle(value, "steady", trusted_receipt_index)
        for value in steady_runs
    ]
    scrub_aggregates = [
        _replay_scrub_bundle(value, trusted_receipt_index) for value in scrub_runs
    ]
    all_bundles = warm + cold + steady + scrub_aggregates
    if not all(
        _identity_matches(value, variant_value, candidate_value, asset_value)
        for value in all_bundles
    ):
        raise PhaseMetricsError("variant/candidate/asset/policy identity is inconsistent")

    phase_ids = {
        "warm": [value["run_id"] for value in warm],
        "cold": [value["run_id"] for value in cold],
        "steady": [value["run_id"] for value in steady],
        "scrub": [value["run_id"] for value in scrub_aggregates],
    }
    if any(len(ids) != len(set(ids)) for ids in phase_ids.values()):
        raise PhaseMetricsError("replicates within each phase require unique run IDs")
    if set(phase_ids["warm"]) != set(phase_ids["cold"]):
        raise PhaseMetricsError("every cold launch must pair with one same-run warm open")
    warm_by_run = {value["run_id"]: value for value in warm}
    cold_by_run = {value["run_id"]: value for value in cold}
    for run_id in warm_by_run:
        warm_run = warm_by_run[run_id]
        cold_run = cold_by_run[run_id]
        if (
            warm_run["scope_id"] != cold_run["scope_id"]
            or warm_run["artifact_id"] != cold_run["artifact_id"]
            or warm_run["raw_artifact_sha256"] != cold_run["raw_artifact_sha256"]
            or warm_run["receipt_id"] != cold_run["receipt_id"]
            or warm_run["immutable_receipt_digest_sha256"]
            != cold_run["immutable_receipt_digest_sha256"]
            or warm_run["app_process_identity"] != cold_run["app_process_identity"]
            or cold_run["end_monotonic_ns"] > warm_run["start_monotonic_ns"]
        ):
            raise PhaseMetricsError(
                "cold/warm pair does not share one retained run artifact, scope, and app PID/start"
            )

    warm_exact = [_phase_exact(value) for value in warm]
    cold_exact = [_phase_exact(value) for value in cold]
    steady_exact = [_phase_exact(value) for value in steady]
    scrub_legs = [leg for aggregate in scrub_aggregates for leg in aggregate["gestures"]]
    scrub_exact = [_phase_exact(value) for value in scrub_legs]
    rolling_exact = [
        _ratio_value(value["rolling_cpu_max_percent_exact"], "rolling CPU maximum")
        for value in scrub_legs
    ]
    memories_by_phase = {
        "warm": [value["member_lifetime_hwm_sum_upper_bound_bytes"] for value in warm],
        "cold": [value["member_lifetime_hwm_sum_upper_bound_bytes"] for value in cold],
        "steady": [value["member_lifetime_hwm_sum_upper_bound_bytes"] for value in steady],
        "scrub": [value["member_lifetime_hwm_sum_upper_bound_bytes"] for value in scrub_legs],
    }
    all_memory = [item for values in memories_by_phase.values() for item in values]
    cold_ms_values = [value[0] for value in cold_exact]
    gates = {
        "warm_cpu_each_strictly_below_10_percent": all(
            value[1] < WARM_CPU_LIMIT_PERCENT for value in warm_exact
        ),
        "warm_cpu_time_each_at_most_25_ms": all(
            value[0] <= WARM_CPU_TIME_LIMIT_MS for value in warm_exact
        ),
        "cold_cpu_p95_at_most_250_ms": _percentile(
            cold_ms_values, Fraction(95, 100)
        )
        <= COLD_CPU_P95_LIMIT_MS,
        "cold_cpu_max_at_most_500_ms": max(cold_ms_values) <= COLD_CPU_MAX_LIMIT_MS,
        "steady_cpu_each_strictly_below_10_percent": all(
            value[1] < STEADY_CPU_LIMIT_PERCENT for value in steady_exact
        ),
        "scrub_each_leg_strictly_below_10_percent": all(
            value[1] < SCRUB_CPU_LIMIT_PERCENT for value in scrub_exact
        ),
        "scrub_each_250ms_window_at_most_25_percent": all(
            value <= SCRUB_ROLLING_CPU_LIMIT_PERCENT for value in rolling_exact
        ),
        "memory_every_member_lifetime_hwm_sum_strictly_below_limit": all(
            value < memory_limit for value in all_memory
        ),
    }
    body = {
        "schema": VARIANT_REPORT_SCHEMA,
        "threshold_policy_version": THRESHOLD_POLICY_VERSION,
        "variant": variant_value,
        "candidate_id": candidate_value,
        "asset_sha256": asset_value,
        "thresholds": {
            "warm_cpu_percent_strict": _ratio(WARM_CPU_LIMIT_PERCENT),
            "warm_cpu_time_ms": _ratio(WARM_CPU_TIME_LIMIT_MS),
            "cold_cpu_p95_ms": _ratio(COLD_CPU_P95_LIMIT_MS),
            "cold_cpu_max_ms": _ratio(COLD_CPU_MAX_LIMIT_MS),
            "steady_cpu_percent_strict": _ratio(STEADY_CPU_LIMIT_PERCENT),
            "scrub_leg_cpu_percent_strict": _ratio(SCRUB_CPU_LIMIT_PERCENT),
            "scrub_rolling_cpu_percent": _ratio(SCRUB_ROLLING_CPU_LIMIT_PERCENT),
            "scrub_rolling_window_ns": ROLLING_CPU_WINDOW_NS,
            "memory_bytes_strict": memory_limit,
        },
        "distributions": {
            "warm_cpu_percent": _exact_distribution([value[1] for value in warm_exact]),
            "warm_cpu_time_ms": _exact_distribution([value[0] for value in warm_exact]),
            "cold_cpu_percent": _exact_distribution([value[1] for value in cold_exact]),
            "cold_cpu_time_ms": _exact_distribution(cold_ms_values),
            "steady_cpu_percent": _exact_distribution([value[1] for value in steady_exact]),
            "scrub_leg_cpu_percent": _exact_distribution([value[1] for value in scrub_exact]),
            "scrub_rolling_cpu_percent": _exact_distribution(rolling_exact),
            "member_lifetime_hwm_sum_upper_bound_bytes": _memory_distribution(all_memory),
            "member_lifetime_hwm_sum_upper_bound_bytes_by_phase": {
                phase: _memory_distribution(values)
                for phase, values in memories_by_phase.items()
            },
        },
        "gates": gates,
        "eligible": all(gates.values()),
        "replayed_reduction_sha256s": {
            "warm": [value["reduction_sha256"] for value in warm],
            "cold": [value["reduction_sha256"] for value in cold],
            "steady": [value["reduction_sha256"] for value in steady],
            "scrub": [value["reduction_sha256"] for value in scrub_aggregates],
        },
        "memory_evidence_label": (
            "sum of authenticated per-member lifetime HWMs; "
            "non-co-temporal conservative upper bound"
        ),
    }
    return _seal(body, "report_sha256")


__all__ = [
    "COLD_CPU_MAX_LIMIT_MS",
    "COLD_CPU_P95_LIMIT_MS",
    "DEFAULT_MEMORY_LIMIT_BYTES",
    "MAX_CAPTURE_LATENESS_NS",
    "MAX_QUERY_DURATION_NS",
    "PHASE_REQUEST_SCHEMA",
    "PHASE_REDUCTION_SCHEMA",
    "PhaseMetricsError",
    "RAW_ARTIFACT_SCHEMA",
    "ROLLING_CPU_WINDOW_NS",
    "SAMPLE_INTERVAL_NS",
    "SCRUB_REQUEST_SCHEMA",
    "SCRUB_REDUCTION_SCHEMA",
    "THRESHOLD_POLICY_VERSION",
    "TRUSTED_RECEIPT_SCHEMA",
    "TrustedReceiptIndex",
    "VARIANT_REPORT_SCHEMA",
    "compute_immutable_receipt_digest_sha256",
    "compute_raw_artifact_sha256",
    "evaluate_variant_gates",
    "reduce_phase",
    "reduce_scrub",
]
