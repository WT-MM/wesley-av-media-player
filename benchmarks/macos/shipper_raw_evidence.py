#!/usr/bin/env python3
"""Fail-closed validation for retained macOS shipper evidence.

The shipping report must be reproducible from files retained below one campaign
directory.  This module validates those files without launching WAM, taking a
screen capture, or trusting summary fields supplied by the capture driver.
"""

from __future__ import annotations

import dataclasses
import ctypes
import errno
import hashlib
import json
import math
import os
import re
import stat
import struct
import threading
import unicodedata
import uuid
import zlib
import sys
from pathlib import Path
from typing import Any, Mapping, Sequence


SCHEMA = "wam.macos.raw-evidence.v1"
WINDOW_STATE_SCHEMA = "wam.macos.window-state.v1"
WINDOW_CAPTURE_RECEIPT_SCHEMA = "wam.macos.trusted-window-capture.v1"
LOADER_OBSERVATION_SCHEMA = "wam.macos.loader-observation.v1"
AUDIO_CAPTURE_PROVENANCE_SCHEMA = "wam.macos.process-audio-provenance.v1"
LOADER_INSPECTOR_RECEIPT_SCHEMA = "wam.macos.loader-inspector-receipt.v1"
EXTERNAL_TRUST_INDEX_SCHEMA = "wam.macos.external-trust-index.v1"
MAX_EVIDENCE_BYTES = 256 * 1024 * 1024
MAX_CAMPAIGN_ENTRIES = 100_000
MAX_DECODED_PNG_BYTES = 256 * 1024 * 1024
MIN_SCREENSHOT_PIXEL_DIMENSION = 64
MAX_SCREENSHOT_PIXEL_DIMENSION = 32_768
LOADER_MAX_SAMPLE_GAP_NS = 50_000_000
LOADER_MIN_OBSERVATION_NS = 100_000_000
HARD_MIN_AUDIO_DURATION_SECONDS = 0.25
HARD_MIN_AUDIO_RMS = 0.001
HARD_MIN_AUDIO_PEAK = 0.005
HARD_MIN_AUDIO_AC_RMS = 0.001
HARD_MIN_AUDIO_PEAK_TO_PEAK = 0.004
HARD_MIN_AUDIO_SAMPLE_MAGNITUDE = 0.0005
HARD_MIN_AUDIO_ACTIVE_SAMPLE_FRACTION = 0.20
HARD_AUDIO_WINDOW_SECONDS = 0.05
HARD_MAX_AUDIO_CAPTURE_PADDING_SECONDS = 0.05
HARD_MIN_ACTIVE_WINDOW_FRACTION = 0.80
HARD_MAX_CONSECUTIVE_INACTIVE_WINDOWS = 1
SUPPORTED_MEDIA_TYPES = {
    "application/json",
    "audio/wav",
    "image/png",
    "text/plain",
}
_EVIDENCE_ID_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}")
_IDENTIFIER_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._:-]{0,127}")
_SHA256_RE = re.compile(r"[0-9a-f]{64}")
_REFERENCE_FIELDS = {
    "schema",
    "evidence_id",
    "ref",
    "sha256",
    "byte_length",
    "media_type",
    "binding",
    "capture_started_monotonic_ns",
    "capture_ended_monotonic_ns",
}
_BINDING_FIELDS = {
    "run_id",
    "process_id",
    "process_start_abstime",
    "source_key",
    "asset_sha256",
    "candidate_id",
}
_PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"
_WINDOW_STATE_FIELDS = {
    "schema",
    "window_id",
    "owner_process_id",
    "owner_process_start_abstime",
    "display_id",
    "on_screen",
    "frontmost",
    "bounds",
    "backing_scale_factor",
    "sampled_monotonic_ns",
    "audit_token_sha256",
}
_RECT_FIELDS = {"x", "y", "width", "height"}
_WINDOW_CAPTURE_RECEIPT_FIELDS = {
    "schema",
    "binding",
    "receipt_id",
    "capture_nonce",
    "screen_capture_tool",
    "window_audit_tool",
    "audit_token_sha256",
    "window_id",
    "owner_process_id",
    "owner_process_start_abstime",
    "display_id",
    "window_bounds",
    "backing_scale_factor",
    "pixel_width",
    "pixel_height",
    "png_artifact",
    "window_state_artifact",
    "decoded_pixel_sha256",
    "capture_started_monotonic_ns",
    "capture_ended_monotonic_ns",
}
_AUDIO_PROVENANCE_FIELDS = {
    "schema",
    "binding",
    "provenance_id",
    "capture_nonce",
    "system_audio_capture_tool",
    "process_tap_tool",
    "capture_scope",
    "process_tap_id",
    "target_process_id",
    "target_process_start_abstime",
    "audit_token_sha256",
    "output_route_uid",
    "output_device_id",
    "output_route_active",
    "stream_sample_rate_hz",
    "stream_channels",
    "stream_frame_count",
    "first_sample_monotonic_ns",
    "last_sample_monotonic_ns",
    "output_latency_frames",
    "capture_started_monotonic_ns",
    "capture_ended_monotonic_ns",
    "wav_artifact",
}
_LOADER_INSPECTOR_RECEIPT_FIELDS = {
    "schema",
    "binding",
    "receipt_id",
    "capture_nonce",
    "audit_token_sha256",
    "loader_inspector_tool",
    "candidate_dylib",
    "route_selection_monotonic_ns",
    "pre_artifact",
    "post_artifact",
    "capture_started_monotonic_ns",
    "capture_ended_monotonic_ns",
}
_RETAINED_ARTIFACT_IDENTITY_FIELDS = {
    "evidence_id",
    "ref",
    "device",
    "inode",
    "mode",
    "uid",
    "gid",
    "nlink",
    "byte_length",
    "mtime_ns",
    "ctime_ns",
    "flags",
    "xattr_sha256",
    "sha256",
    "media_type",
    "capture_started_monotonic_ns",
    "capture_ended_monotonic_ns",
    "campaign_id",
}
_CANDIDATE_DYLIB_FIELDS = {
    "canonical_path",
    "device",
    "inode",
    "byte_length",
    "sha256",
}
_EXTERNAL_TRUST_INDEX_FIELDS = {
    "schema",
    "campaign_id",
    "binding",
    "capture_nonce",
    "audit_token_sha256",
    "tools",
    "receipt_sha256",
    "candidate_dylib",
}
_TRUSTED_TOOL_FIELDS = {
    "role",
    "process_id",
    "process_start_abstime",
    "executable_argv_sha256",
    "executable_path",
    "executable_device",
    "executable_inode",
    "executable_byte_length",
    "executable_sha256",
    "audit_token_sha256",
}
_TRUST_TOOL_ROLES = {
    "screen_capture",
    "window_audit",
    "loader_inspector",
    "system_audio_capture",
    "process_tap",
}
_TRUST_RECEIPT_ROLES = {
    "window_capture",
    "loader_inspector",
    "process_audio",
}
_ATTESTATION_SEAL = object()
_CAMPAIGN_LOCK = threading.Lock()
_CLAIMED_CAMPAIGN_IDS: set[str] = set()
_CLAIMED_ROOT_GENERATIONS: set[tuple[int, int, int]] = set()
_ACTIVE_ROOTS: set[tuple[int, int]] = set()


class RawEvidenceError(ValueError):
    """The retained evidence cannot safely support a shipping claim."""


