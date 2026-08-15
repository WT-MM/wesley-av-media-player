#!/usr/bin/env python3
"""Trust-boundary evidence for an approved macOS screen-backed shipper run.

This module is deliberately incapable of launching an application, posting an
input event, recording a screen, or recording audio on its own.  A caller may
provide an explicit runner to :func:`run_capture_command`; tests and offline
validation need no runner at all.

The SHA-256 seals below provide integrity, not remote attestation.  A valid
receipt is trustworthy only when the caller independently trusts the harness,
supplies the unpredictable capture nonce, and supplies the expected executable
identities.  The receipt records that boundary verbatim so a self-authored JSON
file cannot silently masquerade as OS-level proof.
"""

from __future__ import annotations

import dataclasses
import hashlib
import json
import math
import os
import re
import secrets
import stat
import struct
import uuid
import zlib
from collections.abc import Callable, Mapping, Sequence
from typing import Any


RECEIPT_SCHEMA = "wam.macos.shipper.screen-driver-receipt.v1"
AUDIT_ARTIFACT_SCHEMA = "wam.macos.shipper.window-audit-artifact.v1"
INPUT_TRACE_SCHEMA = "wam.macos.shipper.input-trace-artifact.v1"
DIALOG_ACCEPTANCE_SCHEMA = "wam.macos.shipper.dialog-acceptance-artifact.v1"
NATIVE_TELEMETRY_SCHEMA = "wam.native.benchmark.v2"
INITIAL_OPEN_SCHEMA = "wam.macos.shipper.initial-open-artifact.v1"
LOADER_CAPTURE_SCHEMA = "wam.macos.shipper.loader-capture-artifact.v1"
TRUST_BOUNDARY = (
    "integrity-only: the caller must authenticate the capture harness, "
    "capture nonce, and expected executable identities"
)
EXPECTED_WAM_BUNDLE_ID = "com.wesleymaa.wam"
DRAG_RATE_HZ = 120
DRAG_LEG_DURATION_NS = 4_000_000_000
DRAG_PERIOD_NS = round(1_000_000_000 / DRAG_RATE_HZ)
DRAG_MOVE_COUNT_PER_LEG = DRAG_RATE_HZ * 4
DRAG_EDGE_INSET = 0.05
DRAG_DELIVERY_TOLERANCE_NS = 500_000
STEADY_SAMPLE_PERIOD_NS = 500_000_000
STEADY_SAMPLE_COUNT = 9
STEADY_SAMPLE_DURATION_NS = (STEADY_SAMPLE_COUNT - 1) * STEADY_SAMPLE_PERIOD_NS

_SHA256_RE = re.compile(r"[0-9a-f]{64}")
_IDENTIFIER_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._:-]{0,127}")
_NONCE_RE = re.compile(r"[0-9a-f]{64}")
_BINDING_FIELDS = {
    "run_id",
    "process_id",
    "process_start_abstime",
    "asset_sha256",
    "candidate_id",
    "source_key",
}
_ASSET_FIELDS = {"canonical_path", "device", "inode"}
_DYLIB_FIELDS = {"canonical_path", "device", "inode", "sha256"}
_PHASE_VARIANT_FIELDS = {"phase", "codec", "container", "profile", "replicate"}
_INVOCATION_FIELDS = {
    "invocation_id",
    "role",
    "executable_path",
    "executable_sha256",
    "argv",
    "capture_context_sha256",
}
_AUDIT_FIELDS = {
    "audit_session_id",
    "audit_uid",
    "effective_uid",
    "real_uid",
    "effective_gid",
    "real_gid",
    "process_id",
    "audit_token_sha256",
    "signing_identifier",
    "team_identifier",
    "executable_path",
    "executable_sha256",
    "screen_recording_authorized",
    "accessibility_authorized",
}
_WINDOW_FIELDS = {
    "window_id",
    "owner_process_id",
    "owner_process_start_abstime",
    "owner_bundle_id",
    "owner_name",
    "onscreen",
    "frontmost",
    "visible",
    "layer",
    "alpha",
    "display_id",
    "bounds_x",
    "bounds_y",
    "bounds_width",
    "bounds_height",
    "backing_scale_factor",
}
_INPUT_RECEIPT_FIELDS = {
    "receipt_id",
    "invocation_id",
    "audit_session_id",
    "audit_token_sha256",
    "target_process_id",
    "target_process_start_abstime",
    "target_window_id",
    "event_tap_location",
    "posted_by_harness",
    "started_monotonic_ns",
    "ended_monotonic_ns",
    "event_count",
    "event_sequence_sha256",
    "artifact_id",
}
_ARTIFACT_FIELDS = {
    "artifact_id",
    "kind",
    "sha256",
    "byte_length",
    "media_type",
    "producer_invocation_id",
    "producer_receipt_id",
    "capture_started_monotonic_ns",
    "capture_ended_monotonic_ns",
}
_EVENT_FIELDS = {
    "sequence",
    "event",
    "monotonic_ns",
    "binding",
    "capture_nonce",
    "actor_invocation_id",
    "artifact_id",
    "details",
}
_NATIVE_EVENT_FIELDS = {
    "schema",
    "event",
    "monotonic_ns",
    "route",
    "route_proof",
    "source_key",
    "attempt",
    "serial",
    "generation",
    "gesture",
    "request",
    "draw_sequence",
    "target_seconds",
    "libmpv_initialized",
    "run_id",
    "process_id",
    "process_start_abstime",
    "asset_sha256",
    "candidate_id",
}
_NATIVE_IDENTITY_FIELDS = {
    "schema",
    "record",
    "run_id",
    "process_id",
    "process_start_abstime",
    "asset_sha256",
    "candidate_id",
}
_NATIVE_HEADER_FIELDS = _NATIVE_IDENTITY_FIELDS | {"format_version"}
_NATIVE_BATCH_BEGIN_FIELDS = _NATIVE_IDENTITY_FIELDS | {
    "batch",
    "event_count",
    "first_sequence",
    "last_sequence",
    "previous_chain_sha256",
}
_NATIVE_FRAMED_EVENT_FIELDS = _NATIVE_EVENT_FIELDS | {
    "record",
    "batch",
    "event_sequence",
}
_NATIVE_BATCH_COMMIT_FIELDS = _NATIVE_IDENTITY_FIELDS | {
    "batch",
    "event_count",
    "first_sequence",
    "last_sequence",
    "payload_sha256",
    "chain_sha256",
}
_NATIVE_STREAM_COMMIT_FIELDS = _NATIVE_IDENTITY_FIELDS | {
    "batch_count",
    "event_count",
    "first_sequence",
    "last_sequence",
    "chain_sha256",
}
_RECEIPT_FIELDS = {
    "schema",
    "captured_by_harness",
    "harness_trust_boundary",
    "binding",
    "phase_variant",
    "capture_nonce",
    "asset",
    "trusted_invocations",
    "macos_audit",
    "window",
    "input_driver_receipt",
    "artifacts",
    "events",
    "transcript_sha256",
}

COMMON_INVOCATION_ROLES = frozenset(
    {
        "app_executable",
        "capture_harness",
        "open_driver",
        "window_audit",
    }
)
PHASE_INVOCATION_ROLES = {
    "startup": COMMON_INVOCATION_ROLES | {"input_driver"},
    "steady": COMMON_INVOCATION_ROLES,
    "scrub": COMMON_INVOCATION_ROLES | {"input_driver"},
    "fallback_control": COMMON_INVOCATION_ROLES
    | {
        "screen_capture",
        "loader_inspector",
        "system_audio_capture",
    },
}
COMMON_ARTIFACT_KINDS = frozenset({"window_audit", "initial_open_receipt"})
PHASE_ARTIFACT_KINDS = {
    "startup": COMMON_ARTIFACT_KINDS
    | {"input_trace", "dialog_acceptance", "warm_source_telemetry"},
    "steady": COMMON_ARTIFACT_KINDS | {"steady_native_telemetry"},
    "scrub": COMMON_ARTIFACT_KINDS | {"input_trace", "scrub_native_telemetry"},
    "fallback_control": COMMON_ARTIFACT_KINDS
    | {
        "window_audit",
        "initial_open_receipt",
        "screenshot",
        "loader_pre",
        "fallback_route_telemetry",
        "loader_post",
        "system_audio",
    },
}
_ARTIFACT_MEDIA_TYPES = {
    "window_audit": "application/json",
    "initial_open_receipt": "application/json",
    "input_trace": "application/json",
    "dialog_acceptance": "application/json",
    "warm_source_telemetry": "application/json",
    "scrub_native_telemetry": "application/json",
    "steady_native_telemetry": "application/json",
    "fallback_route_telemetry": "application/json",
    "screenshot": "image/png",
    "loader_pre": "text/plain",
    "loader_post": "text/plain",
    "system_audio": "audio/wav",
}
_ACTOR_ROLES = {
    "macos_audit_capture": "window_audit",
    "loader_pre_capture": "loader_inspector",
    "loader_post_capture": "loader_inspector",
    "initial_open_action": "open_driver",
    "warm_open_action": "input_driver",
    "open_shortcut_key_down": "input_driver",
    "open_shortcut_key_up": "input_driver",
    "file_dialog_shown": "input_driver",
    "file_dialog_path_selected": "input_driver",
    "file_dialog_accepted": "input_driver",
    "warm_open_source_observed": "capture_harness",
    "steady_playback_started": "capture_harness",
    "steady_playback_sample": "capture_harness",
    "steady_playback_completed": "capture_harness",
    "fallback_route_selected": "capture_harness",
    "scrub_telemetry_started": "capture_harness",
    "scrub_telemetry_completed": "capture_harness",
    "pointer_down": "input_driver",
    "pointer_move": "input_driver",
    "pointer_up": "input_driver",
    "screenshot_capture": "screen_capture",
    "system_audio_capture": "system_audio_capture",
}


class ScreenDriverEvidenceError(ValueError):
    """A capture receipt cannot support a screen-backed shipping claim."""


def _exact_fields(value: Any, expected: set[str], label: str) -> Mapping[str, Any]:
    if not isinstance(value, Mapping):
        raise ScreenDriverEvidenceError(f"{label} must be an object")
    fields = set(value)
    if fields != expected:
        missing = sorted(expected - fields)
        extra = sorted(fields - expected)
        raise ScreenDriverEvidenceError(
            f"{label} fields are not exact (missing={missing}, extra={extra})"
        )
    return value


