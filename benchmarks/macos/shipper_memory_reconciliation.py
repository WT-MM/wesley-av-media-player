#!/usr/bin/env python3
"""Fail-closed native/OS memory reconciliation for the macOS ship gate.

Version three deliberately separates three trust domains:

* native allocator events are untrusted mappings whose canonical digest must
  match a trusted producer receipt supplied by the capture boundary;
* the OS coalition reducer is another untrusted mapping whose exact member
  rows and lifecycle evidence must match an independently trusted OS receipt;
* the evaluator supplies the expected run, process set, phase, variant, asset,
  candidate, and exact monotonic window.

The native shipping peak is the producer's *global concurrent aggregate HWM*.
Per-category HWMs are disjoint diagnostics and are never added together.  The
evaluator derives a conservative OS bound by summing each distinct coalition
member's lifetime physical-footprint HWM.  A producer-authored coalition peak
or current-footprint scalar is never accepted as the gate value.  The evaluator
alone derives ``untracked_delta_bytes`` from that conservative bound.  This
prevents independent native-HWM double-counting, omitted helper peaks, and
producer-authored reconciliation deltas.

This module is pure validation.  It launches no application and performs no
process or screen inspection.
"""

from __future__ import annotations

import dataclasses
import hashlib
import json
import re
import uuid
from collections.abc import Mapping, Sequence
from typing import Any


SCHEMA = "wam.macos.native-memory-reconciliation.v3"
NATIVE_EVENT_SCHEMA = "wam.macos.native-memory-events.v3"
NATIVE_RECEIPT_SCHEMA = "wam.macos.trusted-native-memory-receipt.v3"
OS_REDUCER_SCHEMA = "wam.macos.coalition-memory-reducer.v3"
OS_RECEIPT_SCHEMA = "wam.macos.trusted-coalition-memory-receipt.v3"
LIFECYCLE_RECEIPT_SCHEMA = "wam.macos.coalition-lifecycle-receipt.v1"
DEFAULT_MEMORY_LIMIT_BYTES = 300 * 1024 * 1024
PHASE_CLOSE_BOUND_NS = 250_000_000
UNTRACKED_DELTA_DEFINITION = (
    "evaluator-derived sum of every distinct coalition member's trusted "
    "lifetime physical-footprint high-water mark minus the trusted native "
    "producer global concurrent aggregate high-water mark; the delta is a "
    "conservative bound on framework, allocator, stack, executable, helper, "
    "and other unattributed overhead"
)

_SHA256_RE = re.compile(r"[0-9a-f]{64}")
_IDENTIFIER_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._:-]{0,255}")
_ROLES = {"app", "decoder_helper"}

_BINDING_FIELDS = {
    "run_id",
    "process_id",
    "process_start_abstime",
    "source_key",
    "asset_sha256",
    "candidate_id",
}
_PROCESS_FIELDS = {"process_id", "process_start_abstime", "role", "coalition_id"}
_BOUNDS_FIELDS = {"started_monotonic_ns", "ended_monotonic_ns"}
_CLOSE_BINDING_FIELDS = {
    "epoch_id",
    "epoch_generation",
    "phase_end_barrier_id",
    "work_sequence_at_phase_end",
}
_NATIVE_ROOT_FIELDS = {
    "schema",
    "binding",
    "phase",
    "variant",
    "epoch_id",
    "epoch_generation",
    "phase_started_monotonic_ns",
    "phase_ended_monotonic_ns",
    "close_binding",
    "events",
}
_RESET_FIELDS = {
    "sequence",
    "kind",
    "monotonic_ns",
    "epoch_id",
    "epoch_generation",
}
_SNAPSHOT_FIELDS = {
    "sequence",
    "kind",
    "monotonic_ns",
    "epoch_id",
    "epoch_generation",
    "snapshot_id",
    "aggregate_current_bytes",
    "aggregate_native_hwm_bytes",
    "barrier_id",
    "work_sequence",
    "categories",
}
_CATEGORY_COMMON_FIELDS = {"epoch_id", "snapshot_id", "checkpoint_sequence"}
_OS_ROOT_FIELDS = {
    "schema",
    "receipt_id",
    "binding",
    "phase",
    "variant",
    "close_binding",
    "window",
    "coalition_id",
    "processes",
    "provider",
    "tasks_started_before",
    "tasks_started_after",
    "tasks_exited_before",
    "tasks_exited_after",
    "task_counters_started_monotonic_ns",
    "task_counters_ended_monotonic_ns",
    "query",
    "lifecycle_receipt",
}
_PROVIDER_FIELDS = {
    "provider_id",
    "provider_executable_sha256",
    "provider_audit_token_sha256",
    "api_name",
    "api_version",
}
_QUERY_FIELDS = {
    "query_id",
    "query_started_monotonic_ns",
    "query_ended_monotonic_ns",
    "query_status",
    "epoch_id",
    "epoch_generation",
    "phase_end_barrier_id",
    "work_sequence_at_query_begin",
    "work_sequence_at_query_end",
    "coalition_current_footprint_bytes",
    "members",
}
_RUSAGE_ROW_FIELDS = {
    "process_id",
    "process_start_abstime",
    "role",
    "coalition_id",
    "observation_id",
    "query_started_monotonic_ns",
    "query_ended_monotonic_ns",
    "query_status",
    "provider_id",
    "provider_executable_sha256",
    "provider_audit_token_sha256",
    "api_name",
    "api_version",
    "current_phys_footprint_bytes",
    "lifetime_max_phys_footprint_bytes",
}
_LIFECYCLE_FIELDS = {
    "schema",
    "receipt_id",
    "binding",
    "phase",
    "variant",
    "close_binding",
    "coalition_id",
    "provider",
    "tasks_started_before",
    "tasks_started_after",
    "tasks_exited_before",
    "tasks_exited_after",
    "task_counters_started_monotonic_ns",
    "task_counters_ended_monotonic_ns",
    "events",
}
_LIFECYCLE_EVENT_FIELDS = {
    "sequence",
    "kind",
    "monotonic_ns",
    "member",
    "final_rusage",
}
_TRUSTED_INDEX_KINDS = {"native_memory", "os_coalition_memory"}
_RECEIPT_CAPABILITY_SEAL = object()
_NATIVE_RECEIPT_FIELDS = {
    "schema",
    "trusted_execution_index_id",
    "receipt_id",
    "producer_id",
    "producer_attestation_id",
    "producer_executable_sha256",
    "producer_audit_token_sha256",
    "binding",
    "phase",
    "variant",
    "epoch_id",
    "epoch_generation",
    "phase_bounds",
    "event_count",
    "completed_checkpoint_sequence",
    "event_sha256",
    "allocation_contract_sha256",
    "sealed_monotonic_ns",
    "next_reset_monotonic_ns",
    "next_reset_epoch_generation",
    "phase_end_barrier_id",
    "work_sequence_at_phase_end",
    "work_sequence_at_checkpoint",
    "work_sequence_at_seal",
}
_OS_RECEIPT_FIELDS = {
    "schema",
    "trusted_execution_index_id",
    "receipt_id",
    "producer_id",
    "producer_attestation_id",
    "producer_executable_sha256",
    "producer_audit_token_sha256",
    "binding",
    "phase",
    "variant",
    "close_binding",
    "phase_bounds",
    "coalition_id",
    "processes",
    "provider",
    "query_id",
    "query_started_monotonic_ns",
    "query_ended_monotonic_ns",
    "query_status",
    "lifecycle_receipt_sha256",
    "reducer_evidence_sha256",
    "sealed_monotonic_ns",
    "work_sequence_at_seal",
}

# Every byte belongs to exactly one category at an instant.  Category HWMs may
# have occurred at different instants, so only current values may be summed.
# The producer maintains aggregate_native_hwm_bytes after every category
# mutation and attests this exact contract in its trusted receipt.
ALLOCATION_CONTRACT: dict[str, Any] = {
    "schema": "wam.macos.native-allocation-partition.v1",
    "ownership": "each tracked live byte has exactly one category owner",
    "category_current_values": "pairwise disjoint and collectively exhaustive",
    "category_hwm_values": "diagnostic only; never additive",
    "aggregate_hwm": (
        "maximum sum of all category current bytes, updated atomically after "
        "every allocation ownership mutation in the epoch"
    ),
}


def _canonical_json_snapshot(value: Any, label: str) -> tuple[Any, str]:
    try:
        encoded = json.dumps(
            value,
            sort_keys=True,
            separators=(",", ":"),
            ensure_ascii=True,
            allow_nan=False,
        ).encode("utf-8")
    except (TypeError, ValueError) as exc:
        raise MemoryReconciliationError(f"{label} is not canonical JSON") from exc
    return json.loads(encoded.decode("utf-8")), hashlib.sha256(encoded).hexdigest()


def _canonical_sha256(value: Any, label: str) -> str:
    return _canonical_json_snapshot(value, label)[1]


ALLOCATION_CONTRACT_SHA256 = _canonical_sha256(
    ALLOCATION_CONTRACT, "allocation contract"
)

# Exact, revisioned native diagnostic categories.  Adding a fact or category is
# a schema change.  The first item in every pair is a current fact and the
# second is its diagnostic HWM.  Count pairs are checked but never reconciled
# as bytes.
REQUIRED_CATEGORY_FACTS: dict[str, tuple[str, ...]] = {
    "surface": (
        "current_bytes",
        "diagnostic_hwm_bytes",
        "current_count",
        "diagnostic_hwm_count",
    ),
    "source_staged_payload": ("current_bytes", "diagnostic_hwm_bytes"),
    "dispatcher_pending_payload": ("current_bytes", "diagnostic_hwm_bytes"),
    "decoder": (
        "live_current_bytes",
        "live_diagnostic_hwm_bytes",
        "inflight_current_bytes",
        "inflight_diagnostic_hwm_bytes",
        "pending_current_bytes",
        "pending_diagnostic_hwm_bytes",
        "copy_current_bytes",
        "copy_diagnostic_hwm_bytes",
    ),
    "preview": (
        "staged_current_bytes",
        "staged_diagnostic_hwm_bytes",
        "inflight_current_bytes",
        "inflight_diagnostic_hwm_bytes",
    ),
    "audio": (
        "retained_current_bytes",
        "retained_diagnostic_hwm_bytes",
        "ring_current_bytes",
        "ring_diagnostic_hwm_bytes",
    ),
    "qt": (
        "resources_current_count",
        "resources_diagnostic_hwm_count",
        "resources_current_bytes",
        "resources_diagnostic_hwm_bytes",
        "retirement_current_count",
        "retirement_diagnostic_hwm_count",
        "retirement_current_bytes",
        "retirement_diagnostic_hwm_bytes",
        "quarantine_current_count",
        "quarantine_diagnostic_hwm_count",
        "quarantine_current_bytes",
        "quarantine_diagnostic_hwm_bytes",
    ),
}