def _positive_int(value: Any, label: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value <= 0:
        raise RawEvidenceError(f"{label} must be a positive integer")
    return value


def _nonnegative_int(value: Any, label: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        raise RawEvidenceError(f"{label} must be a non-negative integer")
    return value


def _canonical_run_id(value: Any, label: str = "run_id") -> str:
    if not isinstance(value, str):
        raise RawEvidenceError(f"{label} must be a canonical UUID")
    try:
        parsed = uuid.UUID(value)
    except (ValueError, AttributeError) as exc:
        raise RawEvidenceError(f"{label} must be a canonical UUID") from exc
    if str(parsed) != value:
        raise RawEvidenceError(f"{label} must be a canonical lowercase UUID")
    return value


def _bounded_identifier(value: Any, label: str) -> str:
    if not isinstance(value, str) or _IDENTIFIER_RE.fullmatch(value) is None:
        raise RawEvidenceError(f"{label} must be a canonical bounded identifier")
    return value


def _bounded_text(value: Any, label: str, *, limit: int = 512) -> str:
    if (
        not isinstance(value, str)
        or not value
        or len(value) > limit
        or "\x00" in value
        or any(ord(character) < 32 for character in value)
    ):
        raise RawEvidenceError(f"{label} must be non-empty bounded printable text")
    return value


def _sha256(value: Any, label: str) -> str:
    if not isinstance(value, str) or _SHA256_RE.fullmatch(value) is None:
        raise RawEvidenceError(f"{label} must be 64 lowercase hex digits")
    return value


def _exact_fields(value: Any, expected: set[str], label: str) -> Mapping[str, Any]:
    if not isinstance(value, Mapping):
        raise RawEvidenceError(f"{label} must be an object")
    try:
        fields = set(value)
    except (TypeError, ValueError) as exc:
        raise RawEvidenceError(f"{label} contains non-string/unhashable field names") from exc
    if fields != expected:
        try:
            missing = sorted(expected - fields)
            extra = sorted(fields - expected)
        except TypeError as exc:
            raise RawEvidenceError(f"{label} field names must all be strings") from exc
        raise RawEvidenceError(
            f"{label} fields are not exact (missing={missing}, extra={extra})"
        )
    return value


@dataclasses.dataclass(frozen=True, slots=True)
class EvidenceBinding:
    """Identity which every retained proof must match exactly."""

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
        if not isinstance(self.asset_sha256, str) or _SHA256_RE.fullmatch(
            self.asset_sha256
        ) is None:
            raise RawEvidenceError("asset_sha256 must be 64 lowercase hex digits")
        _bounded_identifier(self.candidate_id, "candidate_id")

    def as_dict(self) -> dict[str, Any]:
        return dataclasses.asdict(self)

    @classmethod
    def from_mapping(cls, value: Any) -> "EvidenceBinding":
        if not isinstance(value, Mapping):
            raise RawEvidenceError("evidence binding must be an object")
        fields = set(value)
        if fields != _BINDING_FIELDS:
            missing = sorted(_BINDING_FIELDS - fields)
            extra = sorted(fields - _BINDING_FIELDS)
            raise RawEvidenceError(
                f"evidence binding fields are not exact (missing={missing}, extra={extra})"
            )
        return cls(
            run_id=value["run_id"],
            process_id=value["process_id"],
            process_start_abstime=value["process_start_abstime"],
            source_key=value["source_key"],
            asset_sha256=value["asset_sha256"],
            candidate_id=value["candidate_id"],
        )


@dataclasses.dataclass(frozen=True, slots=True)
class CandidateDylibIdentity:
    canonical_path: str
    device: int
    inode: int
    byte_length: int
    sha256: str

    def __post_init__(self) -> None:
        _canonical_fallback_library_path(self.canonical_path)
        _positive_int(self.device, "candidate dylib device")
        _positive_int(self.inode, "candidate dylib inode")
        _positive_int(self.byte_length, "candidate dylib byte_length")
        _sha256(self.sha256, "candidate dylib sha256")

    def as_dict(self) -> dict[str, Any]:
        return dataclasses.asdict(self)

    @classmethod
    def from_mapping(cls, value: Any) -> "CandidateDylibIdentity":
        value = _exact_fields(value, _CANDIDATE_DYLIB_FIELDS, "candidate dylib identity")
        return cls(
            canonical_path=value["canonical_path"],
            device=value["device"],
            inode=value["inode"],
            byte_length=value["byte_length"],
            sha256=value["sha256"],
        )


@dataclasses.dataclass(frozen=True, slots=True)
class TrustedToolIdentity:
    role: str
    process_id: int
    process_start_abstime: int
    executable_argv_sha256: str
    executable_path: str
    executable_device: int
    executable_inode: int
    executable_byte_length: int
    executable_sha256: str
    audit_token_sha256: str

    def __post_init__(self) -> None:
        if self.role not in _TRUST_TOOL_ROLES:
            raise RawEvidenceError("trusted tool has an unsupported role")
        _positive_int(self.process_id, "trusted tool process_id")
        _positive_int(self.process_start_abstime, "trusted tool process_start_abstime")
        _sha256(self.executable_argv_sha256, "trusted tool executable argv sha256")
        if (
            not isinstance(self.executable_path, str)
            or not self.executable_path.startswith("/")
            or self.executable_path != os.path.normpath(self.executable_path)
            or "\x00" in self.executable_path
        ):
            raise RawEvidenceError("trusted tool executable path is not canonical absolute")
        _positive_int(self.executable_device, "trusted tool executable device")
        _positive_int(self.executable_inode, "trusted tool executable inode")
        _positive_int(
            self.executable_byte_length, "trusted tool executable byte_length"
        )
        _sha256(self.executable_sha256, "trusted tool executable sha256")
        _sha256(self.audit_token_sha256, "trusted tool audit-token sha256")

    def as_dict(self) -> dict[str, Any]:
        return dataclasses.asdict(self)

    @classmethod
    def from_mapping(cls, value: Any) -> "TrustedToolIdentity":
        value = _exact_fields(value, _TRUSTED_TOOL_FIELDS, "trusted tool identity")
        return cls(
            role=value["role"],
            process_id=value["process_id"],
            process_start_abstime=value["process_start_abstime"],
            executable_argv_sha256=value["executable_argv_sha256"],
            executable_path=value["executable_path"],
            executable_device=value["executable_device"],
            executable_inode=value["executable_inode"],
            executable_byte_length=value["executable_byte_length"],
            executable_sha256=value["executable_sha256"],
            audit_token_sha256=value["audit_token_sha256"],
        )


@dataclasses.dataclass(frozen=True, slots=True, init=False)
class ExternalAttestationCapability:
    """Opaque result of matching an external trust-index digest exactly."""

    campaign_id: str
    binding: EvidenceBinding
    capture_nonce: str
    audit_token_sha256: str
    tools: tuple[TrustedToolIdentity, ...]
    receipt_sha256: tuple[tuple[str, str], ...]
    candidate_dylib: CandidateDylibIdentity | None
    trust_index_sha256: str
    _seal: object = dataclasses.field(repr=False, compare=False)

    def __post_init__(self) -> None:
        if self._seal is not _ATTESTATION_SEAL:
            raise RawEvidenceError(
                "attestation capabilities can only come from a validated external trust index"
            )

    def tool(self, role: str) -> TrustedToolIdentity:
        values = {tool.role: tool for tool in self.tools}
        if role not in values:
            raise RawEvidenceError(f"external trust index lacks required tool role {role!r}")
        return values[role]

    def receipt_hash(self, role: str) -> str:
        values = dict(self.receipt_sha256)
        if role not in values:
            raise RawEvidenceError(
                f"external trust index lacks required receipt role {role!r}"
            )
        return values[role]


def _new_external_attestation_capability(
    *,
    campaign_id: str,
    binding: EvidenceBinding,
    capture_nonce: str,
    audit_token_sha256: str,
    tools: tuple[TrustedToolIdentity, ...],
    receipt_sha256: tuple[tuple[str, str], ...],
    candidate_dylib: CandidateDylibIdentity | None,
    trust_index_sha256: str,
) -> ExternalAttestationCapability:
    capability = object.__new__(ExternalAttestationCapability)
    values = {
        "campaign_id": campaign_id,
        "binding": binding,
        "capture_nonce": capture_nonce,
        "audit_token_sha256": audit_token_sha256,
        "tools": tools,
        "receipt_sha256": receipt_sha256,
        "candidate_dylib": candidate_dylib,
        "trust_index_sha256": trust_index_sha256,
        "_seal": _ATTESTATION_SEAL,
    }
    for field, value in values.items():
        object.__setattr__(capability, field, value)
    capability.__post_init__()
    return capability


@dataclasses.dataclass(frozen=True, slots=True)
class CaptureBounds:
    """Inclusive monotonic bounds authorized for one proof capture."""

    started_monotonic_ns: int
    ended_monotonic_ns: int

    def __post_init__(self) -> None:
        _positive_int(self.started_monotonic_ns, "capture bound start")
        _positive_int(self.ended_monotonic_ns, "capture bound end")
        if self.ended_monotonic_ns < self.started_monotonic_ns:
            raise RawEvidenceError("capture bounds run backwards")


@dataclasses.dataclass(frozen=True, slots=True)
class ValidatedEvidence:
    evidence_id: str
    relative_ref: str
    path: Path
    sha256: str
    byte_length: int
    media_type: str
    binding: EvidenceBinding
    capture_started_monotonic_ns: int
    capture_ended_monotonic_ns: int
    device: int
    inode: int
    mode: int
    uid: int
    gid: int
    nlink: int
    mtime_ns: int
    ctime_ns: int
    flags: int
    xattr_sha256: str
    campaign_id: str
    campaign_manifest_sha256: str
    data: bytes = dataclasses.field(repr=False)

    def identity_dict(self) -> dict[str, Any]:
        return {
            "schema": SCHEMA,
            "evidence_id": self.evidence_id,
            "ref": self.relative_ref,
            "sha256": self.sha256,
            "byte_length": self.byte_length,
            "media_type": self.media_type,
            "binding": self.binding.as_dict(),
            "capture_started_monotonic_ns": self.capture_started_monotonic_ns,
            "capture_ended_monotonic_ns": self.capture_ended_monotonic_ns,
            "device": self.device,
            "inode": self.inode,
            "mode": self.mode,
            "uid": self.uid,
            "gid": self.gid,
            "nlink": self.nlink,
            "mtime_ns": self.mtime_ns,
            "ctime_ns": self.ctime_ns,
            "flags": self.flags,
            "xattr_sha256": self.xattr_sha256,
            "campaign_id": self.campaign_id,
            "campaign_manifest_sha256": self.campaign_manifest_sha256,
        }

    def artifact_identity(self) -> dict[str, Any]:
        return {
            "evidence_id": self.evidence_id,
            "ref": self.relative_ref,
            "device": self.device,
            "inode": self.inode,
            "mode": self.mode,
            "uid": self.uid,
            "gid": self.gid,
            "nlink": self.nlink,
            "byte_length": self.byte_length,
            "mtime_ns": self.mtime_ns,
            "ctime_ns": self.ctime_ns,
            "flags": self.flags,
            "xattr_sha256": self.xattr_sha256,
            "sha256": self.sha256,
            "media_type": self.media_type,
            "capture_started_monotonic_ns": self.capture_started_monotonic_ns,
            "capture_ended_monotonic_ns": self.capture_ended_monotonic_ns,
            "campaign_id": self.campaign_id,
        }


def _relative_components(value: Any) -> tuple[str, ...]:
    if not isinstance(value, str) or not value or "\x00" in value:
        raise RawEvidenceError("evidence ref must be a non-empty relative path")
    if "\\" in value or value.startswith("/"):
        raise RawEvidenceError("evidence ref must be a canonical relative POSIX path")
    components = value.split("/")
    try:
        value.encode("utf-8", "strict")
    except UnicodeEncodeError as exc:
        raise RawEvidenceError("evidence ref must be valid UTF-8") from exc
    if any(
        component in {"", ".", ".."}
        or any(ord(character) < 32 for character in component)
        or unicodedata.normalize("NFC", component) != component
        for component in components
    ):
        raise RawEvidenceError("evidence ref cannot contain empty, dot, or parent parts")
    return tuple(components)


def _canonical_absolute_components(
    value: str | os.PathLike[str], label: str
) -> tuple[str, tuple[str, ...]]:
    try:
        raw_path = os.fspath(value)
    except TypeError as exc:
        raise RawEvidenceError(f"{label} must be a canonical absolute path") from exc
    if (
        not isinstance(raw_path, str)
        or not raw_path.startswith("/")
        or raw_path == "/"
        or "\x00" in raw_path
        or "\\" in raw_path
        or os.path.normpath(raw_path) != raw_path
    ):
        raise RawEvidenceError(f"{label} must be a canonical absolute path")
    try:
        raw_path.encode("utf-8", "strict")
    except UnicodeEncodeError as exc:
        raise RawEvidenceError(f"{label} must be valid UTF-8") from exc
    components = tuple(component for component in raw_path.split("/") if component)
    if any(
        component in {".", ".."}
        or any(ord(character) < 32 for character in component)
        or unicodedata.normalize("NFC", component) != component
        for component in components
    ):
        raise RawEvidenceError(f"{label} has a non-canonical path component")
    return raw_path, components


def _open_absolute_directory_nofollow(
    value: str | os.PathLike[str], label: str
) -> tuple[Path, int, os.stat_result]:
    """Open every absolute directory component without following a symlink."""

    canonical, components = _canonical_absolute_components(value, label)
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0)
    flags |= getattr(os, "O_DIRECTORY", 0)
    flags |= getattr(os, "O_NOFOLLOW", 0)
    current = -1
    try:
        current = os.open("/", flags)
        for component in components:
            child = os.open(component, flags, dir_fd=current)
            os.close(current)
            current = child
        observed = os.fstat(current)
        if not stat.S_ISDIR(observed.st_mode):
            raise RawEvidenceError(f"{label} is not a real directory")
        return Path(canonical), current, observed
    except RawEvidenceError:
        if current >= 0:
            os.close(current)
        raise
    except OSError as exc:
        if current >= 0:
            os.close(current)
        raise RawEvidenceError(
            f"{label} is missing or has a symlinked path component"
        ) from exc


def _stat_generation(observed: os.stat_result) -> tuple[int, ...]:
    return (
        observed.st_dev,
        observed.st_ino,
        observed.st_mode,
        observed.st_uid,
        observed.st_gid,
        observed.st_nlink,
        observed.st_size,
        observed.st_mtime_ns,
        observed.st_ctime_ns,
        int(getattr(observed, "st_flags", 0)),
    )


def _read_regular_beneath(
    root_fd: int,
    display_root: Path,
    components: Sequence[str],
) -> tuple[Path, bytes, os.stat_result, str]:
    """Open beneath one already-pinned root descriptor without following links."""

    directory_flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0)
    directory_flags |= getattr(os, "O_DIRECTORY", 0)
    directory_flags |= getattr(os, "O_NOFOLLOW", 0)
    file_flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0)
    file_flags |= getattr(os, "O_NOFOLLOW", 0)
    descriptors: list[int] = []
    try:
        current = os.dup(root_fd)
        descriptors.append(current)
        for component in components[:-1]:
            current = os.open(component, directory_flags, dir_fd=current)
            descriptors.append(current)
        file_fd = os.open(components[-1], file_flags, dir_fd=current)
        descriptors.append(file_fd)
        before = os.fstat(file_fd)
        if not stat.S_ISREG(before.st_mode):
            raise RawEvidenceError("evidence ref is not a regular file")
        if before.st_size > MAX_EVIDENCE_BYTES:
            raise RawEvidenceError("evidence file exceeds the retained-proof size limit")
        chunks: list[bytes] = []
        remaining = before.st_size
        while remaining:
            chunk = os.read(file_fd, min(1024 * 1024, remaining))
            if not chunk:
                raise RawEvidenceError("evidence file was truncated while reading")
            chunks.append(chunk)
            remaining -= len(chunk)
        if os.read(file_fd, 1):
            raise RawEvidenceError("evidence file grew while reading")
        after = os.fstat(file_fd)
        stable_fields = (
            "st_dev",
            "st_ino",
            "st_mode",
            "st_uid",
            "st_gid",
            "st_nlink",
            "st_size",
            "st_mtime_ns",
            "st_ctime_ns",
        )
        if any(getattr(before, field) != getattr(after, field) for field in stable_fields):
            raise RawEvidenceError("evidence file changed while reading")
        if int(getattr(before, "st_flags", 0)) != int(getattr(after, "st_flags", 0)):
            raise RawEvidenceError("evidence file flags changed while reading")
        return (
            display_root.joinpath(*components),
            b"".join(chunks),
            after,
            _xattr_digest_fd(file_fd),
        )
    except RawEvidenceError:
        raise
    except FileNotFoundError as exc:
        raise RawEvidenceError("evidence ref does not exist beneath campaign root") from exc
    except NotADirectoryError as exc:
        raise RawEvidenceError(
            "evidence ref is not a regular non-symlink path beneath campaign root"
        ) from exc
    except OSError as exc:
        raise RawEvidenceError(
            "evidence ref is not a regular non-symlink path beneath campaign root"
        ) from exc
    finally:
        for descriptor in reversed(descriptors):
            try:
                os.close(descriptor)
            except OSError:
                pass


@dataclasses.dataclass(frozen=True, slots=True)
class _ManifestEntry:
    relative_path: str
    kind: str
    device: int
    inode: int
    mode: int
    uid: int
    gid: int
    nlink: int
    byte_length: int
    mtime_ns: int
    ctime_ns: int
    flags: int
    xattr_sha256: str
    sha256: str | None

    def canonical_tuple(self) -> tuple[Any, ...]:
        return dataclasses.astuple(self)


def _entry_from_stat(
    relative_path: str,
    kind: str,
    observed: os.stat_result,
    xattr_sha256: str,
    sha256: str | None,
) -> _ManifestEntry:
    return _ManifestEntry(
        relative_path=relative_path,
        kind=kind,
        device=observed.st_dev,
        inode=observed.st_ino,
        mode=observed.st_mode,
        uid=observed.st_uid,
        gid=observed.st_gid,
        nlink=observed.st_nlink,
        byte_length=observed.st_size,
        mtime_ns=observed.st_mtime_ns,
        ctime_ns=observed.st_ctime_ns,
        flags=int(getattr(observed, "st_flags", 0)),
        xattr_sha256=xattr_sha256,
        sha256=sha256,
    )