def _positive_int(value: Any, label: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value <= 0:
        raise ScreenDriverEvidenceError(f"{label} must be a positive integer")
    return value


def _nonnegative_int(value: Any, label: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        raise ScreenDriverEvidenceError(f"{label} must be a non-negative integer")
    return value


def _finite(value: Any, label: str, *, positive: bool = False) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ScreenDriverEvidenceError(f"{label} must be finite numeric data")
    result = float(value)
    if not math.isfinite(result) or (result <= 0.0 if positive else False):
        qualifier = "positive " if positive else ""
        raise ScreenDriverEvidenceError(f"{label} must be finite {qualifier}numeric data")
    return result


def _identifier(value: Any, label: str) -> str:
    if not isinstance(value, str) or _IDENTIFIER_RE.fullmatch(value) is None:
        raise ScreenDriverEvidenceError(f"{label} is not a bounded identifier")
    return value


def _bounded_text(value: Any, label: str, *, limit: int = 1024) -> str:
    if (
        not isinstance(value, str)
        or not value
        or len(value) > limit
        or "\x00" in value
    ):
        raise ScreenDriverEvidenceError(f"{label} must be non-empty bounded text")
    return value


def _sha256(value: Any, label: str) -> str:
    if not isinstance(value, str) or _SHA256_RE.fullmatch(value) is None:
        raise ScreenDriverEvidenceError(f"{label} must be 64 lowercase hex digits")
    return value


def _canonical_uuid(value: Any, label: str) -> str:
    if not isinstance(value, str):
        raise ScreenDriverEvidenceError(f"{label} must be a canonical UUID")
    try:
        parsed = uuid.UUID(value)
    except (ValueError, AttributeError) as error:
        raise ScreenDriverEvidenceError(f"{label} must be a canonical UUID") from error
    if str(parsed) != value:
        raise ScreenDriverEvidenceError(f"{label} must be a lowercase canonical UUID")
    return value


def _canonical_absolute_path(value: Any, label: str) -> str:
    path = _bounded_text(value, label, limit=4096)
    if not os.path.isabs(path) or os.path.normpath(path) != path:
        raise ScreenDriverEvidenceError(f"{label} must be a canonical absolute path")
    return path


def _canonical_json_bytes(value: Any) -> bytes:
    try:
        return json.dumps(
            value,
            sort_keys=True,
            separators=(",", ":"),
            ensure_ascii=False,
            allow_nan=False,
        ).encode("utf-8")
    except (TypeError, ValueError, RecursionError) as error:
        raise ScreenDriverEvidenceError("capture payload is not canonical JSON data") from error


def _native_json_bytes(value: Mapping[str, Any]) -> bytes:
    """Use the fixed field order emitted by WAM's allocation-free v2 writer."""

    try:
        return json.dumps(
            value,
            sort_keys=False,
            separators=(",", ":"),
            ensure_ascii=False,
            allow_nan=False,
        ).encode("utf-8")
    except (TypeError, ValueError, RecursionError) as error:
        raise ScreenDriverEvidenceError("native telemetry payload is invalid") from error


def _digest(value: Any) -> str:
    return hashlib.sha256(_canonical_json_bytes(value)).hexdigest()


def new_capture_nonce() -> str:
    """Return a caller-retained 256-bit challenge for one real capture."""

    return secrets.token_hex(32)


@dataclasses.dataclass(frozen=True, slots=True)
class DriverBinding:
    run_id: str
    process_id: int
    process_start_abstime: int
    asset_sha256: str
    candidate_id: str
    source_key: int

    def __post_init__(self) -> None:
        _canonical_uuid(self.run_id, "run_id")
        _positive_int(self.process_id, "process_id")
        _positive_int(self.process_start_abstime, "process_start_abstime")
        _sha256(self.asset_sha256, "asset_sha256")
        _sha256(self.candidate_id, "candidate_id")
        _positive_int(self.source_key, "source_key")

    def as_dict(self) -> dict[str, Any]:
        return dataclasses.asdict(self)

    @classmethod
    def from_mapping(cls, value: Any) -> "DriverBinding":
        value = _exact_fields(value, _BINDING_FIELDS, "driver binding")
        return cls(**{field: value[field] for field in _BINDING_FIELDS})


@dataclasses.dataclass(frozen=True, slots=True)
class PhaseVariant:
    phase: str
    codec: str
    container: str
    profile: str
    replicate: int

    def __post_init__(self) -> None:
        if self.phase not in PHASE_INVOCATION_ROLES:
            raise ScreenDriverEvidenceError("phase is not a shipping capture phase")
        _identifier(self.codec, "variant codec")
        _identifier(self.container, "variant container")
        _identifier(self.profile, "variant profile")
        _nonnegative_int(self.replicate, "variant replicate")

    def as_dict(self) -> dict[str, Any]:
        return dataclasses.asdict(self)

    @classmethod
    def from_mapping(cls, value: Any) -> "PhaseVariant":
        value = _exact_fields(value, _PHASE_VARIANT_FIELDS, "phase variant")
        return cls(**{field: value[field] for field in _PHASE_VARIANT_FIELDS})


@dataclasses.dataclass(frozen=True, slots=True)
class AssetFileIdentity:
    canonical_path: str
    device: int
    inode: int

    def __post_init__(self) -> None:
        _canonical_absolute_path(self.canonical_path, "asset canonical_path")
        _positive_int(self.device, "asset device")
        _positive_int(self.inode, "asset inode")

    def as_dict(self) -> dict[str, Any]:
        return dataclasses.asdict(self)

    @classmethod
    def from_mapping(cls, value: Any) -> "AssetFileIdentity":
        value = _exact_fields(value, _ASSET_FIELDS, "asset file identity")
        return cls(**{field: value[field] for field in _ASSET_FIELDS})


@dataclasses.dataclass(frozen=True, slots=True)
class DylibFileIdentity:
    canonical_path: str
    device: int
    inode: int
    sha256: str

    def __post_init__(self) -> None:
        _canonical_absolute_path(self.canonical_path, "dylib canonical_path")
        _positive_int(self.device, "dylib device")
        _positive_int(self.inode, "dylib inode")
        _sha256(self.sha256, "dylib sha256")

    def as_dict(self) -> dict[str, Any]:
        return dataclasses.asdict(self)

    @classmethod
    def from_mapping(cls, value: Any) -> "DylibFileIdentity":
        value = _exact_fields(value, _DYLIB_FIELDS, "fallback dylib identity")
        return cls(**{field: value[field] for field in _DYLIB_FIELDS})


@dataclasses.dataclass(frozen=True, slots=True)
class TrustedInvocation:
    invocation_id: str
    role: str
    executable_path: str
    executable_sha256: str
    argv: tuple[str, ...]
    capture_context_sha256: str

    def __post_init__(self) -> None:
        _identifier(self.invocation_id, "invocation_id")
        _identifier(self.role, "invocation role")
        _canonical_absolute_path(self.executable_path, "executable_path")
        _sha256(self.executable_sha256, "executable_sha256")
        if not isinstance(self.argv, tuple) or not self.argv:
            raise ScreenDriverEvidenceError("invocation argv must be a non-empty tuple")
        for index, argument in enumerate(self.argv):
            _bounded_text(argument, f"argv[{index}]", limit=8192)
        if self.argv[0] != self.executable_path:
            raise ScreenDriverEvidenceError("argv[0] must be the identified executable path")
        _sha256(self.capture_context_sha256, "capture_context_sha256")
        context_argument = f"--capture-context-sha256={self.capture_context_sha256}"
        if self.argv.count(context_argument) != 1:
            raise ScreenDriverEvidenceError(
                "invocation argv must carry its exact capture context once"
            )

    def as_dict(self) -> dict[str, Any]:
        value = dataclasses.asdict(self)
        value["argv"] = list(self.argv)
        return value

    @classmethod
    def from_mapping(cls, value: Any) -> "TrustedInvocation":
        value = _exact_fields(value, _INVOCATION_FIELDS, "trusted invocation")
        argv = value["argv"]
        if isinstance(argv, (str, bytes)) or not isinstance(argv, Sequence):
            raise ScreenDriverEvidenceError("trusted invocation argv must be an array")
        return cls(
            invocation_id=value["invocation_id"],
            role=value["role"],
            executable_path=value["executable_path"],
            executable_sha256=value["executable_sha256"],
            argv=tuple(argv),
            capture_context_sha256=value["capture_context_sha256"],
        )


@dataclasses.dataclass(frozen=True, slots=True)
class CaptureCommandResult:
    returncode: int
    stdout: bytes
    stderr: bytes


CaptureRunner = Callable[[tuple[str, ...], int], CaptureCommandResult]


def build_capture_command(invocation: TrustedInvocation) -> tuple[str, ...]:
    """Build, but never execute, one already-identified invocation."""

    if not isinstance(invocation, TrustedInvocation):
        raise ScreenDriverEvidenceError("capture command requires a trusted invocation")
    return invocation.argv


def run_capture_command(
    invocation: TrustedInvocation,
    *,
    runner: CaptureRunner | None = None,
) -> CaptureCommandResult:
    """Run only through an explicit caller-owned capture runner."""

    if runner is None:
        raise ScreenDriverEvidenceError("capture execution requires an injected runner")
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    descriptor = -1
    try:
        descriptor = os.open(invocation.executable_path, flags)
        before = os.fstat(descriptor)
        if not stat.S_ISREG(before.st_mode) or not (before.st_mode & 0o111):
            raise ScreenDriverEvidenceError("trusted executable is no longer executable")
        digest = hashlib.sha256()
        while True:
            chunk = os.read(descriptor, 1024 * 1024)
            if not chunk:
                break
            digest.update(chunk)
        if digest.hexdigest() != invocation.executable_sha256:
            raise ScreenDriverEvidenceError("trusted executable bytes changed before capture")
        os.lseek(descriptor, 0, os.SEEK_SET)
        # The injected runner contract requires execution from this open file
        # descriptor, not a second pathname lookup.  Keeping the descriptor
        # open closes the identify-then-execute pathname race.
        result = runner(build_capture_command(invocation), descriptor)
        after = os.fstat(descriptor)
        stable = ("st_dev", "st_ino", "st_mode", "st_size", "st_mtime_ns", "st_ctime_ns")
        if any(getattr(before, field) != getattr(after, field) for field in stable):
            raise ScreenDriverEvidenceError("trusted executable changed during capture")
    except ScreenDriverEvidenceError:
        raise
    except OSError as error:
        raise ScreenDriverEvidenceError("trusted executable could not be opened for capture") from error
    finally:
        if descriptor >= 0:
            os.close(descriptor)
    if not isinstance(result, CaptureCommandResult):
        raise ScreenDriverEvidenceError("capture runner returned an invalid result")
    if isinstance(result.returncode, bool) or not isinstance(result.returncode, int):
        raise ScreenDriverEvidenceError("capture runner returncode must be an integer")
    if result.returncode != 0:
        raise ScreenDriverEvidenceError("capture runner exited nonzero")
    if not isinstance(result.stdout, bytes) or not isinstance(result.stderr, bytes):
        raise ScreenDriverEvidenceError("capture runner output must be bytes")
    return result


def identify_trusted_invocation(
    invocation_id: str,
    role: str,
    argv: Sequence[str],
    *,
    capture_context_sha256: str,
) -> TrustedInvocation:
    """Hash a stable, regular, executable file without invoking it."""

    if isinstance(argv, (str, bytes)) or not isinstance(argv, Sequence) or not argv:
        raise ScreenDriverEvidenceError("argv must be a non-empty sequence")
    executable = _canonical_absolute_path(argv[0], "argv[0]")
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    descriptor = -1
    try:
        descriptor = os.open(executable, flags)
        before = os.fstat(descriptor)
        if not stat.S_ISREG(before.st_mode) or not (before.st_mode & 0o111):
            raise ScreenDriverEvidenceError("trusted executable is not a regular executable file")
        digest = hashlib.sha256()
        while True:
            chunk = os.read(descriptor, 1024 * 1024)
            if not chunk:
                break
            digest.update(chunk)
        after = os.fstat(descriptor)
        stable = ("st_dev", "st_ino", "st_mode", "st_size", "st_mtime_ns", "st_ctime_ns")
        if any(getattr(before, field) != getattr(after, field) for field in stable):
            raise ScreenDriverEvidenceError("trusted executable changed while hashing")
    except ScreenDriverEvidenceError:
        raise
    except OSError as error:
        raise ScreenDriverEvidenceError("trusted executable could not be identified") from error
    finally:
        if descriptor >= 0:
            os.close(descriptor)
    return TrustedInvocation(
        invocation_id=invocation_id,
        role=role,
        executable_path=executable,
        executable_sha256=digest.hexdigest(),
        argv=tuple(argv),
        capture_context_sha256=capture_context_sha256,
    )


def capture_context_sha256(
    binding: DriverBinding,
    phase_variant: PhaseVariant,
    capture_nonce: str,
) -> str:
    if not isinstance(binding, DriverBinding) or not isinstance(
        phase_variant, PhaseVariant
    ):
        raise ScreenDriverEvidenceError("capture context requires binding and phase variant")
    if not isinstance(capture_nonce, str) or _NONCE_RE.fullmatch(capture_nonce) is None:
        raise ScreenDriverEvidenceError("capture context requires a 256-bit nonce")
    return _digest(
        {
            "binding": binding.as_dict(),
            "phase_variant": phase_variant.as_dict(),
            "capture_nonce": capture_nonce,
        }
    )


@dataclasses.dataclass(frozen=True, slots=True)
class MacOSAuditIdentity:
    audit_session_id: int
    audit_uid: int
    effective_uid: int
    real_uid: int
    effective_gid: int
    real_gid: int
    process_id: int
    audit_token_sha256: str
    signing_identifier: str
    team_identifier: str
    executable_path: str
    executable_sha256: str
    screen_recording_authorized: bool
    accessibility_authorized: bool

    def __post_init__(self) -> None:
        _positive_int(self.audit_session_id, "audit_session_id")
        for field in ("audit_uid", "effective_uid", "real_uid", "effective_gid", "real_gid"):
            _nonnegative_int(getattr(self, field), field)
        _positive_int(self.process_id, "audit process_id")
        _sha256(self.audit_token_sha256, "audit_token_sha256")
        _bounded_text(self.signing_identifier, "signing_identifier")
        _bounded_text(self.team_identifier, "team_identifier")
        _canonical_absolute_path(self.executable_path, "audit executable_path")
        _sha256(self.executable_sha256, "audit executable_sha256")
        if not isinstance(self.screen_recording_authorized, bool):
            raise ScreenDriverEvidenceError("screen recording authorization must be boolean")
        if not isinstance(self.accessibility_authorized, bool):
            raise ScreenDriverEvidenceError("accessibility authorization must be boolean")

    def as_dict(self) -> dict[str, Any]:
        return dataclasses.asdict(self)

    @classmethod
    def from_mapping(cls, value: Any) -> "MacOSAuditIdentity":
        value = _exact_fields(value, _AUDIT_FIELDS, "macOS audit identity")
        return cls(**{field: value[field] for field in _AUDIT_FIELDS})


@dataclasses.dataclass(frozen=True, slots=True)
class WindowIdentity:
    window_id: int
    owner_process_id: int
    owner_process_start_abstime: int
    owner_bundle_id: str
    owner_name: str
    onscreen: bool
    frontmost: bool
    visible: bool
    layer: int
    alpha: float
    display_id: int
    bounds_x: float
    bounds_y: float
    bounds_width: float
    bounds_height: float
    backing_scale_factor: float

    def __post_init__(self) -> None:
        _positive_int(self.window_id, "window_id")
        _positive_int(self.owner_process_id, "window owner_process_id")
        _positive_int(
            self.owner_process_start_abstime, "window owner_process_start_abstime"
        )
        _bounded_text(self.owner_bundle_id, "window owner_bundle_id")
        _bounded_text(self.owner_name, "window owner_name")
        for field in ("onscreen", "frontmost", "visible"):
            if not isinstance(getattr(self, field), bool):
                raise ScreenDriverEvidenceError(f"window {field} must be boolean")
        _nonnegative_int(self.layer, "window layer")
        alpha = _finite(self.alpha, "window alpha")
        if alpha < 0.0 or alpha > 1.0:
            raise ScreenDriverEvidenceError("window alpha must be between zero and one")
        _positive_int(self.display_id, "window display_id")
        _finite(self.bounds_x, "window bounds_x")
        _finite(self.bounds_y, "window bounds_y")
        _finite(self.bounds_width, "window bounds_width", positive=True)
        _finite(self.bounds_height, "window bounds_height", positive=True)
        _finite(self.backing_scale_factor, "window backing_scale_factor", positive=True)

    def as_dict(self) -> dict[str, Any]:
        return dataclasses.asdict(self)

    @classmethod
    def from_mapping(cls, value: Any) -> "WindowIdentity":
        value = _exact_fields(value, _WINDOW_FIELDS, "window identity")
        return cls(**{field: value[field] for field in _WINDOW_FIELDS})


@dataclasses.dataclass(frozen=True, slots=True)
class InputDriverReceipt:
    receipt_id: str
    invocation_id: str
    audit_session_id: int
    audit_token_sha256: str
    target_process_id: int
    target_process_start_abstime: int
    target_window_id: int
    event_tap_location: str
    posted_by_harness: bool
    started_monotonic_ns: int
    ended_monotonic_ns: int
    event_count: int
    event_sequence_sha256: str
    artifact_id: str

    def __post_init__(self) -> None:
        _identifier(self.receipt_id, "input receipt_id")
        _identifier(self.invocation_id, "input invocation_id")
        _positive_int(self.audit_session_id, "input audit_session_id")
        _sha256(self.audit_token_sha256, "input audit_token_sha256")
        _positive_int(self.target_process_id, "input target_process_id")
        _positive_int(
            self.target_process_start_abstime, "input target_process_start_abstime"
        )
        _positive_int(self.target_window_id, "input target_window_id")
        if self.event_tap_location != "cghid":
            raise ScreenDriverEvidenceError("input event tap must be cghid")
        if not isinstance(self.posted_by_harness, bool):
            raise ScreenDriverEvidenceError("posted_by_harness must be boolean")
        _positive_int(self.started_monotonic_ns, "input start clock")
        _positive_int(self.ended_monotonic_ns, "input end clock")
        if self.ended_monotonic_ns < self.started_monotonic_ns:
            raise ScreenDriverEvidenceError("input receipt clocks run backwards")
        _positive_int(self.event_count, "input event_count")
        _sha256(self.event_sequence_sha256, "input event_sequence_sha256")
        _identifier(self.artifact_id, "input artifact_id")

    def as_dict(self) -> dict[str, Any]:
        return dataclasses.asdict(self)

    @classmethod
    def from_mapping(cls, value: Any) -> "InputDriverReceipt":
        value = _exact_fields(value, _INPUT_RECEIPT_FIELDS, "input driver receipt")
        return cls(**{field: value[field] for field in _INPUT_RECEIPT_FIELDS})


@dataclasses.dataclass(frozen=True, slots=True)
class ArtifactRecord:
    artifact_id: str
    kind: str
    sha256: str
    byte_length: int
    media_type: str
    producer_invocation_id: str
    producer_receipt_id: str
    capture_started_monotonic_ns: int
    capture_ended_monotonic_ns: int

    def __post_init__(self) -> None:
        _identifier(self.artifact_id, "artifact_id")
        _identifier(self.kind, "artifact kind")
        _sha256(self.sha256, "artifact sha256")
        _positive_int(self.byte_length, "artifact byte_length")
        _bounded_text(self.media_type, "artifact media_type")
        _identifier(self.producer_invocation_id, "artifact producer_invocation_id")
        _identifier(self.producer_receipt_id, "artifact producer_receipt_id")
        _positive_int(
            self.capture_started_monotonic_ns, "artifact capture start clock"
        )
        _positive_int(self.capture_ended_monotonic_ns, "artifact capture end clock")
        if self.capture_ended_monotonic_ns < self.capture_started_monotonic_ns:
            raise ScreenDriverEvidenceError("artifact capture clocks run backwards")

    def as_dict(self) -> dict[str, Any]:
        return dataclasses.asdict(self)

    @classmethod
    def from_mapping(cls, value: Any) -> "ArtifactRecord":
        value = _exact_fields(value, _ARTIFACT_FIELDS, "artifact record")
        return cls(**{field: value[field] for field in _ARTIFACT_FIELDS})


@dataclasses.dataclass(frozen=True, slots=True)
class ValidatedCaptureReceipt:
    binding: DriverBinding
    asset: AssetFileIdentity
    capture_nonce: str
    transcript_sha256: str
    first_monotonic_ns: int
    last_monotonic_ns: int
    gesture_ids: tuple[int, int]
    artifact_sha256: tuple[tuple[str, str], ...]
    harness_trust_boundary: str = TRUST_BOUNDARY


def make_artifact_record(
    artifact_id: str,
    kind: str,
    payload: bytes,
    *,
    producer_invocation_id: str,
    producer_receipt_id: str,
    capture_started_monotonic_ns: int,
    capture_ended_monotonic_ns: int,
) -> ArtifactRecord:
    if kind not in set().union(*PHASE_ARTIFACT_KINDS.values()):
        raise ScreenDriverEvidenceError("artifact kind is not part of the capture schema")
    if not isinstance(payload, bytes) or not payload:
        raise ScreenDriverEvidenceError("artifact payload must be non-empty bytes")
    return ArtifactRecord(
        artifact_id=artifact_id,
        kind=kind,
        sha256=hashlib.sha256(payload).hexdigest(),
        byte_length=len(payload),
        media_type=_ARTIFACT_MEDIA_TYPES[kind],
        producer_invocation_id=producer_invocation_id,
        producer_receipt_id=producer_receipt_id,
        capture_started_monotonic_ns=capture_started_monotonic_ns,
        capture_ended_monotonic_ns=capture_ended_monotonic_ns,
    )


def transcript_sha256(
    events: Sequence[Mapping[str, Any]],
    artifacts: Sequence[Mapping[str, Any]],
) -> str:
    if isinstance(events, (str, bytes)) or not isinstance(events, Sequence):
        raise ScreenDriverEvidenceError("events must be an array")
    if isinstance(artifacts, (str, bytes)) or not isinstance(artifacts, Sequence):
        raise ScreenDriverEvidenceError("artifacts must be an array")
    return _digest({"events": list(events), "artifacts": list(artifacts)})


def input_event_sha256(events: Sequence[Mapping[str, Any]]) -> str:
    relevant = [
        event
        for event in events
        if isinstance(event, Mapping)
        and event.get("event")
        in {
            "open_shortcut_key_down",
            "open_shortcut_key_up",
            "file_dialog_shown",
            "file_dialog_path_selected",
            "file_dialog_accepted",
            "warm_open_action",
            "pointer_down",
            "pointer_move",
            "pointer_up",
        }
    ]
    return _digest(relevant)


def make_window_audit_payload(
    binding: DriverBinding,
    capture_nonce: str,
    audit: MacOSAuditIdentity,
    window: WindowIdentity,
) -> bytes:
    return _canonical_json_bytes(
        {
            "schema": AUDIT_ARTIFACT_SCHEMA,
            "binding": binding.as_dict(),
            "capture_nonce": capture_nonce,
            "macos_audit": audit.as_dict(),
            "window": window.as_dict(),
        }
    )


def make_input_trace_payload(
    binding: DriverBinding,
    capture_nonce: str,
    receipt: InputDriverReceipt,
    events: Sequence[Mapping[str, Any]],
) -> bytes:
    input_events = [
        dict(event)
        for event in events
        if event.get("event")
        in {
            "open_shortcut_key_down",
            "open_shortcut_key_up",
            "file_dialog_shown",
            "file_dialog_path_selected",
            "file_dialog_accepted",
            "warm_open_action",
            "pointer_down",
            "pointer_move",
            "pointer_up",
        }
    ]
    return _canonical_json_bytes(
        {
            "schema": INPUT_TRACE_SCHEMA,
            "binding": binding.as_dict(),
            "capture_nonce": capture_nonce,
            "input_driver_receipt": receipt.as_dict(),
            "events": input_events,
        }
    )


def make_initial_open_payload(
    binding: DriverBinding,
    capture_nonce: str,
    asset: AssetFileIdentity,
    initial_open_event: Mapping[str, Any],
) -> bytes:
    return _canonical_json_bytes(
        {
            "schema": INITIAL_OPEN_SCHEMA,
            "binding": binding.as_dict(),
            "capture_nonce": capture_nonce,
            "asset": asset.as_dict(),
            "event": dict(initial_open_event),
        }
    )


def make_dialog_acceptance_payload(
    binding: DriverBinding,
    capture_nonce: str,
    asset: AssetFileIdentity,
    window: WindowIdentity,
    events: Sequence[Mapping[str, Any]],
) -> bytes:
    dialog_events = [
        dict(event)
        for event in events
        if event.get("event")
        in {
            "open_shortcut_key_down",
            "open_shortcut_key_up",
            "file_dialog_shown",
            "file_dialog_path_selected",
            "file_dialog_accepted",
            "warm_open_action",
        }
    ]
    return _canonical_json_bytes(
        {
            "schema": DIALOG_ACCEPTANCE_SCHEMA,
            "binding": binding.as_dict(),
            "capture_nonce": capture_nonce,
            "asset": asset.as_dict(),
            "window": window.as_dict(),
            "events": dialog_events,
        }
    )


def make_warm_source_payload(
    native_events: Sequence[Mapping[str, Any]],
) -> bytes:
    """Serialize a complete canonical v2 stream containing one event batch."""

    if isinstance(native_events, (str, bytes)) or not isinstance(
        native_events, Sequence
    ) or not native_events:
        raise ScreenDriverEvidenceError("native telemetry requires non-empty events")
    raw_events = [dict(event) for event in native_events]
    identity = {
        field: raw_events[0][field]
        for field in (
            "run_id",
            "process_id",
            "process_start_abstime",
            "asset_sha256",
            "candidate_id",
        )
    }
    count = len(raw_events)
    framed_events = []
    for index, event in enumerate(raw_events, start=1):
        framed_events.append(
            {
                "schema": event["schema"],
                "record": "event",
                "batch": 1,
                "event_sequence": index,
                "event": event["event"],
                "monotonic_ns": event["monotonic_ns"],
                "run_id": event["run_id"],
                "process_id": event["process_id"],
                "process_start_abstime": event["process_start_abstime"],
                "asset_sha256": event["asset_sha256"],
                "candidate_id": event["candidate_id"],
                "route": event["route"],
                "route_proof": event["route_proof"],
                "source_key": event["source_key"],
                "attempt": event["attempt"],
                "serial": event["serial"],
                "generation": event["generation"],
                "gesture": event["gesture"],
                "request": event["request"],
                "draw_sequence": event["draw_sequence"],
                "target_seconds": event["target_seconds"],
                "libmpv_initialized": event["libmpv_initialized"],
            }
        )
    payload_lines = [_native_json_bytes(event) + b"\n" for event in framed_events]
    payload_digest = hashlib.sha256(b"".join(payload_lines)).digest()
    chain_hasher = hashlib.sha256()
    chain_hasher.update(bytes(32))
    chain_hasher.update(payload_digest)
    chain_hasher.update(struct.pack(">QQQQ", 1, count, 1, count))
    chain = chain_hasher.hexdigest()
    records = [
        {
            "schema": NATIVE_TELEMETRY_SCHEMA,
            "record": "stream_header",
            "format_version": 2,
            **identity,
        },
        {
            "schema": NATIVE_TELEMETRY_SCHEMA,
            "record": "batch_begin",
            "batch": 1,
            "event_count": count,
            "first_sequence": 1,
            "last_sequence": count,
            "previous_chain_sha256": bytes(32).hex(),
            **identity,
        },
    ]
    prefix = b"".join(_native_json_bytes(record) + b"\n" for record in records)
    suffix_records = [
        {
            "schema": NATIVE_TELEMETRY_SCHEMA,
            "record": "batch_commit",
            "batch": 1,
            "event_count": count,
            "first_sequence": 1,
            "last_sequence": count,
            "payload_sha256": payload_digest.hex(),
            "chain_sha256": chain,
            **identity,
        },
        {
            "schema": NATIVE_TELEMETRY_SCHEMA,
            "record": "stream_commit",
            "batch_count": 1,
            "event_count": count,
            "first_sequence": 1,
            "last_sequence": count,
            "chain_sha256": chain,
            **identity,
        },
    ]
    return prefix + b"".join(payload_lines) + b"".join(
        _native_json_bytes(record) + b"\n" for record in suffix_records
    )


def make_scrub_native_telemetry_payload(
    native_events: Sequence[Mapping[str, Any]],
) -> bytes:
    return make_warm_source_payload(native_events)


def seal_capture_receipt(
    *,
    binding: DriverBinding,
    phase_variant: PhaseVariant,
    capture_nonce: str,
    asset: AssetFileIdentity,
    trusted_invocations: Sequence[TrustedInvocation],
    macos_audit: MacOSAuditIdentity,
    window: WindowIdentity,
    input_driver_receipt: InputDriverReceipt | None,
    artifacts: Sequence[ArtifactRecord],
    events: Sequence[Mapping[str, Any]],
) -> dict[str, Any]:
    """Seal already-captured data; this function does not claim authenticity."""

    if not isinstance(capture_nonce, str) or _NONCE_RE.fullmatch(capture_nonce) is None:
        raise ScreenDriverEvidenceError("capture_nonce must be 64 lowercase hex digits")
    event_values = [dict(event) for event in events]
    invocation_values = sorted(
        (invocation.as_dict() for invocation in trusted_invocations),
        key=lambda value: value["invocation_id"],
    )
    artifact_values = sorted(
        (artifact.as_dict() for artifact in artifacts),
        key=lambda value: value["artifact_id"],
    )
    return {
        "schema": RECEIPT_SCHEMA,
        "captured_by_harness": True,
        "harness_trust_boundary": TRUST_BOUNDARY,
        "binding": binding.as_dict(),
        "phase_variant": phase_variant.as_dict(),
        "capture_nonce": capture_nonce,
        "asset": asset.as_dict(),
        "trusted_invocations": invocation_values,
        "macos_audit": macos_audit.as_dict(),
        "window": window.as_dict(),
        "input_driver_receipt": (
            input_driver_receipt.as_dict()
            if input_driver_receipt is not None
            else None
        ),
        "artifacts": artifact_values,
        "events": event_values,
        "transcript_sha256": transcript_sha256(event_values, artifact_values),
    }


def _validate_expected_invocations(
    actual_raw: Any,
    expected_invocations: Sequence[TrustedInvocation],
    phase: str,
    expected_context_sha256: str,
) -> tuple[dict[str, TrustedInvocation], dict[str, TrustedInvocation]]:
    if isinstance(actual_raw, (str, bytes)) or not isinstance(actual_raw, Sequence):
        raise ScreenDriverEvidenceError("trusted_invocations must be an array")
    actual = [TrustedInvocation.from_mapping(value) for value in actual_raw]
    expected = list(expected_invocations)
    if not expected or any(not isinstance(value, TrustedInvocation) for value in expected):
        raise ScreenDriverEvidenceError("expected trusted invocations are required")
    for label, values in (("receipt", actual), ("expected", expected)):
        identifiers = [value.invocation_id for value in values]
        roles = [value.role for value in values]
        if len(set(identifiers)) != len(identifiers):
            raise ScreenDriverEvidenceError(f"{label} invocations contain duplicate IDs")
        required_roles = PHASE_INVOCATION_ROLES[phase]
        if set(roles) != required_roles or len(roles) != len(
            required_roles
        ):
            raise ScreenDriverEvidenceError(
                f"{label} invocations do not contain the exact required roles"
            )
        if identifiers != sorted(identifiers):
            raise ScreenDriverEvidenceError(f"{label} invocations are not canonically ordered")
        if any(
            value.capture_context_sha256 != expected_context_sha256
            for value in values
        ):
            raise ScreenDriverEvidenceError(
                f"{label} invocation lacks the exact nonce/run/PID/phase context commitment"
            )
    actual_by_id = {value.invocation_id: value for value in actual}
    expected_by_id = {value.invocation_id: value for value in expected}
    if actual_by_id != expected_by_id:
        raise ScreenDriverEvidenceError(
            "receipt invocation paths, executable hashes, or argv do not match trusted expectations"
        )
    return actual_by_id, {value.role: value for value in actual}


def _event_detail_fields(event_name: str) -> set[str]:
    if event_name == "macos_audit_capture":
        return {"window_id", "audit_session_id", "capture_receipt_id"}
    if event_name in {"loader_pre_capture", "loader_post_capture"}:
        return {
            "library_canonical_path",
            "loaded",
            "observation_scope",
            "target_process_id",
            "target_process_start_abstime",
            "observation_method",
            "observation_receipt_id",
        }
    if event_name == "initial_open_action":
        return {
            "action_id",
            "action_kind",
            "delivery_receipt_id",
            "asset",
            "target_process_id",
            "target_process_start_abstime",
            "process_was_already_running",
            "resulting_source_key",
            "delivery_source",
        }
    if event_name == "warm_open_action":
        return {
            "action_id",
            "prior_action_id",
            "action_kind",
            "delivery_receipt_id",
            "asset",
            "target_process_id",
            "target_process_start_abstime",
            "process_was_already_running",
            "same_process_confirmed",
            "delivery_source",
            "target_window_id",
            "accessibility_receipt_id",
            "command_key_delivery_receipt_id",
            "dialog_acceptance_receipt_id",
            "standard_key",
            "shortcut",
            "dialog_kind",
            "dialog_window_id",
            "dialog_owner_process_id",
            "dialog_owner_process_start_abstime",
            "dialog_onscreen",
            "dialog_frontmost",
            "command_key_down_monotonic_ns",
            "command_key_up_monotonic_ns",
            "dialog_shown_monotonic_ns",
            "path_selected_monotonic_ns",
            "dialog_accepted_monotonic_ns",
            "command_key_down_receipt_id",
            "command_key_up_receipt_id",
            "path_selection_receipt_id",
        }
    if event_name in {"open_shortcut_key_down", "open_shortcut_key_up"}:
        return {
            "key",
            "modifiers",
            "delivery_receipt_id",
            "target_window_id",
        }
    if event_name == "file_dialog_shown":
        return {
            "dialog_kind",
            "dialog_window_id",
            "owner_process_id",
            "owner_process_start_abstime",
            "onscreen",
            "frontmost",
            "delivery_receipt_id",
        }
    if event_name == "file_dialog_path_selected":
        return {
            "dialog_window_id",
            "asset",
            "delivery_receipt_id",
        }
    if event_name == "file_dialog_accepted":
        return {
            "dialog_window_id",
            "asset",
            "delivery_receipt_id",
            "target_process_id",
            "target_process_start_abstime",
        }
    if event_name == "warm_open_source_observed":
        return {
            "source_key",
            "caused_by_action_id",
            "telemetry_event",
            "asset_sha256",
            "target_process_id",
            "target_process_start_abstime",
            "telemetry_receipt_id",
            "open_requested_monotonic_ns",
            "native_selected_monotonic_ns",
            "first_frame_drawn_monotonic_ns",
        }
    if event_name == "fallback_route_selected":
        return {
            "source_key",
            "telemetry_event",
            "asset_sha256",
            "target_process_id",
            "target_process_start_abstime",
            "route_proof",
            "libmpv_initialized",
            "telemetry_receipt_id",
        }
    if event_name in {"scrub_telemetry_started", "scrub_telemetry_completed"}:
        return {"telemetry_receipt_id"}
    if event_name in {"steady_playback_started", "steady_playback_completed"}:
        return {"telemetry_receipt_id"}
    if event_name == "steady_playback_sample":
        return {
            "telemetry_receipt_id",
            "sample_index",
            "source_key",
            "draw_sequence",
            "position_seconds",
        }
    if event_name in {"pointer_down", "pointer_move", "pointer_up"}:
        return {
            "gesture_id",
            "pointer_id",
            "normalized_x",
            "normalized_y",
            "delivery_receipt_id",
            "window_id",
            "planned_offset_ns",
        }
    if event_name == "screenshot_capture":
        return {
            "window_id",
            "owner_process_id",
            "owner_process_start_abstime",
            "capture_receipt_id",
        }
    if event_name == "system_audio_capture":
        return {
            "capture_scope",
            "capture_api",
            "tap_process_id",
            "tap_receipt_id",
            "output_device_uid",
            "output_route_active",
            "target_process_id",
            "target_process_start_abstime",
            "audit_token_sha256",
            "audio_active",
            "audible",
            "sample_rate_hz",
            "channels",
            "captured_frames",
            "non_silent_frames",
            "peak_dbfs",
            "capture_receipt_id",
        }
    raise ScreenDriverEvidenceError(f"unknown transcript event {event_name!r}")


def _parse_events(
    raw_events: Any,
    *,
    binding: DriverBinding,
    phase: str,
    capture_nonce: str,
    asset: AssetFileIdentity,
    invocations_by_id: Mapping[str, TrustedInvocation],
    invocations_by_role: Mapping[str, TrustedInvocation],
    audit: MacOSAuditIdentity,
    window: WindowIdentity,
    input_receipt: InputDriverReceipt | None,
    artifacts_by_id: Mapping[str, ArtifactRecord],
    expected_loader_library_path: str,
) -> tuple[list[Mapping[str, Any]], tuple[int, int]]:
    if isinstance(raw_events, (str, bytes)) or not isinstance(raw_events, Sequence):
        raise ScreenDriverEvidenceError("events must be an array")
    events: list[Mapping[str, Any]] = []
    prior_clock = 0
    delivery_ids: set[str] = set()
    action_ids: set[str] = set()

    expected_artifact_kind = {
        "macos_audit_capture": "window_audit",
        "loader_pre_capture": "loader_pre",
        "loader_post_capture": "loader_post",
        "initial_open_action": "initial_open_receipt",
        "warm_open_action": "dialog_acceptance",
        "open_shortcut_key_down": "dialog_acceptance",
        "open_shortcut_key_up": "dialog_acceptance",
        "file_dialog_shown": "dialog_acceptance",
        "file_dialog_path_selected": "dialog_acceptance",
        "file_dialog_accepted": "dialog_acceptance",
        "warm_open_source_observed": "warm_source_telemetry",
        "fallback_route_selected": "fallback_route_telemetry",
        "scrub_telemetry_started": "scrub_native_telemetry",
        "scrub_telemetry_completed": "scrub_native_telemetry",
        "steady_playback_started": "steady_native_telemetry",
        "steady_playback_sample": "steady_native_telemetry",
        "steady_playback_completed": "steady_native_telemetry",
        "pointer_down": "input_trace",
        "pointer_move": "input_trace",
        "pointer_up": "input_trace",
        "screenshot_capture": "screenshot",
        "system_audio_capture": "system_audio",
    }

    for index, raw_event in enumerate(raw_events):
        event = _exact_fields(raw_event, _EVENT_FIELDS, f"event {index}")
        if event["sequence"] != index:
            raise ScreenDriverEvidenceError("event sequence must be contiguous from zero")
        clock = _positive_int(event["monotonic_ns"], f"event {index} clock")
        if clock <= prior_clock:
            raise ScreenDriverEvidenceError("event clocks must be strictly increasing")
        prior_clock = clock
        if DriverBinding.from_mapping(event["binding"]) != binding:
            raise ScreenDriverEvidenceError("event binding does not match the driver binding")
        if event["capture_nonce"] != capture_nonce:
            raise ScreenDriverEvidenceError("event capture nonce does not match")
        name = _bounded_text(event["event"], f"event {index} name")
        expected_role = _ACTOR_ROLES.get(name)
        if expected_role is None:
            raise ScreenDriverEvidenceError(f"unknown transcript event {name!r}")
        actor_id = _identifier(event["actor_invocation_id"], "event actor invocation")
        invocation = invocations_by_id.get(actor_id)
        if invocation is None or invocation.role != expected_role:
            raise ScreenDriverEvidenceError(f"{name} was not emitted by its trusted tool role")
        artifact_id = _identifier(event["artifact_id"], "event artifact_id")
        artifact = artifacts_by_id.get(artifact_id)
        if artifact is None or artifact.kind != expected_artifact_kind[name]:
            raise ScreenDriverEvidenceError(f"{name} has the wrong or missing artifact ID")
        details = _exact_fields(
            event["details"], _event_detail_fields(name), f"{name} details"
        )

        if name == "macos_audit_capture":
            if (
                details["window_id"] != window.window_id
                or details["audit_session_id"] != audit.audit_session_id
            ):
                raise ScreenDriverEvidenceError("audit event does not identify the approved window")
            _identifier(details["capture_receipt_id"], "audit capture receipt")
        elif name in {"loader_pre_capture", "loader_post_capture"}:
            expected_loaded = name == "loader_post_capture"
            if (
                details["library_canonical_path"] != expected_loader_library_path
                or details["loaded"] is not expected_loaded
                or details["observation_scope"] != "process"
                or details["target_process_id"] != binding.process_id
                or details["target_process_start_abstime"]
                != binding.process_start_abstime
                or details["observation_method"]
                not in {"dyld_image_list", "vmmap", "lsof"}
            ):
                raise ScreenDriverEvidenceError("loader event is not exact process-scoped proof")
            _identifier(details["observation_receipt_id"], "loader observation receipt")
        elif name in {"initial_open_action", "warm_open_action"}:
            if AssetFileIdentity.from_mapping(details["asset"]) != asset:
                raise ScreenDriverEvidenceError("open action changed the canonical asset inode")
            if (
                details["action_kind"] != "open_asset"
                or details["target_process_id"] != binding.process_id
                or details["target_process_start_abstime"]
                != binding.process_start_abstime
            ):
                raise ScreenDriverEvidenceError("open action is not bound to the WAM process")
            action_id = _identifier(details["action_id"], "open action_id")
            delivery_id = _identifier(
                details["delivery_receipt_id"], "open delivery_receipt_id"
            )
            if action_id in action_ids or delivery_id in delivery_ids:
                raise ScreenDriverEvidenceError("open actions contain duplicate receipt IDs")
            action_ids.add(action_id)
            delivery_ids.add(delivery_id)
            if name == "initial_open_action":
                if (
                    details["delivery_source"] != "launchservices_completion"
                    or details["process_was_already_running"] is not True
                ):
                    raise ScreenDriverEvidenceError(
                        "initial asset delivery must target the already-audited WAM process"
                    )
                _positive_int(details["resulting_source_key"], "initial source key")
            elif input_receipt is None or (
                details["delivery_source"] != "screen_file_dialog_acceptance"
                or
                details["process_was_already_running"] is not True
                or details["same_process_confirmed"] is not True
                or details["target_window_id"] != window.window_id
                or details["accessibility_receipt_id"] != input_receipt.receipt_id
                or details["standard_key"] != "StandardKey.Open"
                or details["shortcut"] != "Meta+O"
                or details["dialog_kind"] != "native_file_dialog"
                or not isinstance(details["dialog_window_id"], int)
                or details["dialog_window_id"] <= 0
                or details["dialog_owner_process_id"] != binding.process_id
                or details["dialog_owner_process_start_abstime"]
                != binding.process_start_abstime
                or details["dialog_onscreen"] is not True
                or details["dialog_frontmost"] is not True
                or not (
                    _positive_int(
                        details["command_key_down_monotonic_ns"],
                        "Cmd+O key-down clock",
                    )
                    < _positive_int(
                        details["command_key_up_monotonic_ns"],
                        "Cmd+O key-up clock",
                    )
                    < _positive_int(
                        details["dialog_shown_monotonic_ns"],
                        "file dialog shown clock",
                    )
                    < _positive_int(
                        details["path_selected_monotonic_ns"],
                        "file path selected clock",
                    )
                    < _positive_int(
                        details["dialog_accepted_monotonic_ns"],
                        "file dialog accepted clock",
                    )
                    < clock
                )
            ):
                raise ScreenDriverEvidenceError(
                    "warm open must be a delivered second action to the same live PID"
                )
            if name == "warm_open_action":
                for field in (
                    "command_key_delivery_receipt_id",
                ):
                    receipt_id = _identifier(details[field], f"warm open {field}")
                    if receipt_id in delivery_ids:
                        raise ScreenDriverEvidenceError(
                            "warm open contains duplicate accessibility receipt IDs"
                        )
                    delivery_ids.add(receipt_id)
        elif name == "warm_open_source_observed":
            if (
                details["source_key"] != binding.source_key
                or details["telemetry_event"] != "warm_open_to_first_frame"
                or details["asset_sha256"] != binding.asset_sha256
                or details["target_process_id"] != binding.process_id
                or details["target_process_start_abstime"]
                != binding.process_start_abstime
                or not (
                    _positive_int(
                        details["open_requested_monotonic_ns"],
                        "warm open-requested clock",
                    )
                    < _positive_int(
                        details["native_selected_monotonic_ns"],
                        "warm native-selected clock",
                    )
                    < _positive_int(
                        details["first_frame_drawn_monotonic_ns"],
                        "warm first-frame clock",
                    )
                    == clock
                )
            ):
                raise ScreenDriverEvidenceError(
                    "warm source telemetry is not bound to the same process and asset"
                )
            _identifier(details["telemetry_receipt_id"], "warm telemetry receipt")
        elif name == "fallback_route_selected":
            if (
                details["source_key"] != binding.source_key
                or details["telemetry_event"] != "fallback_selected"
                or details["asset_sha256"] != binding.asset_sha256
                or details["target_process_id"] != binding.process_id
                or details["target_process_start_abstime"]
                != binding.process_start_abstime
                or details["route_proof"] is not True
                or details["libmpv_initialized"] is not True
            ):
                raise ScreenDriverEvidenceError(
                    "fallback route event is not exact WAM route proof"
                )
            _identifier(details["telemetry_receipt_id"], "fallback telemetry receipt")
        elif name in {"open_shortcut_key_down", "open_shortcut_key_up"}:
            if (
                details["key"] != "O"
                or details["modifiers"] != ["command"]
                or details["target_window_id"] != window.window_id
            ):
                raise ScreenDriverEvidenceError("open shortcut delivery is not exact Cmd+O")
            receipt_id = _identifier(
                details["delivery_receipt_id"], "shortcut delivery receipt"
            )
            if receipt_id in delivery_ids:
                raise ScreenDriverEvidenceError("shortcut receipt ID is duplicated")
            delivery_ids.add(receipt_id)
        elif name == "file_dialog_shown":
            if (
                details["dialog_kind"] != "native_file_dialog"
                or isinstance(details["dialog_window_id"], bool)
                or not isinstance(details["dialog_window_id"], int)
                or details["dialog_window_id"] <= 0
                or details["owner_process_id"] != binding.process_id
                or details["owner_process_start_abstime"]
                != binding.process_start_abstime
                or details["onscreen"] is not True
                or details["frontmost"] is not True
            ):
                raise ScreenDriverEvidenceError("native file dialog identity is not proven")
            receipt_id = _identifier(details["delivery_receipt_id"], "dialog shown receipt")
            if receipt_id in delivery_ids:
                raise ScreenDriverEvidenceError("dialog receipt ID is duplicated")
            delivery_ids.add(receipt_id)
        elif name in {"file_dialog_path_selected", "file_dialog_accepted"}:
            if AssetFileIdentity.from_mapping(details["asset"]) != asset:
                raise ScreenDriverEvidenceError("file dialog selected a different asset inode")
            _positive_int(details["dialog_window_id"], "dialog window_id")
            if name == "file_dialog_accepted" and (
                details["target_process_id"] != binding.process_id
                or details["target_process_start_abstime"]
                != binding.process_start_abstime
            ):
                raise ScreenDriverEvidenceError("dialog acceptance targets a different process")
            receipt_id = _identifier(details["delivery_receipt_id"], "dialog delivery receipt")
            if receipt_id in delivery_ids:
                raise ScreenDriverEvidenceError("dialog receipt ID is duplicated")
            delivery_ids.add(receipt_id)
        elif name in {"scrub_telemetry_started", "scrub_telemetry_completed"}:
            _identifier(details["telemetry_receipt_id"], "scrub telemetry receipt")
        elif name in {"steady_playback_started", "steady_playback_completed"}:
            _identifier(details["telemetry_receipt_id"], "steady telemetry receipt")
        elif name == "steady_playback_sample":
            _identifier(details["telemetry_receipt_id"], "steady telemetry receipt")
            if (
                _nonnegative_int(details["sample_index"], "steady sample index")
                >= STEADY_SAMPLE_COUNT
                or details["source_key"] != binding.source_key
                or _positive_int(details["draw_sequence"], "steady draw sequence") <= 0
                or _finite(
                    details["position_seconds"], "steady position seconds"
                )
                < 0.0
            ):
                raise ScreenDriverEvidenceError("steady playback sample is invalid")
        elif name in {"pointer_down", "pointer_move", "pointer_up"}:
            _positive_int(details["gesture_id"], "pointer gesture_id")
            _positive_int(details["pointer_id"], "pointer pointer_id")
            for axis in ("normalized_x", "normalized_y"):
                coordinate = _finite(details[axis], f"pointer {axis}")
                if coordinate < 0.0 or coordinate > 1.0:
                    raise ScreenDriverEvidenceError("pointer coordinate is outside the window")
            _nonnegative_int(details["planned_offset_ns"], "pointer planned_offset_ns")
            if details["window_id"] != window.window_id:
                raise ScreenDriverEvidenceError("pointer event targets a different window")
            delivery_id = _identifier(
                details["delivery_receipt_id"], "pointer delivery_receipt_id"
            )
            if delivery_id in delivery_ids:
                raise ScreenDriverEvidenceError("input delivery receipt IDs are not unique")
            delivery_ids.add(delivery_id)
        elif name == "screenshot_capture":
            if (
                details["window_id"] != window.window_id
                or details["owner_process_id"] != binding.process_id
                or details["owner_process_start_abstime"]
                != binding.process_start_abstime
            ):
                raise ScreenDriverEvidenceError("screenshot targets a different window owner")
            _identifier(details["capture_receipt_id"], "screenshot capture receipt")
        elif name == "system_audio_capture":
            peak = _finite(details["peak_dbfs"], "audio peak_dbfs")
            frames = _positive_int(details["captured_frames"], "audio captured_frames")
            non_silent = _positive_int(
                details["non_silent_frames"], "audio non_silent_frames"
            )
            if (
                details["capture_scope"] != "process"
                or details["capture_api"] != "AudioHardwareCreateProcessTap"
                or details["tap_process_id"] != binding.process_id
                or _identifier(details["tap_receipt_id"], "process tap receipt")
                == details["capture_receipt_id"]
                or not isinstance(details["output_device_uid"], str)
                or not details["output_device_uid"]
                or details["output_route_active"] is not True
                or details["target_process_id"] != binding.process_id
                or details["target_process_start_abstime"]
                != binding.process_start_abstime
                or details["audit_token_sha256"] != audit.audit_token_sha256
                or details["audio_active"] is not True
                or details["audible"] is not True
                or _positive_int(details["sample_rate_hz"], "audio sample_rate_hz") <= 0
                or _positive_int(details["channels"], "audio channels") <= 0
                or non_silent > frames
                or not -160.0 <= peak <= 0.0
            ):
                raise ScreenDriverEvidenceError(
                    "audio event is not active, audible, process-scoped capture proof"
                )
            _identifier(details["capture_receipt_id"], "audio capture receipt")
        events.append(event)

    # Each phase has an exact grammar.  Native phases cannot contain any
    # fallback-loader event because there is no branch which accepts one.
    cursor = 0

    def expect(name: str) -> Mapping[str, Any]:
        nonlocal cursor
        if cursor >= len(events) or events[cursor]["event"] != name:
            raise ScreenDriverEvidenceError(f"transcript expected {name} at event {cursor}")
        value = events[cursor]
        cursor += 1
        return value

    expect("macos_audit_capture")
    loader_pre: Mapping[str, Any] | None = None
    if phase == "fallback_control":
        loader_pre = expect("loader_pre_capture")
    initial = expect("initial_open_action")
    initial_source_key = initial["details"]["resulting_source_key"]
    gesture_ids: list[int] = []
    input_events: list[Mapping[str, Any]] = []

    if phase == "startup":
        key_down = expect("open_shortcut_key_down")
        key_up = expect("open_shortcut_key_up")
        dialog_shown = expect("file_dialog_shown")
        path_selected = expect("file_dialog_path_selected")
        dialog_accepted = expect("file_dialog_accepted")
        warm = expect("warm_open_action")
        warm_source = expect("warm_open_source_observed")
        if warm["details"]["prior_action_id"] != initial["details"]["action_id"]:
            raise ScreenDriverEvidenceError(
                "warm open does not reference the initial delivered action"
            )
        if warm_source["details"]["caused_by_action_id"] != warm["details"]["action_id"]:
            raise ScreenDriverEvidenceError(
                "warm source telemetry is not caused by dialog acceptance"
            )
        if initial_source_key == binding.source_key:
            raise ScreenDriverEvidenceError("warm open did not create a distinct source key")
        raw_open_events = [
            key_down,
            key_up,
            dialog_shown,
            path_selected,
            dialog_accepted,
        ]
        warm_details = warm["details"]
        if (
            warm_details["command_key_down_monotonic_ns"] != key_down["monotonic_ns"]
            or warm_details["command_key_up_monotonic_ns"] != key_up["monotonic_ns"]
            or warm_details["dialog_shown_monotonic_ns"]
            != dialog_shown["monotonic_ns"]
            or warm_details["path_selected_monotonic_ns"]
            != path_selected["monotonic_ns"]
            or warm_details["dialog_accepted_monotonic_ns"]
            != dialog_accepted["monotonic_ns"]
            or warm_details["command_key_down_receipt_id"]
            != key_down["details"]["delivery_receipt_id"]
            or warm_details["command_key_up_receipt_id"]
            != key_up["details"]["delivery_receipt_id"]
            or warm_details["path_selection_receipt_id"]
            != path_selected["details"]["delivery_receipt_id"]
            or warm_details["dialog_acceptance_receipt_id"]
            != dialog_accepted["details"]["delivery_receipt_id"]
            or warm_details["dialog_window_id"]
            != dialog_shown["details"]["dialog_window_id"]
            or path_selected["details"]["dialog_window_id"]
            != dialog_shown["details"]["dialog_window_id"]
            or dialog_accepted["details"]["dialog_window_id"]
            != dialog_shown["details"]["dialog_window_id"]
        ):
            raise ScreenDriverEvidenceError(
                "warm open summary does not match raw key/dialog deliveries"
            )
        input_events = [*raw_open_events, warm]
    elif phase == "steady":
        if initial_source_key != binding.source_key:
            raise ScreenDriverEvidenceError("steady receipt is not bound to its initial source")
        steady_start = expect("steady_playback_started")
        steady_samples = [expect("steady_playback_sample") for _ in range(STEADY_SAMPLE_COUNT)]
        steady_end = expect("steady_playback_completed")
        receipt_id = steady_start["details"]["telemetry_receipt_id"]
        if (
            steady_end["details"]["telemetry_receipt_id"] != receipt_id
            or steady_samples[0]["monotonic_ns"] - steady_start["monotonic_ns"]
            != STEADY_SAMPLE_PERIOD_NS
            or steady_end["monotonic_ns"] - steady_start["monotonic_ns"]
            - 1
            != STEADY_SAMPLE_DURATION_NS + STEADY_SAMPLE_PERIOD_NS
        ):
            raise ScreenDriverEvidenceError("steady sample brackets are not exact")
        prior_position = -1.0
        prior_draw = 0
        for index, sample in enumerate(steady_samples):
            details = sample["details"]
            if (
                details["telemetry_receipt_id"] != receipt_id
                or details["sample_index"] != index
                or sample["monotonic_ns"]
                != steady_start["monotonic_ns"]
                + (index + 1) * STEADY_SAMPLE_PERIOD_NS
                or details["position_seconds"] <= prior_position
                or details["draw_sequence"] <= prior_draw
            ):
                raise ScreenDriverEvidenceError(
                    "steady playback is not continuously advancing"
                )
            prior_position = float(details["position_seconds"])
            prior_draw = details["draw_sequence"]
    elif phase == "scrub":
        if initial_source_key != binding.source_key:
            raise ScreenDriverEvidenceError("scrub receipt is not bound to its initial source")
        telemetry_start = expect("scrub_telemetry_started")
        pointer_events: list[Mapping[str, Any]] = []
        prior_up_clock: int | None = None
        for gesture_index in range(2):
            down = expect("pointer_down")
            gesture_id = down["details"]["gesture_id"]
            pointer_id = down["details"]["pointer_id"]
            moves = 0
            expected_start = (
                DRAG_EDGE_INSET if gesture_index == 0 else 1.0 - DRAG_EDGE_INSET
            )
            expected_finish = 1.0 - expected_start
            if (
                not math.isclose(
                    float(down["details"]["normalized_x"]),
                    expected_start,
                    rel_tol=0.0,
                    abs_tol=1e-12,
                )
                or not math.isclose(
                    float(down["details"]["normalized_y"]),
                    0.5,
                    rel_tol=0.0,
                    abs_tol=1e-12,
                )
                or down["details"]["planned_offset_ns"] != 0
                or (
                    prior_up_clock is not None
                    and abs(
                        down["monotonic_ns"] - prior_up_clock - 250_000_000
                    )
                    > DRAG_DELIVERY_TOLERANCE_NS
                )
            ):
                raise ScreenDriverEvidenceError(
                    "pointer gesture did not start at its exact endpoint"
                )
            down_clock = down["monotonic_ns"]
            pointer_events.append(down)
            while cursor < len(events) and events[cursor]["event"] == "pointer_move":
                move = expect("pointer_move")
                if (
                    move["details"]["gesture_id"] != gesture_id
                    or move["details"]["pointer_id"] != pointer_id
                ):
                    raise ScreenDriverEvidenceError(
                        "pointer move changed gesture or pointer identity"
                    )
                moves += 1
                expected_position = expected_start + (
                    (expected_finish - expected_start)
                    * moves
                    / DRAG_MOVE_COUNT_PER_LEG
                )
                expected_offset_ns = moves * DRAG_PERIOD_NS
                if (
                    not math.isclose(
                        float(move["details"]["normalized_x"]),
                        expected_position,
                        rel_tol=0.0,
                        abs_tol=1e-12,
                    )
                    or not math.isclose(
                        float(move["details"]["normalized_y"]),
                        0.5,
                        rel_tol=0.0,
                        abs_tol=1e-12,
                    )
                    or move["details"]["planned_offset_ns"] != expected_offset_ns
                    or abs(
                        (move["monotonic_ns"] - down_clock) - expected_offset_ns
                    )
                    > DRAG_DELIVERY_TOLERANCE_NS
                ):
                    raise ScreenDriverEvidenceError(
                        "pointer move missed the exact 120 Hz four-second drag schedule"
                    )
                pointer_events.append(move)
            if moves != DRAG_MOVE_COUNT_PER_LEG:
                raise ScreenDriverEvidenceError(
                    "each pointer gesture needs exactly 480 delivered moves"
                )
            up = expect("pointer_up")
            pointer_events.append(up)
            if (
                up["details"]["gesture_id"] != gesture_id
                or up["details"]["pointer_id"] != pointer_id
                or not math.isclose(
                    float(up["details"]["normalized_x"]),
                    expected_finish,
                    rel_tol=0.0,
                    abs_tol=1e-12,
                )
                or not math.isclose(
                    float(up["details"]["normalized_y"]),
                    0.5,
                    rel_tol=0.0,
                    abs_tol=1e-12,
                )
                or up["details"]["planned_offset_ns"] != DRAG_LEG_DURATION_NS
                or abs(
                    (up["monotonic_ns"] - down_clock) - DRAG_LEG_DURATION_NS
                )
                > DRAG_DELIVERY_TOLERANCE_NS
            ):
                raise ScreenDriverEvidenceError(
                    "pointer up missed the exact drag endpoint/deadline"
                )
            gesture_ids.append(gesture_id)
            prior_up_clock = up["monotonic_ns"]
            if gesture_index == 1 and gesture_ids[0] == gesture_ids[1]:
                raise ScreenDriverEvidenceError("the two pointer gestures need distinct IDs")
        telemetry_end = expect("scrub_telemetry_completed")
        if not (
            telemetry_start["monotonic_ns"] < pointer_events[0]["monotonic_ns"]
            < pointer_events[-1]["monotonic_ns"] < telemetry_end["monotonic_ns"]
        ):
            raise ScreenDriverEvidenceError(
                "native scrub telemetry does not bracket the exact input delivery"
            )
        input_events = pointer_events
    elif phase == "fallback_control":
        if initial_source_key != binding.source_key:
            raise ScreenDriverEvidenceError("fallback receipt is not bound to its initial source")
        fallback_selected = expect("fallback_route_selected")
        loader_post = expect("loader_post_capture")
        screenshot = expect("screenshot_capture")
        audio = expect("system_audio_capture")
        if loader_pre is None or loader_pre["monotonic_ns"] >= initial["monotonic_ns"]:
            raise ScreenDriverEvidenceError(
                "loader-before proof was not captured before first asset delivery"
            )
        if not (
            initial["monotonic_ns"] < fallback_selected["monotonic_ns"]
            < loader_post["monotonic_ns"]
            < screenshot["monotonic_ns"] < audio["monotonic_ns"]
        ):
            raise ScreenDriverEvidenceError("fallback capture phases are out of order")
        if (
            artifacts_by_id[screenshot["artifact_id"]].capture_started_monotonic_ns
            < loader_post["monotonic_ns"]
        ):
            raise ScreenDriverEvidenceError(
                "screenshot capture began before fallback loader proof completed"
            )

    if cursor != len(events):
        raise ScreenDriverEvidenceError("transcript contains duplicate or unexpected events")
    if phase in {"startup", "scrub"}:
        if input_receipt is None or not input_events:
            raise ScreenDriverEvidenceError("input phase has no trusted input receipt")
        if (
            input_receipt.started_monotonic_ns != input_events[0]["monotonic_ns"]
            or input_receipt.ended_monotonic_ns != input_events[-1]["monotonic_ns"]
            or input_receipt.event_count != len(input_events)
            or input_receipt.event_sequence_sha256 != _digest(input_events)
            or input_receipt.invocation_id
            != invocations_by_role["input_driver"].invocation_id
        ):
            raise ScreenDriverEvidenceError(
                "input driver receipt does not seal exact phase deliveries"
            )
    elif input_receipt is not None:
        raise ScreenDriverEvidenceError("non-input phase supplied an input driver receipt")
    return events, tuple(gesture_ids)


def _validate_png(payload: bytes, window: WindowIdentity) -> None:
    if len(payload) < 45 or payload[:8] != b"\x89PNG\r\n\x1a\n":
        raise ScreenDriverEvidenceError("screenshot artifact is not a complete PNG")
    cursor = 8
    chunks: list[tuple[bytes, bytes]] = []
    while cursor + 12 <= len(payload):
        size = struct.unpack(">I", payload[cursor : cursor + 4])[0]
        kind = payload[cursor + 4 : cursor + 8]
        start = cursor + 8
        end = start + size
        if end + 4 > len(payload):
            raise ScreenDriverEvidenceError("screenshot PNG has a truncated chunk")
        data = payload[start:end]
        expected_crc = struct.unpack(">I", payload[end : end + 4])[0]
        if zlib.crc32(kind + data) & 0xFFFFFFFF != expected_crc:
            raise ScreenDriverEvidenceError("screenshot PNG chunk CRC is invalid")
        chunks.append((kind, data))
        cursor = end + 4
        if kind == b"IEND":
            break
    if cursor != len(payload) or not chunks or chunks[-1][0] != b"IEND":
        raise ScreenDriverEvidenceError("screenshot PNG is incomplete or has trailing bytes")
    if chunks[0][0] != b"IHDR" or len(chunks[0][1]) != 13:
        raise ScreenDriverEvidenceError("screenshot PNG has no canonical IHDR")
    if sum(kind == b"IHDR" for kind, _ in chunks) != 1:
        raise ScreenDriverEvidenceError("screenshot PNG contains duplicate headers")
    width, height, bit_depth, color_type, compression, filtering, interlace = struct.unpack(
        ">IIBBBBB", chunks[0][1]
    )
    expected_width = round(window.bounds_width * window.backing_scale_factor)
    expected_height = round(window.bounds_height * window.backing_scale_factor)
    if width != expected_width or height != expected_height:
        raise ScreenDriverEvidenceError("screenshot pixels do not match the audited window bounds")
    if (
        bit_depth != 8
        or color_type not in {2, 6}
        or compression != 0
        or filtering != 0
        or interlace != 0
    ):
        raise ScreenDriverEvidenceError("screenshot PNG uses an unsupported pixel encoding")
    bytes_per_pixel = 3 if color_type == 2 else 4
    stride = width * bytes_per_pixel
    expected_bytes = height * (stride + 1)
    if expected_bytes > 128 * 1024 * 1024:
        raise ScreenDriverEvidenceError("screenshot PNG dimensions exceed the capture limit")
    compressed = b"".join(data for kind, data in chunks if kind == b"IDAT")
    if not compressed:
        raise ScreenDriverEvidenceError("screenshot PNG has no image data")
    decompressor = zlib.decompressobj()
    try:
        raw = decompressor.decompress(compressed, expected_bytes + 1)
        raw += decompressor.flush()
    except zlib.error as error:
        raise ScreenDriverEvidenceError("screenshot PNG image data is corrupt") from error
    if (
        len(raw) != expected_bytes
        or not decompressor.eof
        or decompressor.unused_data
        or decompressor.unconsumed_tail
    ):
        raise ScreenDriverEvidenceError("screenshot PNG image data has the wrong size")

    prior = bytearray(stride)
    luminance_min = 255
    luminance_max = 0
    opaque_pixels = 0
    for row_index in range(height):
        row_start = row_index * (stride + 1)
        filter_type = raw[row_start]
        encoded = raw[row_start + 1 : row_start + 1 + stride]
        decoded = bytearray(stride)
        for byte_index, encoded_byte in enumerate(encoded):
            left = decoded[byte_index - bytes_per_pixel] if byte_index >= bytes_per_pixel else 0
            above = prior[byte_index]
            upper_left = prior[byte_index - bytes_per_pixel] if byte_index >= bytes_per_pixel else 0
            if filter_type == 0:
                predictor = 0
            elif filter_type == 1:
                predictor = left
            elif filter_type == 2:
                predictor = above
            elif filter_type == 3:
                predictor = (left + above) // 2
            elif filter_type == 4:
                estimate = left + above - upper_left
                left_distance = abs(estimate - left)
                above_distance = abs(estimate - above)
                upper_left_distance = abs(estimate - upper_left)
                predictor = (
                    left
                    if left_distance <= above_distance and left_distance <= upper_left_distance
                    else above
                    if above_distance <= upper_left_distance
                    else upper_left
                )
            else:
                raise ScreenDriverEvidenceError("screenshot PNG uses an invalid row filter")
            decoded[byte_index] = (encoded_byte + predictor) & 0xFF
        if row_index % max(1, height // 128) == 0:
            for pixel in range(0, width, max(1, width // 256)):
                offset = pixel * bytes_per_pixel
                red, green, blue = decoded[offset : offset + 3]
                if bytes_per_pixel == 4:
                    alpha = decoded[offset + 3]
                    red = (red * alpha) // 255
                    green = (green * alpha) // 255
                    blue = (blue * alpha) // 255
                luminance = (54 * red + 183 * green + 19 * blue) >> 8
                luminance_min = min(luminance_min, luminance)
                luminance_max = max(luminance_max, luminance)
        if bytes_per_pixel == 4:
            opaque_pixels += sum(
                decoded[offset + 3] >= 250
                for offset in range(0, stride, bytes_per_pixel)
            )
        prior = decoded
    if bytes_per_pixel == 4 and opaque_pixels < math.ceil(width * height * 0.95):
        raise ScreenDriverEvidenceError(
            "screenshot PNG is not an opaque visible-window capture"
        )
    if luminance_max - luminance_min < 4:
        raise ScreenDriverEvidenceError(
            "screenshot PNG has no visible pixel variation for a rendered player window"
        )


def _parse_native_telemetry_jsonl(
    payload: bytes,
    binding: DriverBinding,
) -> list[Mapping[str, Any]]:
    """Validate canonical v2 framing, batch hash-chain, and terminal commit."""

    if not isinstance(payload, bytes) or not payload or len(payload) > 64 * 1024 * 1024:
        raise ScreenDriverEvidenceError("native telemetry payload size is invalid")
    if not payload.endswith(b"\n"):
        raise ScreenDriverEvidenceError("native telemetry JSONL is not newline terminated")
    try:
        text = payload.decode("utf-8")
    except UnicodeDecodeError as error:
        raise ScreenDriverEvidenceError("native telemetry is not UTF-8 JSONL") from error
    raw_lines = text.splitlines()
    if not raw_lines or len(raw_lines) > 10_000 or any(not line for line in raw_lines):
        raise ScreenDriverEvidenceError("native telemetry line count is invalid")
    records: list[Mapping[str, Any]] = []

    def reject_duplicate_pairs(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ScreenDriverEvidenceError(
                    "native telemetry contains a duplicate JSON member"
                )
            result[key] = value
        return result

    for line_number, line in enumerate(raw_lines, start=1):
        try:
            raw = json.loads(line, object_pairs_hook=reject_duplicate_pairs)
        except json.JSONDecodeError as error:
            raise ScreenDriverEvidenceError(
                f"native telemetry line {line_number} is not JSON"
            ) from error
        if any(character.isspace() for character in line):
            raise ScreenDriverEvidenceError("native telemetry JSONL is not compact")
        records.append(raw)

    identity_order = (
        "run_id",
        "process_id",
        "process_start_abstime",
        "asset_sha256",
        "candidate_id",
    )
    expected_orders = {
        "stream_header": (
            "schema",
            "record",
            "format_version",
            *identity_order,
        ),
        "batch_begin": (
            "schema",
            "record",
            "batch",
            "event_count",
            "first_sequence",
            "last_sequence",
            "previous_chain_sha256",
            *identity_order,
        ),
        "event": (
            "schema",
            "record",
            "batch",
            "event_sequence",
            "event",
            "monotonic_ns",
            *identity_order,
            "route",
            "route_proof",
            "source_key",
            "attempt",
            "serial",
            "generation",
            "gesture",
            "request",
            "draw_sequence",
            "target_seconds",
            "libmpv_initialized",
        ),
        "batch_commit": (
            "schema",
            "record",
            "batch",
            "event_count",
            "first_sequence",
            "last_sequence",
            "payload_sha256",
            "chain_sha256",
            *identity_order,
        ),
        "stream_commit": (
            "schema",
            "record",
            "batch_count",
            "event_count",
            "first_sequence",
            "last_sequence",
            "chain_sha256",
            *identity_order,
        ),
    }
    for record in records:
        order = expected_orders.get(record.get("record"))
        if order is None or tuple(record) != order:
            raise ScreenDriverEvidenceError(
                "native telemetry record is not in the exact WAM field order"
            )

    def validate_identity(record: Mapping[str, Any]) -> None:
        if (
            record["schema"] != NATIVE_TELEMETRY_SCHEMA
            or record["run_id"] != binding.run_id
            or record["process_id"] != binding.process_id
            or record["process_start_abstime"] != binding.process_start_abstime
            or record["asset_sha256"] != binding.asset_sha256
            or record["candidate_id"] != binding.candidate_id
        ):
            raise ScreenDriverEvidenceError(
                "native telemetry changed the run/PID/start/asset/candidate binding"
            )

    if len(records) < 5:
        raise ScreenDriverEvidenceError("native telemetry stream is incomplete")
    header = _exact_fields(records[0], _NATIVE_HEADER_FIELDS, "native stream header")
    validate_identity(header)
    if header["record"] != "stream_header" or header["format_version"] != 2:
        raise ScreenDriverEvidenceError("native telemetry has no v2 stream header")
    begin = _exact_fields(
        records[1], _NATIVE_BATCH_BEGIN_FIELDS, "native batch begin"
    )
    validate_identity(begin)
    count = _positive_int(begin["event_count"], "native batch event_count")
    if (
        begin["record"] != "batch_begin"
        or begin["batch"] != 1
        or begin["first_sequence"] != 1
        or begin["last_sequence"] != count
        or begin["previous_chain_sha256"] != bytes(32).hex()
        or len(records) != count + 4
    ):
        raise ScreenDriverEvidenceError("native telemetry batch metadata is invalid")
    raw_event_lines = [
        raw_lines[index].encode("utf-8") + b"\n"
        for index in range(2, 2 + count)
    ]
    events: list[Mapping[str, Any]] = []
    prior_clock = 0
    for offset, raw_event in enumerate(records[2 : 2 + count], start=1):
        framed = _exact_fields(
            raw_event, _NATIVE_FRAMED_EVENT_FIELDS, "native framed event"
        )
        validate_identity(framed)
        if (
            framed["record"] != "event"
            or framed["batch"] != 1
            or framed["event_sequence"] != offset
        ):
            raise ScreenDriverEvidenceError("native event sequence/framing is invalid")
        event = {field: framed[field] for field in _NATIVE_EVENT_FIELDS}
        clock = _positive_int(event["monotonic_ns"], "native telemetry clock")
        if clock < prior_clock:
            raise ScreenDriverEvidenceError("native telemetry clocks run backwards")
        prior_clock = clock
        _bounded_text(event["event"], "native telemetry event")
        if event["route"] not in {"undecided", "native", "fallback"}:
            raise ScreenDriverEvidenceError("native telemetry route is invalid")
        if not isinstance(event["route_proof"], bool) or not isinstance(
            event["libmpv_initialized"], bool
        ):
            raise ScreenDriverEvidenceError("native telemetry booleans are invalid")
        for field in (
            "source_key",
            "attempt",
            "serial",
            "generation",
            "gesture",
            "request",
            "draw_sequence",
        ):
            _nonnegative_int(event[field], f"native telemetry {field}")
        target = event["target_seconds"]
        if target is not None:
            _finite(target, "native telemetry target_seconds")
        events.append(event)
    commit = _exact_fields(
        records[-2], _NATIVE_BATCH_COMMIT_FIELDS, "native batch commit"
    )
    terminal = _exact_fields(
        records[-1], _NATIVE_STREAM_COMMIT_FIELDS, "native stream commit"
    )
    validate_identity(commit)
    validate_identity(terminal)
    payload_digest = hashlib.sha256(b"".join(raw_event_lines)).digest()
    chain_hasher = hashlib.sha256()
    chain_hasher.update(bytes(32))
    chain_hasher.update(payload_digest)
    chain_hasher.update(struct.pack(">QQQQ", 1, count, 1, count))
    chain = chain_hasher.hexdigest()
    exact_common = (
        commit["batch"] == 1
        and commit["event_count"] == count
        and commit["first_sequence"] == 1
        and commit["last_sequence"] == count
        and terminal["batch_count"] == 1
        and terminal["event_count"] == count
        and terminal["first_sequence"] == 1
        and terminal["last_sequence"] == count
    )
    if not (
        commit["record"] == "batch_commit"
        and terminal["record"] == "stream_commit"
        and exact_common
        and commit["payload_sha256"] == payload_digest.hex()
        and commit["chain_sha256"] == chain
        and terminal["chain_sha256"] == chain
    ):
        raise ScreenDriverEvidenceError(
            "native telemetry batch chain or terminal commit is invalid"
        )
    return events


def _validate_warm_native_telemetry(
    payload: bytes,
    binding: DriverBinding,
    transcript_event: Mapping[str, Any],
    dialog_accepted_monotonic_ns: int,
) -> None:
    events = _parse_native_telemetry_jsonl(payload, binding)
    if [event["event"] for event in events] != [
        "open_requested",
        "native_selected",
        "first_frame_drawn",
    ]:
        raise ScreenDriverEvidenceError(
            "warm telemetry must retain open, native selection, and first draw"
        )
    opened, selected, drawn = events
    details = transcript_event["details"]
    if not (
        transcript_event["monotonic_ns"] == drawn["monotonic_ns"]
        and details["open_requested_monotonic_ns"] == opened["monotonic_ns"]
        and details["native_selected_monotonic_ns"] == selected["monotonic_ns"]
        and details["first_frame_drawn_monotonic_ns"] == drawn["monotonic_ns"]
        and dialog_accepted_monotonic_ns
        < opened["monotonic_ns"]
        < selected["monotonic_ns"]
        < drawn["monotonic_ns"]
    ):
        raise ScreenDriverEvidenceError(
            "warm native clocks do not match the retained telemetry"
        )
    if any(event["source_key"] != binding.source_key for event in events):
        raise ScreenDriverEvidenceError("warm telemetry changed source identity")
    if not (
        opened["route"] == "undecided"
        and opened["route_proof"] is False
        and selected["route"] == "native"
        and selected["route_proof"] is True
        and drawn["route"] == "native"
        and all(event["libmpv_initialized"] is False for event in events)
        and selected["attempt"] > 0
        and selected["generation"] > 0
        and drawn["attempt"] == selected["attempt"]
        and drawn["generation"] == selected["generation"]
        and drawn["draw_sequence"] > 0
    ):
        raise ScreenDriverEvidenceError(
            "warm telemetry does not prove native selection and first frame"
        )


def _validate_steady_native_telemetry(
    payload: bytes,
    binding: DriverBinding,
    transcript_events: Sequence[Mapping[str, Any]],
) -> None:
    native_events = _parse_native_telemetry_jsonl(payload, binding)
    if [event["event"] for event in native_events[:3]] != [
        "open_requested",
        "native_selected",
        "first_frame_drawn",
    ] or len(native_events) != 3 + STEADY_SAMPLE_COUNT:
        raise ScreenDriverEvidenceError(
            "steady telemetry lacks route, first frame, or ongoing draws"
        )
    opened, selected, first_draw = native_events[:3]
    ongoing = native_events[3:]
    samples = [
        event for event in transcript_events if event["event"] == "steady_playback_sample"
    ]
    start = next(
        event for event in transcript_events if event["event"] == "steady_playback_started"
    )
    end = next(
        event for event in transcript_events if event["event"] == "steady_playback_completed"
    )
    if not (
        opened["monotonic_ns"] > next(
            event["monotonic_ns"]
            for event in transcript_events
            if event["event"] == "initial_open_action"
        )
        and opened["monotonic_ns"] < selected["monotonic_ns"] < first_draw["monotonic_ns"]
        <= start["monotonic_ns"]
        and all(event["source_key"] == binding.source_key for event in native_events)
        and opened["route"] == "undecided"
        and selected["route"] == "native"
        and selected["route_proof"] is True
        and first_draw["route"] == "native"
        and all(event["libmpv_initialized"] is False for event in native_events)
        and selected["attempt"] > 0
        and selected["generation"] > 0
        and first_draw["attempt"] == selected["attempt"]
        and first_draw["generation"] == selected["generation"]
        and first_draw["draw_sequence"] > 0
    ):
        raise ScreenDriverEvidenceError("steady native startup lineage is invalid")
    prior_draw = first_draw["draw_sequence"]
    prior_position = float(first_draw["target_seconds"])
    for sample, draw in zip(samples, ongoing):
        if not (
            draw["event"] == "first_frame_drawn"
            and draw["route"] == "native"
            and draw["monotonic_ns"] == sample["monotonic_ns"]
            and draw["draw_sequence"] == sample["details"]["draw_sequence"]
            and math.isclose(
                float(draw["target_seconds"]),
                float(sample["details"]["position_seconds"]),
                rel_tol=0.0,
                abs_tol=1e-9,
            )
            and draw["draw_sequence"] > prior_draw
            and float(draw["target_seconds"]) > prior_position
            and start["monotonic_ns"] < draw["monotonic_ns"] <= end["monotonic_ns"]
        ):
            raise ScreenDriverEvidenceError("steady sample lacks an advancing native draw")
        prior_draw = draw["draw_sequence"]
        prior_position = float(draw["target_seconds"])


def _validate_scrub_native_telemetry(
    payload: bytes,
    binding: DriverBinding,
    transcript_events: Sequence[Mapping[str, Any]],
    media_duration_seconds: float,
) -> None:
    native_events = _parse_native_telemetry_jsonl(payload, binding)
    allowed = {
        "preview_demanded",
        "preview_frame_drawn",
        "commit_seek_submitted",
        "commit_ready",
        "commit_frame_drawn",
    }
    if any(
        event["event"] not in allowed
        or event["route"] != "native"
        or event["route_proof"] is not False
        or event["libmpv_initialized"] is not False
        or event["source_key"] != binding.source_key
        for event in native_events
    ):
        raise ScreenDriverEvidenceError(
            "scrub telemetry is not exact native/non-fallback proof"
        )
    wrapper_start = next(
        event for event in transcript_events if event["event"] == "scrub_telemetry_started"
    )
    wrapper_end = next(
        event for event in transcript_events if event["event"] == "scrub_telemetry_completed"
    )
    if not (
        wrapper_start["monotonic_ns"] < native_events[0]["monotonic_ns"]
        <= native_events[-1]["monotonic_ns"] < wrapper_end["monotonic_ns"]
    ):
        raise ScreenDriverEvidenceError(
            "retained native telemetry is outside its capture brackets"
        )
    pointer_events = [
        event
        for event in transcript_events
        if event["event"] in {"pointer_down", "pointer_move", "pointer_up"}
    ]
    gesture_ids = []
    for event in pointer_events:
        gesture = event["details"]["gesture_id"]
        if gesture not in gesture_ids:
            gesture_ids.append(gesture)
    if len(gesture_ids) != 2:
        raise ScreenDriverEvidenceError("scrub telemetry needs exactly two gestures")
    allowed_gestures = set(gesture_ids)
    if any(event["gesture"] not in allowed_gestures for event in native_events):
        raise ScreenDriverEvidenceError("scrub telemetry contains an undelivered gesture")
    semantic_ids = [
        (event["gesture"], event["request"])
        for event in native_events
        if event["event"] == "preview_demanded"
    ]
    global_requests = [request for _, request in semantic_ids]
    if len(set(global_requests)) != len(global_requests):
        raise ScreenDriverEvidenceError("scrub request IDs are not globally unique")
    for gesture_index, gesture in enumerate(gesture_ids):
        moves = [
            event
            for event in pointer_events
            if event["event"] == "pointer_move"
            and event["details"]["gesture_id"] == gesture
        ]
        up = next(
            event
            for event in pointer_events
            if event["event"] == "pointer_up"
            and event["details"]["gesture_id"] == gesture
        )
        native_for_gesture = [
            event for event in native_events if event["gesture"] == gesture
        ]
        demands = [
            event for event in native_for_gesture if event["event"] == "preview_demanded"
        ]
        draws = [
            event
            for event in native_for_gesture
            if event["event"] == "preview_frame_drawn"
        ]
        submitted = [
            event
            for event in native_for_gesture
            if event["event"] == "commit_seek_submitted"
        ]
        ready = [
            event for event in native_for_gesture if event["event"] == "commit_ready"
        ]
        committed = [
            event
            for event in native_for_gesture
            if event["event"] == "commit_frame_drawn"
        ]
        if (
            len(demands) != DRAG_MOVE_COUNT_PER_LEG
            or len(draws) < 1
            or len(submitted) != 1
            or len(ready) != 1
            or len(committed) != 1
        ):
            raise ScreenDriverEvidenceError(
                "each scrub leg needs every public demand, a draw, and one commit proof"
            )
        requests = [event["request"] for event in demands]
        if any(request <= 0 for request in requests) or len(set(requests)) != len(requests):
            raise ScreenDriverEvidenceError("scrub public demand IDs are not exact")
        targets = [
            _finite(event["target_seconds"], "scrub public target") for event in demands
        ]
        increasing = gesture_index == 0
        if any(
            (right <= left if increasing else right >= left)
            for left, right in zip(targets, targets[1:])
        ):
            raise ScreenDriverEvidenceError("scrub public demand direction is wrong")
        for move, demand in zip(moves, demands):
            delay = demand["monotonic_ns"] - move["monotonic_ns"]
            expected_target = float(move["details"]["normalized_x"]) * media_duration_seconds
            if (
                delay < 0
                or delay > 5_000_000
                or not math.isclose(
                    float(demand["target_seconds"]),
                    expected_target,
                    rel_tol=0.0,
                    abs_tol=1e-9,
                )
                or any(
                    demand[field] != expected
                    for field, expected in (
                        ("attempt", 0),
                        ("serial", 0),
                        ("generation", 0),
                        ("draw_sequence", 0),
                    )
                )
            ):
                raise ScreenDriverEvidenceError(
                    "public scrub demand is not caused by its exact input/target"
                )
        demand_by_request = {event["request"]: event for event in demands}
        if any(
            draw["request"] not in demand_by_request
            or draw["attempt"] <= 0
            or draw["serial"] <= 0
            or draw["generation"] <= 0
            or draw["draw_sequence"] <= 0
            or draw["monotonic_ns"] < demand_by_request[draw["request"]]["monotonic_ns"]
            or draw["monotonic_ns"] > up["monotonic_ns"]
            or not math.isclose(
                float(draw["target_seconds"]),
                float(demand_by_request[draw["request"]]["target_seconds"]),
                rel_tol=0.0,
                abs_tol=1e-9,
            )
            for draw in draws
        ):
            raise ScreenDriverEvidenceError("scrub draw lacks a matching public demand")
        submit, ready_event, committed_event = submitted[0], ready[0], committed[0]
        submit_target = _finite(
            submit["target_seconds"], "native commit target_seconds"
        )
        ready_target = _finite(
            ready_event["target_seconds"], "native commit-ready target_seconds"
        )
        committed_target = _finite(
            committed_event["target_seconds"], "native commit-draw target_seconds"
        )
        commit_identity = (
            submit["gesture"],
            submit["request"],
            submit["attempt"],
            submit["serial"],
            submit["generation"],
        )
        if not (
            0 <= submit["monotonic_ns"] - up["monotonic_ns"] <= 100_000_000
            and commit_identity
            == (
                ready_event["gesture"],
                ready_event["request"],
                ready_event["attempt"],
                ready_event["serial"],
                ready_event["generation"],
            )
            == (
                committed_event["gesture"],
                committed_event["request"],
                committed_event["attempt"],
                committed_event["serial"],
                committed_event["generation"],
            )
            and all(value > 0 for value in commit_identity)
            and math.isclose(
                submit_target,
                targets[-1],
                rel_tol=0.0,
                abs_tol=1e-9,
            )
            and math.isclose(
                ready_target, submit_target, rel_tol=0.0, abs_tol=1e-9
            )
            and math.isclose(
                committed_target, submit_target, rel_tol=0.0, abs_tol=1e-9
            )
            and ready_event["monotonic_ns"] == committed_event["monotonic_ns"]
            and ready_event["monotonic_ns"] >= submit["monotonic_ns"]
            and native_events.index(submit)
            < native_events.index(ready_event)
            < native_events.index(committed_event)
            and ready_event["draw_sequence"] > 0
            and ready_event["draw_sequence"] == committed_event["draw_sequence"]
        ):
            raise ScreenDriverEvidenceError(
                "scrub release is not bracketed by one exact native commit/draw"
            )


def _wav_identity(payload: bytes) -> tuple[int, int, int, int, float]:
    if len(payload) < 12 or payload[:4] != b"RIFF" or payload[8:12] != b"WAVE":
        raise ScreenDriverEvidenceError("system-audio artifact is not a WAV")
    if struct.unpack("<I", payload[4:8])[0] + 8 != len(payload):
        raise ScreenDriverEvidenceError("system-audio WAV has the wrong RIFF length")
    cursor = 12
    channels = sample_rate = byte_rate = block_align = data_bytes = bits_per_sample = format_tag = 0
    pcm_data = b""
    format_chunks = data_chunks = 0
    while cursor + 8 <= len(payload):
        chunk_id = payload[cursor : cursor + 4]
        size = struct.unpack("<I", payload[cursor + 4 : cursor + 8])[0]
        start = cursor + 8
        end = start + size
        if end > len(payload):
            raise ScreenDriverEvidenceError("system-audio WAV has a truncated chunk")
        if chunk_id == b"fmt " and size >= 16:
            format_tag, channels, sample_rate, byte_rate, block_align, bits_per_sample = struct.unpack(
                "<HHIIHH", payload[start : start + 16]
            )
            format_chunks += 1
        elif chunk_id == b"data":
            data_bytes += size
            pcm_data += payload[start:end]
            data_chunks += 1
        cursor = end + (size & 1)
    if cursor != len(payload):
        raise ScreenDriverEvidenceError("system-audio WAV has trailing partial data")
    if (
        format_chunks != 1
        or data_chunks != 1
        or format_tag != 1
        or bits_per_sample != 16
        or not 1 <= channels <= 8
        or not 8_000 <= sample_rate <= 192_000
        or block_align != channels * 2
        or byte_rate != sample_rate * block_align
        or data_bytes <= 0
        or data_bytes > 256 * 1024 * 1024
    ):
        raise ScreenDriverEvidenceError("system-audio WAV has no decodable captured frames")
    if data_bytes % block_align:
        raise ScreenDriverEvidenceError("system-audio WAV data is not frame-aligned")
    frames = data_bytes // block_align
    if frames < sample_rate // 2:
        raise ScreenDriverEvidenceError("system-audio WAV is shorter than 500 milliseconds")
    samples = struct.unpack("<" + "h" * (data_bytes // 2), pcm_data)
    non_silent_frames = sum(
        any(samples[frame * channels + channel] != 0 for channel in range(channels))
        for frame in range(frames)
    )
    peak = max(abs(sample) for sample in samples)
    peak_dbfs = 20.0 * math.log10(peak / 32768.0) if peak else -math.inf
    if non_silent_frames < math.ceil(frames * 0.05) or peak_dbfs < -60.0:
        raise ScreenDriverEvidenceError("system-audio WAV contains no audible signal")
    # A global peak/RMS bit is trivial to forge with a short burst, DC value,
    # or sparse impulses.  Prove sustained AC energy in fixed 20 ms windows.
    window_frames = max(1, sample_rate // 50)
    window_count = frames // window_frames
    if window_count < 25:
        raise ScreenDriverEvidenceError("system-audio WAV lacks 500 ms of full windows")
    active_windows = 0
    for window_index in range(window_count):
        first_frame = window_index * window_frames
        first_sample = first_frame * channels
        last_sample = (first_frame + window_frames) * channels
        window = samples[first_sample:last_sample]
        mean = sum(window) / len(window)
        centered_energy = sum((sample - mean) ** 2 for sample in window) / len(window)
        centered_rms = math.sqrt(centered_energy)
        centered_peak = max(abs(sample - mean) for sample in window)
        varying_samples = sum(
            sample != previous for previous, sample in zip(window, window[1:])
        )
        dense_samples = sum(abs(sample - mean) >= max(8.0, centered_rms / 4.0) for sample in window)
        crest = centered_peak / centered_rms if centered_rms > 0.0 else math.inf
        if (
            centered_rms >= 16.0
            and crest <= 4.0
            and varying_samples >= math.ceil((len(window) - 1) * 0.10)
            and dense_samples >= math.ceil(len(window) * 0.20)
        ):
            active_windows += 1
    if active_windows < math.ceil(window_count * 0.80):
        raise ScreenDriverEvidenceError(
            "system-audio WAV is not sustained non-DC, non-impulse output"
        )
    return sample_rate, channels, frames, non_silent_frames, peak_dbfs


def make_loader_capture_payload(
    binding: DriverBinding,
    capture_nonce: str,
    *,
    library_identity: DylibFileIdentity,
    loaded: bool,
    observation_method: str,
    invocation: TrustedInvocation,
    artifact: ArtifactRecord,
) -> bytes:
    lines = (
        f"schema={LOADER_CAPTURE_SCHEMA}",
        f"capture_nonce={capture_nonce}",
        f"run_id={binding.run_id}",
        f"process_id={binding.process_id}",
        f"process_start_abstime={binding.process_start_abstime}",
        f"source_key={binding.source_key}",
        f"asset_sha256={binding.asset_sha256}",
        f"candidate_id={binding.candidate_id}",
        f"library={library_identity.canonical_path}",
        f"library_device={library_identity.device}",
        f"library_inode={library_identity.inode}",
        f"library_sha256={library_identity.sha256}",
        f"loaded={'true' if loaded else 'false'}",
        f"observation_method={observation_method}",
        f"producer_invocation_id={invocation.invocation_id}",
        f"producer_executable_path={invocation.executable_path}",
        f"producer_executable_sha256={invocation.executable_sha256}",
        f"producer_argv_sha256={_digest(list(invocation.argv))}",
        f"producer_receipt_id={artifact.producer_receipt_id}",
        f"capture_started_monotonic_ns={artifact.capture_started_monotonic_ns}",
        f"capture_ended_monotonic_ns={artifact.capture_ended_monotonic_ns}",
        f"artifact_id={artifact.artifact_id}",
    )
    return ("\n".join(lines) + "\n").encode("utf-8")


def _validate_artifacts(
    raw_artifacts: Any,
    payloads: Mapping[str, bytes],
    *,
    binding: DriverBinding,
    phase: str,
    capture_nonce: str,
    audit: MacOSAuditIdentity,
    window: WindowIdentity,
    input_receipt: InputDriverReceipt | None,
    invocations_by_id: Mapping[str, TrustedInvocation],
    invocations_by_role: Mapping[str, TrustedInvocation],
    events: Sequence[Mapping[str, Any]],
    loader_library_path: str,
    expected_loader_identity: DylibFileIdentity,
    media_duration_seconds: float,
) -> dict[str, ArtifactRecord]:
    if isinstance(raw_artifacts, (str, bytes)) or not isinstance(raw_artifacts, Sequence):
        raise ScreenDriverEvidenceError("artifacts must be an array")
    artifacts = [ArtifactRecord.from_mapping(value) for value in raw_artifacts]
    identifiers = [artifact.artifact_id for artifact in artifacts]
    kinds = [artifact.kind for artifact in artifacts]
    if identifiers != sorted(identifiers):
        raise ScreenDriverEvidenceError("artifact records are not canonically ordered")
    if len(set(identifiers)) != len(identifiers):
        raise ScreenDriverEvidenceError("artifact IDs are duplicated")
    required_kinds = PHASE_ARTIFACT_KINDS[phase]
    if set(kinds) != required_kinds or len(kinds) != len(required_kinds):
        raise ScreenDriverEvidenceError("receipt does not contain the exact required artifacts")
    if not isinstance(payloads, Mapping) or set(payloads) != set(identifiers):
        raise ScreenDriverEvidenceError("retained artifact payload IDs are not exact")
    by_id = {artifact.artifact_id: artifact for artifact in artifacts}
    by_kind = {artifact.kind: artifact for artifact in artifacts}
    expected_producer_role = {
        "window_audit": "window_audit",
        "initial_open_receipt": "open_driver",
        "input_trace": "input_driver",
        "dialog_acceptance": "input_driver",
        "warm_source_telemetry": "capture_harness",
        "scrub_native_telemetry": "capture_harness",
        "steady_native_telemetry": "capture_harness",
        "fallback_route_telemetry": "capture_harness",
        "screenshot": "screen_capture",
        "loader_pre": "loader_inspector",
        "loader_post": "loader_inspector",
        "system_audio": "system_audio_capture",
    }
    producer_receipt_ids = [artifact.producer_receipt_id for artifact in artifacts]
    if len(set(producer_receipt_ids)) != len(producer_receipt_ids):
        raise ScreenDriverEvidenceError("artifact producer receipt IDs are duplicated")
    for artifact in artifacts:
        payload = payloads[artifact.artifact_id]
        if not isinstance(payload, bytes) or not payload:
            raise ScreenDriverEvidenceError("retained artifact payload must be non-empty bytes")
        if (
            hashlib.sha256(payload).hexdigest() != artifact.sha256
            or len(payload) != artifact.byte_length
            or artifact.media_type != _ARTIFACT_MEDIA_TYPES[artifact.kind]
        ):
            raise ScreenDriverEvidenceError("retained artifact bytes do not match their receipt")
        producer = invocations_by_id.get(artifact.producer_invocation_id)
        if producer is None or producer.role != expected_producer_role[artifact.kind]:
            raise ScreenDriverEvidenceError(
                "artifact was not emitted by its identified trusted producer role"
            )

    for event in events:
        artifact = by_id[event["artifact_id"]]
        if artifact.producer_invocation_id != event["actor_invocation_id"]:
            raise ScreenDriverEvidenceError("event and artifact producer identities differ")
        if not (
            artifact.capture_started_monotonic_ns
            <= event["monotonic_ns"]
            <= artifact.capture_ended_monotonic_ns
        ):
            raise ScreenDriverEvidenceError("event clock is outside artifact capture bounds")

    events_by_name = {event["event"]: event for event in events}
    exact_receipts: dict[str, str] = {
        "window_audit": events_by_name["macos_audit_capture"]["details"][
            "capture_receipt_id"
        ],
        "initial_open_receipt": events_by_name["initial_open_action"]["details"][
            "delivery_receipt_id"
        ],
    }
    if phase == "startup":
        assert input_receipt is not None
        exact_receipts.update(
            {
                "input_trace": input_receipt.receipt_id,
                "dialog_acceptance": events_by_name["warm_open_action"]["details"][
                    "dialog_acceptance_receipt_id"
                ],
                "warm_source_telemetry": events_by_name[
                    "warm_open_source_observed"
                ]["details"]["telemetry_receipt_id"],
            }
        )
    elif phase == "scrub":
        assert input_receipt is not None
        start_receipt = events_by_name["scrub_telemetry_started"]["details"][
            "telemetry_receipt_id"
        ]
        if (
            events_by_name["scrub_telemetry_completed"]["details"][
                "telemetry_receipt_id"
            ]
            != start_receipt
        ):
            raise ScreenDriverEvidenceError("scrub telemetry receipt IDs differ")
        exact_receipts.update(
            {"input_trace": input_receipt.receipt_id, "scrub_native_telemetry": start_receipt}
        )
    elif phase == "steady":
        receipt_ids = {
            event["details"]["telemetry_receipt_id"]
            for event in events
            if event["event"].startswith("steady_playback_")
        }
        if len(receipt_ids) != 1:
            raise ScreenDriverEvidenceError("steady telemetry receipt IDs differ")
        exact_receipts["steady_native_telemetry"] = next(iter(receipt_ids))
    elif phase == "fallback_control":
        exact_receipts.update(
            {
                "loader_pre": events_by_name["loader_pre_capture"]["details"][
                    "observation_receipt_id"
                ],
                "fallback_route_telemetry": events_by_name[
                    "fallback_route_selected"
                ]["details"]["telemetry_receipt_id"],
                "loader_post": events_by_name["loader_post_capture"]["details"][
                    "observation_receipt_id"
                ],
                "screenshot": events_by_name["screenshot_capture"]["details"][
                    "capture_receipt_id"
                ],
                "system_audio": events_by_name["system_audio_capture"]["details"][
                    "capture_receipt_id"
                ],
            }
        )
    for kind, producer_receipt_id in exact_receipts.items():
        if by_kind[kind].producer_receipt_id != producer_receipt_id:
            raise ScreenDriverEvidenceError(
                f"{kind} artifact does not match its producer receipt ID"
            )
    if input_receipt is not None:
        if (
            events_by_name["initial_open_action"]["details"]["delivery_receipt_id"]
            == input_receipt.receipt_id
        ):
            raise ScreenDriverEvidenceError("initial open reuses an input-driver receipt")
        if phase == "startup" and (
            events_by_name["warm_open_action"]["details"]["delivery_receipt_id"]
            == input_receipt.receipt_id
        ):
            raise ScreenDriverEvidenceError(
                "warm open action reuses its aggregate input-driver receipt"
            )
        if (
            by_kind["input_trace"].capture_started_monotonic_ns
            != input_receipt.started_monotonic_ns
            or by_kind["input_trace"].capture_ended_monotonic_ns
            != input_receipt.ended_monotonic_ns
        ):
            raise ScreenDriverEvidenceError(
                "input trace capture clocks do not match its receipt"
            )
    for kind in required_kinds - {
        "input_trace",
        "dialog_acceptance",
        "scrub_native_telemetry",
        "steady_native_telemetry",
    }:
        matching_events = [
            event for event in events if event["artifact_id"] == by_kind[kind].artifact_id
        ]
        if len(matching_events) != 1:
            raise ScreenDriverEvidenceError(f"{kind} artifact is not used exactly once")
        if by_kind[kind].capture_ended_monotonic_ns != matching_events[0]["monotonic_ns"]:
            raise ScreenDriverEvidenceError(f"{kind} capture completion clock is not exact")

    expected_audit = make_window_audit_payload(binding, capture_nonce, audit, window)
    if payloads[by_kind["window_audit"].artifact_id] != expected_audit:
        raise ScreenDriverEvidenceError("window-audit JSON is not the canonical receipt snapshot")
    if input_receipt is not None:
        expected_input = make_input_trace_payload(
            binding, capture_nonce, input_receipt, events
        )
        if payloads[by_kind["input_trace"].artifact_id] != expected_input:
            raise ScreenDriverEvidenceError(
                "input-trace JSON is not the exact delivered trace"
            )
    expected_initial = make_initial_open_payload(
        binding, capture_nonce, AssetFileIdentity.from_mapping(
            events_by_name["initial_open_action"]["details"]["asset"]
        ), events_by_name["initial_open_action"]
    )
    if payloads[by_kind["initial_open_receipt"].artifact_id] != expected_initial:
        raise ScreenDriverEvidenceError(
            "initial-open JSON is not the exact LaunchServices receipt"
        )
    if phase == "fallback_control":
        _validate_png(payloads[by_kind["screenshot"].artifact_id], window)
    if phase == "fallback_control":
        fallback_event = events_by_name["fallback_route_selected"]
        fallback_native = _parse_native_telemetry_jsonl(
            payloads[by_kind["fallback_route_telemetry"].artifact_id], binding
        )
        if len(fallback_native) != 1:
            raise ScreenDriverEvidenceError(
                "fallback route artifact must retain exactly one native record"
            )
        native_route = fallback_native[0]
        if not (
            native_route["event"] == "fallback_selected"
            and native_route["monotonic_ns"] == fallback_event["monotonic_ns"]
            and native_route["route"] == "fallback"
            and native_route["route_proof"] is True
            and native_route["source_key"] == binding.source_key
            and native_route["attempt"] > 0
            and native_route["serial"] > 0
            and native_route["libmpv_initialized"] is True
        ):
            raise ScreenDriverEvidenceError(
                "fallback artifact is not retained exact route-selection proof"
            )
        loader_events = {
            event["event"]: event
            for event in events
            if event["event"] in {"loader_pre_capture", "loader_post_capture"}
        }
        loader_invocation = invocations_by_role["loader_inspector"]
        for kind, event_name, loaded in (
            ("loader_pre", "loader_pre_capture", False),
            ("loader_post", "loader_post_capture", True),
        ):
            artifact = by_kind[kind]
            expected_loader = make_loader_capture_payload(
                binding,
                capture_nonce,
                library_identity=expected_loader_identity,
                loaded=loaded,
                observation_method=loader_events[event_name]["details"][
                    "observation_method"
                ],
                invocation=loader_invocation,
                artifact=artifact,
            )
            if payloads[artifact.artifact_id] != expected_loader:
                raise ScreenDriverEvidenceError(
                    f"{kind} text is not the exact tool receipt"
                )
        sample_rate, channels, frames, non_silent_frames, peak_dbfs = _wav_identity(
            payloads[by_kind["system_audio"].artifact_id]
        )
        audio_event = events_by_name["system_audio_capture"]
        details = audio_event["details"]
        audio_artifact = by_kind["system_audio"]
        capture_duration_s = (
            audio_artifact.capture_ended_monotonic_ns
            - audio_artifact.capture_started_monotonic_ns
        ) / 1_000_000_000.0
        audio_duration_s = frames / sample_rate
        if (
            audio_artifact.capture_started_monotonic_ns
            <= events_by_name["loader_post_capture"]["monotonic_ns"]
            or details["sample_rate_hz"] != sample_rate
            or details["channels"] != channels
            or details["captured_frames"] != frames
            or details["non_silent_frames"] != non_silent_frames
            or not math.isclose(
                float(details["peak_dbfs"]), peak_dbfs, rel_tol=0.0, abs_tol=0.01
            )
            or abs(audio_duration_s - capture_duration_s) > 1.0 / sample_rate
        ):
            raise ScreenDriverEvidenceError(
                "WAV identity/timing does not match post-route audio capture"
            )
    if input_receipt is not None and (
        input_receipt.artifact_id != by_kind["input_trace"].artifact_id
    ):
        raise ScreenDriverEvidenceError("input receipt references the wrong artifact ID")
    initial_events = [event for event in events if event["event"] == "initial_open_action"]
    warm_events = [event for event in events if event["event"] == "warm_open_action"]
    warm_source_events = [
        event for event in events if event["event"] == "warm_open_source_observed"
    ]
    if len(initial_events) != 1:
        raise ScreenDriverEvidenceError("initial open evidence is not exact")
    if phase == "startup":
        if len(warm_events) != 1 or len(warm_source_events) != 1:
            raise ScreenDriverEvidenceError("warm open evidence is not exact")
        expected_dialog = make_dialog_acceptance_payload(
            binding,
            capture_nonce,
            AssetFileIdentity.from_mapping(warm_events[0]["details"]["asset"]),
            window,
            events,
        )
        if payloads[by_kind["dialog_acceptance"].artifact_id] != expected_dialog:
            raise ScreenDriverEvidenceError(
                "dialog-acceptance JSON is not the exact screen input receipt"
            )
        dialog_events = [
            event
            for event in events
            if event["event"]
            in {
                "open_shortcut_key_down",
                "open_shortcut_key_up",
                "file_dialog_shown",
                "file_dialog_path_selected",
                "file_dialog_accepted",
                "warm_open_action",
            }
        ]
        dialog_artifact = by_kind["dialog_acceptance"]
        if (
            dialog_artifact.capture_started_monotonic_ns
            != dialog_events[0]["monotonic_ns"]
            or dialog_artifact.capture_ended_monotonic_ns
            != dialog_events[-1]["monotonic_ns"]
        ):
            raise ScreenDriverEvidenceError(
                "dialog artifact clocks do not cover exact raw deliveries"
            )
        warm_source_artifact = by_kind["warm_source_telemetry"]
        warm_source_event = warm_source_events[0]
        if (
            warm_source_artifact.capture_started_monotonic_ns
            > warm_source_event["details"]["open_requested_monotonic_ns"]
            or warm_source_artifact.capture_ended_monotonic_ns
            != warm_source_event["monotonic_ns"]
        ):
            raise ScreenDriverEvidenceError(
                "warm-source capture clocks do not retain the native lineage"
            )
        _validate_warm_native_telemetry(
            payloads[warm_source_artifact.artifact_id],
            binding,
            warm_source_event,
            events_by_name["file_dialog_accepted"]["monotonic_ns"],
        )
    elif warm_events or warm_source_events:
        raise ScreenDriverEvidenceError("non-startup phase contains warm-open evidence")
    if phase == "steady":
        steady_artifact = by_kind["steady_native_telemetry"]
        steady_events = [
            event for event in events if event["event"].startswith("steady_playback_")
        ]
        if (
            steady_artifact.capture_started_monotonic_ns
            != steady_events[0]["monotonic_ns"]
            or steady_artifact.capture_ended_monotonic_ns
            != steady_events[-1]["monotonic_ns"]
        ):
            raise ScreenDriverEvidenceError("steady telemetry capture brackets differ")
        _validate_steady_native_telemetry(
            payloads[steady_artifact.artifact_id], binding, events
        )
    if phase == "scrub":
        scrub_artifact = by_kind["scrub_native_telemetry"]
        telemetry_events = [
            event
            for event in events
            if event["event"] in {
                "scrub_telemetry_started",
                "scrub_telemetry_completed",
            }
        ]
        if (
            scrub_artifact.capture_started_monotonic_ns
            != telemetry_events[0]["monotonic_ns"]
            or scrub_artifact.capture_ended_monotonic_ns
            != telemetry_events[-1]["monotonic_ns"]
        ):
            raise ScreenDriverEvidenceError(
                "scrub telemetry artifact does not bracket the input trace"
            )
        _validate_scrub_native_telemetry(
            payloads[scrub_artifact.artifact_id],
            binding,
            events,
            media_duration_seconds,
        )
    return by_id


def validate_capture_receipt(
    receipt: Any,
    *,
    expected_binding: DriverBinding,
    expected_capture_nonce: str,
    expected_transcript_sha256: str,
    expected_phase_variant: PhaseVariant,
    expected_asset: AssetFileIdentity,
    expected_invocations: Sequence[TrustedInvocation],
    expected_loader_identity: DylibFileIdentity,
    expected_media_duration_seconds: float,
    external_attestation: Any,
    artifact_payloads: Mapping[str, bytes],
) -> ValidatedCaptureReceipt:
    """Validate one complete, externally authenticated screen-capture bundle.

    The expected nonce and tool identities must come from outside ``receipt``.
    Accepting values copied out of an untrusted receipt would defeat the trust
    boundary and is intentionally not offered as a convenience mode.
    """

    receipt = _exact_fields(receipt, _RECEIPT_FIELDS, "capture receipt")
    if receipt["schema"] != RECEIPT_SCHEMA:
        raise ScreenDriverEvidenceError("capture receipt schema is unsupported")
    if receipt["captured_by_harness"] is not True:
        raise ScreenDriverEvidenceError("capture was not marked captured_by_harness=true")
    if receipt["harness_trust_boundary"] != TRUST_BOUNDARY:
        raise ScreenDriverEvidenceError("capture receipt obscures the harness trust boundary")
    if not isinstance(expected_binding, DriverBinding):
        raise ScreenDriverEvidenceError("expected DriverBinding is required")
    binding = DriverBinding.from_mapping(receipt["binding"])
    if binding != expected_binding:
        raise ScreenDriverEvidenceError("receipt binding does not match expected run identity")
    if not isinstance(expected_phase_variant, PhaseVariant):
        raise ScreenDriverEvidenceError("expected PhaseVariant is required")
    phase_variant = PhaseVariant.from_mapping(receipt["phase_variant"])
    if phase_variant != expected_phase_variant:
        raise ScreenDriverEvidenceError("receipt phase/variant/replicate does not match")
    phase = phase_variant.phase
    if not isinstance(expected_capture_nonce, str) or _NONCE_RE.fullmatch(
        expected_capture_nonce
    ) is None:
        raise ScreenDriverEvidenceError("an external 256-bit expected capture nonce is required")
    if receipt["capture_nonce"] != expected_capture_nonce:
        raise ScreenDriverEvidenceError("capture nonce does not match the external challenge")
    trusted_transcript_digest = _sha256(
        expected_transcript_sha256, "external expected_transcript_sha256"
    )
    if not isinstance(expected_asset, AssetFileIdentity):
        raise ScreenDriverEvidenceError("expected asset file identity is required")
    asset = AssetFileIdentity.from_mapping(receipt["asset"])
    if asset != expected_asset:
        raise ScreenDriverEvidenceError("asset canonical path, device, or inode changed")
    if external_attestation is None or not hasattr(external_attestation, "tool"):
        raise ScreenDriverEvidenceError(
            "validated external trust-index capability is required"
        )
    try:
        attested_binding = external_attestation.binding
        attested_nonce = external_attestation.capture_nonce
        attested_audit = external_attestation.audit_token_sha256
        attested_dylib = external_attestation.candidate_dylib
        _sha256(external_attestation.trust_index_sha256, "trust-index SHA-256")
    except (AttributeError, TypeError, ValueError) as error:
        raise ScreenDriverEvidenceError(
            "external trust-index capability is incomplete"
        ) from error
    for field in _BINDING_FIELDS:
        if getattr(attested_binding, field) != getattr(binding, field):
            raise ScreenDriverEvidenceError(
                "external trust-index binding does not match screen receipt"
            )
    if attested_nonce != expected_capture_nonce:
        raise ScreenDriverEvidenceError("external trust-index nonce does not match")
    if not isinstance(expected_loader_identity, DylibFileIdentity):
        raise ScreenDriverEvidenceError("external fallback dylib identity is required")
    loader_path = expected_loader_identity.canonical_path
    if phase == "fallback_control" and (
        attested_dylib is None
        or any(
            getattr(attested_dylib, field)
            != getattr(expected_loader_identity, field)
            for field in ("canonical_path", "device", "inode", "sha256")
        )
    ):
        raise ScreenDriverEvidenceError(
            "external trust index does not authenticate the fallback dylib"
        )
    media_duration = _finite(
        expected_media_duration_seconds,
        "external expected media duration",
        positive=True,
    )
    context_digest = capture_context_sha256(
        binding, phase_variant, expected_capture_nonce
    )

    invocations_by_id, invocations_by_role = _validate_expected_invocations(
        receipt["trusted_invocations"], expected_invocations, phase, context_digest
    )
    trust_roles = {
        role
        for role in PHASE_INVOCATION_ROLES[phase]
        if role
        in {
            "screen_capture",
            "window_audit",
            "loader_inspector",
            "system_audio_capture",
        }
    }
    for role in trust_roles:
        invocation = invocations_by_role[role]
        try:
            attested_tool = external_attestation.tool(role)
        except Exception as error:
            raise ScreenDriverEvidenceError(
                f"external trust index lacks {role}"
            ) from error
        if (
            attested_tool.executable_path != invocation.executable_path
            or attested_tool.executable_sha256 != invocation.executable_sha256
            or attested_tool.executable_argv_sha256 != _digest(list(invocation.argv))
            or attested_tool.audit_token_sha256 != attested_audit
        ):
            raise ScreenDriverEvidenceError(
                f"external trust-index tool identity differs for {role}"
            )
    audit = MacOSAuditIdentity.from_mapping(receipt["macos_audit"])
    window = WindowIdentity.from_mapping(receipt["window"])
    input_receipt = (
        InputDriverReceipt.from_mapping(receipt["input_driver_receipt"])
        if phase in {"startup", "scrub"}
        else None
    )
    if phase not in {"startup", "scrub"} and receipt["input_driver_receipt"] is not None:
        raise ScreenDriverEvidenceError("non-input phase must store null input receipt")
    app_invocation = invocations_by_role["app_executable"]
    if (
        audit.process_id != binding.process_id
        or audit.audit_token_sha256 != attested_audit
        or audit.executable_path != app_invocation.executable_path
        or audit.executable_sha256 != app_invocation.executable_sha256
        or audit.screen_recording_authorized is not True
    ):
        raise ScreenDriverEvidenceError("macOS audit lacks required screen capture identity")
    if input_receipt is not None and audit.accessibility_authorized is not True:
        raise ScreenDriverEvidenceError("macOS audit lacks required input permission")
    if (
        window.owner_process_id != binding.process_id
        or window.owner_process_start_abstime != binding.process_start_abstime
        or window.owner_bundle_id != EXPECTED_WAM_BUNDLE_ID
        or audit.signing_identifier != EXPECTED_WAM_BUNDLE_ID
        or window.onscreen is not True
        or window.frontmost is not True
        or window.visible is not True
        or window.layer != 0
        or window.alpha <= 0.0
    ):
        raise ScreenDriverEvidenceError("window is not the visible frontmost WAM process window")
    if input_receipt is not None and (
        input_receipt.audit_session_id != audit.audit_session_id
        or input_receipt.audit_token_sha256 != audit.audit_token_sha256
        or input_receipt.target_process_id != binding.process_id
        or input_receipt.target_process_start_abstime != binding.process_start_abstime
        or input_receipt.target_window_id != window.window_id
        or input_receipt.posted_by_harness is not True
    ):
        raise ScreenDriverEvidenceError("input driver receipt is not bound to the audited window")

    # Artifact IDs are needed while validating event references, while payload
    # content is validated after the exact event grammar is known.
    raw_artifacts = receipt["artifacts"]
    if isinstance(raw_artifacts, (str, bytes)) or not isinstance(raw_artifacts, Sequence):
        raise ScreenDriverEvidenceError("artifacts must be an array")
    preliminary = [ArtifactRecord.from_mapping(value) for value in raw_artifacts]
    preliminary_by_id = {value.artifact_id: value for value in preliminary}
    if len(preliminary_by_id) != len(preliminary):
        raise ScreenDriverEvidenceError("artifact IDs are duplicated")
    events, gesture_ids = _parse_events(
        receipt["events"],
        binding=binding,
        phase=phase,
        capture_nonce=expected_capture_nonce,
        asset=asset,
        invocations_by_id=invocations_by_id,
        invocations_by_role=invocations_by_role,
        audit=audit,
        window=window,
        input_receipt=input_receipt,
        artifacts_by_id=preliminary_by_id,
        expected_loader_library_path=loader_path,
    )
    supplied_digest = _sha256(receipt["transcript_sha256"], "transcript_sha256")
    computed_digest = transcript_sha256(events, receipt["artifacts"])
    if supplied_digest != computed_digest:
        raise ScreenDriverEvidenceError("transcript SHA-256 does not match canonical events")
    if computed_digest != trusted_transcript_digest:
        raise ScreenDriverEvidenceError(
            "transcript SHA-256 does not match the external harness anchor"
        )
    artifacts = _validate_artifacts(
        raw_artifacts,
        artifact_payloads,
        binding=binding,
        phase=phase,
        capture_nonce=expected_capture_nonce,
        audit=audit,
        window=window,
        input_receipt=input_receipt,
        invocations_by_id=invocations_by_id,
        invocations_by_role=invocations_by_role,
        events=events,
        loader_library_path=loader_path,
        expected_loader_identity=expected_loader_identity,
        media_duration_seconds=media_duration,
    )
    return ValidatedCaptureReceipt(
        binding=binding,
        asset=asset,
        capture_nonce=expected_capture_nonce,
        transcript_sha256=computed_digest,
        first_monotonic_ns=events[0]["monotonic_ns"],
        last_monotonic_ns=events[-1]["monotonic_ns"],
        gesture_ids=gesture_ids,
        artifact_sha256=tuple(
            sorted((artifact_id, value.sha256) for artifact_id, value in artifacts.items())
        ),
    )