_BYTE_PAIRS: tuple[tuple[str, str, str], ...] = (
    ("surface", "current_bytes", "diagnostic_hwm_bytes"),
    ("source_staged_payload", "current_bytes", "diagnostic_hwm_bytes"),
    ("dispatcher_pending_payload", "current_bytes", "diagnostic_hwm_bytes"),
    ("decoder", "live_current_bytes", "live_diagnostic_hwm_bytes"),
    ("decoder", "inflight_current_bytes", "inflight_diagnostic_hwm_bytes"),
    ("decoder", "pending_current_bytes", "pending_diagnostic_hwm_bytes"),
    ("decoder", "copy_current_bytes", "copy_diagnostic_hwm_bytes"),
    ("preview", "staged_current_bytes", "staged_diagnostic_hwm_bytes"),
    ("preview", "inflight_current_bytes", "inflight_diagnostic_hwm_bytes"),
    ("audio", "retained_current_bytes", "retained_diagnostic_hwm_bytes"),
    ("audio", "ring_current_bytes", "ring_diagnostic_hwm_bytes"),
    ("qt", "resources_current_bytes", "resources_diagnostic_hwm_bytes"),
    ("qt", "retirement_current_bytes", "retirement_diagnostic_hwm_bytes"),
    ("qt", "quarantine_current_bytes", "quarantine_diagnostic_hwm_bytes"),
)
_COUNT_PAIRS: tuple[tuple[str, str, str], ...] = (
    ("surface", "current_count", "diagnostic_hwm_count"),
    ("qt", "resources_current_count", "resources_diagnostic_hwm_count"),
    ("qt", "retirement_current_count", "retirement_diagnostic_hwm_count"),
    ("qt", "quarantine_current_count", "quarantine_diagnostic_hwm_count"),
)


class MemoryReconciliationError(ValueError):
    """Evidence or an authoritative trust-boundary input is malformed."""