def _xattr_digest_fd(descriptor: int) -> str:
    library = ctypes.CDLL(None, use_errno=True)
    if sys.platform != "darwin":
        raise RawEvidenceError("xattr proof is only implemented for the macOS shipper")
    library.flistxattr.argtypes = [
        ctypes.c_int,
        ctypes.c_void_p,
        ctypes.c_size_t,
        ctypes.c_int,
    ]
    library.flistxattr.restype = ctypes.c_ssize_t
    ctypes.set_errno(0)
    names_size = library.flistxattr(descriptor, None, 0, 0)
    if names_size < 0:
        raise RawEvidenceError("campaign entry xattrs could not be inspected")
    names_buffer = ctypes.create_string_buffer(names_size) if names_size else None
    if names_size and library.flistxattr(descriptor, names_buffer, names_size, 0) != names_size:
        raise RawEvidenceError("campaign entry xattrs changed during inspection")
    raw_names = names_buffer.raw if names_buffer is not None else b""
    try:
        names = sorted(
            item.decode("utf-8", "strict")
            for item in raw_names.rstrip(b"\0").split(b"\0")
            if item
        )
    except UnicodeDecodeError as exc:
        raise RawEvidenceError("campaign entry has a non-UTF-8 xattr name") from exc
    if any(name == "com.apple.acl.text" or name.startswith("system.posix_acl_") for name in names):
        raise RawEvidenceError("campaign entries with ACL metadata are not eligible")
    library.fgetxattr.argtypes = [
        ctypes.c_int,
        ctypes.c_char_p,
        ctypes.c_void_p,
        ctypes.c_size_t,
        ctypes.c_uint32,
        ctypes.c_int,
    ]
    library.fgetxattr.restype = ctypes.c_ssize_t
    digest = hashlib.sha256()
    for name in names:
        encoded_name = name.encode("utf-8", "strict")
        ctypes.set_errno(0)
        value_size = library.fgetxattr(
            descriptor, encoded_name, None, 0, 0, 0
        )
        if value_size < 0:
            raise RawEvidenceError("campaign entry xattrs changed during inspection")
        value_buffer = ctypes.create_string_buffer(value_size) if value_size else None
        if value_size and library.fgetxattr(
            descriptor,
            encoded_name,
            value_buffer,
            value_size,
            0,
            0,
        ) != value_size:
            raise RawEvidenceError("campaign entry xattrs changed during inspection")
        value = value_buffer.raw if value_buffer is not None else b""
        digest.update(struct.pack(">I", len(encoded_name)))
        digest.update(encoded_name)
        digest.update(struct.pack(">Q", len(value)))
        digest.update(value)
    return digest.hexdigest()


def _reject_acl_fd(descriptor: int) -> None:
    if sys.platform != "darwin":
        raise RawEvidenceError("ACL proof is only implemented for the macOS shipper")
    library = ctypes.CDLL(None, use_errno=True)
    library.acl_get_fd_np.argtypes = [ctypes.c_int, ctypes.c_int]
    library.acl_get_fd_np.restype = ctypes.c_void_p
    library.acl_free.argtypes = [ctypes.c_void_p]
    library.acl_free.restype = ctypes.c_int
    ctypes.set_errno(0)
    acl = library.acl_get_fd_np(descriptor, 0x00000100)
    if acl:
        library.acl_free(acl)
        raise RawEvidenceError("campaign entries with extended ACLs are not eligible")
    observed_errno = ctypes.get_errno()
    if observed_errno not in {0, errno.ENOENT}:
        raise RawEvidenceError("campaign entry ACL could not be inspected")


def _hash_regular_fd(file_fd: int, before: os.stat_result) -> str:
    if before.st_size > MAX_EVIDENCE_BYTES:
        raise RawEvidenceError("campaign manifest contains an oversized evidence file")
    digest = hashlib.sha256()
    remaining = before.st_size
    while remaining:
        chunk = os.read(file_fd, min(1024 * 1024, remaining))
        if not chunk:
            raise RawEvidenceError("campaign file was truncated while sealing manifest")
        digest.update(chunk)
        remaining -= len(chunk)
    if os.read(file_fd, 1):
        raise RawEvidenceError("campaign file grew while sealing manifest")
    after = os.fstat(file_fd)
    stable_fields = (
        "st_dev",
        "st_ino",
        "st_mode",
        "st_uid",
        "st_gid",
        "st_nlink",
        "st_size",
        "st_mtime_ns",
        "st_ctime_ns",
    )
    if any(getattr(before, field) != getattr(after, field) for field in stable_fields):
        raise RawEvidenceError("campaign file changed while sealing manifest")
    if int(getattr(before, "st_flags", 0)) != int(getattr(after, "st_flags", 0)):
        raise RawEvidenceError("campaign file flags changed while sealing manifest")
    return digest.hexdigest()


def _scan_campaign_tree(root_fd: int) -> tuple[_ManifestEntry, ...]:
    """Return a complete no-follow identity/hash snapshot below a pinned root."""

    directory_flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0)
    directory_flags |= getattr(os, "O_DIRECTORY", 0)
    directory_flags |= getattr(os, "O_NOFOLLOW", 0)
    file_flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0)
    file_flags |= getattr(os, "O_NOFOLLOW", 0)
    entries: list[_ManifestEntry] = []
    seen_inodes: set[tuple[int, int]] = set()

    def visit(directory_fd: int, relative_path: str) -> None:
        directory_stat = os.fstat(directory_fd)
        _reject_acl_fd(directory_fd)
        entries.append(
            _entry_from_stat(
                relative_path,
                "directory",
                directory_stat,
                _xattr_digest_fd(directory_fd),
                None,
            )
        )
        try:
            names = sorted(os.listdir(directory_fd))
        except OSError as exc:
            raise RawEvidenceError("campaign directory could not be enumerated") from exc
        for name in names:
            try:
                name.encode("utf-8", "strict")
            except UnicodeEncodeError as exc:
                raise RawEvidenceError(
                    "campaign contains a non-UTF-8 directory entry"
                ) from exc
            if (
                not name
                or name in {".", ".."}
                or "/" in name
                or "\\" in name
                or "\x00" in name
                or any(ord(character) < 32 for character in name)
                or unicodedata.normalize("NFC", name) != name
            ):
                raise RawEvidenceError("campaign contains a non-canonical directory entry")
            child_path = name if not relative_path else f"{relative_path}/{name}"
            try:
                observed = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
            except OSError as exc:
                raise RawEvidenceError("campaign entry changed during manifest scan") from exc
            if stat.S_ISDIR(observed.st_mode):
                try:
                    child_fd = os.open(name, directory_flags, dir_fd=directory_fd)
                except OSError as exc:
                    raise RawEvidenceError(
                        "campaign directory is not a stable non-symlink"
                    ) from exc
                try:
                    opened_directory = os.fstat(child_fd)
                    if (opened_directory.st_dev, opened_directory.st_ino) != (
                        observed.st_dev,
                        observed.st_ino,
                    ):
                        raise RawEvidenceError(
                            "campaign directory changed during manifest scan"
                        )
                    visit(child_fd, child_path)
                finally:
                    os.close(child_fd)
            elif stat.S_ISREG(observed.st_mode):
                if observed.st_nlink != 1:
                    raise RawEvidenceError(
                        "campaign manifest rejects hard-linked evidence aliases"
                    )
                inode_key = (observed.st_dev, observed.st_ino)
                if inode_key in seen_inodes:
                    raise RawEvidenceError(
                        "campaign manifest contains duplicate evidence inode aliases"
                    )
                seen_inodes.add(inode_key)
                try:
                    file_fd = os.open(name, file_flags, dir_fd=directory_fd)
                except OSError as exc:
                    raise RawEvidenceError(
                        "campaign file is not a stable non-symlink"
                    ) from exc
                try:
                    opened = os.fstat(file_fd)
                    if (opened.st_dev, opened.st_ino) != inode_key:
                        raise RawEvidenceError(
                            "campaign file changed during manifest scan"
                        )
                    _reject_acl_fd(file_fd)
                    digest = _hash_regular_fd(file_fd, opened)
                    entries.append(
                        _entry_from_stat(
                            child_path,
                            "regular",
                            opened,
                            _xattr_digest_fd(file_fd),
                            digest,
                        )
                    )
                finally:
                    os.close(file_fd)
            else:
                raise RawEvidenceError(
                    "campaign manifest permits only real directories and regular files"
                )
            if len(entries) > MAX_CAMPAIGN_ENTRIES:
                raise RawEvidenceError("campaign manifest exceeds its entry limit")

    pinned_root_copy = os.dup(root_fd)
    try:
        visit(pinned_root_copy, "")
    finally:
        os.close(pinned_root_copy)
    return tuple(sorted(entries, key=lambda entry: entry.relative_path))


def _manifest_digest(campaign_id: str, entries: Sequence[_ManifestEntry]) -> str:
    canonical = json.dumps(
        {
            "campaign_id": _canonical_run_id(campaign_id, "manifest campaign_id"),
            "entries": [entry.canonical_tuple() for entry in entries],
        },
        ensure_ascii=True,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("ascii")
    return hashlib.sha256(canonical).hexdigest()


def _decode_text(data: bytes) -> str:
    try:
        value = data.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise RawEvidenceError("text evidence is not valid UTF-8") from exc
    if any(ord(character) < 32 and character not in "\t\r\n" for character in value):
        raise RawEvidenceError("text evidence contains binary control bytes")
    return value


def _detect_media_type(data: bytes) -> str:
    if data.startswith(_PNG_SIGNATURE):
        return "image/png"
    if len(data) >= 12 and data[:4] == b"RIFF" and data[8:12] == b"WAVE":
        return "audio/wav"
    try:
        text = _decode_text(data)
    except RawEvidenceError:
        return "application/octet-stream"
    try:
        json.loads(text)
    except (json.JSONDecodeError, RecursionError):
        return "text/plain"
    return "application/json"


class EvidenceRegistry:
    """Validate references below one immutable, descriptor-pinned campaign root."""

    def __init__(
        self,
        campaign_root: str | os.PathLike[str],
        *,
        campaign_id: str,
    ) -> None:
        self.campaign_id = _canonical_run_id(campaign_id, "campaign_id")
        try:
            self.campaign_root, self._root_fd, pinned = (
                _open_absolute_directory_nofollow(campaign_root, "campaign root")
            )
            _reject_acl_fd(self._root_fd)
            self._root_xattr_sha256 = _xattr_digest_fd(self._root_fd)
        except Exception:
            if getattr(self, "_root_fd", -1) >= 0:
                os.close(self._root_fd)
                self._root_fd = -1
            raise
        self._root_identity = _stat_generation(pinned)
        root_generation = (
            pinned.st_dev,
            pinned.st_ino,
            pinned.st_ctime_ns,
        )
        root_key = (pinned.st_dev, pinned.st_ino)
        with _CAMPAIGN_LOCK:
            if self.campaign_id in _CLAIMED_CAMPAIGN_IDS:
                os.close(self._root_fd)
                self._root_fd = -1
                raise RawEvidenceError(
                    "campaign_id already has a registry in this verifier process"
                )
            if root_key in _ACTIVE_ROOTS or root_generation in _CLAIMED_ROOT_GENERATIONS:
                os.close(self._root_fd)
                self._root_fd = -1
                raise RawEvidenceError(
                    "campaign root generation already has a registry in this verifier process"
                )
            _CLAIMED_CAMPAIGN_IDS.add(self.campaign_id)
            _CLAIMED_ROOT_GENERATIONS.add(root_generation)
            _ACTIVE_ROOTS.add(root_key)
        self._root_key = root_key
        self._manifest: tuple[_ManifestEntry, ...] | None = None
        self._manifest_by_ref: dict[str, _ManifestEntry] = {}
        self._manifest_sha256: str | None = None
        self._evidence_ids: set[str] = set()
        self._refs: set[str] = set()
        self._evidence_inodes: set[tuple[int, int]] = set()
        self._registry_lock = threading.RLock()

    @property
    def manifest_sha256(self) -> str:
        if self._manifest_sha256 is None:
            raise RawEvidenceError("campaign manifest has not been sealed")
        return self._manifest_sha256

    def seal_campaign(self) -> dict[str, Any]:
        """Seal the complete retained tree once; no later generation is accepted."""

        with self._registry_lock:
            self._assert_root_pinned()
            if self._manifest is not None:
                self._assert_manifest_unchanged()
            else:
                first_manifest = _scan_campaign_tree(self._root_fd)
                manifest = _scan_campaign_tree(self._root_fd)
                if first_manifest != manifest:
                    raise RawEvidenceError(
                        "campaign manifest generation changed while it was being sealed"
                    )
                self._manifest = manifest
                self._manifest_by_ref = {
                    entry.relative_path: entry
                    for entry in manifest
                    if entry.kind == "regular"
                }
                self._manifest_sha256 = _manifest_digest(self.campaign_id, manifest)
        return {
            "campaign_id": self.campaign_id,
            "campaign_root": str(self.campaign_root),
            "root_device": self._root_identity[0],
            "root_inode": self._root_identity[1],
            "entry_count": len(self._manifest),
            "manifest_sha256": self.manifest_sha256,
        }

    def _assert_manifest_unchanged(self) -> None:
        if self._manifest is None:
            raise RawEvidenceError("campaign manifest must be sealed before validation")
        self._assert_root_pinned()
        current = _scan_campaign_tree(self._root_fd)
        if (
            current != self._manifest
            or _manifest_digest(self.campaign_id, current) != self.manifest_sha256
        ):
            raise RawEvidenceError(
                "campaign manifest generation changed after it was sealed"
            )

    def close(self) -> None:
        if getattr(self, "_root_fd", -1) >= 0:
            os.close(self._root_fd)
            self._root_fd = -1
            if hasattr(self, "_root_key"):
                with _CAMPAIGN_LOCK:
                    _ACTIVE_ROOTS.discard(self._root_key)

    def __enter__(self) -> "EvidenceRegistry":
        return self

    def __exit__(self, *_: Any) -> None:
        self.close()

    def __del__(self) -> None:
        try:
            self.close()
        except (AttributeError, OSError):
            pass

    def _assert_root_pinned(self) -> None:
        if self._root_fd < 0:
            raise RawEvidenceError("campaign root registry is closed")
        reopened_fd = -1
        try:
            pinned = os.fstat(self._root_fd)
            _, reopened_fd, current = _open_absolute_directory_nofollow(
                self.campaign_root, "campaign root path"
            )
            _reject_acl_fd(reopened_fd)
            current_xattr_sha256 = _xattr_digest_fd(reopened_fd)
        except (OSError, RawEvidenceError) as exc:
            raise RawEvidenceError(
                "campaign root path no longer names the pinned root"
            ) from exc
        finally:
            if reopened_fd >= 0:
                os.close(reopened_fd)
        if (
            _stat_generation(current) != self._root_identity
            or _stat_generation(pinned) != self._root_identity
            or current_xattr_sha256 != self._root_xattr_sha256
        ):
            raise RawEvidenceError("campaign root was replaced or changed after pinning")

    def assert_campaign_unchanged(self) -> None:
        """Revalidate the sealed tree immediately before consuming a proof result."""

        with self._registry_lock:
            self._assert_manifest_unchanged()

    def _validate_unregistered(
        self,
        reference: Any,
        *,
        expected_binding: EvidenceBinding,
        expected_media_type: str,
        allowed_capture_bounds: CaptureBounds,
    ) -> ValidatedEvidence:
        if self._manifest is None:
            raise RawEvidenceError(
                "campaign manifest must be explicitly sealed after capture"
            )
        self._assert_manifest_unchanged()
        if not isinstance(reference, Mapping):
            raise RawEvidenceError("raw evidence reference must be an object")
        fields = set(reference)
        if fields != _REFERENCE_FIELDS:
            missing = sorted(_REFERENCE_FIELDS - fields)
            extra = sorted(fields - _REFERENCE_FIELDS)
            raise RawEvidenceError(
                f"raw evidence reference fields are not exact (missing={missing}, extra={extra})"
            )
        if reference["schema"] != SCHEMA:
            raise RawEvidenceError("raw evidence reference schema is unsupported")
        evidence_id = reference["evidence_id"]
        if not isinstance(evidence_id, str) or _EVIDENCE_ID_RE.fullmatch(
            evidence_id
        ) is None:
            raise RawEvidenceError("evidence_id is not canonical")
        components = _relative_components(reference["ref"])
        relative_ref = "/".join(components)
        declared_sha256 = reference["sha256"]
        if not isinstance(declared_sha256, str) or _SHA256_RE.fullmatch(
            declared_sha256
        ) is None:
            raise RawEvidenceError("evidence sha256 must be 64 lowercase hex digits")
        declared_size = _nonnegative_int(reference["byte_length"], "byte_length")
        declared_media_type = reference["media_type"]
        if (
            expected_media_type not in SUPPORTED_MEDIA_TYPES
            or declared_media_type != expected_media_type
        ):
            raise RawEvidenceError("evidence media type does not match the required proof")
        observed_binding = EvidenceBinding.from_mapping(reference["binding"])
        if observed_binding != expected_binding:
            raise RawEvidenceError("evidence binding does not match the exact run identity")
        capture_start = _positive_int(
            reference["capture_started_monotonic_ns"], "capture start"
        )
        capture_end = _positive_int(
            reference["capture_ended_monotonic_ns"], "capture end"
        )
        if capture_end < capture_start:
            raise RawEvidenceError("evidence capture interval runs backwards")
        if (
            capture_start < allowed_capture_bounds.started_monotonic_ns
            or capture_end > allowed_capture_bounds.ended_monotonic_ns
        ):
            raise RawEvidenceError("evidence capture interval is outside authorized bounds")

        manifest_entry = self._manifest_by_ref.get(relative_ref)
        if manifest_entry is None:
            raise RawEvidenceError("evidence ref is absent from the sealed campaign manifest")
        path, data, observed_stat, observed_xattr_sha256 = _read_regular_beneath(
            self._root_fd, self.campaign_root, components
        )
        observed_entry = _entry_from_stat(
            relative_ref,
            "regular",
            observed_stat,
            observed_xattr_sha256,
            hashlib.sha256(data).hexdigest(),
        )
        if observed_entry != manifest_entry:
            raise RawEvidenceError(
                "evidence leaf generation differs from the sealed campaign manifest"
            )
        self._assert_manifest_unchanged()
        if len(data) != declared_size:
            raise RawEvidenceError("evidence byte length does not match retained bytes")
        observed_sha256 = hashlib.sha256(data).hexdigest()
        if observed_sha256 != declared_sha256:
            raise RawEvidenceError("evidence sha256 does not match retained bytes")
        observed_media_type = _detect_media_type(data)
        if observed_media_type != expected_media_type:
            raise RawEvidenceError(
                f"retained bytes are {observed_media_type}, not {expected_media_type}"
            )
        return ValidatedEvidence(
            evidence_id=evidence_id,
            relative_ref=relative_ref,
            path=path,
            sha256=observed_sha256,
            byte_length=len(data),
            media_type=observed_media_type,
            binding=observed_binding,
            capture_started_monotonic_ns=capture_start,
            capture_ended_monotonic_ns=capture_end,
            device=observed_stat.st_dev,
            inode=observed_stat.st_ino,
            mode=observed_stat.st_mode,
            uid=observed_stat.st_uid,
            gid=observed_stat.st_gid,
            nlink=observed_stat.st_nlink,
            mtime_ns=observed_stat.st_mtime_ns,
            ctime_ns=observed_stat.st_ctime_ns,
            flags=int(getattr(observed_stat, "st_flags", 0)),
            xattr_sha256=observed_xattr_sha256,
            campaign_id=self.campaign_id,
            campaign_manifest_sha256=self.manifest_sha256,
            data=data,
        )

    def _register_many(self, evidence: Sequence[ValidatedEvidence]) -> None:
        with self._registry_lock:
            id_keys = [item.evidence_id for item in evidence]
            ref_keys = [item.relative_ref for item in evidence]
            inode_keys = [(item.device, item.inode) for item in evidence]
            if len(set(id_keys)) != len(id_keys) or any(
                key in self._evidence_ids for key in id_keys
            ):
                raise RawEvidenceError("evidence_id was reused within the campaign")
            if len(set(ref_keys)) != len(ref_keys) or any(
                key in self._refs for key in ref_keys
            ):
                raise RawEvidenceError("evidence ref was reused within the campaign")
            if len(set(inode_keys)) != len(inode_keys) or any(
                key in self._evidence_inodes for key in inode_keys
            ):
                raise RawEvidenceError("evidence inode was reused within the campaign")
            self._evidence_ids.update(id_keys)
            self._refs.update(ref_keys)
            self._evidence_inodes.update(inode_keys)

    def validate_reference(
        self,
        reference: Any,
        *,
        expected_binding: EvidenceBinding,
        expected_media_type: str,
        allowed_capture_bounds: CaptureBounds,
    ) -> ValidatedEvidence:
        validated = self._validate_unregistered(
            reference,
            expected_binding=expected_binding,
            expected_media_type=expected_media_type,
            allowed_capture_bounds=allowed_capture_bounds,
        )
        self._register_many((validated,))
        self.assert_campaign_unchanged()
        return validated


def _parse_json_object(data: bytes, label: str) -> Mapping[str, Any]:
    def reject_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
        value: dict[str, Any] = {}
        for key, item in pairs:
            if key in value:
                raise RawEvidenceError(f"{label} contains duplicate JSON key {key!r}")
            value[key] = item
        return value

    try:
        parsed = json.loads(_decode_text(data), object_pairs_hook=reject_duplicate_keys)
    except json.JSONDecodeError as exc:
        raise RawEvidenceError(f"{label} is not valid JSON") from exc
    if not isinstance(parsed, Mapping):
        raise RawEvidenceError(f"{label} must contain one JSON object")
    return parsed


def _canonical_json_bytes(value: Any) -> bytes:
    try:
        return (
            json.dumps(
                value,
                ensure_ascii=True,
                allow_nan=False,
                sort_keys=True,
                separators=(",", ":"),
            )
            + "\n"
        ).encode("ascii")
    except (TypeError, ValueError, UnicodeError) as exc:
        raise RawEvidenceError("trust data cannot be canonically encoded") from exc


def make_external_trust_index_bytes(
    *,
    campaign_id: str,
    binding: EvidenceBinding,
    capture_nonce: str,
    audit_token_sha256: str,
    tools: Sequence[TrustedToolIdentity],
    receipt_sha256: Mapping[str, str],
    candidate_dylib: CandidateDylibIdentity | None = None,
) -> bytes:
    """Encode an integrity-only trust index; this does not authenticate it."""

    _canonical_run_id(campaign_id, "campaign_id")
    if not isinstance(binding, EvidenceBinding):
        raise RawEvidenceError("trust index requires an exact EvidenceBinding")
    nonce = _sha256(capture_nonce, "trust-index capture nonce")
    audit_hash = _sha256(audit_token_sha256, "trust-index audit-token sha256")
    parsed_tools = tuple(tools)
    if not parsed_tools or any(not isinstance(tool, TrustedToolIdentity) for tool in parsed_tools):
        raise RawEvidenceError("trust index requires trusted tool identities")
    roles = [tool.role for tool in parsed_tools]
    if len(set(roles)) != len(roles) or roles != sorted(roles):
        raise RawEvidenceError("trust-index tools must be unique and canonically ordered")
    if not isinstance(receipt_sha256, Mapping) or not receipt_sha256:
        raise RawEvidenceError("trust index requires externally sealed receipt hashes")
    receipt_values: dict[str, str] = {}
    for role, digest in receipt_sha256.items():
        if role not in _TRUST_RECEIPT_ROLES:
            raise RawEvidenceError("trust index contains an unsupported receipt role")
        receipt_values[role] = _sha256(digest, f"{role} receipt sha256")
    return _canonical_json_bytes(
        {
            "schema": EXTERNAL_TRUST_INDEX_SCHEMA,
            "campaign_id": campaign_id,
            "binding": binding.as_dict(),
            "capture_nonce": nonce,
            "audit_token_sha256": audit_hash,
            "tools": [tool.as_dict() for tool in parsed_tools],
            "receipt_sha256": dict(sorted(receipt_values.items())),
            "candidate_dylib": (
                candidate_dylib.as_dict() if candidate_dylib is not None else None
            ),
        }
    )


def validate_external_trust_index(
    index_bytes: bytes,
    *,
    expected_index_sha256: str,
    expected_campaign_id: str,
    expected_binding: EvidenceBinding,
) -> ExternalAttestationCapability:
    """Authenticate canonical index bytes against an independently supplied digest."""

    if not isinstance(index_bytes, bytes) or not index_bytes:
        raise RawEvidenceError("external trust index must be retained bytes")
    expected_digest = _sha256(expected_index_sha256, "expected trust-index sha256")
    observed_digest = hashlib.sha256(index_bytes).hexdigest()
    if observed_digest != expected_digest:
        raise RawEvidenceError("external trust index does not match its trust-anchor digest")
    value = _parse_json_object(index_bytes, "external trust index")
    value = _exact_fields(value, _EXTERNAL_TRUST_INDEX_FIELDS, "external trust index")
    if index_bytes != _canonical_json_bytes(value):
        raise RawEvidenceError("external trust index is not canonical JSON bytes")
    if value["schema"] != EXTERNAL_TRUST_INDEX_SCHEMA:
        raise RawEvidenceError("external trust index schema is unsupported")
    campaign_id = _canonical_run_id(value["campaign_id"], "trust-index campaign_id")
    if campaign_id != _canonical_run_id(expected_campaign_id, "expected campaign_id"):
        raise RawEvidenceError("external trust index names a different campaign")
    binding = EvidenceBinding.from_mapping(value["binding"])
    if not isinstance(expected_binding, EvidenceBinding) or binding != expected_binding:
        raise RawEvidenceError("external trust index names a different evidence binding")
    capture_nonce = _sha256(value["capture_nonce"], "trust-index capture nonce")
    audit_hash = _sha256(
        value["audit_token_sha256"], "trust-index audit-token sha256"
    )
    raw_tools = value["tools"]
    if isinstance(raw_tools, (str, bytes)) or not isinstance(raw_tools, Sequence):
        raise RawEvidenceError("external trust-index tools must be an array")
    tools = tuple(TrustedToolIdentity.from_mapping(tool) for tool in raw_tools)
    roles = [tool.role for tool in tools]
    if not tools or len(set(roles)) != len(roles) or roles != sorted(roles):
        raise RawEvidenceError("external trust-index tools are not unique/canonical")
    raw_receipts = value["receipt_sha256"]
    if not isinstance(raw_receipts, Mapping) or not raw_receipts:
        raise RawEvidenceError("external trust index has no receipt hashes")
    receipt_values: list[tuple[str, str]] = []
    for role, digest in raw_receipts.items():
        if role not in _TRUST_RECEIPT_ROLES:
            raise RawEvidenceError("external trust index has an unsupported receipt role")
        receipt_values.append((role, _sha256(digest, f"{role} receipt sha256")))
    if [role for role, _ in receipt_values] != sorted(role for role, _ in receipt_values):
        raise RawEvidenceError("external trust-index receipt roles are not canonical")
    candidate = (
        None
        if value["candidate_dylib"] is None
        else CandidateDylibIdentity.from_mapping(value["candidate_dylib"])
    )
    return _new_external_attestation_capability(
        campaign_id=campaign_id,
        binding=binding,
        capture_nonce=capture_nonce,
        audit_token_sha256=audit_hash,
        tools=tools,
        receipt_sha256=tuple(receipt_values),
        candidate_dylib=candidate,
        trust_index_sha256=observed_digest,
    )


def _require_capability(
    registry: EvidenceRegistry,
    binding: EvidenceBinding,
    attestation: ExternalAttestationCapability,
) -> None:
    if (
        not isinstance(attestation, ExternalAttestationCapability)
        or getattr(attestation, "_seal", None) is not _ATTESTATION_SEAL
    ):
        raise RawEvidenceError(
            "an externally authenticated attestation capability is required"
        )
    if attestation.campaign_id != registry.campaign_id:
        raise RawEvidenceError("attestation capability belongs to a different campaign")
    if attestation.binding != binding:
        raise RawEvidenceError("attestation capability belongs to a different run binding")


def _require_attestation(
    registry: EvidenceRegistry,
    binding: EvidenceBinding,
    attestation: ExternalAttestationCapability,
    *,
    receipt_role: str,
    receipt_evidence: ValidatedEvidence,
) -> None:
    _require_capability(registry, binding, attestation)
    if receipt_evidence.sha256 != attestation.receipt_hash(receipt_role):
        raise RawEvidenceError(
            "producer receipt does not match the externally authenticated trust index"
        )


def _require_tool(
    raw_tool: Any,
    attestation: ExternalAttestationCapability,
    role: str,
) -> TrustedToolIdentity:
    observed = TrustedToolIdentity.from_mapping(raw_tool)
    expected = attestation.tool(role)
    if observed != expected or observed.role != role:
        raise RawEvidenceError(f"producer receipt does not match trusted {role} identity")
    current = capture_trusted_tool_identity(
        role=expected.role,
        process_id=expected.process_id,
        process_start_abstime=expected.process_start_abstime,
        executable_argv_sha256=expected.executable_argv_sha256,
        executable_path=expected.executable_path,
        audit_token_sha256=expected.audit_token_sha256,
    )
    if current != expected:
        raise RawEvidenceError(f"trusted {role} executable generation changed")
    return observed


def _require_artifact_identity(raw: Any, evidence: ValidatedEvidence, label: str) -> None:
    raw = _exact_fields(raw, _RETAINED_ARTIFACT_IDENTITY_FIELDS, label)
    if dict(raw) != evidence.artifact_identity():
        raise RawEvidenceError(f"{label} does not bind the exact retained artifact generation")


@dataclasses.dataclass(frozen=True, slots=True)
class _DecodedPng:
    width: int
    height: int
    color_type: int
    bytes_per_pixel: int
    decoded_pixel_sha256: str
    nontransparent_pixels: int


def _paeth_predictor(left: int, above: int, upper_left: int) -> int:
    prediction = left + above - upper_left
    left_distance = abs(prediction - left)
    above_distance = abs(prediction - above)
    upper_left_distance = abs(prediction - upper_left)
    if left_distance <= above_distance and left_distance <= upper_left_distance:
        return left
    if above_distance <= upper_left_distance:
        return above
    return upper_left


def _parse_png(data: bytes) -> _DecodedPng:
    """Decode one bounded 8-bit RGB/RGBA screenshot through PNG filtering."""

    if not data.startswith(_PNG_SIGNATURE):
        raise RawEvidenceError("screen proof does not retain the PNG signature")
    cursor = len(_PNG_SIGNATURE)
    saw_ihdr = False
    saw_idat = False
    saw_iend = False
    ended_idat = False
    width = 0
    height = 0
    color_type = -1
    idat_parts: list[bytes] = []
    while cursor < len(data):
        if len(data) - cursor < 12:
            raise RawEvidenceError("screen PNG has a truncated chunk header")
        chunk_length = struct.unpack_from(">I", data, cursor)[0]
        chunk_type = data[cursor + 4 : cursor + 8]
        payload_start = cursor + 8
        payload_end = payload_start + chunk_length
        chunk_end = payload_end + 4
        if chunk_end > len(data):
            raise RawEvidenceError("screen PNG has a truncated chunk payload")
        payload = data[payload_start:payload_end]
        if re.fullmatch(rb"[A-Za-z]{4}", chunk_type) is None or not (
            65 <= chunk_type[2] <= 90
        ):
            raise RawEvidenceError("screen PNG has an invalid chunk type")
        declared_crc = struct.unpack_from(">I", data, payload_end)[0]
        if (zlib.crc32(chunk_type + payload) & 0xFFFFFFFF) != declared_crc:
            raise RawEvidenceError("screen PNG has a corrupt chunk CRC")
        if not saw_ihdr:
            if chunk_type != b"IHDR" or chunk_length != 13:
                raise RawEvidenceError("screen PNG does not begin with an exact IHDR")
            width, height, bit_depth, color_type, compression, filtering, interlace = (
                struct.unpack(">IIBBBBB", payload)
            )
            if (
                width < MIN_SCREENSHOT_PIXEL_DIMENSION
                or height < MIN_SCREENSHOT_PIXEL_DIMENSION
                or width > MAX_SCREENSHOT_PIXEL_DIMENSION
                or height > MAX_SCREENSHOT_PIXEL_DIMENSION
                or bit_depth != 8
                or color_type not in {2, 6}
                or compression != 0
                or filtering != 0
                or interlace != 0
            ):
                raise RawEvidenceError(
                    "screen PNG IHDR is not a bounded non-interlaced RGB/RGBA capture"
                )
            saw_ihdr = True
        elif chunk_type == b"IHDR":
            raise RawEvidenceError("screen PNG contains multiple IHDR chunks")
        if chunk_type == b"IDAT":
            if ended_idat:
                raise RawEvidenceError("screen PNG has non-consecutive IDAT chunks")
            if chunk_length == 0:
                raise RawEvidenceError("screen PNG contains an empty IDAT")
            saw_idat = True
            idat_parts.append(payload)
        elif saw_idat and chunk_type != b"IEND":
            ended_idat = True
        if chunk_type not in {b"IHDR", b"IDAT", b"IEND", b"PLTE"} and (
            chunk_type[0] & 0x20
        ) == 0:
            raise RawEvidenceError("screen PNG contains an unsupported critical chunk")
        if chunk_type == b"PLTE" and (saw_idat or chunk_length == 0 or chunk_length % 3):
            raise RawEvidenceError("screen PNG PLTE chunk is invalid or misplaced")
        if chunk_type == b"IEND":
            if chunk_length != 0:
                raise RawEvidenceError("screen PNG IEND is invalid")
            saw_iend = True
            cursor = chunk_end
            break
        cursor = chunk_end
    if not (saw_ihdr and saw_idat and saw_iend) or cursor != len(data):
        raise RawEvidenceError("screen PNG is incomplete or has trailing bytes")
    bytes_per_pixel = 3 if color_type == 2 else 4
    row_bytes = width * bytes_per_pixel
    expected_decoded_bytes = (row_bytes + 1) * height
    if expected_decoded_bytes > MAX_DECODED_PNG_BYTES:
        raise RawEvidenceError("screen PNG decoded scanlines exceed the proof size limit")
    try:
        inflater = zlib.decompressobj()
        decoded = inflater.decompress(b"".join(idat_parts), expected_decoded_bytes + 1)
        if inflater.unconsumed_tail or len(decoded) > expected_decoded_bytes:
            raise RawEvidenceError("screen PNG IDAT expands beyond exact scanline bytes")
        decoded += inflater.flush(expected_decoded_bytes + 1 - len(decoded))
    except (zlib.error, ValueError) as exc:
        raise RawEvidenceError("screen PNG IDAT is not a valid zlib stream") from exc
    if (
        not inflater.eof
        or inflater.unused_data
        or inflater.unconsumed_tail
        or len(decoded) != expected_decoded_bytes
    ):
        raise RawEvidenceError("screen PNG IDAT does not contain exact scanline bytes")

    previous = bytearray(row_bytes)
    pixels = bytearray(width * height * bytes_per_pixel)
    source_offset = 0
    destination_offset = 0
    for _ in range(height):
        filter_type = decoded[source_offset]
        source_offset += 1
        if filter_type > 4:
            raise RawEvidenceError("screen PNG scanline uses an invalid filter")
        filtered = decoded[source_offset : source_offset + row_bytes]
        source_offset += row_bytes
        reconstructed = bytearray(row_bytes)
        for index, value in enumerate(filtered):
            left = reconstructed[index - bytes_per_pixel] if index >= bytes_per_pixel else 0
            above = previous[index]
            upper_left = previous[index - bytes_per_pixel] if index >= bytes_per_pixel else 0
            if filter_type == 0:
                predictor = 0
            elif filter_type == 1:
                predictor = left
            elif filter_type == 2:
                predictor = above
            elif filter_type == 3:
                predictor = (left + above) // 2
            else:
                predictor = _paeth_predictor(left, above, upper_left)
            reconstructed[index] = (value + predictor) & 0xFF
        pixels[destination_offset : destination_offset + row_bytes] = reconstructed
        destination_offset += row_bytes
        previous = reconstructed
    nontransparent = width * height
    if color_type == 6:
        nontransparent = sum(1 for index in range(3, len(pixels), 4) if pixels[index])
        if nontransparent == 0:
            raise RawEvidenceError("screen PNG is fully transparent")
    return _DecodedPng(
        width=width,
        height=height,
        color_type=color_type,
        bytes_per_pixel=bytes_per_pixel,
        decoded_pixel_sha256=hashlib.sha256(pixels).hexdigest(),
        nontransparent_pixels=nontransparent,
    )


def _finite_number(value: Any, label: str) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise RawEvidenceError(f"{label} must be numeric")
    result = float(value)
    if not math.isfinite(result):
        raise RawEvidenceError(f"{label} must be finite")
    return result


def _parse_rect(value: Any, label: str) -> dict[str, float]:
    value = _exact_fields(value, _RECT_FIELDS, label)
    result = {
        field: _finite_number(value[field], f"{label} {field}")
        for field in ("x", "y", "width", "height")
    }
    if result["width"] <= 0 or result["height"] <= 0:
        raise RawEvidenceError(f"{label} has non-visible dimensions")
    return result


def _strict_interval_overlap(*intervals: tuple[int, int]) -> bool:
    return max(start for start, _ in intervals) < min(end for _, end in intervals)


def validate_png_window_proof(
    registry: EvidenceRegistry,
    *,
    png_reference: Mapping[str, Any],
    window_state_reference: Mapping[str, Any],
    capture_receipt_reference: Mapping[str, Any],
    expected_binding: EvidenceBinding,
    allowed_capture_bounds: CaptureBounds,
    attestation: ExternalAttestationCapability,
) -> dict[str, Any]:
    """Bind decoded screenshot pixels to one externally trusted window receipt."""

    if not isinstance(registry, EvidenceRegistry):
        raise RawEvidenceError("an EvidenceRegistry is required")
    if not isinstance(expected_binding, EvidenceBinding):
        raise RawEvidenceError("an exact EvidenceBinding is required")
    if not isinstance(allowed_capture_bounds, CaptureBounds):
        raise RawEvidenceError("exact CaptureBounds are required")

    png = registry._validate_unregistered(
        png_reference,
        expected_binding=expected_binding,
        expected_media_type="image/png",
        allowed_capture_bounds=allowed_capture_bounds,
    )
    state_evidence = registry._validate_unregistered(
        window_state_reference,
        expected_binding=expected_binding,
        expected_media_type="application/json",
        allowed_capture_bounds=allowed_capture_bounds,
    )
    receipt_evidence = registry._validate_unregistered(
        capture_receipt_reference,
        expected_binding=expected_binding,
        expected_media_type="application/json",
        allowed_capture_bounds=allowed_capture_bounds,
    )
    _require_attestation(
        registry,
        expected_binding,
        attestation,
        receipt_role="window_capture",
        receipt_evidence=receipt_evidence,
    )
    decoded_png = _parse_png(png.data)
    state = _parse_json_object(state_evidence.data, "window-state evidence")
    state = _exact_fields(state, _WINDOW_STATE_FIELDS, "window-state evidence")
    if state["schema"] != WINDOW_STATE_SCHEMA:
        raise RawEvidenceError("window-state evidence schema is unsupported")
    receipt = _exact_fields(
        _parse_json_object(receipt_evidence.data, "trusted window capture receipt"),
        _WINDOW_CAPTURE_RECEIPT_FIELDS,
        "trusted window capture receipt",
    )
    if receipt["schema"] != WINDOW_CAPTURE_RECEIPT_SCHEMA:
        raise RawEvidenceError("trusted window capture receipt schema is unsupported")
    _bounded_identifier(receipt["receipt_id"], "capture receipt_id")
    if EvidenceBinding.from_mapping(receipt["binding"]) != expected_binding:
        raise RawEvidenceError("window capture receipt binding does not match")
    if receipt["capture_nonce"] != attestation.capture_nonce:
        raise RawEvidenceError("window capture nonce does not match the trusted challenge")
    _require_tool(
        receipt["screen_capture_tool"], attestation, "screen_capture"
    )
    _require_tool(
        receipt["window_audit_tool"], attestation, "window_audit"
    )
    if receipt["audit_token_sha256"] != attestation.audit_token_sha256:
        raise RawEvidenceError("window capture audit token does not match trusted provenance")
    window_id = _positive_int(receipt["window_id"], "receipt window_id")
    if (
        _positive_int(state["window_id"], "window-state window_id") != window_id
    ):
        raise RawEvidenceError("screenshot receipt and state do not identify the exact window")
    owner_process_id = _positive_int(
        state["owner_process_id"], "window-state owner_process_id"
    )
    if (
        owner_process_id != expected_binding.process_id
        or _positive_int(receipt["owner_process_id"], "receipt owner_process_id")
        != expected_binding.process_id
        or _positive_int(
            state["owner_process_start_abstime"],
            "window-state owner_process_start_abstime",
        )
        != expected_binding.process_start_abstime
        or _positive_int(
            receipt["owner_process_start_abstime"],
            "receipt owner_process_start_abstime",
        )
        != expected_binding.process_start_abstime
    ):
        raise RawEvidenceError("window proof owner PID/start does not match the WAM process")
    if state["on_screen"] is not True:
        raise RawEvidenceError("window-state evidence does not show an on-screen window")
    if state["frontmost"] is not True:
        raise RawEvidenceError("window-state evidence does not show a frontmost window")
    if state["audit_token_sha256"] != attestation.audit_token_sha256:
        raise RawEvidenceError("window state audit token does not match trusted provenance")
    display_id = _positive_int(state["display_id"], "window-state display_id")
    if _positive_int(receipt["display_id"], "receipt display_id") != display_id:
        raise RawEvidenceError("window-state and screenshot display IDs do not match")
    bounds = _parse_rect(state["bounds"], "window bounds")
    receipt_bounds = _parse_rect(receipt["window_bounds"], "receipt window bounds")
    if bounds != receipt_bounds:
        raise RawEvidenceError("window-state geometry differs from the capture receipt")
    scale = _finite_number(state["backing_scale_factor"], "window backing scale")
    receipt_scale = _finite_number(
        receipt["backing_scale_factor"], "receipt backing scale"
    )
    if scale <= 0 or scale != receipt_scale:
        raise RawEvidenceError("window-state backing scale differs from the capture receipt")
    expected_pixel_width = round(bounds["width"] * scale)
    expected_pixel_height = round(bounds["height"] * scale)
    receipt_width = _positive_int(receipt["pixel_width"], "receipt pixel_width")
    receipt_height = _positive_int(receipt["pixel_height"], "receipt pixel_height")
    if (
        decoded_png.width != expected_pixel_width
        or decoded_png.height != expected_pixel_height
        or receipt_width != expected_pixel_width
        or receipt_height != expected_pixel_height
    ):
        raise RawEvidenceError("decoded PNG pixels do not match exact audited window geometry")
    _require_artifact_identity(receipt["png_artifact"], png, "receipt PNG artifact")
    _require_artifact_identity(
        receipt["window_state_artifact"],
        state_evidence,
        "receipt window-state artifact",
    )
    if receipt["decoded_pixel_sha256"] != decoded_png.decoded_pixel_sha256:
        raise RawEvidenceError("capture receipt does not seal the decoded PNG pixels")
    receipt_start = _positive_int(
        receipt["capture_started_monotonic_ns"], "receipt capture start"
    )
    receipt_end = _positive_int(
        receipt["capture_ended_monotonic_ns"], "receipt capture end"
    )
    if receipt_end <= receipt_start:
        raise RawEvidenceError("window capture receipt interval is not positive")
    if (receipt_start, receipt_end) != (
        png.capture_started_monotonic_ns,
        png.capture_ended_monotonic_ns,
    ) or (receipt_start, receipt_end) != (
        receipt_evidence.capture_started_monotonic_ns,
        receipt_evidence.capture_ended_monotonic_ns,
    ):
        raise RawEvidenceError("PNG evidence interval differs from its trusted receipt")
    sampled_ns = _positive_int(state["sampled_monotonic_ns"], "window sampled clock")
    if not (
        state_evidence.capture_started_monotonic_ns
        <= sampled_ns
        <= state_evidence.capture_ended_monotonic_ns
        and receipt_start <= sampled_ns <= receipt_end
    ):
        raise RawEvidenceError("window sample clock is outside the overlapping capture")
    if not _strict_interval_overlap(
        (receipt_start, receipt_end),
        (
            state_evidence.capture_started_monotonic_ns,
            state_evidence.capture_ended_monotonic_ns,
        ),
    ):
        raise RawEvidenceError("window state and screenshot captures do not overlap")
    _require_tool(receipt["screen_capture_tool"], attestation, "screen_capture")
    _require_tool(receipt["window_audit_tool"], attestation, "window_audit")
    registry._register_many((png, state_evidence, receipt_evidence))
    registry.assert_campaign_unchanged()
    return {
        "eligible": True,
        "png": png.identity_dict(),
        "window_state": state_evidence.identity_dict(),
        "capture_receipt": receipt_evidence.identity_dict(),
        "png_width": decoded_png.width,
        "png_height": decoded_png.height,
        "decoded_pixel_sha256": decoded_png.decoded_pixel_sha256,
        "nontransparent_pixels": decoded_png.nontransparent_pixels,
        "window_id": window_id,
        "display_id": display_id,
        "owner_process_id": expected_binding.process_id,
        "on_screen": True,
        "frontmost": True,
        "bounds": {
            "x": bounds["x"],
            "y": bounds["y"],
            "width": bounds["width"],
            "height": bounds["height"],
        },
        "capture_receipt_id": receipt["receipt_id"],
        "attestation_trust_index_sha256": attestation.trust_index_sha256,
    }


def _canonical_fallback_library_path(value: Any) -> str:
    if not isinstance(value, str) or not value.startswith("/") or "\x00" in value:
        raise RawEvidenceError("fallback dylib path must be absolute and canonical")
    if value != os.path.normpath(value) or "/../" in f"{value}/":
        raise RawEvidenceError("fallback dylib path must be absolute and canonical")
    required_suffix = "/Contents/Frameworks/WAMMpvFallback.dylib"
    if not value.endswith(required_suffix):
        raise RawEvidenceError("fallback dylib path is not the canonical bundled library")
    return value


def _capture_absolute_regular(path: str, label: str) -> tuple[str, os.stat_result, str]:
    if (
        not isinstance(path, str)
        or not path.startswith("/")
        or path != os.path.normpath(path)
        or "\x00" in path
    ):
        raise RawEvidenceError(f"{label} path is not canonical absolute")
    canonical = path
    components = tuple(component for component in canonical.split("/") if component)
    directory_flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0)
    directory_flags |= getattr(os, "O_DIRECTORY", 0)
    directory_flags |= getattr(os, "O_NOFOLLOW", 0)
    file_flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0)
    file_flags |= getattr(os, "O_NOFOLLOW", 0)
    descriptors: list[int] = []
    try:
        current = os.open("/", directory_flags)
        descriptors.append(current)
        for component in components[:-1]:
            current = os.open(component, directory_flags, dir_fd=current)
            descriptors.append(current)
        file_fd = os.open(components[-1], file_flags, dir_fd=current)
        descriptors.append(file_fd)
        observed = os.fstat(file_fd)
        if not stat.S_ISREG(observed.st_mode) or observed.st_nlink != 1:
            raise RawEvidenceError(f"{label} is not one regular unaliased file")
        digest = _hash_regular_fd(file_fd, observed)
        return canonical, observed, digest
    except RawEvidenceError:
        raise
    except OSError as exc:
        raise RawEvidenceError(
            f"{label} is missing or has a symlinked path component"
        ) from exc
    finally:
        for descriptor in reversed(descriptors):
            try:
                os.close(descriptor)
            except OSError:
                pass