def _positive_int(value: Any, label: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value <= 0:
        raise MemoryReconciliationError(f"{label} must be a positive integer")
    return value


def _nonnegative_int(value: Any, label: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        raise MemoryReconciliationError(f"{label} must be a non-negative integer")
    return value


def _bounded_identifier(value: Any, label: str) -> str:
    if not isinstance(value, str) or _IDENTIFIER_RE.fullmatch(value) is None:
        raise MemoryReconciliationError(
            f"{label} must be a canonical bounded identifier"
        )
    return value


def _sha256_text(value: Any, label: str) -> str:
    if not isinstance(value, str) or _SHA256_RE.fullmatch(value) is None:
        raise MemoryReconciliationError(f"{label} must be 64 lowercase hex digits")
    return value


def _canonical_run_id(value: Any) -> str:
    if not isinstance(value, str):
        raise MemoryReconciliationError("run_id must be a canonical UUID")
    try:
        parsed = uuid.UUID(value)
    except (ValueError, AttributeError) as exc:
        raise MemoryReconciliationError("run_id must be a canonical UUID") from exc
    if str(parsed) != value:
        raise MemoryReconciliationError("run_id must be a canonical lowercase UUID")
    return value


def _exact_fields(value: Any, required: set[str], label: str) -> Mapping[str, Any]:
    if not isinstance(value, Mapping):
        raise MemoryReconciliationError(f"{label} must be an object")
    if any(not isinstance(field, str) for field in value):
        raise MemoryReconciliationError(f"{label} field names must be strings")
    fields = set(value)
    if fields != required:
        missing = sorted(required - fields)
        extra = sorted(fields - required)
        raise MemoryReconciliationError(
            f"{label} fields are not exact (missing={missing}, extra={extra})"
        )
    return value


@dataclasses.dataclass(frozen=True, slots=True)
class MemoryBinding:
    """Exact workload/process identity shared by both producer receipts."""

    run_id: str
    process_id: int
    process_start_abstime: int
    source_key: int
    asset_sha256: str
    candidate_id: str

    def __post_init__(self) -> None:
        _canonical_run_id(self.run_id)
        _positive_int(self.process_id, "process_id")
        _positive_int(self.process_start_abstime, "process_start_abstime")
        _positive_int(self.source_key, "source_key")
        _sha256_text(self.asset_sha256, "asset_sha256")
        _bounded_identifier(self.candidate_id, "candidate_id")

    def as_dict(self) -> dict[str, Any]:
        return dataclasses.asdict(self)

    @classmethod
    def from_mapping(cls, value: Any) -> "MemoryBinding":
        parsed = _exact_fields(value, _BINDING_FIELDS, "memory binding")
        return cls(**{field: parsed[field] for field in _BINDING_FIELDS})


@dataclasses.dataclass(frozen=True, slots=True)
class PhaseBounds:
    """Exact half-open semantic phase bounds (the end event is included)."""

    started_monotonic_ns: int
    ended_monotonic_ns: int

    def __post_init__(self) -> None:
        _positive_int(self.started_monotonic_ns, "phase start")
        _positive_int(self.ended_monotonic_ns, "phase end")
        if self.ended_monotonic_ns <= self.started_monotonic_ns:
            raise MemoryReconciliationError("phase end must follow phase start")

    def as_dict(self) -> dict[str, int]:
        return dataclasses.asdict(self)


@dataclasses.dataclass(frozen=True, slots=True)
class PhaseCloseBinding:
    """Trusted session-worker barrier shared by native and OS close evidence."""

    epoch_id: str
    epoch_generation: int
    phase_end_barrier_id: str
    work_sequence_at_phase_end: int

    def __post_init__(self) -> None:
        _bounded_identifier(self.epoch_id, "close epoch_id")
        _positive_int(self.epoch_generation, "close epoch_generation")
        _bounded_identifier(self.phase_end_barrier_id, "phase_end_barrier_id")
        _nonnegative_int(
            self.work_sequence_at_phase_end, "work_sequence_at_phase_end"
        )

    def as_dict(self) -> dict[str, Any]:
        return dataclasses.asdict(self)

    @classmethod
    def from_mapping(cls, value: Any) -> "PhaseCloseBinding":
        parsed = _exact_fields(value, _CLOSE_BINDING_FIELDS, "phase close binding")
        return cls(**{field: parsed[field] for field in _CLOSE_BINDING_FIELDS})


@dataclasses.dataclass(frozen=True, slots=True)
class OSProviderProvenance:
    """Exact provider identity repeated by every retained rusage row."""

    provider_id: str
    provider_executable_sha256: str
    provider_audit_token_sha256: str
    api_name: str
    api_version: int

    def __post_init__(self) -> None:
        _bounded_identifier(self.provider_id, "provider_id")
        _sha256_text(self.provider_executable_sha256, "provider executable")
        _sha256_text(self.provider_audit_token_sha256, "provider audit token")
        _bounded_identifier(self.api_name, "provider api_name")
        _positive_int(self.api_version, "provider api_version")

    def as_dict(self) -> dict[str, Any]:
        return dataclasses.asdict(self)

    @classmethod
    def from_mapping(cls, value: Any) -> "OSProviderProvenance":
        parsed = _exact_fields(value, _PROVIDER_FIELDS, "OS provider provenance")
        return cls(**{field: parsed[field] for field in _PROVIDER_FIELDS})


@dataclasses.dataclass(frozen=True, slots=True, order=True)
class CoalitionProcess:
    """One exact member of the trusted coalition process set."""

    process_id: int
    process_start_abstime: int
    role: str
    coalition_id: int

    def __post_init__(self) -> None:
        _positive_int(self.process_id, "coalition process_id")
        _positive_int(self.process_start_abstime, "coalition process_start_abstime")
        if self.role not in _ROLES:
            raise MemoryReconciliationError("coalition process role is unsupported")
        _positive_int(self.coalition_id, "coalition_id")

    def as_dict(self) -> dict[str, Any]:
        return dataclasses.asdict(self)

    @classmethod
    def from_mapping(cls, value: Any) -> "CoalitionProcess":
        parsed = _exact_fields(value, _PROCESS_FIELDS, "coalition process")
        return cls(**{field: parsed[field] for field in _PROCESS_FIELDS})


@dataclasses.dataclass(frozen=True, slots=True, order=True)
class TrustedExecutionEntry:
    """One receipt digest authorized by an out-of-band execution index."""

    kind: str
    receipt_id: str
    receipt_sha256: str

    def __post_init__(self) -> None:
        if self.kind not in _TRUSTED_INDEX_KINDS:
            raise MemoryReconciliationError("trusted execution entry kind is invalid")
        _bounded_identifier(self.receipt_id, "trusted execution receipt_id")
        _sha256_text(self.receipt_sha256, "trusted execution receipt sha256")


@dataclasses.dataclass(frozen=True, slots=True)
class TrustedExecutionIndex:
    """Authoritative receipt allowlist supplied outside retained evidence.

    This is an evaluator input, not a structure parsed from a benchmark result.
    Its entries normally come from the trusted driver/capture execution log.
    """

    index_id: str
    entries: tuple[TrustedExecutionEntry, ...]

    def __post_init__(self) -> None:
        _bounded_identifier(self.index_id, "trusted execution index_id")
        if not isinstance(self.entries, tuple) or not self.entries:
            raise MemoryReconciliationError(
                "trusted execution entries must be a non-empty canonical tuple"
            )
        if any(not isinstance(entry, TrustedExecutionEntry) for entry in self.entries):
            raise MemoryReconciliationError(
                "trusted execution index contains an unvalidated entry"
            )
        if tuple(sorted(self.entries)) != self.entries:
            raise MemoryReconciliationError(
                "trusted execution entries must be sorted canonically"
            )
        keys = {(entry.kind, entry.receipt_id) for entry in self.entries}
        if len(keys) != len(self.entries):
            raise MemoryReconciliationError(
                "trusted execution index contains duplicate receipt identities"
            )

    def require_digest(self, kind: str, receipt_id: str, digest: str) -> None:
        matching = [
            entry
            for entry in self.entries
            if entry.kind == kind and entry.receipt_id == receipt_id
        ]
        if len(matching) != 1 or matching[0].receipt_sha256 != digest:
            raise MemoryReconciliationError(
                "receipt is absent from or differs from the trusted execution index"
            )


def _validate_process_tuple(
    processes: Any,
    binding: MemoryBinding,
    label: str,
) -> tuple[CoalitionProcess, ...]:
    if not isinstance(processes, tuple) or not processes:
        raise MemoryReconciliationError(
            f"{label} must be a non-empty canonical tuple"
        )
    if any(not isinstance(process, CoalitionProcess) for process in processes):
        raise MemoryReconciliationError(
            f"{label} must contain validated CoalitionProcess values"
        )
    if tuple(sorted(processes)) != processes:
        raise MemoryReconciliationError(f"{label} must be sorted canonically")
    if len({process.process_id for process in processes}) != len(processes):
        raise MemoryReconciliationError(f"{label} contains duplicate PIDs")
    coalition_ids = {process.coalition_id for process in processes}
    if len(coalition_ids) != 1:
        raise MemoryReconciliationError(f"{label} spans multiple coalitions")
    apps = [process for process in processes if process.role == "app"]
    if len(apps) != 1:
        raise MemoryReconciliationError(f"{label} must contain exactly one app")
    app = apps[0]
    if (
        app.process_id != binding.process_id
        or app.process_start_abstime != binding.process_start_abstime
    ):
        raise MemoryReconciliationError(f"{label} app does not match binding")
    return processes


@dataclasses.dataclass(frozen=True, slots=True)
class TrustedNativeProducerReceipt:
    """Receipt already authenticated by the native capture trust boundary.

    There is intentionally no ``from_mapping`` constructor.  Persisted JSON is
    not promoted to this type until the surrounding capture layer has
    authenticated its producer identity and attestation.
    """

    trusted_execution_index_id: str
    receipt_id: str
    producer_id: str
    producer_attestation_id: str
    producer_executable_sha256: str
    producer_audit_token_sha256: str
    binding: MemoryBinding
    phase: str
    variant: str
    epoch_id: str
    epoch_generation: int
    phase_bounds: PhaseBounds
    event_count: int
    completed_checkpoint_sequence: int
    event_sha256: str
    allocation_contract_sha256: str
    sealed_monotonic_ns: int
    next_reset_monotonic_ns: int
    next_reset_epoch_generation: int
    phase_end_barrier_id: str
    work_sequence_at_phase_end: int
    work_sequence_at_checkpoint: int
    work_sequence_at_seal: int
    retained_receipt_sha256: str
    _capability_seal: object = dataclasses.field(repr=False, compare=False)

    def __post_init__(self) -> None:
        if self._capability_seal is not _RECEIPT_CAPABILITY_SEAL:
            raise MemoryReconciliationError(
                "native receipt capability must be sealed by authentication"
            )
        for value, label in (
            (self.trusted_execution_index_id, "native trusted_execution_index_id"),
            (self.receipt_id, "native receipt_id"),
            (self.producer_id, "native producer_id"),
            (self.producer_attestation_id, "native producer_attestation_id"),
            (self.phase, "native phase"),
            (self.variant, "native variant"),
            (self.epoch_id, "native epoch_id"),
            (self.phase_end_barrier_id, "native phase_end_barrier_id"),
        ):
            _bounded_identifier(value, label)
        _sha256_text(self.producer_executable_sha256, "native producer executable")
        _sha256_text(self.producer_audit_token_sha256, "native producer audit token")
        if not isinstance(self.binding, MemoryBinding):
            raise MemoryReconciliationError("native receipt binding is not validated")
        if not isinstance(self.phase_bounds, PhaseBounds):
            raise MemoryReconciliationError("native receipt bounds are not validated")
        _positive_int(self.epoch_generation, "native epoch_generation")
        _positive_int(self.event_count, "native event_count")
        _nonnegative_int(
            self.completed_checkpoint_sequence,
            "native completed_checkpoint_sequence",
        )
        _sha256_text(self.event_sha256, "native event_sha256")
        _sha256_text(
            self.allocation_contract_sha256, "native allocation contract sha256"
        )
        _positive_int(self.sealed_monotonic_ns, "native sealed_monotonic_ns")
        _positive_int(self.next_reset_monotonic_ns, "native next_reset_monotonic_ns")
        _positive_int(
            self.next_reset_epoch_generation,
            "native next_reset_epoch_generation",
        )
        _nonnegative_int(
            self.work_sequence_at_phase_end,
            "native work_sequence_at_phase_end",
        )
        _nonnegative_int(
            self.work_sequence_at_checkpoint,
            "native work_sequence_at_checkpoint",
        )
        _nonnegative_int(
            self.work_sequence_at_seal, "native work_sequence_at_seal"
        )
        _sha256_text(self.retained_receipt_sha256, "retained native receipt sha256")
        if self.next_reset_monotonic_ns <= self.sealed_monotonic_ns:
            raise MemoryReconciliationError(
                "native receipt must be sealed before the exact next reset"
            )

    @property
    def schema(self) -> str:
        return NATIVE_RECEIPT_SCHEMA

    def as_dict(self) -> dict[str, Any]:
        value = dataclasses.asdict(self)
        value.pop("retained_receipt_sha256")
        value.pop("_capability_seal")
        value["schema"] = self.schema
        return value


@dataclasses.dataclass(frozen=True, slots=True)
class TrustedOSCoalitionReceipt:
    """Member-row receipt authenticated by the OS capture boundary.

    It intentionally contains no producer-authored coalition peak.
    """

    trusted_execution_index_id: str
    receipt_id: str
    producer_id: str
    producer_attestation_id: str
    producer_executable_sha256: str
    producer_audit_token_sha256: str
    binding: MemoryBinding
    phase: str
    variant: str
    close_binding: PhaseCloseBinding
    phase_bounds: PhaseBounds
    coalition_id: int
    processes: tuple[CoalitionProcess, ...]
    provider: OSProviderProvenance
    query_id: str
    query_started_monotonic_ns: int
    query_ended_monotonic_ns: int
    query_status: int
    lifecycle_receipt_sha256: str | None
    reducer_evidence_sha256: str
    sealed_monotonic_ns: int
    work_sequence_at_seal: int
    retained_receipt_sha256: str
    _capability_seal: object = dataclasses.field(repr=False, compare=False)

    def __post_init__(self) -> None:
        if self._capability_seal is not _RECEIPT_CAPABILITY_SEAL:
            raise MemoryReconciliationError(
                "OS receipt capability must be sealed by authentication"
            )
        for value, label in (
            (self.trusted_execution_index_id, "OS trusted_execution_index_id"),
            (self.receipt_id, "OS receipt_id"),
            (self.producer_id, "OS producer_id"),
            (self.producer_attestation_id, "OS producer_attestation_id"),
            (self.phase, "OS phase"),
            (self.variant, "OS variant"),
            (self.query_id, "OS query_id"),
        ):
            _bounded_identifier(value, label)
        _sha256_text(self.producer_executable_sha256, "OS producer executable")
        _sha256_text(self.producer_audit_token_sha256, "OS producer audit token")
        if not isinstance(self.binding, MemoryBinding):
            raise MemoryReconciliationError("OS receipt binding is not validated")
        if not isinstance(self.phase_bounds, PhaseBounds):
            raise MemoryReconciliationError("OS receipt bounds are not validated")
        if not isinstance(self.close_binding, PhaseCloseBinding):
            raise MemoryReconciliationError("OS receipt close binding is not validated")
        _positive_int(self.coalition_id, "OS coalition_id")
        _validate_process_tuple(self.processes, self.binding, "OS receipt processes")
        if {process.coalition_id for process in self.processes} != {
            self.coalition_id
        }:
            raise MemoryReconciliationError(
                "OS receipt process set has the wrong coalition"
            )
        _sha256_text(self.reducer_evidence_sha256, "OS reducer evidence sha256")
        if not isinstance(self.provider, OSProviderProvenance):
            raise MemoryReconciliationError("OS receipt provider is not validated")
        _positive_int(
            self.query_started_monotonic_ns, "OS query_started_monotonic_ns"
        )
        _positive_int(self.query_ended_monotonic_ns, "OS query_ended_monotonic_ns")
        if self.query_ended_monotonic_ns < self.query_started_monotonic_ns:
            raise MemoryReconciliationError("OS receipt query runs backwards")
        _nonnegative_int(self.query_status, "OS query_status")
        if self.lifecycle_receipt_sha256 is not None:
            _sha256_text(
                self.lifecycle_receipt_sha256, "OS lifecycle receipt sha256"
            )
        _positive_int(self.sealed_monotonic_ns, "OS sealed_monotonic_ns")
        _nonnegative_int(
            self.work_sequence_at_seal, "OS work_sequence_at_seal"
        )
        _sha256_text(self.retained_receipt_sha256, "retained OS receipt sha256")

    @property
    def schema(self) -> str:
        return OS_RECEIPT_SCHEMA

    def as_dict(self) -> dict[str, Any]:
        value = dataclasses.asdict(self)
        value.pop("retained_receipt_sha256")
        value.pop("_capability_seal")
        value["schema"] = self.schema
        return value


@dataclasses.dataclass(frozen=True, slots=True)
class MemoryReconciliationReport:
    schema: str
    reconciliation_complete: bool
    identity_bound: bool
    native_receipt_bound: bool
    os_receipt_bound: bool
    epoch_and_order_complete: bool
    required_categories_complete: bool
    os_conservative_member_hwm_sum_bytes: int | None
    os_coalition_current_footprint_bytes: int | None
    os_distinct_member_count: int
    os_member_churn_observed: bool
    native_reconciled_peak_bytes: int | None
    untracked_delta_bytes: int | None
    untracked_delta_definition: str
    requested_memory_limit_bytes: int
    effective_memory_limit_bytes: int
    hard_memory_ceiling_bytes: int
    phase_close_bound_ns: int
    under_memory_limit: bool
    evidence_pass: bool
    production_integration_authorized: bool
    gate_pass: bool
    evaluation_context_sha256: str
    errors: tuple[str, ...]

    @property
    def eligible(self) -> bool:
        return self.gate_pass

    def as_dict(self) -> dict[str, Any]:
        value = dataclasses.asdict(self)
        value["errors"] = list(self.errors)
        value["eligible"] = self.eligible
        value["report_sha256"] = _canonical_sha256(
            value, "memory reconciliation report"
        )
        return value


def native_event_sha256(value: Any) -> str:
    """Canonical digest which a trusted native receipt must authenticate."""

    return _canonical_json_snapshot(value, "native memory event evidence")[1]


def os_reducer_evidence_sha256(value: Any) -> str:
    """Canonical digest which a trusted OS receipt must authenticate."""

    return _canonical_json_snapshot(value, "OS coalition reducer evidence")[1]


def authenticate_native_receipt(
    retained_receipt: Any,
    *,
    trusted_execution_index: TrustedExecutionIndex,
) -> TrustedNativeProducerReceipt:
    """Seal retained native receipt bytes authorized by an external index."""

    if not isinstance(trusted_execution_index, TrustedExecutionIndex):
        raise MemoryReconciliationError("trusted execution index is required")
    snapshot, digest = _canonical_json_snapshot(
        retained_receipt, "retained native receipt"
    )
    value = _exact_fields(snapshot, _NATIVE_RECEIPT_FIELDS, "retained native receipt")
    if value["schema"] != NATIVE_RECEIPT_SCHEMA:
        raise MemoryReconciliationError("retained native receipt schema is invalid")
    if value["trusted_execution_index_id"] != trusted_execution_index.index_id:
        raise MemoryReconciliationError(
            "native receipt has the wrong trusted execution index"
        )
    receipt_id = _bounded_identifier(value["receipt_id"], "native receipt_id")
    trusted_execution_index.require_digest("native_memory", receipt_id, digest)
    bounds = _exact_fields(
        value["phase_bounds"], _BOUNDS_FIELDS, "native receipt phase bounds"
    )
    return TrustedNativeProducerReceipt(
        trusted_execution_index_id=value["trusted_execution_index_id"],
        receipt_id=receipt_id,
        producer_id=value["producer_id"],
        producer_attestation_id=value["producer_attestation_id"],
        producer_executable_sha256=value["producer_executable_sha256"],
        producer_audit_token_sha256=value["producer_audit_token_sha256"],
        binding=MemoryBinding.from_mapping(value["binding"]),
        phase=value["phase"],
        variant=value["variant"],
        epoch_id=value["epoch_id"],
        epoch_generation=value["epoch_generation"],
        phase_bounds=PhaseBounds(
            bounds["started_monotonic_ns"], bounds["ended_monotonic_ns"]
        ),
        event_count=value["event_count"],
        completed_checkpoint_sequence=value["completed_checkpoint_sequence"],
        event_sha256=value["event_sha256"],
        allocation_contract_sha256=value["allocation_contract_sha256"],
        sealed_monotonic_ns=value["sealed_monotonic_ns"],
        next_reset_monotonic_ns=value["next_reset_monotonic_ns"],
        next_reset_epoch_generation=value["next_reset_epoch_generation"],
        phase_end_barrier_id=value["phase_end_barrier_id"],
        work_sequence_at_phase_end=value["work_sequence_at_phase_end"],
        work_sequence_at_checkpoint=value["work_sequence_at_checkpoint"],
        work_sequence_at_seal=value["work_sequence_at_seal"],
        retained_receipt_sha256=digest,
        _capability_seal=_RECEIPT_CAPABILITY_SEAL,
    )


def authenticate_os_receipt(
    retained_receipt: Any,
    *,
    trusted_execution_index: TrustedExecutionIndex,
) -> TrustedOSCoalitionReceipt:
    """Seal retained OS receipt bytes authorized by an external index."""

    if not isinstance(trusted_execution_index, TrustedExecutionIndex):
        raise MemoryReconciliationError("trusted execution index is required")
    snapshot, digest = _canonical_json_snapshot(retained_receipt, "retained OS receipt")
    value = _exact_fields(snapshot, _OS_RECEIPT_FIELDS, "retained OS receipt")
    if value["schema"] != OS_RECEIPT_SCHEMA:
        raise MemoryReconciliationError("retained OS receipt schema is invalid")
    if value["trusted_execution_index_id"] != trusted_execution_index.index_id:
        raise MemoryReconciliationError(
            "OS receipt has the wrong trusted execution index"
        )
    receipt_id = _bounded_identifier(value["receipt_id"], "OS receipt_id")
    trusted_execution_index.require_digest("os_coalition_memory", receipt_id, digest)
    bounds = _exact_fields(
        value["phase_bounds"], _BOUNDS_FIELDS, "OS receipt phase bounds"
    )
    processes = _processes_from_evidence(value["processes"], "OS receipt processes")
    close_binding = PhaseCloseBinding.from_mapping(value["close_binding"])
    provider = OSProviderProvenance.from_mapping(value["provider"])
    return TrustedOSCoalitionReceipt(
        trusted_execution_index_id=value["trusted_execution_index_id"],
        receipt_id=receipt_id,
        producer_id=value["producer_id"],
        producer_attestation_id=value["producer_attestation_id"],
        producer_executable_sha256=value["producer_executable_sha256"],
        producer_audit_token_sha256=value["producer_audit_token_sha256"],
        binding=MemoryBinding.from_mapping(value["binding"]),
        phase=value["phase"],
        variant=value["variant"],
        close_binding=close_binding,
        phase_bounds=PhaseBounds(
            bounds["started_monotonic_ns"], bounds["ended_monotonic_ns"]
        ),
        coalition_id=value["coalition_id"],
        processes=processes,
        provider=provider,
        query_id=value["query_id"],
        query_started_monotonic_ns=value["query_started_monotonic_ns"],
        query_ended_monotonic_ns=value["query_ended_monotonic_ns"],
        query_status=value["query_status"],
        lifecycle_receipt_sha256=value["lifecycle_receipt_sha256"],
        reducer_evidence_sha256=value["reducer_evidence_sha256"],
        sealed_monotonic_ns=value["sealed_monotonic_ns"],
        work_sequence_at_seal=value["work_sequence_at_seal"],
        retained_receipt_sha256=digest,
        _capability_seal=_RECEIPT_CAPABILITY_SEAL,
    )


def _append_error(errors: list[str], exc: MemoryReconciliationError) -> None:
    errors.append(str(exc))


def _parse_categories(
    value: Any,
    *,
    epoch_id: str,
    snapshot_id: str,
    sequence: int,
    baseline: bool,
    errors: list[str],
) -> tuple[dict[str, dict[str, int]], bool]:
    parsed: dict[str, dict[str, int]] = {}
    if not isinstance(value, Mapping):
        errors.append("categories must be an object")
        return parsed, False
    if any(not isinstance(category, str) for category in value):
        errors.append("memory category names must be strings")
        return parsed, False
    observed = set(value)
    required = set(REQUIRED_CATEGORY_FACTS)
    missing, extra = sorted(required - observed), sorted(observed - required)
    if missing or extra:
        errors.append(
            f"memory categories are not exact (missing={missing}, extra={extra})"
        )

    for category, category_facts in REQUIRED_CATEGORY_FACTS.items():
        facts = value.get(category)
        expected_fields = _CATEGORY_COMMON_FIELDS | set(category_facts)
        try:
            exact = _exact_fields(facts, expected_fields, f"memory category {category}")
            category_epoch_id = _bounded_identifier(
                exact["epoch_id"], f"memory category {category} epoch_id"
            )
            category_snapshot_id = _bounded_identifier(
                exact["snapshot_id"], f"memory category {category} snapshot_id"
            )
            category_sequence = _nonnegative_int(
                exact["checkpoint_sequence"],
                f"memory category {category} checkpoint_sequence",
            )
        except MemoryReconciliationError as exc:
            _append_error(errors, exc)
            continue
        if (
            category_epoch_id != epoch_id
            or category_snapshot_id != snapshot_id
            or category_sequence != sequence
        ):
            errors.append(
                f"memory category {category} is from a mixed atomic snapshot"
            )
            continue
        values: dict[str, int] = {}
        valid = True
        for fact in category_facts:
            try:
                values[fact] = _nonnegative_int(
                    exact[fact], f"{category}.{fact}"
                )
            except MemoryReconciliationError as exc:
                _append_error(errors, exc)
                valid = False
        if valid:
            parsed[category] = values

    complete = not missing and not extra and len(parsed) == len(required)
    if complete:
        for category, current, hwm in (*_BYTE_PAIRS, *_COUNT_PAIRS):
            current_value = parsed[category][current]
            hwm_value = parsed[category][hwm]
            if current_value > hwm_value:
                errors.append(f"{category}.{current} exceeds {hwm}")
                complete = False
            if baseline and current_value != hwm_value:
                errors.append(
                    f"baseline {category}.{hwm} must equal reset current value"
                )
                complete = False
    return parsed, complete


def _snapshot(
    value: Any,
    *,
    expected_sequence: int,
    expected_kind: str,
    expected_epoch_id: str,
    expected_epoch_generation: int,
    baseline: bool,
    errors: list[str],
) -> dict[str, Any] | None:
    error_count = len(errors)
    try:
        event = _exact_fields(value, _SNAPSHOT_FIELDS, expected_kind)
        sequence = _nonnegative_int(event["sequence"], f"{expected_kind} sequence")
        timestamp = _positive_int(event["monotonic_ns"], f"{expected_kind} timestamp")
        snapshot_id = _bounded_identifier(
            event["snapshot_id"], f"{expected_kind} snapshot_id"
        )
        aggregate_current = _nonnegative_int(
            event["aggregate_current_bytes"],
            f"{expected_kind} aggregate_current_bytes",
        )
        aggregate_hwm = _nonnegative_int(
            event["aggregate_native_hwm_bytes"],
            f"{expected_kind} aggregate_native_hwm_bytes",
        )
        barrier_id = _bounded_identifier(
            event["barrier_id"], f"{expected_kind} barrier_id"
        )
        work_sequence = _nonnegative_int(
            event["work_sequence"], f"{expected_kind} work_sequence"
        )
        event_epoch_id = _bounded_identifier(
            event["epoch_id"], f"{expected_kind} epoch_id"
        )
        event_epoch_generation = _positive_int(
            event["epoch_generation"], f"{expected_kind} epoch_generation"
        )
    except MemoryReconciliationError as exc:
        _append_error(errors, exc)
        return None
    if sequence != expected_sequence or event["kind"] != expected_kind:
        errors.append(f"{expected_kind} event has the wrong sequence or kind")
    if (
        event_epoch_id != expected_epoch_id
        or event_epoch_generation != expected_epoch_generation
    ):
        errors.append(f"{expected_kind} event has the wrong epoch")
    categories, complete = _parse_categories(
        event["categories"],
        epoch_id=expected_epoch_id,
        snapshot_id=snapshot_id,
        sequence=expected_sequence,
        baseline=baseline,
        errors=errors,
    )
    if complete:
        current_sum = sum(
            categories[category][current]
            for category, current, _hwm in _BYTE_PAIRS
        )
        maximum_category_hwm = max(
            categories[category][hwm]
            for category, _current, hwm in _BYTE_PAIRS
        )
        if aggregate_current != current_sum:
            errors.append(
                f"{expected_kind} aggregate current does not equal the disjoint "
                "category current sum"
            )
            complete = False
        if aggregate_hwm < aggregate_current or aggregate_hwm < maximum_category_hwm:
            errors.append(
                f"{expected_kind} aggregate native HWM is inconsistent with diagnostics"
            )
            complete = False
        if baseline and aggregate_hwm != aggregate_current:
            errors.append("baseline aggregate native HWM was not reset to current")
            complete = False
    return {
        "sequence": sequence,
        "timestamp": timestamp,
        "snapshot_id": snapshot_id,
        "aggregate_current": aggregate_current,
        "aggregate_hwm": aggregate_hwm,
        "barrier_id": barrier_id,
        "work_sequence": work_sequence,
        "categories": categories,
        "complete": complete and len(errors) == error_count,
    }


def _validate_native_events(
    evidence: Any,
    *,
    receipt: TrustedNativeProducerReceipt,
    expected_binding: MemoryBinding,
    expected_phase: str,
    expected_variant: str,
    bounds: PhaseBounds,
    close_binding: PhaseCloseBinding,
    errors: list[str],
) -> tuple[int | None, bool, bool, bool, int | None]:
    receipt_bound = True
    if (
        receipt.binding != expected_binding
        or receipt.phase != expected_phase
        or receipt.variant != expected_variant
        or receipt.phase_bounds != bounds
        or receipt.epoch_id != close_binding.epoch_id
        or receipt.epoch_generation != close_binding.epoch_generation
        or receipt.phase_end_barrier_id != close_binding.phase_end_barrier_id
        or receipt.work_sequence_at_phase_end
        != close_binding.work_sequence_at_phase_end
        or receipt.work_sequence_at_checkpoint
        != close_binding.work_sequence_at_phase_end
        or receipt.work_sequence_at_seal
        != close_binding.work_sequence_at_phase_end
    ):
        errors.append("trusted native receipt has the wrong workload or phase binding")
        receipt_bound = False
    if receipt.allocation_contract_sha256 != ALLOCATION_CONTRACT_SHA256:
        errors.append("trusted native receipt has the wrong allocation contract")
        receipt_bound = False
    try:
        observed_digest = native_event_sha256(evidence)
    except MemoryReconciliationError as exc:
        _append_error(errors, exc)
        observed_digest = None
    if observed_digest != receipt.event_sha256:
        errors.append("native producer receipt is not hash-bound to the event evidence")
        receipt_bound = False

    try:
        root = _exact_fields(evidence, _NATIVE_ROOT_FIELDS, "native memory events")
    except MemoryReconciliationError as exc:
        _append_error(errors, exc)
        return None, receipt_bound, False, False, None
    if root["schema"] != NATIVE_EVENT_SCHEMA:
        errors.append(f"native memory event schema must be {NATIVE_EVENT_SCHEMA}")

    identity_bound = True
    try:
        observed_binding = MemoryBinding.from_mapping(root["binding"])
        if observed_binding != expected_binding:
            errors.append("native event binding does not match expected binding")
            identity_bound = False
    except MemoryReconciliationError as exc:
        _append_error(errors, exc)
        identity_bound = False
    if root["phase"] != expected_phase or root["variant"] != expected_variant:
        errors.append("native events have the wrong phase or variant")
        identity_bound = False
    try:
        phase_started_ns = _positive_int(
            root["phase_started_monotonic_ns"], "native phase start"
        )
        phase_ended_ns = _positive_int(
            root["phase_ended_monotonic_ns"], "native phase end"
        )
        observed_close = PhaseCloseBinding.from_mapping(root["close_binding"])
    except MemoryReconciliationError as exc:
        _append_error(errors, exc)
        return None, receipt_bound, False, False, None
    if phase_started_ns != bounds.started_monotonic_ns or phase_ended_ns != bounds.ended_monotonic_ns:
        errors.append("native events have the wrong exact phase bounds")
        identity_bound = False
    if observed_close != close_binding:
        errors.append("native events have the wrong phase-close binding")
        identity_bound = False
    try:
        epoch_id = _bounded_identifier(root["epoch_id"], "native epoch_id")
        epoch_generation = _positive_int(
            root["epoch_generation"], "native epoch_generation"
        )
    except MemoryReconciliationError as exc:
        _append_error(errors, exc)
        return None, receipt_bound, identity_bound, False, None
    if (
        epoch_id != receipt.epoch_id
        or epoch_generation != receipt.epoch_generation
        or epoch_id != close_binding.epoch_id
        or epoch_generation != close_binding.epoch_generation
    ):
        errors.append("native event epoch does not match trusted receipt")
        identity_bound = False

    events = root["events"]
    if not isinstance(events, Sequence) or isinstance(events, (str, bytes)):
        errors.append("native events must be an array")
        return None, receipt_bound, identity_bound, False, None
    if len(events) != 3 or receipt.event_count != 3:
        errors.append(
            "native epoch must contain exactly reset, baseline, and one phase-end checkpoint"
        )
        return None, receipt_bound, identity_bound, False, None

    order_complete = True
    try:
        reset = _exact_fields(events[0], _RESET_FIELDS, "epoch reset")
        reset_sequence = _nonnegative_int(reset["sequence"], "reset sequence")
        reset_time = _positive_int(reset["monotonic_ns"], "reset timestamp")
        reset_generation = _positive_int(
            reset["epoch_generation"], "reset epoch_generation"
        )
        if (
            reset_sequence != 0
            or reset["kind"] != "epoch_reset"
            or reset["epoch_id"] != epoch_id
            or reset_generation != epoch_generation
            or reset_time != bounds.started_monotonic_ns
        ):
            errors.append("epoch reset is not sequence zero at the exact phase start")
            order_complete = False
    except MemoryReconciliationError as exc:
        _append_error(errors, exc)
        order_complete = False

    baseline = _snapshot(
        events[1],
        expected_sequence=1,
        expected_kind="phase_baseline",
        expected_epoch_id=epoch_id,
        expected_epoch_generation=epoch_generation,
        baseline=True,
        errors=errors,
    )
    checkpoint = _snapshot(
        events[2],
        expected_sequence=2,
        expected_kind="phase_end_checkpoint",
        expected_epoch_id=epoch_id,
        expected_epoch_generation=epoch_generation,
        baseline=False,
        errors=errors,
    )
    if baseline is None or checkpoint is None:
        return None, receipt_bound, identity_bound, False, None
    if baseline["timestamp"] != bounds.started_monotonic_ns:
        errors.append("native baseline is not at the exact phase start")
        order_complete = False
    if checkpoint["timestamp"] < bounds.ended_monotonic_ns:
        errors.append("native phase-end checkpoint precedes the exact phase end")
        order_complete = False
    if checkpoint["timestamp"] > bounds.ended_monotonic_ns + PHASE_CLOSE_BOUND_NS:
        errors.append("native phase-end checkpoint exceeds the fixed close bound")
        order_complete = False
    if (
        checkpoint["barrier_id"] != close_binding.phase_end_barrier_id
        or checkpoint["work_sequence"]
        != close_binding.work_sequence_at_phase_end
    ):
        errors.append("native phase-end checkpoint crossed a barrier or work sequence")
        order_complete = False
    if checkpoint["timestamp"] < baseline["timestamp"]:
        errors.append("native phase-end checkpoint precedes the baseline")
        order_complete = False
    if baseline["snapshot_id"] == checkpoint["snapshot_id"]:
        errors.append("baseline and phase-end checkpoint reuse one snapshot id")
        order_complete = False
    if receipt.completed_checkpoint_sequence != 2:
        errors.append("trusted native receipt did not seal checkpoint sequence two")
        order_complete = False
    if receipt.sealed_monotonic_ns < checkpoint["timestamp"]:
        errors.append("trusted native receipt was sealed before its checkpoint")
        order_complete = False
    if receipt.sealed_monotonic_ns > bounds.ended_monotonic_ns + PHASE_CLOSE_BOUND_NS:
        errors.append("trusted native receipt sealing exceeds the fixed close bound")
        order_complete = False
    if receipt.next_reset_epoch_generation != close_binding.epoch_generation + 1:
        errors.append("trusted native receipt has the wrong next reset epoch")
        order_complete = False
    if checkpoint["timestamp"] >= receipt.next_reset_monotonic_ns:
        errors.append("native phase-end checkpoint was not ordered before the next reset")
        order_complete = False

    categories_complete = bool(baseline["complete"] and checkpoint["complete"])
    if categories_complete:
        for category, current, hwm in (*_BYTE_PAIRS, *_COUNT_PAIRS):
            if checkpoint["categories"][category][hwm] < baseline["categories"][
                category
            ][current]:
                errors.append(
                    f"phase-end {category}.{hwm} is below its reset baseline"
                )
                categories_complete = False
        if checkpoint["aggregate_hwm"] < baseline["aggregate_current"]:
            errors.append("phase-end aggregate HWM is below reset baseline")
            categories_complete = False

    return (
        checkpoint["aggregate_hwm"] if categories_complete else None,
        receipt_bound,
        identity_bound,
        order_complete and categories_complete,
        checkpoint["timestamp"],
    )


def _processes_from_evidence(value: Any, label: str) -> tuple[CoalitionProcess, ...]:
    if not isinstance(value, Sequence) or isinstance(value, (str, bytes)) or not value:
        raise MemoryReconciliationError(f"{label} must be a non-empty array")
    parsed = tuple(CoalitionProcess.from_mapping(item) for item in value)
    if tuple(sorted(parsed)) != parsed:
        raise MemoryReconciliationError(f"{label} must be sorted canonically")
    return parsed


def _process_key(process: CoalitionProcess) -> tuple[int, int]:
    return process.process_id, process.process_start_abstime


def _parse_rusage_row(
    value: Any,
    *,
    label: str,
    expected_observation_id: str,
    provider: OSProviderProvenance,
    coalition_id: int,
    enclosing_started_ns: int,
    enclosing_ended_ns: int,
    require_live_current: bool,
    errors: list[str],
) -> tuple[CoalitionProcess, int, int] | None:
    try:
        row = _exact_fields(value, _RUSAGE_ROW_FIELDS, label)
        process = CoalitionProcess.from_mapping(
            {field: row[field] for field in _PROCESS_FIELDS}
        )
        observation_id = _bounded_identifier(
            row["observation_id"], f"{label} observation_id"
        )
        query_started_ns = _positive_int(
            row["query_started_monotonic_ns"], f"{label} query start"
        )
        query_ended_ns = _positive_int(
            row["query_ended_monotonic_ns"], f"{label} query end"
        )
        query_status = _nonnegative_int(row["query_status"], f"{label} status")
        observed_provider = OSProviderProvenance.from_mapping(
            {field: row[field] for field in _PROVIDER_FIELDS}
        )
        current = (
            _positive_int(
                row["current_phys_footprint_bytes"], f"{label} current bytes"
            )
            if require_live_current
            else _nonnegative_int(
                row["current_phys_footprint_bytes"], f"{label} current bytes"
            )
        )
        lifetime_hwm = _positive_int(
            row["lifetime_max_phys_footprint_bytes"], f"{label} lifetime HWM"
        )
    except MemoryReconciliationError as exc:
        _append_error(errors, exc)
        return None
    if process.coalition_id != coalition_id:
        errors.append(f"{label} has the wrong coalition")
        return None
    if observation_id != expected_observation_id:
        errors.append(f"{label} has the wrong observation id")
        return None
    if (
        query_started_ns < enclosing_started_ns
        or query_ended_ns > enclosing_ended_ns
        or query_ended_ns < query_started_ns
    ):
        errors.append(f"{label} query bracket is outside its trusted observation")
        return None
    if query_status != 0:
        errors.append(f"{label} provider query did not succeed")
        return None
    if observed_provider != provider:
        errors.append(f"{label} has different provider provenance")
        return None
    if lifetime_hwm < current:
        errors.append(f"{label} lifetime HWM is below current footprint")
        return None
    return process, current, lifetime_hwm


def _validate_lifecycle_receipt(
    value: Any,
    *,
    expected_sha256: str | None,
    binding: MemoryBinding,
    phase: str,
    variant: str,
    close_binding: PhaseCloseBinding,
    bounds: PhaseBounds,
    coalition_id: int,
    provider: OSProviderProvenance,
    initial_processes: tuple[CoalitionProcess, ...],
    query_processes: tuple[CoalitionProcess, ...],
    task_counters: tuple[int, int, int, int],
    task_counter_bounds: tuple[int, int],
    errors: list[str],
) -> tuple[list[tuple[CoalitionProcess, int]], bool, bool]:
    started_before, started_after, exited_before, exited_after = task_counters
    started_delta = started_after - started_before
    exited_delta = exited_after - exited_before
    if started_delta < 0 or exited_delta < 0:
        errors.append("coalition task counters run backwards")
        return [], True, False
    churn = started_delta != 0 or exited_delta != 0
    if churn and (value is None or expected_sha256 is None):
        errors.append(
            "task churn requires an exact lifecycle/member/final-rusage receipt"
        )
        return [], True, False
    if (
        started_before < exited_before
        or started_after < exited_after
        or started_before - exited_before != len(initial_processes)
        or started_after - exited_after != len(query_processes)
    ):
        errors.append("coalition task counters do not match active member sets")
        return [], churn, False
    if not churn:
        if value is not None or expected_sha256 is not None:
            errors.append("lifecycle receipt is forbidden when no task churn occurred")
            return [], False, False
        if query_processes != initial_processes:
            errors.append("coalition member set changed without task-counter churn")
            return [], False, False
        return [], False, True
    try:
        lifecycle, observed_sha256 = _canonical_json_snapshot(
            value, "coalition lifecycle receipt"
        )
        root = _exact_fields(
            lifecycle, _LIFECYCLE_FIELDS, "coalition lifecycle receipt"
        )
    except MemoryReconciliationError as exc:
        _append_error(errors, exc)
        return [], True, False
    complete = True
    if observed_sha256 != expected_sha256:
        errors.append("lifecycle receipt hash does not match the trusted OS receipt")
        complete = False
    if root["schema"] != LIFECYCLE_RECEIPT_SCHEMA:
        errors.append("coalition lifecycle receipt schema is invalid")
        complete = False
    try:
        lifecycle_id = _bounded_identifier(root["receipt_id"], "lifecycle receipt_id")
        observed_binding = MemoryBinding.from_mapping(root["binding"])
        observed_close = PhaseCloseBinding.from_mapping(root["close_binding"])
        observed_provider = OSProviderProvenance.from_mapping(root["provider"])
        observed_coalition = _positive_int(
            root["coalition_id"], "lifecycle coalition_id"
        )
        observed_counters = tuple(
            _nonnegative_int(root[field], f"lifecycle {field}")
            for field in (
                "tasks_started_before",
                "tasks_started_after",
                "tasks_exited_before",
                "tasks_exited_after",
            )
        )
        observed_counter_bounds = (
            _positive_int(
                root["task_counters_started_monotonic_ns"],
                "lifecycle task-counter start",
            ),
            _positive_int(
                root["task_counters_ended_monotonic_ns"],
                "lifecycle task-counter end",
            ),
        )
    except MemoryReconciliationError as exc:
        _append_error(errors, exc)
        return [], True, False
    if (
        observed_binding != binding
        or root["phase"] != phase
        or root["variant"] != variant
        or observed_close != close_binding
        or observed_provider != provider
        or observed_coalition != coalition_id
        or observed_counters != task_counters
        or observed_counter_bounds != task_counter_bounds
    ):
        errors.append("lifecycle receipt has the wrong workload or provider binding")
        complete = False

    raw_events = root["events"]
    if not isinstance(raw_events, Sequence) or isinstance(raw_events, (str, bytes)):
        errors.append("lifecycle events must be an array")
        return [], True, False
    active = {_process_key(process): process for process in initial_processes}
    known = dict(active)
    exited_hwm: list[tuple[CoalitionProcess, int]] = []
    observed_starts = 0
    observed_exits = 0
    for index, raw_event in enumerate(raw_events):
        try:
            event = _exact_fields(
                raw_event, _LIFECYCLE_EVENT_FIELDS, f"lifecycle event {index}"
            )
            sequence = _nonnegative_int(
                event["sequence"], f"lifecycle event {index} sequence"
            )
            event_ns = _positive_int(
                event["monotonic_ns"], f"lifecycle event {index} timestamp"
            )
            member = CoalitionProcess.from_mapping(event["member"])
        except MemoryReconciliationError as exc:
            _append_error(errors, exc)
            complete = False
            continue
        if sequence != index:
            errors.append(f"lifecycle event {index} sequence is not contiguous")
            complete = False
        if not (bounds.started_monotonic_ns <= event_ns <= bounds.ended_monotonic_ns):
            errors.append(f"lifecycle event {index} is outside the exact phase")
            complete = False
        if member.coalition_id != coalition_id:
            errors.append(f"lifecycle event {index} has the wrong coalition")
            complete = False
        key = _process_key(member)
        if event["kind"] == "task_started":
            observed_starts += 1
            if event["final_rusage"] is not None:
                errors.append(f"lifecycle start event {index} has final rusage")
                complete = False
            if (
                key in known
                or member.role == "app"
                or any(
                    active_member.process_id == member.process_id
                    for active_member in active.values()
                )
            ):
                errors.append(f"lifecycle start event {index} reuses a member identity")
                complete = False
            else:
                known[key] = member
                active[key] = member
        elif event["kind"] == "task_exited":
            observed_exits += 1
            if key not in active or active.get(key) != member or member.role == "app":
                errors.append(f"lifecycle exit event {index} is not an active helper")
                complete = False
                continue
            observation_id = f"{lifecycle_id}.exit.{index}"
            row = _parse_rusage_row(
                event["final_rusage"],
                label=f"lifecycle exit event {index} final rusage",
                expected_observation_id=observation_id,
                provider=provider,
                coalition_id=coalition_id,
                enclosing_started_ns=bounds.started_monotonic_ns,
                enclosing_ended_ns=bounds.ended_monotonic_ns + PHASE_CLOSE_BOUND_NS,
                require_live_current=False,
                errors=errors,
            )
            if row is None or row[0] != member:
                errors.append(f"lifecycle exit event {index} lacks exact final rusage")
                complete = False
            else:
                final_started_ns = event["final_rusage"][
                    "query_started_monotonic_ns"
                ]
                final_ended_ns = event["final_rusage"][
                    "query_ended_monotonic_ns"
                ]
                if not (final_started_ns <= event_ns <= final_ended_ns):
                    errors.append(
                        f"lifecycle exit event {index} is outside its final-rusage bracket"
                    )
                    complete = False
                exited_hwm.append((member, row[2]))
            del active[key]
        else:
            errors.append(f"lifecycle event {index} kind is invalid")
            complete = False
    if observed_starts != started_delta or observed_exits != exited_delta:
        errors.append("lifecycle event counts do not match coalition task counters")
        complete = False
    active_tuple = tuple(sorted(active.values()))
    if active_tuple != query_processes:
        errors.append("lifecycle result does not match the final query member set")
        complete = False
    return exited_hwm, True, complete


def _validate_os_evidence(
    evidence: Any,
    *,
    receipt: TrustedOSCoalitionReceipt,
    expected_binding: MemoryBinding,
    expected_phase: str,
    expected_variant: str,
    bounds: PhaseBounds,
    close_binding: PhaseCloseBinding,
    expected_processes: tuple[CoalitionProcess, ...],
    errors: list[str],
) -> tuple[int | None, int | None, int, bool, bool, bool, int | None]:
    receipt_bound = True
    if (
        receipt.binding != expected_binding
        or receipt.phase != expected_phase
        or receipt.variant != expected_variant
        or receipt.phase_bounds != bounds
        or receipt.close_binding != close_binding
        or receipt.processes != expected_processes
        or receipt.coalition_id != expected_processes[0].coalition_id
        or receipt.work_sequence_at_seal
        != close_binding.work_sequence_at_phase_end
    ):
        errors.append("trusted OS receipt has the wrong workload, process, or window binding")
        receipt_bound = False
    try:
        observed_digest = os_reducer_evidence_sha256(evidence)
    except MemoryReconciliationError as exc:
        _append_error(errors, exc)
        observed_digest = None
    if observed_digest != receipt.reducer_evidence_sha256:
        errors.append("trusted OS receipt is not hash-bound to raw reducer evidence")
        receipt_bound = False

    try:
        root = _exact_fields(evidence, _OS_ROOT_FIELDS, "OS reducer evidence")
    except MemoryReconciliationError as exc:
        _append_error(errors, exc)
        return None, None, 0, False, receipt_bound, False, None
    identity_bound = True
    if root["schema"] != OS_REDUCER_SCHEMA:
        errors.append(f"OS reducer schema must be {OS_REDUCER_SCHEMA}")
        identity_bound = False
    if root["receipt_id"] != receipt.receipt_id:
        errors.append("OS reducer evidence has the wrong receipt id")
        identity_bound = False
    try:
        observed_binding = MemoryBinding.from_mapping(root["binding"])
        if observed_binding != expected_binding:
            errors.append("OS reducer binding does not match expected binding")
            identity_bound = False
    except MemoryReconciliationError as exc:
        _append_error(errors, exc)
        identity_bound = False
    if root["phase"] != expected_phase or root["variant"] != expected_variant:
        errors.append("OS reducer evidence has the wrong phase or variant")
        identity_bound = False
    try:
        window = _exact_fields(root["window"], _BOUNDS_FIELDS, "OS reducer window")
        observed_bounds = PhaseBounds(
            window["started_monotonic_ns"], window["ended_monotonic_ns"]
        )
        if observed_bounds != bounds:
            errors.append("OS reducer evidence has the wrong exact window")
            identity_bound = False
        observed_close = PhaseCloseBinding.from_mapping(root["close_binding"])
        if observed_close != close_binding:
            errors.append("OS reducer evidence has the wrong phase-close binding")
            identity_bound = False
    except MemoryReconciliationError as exc:
        _append_error(errors, exc)
        identity_bound = False
    coalition_id = receipt.coalition_id
    try:
        coalition_id = _positive_int(root["coalition_id"], "OS reducer coalition_id")
        if coalition_id != receipt.coalition_id:
            errors.append("OS reducer evidence has the wrong coalition")
            identity_bound = False
        root_processes = _processes_from_evidence(
            root["processes"], "OS reducer process set"
        )
        _validate_process_tuple(root_processes, expected_binding, "OS reducer process set")
        if root_processes != expected_processes:
            errors.append("OS reducer evidence has a different process set")
            identity_bound = False
    except MemoryReconciliationError as exc:
        _append_error(errors, exc)
        identity_bound = False
    try:
        provider = OSProviderProvenance.from_mapping(root["provider"])
        if provider != receipt.provider:
            errors.append("OS reducer evidence has different provider provenance")
            identity_bound = False
        task_counters = tuple(
            _nonnegative_int(root[field], f"OS reducer {field}")
            for field in (
                "tasks_started_before",
                "tasks_started_after",
                "tasks_exited_before",
                "tasks_exited_after",
            )
        )
        task_counter_bounds = (
            _positive_int(
                root["task_counters_started_monotonic_ns"],
                "OS reducer task-counter start",
            ),
            _positive_int(
                root["task_counters_ended_monotonic_ns"],
                "OS reducer task-counter end",
            ),
        )
        query = _exact_fields(root["query"], _QUERY_FIELDS, "OS coalition query")
        query_id = _bounded_identifier(query["query_id"], "OS query_id")
        query_started_ns = _positive_int(
            query["query_started_monotonic_ns"], "OS query start"
        )
        query_ended_ns = _positive_int(
            query["query_ended_monotonic_ns"], "OS query end"
        )
        query_status = _nonnegative_int(query["query_status"], "OS query status")
        query_epoch_generation = _positive_int(
            query["epoch_generation"], "OS query epoch_generation"
        )
        query_work_begin = _nonnegative_int(
            query["work_sequence_at_query_begin"], "OS query begin work sequence"
        )
        query_work_end = _nonnegative_int(
            query["work_sequence_at_query_end"], "OS query end work sequence"
        )
        coalition_current = _nonnegative_int(
            query["coalition_current_footprint_bytes"],
            "OS coalition current footprint diagnostic",
        )
    except MemoryReconciliationError as exc:
        _append_error(errors, exc)
        return None, None, 0, False, receipt_bound, False, None
    query_complete = True
    if task_counter_bounds != (
        bounds.started_monotonic_ns,
        bounds.ended_monotonic_ns,
    ):
        errors.append("coalition task counters do not span the exact phase")
        query_complete = False
    if (
        query_id != receipt.query_id
        or query_started_ns != receipt.query_started_monotonic_ns
        or query_ended_ns != receipt.query_ended_monotonic_ns
        or query_status != receipt.query_status
    ):
        errors.append("OS query does not match the trusted receipt")
        receipt_bound = False
        query_complete = False
    if query_status != 0:
        errors.append("OS coalition query did not succeed")
        query_complete = False
    if (
        query["epoch_id"] != close_binding.epoch_id
        or query_epoch_generation != close_binding.epoch_generation
        or query["phase_end_barrier_id"] != close_binding.phase_end_barrier_id
        or query_work_begin != close_binding.work_sequence_at_phase_end
        or query_work_end != close_binding.work_sequence_at_phase_end
    ):
        errors.append("OS query crossed an epoch, barrier, or work sequence")
        query_complete = False
    if (
        query_started_ns < bounds.ended_monotonic_ns
        or query_ended_ns < query_started_ns
        or query_ended_ns > bounds.ended_monotonic_ns + PHASE_CLOSE_BOUND_NS
    ):
        errors.append("OS query is outside the fixed phase-close bound")
        query_complete = False
    if (
        receipt.sealed_monotonic_ns < query_ended_ns
        or receipt.sealed_monotonic_ns
        > bounds.ended_monotonic_ns + PHASE_CLOSE_BOUND_NS
    ):
        errors.append("trusted OS receipt sealing is outside the fixed close bound")
        query_complete = False

    raw_members = query["members"]
    if not isinstance(raw_members, Sequence) or isinstance(raw_members, (str, bytes)) or not raw_members:
        errors.append("OS query must contain exact per-member rows")
        return None, coalition_current, 0, False, receipt_bound, False, query_ended_ns
    member_rows: list[tuple[CoalitionProcess, int, int]] = []
    for index, raw_member in enumerate(raw_members):
        row = _parse_rusage_row(
            raw_member,
            label=f"OS query member {index}",
            expected_observation_id=query_id,
            provider=provider,
            coalition_id=coalition_id,
            enclosing_started_ns=query_started_ns,
            enclosing_ended_ns=query_ended_ns,
            require_live_current=True,
            errors=errors,
        )
        if row is None:
            query_complete = False
        else:
            member_rows.append(row)
    query_processes = tuple(row[0] for row in member_rows)
    if tuple(sorted(query_processes)) != query_processes:
        errors.append("OS query member rows are not sorted canonically")
        query_complete = False
    if len({_process_key(process) for process in query_processes}) != len(query_processes):
        errors.append("OS query contains duplicate member identities")
        query_complete = False
    if len({process.process_id for process in query_processes}) != len(query_processes):
        errors.append("OS query contains simultaneous duplicate PIDs")
        query_complete = False

    exited_rows, churn, lifecycle_complete = _validate_lifecycle_receipt(
        root["lifecycle_receipt"],
        expected_sha256=receipt.lifecycle_receipt_sha256,
        binding=expected_binding,
        phase=expected_phase,
        variant=expected_variant,
        close_binding=close_binding,
        bounds=bounds,
        coalition_id=coalition_id,
        provider=provider,
        initial_processes=expected_processes,
        query_processes=query_processes,
        task_counters=task_counters,
        task_counter_bounds=task_counter_bounds,
        errors=errors,
    )
    complete = identity_bound and query_complete and lifecycle_complete
    all_hwm_rows = [(row[0], row[2]) for row in member_rows] + exited_rows
    all_keys = [_process_key(process) for process, _hwm in all_hwm_rows]
    if len(set(all_keys)) != len(all_keys):
        errors.append("OS member HWM evidence double-counts one process incarnation")
        complete = False
    derived_peak = sum(hwm for _process, hwm in all_hwm_rows) if complete else None
    return (
        derived_peak,
        coalition_current,
        len(all_hwm_rows),
        churn,
        receipt_bound,
        complete,
        query_ended_ns,
    )


def validate_memory_reconciliation(
    native_event_evidence: Any,
    *,
    trusted_native_receipt: TrustedNativeProducerReceipt,
    os_reducer_evidence: Any,
    trusted_os_receipt: TrustedOSCoalitionReceipt,
    trusted_execution_index: TrustedExecutionIndex,
    expected_binding: MemoryBinding,
    expected_phase: str,
    expected_variant: str,
    allowed_phase_bounds: PhaseBounds,
    expected_close_binding: PhaseCloseBinding,
    expected_processes: tuple[CoalitionProcess, ...],
    memory_limit_bytes: int = DEFAULT_MEMORY_LIMIT_BYTES,
) -> MemoryReconciliationReport:
    """Validate both receipts/evidence streams and evaluate the strict gate.

    Receipt arguments must already be authenticated typed values.  Plain
    mappings are rejected rather than being allowed to self-declare trust.
    """

    if not isinstance(expected_binding, MemoryBinding):
        raise MemoryReconciliationError("expected_binding must be validated")
    if not isinstance(allowed_phase_bounds, PhaseBounds):
        raise MemoryReconciliationError("allowed_phase_bounds must be validated")
    if not isinstance(expected_close_binding, PhaseCloseBinding):
        raise MemoryReconciliationError("expected_close_binding must be validated")
    if not isinstance(trusted_native_receipt, TrustedNativeProducerReceipt):
        raise MemoryReconciliationError(
            "trusted_native_receipt must come from the authenticated capture boundary"
        )
    if not isinstance(trusted_os_receipt, TrustedOSCoalitionReceipt):
        raise MemoryReconciliationError(
            "trusted_os_receipt must come from the authenticated capture boundary"
        )
    if not isinstance(trusted_execution_index, TrustedExecutionIndex):
        raise MemoryReconciliationError(
            "trusted_execution_index must be an authoritative out-of-band index"
        )
    _bounded_identifier(expected_phase, "expected_phase")
    _bounded_identifier(expected_variant, "expected_variant")
    processes = _validate_process_tuple(
        expected_processes, expected_binding, "expected_processes"
    )
    requested_limit = _positive_int(memory_limit_bytes, "memory_limit_bytes")
    effective_limit = min(requested_limit, DEFAULT_MEMORY_LIMIT_BYTES)

    errors: list[str] = []
    try:
        native_snapshot, native_evidence_digest = _canonical_json_snapshot(
            native_event_evidence, "native memory event evidence"
        )
    except MemoryReconciliationError as exc:
        errors.append(str(exc))
        native_snapshot, native_evidence_digest = None, None
    try:
        os_snapshot, os_evidence_digest = _canonical_json_snapshot(
            os_reducer_evidence, "OS coalition reducer evidence"
        )
    except MemoryReconciliationError as exc:
        errors.append(str(exc))
        os_snapshot, os_evidence_digest = None, None
    native_capability_bound = True
    os_capability_bound = True
    for kind, label, receipt in (
        ("native_memory", "native", trusted_native_receipt),
        ("os_coalition_memory", "OS", trusted_os_receipt),
    ):
        bound = True
        if receipt.trusted_execution_index_id != trusted_execution_index.index_id:
            errors.append(f"trusted {label} receipt has the wrong execution index")
            bound = False
        observed_receipt_digest = _canonical_sha256(
            receipt.as_dict(), f"trusted {label} receipt"
        )
        if observed_receipt_digest != receipt.retained_receipt_sha256:
            errors.append(f"trusted {label} receipt capability bytes were altered")
            bound = False
        try:
            trusted_execution_index.require_digest(
                kind, receipt.receipt_id, receipt.retained_receipt_sha256
            )
        except MemoryReconciliationError as exc:
            errors.append(f"trusted {label} receipt: {exc}")
            bound = False
        if kind == "native_memory":
            native_capability_bound = bound
        else:
            os_capability_bound = bound
    (
        native_peak,
        native_receipt_bound,
        native_identity,
        epoch_complete,
        native_checkpoint_ns,
    ) = (
        _validate_native_events(
            native_snapshot,
            receipt=trusted_native_receipt,
            expected_binding=expected_binding,
            expected_phase=expected_phase,
            expected_variant=expected_variant,
            bounds=allowed_phase_bounds,
            close_binding=expected_close_binding,
            errors=errors,
        )
    )
    (
        os_peak,
        os_current,
        os_member_count,
        os_churn,
        os_receipt_bound,
        os_identity,
        os_query_ended_ns,
    ) = _validate_os_evidence(
        os_snapshot,
        receipt=trusted_os_receipt,
        expected_binding=expected_binding,
        expected_phase=expected_phase,
        expected_variant=expected_variant,
        bounds=allowed_phase_bounds,
        close_binding=expected_close_binding,
        expected_processes=processes,
        errors=errors,
    )
    native_receipt_bound = native_receipt_bound and native_capability_bound
    os_receipt_bound = os_receipt_bound and os_capability_bound
    if (
        native_checkpoint_ns is not None
        and os_query_ended_ns is not None
        and trusted_native_receipt.next_reset_monotonic_ns
        <= max(
            native_checkpoint_ns,
            os_query_ended_ns,
            trusted_native_receipt.sealed_monotonic_ns,
            trusted_os_receipt.sealed_monotonic_ns,
        )
    ):
        errors.append("a phase reset intervened before close evidence was sealed")
        epoch_complete = False

    untracked_delta: int | None = None
    if native_peak is not None and os_peak is not None:
        if native_peak > os_peak:
            errors.append(
                "native aggregate HWM exceeds the conservative OS member-HWM sum"
            )
        else:
            untracked_delta = os_peak - native_peak

    identity_bound = native_identity and os_identity
    categories_complete = native_peak is not None
    reconciliation_complete = (
        not errors
        and identity_bound
        and native_receipt_bound
        and os_receipt_bound
        and epoch_complete
        and categories_complete
        and os_peak is not None
        and untracked_delta is not None
    )
    under_limit = reconciliation_complete and os_peak < effective_limit
    if reconciliation_complete and not under_limit:
        errors.append(
            "conservative OS member-HWM sum must be strictly less than "
            f"{effective_limit} bytes"
        )
    evidence_pass = reconciliation_complete and under_limit

    evaluation_context_sha256 = _canonical_sha256(
        {
            "schema": SCHEMA,
            "trusted_execution_index_id": trusted_execution_index.index_id,
            "binding": expected_binding.as_dict(),
            "phase": expected_phase,
            "variant": expected_variant,
            "phase_bounds": allowed_phase_bounds.as_dict(),
            "close_binding": expected_close_binding.as_dict(),
            "processes": [process.as_dict() for process in processes],
            "native_event_sha256": native_evidence_digest,
            "native_receipt_sha256": trusted_native_receipt.retained_receipt_sha256,
            "os_reducer_evidence_sha256": os_evidence_digest,
            "os_receipt_sha256": trusted_os_receipt.retained_receipt_sha256,
            "allocation_contract_sha256": ALLOCATION_CONTRACT_SHA256,
            "requested_memory_limit_bytes": requested_limit,
            "effective_memory_limit_bytes": effective_limit,
            "hard_memory_ceiling_bytes": DEFAULT_MEMORY_LIMIT_BYTES,
            "phase_close_bound_ns": PHASE_CLOSE_BOUND_NS,
        },
        "memory reconciliation evaluation context",
    )

    return MemoryReconciliationReport(
        schema=SCHEMA,
        reconciliation_complete=reconciliation_complete,
        identity_bound=identity_bound,
        native_receipt_bound=native_receipt_bound,
        os_receipt_bound=os_receipt_bound,
        epoch_and_order_complete=epoch_complete,
        required_categories_complete=categories_complete,
        os_conservative_member_hwm_sum_bytes=os_peak,
        os_coalition_current_footprint_bytes=os_current,
        os_distinct_member_count=os_member_count,
        os_member_churn_observed=os_churn,
        native_reconciled_peak_bytes=native_peak,
        untracked_delta_bytes=untracked_delta,
        untracked_delta_definition=UNTRACKED_DELTA_DEFINITION,
        requested_memory_limit_bytes=requested_limit,
        effective_memory_limit_bytes=effective_limit,
        hard_memory_ceiling_bytes=DEFAULT_MEMORY_LIMIT_BYTES,
        phase_close_bound_ns=PHASE_CLOSE_BOUND_NS,
        under_memory_limit=under_limit,
        evidence_pass=evidence_pass,
        production_integration_authorized=False,
        gate_pass=False,
        evaluation_context_sha256=evaluation_context_sha256,
        errors=tuple(errors),
    )


def require_memory_reconciliation(
    native_event_evidence: Any,
    **kwargs: Any,
) -> MemoryReconciliationReport:
    """Return a passing report or raise with every fail-closed reason."""

    report = validate_memory_reconciliation(native_event_evidence, **kwargs)
    if not report.evidence_pass:
        raise MemoryReconciliationError("; ".join(report.errors))
    return report