def capture_candidate_dylib_identity(path: str) -> CandidateDylibIdentity:
    """Open every absolute path component no-follow and hash the exact dylib bytes."""

    canonical = _canonical_fallback_library_path(path)
    _, observed, digest = _capture_absolute_regular(
        canonical, "candidate fallback dylib"
    )
    return CandidateDylibIdentity(
        canonical_path=canonical,
        device=observed.st_dev,
        inode=observed.st_ino,
        byte_length=observed.st_size,
        sha256=digest,
    )


def capture_trusted_tool_identity(
    *,
    role: str,
    process_id: int,
    process_start_abstime: int,
    executable_argv_sha256: str,
    executable_path: str,
    audit_token_sha256: str,
) -> TrustedToolIdentity:
    """Capture exact executable bytes for an externally observed producer process."""

    canonical, observed, digest = _capture_absolute_regular(
        executable_path, f"{role} executable"
    )
    return TrustedToolIdentity(
        role=role,
        process_id=process_id,
        process_start_abstime=process_start_abstime,
        executable_argv_sha256=executable_argv_sha256,
        executable_path=canonical,
        executable_device=observed.st_dev,
        executable_inode=observed.st_ino,
        executable_byte_length=observed.st_size,
        executable_sha256=digest,
        audit_token_sha256=audit_token_sha256,
    )


@dataclasses.dataclass(frozen=True, slots=True)
class _LoaderObservation:
    started_monotonic_ns: int
    ended_monotonic_ns: int
    sample_period_ns: int
    sample_clocks: tuple[int, ...]
    loaded: bool


def make_loader_observation_text(
    *,
    binding: EvidenceBinding,
    canonical_dylib_path: str,
    dylib_sha256: str,
    started_monotonic_ns: int,
    ended_monotonic_ns: int,
    sample_period_ns: int,
    sample_clocks: Sequence[int],
    loaded: bool,
) -> bytes:
    """Create the canonical process-scoped loader-inspector text contract."""

    path = _canonical_fallback_library_path(canonical_dylib_path)
    digest = _sha256(dylib_sha256, "fallback dylib sha256")
    if not isinstance(loaded, bool):
        raise RawEvidenceError("loader state must be boolean")
    lines = [
        f"schema={LOADER_OBSERVATION_SCHEMA}",
        f"candidate_id={binding.candidate_id}",
        f"process_id={binding.process_id}",
        f"process_start_abstime={binding.process_start_abstime}",
        f"library_canonical_path={path}",
        f"library_sha256={digest}",
        f"observation_started_monotonic_ns={started_monotonic_ns}",
        f"observation_ended_monotonic_ns={ended_monotonic_ns}",
        f"sample_period_ns={sample_period_ns}",
    ]
    state = "true" if loaded else "false"
    lines.extend(f"sample={clock},loaded={state}" for clock in sample_clocks)
    return ("\n".join(lines) + "\n").encode("utf-8")


def _canonical_decimal(value: str, label: str) -> int:
    if re.fullmatch(r"[1-9][0-9]*", value) is None:
        raise RawEvidenceError(f"{label} is not a canonical positive decimal")
    return int(value)


def _parse_loader_observation(
    data: bytes,
    *,
    evidence: ValidatedEvidence,
    expected_binding: EvidenceBinding,
    expected_path: str,
    expected_dylib_sha256: str,
    expected_loaded: bool,
) -> _LoaderObservation:
    text = _decode_text(data)
    if not text.endswith("\n") or "\r" in text:
        raise RawEvidenceError("loader observation is not canonical newline-delimited text")
    lines = text[:-1].split("\n")
    header_keys = (
        "schema",
        "candidate_id",
        "process_id",
        "process_start_abstime",
        "library_canonical_path",
        "library_sha256",
        "observation_started_monotonic_ns",
        "observation_ended_monotonic_ns",
        "sample_period_ns",
    )
    if len(lines) < len(header_keys) + 3:
        raise RawEvidenceError("loader observation lacks a continuous sample series")
    header: dict[str, str] = {}
    for index, key in enumerate(header_keys):
        prefix = f"{key}="
        if not lines[index].startswith(prefix):
            raise RawEvidenceError("loader observation header is not exact or canonical")
        header[key] = lines[index][len(prefix) :]
    if header["schema"] != LOADER_OBSERVATION_SCHEMA:
        raise RawEvidenceError("loader observation schema is unsupported")
    if header["candidate_id"] != expected_binding.candidate_id:
        raise RawEvidenceError("loader observation candidate identity does not match")
    if _canonical_decimal(header["process_id"], "loader process_id") != expected_binding.process_id:
        raise RawEvidenceError("loader observation PID does not match the WAM process")
    if (
        _canonical_decimal(
            header["process_start_abstime"], "loader process_start_abstime"
        )
        != expected_binding.process_start_abstime
    ):
        raise RawEvidenceError("loader observation process start does not match")
    if header["library_canonical_path"] != expected_path:
        raise RawEvidenceError("loader observation names a different fallback dylib")
    if header["library_sha256"] != expected_dylib_sha256:
        raise RawEvidenceError("loader observation fallback dylib hash does not match candidate")
    started = _canonical_decimal(
        header["observation_started_monotonic_ns"], "loader observation start"
    )
    ended = _canonical_decimal(
        header["observation_ended_monotonic_ns"], "loader observation end"
    )
    period = _canonical_decimal(header["sample_period_ns"], "loader sample period")
    if (started, ended) != (
        evidence.capture_started_monotonic_ns,
        evidence.capture_ended_monotonic_ns,
    ):
        raise RawEvidenceError("loader observation clocks differ from retained evidence")
    if ended - started < LOADER_MIN_OBSERVATION_NS:
        raise RawEvidenceError("loader observation is too short to prove continuous state")
    if period > LOADER_MAX_SAMPLE_GAP_NS:
        raise RawEvidenceError("loader observation sampling period is too sparse")
    expected_state = "true" if expected_loaded else "false"
    sample_clocks: list[int] = []
    for line in lines[len(header_keys) :]:
        match = re.fullmatch(r"sample=([1-9][0-9]*),loaded=(true|false)", line)
        if match is None:
            raise RawEvidenceError("loader observation contains a malformed sample")
        clock = _canonical_decimal(match.group(1), "loader sample clock")
        if match.group(2) != expected_state:
            raise RawEvidenceError("loader observation contains contradictory load state")
        if sample_clocks and not 0 < clock - sample_clocks[-1] <= period:
            raise RawEvidenceError("loader observation is not continuous at its declared cadence")
        sample_clocks.append(clock)
    if sample_clocks[0] != started or sample_clocks[-1] != ended:
        raise RawEvidenceError("loader samples do not cover the exact observation interval")
    return _LoaderObservation(
        started_monotonic_ns=started,
        ended_monotonic_ns=ended,
        sample_period_ns=period,
        sample_clocks=tuple(sample_clocks),
        loaded=expected_loaded,
    )


def validate_lazy_load_proof(
    registry: EvidenceRegistry,
    *,
    pre_route_reference: Mapping[str, Any],
    post_route_reference: Mapping[str, Any],
    inspector_receipt_reference: Mapping[str, Any],
    expected_binding: EvidenceBinding,
    allowed_capture_bounds: CaptureBounds,
    route_selection_monotonic_ns: int,
    canonical_dylib_path: str,
    attestation: ExternalAttestationCapability,
) -> dict[str, Any]:
    """Prove continuous exact-process absence before route and presence after it."""

    if not isinstance(registry, EvidenceRegistry):
        raise RawEvidenceError("an EvidenceRegistry is required")
    if not isinstance(expected_binding, EvidenceBinding):
        raise RawEvidenceError("an exact EvidenceBinding is required")
    if not isinstance(allowed_capture_bounds, CaptureBounds):
        raise RawEvidenceError("exact CaptureBounds are required")

    route_ns = _positive_int(route_selection_monotonic_ns, "route selection clock")
    if not (
        allowed_capture_bounds.started_monotonic_ns
        <= route_ns
        <= allowed_capture_bounds.ended_monotonic_ns
    ):
        raise RawEvidenceError("route selection clock is outside authorized bounds")
    _require_capability(registry, expected_binding, attestation)
    expected_path = _canonical_fallback_library_path(canonical_dylib_path)
    observed_candidate = capture_candidate_dylib_identity(expected_path)
    if attestation.candidate_dylib is None:
        raise RawEvidenceError("external trust index lacks exact candidate dylib identity")
    if observed_candidate != attestation.candidate_dylib:
        raise RawEvidenceError("candidate fallback dylib changed from external trust index")
    expected_hash = observed_candidate.sha256
    pre = registry._validate_unregistered(
        pre_route_reference,
        expected_binding=expected_binding,
        expected_media_type="text/plain",
        allowed_capture_bounds=allowed_capture_bounds,
    )
    post = registry._validate_unregistered(
        post_route_reference,
        expected_binding=expected_binding,
        expected_media_type="text/plain",
        allowed_capture_bounds=allowed_capture_bounds,
    )
    receipt_evidence = registry._validate_unregistered(
        inspector_receipt_reference,
        expected_binding=expected_binding,
        expected_media_type="application/json",
        allowed_capture_bounds=allowed_capture_bounds,
    )
    _require_attestation(
        registry,
        expected_binding,
        attestation,
        receipt_role="loader_inspector",
        receipt_evidence=receipt_evidence,
    )
    receipt = _exact_fields(
        _parse_json_object(receipt_evidence.data, "loader inspector receipt"),
        _LOADER_INSPECTOR_RECEIPT_FIELDS,
        "loader inspector receipt",
    )
    if receipt["schema"] != LOADER_INSPECTOR_RECEIPT_SCHEMA:
        raise RawEvidenceError("loader inspector receipt schema is unsupported")
    if EvidenceBinding.from_mapping(receipt["binding"]) != expected_binding:
        raise RawEvidenceError("loader inspector receipt binding does not match")
    _bounded_identifier(receipt["receipt_id"], "loader inspector receipt_id")
    if (
        receipt["capture_nonce"] != attestation.capture_nonce
        or receipt["audit_token_sha256"] != attestation.audit_token_sha256
    ):
        raise RawEvidenceError("loader inspector receipt lacks trusted nonce/audit identity")
    _require_tool(
        receipt["loader_inspector_tool"], attestation, "loader_inspector"
    )
    if CandidateDylibIdentity.from_mapping(receipt["candidate_dylib"]) != observed_candidate:
        raise RawEvidenceError("loader inspector receipt names a different candidate dylib")
    if receipt["route_selection_monotonic_ns"] != route_ns:
        raise RawEvidenceError("loader inspector receipt has a different route clock")
    _require_artifact_identity(receipt["pre_artifact"], pre, "loader pre artifact")
    _require_artifact_identity(receipt["post_artifact"], post, "loader post artifact")
    if (
        receipt["capture_started_monotonic_ns"] != pre.capture_started_monotonic_ns
        or receipt["capture_ended_monotonic_ns"] != post.capture_ended_monotonic_ns
        or receipt_evidence.capture_started_monotonic_ns
        != pre.capture_started_monotonic_ns
        or receipt_evidence.capture_ended_monotonic_ns
        != post.capture_ended_monotonic_ns
    ):
        raise RawEvidenceError("loader inspector receipt does not span exact observations")
    if pre.capture_ended_monotonic_ns >= route_ns:
        raise RawEvidenceError("pre-route loader observation is not strictly before route")
    if post.capture_started_monotonic_ns <= route_ns:
        raise RawEvidenceError("post-route loader observation is not strictly after route")
    if (
        route_ns - pre.capture_ended_monotonic_ns > LOADER_MAX_SAMPLE_GAP_NS
        or post.capture_started_monotonic_ns - route_ns > LOADER_MAX_SAMPLE_GAP_NS
        or post.capture_started_monotonic_ns - pre.capture_ended_monotonic_ns
        > LOADER_MAX_SAMPLE_GAP_NS
    ):
        raise RawEvidenceError("loader observation is not continuous across route selection")
    pre_observation = _parse_loader_observation(
        pre.data,
        evidence=pre,
        expected_binding=expected_binding,
        expected_path=expected_path,
        expected_dylib_sha256=expected_hash,
        expected_loaded=False,
    )
    post_observation = _parse_loader_observation(
        post.data,
        evidence=post,
        expected_binding=expected_binding,
        expected_path=expected_path,
        expected_dylib_sha256=expected_hash,
        expected_loaded=True,
    )
    if capture_candidate_dylib_identity(expected_path) != observed_candidate:
        raise RawEvidenceError("candidate fallback dylib changed during validation")
    _require_tool(receipt["loader_inspector_tool"], attestation, "loader_inspector")
    registry._register_many((pre, post, receipt_evidence))
    registry.assert_campaign_unchanged()
    return {
        "eligible": True,
        "canonical_dylib_path": expected_path,
        "dylib_sha256": expected_hash,
        "route_selection_monotonic_ns": route_ns,
        "pre_route": pre.identity_dict(),
        "post_route": post.identity_dict(),
        "inspector_receipt": receipt_evidence.identity_dict(),
        "candidate_dylib": observed_candidate.as_dict(),
        "not_loaded_before_route_selection": True,
        "loaded_after_route_selection": True,
        "pre_route_sample_count": len(pre_observation.sample_clocks),
        "post_route_sample_count": len(post_observation.sample_clocks),
        "attestation_trust_index_sha256": attestation.trust_index_sha256,
    }


@dataclasses.dataclass(frozen=True, slots=True)
class _PcmWindow:
    rms: float
    ac_rms: float
    peak: float
    peak_to_peak: float
    active_sample_fraction: float


@dataclasses.dataclass(frozen=True, slots=True)
class _PcmWav:
    channels: int
    sample_rate_hz: int
    bits_per_sample: int
    frame_count: int
    duration_seconds: float
    rms: float
    ac_rms: float
    peak: float
    mean: float
    peak_to_peak: float
    windows: tuple[_PcmWindow, ...]


def _parse_pcm_wav(data: bytes) -> _PcmWav:
    if len(data) < 12 or data[:4] != b"RIFF" or data[8:12] != b"WAVE":
        raise RawEvidenceError("audio proof is not a RIFF/WAVE file")
    riff_size = struct.unpack_from("<I", data, 4)[0]
    if riff_size + 8 != len(data):
        raise RawEvidenceError("audio WAV RIFF length is truncated or has trailing bytes")
    cursor = 12
    fmt_payload: bytes | None = None
    pcm_data: bytes | None = None
    while cursor < len(data):
        if len(data) - cursor < 8:
            raise RawEvidenceError("audio WAV has a truncated chunk header")
        chunk_id = data[cursor : cursor + 4]
        chunk_size = struct.unpack_from("<I", data, cursor + 4)[0]
        payload_start = cursor + 8
        payload_end = payload_start + chunk_size
        padded_end = payload_end + (chunk_size & 1)
        if padded_end > len(data):
            raise RawEvidenceError("audio WAV has a truncated chunk payload")
        payload = data[payload_start:payload_end]
        if chunk_id == b"fmt ":
            if fmt_payload is not None:
                raise RawEvidenceError("audio WAV has multiple fmt chunks")
            fmt_payload = payload
        elif chunk_id == b"data":
            if pcm_data is not None:
                raise RawEvidenceError("audio WAV has multiple data chunks")
            pcm_data = payload
        cursor = padded_end
    if cursor != len(data) or fmt_payload is None or pcm_data is None:
        raise RawEvidenceError("audio WAV lacks one exact fmt/data payload")
    if len(fmt_payload) != 16:
        raise RawEvidenceError("audio WAV fmt chunk is not canonical PCM")
    (
        audio_format,
        channels,
        sample_rate,
        byte_rate,
        block_align,
        bits_per_sample,
    ) = struct.unpack("<HHIIHH", fmt_payload)
    if audio_format != 1:
        raise RawEvidenceError("audio WAV is not integer PCM")
    if channels <= 0 or channels > 8 or sample_rate <= 0 or sample_rate > 384_000:
        raise RawEvidenceError("audio WAV channel count or sample rate is invalid")
    if bits_per_sample not in {8, 16, 24, 32}:
        raise RawEvidenceError("audio WAV PCM sample width is unsupported")
    bytes_per_sample = bits_per_sample // 8
    expected_align = channels * bytes_per_sample
    if block_align != expected_align or byte_rate != sample_rate * expected_align:
        raise RawEvidenceError("audio WAV PCM rate/alignment fields are inconsistent")
    if not pcm_data or len(pcm_data) % block_align:
        raise RawEvidenceError("audio WAV PCM data is empty or not frame-aligned")

    sum_samples = 0.0
    sum_squares = 0.0
    peak = 0.0
    channel_counts = [0] * channels
    channel_sums = [0.0] * channels
    channel_squares = [0.0] * channels
    channel_minimums = [1.0] * channels
    channel_maximums = [-1.0] * channels
    sample_count = len(pcm_data) // bytes_per_sample
    if bits_per_sample == 8:
        iterator = ((value - 128) / 128.0 for value in pcm_data)
    elif bits_per_sample == 16:
        iterator = (value[0] / 32768.0 for value in struct.iter_unpack("<h", pcm_data))
    elif bits_per_sample == 24:
        def samples_24() -> Any:
            for offset in range(0, len(pcm_data), 3):
                value = int.from_bytes(pcm_data[offset : offset + 3], "little")
                if value & 0x800000:
                    value -= 1 << 24
                yield value / 8388608.0

        iterator = samples_24()
    else:
        iterator = (
            value[0] / 2147483648.0 for value in struct.iter_unpack("<i", pcm_data)
        )
    window_sample_count = max(1, round(sample_rate * HARD_AUDIO_WINDOW_SECONDS)) * channels
    window_count = 0
    window_sum = 0.0
    window_sum_squares = 0.0
    window_peak = 0.0
    window_active_samples = 0
    window_channel_counts = [0] * channels
    window_channel_sums = [0.0] * channels
    window_channel_squares = [0.0] * channels
    window_channel_minimums = [1.0] * channels
    window_channel_maximums = [-1.0] * channels
    windows: list[_PcmWindow] = []

    def finish_window() -> None:
        nonlocal window_count, window_sum, window_sum_squares
        nonlocal window_peak, window_active_samples
        nonlocal window_channel_counts, window_channel_sums, window_channel_squares
        nonlocal window_channel_minimums, window_channel_maximums
        if window_count == 0:
            return
        rms = math.sqrt(window_sum_squares / window_count)
        centered_squares = sum(
            squares - (total * total / count)
            for count, total, squares in zip(
                window_channel_counts,
                window_channel_sums,
                window_channel_squares,
            )
            if count
        )
        ac_rms = math.sqrt(max(0.0, centered_squares / window_count))
        temporal_peak_to_peak = max(
            maximum - minimum
            for count, minimum, maximum in zip(
                window_channel_counts,
                window_channel_minimums,
                window_channel_maximums,
            )
            if count
        )
        windows.append(
            _PcmWindow(
                rms=rms,
                ac_rms=ac_rms,
                peak=window_peak,
                peak_to_peak=temporal_peak_to_peak,
                active_sample_fraction=window_active_samples / window_count,
            )
        )
        window_count = 0
        window_sum = 0.0
        window_sum_squares = 0.0
        window_peak = 0.0
        window_active_samples = 0
        window_channel_counts = [0] * channels
        window_channel_sums = [0.0] * channels
        window_channel_squares = [0.0] * channels
        window_channel_minimums = [1.0] * channels
        window_channel_maximums = [-1.0] * channels

    for sample_index, sample in enumerate(iterator):
        channel = sample_index % channels
        magnitude = abs(sample)
        peak = max(peak, magnitude)
        sum_samples += sample
        sum_squares += sample * sample
        channel_counts[channel] += 1
        channel_sums[channel] += sample
        channel_squares[channel] += sample * sample
        channel_minimums[channel] = min(channel_minimums[channel], sample)
        channel_maximums[channel] = max(channel_maximums[channel], sample)
        window_count += 1
        window_sum += sample
        window_sum_squares += sample * sample
        window_peak = max(window_peak, magnitude)
        if magnitude >= HARD_MIN_AUDIO_SAMPLE_MAGNITUDE:
            window_active_samples += 1
        window_channel_counts[channel] += 1
        window_channel_sums[channel] += sample
        window_channel_squares[channel] += sample * sample
        window_channel_minimums[channel] = min(
            window_channel_minimums[channel], sample
        )
        window_channel_maximums[channel] = max(
            window_channel_maximums[channel], sample
        )
        if window_count == window_sample_count:
            finish_window()
    finish_window()
    rms = math.sqrt(sum_squares / sample_count)
    mean = sum_samples / sample_count
    centered_squares = sum(
        squares - (total * total / count)
        for count, total, squares in zip(
            channel_counts, channel_sums, channel_squares
        )
    )
    ac_rms = math.sqrt(max(0.0, centered_squares / sample_count))
    temporal_peak_to_peak = max(
        maximum - minimum
        for minimum, maximum in zip(channel_minimums, channel_maximums)
    )
    frame_count = len(pcm_data) // block_align
    return _PcmWav(
        channels=channels,
        sample_rate_hz=sample_rate,
        bits_per_sample=bits_per_sample,
        frame_count=frame_count,
        duration_seconds=frame_count / sample_rate,
        rms=rms,
        ac_rms=ac_rms,
        peak=peak,
        mean=mean,
        peak_to_peak=temporal_peak_to_peak,
        windows=tuple(windows),
    )


def make_audio_capture_provenance(
    *,
    binding: EvidenceBinding,
    provenance_id: str,
    capture_nonce: str,
    system_audio_capture_tool: TrustedToolIdentity,
    process_tap_tool: TrustedToolIdentity,
    process_tap_id: str,
    audit_token_sha256: str,
    output_route_uid: str,
    output_device_id: int,
    capture_started_monotonic_ns: int,
    capture_ended_monotonic_ns: int,
    stream_sample_rate_hz: int,
    stream_channels: int,
    stream_frame_count: int,
    first_sample_monotonic_ns: int,
    last_sample_monotonic_ns: int,
    output_latency_frames: int,
    wav_artifact: Mapping[str, Any],
) -> dict[str, Any]:
    """Create an integrity-only receipt; external attestation is still required."""

    return {
        "schema": AUDIO_CAPTURE_PROVENANCE_SCHEMA,
        "binding": binding.as_dict(),
        "provenance_id": _bounded_identifier(provenance_id, "audio provenance_id"),
        "capture_nonce": _sha256(capture_nonce, "audio capture nonce"),
        "system_audio_capture_tool": system_audio_capture_tool.as_dict(),
        "process_tap_tool": process_tap_tool.as_dict(),
        "capture_scope": "process_tap",
        "process_tap_id": _bounded_identifier(process_tap_id, "process tap ID"),
        "target_process_id": binding.process_id,
        "target_process_start_abstime": binding.process_start_abstime,
        "audit_token_sha256": _sha256(audit_token_sha256, "audit-token sha256"),
        "output_route_uid": _bounded_text(output_route_uid, "output route UID"),
        "output_device_id": _positive_int(output_device_id, "output device ID"),
        "output_route_active": True,
        "stream_sample_rate_hz": _positive_int(
            stream_sample_rate_hz, "audio stream sample rate"
        ),
        "stream_channels": _positive_int(stream_channels, "audio stream channels"),
        "stream_frame_count": _positive_int(
            stream_frame_count, "audio stream frame count"
        ),
        "first_sample_monotonic_ns": _positive_int(
            first_sample_monotonic_ns, "audio first-sample clock"
        ),
        "last_sample_monotonic_ns": _positive_int(
            last_sample_monotonic_ns, "audio last-sample clock"
        ),
        "output_latency_frames": _nonnegative_int(
            output_latency_frames, "audio output latency frames"
        ),
        "capture_started_monotonic_ns": _positive_int(
            capture_started_monotonic_ns, "audio provenance start"
        ),
        "capture_ended_monotonic_ns": _positive_int(
            capture_ended_monotonic_ns, "audio provenance end"
        ),
        "wav_artifact": dict(wav_artifact),
    }


def validate_process_audio_wav(
    registry: EvidenceRegistry,
    *,
    wav_reference: Mapping[str, Any],
    provenance_reference: Mapping[str, Any],
    expected_binding: EvidenceBinding,
    allowed_capture_bounds: CaptureBounds,
    attestation: ExternalAttestationCapability,
    minimum_duration_seconds: float = HARD_MIN_AUDIO_DURATION_SECONDS,
    minimum_rms: float = HARD_MIN_AUDIO_RMS,
    minimum_peak: float = HARD_MIN_AUDIO_PEAK,
) -> dict[str, Any]:
    """Validate trusted process-tap audio with sustained, varying signal energy."""

    if not isinstance(registry, EvidenceRegistry):
        raise RawEvidenceError("an EvidenceRegistry is required")
    if not isinstance(expected_binding, EvidenceBinding):
        raise RawEvidenceError("an exact EvidenceBinding is required")
    if not isinstance(allowed_capture_bounds, CaptureBounds):
        raise RawEvidenceError("exact CaptureBounds are required")

    for value, label in (
        (minimum_duration_seconds, "minimum duration"),
        (minimum_rms, "minimum RMS"),
        (minimum_peak, "minimum peak"),
    ):
        if (
            isinstance(value, bool)
            or not isinstance(value, (int, float))
            or not math.isfinite(float(value))
            or float(value) <= 0
        ):
            raise RawEvidenceError(f"{label} must be a finite positive number")
    if minimum_duration_seconds < HARD_MIN_AUDIO_DURATION_SECONDS:
        raise RawEvidenceError("minimum duration cannot weaken the hard audio floor")
    if minimum_rms < HARD_MIN_AUDIO_RMS:
        raise RawEvidenceError("minimum RMS cannot weaken the hard audio floor")
    if minimum_peak < HARD_MIN_AUDIO_PEAK:
        raise RawEvidenceError("minimum peak cannot weaken the hard audio floor")
    if minimum_rms > 1.0 or minimum_peak > 1.0:
        raise RawEvidenceError("PCM non-silence thresholds cannot exceed full scale")
    wav = registry._validate_unregistered(
        wav_reference,
        expected_binding=expected_binding,
        expected_media_type="audio/wav",
        allowed_capture_bounds=allowed_capture_bounds,
    )
    provenance_evidence = registry._validate_unregistered(
        provenance_reference,
        expected_binding=expected_binding,
        expected_media_type="application/json",
        allowed_capture_bounds=allowed_capture_bounds,
    )
    _require_attestation(
        registry,
        expected_binding,
        attestation,
        receipt_role="process_audio",
        receipt_evidence=provenance_evidence,
    )
    parsed = _parse_pcm_wav(wav.data)
    provenance = _exact_fields(
        _parse_json_object(provenance_evidence.data, "process-audio provenance"),
        _AUDIO_PROVENANCE_FIELDS,
        "process-audio provenance",
    )
    if provenance["schema"] != AUDIO_CAPTURE_PROVENANCE_SCHEMA:
        raise RawEvidenceError("process-audio provenance schema is unsupported")
    if EvidenceBinding.from_mapping(provenance["binding"]) != expected_binding:
        raise RawEvidenceError("process-audio provenance binding does not match")
    _bounded_identifier(provenance["provenance_id"], "audio provenance_id")
    if provenance["capture_nonce"] != attestation.capture_nonce:
        raise RawEvidenceError("audio provenance capture nonce does not match")
    _require_tool(
        provenance["system_audio_capture_tool"],
        attestation,
        "system_audio_capture",
    )
    _require_tool(
        provenance["process_tap_tool"], attestation, "process_tap"
    )
    expected_tap_id = _bounded_identifier(
        provenance["process_tap_id"], "process tap ID"
    )
    expected_route_uid = _bounded_text(provenance["output_route_uid"], "output route UID")
    if (
        provenance["capture_scope"] != "process_tap"
        or provenance["target_process_id"] != expected_binding.process_id
        or provenance["target_process_start_abstime"]
        != expected_binding.process_start_abstime
        or provenance["audit_token_sha256"] != attestation.audit_token_sha256
    ):
        raise RawEvidenceError("audio provenance is not the exact trusted process tap")
    if (
        provenance["output_route_uid"] != expected_route_uid
        or _positive_int(provenance["output_device_id"], "audio output device ID") <= 0
        or provenance["output_route_active"] is not True
    ):
        raise RawEvidenceError("audio provenance is not the active trusted output route")
    if (
        _positive_int(
            provenance["capture_started_monotonic_ns"],
            "audio provenance capture start",
        )
        != wav.capture_started_monotonic_ns
        or _positive_int(
            provenance["capture_ended_monotonic_ns"],
            "audio provenance capture end",
        )
        != wav.capture_ended_monotonic_ns
        or provenance_evidence.capture_started_monotonic_ns
        != wav.capture_started_monotonic_ns
        or provenance_evidence.capture_ended_monotonic_ns
        != wav.capture_ended_monotonic_ns
    ):
        raise RawEvidenceError("audio provenance does not seal the exact WAV capture")
    _require_artifact_identity(
        provenance["wav_artifact"], wav, "audio provenance WAV artifact"
    )
    stream_sample_rate = _positive_int(
        provenance["stream_sample_rate_hz"], "audio stream sample rate"
    )
    stream_channels = _positive_int(
        provenance["stream_channels"], "audio stream channels"
    )
    stream_frames = _positive_int(
        provenance["stream_frame_count"], "audio stream frame count"
    )
    first_sample_ns = _positive_int(
        provenance["first_sample_monotonic_ns"], "audio first-sample clock"
    )
    last_sample_ns = _positive_int(
        provenance["last_sample_monotonic_ns"], "audio last-sample clock"
    )
    output_latency_frames = _nonnegative_int(
        provenance["output_latency_frames"], "audio output latency frames"
    )
    if (
        stream_sample_rate != parsed.sample_rate_hz
        or stream_channels != parsed.channels
        or stream_frames != parsed.frame_count
        or output_latency_frames >= stream_frames
        or not wav.capture_started_monotonic_ns <= first_sample_ns < last_sample_ns
        or last_sample_ns > wav.capture_ended_monotonic_ns
    ):
        raise RawEvidenceError("audio provenance stream identity/timing differs from PCM")
    expected_stream_span_ns = round(
        (parsed.frame_count - 1) * 1_000_000_000 / parsed.sample_rate_hz
    )
    one_frame_ns = math.ceil(1_000_000_000 / parsed.sample_rate_hz)
    if abs((last_sample_ns - first_sample_ns) - expected_stream_span_ns) > one_frame_ns:
        raise RawEvidenceError("audio provenance sample clocks do not span the PCM frames")
    capture_seconds = (
        wav.capture_ended_monotonic_ns - wav.capture_started_monotonic_ns
    ) / 1_000_000_000.0
    if parsed.duration_seconds > capture_seconds + (1.0 / parsed.sample_rate_hz):
        raise RawEvidenceError("audio WAV duration exceeds its monotonic capture interval")
    if capture_seconds - parsed.duration_seconds > HARD_MAX_AUDIO_CAPTURE_PADDING_SECONDS:
        raise RawEvidenceError("audio WAV does not cover its monotonic capture interval")
    if parsed.duration_seconds < float(minimum_duration_seconds):
        raise RawEvidenceError("audio WAV is too short to prove sustained output")
    if parsed.rms < float(minimum_rms) or parsed.peak < float(minimum_peak):
        raise RawEvidenceError("audio WAV is silent or below the non-silence threshold")
    if (
        parsed.ac_rms < HARD_MIN_AUDIO_AC_RMS
        or parsed.peak_to_peak < HARD_MIN_AUDIO_PEAK_TO_PEAK
    ):
        raise RawEvidenceError("audio WAV is DC or lacks changing audible signal")
    active_windows = [
        window.ac_rms >= HARD_MIN_AUDIO_AC_RMS
        and window.peak >= float(minimum_peak)
        and window.peak_to_peak >= HARD_MIN_AUDIO_PEAK_TO_PEAK
        and window.active_sample_fraction >= HARD_MIN_AUDIO_ACTIVE_SAMPLE_FRACTION
        for window in parsed.windows
    ]
    active_window_count = sum(active_windows)
    active_fraction = active_window_count / len(active_windows)
    maximum_inactive_run = 0
    inactive_run = 0
    for active in active_windows:
        if active:
            inactive_run = 0
        else:
            inactive_run += 1
            maximum_inactive_run = max(maximum_inactive_run, inactive_run)
    if (
        active_fraction < HARD_MIN_ACTIVE_WINDOW_FRACTION
        or maximum_inactive_run > HARD_MAX_CONSECUTIVE_INACTIVE_WINDOWS
    ):
        raise RawEvidenceError("audio WAV does not contain sustained windowed activity")
    _require_tool(
        provenance["system_audio_capture_tool"],
        attestation,
        "system_audio_capture",
    )
    _require_tool(provenance["process_tap_tool"], attestation, "process_tap")
    registry._register_many((wav, provenance_evidence))
    registry.assert_campaign_unchanged()
    return {
        "eligible": True,
        "wav": wav.identity_dict(),
        "provenance": provenance_evidence.identity_dict(),
        "process_id": expected_binding.process_id,
        "channels": parsed.channels,
        "sample_rate_hz": parsed.sample_rate_hz,
        "bits_per_sample": parsed.bits_per_sample,
        "frame_count": parsed.frame_count,
        "duration_seconds": parsed.duration_seconds,
        "rms": parsed.rms,
        "ac_rms": parsed.ac_rms,
        "peak": parsed.peak,
        "peak_to_peak": parsed.peak_to_peak,
        "window_seconds": HARD_AUDIO_WINDOW_SECONDS,
        "window_count": len(parsed.windows),
        "active_window_count": active_window_count,
        "active_window_fraction": active_fraction,
        "maximum_consecutive_inactive_windows": maximum_inactive_run,
        "process_tap_id": expected_tap_id,
        "output_route_uid": expected_route_uid,
        "audio_provenance_id": provenance["provenance_id"],
        "attestation_trust_index_sha256": attestation.trust_index_sha256,
        "active": True,
        "audible": True,
    }
