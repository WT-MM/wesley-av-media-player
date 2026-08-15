#!/usr/bin/env python3
"""Fail-closed identities for a screen-backed macOS shipping campaign.

The benchmark runner must be able to prove that the bytes it measured did not
change between preflight and postflight.  This module provides the read-only
primitives for doing that.  It deliberately contains no GUI, launch, input, or
network behavior.

All external programs are named by absolute path, identified by content, and
run with bounded output.  Media is probed through an already-open descriptor,
so the probe sees the same inode that is hashed.  App bundles are walked with
``openat``-style operations and ``O_NOFOLLOW``; symlinks are recorded but never
traversed.
"""

from __future__ import annotations

import ctypes
import contextlib
import dataclasses
import errno
import hashlib
import json
import math
import os
import plistlib
import selectors
import shutil
import signal
import stat
import struct
import subprocess
import tempfile
import time
import uuid
from fractions import Fraction
from pathlib import PurePosixPath
from typing import Any, Callable, Iterator, Mapping, Sequence


ASSET_IDENTITY_SCHEMA = "wam.macos.shipper.asset-identity.v2"
APP_IDENTITY_SCHEMA = "wam.macos.shipper.app-identity.v2"
CONTENTS_MANIFEST_SCHEMA = "wam.macos.shipper.contents-manifest.v2"
COMMAND_EVIDENCE_SCHEMA = "wam.macos.shipper.command-evidence.v2"
TRUSTED_COMMAND_RECEIPT_SCHEMA = "wam.macos.shipper.command-execution-receipt.v1"
TRUSTED_COMMAND_INDEX_SCHEMA = "wam.macos.shipper.external-command-trust-index.v1"
DEFAULT_MAX_TOOL_OUTPUT_BYTES = 1024 * 1024
DEFAULT_TOOL_TIMEOUT_S = 30.0
MAX_EBML_HEADER_BYTES = 1024 * 1024
HASH_CHUNK_BYTES = 1024 * 1024
SANITIZED_COMMAND_ENVIRONMENT = (
    ("LANG", "C"),
    ("LC_ALL", "C"),
    ("PATH", "/usr/bin:/bin"),
)
class IdentityError(RuntimeError):
    """An identity could not be established without ambiguity."""


@dataclasses.dataclass(frozen=True)
class FileStatIdentity:
    device: int
    inode: int
    mode: int
    uid: int
    gid: int
    size_bytes: int
    mtime_ns: int
    ctime_ns: int
    birthtime_ns: int
    flags: int

    @classmethod
    def from_stat(cls, value: os.stat_result) -> "FileStatIdentity":
        return cls(
            device=int(value.st_dev),
            inode=int(value.st_ino),
            mode=int(value.st_mode),
            uid=int(value.st_uid),
            gid=int(value.st_gid),
            size_bytes=int(value.st_size),
            mtime_ns=int(value.st_mtime_ns),
            ctime_ns=int(value.st_ctime_ns),
            birthtime_ns=int(
                getattr(
                    value,
                    "st_birthtime_ns",
                    round(getattr(value, "st_birthtime", 0.0) * 1_000_000_000),
                )
            ),
            flags=int(getattr(value, "st_flags", 0)),
        )

    def as_dict(self) -> dict[str, int]:
        return dataclasses.asdict(self)


@dataclasses.dataclass(frozen=True)
class FileIdentity:
    requested_path: str
    canonical_path: str
    sha256: str
    stat: FileStatIdentity
    extended_metadata_sha256: str
    path_ancestry: tuple[FileStatIdentity, ...] = ()

    def as_dict(self) -> dict[str, Any]:
        return {
            "requested_path": self.requested_path,
            "canonical_path": self.canonical_path,
            "sha256": self.sha256,
            "stat": self.stat.as_dict(),
            "extended_metadata_sha256": self.extended_metadata_sha256,
            "path_ancestry": [value.as_dict() for value in self.path_ancestry],
        }


@dataclasses.dataclass(frozen=True)
class CommandResult:
    """Raw result returned by an injected command runner."""

    returncode: int
    stdout: bytes
    stderr: bytes


CommandRunner = Callable[
    [Sequence[str], tuple[int, ...], float, int], CommandResult
]


@dataclasses.dataclass(frozen=True)
class CommandEvidence:
    schema: str
    argv: tuple[str, ...]
    returncode: int
    stdout_text: str
    stderr_text: str
    stdout_bytes: int
    stderr_bytes: int
    stdout_sha256: str
    stderr_sha256: str
    tool: FileIdentity
    executed_tool: FileIdentity
    executed_argv: tuple[str, ...]
    sanitized_environment: tuple[tuple[str, str], ...]
    trusted_execution: bool
    pass_fds: tuple[int, ...]
    targets: tuple["CommandTargetIdentity", ...]
    private_snapshot_root_stat: FileStatIdentity | None
    private_snapshot_root_extended_metadata_sha256: str | None
    execution_receipt_id: str | None

    def as_dict(self) -> dict[str, Any]:
        return {
            "schema": self.schema,
            "argv": list(self.argv),
            "returncode": self.returncode,
            "stdout_text": self.stdout_text,
            "stderr_text": self.stderr_text,
            "stdout_bytes": self.stdout_bytes,
            "stderr_bytes": self.stderr_bytes,
            "stdout_sha256": self.stdout_sha256,
            "stderr_sha256": self.stderr_sha256,
            "tool": self.tool.as_dict(),
            "executed_tool": self.executed_tool.as_dict(),
            "executed_argv": list(self.executed_argv),
            "sanitized_environment": [list(item) for item in self.sanitized_environment],
            "trusted_execution": self.trusted_execution,
            "pass_fds": list(self.pass_fds),
            "targets": [target.as_dict() for target in self.targets],
            "private_snapshot_root_stat": (
                self.private_snapshot_root_stat.as_dict()
                if self.private_snapshot_root_stat is not None
                else None
            ),
            "private_snapshot_root_extended_metadata_sha256": (
                self.private_snapshot_root_extended_metadata_sha256
            ),
            "execution_receipt_id": self.execution_receipt_id,
        }


@dataclasses.dataclass(frozen=True)
class CommandTargetIdentity:
    role: str
    source_argument: str
    executed_argument: str
    descriptor: int | None
    file: FileIdentity | None
    executed_file: FileIdentity | None
    contents_tree_sha256: str | None
    executed_contents_tree_sha256: str | None
    executed_root_stat: FileStatIdentity | None
    executed_root_extended_metadata_sha256: str | None

    def as_dict(self) -> dict[str, Any]:
        return {
            "role": self.role,
            "source_argument": self.source_argument,
            "executed_argument": self.executed_argument,
            "descriptor": self.descriptor,
            "file": self.file.as_dict() if self.file is not None else None,
            "executed_file": (
                self.executed_file.as_dict()
                if self.executed_file is not None
                else None
            ),
            "contents_tree_sha256": self.contents_tree_sha256,
            "executed_contents_tree_sha256": self.executed_contents_tree_sha256,
            "executed_root_stat": (
                self.executed_root_stat.as_dict()
                if self.executed_root_stat is not None
                else None
            ),
            "executed_root_extended_metadata_sha256": (
                self.executed_root_extended_metadata_sha256
            ),
        }


@dataclasses.dataclass(frozen=True)
class VideoIdentity:
    codec: str
    profile: str
    fourcc: str
    width: int
    height: int
    pixel_format: str
    fps_numerator: int
    fps_denominator: int

    @property
    def fps(self) -> float:
        return self.fps_numerator / self.fps_denominator

    def as_dict(self) -> dict[str, Any]:
        value = dataclasses.asdict(self)
        value["fps"] = self.fps
        return value


@dataclasses.dataclass(frozen=True)
class AudioIdentity:
    codec: str
    profile: str | None
    sample_rate_hz: int
    channels: int
    channel_layout: str

    def as_dict(self) -> dict[str, Any]:
        return dataclasses.asdict(self)


@dataclasses.dataclass(frozen=True)
class AssetIdentity:
    schema: str
    file: FileIdentity
    container: str
    structural_detail: str
    duration_seconds: str
    video: VideoIdentity
    audio: AudioIdentity
    native_eligible: bool
    native_ineligibility_reasons: tuple[str, ...]
    staged_app_path: str | None
    contained_in_staged_app: bool
    staged_app_binding: "StagedAppBinding | None"
    probe: CommandEvidence
    probe_raw_json: str

    def as_dict(self) -> dict[str, Any]:
        return {
            "schema": self.schema,
            "file": self.file.as_dict(),
            "container": self.container,
            "structural_detail": self.structural_detail,
            "duration_seconds": self.duration_seconds,
            "video": self.video.as_dict(),
            "audio": self.audio.as_dict(),
            "native_eligible": self.native_eligible,
            "native_ineligibility_reasons": list(
                self.native_ineligibility_reasons
            ),
            "staged_app_path": self.staged_app_path,
            "contained_in_staged_app": self.contained_in_staged_app,
            "staged_app_binding": (
                self.staged_app_binding.as_dict()
                if self.staged_app_binding is not None
                else None
            ),
            "probe": self.probe.as_dict(),
            "probe_raw_json": self.probe_raw_json,
        }

    @property
    def asset_sha256(self) -> str:
        return _canonical_sha256(self.as_dict())


@dataclasses.dataclass(frozen=True)
class ManifestEntry:
    path: str
    kind: str
    mode: int
    size_bytes: int
    sha256: str | None
    symlink_target: str | None
    stat: FileStatIdentity
    extended_metadata_sha256: str

    def canonical_record(self) -> dict[str, Any]:
        return {
            "kind": self.kind,
            "mode": self.mode,
            "path": self.path,
            "sha256": self.sha256,
            "size_bytes": self.size_bytes,
            "symlink_target": self.symlink_target,
            "extended_metadata_sha256": self.extended_metadata_sha256,
        }

    def as_dict(self) -> dict[str, Any]:
        value = self.canonical_record()
        value["stat"] = self.stat.as_dict()
        return value


@dataclasses.dataclass(frozen=True)
class ContentsManifest:
    schema: str
    app_path: str
    contents_path: str
    app_root_stat: FileStatIdentity
    app_root_extended_metadata_sha256: str
    root_stat: FileStatIdentity
    root_extended_metadata_sha256: str
    entries: tuple[ManifestEntry, ...]
    tree_sha256: str

    def as_dict(self) -> dict[str, Any]:
        return {
            "schema": self.schema,
            "app_path": self.app_path,
            "contents_path": self.contents_path,
            "app_root_stat": self.app_root_stat.as_dict(),
            "app_root_extended_metadata_sha256": self.app_root_extended_metadata_sha256,
            "root_stat": self.root_stat.as_dict(),
            "root_extended_metadata_sha256": self.root_extended_metadata_sha256,
            "entries": [entry.as_dict() for entry in self.entries],
            "tree_sha256": self.tree_sha256,
        }


@dataclasses.dataclass(frozen=True)
class CodeLeafEvidence:
    relative_path: str
    sha256: str
    codesign: CommandEvidence

    def as_dict(self) -> dict[str, Any]:
        return {
            "relative_path": self.relative_path,
            "sha256": self.sha256,
            "codesign": self.codesign.as_dict(),
        }


@dataclasses.dataclass(frozen=True)
class StagedAppBinding:
    app_identity_sha256: str
    app_path: str
    manifest_tree_sha256: str
    app_root_stat: FileStatIdentity
    root_stat: FileStatIdentity
    entry: ManifestEntry

    def as_dict(self) -> dict[str, Any]:
        return {
            "app_identity_sha256": self.app_identity_sha256,
            "app_path": self.app_path,
            "manifest_tree_sha256": self.manifest_tree_sha256,
            "app_root_stat": self.app_root_stat.as_dict(),
            "root_stat": self.root_stat.as_dict(),
            "entry": self.entry.as_dict(),
        }


@dataclasses.dataclass(frozen=True)
class AppIdentity:
    schema: str
    app_path: str
    manifest: ContentsManifest
    bundle_identifier: str
    bundle_short_version: str
    bundle_version: str
    executable_relative_path: str
    executable: FileIdentity
    info_plist: FileIdentity
    codesign: CommandEvidence
    code_leaves: tuple[CodeLeafEvidence, ...]

    def as_dict(self) -> dict[str, Any]:
        candidate_record = _app_candidate_record(self)
        value = {
            "schema": self.schema,
            "app_path": self.app_path,
            "manifest": self.manifest.as_dict(),
            "bundle_identifier": self.bundle_identifier,
            "bundle_short_version": self.bundle_short_version,
            "bundle_version": self.bundle_version,
            "executable_relative_path": self.executable_relative_path,
            "executable": self.executable.as_dict(),
            "info_plist": self.info_plist.as_dict(),
            "codesign": self.codesign.as_dict(),
            "code_leaves": [leaf.as_dict() for leaf in self.code_leaves],
            "candidate_record": candidate_record,
        }
        value["candidate_sha256"] = _canonical_sha256(candidate_record)
        return value

    @property
    def candidate_sha256(self) -> str:
        return _canonical_sha256(_app_candidate_record(self))


def _require_absolute_path(value: os.PathLike[str] | str, label: str) -> str:
    path = os.fspath(value)
    if not path or not os.path.isabs(path):
        raise IdentityError(f"{label} must be an absolute path")
    return os.path.normpath(path)


def _canonical_sha256(value: Mapping[str, Any]) -> str:
    encoded = json.dumps(
        value,
        ensure_ascii=False,
        allow_nan=False,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def _reject_duplicate_pairs(pairs: Sequence[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise IdentityError(f"JSON object contains duplicate key {key!r}")
        result[key] = value
    return result


_LIBC = ctypes.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True)
_LIBC.flistxattr.argtypes = [
    ctypes.c_int,
    ctypes.c_void_p,
    ctypes.c_size_t,
    ctypes.c_int,
]
_LIBC.flistxattr.restype = ctypes.c_ssize_t
_LIBC.fgetxattr.argtypes = [
    ctypes.c_int,
    ctypes.c_char_p,
    ctypes.c_void_p,
    ctypes.c_size_t,
    ctypes.c_uint32,
    ctypes.c_int,
]
_LIBC.fgetxattr.restype = ctypes.c_ssize_t
_LIBC.fsetxattr.argtypes = [
    ctypes.c_int,
    ctypes.c_char_p,
    ctypes.c_void_p,
    ctypes.c_size_t,
    ctypes.c_uint32,
    ctypes.c_int,
]
_LIBC.fsetxattr.restype = ctypes.c_int
_LIBC.fremovexattr.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int]
_LIBC.fremovexattr.restype = ctypes.c_int
_LIBC.acl_get_fd_np.argtypes = [ctypes.c_int, ctypes.c_int]
_LIBC.acl_get_fd_np.restype = ctypes.c_void_p
_LIBC.acl_get_entry.argtypes = [
    ctypes.c_void_p,
    ctypes.c_int,
    ctypes.POINTER(ctypes.c_void_p),
]
_LIBC.acl_get_entry.restype = ctypes.c_int
_LIBC.acl_free.argtypes = [ctypes.c_void_p]
_LIBC.acl_free.restype = ctypes.c_int
_ACL_TYPE_EXTENDED = 0x00000100
_ACL_FIRST_ENTRY = 0
_MAX_XATTR_BYTES = 16 * 1024 * 1024


def _extended_metadata_items(fd: int, *, label: str) -> tuple[tuple[bytes, bytes], ...]:
    """Read every xattr and reject unrepresented extended ACLs."""

    ctypes.set_errno(0)
    acl = _LIBC.acl_get_fd_np(fd, _ACL_TYPE_EXTENDED)
    if acl:
        try:
            entry = ctypes.c_void_p()
            result = _LIBC.acl_get_entry(acl, _ACL_FIRST_ENTRY, ctypes.byref(entry))
            if result == 0:
                raise IdentityError(
                    f"{label} has an extended ACL which is not admitted by the campaign"
                )
            if ctypes.get_errno() not in {0, errno.ENOENT}:
                raise IdentityError(f"could not inspect {label} extended ACL")
        finally:
            _LIBC.acl_free(acl)
    elif ctypes.get_errno() not in {0, errno.ENOENT}:
        raise IdentityError(f"could not inspect {label} extended ACL")

    ctypes.set_errno(0)
    names_size = int(_LIBC.flistxattr(fd, None, 0, 0))
    if names_size < 0:
        raise IdentityError(f"could not enumerate {label} extended attributes")
    if names_size > _MAX_XATTR_BYTES:
        raise IdentityError(f"{label} extended-attribute names exceed the bound")
    names_data = b""
    if names_size:
        names_buffer = ctypes.create_string_buffer(names_size)
        observed = int(_LIBC.flistxattr(fd, names_buffer, names_size, 0))
        if observed != names_size:
            raise IdentityError(f"{label} extended attributes changed while enumerating")
        names_data = names_buffer.raw[:observed]
    names = sorted(name for name in names_data.split(b"\0") if name)
    if len(names) != len(set(names)):
        raise IdentityError(f"{label} has duplicate extended-attribute names")

    total = 0
    items: list[tuple[bytes, bytes]] = []
    for name in names:
        ctypes.set_errno(0)
        size = int(_LIBC.fgetxattr(fd, name, None, 0, 0, 0))
        if size < 0 or size > _MAX_XATTR_BYTES - total:
            raise IdentityError(f"could not read bounded {label} extended attribute")
        buffer = ctypes.create_string_buffer(size) if size else None
        value_pointer = buffer if buffer is not None else None
        observed = int(_LIBC.fgetxattr(fd, name, value_pointer, size, 0, 0))
        if observed != size:
            raise IdentityError(f"{label} extended attributes changed while reading")
        value = buffer.raw[:size] if buffer is not None else b""
        total += size
        items.append((name, value))
    return tuple(items)


def _extended_metadata_digest(items: Sequence[tuple[bytes, bytes]]) -> str:
    digest = hashlib.sha256()
    digest.update(b"wam.macos.extended-metadata.v1\0")
    for name, value in items:
        digest.update(struct.pack(">I", len(name)))
        digest.update(name)
        digest.update(struct.pack(">Q", len(value)))
        digest.update(value)
    return digest.hexdigest()


def _extended_metadata_sha256(fd: int, *, label: str) -> str:
    return _extended_metadata_digest(_extended_metadata_items(fd, label=label))


def _copy_extended_metadata(
    source_fd: int,
    destination_fd: int,
    *,
    label: str,
    allow_automatic_provenance: bool = False,
) -> None:
    items = _extended_metadata_items(source_fd, label=f"source {label}")
    destination_items = _extended_metadata_items(
        destination_fd, label=f"initial snapshot {label}"
    )
    for name, _ in destination_items:
        ctypes.set_errno(0)
        if int(_LIBC.fremovexattr(destination_fd, name, 0)) != 0:
            error_number = ctypes.get_errno()
            raise IdentityError(
                f"could not clear automatic {label} extended attribute: "
                f"{os.strerror(error_number)}"
            )
    for name, value in items:
        buffer = ctypes.create_string_buffer(value) if value else None
        ctypes.set_errno(0)
        result = int(
            _LIBC.fsetxattr(
                destination_fd,
                name,
                buffer if buffer is not None else None,
                len(value),
                0,
                0,
            )
        )
        if result != 0:
            error_number = ctypes.get_errno()
            raise IdentityError(
                f"could not copy {label} extended attribute: "
                f"{os.strerror(error_number)}"
            )
    observed = _extended_metadata_items(destination_fd, label=f"snapshot {label}")
    admissible = items
    if allow_automatic_provenance:
        observed = tuple(
            item for item in observed if item[0] != b"com.apple.provenance"
        )
        admissible = tuple(
            item for item in items if item[0] != b"com.apple.provenance"
        )
    if observed != admissible:
        raise IdentityError(f"{label} extended metadata changed in the private snapshot")


def _open_absolute_nofollow(
    path: str, *, label: str, final_flags: int
) -> tuple[int, tuple[FileStatIdentity, ...]]:
    """Open every absolute path component with O_NOFOLLOW."""

    normalized = _require_absolute_path(path, label)
    components = tuple(part for part in normalized.split("/") if part)
    if not components:
        raise IdentityError(f"{label} cannot name the filesystem root")
    directory_flags = (
        os.O_RDONLY
        | getattr(os, "O_CLOEXEC", 0)
        | getattr(os, "O_DIRECTORY", 0)
        | getattr(os, "O_NOFOLLOW", 0)
    )
    descriptors: list[int] = []
    identities: list[FileStatIdentity] = []
    try:
        current = os.open("/", directory_flags)
        descriptors.append(current)
        identities.append(FileStatIdentity.from_stat(os.fstat(current)))
        for component in components[:-1]:
            current = os.open(component, directory_flags, dir_fd=current)
            descriptors.append(current)
            identities.append(FileStatIdentity.from_stat(os.fstat(current)))
        fd = os.open(
            components[-1],
            final_flags | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0),
            dir_fd=current,
        )
        identities.append(FileStatIdentity.from_stat(os.fstat(fd)))
    except OSError as error:
        raise IdentityError(
            f"could not open {label} without following any path component: {error}"
        ) from error
    finally:
        for descriptor in reversed(descriptors):
            os.close(descriptor)
    return fd, tuple(identities)


def _verify_absolute_binding(
    path: str,
    expected_fd: int,
    expected_chain: tuple[FileStatIdentity, ...],
    *,
    label: str,
    final_flags: int,
) -> None:
    rebound_fd, rebound_chain = _open_absolute_nofollow(
        path, label=label, final_flags=final_flags
    )
    try:
        # Directory mtimes/ctimes may legitimately move when the harness
        # creates its private tool snapshot beneath the same temporary tree.
        # Device/inode/type bind every ancestor without falsely treating an
        # unrelated sibling creation as a path rebind. The final file retains
        # full stat/metadata comparison below.
        chain_matches = len(rebound_chain) == len(expected_chain) and all(
            (left.device, left.inode, stat.S_IFMT(left.mode))
            == (right.device, right.inode, stat.S_IFMT(right.mode))
            for left, right in zip(rebound_chain[:-1], expected_chain[:-1])
        )
        if not chain_matches or FileStatIdentity.from_stat(
            os.fstat(rebound_fd)
        ) != FileStatIdentity.from_stat(os.fstat(expected_fd)):
            raise IdentityError(f"{label} path or an ancestor was rebound")
    finally:
        os.close(rebound_fd)


def _resolved_path_binding(
    requested: str, canonical: str, *, label: str
) -> None:
    try:
        observed = os.path.realpath(requested)
    except OSError as error:
        raise IdentityError(f"could not resolve {label}: {error}") from error
    if observed != canonical:
        raise IdentityError(f"{label} path or an ancestor was rebound")


def _stat_is_stable(
    before: FileStatIdentity,
    after: FileStatIdentity,
    *,
    label: str,
) -> None:
    if before != after:
        raise IdentityError(f"{label} changed while its identity was captured")


def _hash_open_file(fd: int, expected_size: int, *, label: str) -> str:
    os.lseek(fd, 0, os.SEEK_SET)
    digest = hashlib.sha256()
    total = 0
    while True:
        chunk = os.read(fd, HASH_CHUNK_BYTES)
        if not chunk:
            break
        digest.update(chunk)
        total += len(chunk)
    if total != expected_size:
        raise IdentityError(
            f"{label} size changed while hashing: expected {expected_size}, "
            f"read {total}"
        )
    return digest.hexdigest()


def _open_regular_nofollow(
    path: str,
    *,
    label: str,
    dir_fd: int | None = None,
) -> int:
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0)
    flags |= getattr(os, "O_NOFOLLOW", 0)
    try:
        fd = os.open(path, flags, dir_fd=dir_fd)
    except OSError as error:
        raise IdentityError(
            f"could not open {label} without following links: {error}"
        ) from error
    try:
        value = os.fstat(fd)
        if not stat.S_ISREG(value.st_mode):
            raise IdentityError(f"{label} is not a regular file")
    except BaseException:
        os.close(fd)
        raise
    return fd


def _identity_from_open_fd(
    fd: int,
    *,
    requested_path: str,
    canonical_path: str,
    label: str,
) -> FileIdentity:
    before = FileStatIdentity.from_stat(os.fstat(fd))
    if not stat.S_ISREG(before.mode):
        raise IdentityError(f"{label} is not a regular file")
    digest = _hash_open_file(fd, before.size_bytes, label=label)
    extended_metadata = _extended_metadata_sha256(fd, label=label)
    after = FileStatIdentity.from_stat(os.fstat(fd))
    _stat_is_stable(before, after, label=label)
    return FileIdentity(
        requested_path=requested_path,
        canonical_path=canonical_path,
        sha256=digest,
        stat=before,
        extended_metadata_sha256=extended_metadata,
    )


def capture_tool_identity(
    path: os.PathLike[str] | str,
    *,
    label: str,
) -> FileIdentity:
    requested = _require_absolute_path(path, label)
    canonical = requested
    flags = os.O_RDONLY
    fd, chain = _open_absolute_nofollow(
        canonical, label=label, final_flags=flags
    )
    try:
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            raise IdentityError(f"{label} is not a regular file")
        identity = _identity_from_open_fd(
            fd,
            requested_path=requested,
            canonical_path=canonical,
            label=label,
        )
        _verify_absolute_binding(
            canonical,
            fd,
            chain,
            label=label,
            final_flags=flags,
        )
        identity = dataclasses.replace(identity, path_ancestry=chain)
    finally:
        os.close(fd)
    if identity.stat.mode & 0o111 == 0:
        raise IdentityError(f"{label} is not executable")
    return identity


def _same_file_identity(
    left: FileIdentity,
    right: FileIdentity,
    *,
    compare_paths: bool = True,
    compare_ancestry: bool = True,
) -> bool:
    if compare_paths and (
        left.requested_path != right.requested_path
        or left.canonical_path != right.canonical_path
    ):
        return False
    if (
        left.sha256 != right.sha256
        or left.stat != right.stat
        or left.extended_metadata_sha256 != right.extended_metadata_sha256
    ):
        return False
    if not compare_ancestry:
        return True
    if len(left.path_ancestry) != len(right.path_ancestry):
        return False
    return all(
        (a.device, a.inode, stat.S_IFMT(a.mode))
        == (b.device, b.inode, stat.S_IFMT(b.mode))
        for a, b in zip(left.path_ancestry, right.path_ancestry)
    )


def _bounded_command_runner(
    argv: Sequence[str],
    pass_fds: tuple[int, ...],
    timeout_s: float,
    max_output_bytes: int,
) -> CommandResult:
    if not argv or not os.path.isabs(argv[0]):
        raise IdentityError("external command executable must be absolute")
    if not math.isfinite(timeout_s) or timeout_s <= 0:
        raise IdentityError("external command timeout must be finite and positive")
    if isinstance(max_output_bytes, bool) or max_output_bytes <= 0:
        raise IdentityError("external command output bound must be positive")

    try:
        process = subprocess.Popen(
            list(argv),
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            close_fds=True,
            pass_fds=pass_fds,
            env=dict(SANITIZED_COMMAND_ENVIRONMENT),
        )
    except OSError as error:
        raise IdentityError(f"could not execute {argv[0]}: {error}") from error

    assert process.stdout is not None
    assert process.stderr is not None
    selector = selectors.DefaultSelector()
    streams = {process.stdout: bytearray(), process.stderr: bytearray()}
    try:
        for stream in streams:
            os.set_blocking(stream.fileno(), False)
            selector.register(stream, selectors.EVENT_READ)
        deadline = time.monotonic() + timeout_s
        while selector.get_map():
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise IdentityError(f"external command timed out after {timeout_s}s")
            for key, _ in selector.select(min(remaining, 0.1)):
                stream = key.fileobj
                chunk = os.read(stream.fileno(), 65536)
                if not chunk:
                    selector.unregister(stream)
                    continue
                target = streams[stream]
                target.extend(chunk)
                if len(target) > max_output_bytes:
                    raise IdentityError(
                        f"external command exceeded {max_output_bytes} bytes "
                        f"on one output stream"
                    )
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise IdentityError(f"external command timed out after {timeout_s}s")
        returncode = process.wait(timeout=remaining)
    except BaseException:
        if process.poll() is None:
            process.send_signal(signal.SIGKILL)
            process.wait()
        raise
    finally:
        selector.close()
        process.stdout.close()
        process.stderr.close()

    return CommandResult(
        returncode=int(returncode),
        stdout=bytes(streams[process.stdout]),
        stderr=bytes(streams[process.stderr]),
    )


def _coerce_command_result(value: Any) -> CommandResult:
    if isinstance(value, CommandResult):
        result = value
    elif isinstance(value, subprocess.CompletedProcess):
        result = CommandResult(value.returncode, value.stdout, value.stderr)
    else:
        raise IdentityError("injected command runner returned an unsupported result")
    if isinstance(result.returncode, bool) or not isinstance(result.returncode, int):
        raise IdentityError("external command return code is not an integer")
    if not isinstance(result.stdout, bytes) or not isinstance(result.stderr, bytes):
        raise IdentityError("external command output must be bytes")
    return result


def _run_identified_command(
    tool: FileIdentity,
    arguments: Sequence[str],
    *,
    runner: CommandRunner | None,
    executed_arguments: Sequence[str] | None = None,
    pass_fds: tuple[int, ...] = (),
    targets: tuple[CommandTargetIdentity, ...] = (),
    timeout_s: float = DEFAULT_TOOL_TIMEOUT_S,
    max_output_bytes: int = DEFAULT_MAX_TOOL_OUTPUT_BYTES,
) -> CommandEvidence:
    """Execute one command while retaining source, exec, fd, and target facts.

    ``runner`` is deliberately a one-way test seam: evidence emitted through it
    is structurally untrusted and cannot be converted into shipping evidence.
    Production always executes the verified private tool snapshot.
    """

    if len(set(pass_fds)) != len(pass_fds) or any(
        isinstance(value, bool) or not isinstance(value, int) or value < 0
        for value in pass_fds
    ):
        raise IdentityError("external command pass_fds must be unique descriptors")
    for target in targets:
        if target.descriptor is not None:
            if target.descriptor not in pass_fds or target.file is None:
                raise IdentityError("descriptor command target is not bound to pass_fds")
            actual = _identity_from_open_fd(
                target.descriptor,
                requested_path=f"/dev/fd/{target.descriptor}",
                canonical_path=f"/dev/fd/{target.descriptor}",
                label=f"{target.role} descriptor",
            )
            if not _same_file_identity(
                target.file,
                actual,
                compare_paths=False,
                compare_ancestry=False,
            ):
                raise IdentityError(f"{target.role} descriptor identity mismatch")
            if target.executed_argument not in tuple(
                executed_arguments if executed_arguments is not None else arguments
            ):
                raise IdentityError(f"{target.role} descriptor argument is not executed")

    tool_fd, tool_chain = _open_absolute_nofollow(
        tool.canonical_path, label="identified command", final_flags=os.O_RDONLY
    )
    try:
        opened_tool = _identity_from_open_fd(
            tool_fd,
            requested_path=tool.requested_path,
            canonical_path=tool.canonical_path,
            label="identified command",
        )
        opened_tool = dataclasses.replace(opened_tool, path_ancestry=tool_chain)
        if not _same_file_identity(opened_tool, tool):
            raise IdentityError("identified command changed before execution")
        source_arguments = tuple(arguments)
        actual_arguments = tuple(
            executed_arguments if executed_arguments is not None else source_arguments
        )
        source_argv = (tool.canonical_path, *source_arguments)
        snapshot_root_stat: FileStatIdentity | None = None
        snapshot_root_metadata: str | None = None
        if runner is None:
            snapshot_directory = os.path.realpath(
                tempfile.mkdtemp(prefix="wam-shipper-tool-")
            )
            snapshot_path = os.path.join(snapshot_directory, "tool")
            snapshot_root_fd = -1
            snapshot_fd = -1
            try:
                os.chmod(snapshot_directory, 0o700)
                snapshot_root_fd = os.open(
                    snapshot_directory,
                    os.O_RDONLY
                    | getattr(os, "O_CLOEXEC", 0)
                    | getattr(os, "O_DIRECTORY", 0)
                    | getattr(os, "O_NOFOLLOW", 0),
                )
                snapshot_fd = os.open(
                    "tool",
                    os.O_WRONLY
                    | os.O_CREAT
                    | os.O_EXCL
                    | getattr(os, "O_CLOEXEC", 0)
                    | getattr(os, "O_NOFOLLOW", 0),
                    0o600,
                    dir_fd=snapshot_root_fd,
                )
                os.lseek(tool_fd, 0, os.SEEK_SET)
                remaining = tool.stat.size_bytes
                while remaining:
                    chunk = os.read(tool_fd, min(HASH_CHUNK_BYTES, remaining))
                    if not chunk:
                        raise IdentityError("identified tool snapshot was truncated")
                    view = memoryview(chunk)
                    while view:
                        written = os.write(snapshot_fd, view)
                        if written <= 0:
                            raise IdentityError("identified tool snapshot write failed")
                        view = view[written:]
                    remaining -= len(chunk)
                _copy_extended_metadata(
                    tool_fd,
                    snapshot_fd,
                    label="identified tool",
                    allow_automatic_provenance=True,
                )
                os.fchmod(snapshot_fd, 0o500)
                os.fsync(snapshot_fd)
                os.close(snapshot_fd)
                snapshot_fd = -1
                os.fsync(snapshot_root_fd)
                snapshot_root_stat = FileStatIdentity.from_stat(
                    os.fstat(snapshot_root_fd)
                )
                snapshot_root_metadata = _extended_metadata_sha256(
                    snapshot_root_fd, label="private tool snapshot root"
                )
                executed_tool = capture_tool_identity(
                    snapshot_path, label="executed command snapshot"
                )
                if executed_tool.sha256 != tool.sha256:
                    raise IdentityError("identified tool snapshot hash mismatch")
                if stat.S_IMODE(executed_tool.stat.mode) != 0o500:
                    raise IdentityError("identified tool snapshot mode is not 0500")
                actual_argv = (snapshot_path, *actual_arguments)
                result = _coerce_command_result(
                    _bounded_command_runner(
                        actual_argv, pass_fds, timeout_s, max_output_bytes
                    )
                )
                executed_after = capture_tool_identity(
                    snapshot_path, label="executed command snapshot after execution"
                )
                if not _same_file_identity(executed_tool, executed_after):
                    raise IdentityError("executed command snapshot changed during execution")
                if FileStatIdentity.from_stat(os.fstat(snapshot_root_fd)) != snapshot_root_stat:
                    raise IdentityError("private tool snapshot root changed during execution")
                if _extended_metadata_sha256(
                    snapshot_root_fd, label="private tool snapshot root after execution"
                ) != snapshot_root_metadata:
                    raise IdentityError(
                        "private tool snapshot root metadata changed during execution"
                    )
            finally:
                if snapshot_fd >= 0:
                    os.close(snapshot_fd)
                if snapshot_root_fd >= 0:
                    os.close(snapshot_root_fd)
                shutil.rmtree(snapshot_directory)
            trusted_execution = True
            execution_receipt_id = str(uuid.uuid4())
        else:
            actual_argv = (tool.canonical_path, *actual_arguments)
            executed_tool = tool
            try:
                result = _coerce_command_result(
                    runner(actual_argv, pass_fds, timeout_s, max_output_bytes)
                )
            except IdentityError:
                raise
            except BaseException as error:
                raise IdentityError(f"external command runner failed: {error}") from error
            trusted_execution = False
            execution_receipt_id = None
        if _identity_from_open_fd(
            tool_fd,
            requested_path=tool.requested_path,
            canonical_path=tool.canonical_path,
            label="identified command after execution",
        ).sha256 != tool.sha256:
            raise IdentityError("identified command bytes changed during execution")
        _verify_absolute_binding(
            tool.canonical_path,
            tool_fd,
            tool_chain,
            label="identified command after execution",
            final_flags=os.O_RDONLY,
        )
        rebound_tool = capture_tool_identity(
            tool.canonical_path, label="identified command after execution"
        )
        if not _same_file_identity(rebound_tool, tool):
            raise IdentityError("identified command path changed during execution")
    finally:
        os.close(tool_fd)
    if len(result.stdout) > max_output_bytes or len(result.stderr) > max_output_bytes:
        raise IdentityError("external command runner returned output beyond its bound")
    try:
        stdout_text = result.stdout.decode("utf-8", errors="strict")
        stderr_text = result.stderr.decode("utf-8", errors="strict")
    except UnicodeDecodeError as error:
        raise IdentityError("external command output was not valid UTF-8") from error
    return CommandEvidence(
        schema=COMMAND_EVIDENCE_SCHEMA,
        argv=source_argv,
        returncode=result.returncode,
        stdout_text=stdout_text,
        stderr_text=stderr_text,
        stdout_bytes=len(result.stdout),
        stderr_bytes=len(result.stderr),
        stdout_sha256=hashlib.sha256(result.stdout).hexdigest(),
        stderr_sha256=hashlib.sha256(result.stderr).hexdigest(),
        tool=tool,
        executed_tool=executed_tool,
        executed_argv=actual_argv,
        sanitized_environment=SANITIZED_COMMAND_ENVIRONMENT,
        trusted_execution=trusted_execution,
        pass_fds=pass_fds,
        targets=targets,
        private_snapshot_root_stat=snapshot_root_stat,
        private_snapshot_root_extended_metadata_sha256=snapshot_root_metadata,
        execution_receipt_id=execution_receipt_id,
    )


def _read_prefix(fd: int, maximum: int) -> bytes:
    os.lseek(fd, 0, os.SEEK_SET)
    chunks: list[bytes] = []
    remaining = maximum
    while remaining:
        chunk = os.read(fd, min(remaining, 65536))
        if not chunk:
            break
        chunks.append(chunk)
        remaining -= len(chunk)
    return b"".join(chunks)


def _macho_structure_is_valid(fd: int, size_bytes: int) -> bool:
    """Validate bounded Mach-O/fat headers and load-command layout."""

    if size_bytes < 8:
        return False
    os.lseek(fd, 0, os.SEEK_SET)
    prefix = os.read(fd, min(size_bytes, 32))
    magic = prefix[:4]
    thin = {
        b"\xfe\xed\xfa\xce": (">", 28),
        b"\xce\xfa\xed\xfe": ("<", 28),
        b"\xfe\xed\xfa\xcf": (">", 32),
        b"\xcf\xfa\xed\xfe": ("<", 32),
    }
    if magic in thin:
        endian, header_size = thin[magic]
        if size_bytes < header_size:
            return False
        os.lseek(fd, 0, os.SEEK_SET)
        header = os.read(fd, header_size)
        if len(header) != header_size:
            return False
        values = struct.unpack(
            endian + ("7I" if header_size == 28 else "8I"), header
        )
        _, cpu_type, _, file_type, command_count, command_bytes, _, *rest = values
        if (
            cpu_type == 0
            or file_type == 0
            or command_count > 65535
            or command_bytes > size_bytes - header_size
        ):
            return False
        commands = os.read(fd, command_bytes)
        if len(commands) != command_bytes:
            return False
        cursor = 0
        alignment = 8 if header_size == 32 else 4
        for _ in range(command_count):
            if cursor + 8 > len(commands):
                return False
            _, command_size = struct.unpack_from(endian + "II", commands, cursor)
            if (
                command_size < 8
                or command_size % alignment
                or cursor + command_size > len(commands)
            ):
                return False
            cursor += command_size
        return cursor == len(commands)

    fat = {
        b"\xca\xfe\xba\xbe": (">", 20),
        b"\xbe\xba\xfe\xca": ("<", 20),
        b"\xca\xfe\xba\xbf": (">", 32),
        b"\xbf\xba\xfe\xca": ("<", 32),
    }
    if magic not in fat:
        return False
    endian, architecture_size = fat[magic]
    architecture_count = struct.unpack(endian + "I", prefix[4:8])[0]
    if architecture_count == 0 or architecture_count > 4096:
        return False
    table_size = 8 + architecture_count * architecture_size
    if table_size > size_bytes:
        return False
    os.lseek(fd, 8, os.SEEK_SET)
    table = os.read(fd, architecture_count * architecture_size)
    if len(table) != architecture_count * architecture_size:
        return False
    ranges: list[tuple[int, int]] = []
    for index in range(architecture_count):
        offset = index * architecture_size
        if architecture_size == 20:
            cpu_type, _, slice_offset, slice_size, align = struct.unpack_from(
                endian + "IIIII", table, offset
            )
        else:
            cpu_type, _, slice_offset, slice_size, align, _ = struct.unpack_from(
                endian + "IIQQII", table, offset
            )
        if (
            cpu_type == 0
            or slice_size < 28
            or slice_offset < table_size
            or slice_offset + slice_size > size_bytes
            or align > 63
            or slice_offset % (1 << align)
        ):
            return False
        ranges.append((slice_offset, slice_offset + slice_size))
    ranges.sort()
    return not any(
        left[1] > right[0] for left, right in zip(ranges, ranges[1:])
    )


def _parse_ebml_vint(data: bytes, offset: int, *, keep_marker: bool) -> tuple[int, int]:
    if offset >= len(data) or data[offset] == 0:
        raise IdentityError("malformed EBML variable-length integer")
    first = data[offset]
    mask = 0x80
    width = 1
    while width <= 8 and first & mask == 0:
        mask >>= 1
        width += 1
    if width > 8 or offset + width > len(data):
        raise IdentityError("truncated EBML variable-length integer")
    value = first if keep_marker else first & (mask - 1)
    for byte in data[offset + 1 : offset + width]:
        value = (value << 8) | byte
    if not keep_marker and value == (1 << (7 * width)) - 1:
        raise IdentityError("unknown-length EBML header is not accepted")
    return value, width


def _structural_container(prefix: bytes, total_size: int) -> tuple[str, str]:
    if len(prefix) >= 16 and prefix[4:8] == b"ftyp":
        box_size = struct.unpack(">I", prefix[:4])[0]
        header_size = 8
        if box_size == 1:
            if len(prefix) < 24:
                raise IdentityError("truncated extended ISO BMFF ftyp box")
            box_size = struct.unpack(">Q", prefix[8:16])[0]
            header_size = 16
        if box_size < header_size + 8 or box_size > total_size or box_size > len(prefix):
            raise IdentityError("invalid ISO BMFF ftyp box size")
        payload = prefix[header_size:box_size]
        if (len(payload) - 8) % 4 != 0:
            raise IdentityError("malformed ISO BMFF compatible-brand list")
        major = payload[:4]
        compatible = tuple(
            payload[index : index + 4]
            for index in range(8, len(payload), 4)
        )
        brands = (major, *compatible)
        if major == b"qt  ":
            if any(brand != b"qt  " for brand in brands):
                raise IdentityError("ambiguous QuickTime/MP4 ftyp brands")
            return "mov", "ftyp:qt"
        if b"qt  " in brands:
            raise IdentityError("ambiguous QuickTime/MP4 ftyp brands")
        if not all(
            len(brand) == 4 and all(32 <= byte <= 126 for byte in brand)
            for brand in brands
        ):
            raise IdentityError("invalid ISO BMFF brand bytes")
        recognized = (
            major.startswith(b"iso")
            or major.startswith(b"mp4")
            or major in {b"avc1", b"hvc1", b"hev1", b"M4V ", b"M4A ", b"MSNV"}
        )
        if not recognized:
            raise IdentityError(f"unsupported ISO BMFF major brand {major!r}")
        return "mp4", f"ftyp:{major.decode('ascii')}"

    if prefix.startswith(b"\x1a\x45\xdf\xa3"):
        header_size, size_width = _parse_ebml_vint(prefix, 4, keep_marker=False)
        start = 4 + size_width
        end = start + header_size
        if end > len(prefix) or end > total_size:
            raise IdentityError("truncated EBML header")
        doctype: str | None = None
        cursor = start
        while cursor < end:
            element_id, id_width = _parse_ebml_vint(prefix, cursor, keep_marker=True)
            cursor += id_width
            element_size, element_width = _parse_ebml_vint(
                prefix, cursor, keep_marker=False
            )
            cursor += element_width
            element_end = cursor + element_size
            if element_end > end:
                raise IdentityError("EBML element escapes its header")
            if element_id == 0x4282:
                if doctype is not None:
                    raise IdentityError("EBML header contains duplicate DocType")
                try:
                    doctype = prefix[cursor:element_end].decode("ascii", errors="strict")
                except UnicodeDecodeError as error:
                    raise IdentityError("EBML DocType is not ASCII") from error
            cursor = element_end
        if cursor != end or doctype not in {"matroska", "webm"}:
            raise IdentityError("EBML DocType is missing or unsupported")
        if doctype == "matroska":
            return "mkv", "ebml:matroska"
        return "webm", "ebml:webm"

    raise IdentityError("asset is neither a supported ftyp nor EBML container")


def _strict_json_object(text: str) -> Mapping[str, Any]:
    def pairs(values: list[tuple[str, Any]]) -> dict[str, Any]:
        result: dict[str, Any] = {}
        for key, value in values:
            if key in result:
                raise IdentityError(f"probe JSON contains duplicate key {key!r}")
            result[key] = value
        return result

    def reject_constant(value: str) -> Any:
        raise IdentityError(f"probe JSON contains non-finite value {value}")

    try:
        parsed = json.loads(
            text,
            object_pairs_hook=pairs,
            parse_constant=reject_constant,
        )
    except IdentityError:
        raise
    except (json.JSONDecodeError, TypeError) as error:
        raise IdentityError(f"probe did not emit valid JSON: {error}") from error
    if not isinstance(parsed, dict):
        raise IdentityError("probe JSON root must be an object")
    return parsed


def _required_string(value: Mapping[str, Any], key: str, label: str) -> str:
    item = value.get(key)
    if not isinstance(item, str) or not item or "\x00" in item:
        raise IdentityError(f"{label}.{key} must be a non-empty string")
    return item


def _required_positive_int(value: Mapping[str, Any], key: str, label: str) -> int:
    item = value.get(key)
    if isinstance(item, str) and item.isascii() and item.isdigit():
        item = int(item)
    if isinstance(item, bool) or not isinstance(item, int) or item <= 0:
        raise IdentityError(f"{label}.{key} must be a positive integer")
    return item


def _normalized_profile(value: str) -> str:
    normalized = "".join(character for character in value.lower() if character.isalnum())
    if not normalized:
        raise IdentityError("video profile normalized to an empty value")
    return normalized


def _positive_fraction(value: str, label: str) -> Fraction:
    try:
        result = Fraction(value)
    except (ValueError, ZeroDivisionError) as error:
        raise IdentityError(f"{label} is not a valid rational") from error
    if result <= 0:
        raise IdentityError(f"{label} must be positive")
    return result


def _positive_decimal_string(value: Any, label: str) -> str:
    if not isinstance(value, str) or not value:
        raise IdentityError(f"{label} must be a decimal string")
    try:
        numeric = float(value)
    except ValueError as error:
        raise IdentityError(f"{label} must be a decimal string") from error
    if not math.isfinite(numeric) or numeric <= 0:
        raise IdentityError(f"{label} must be finite and positive")
    # Preserve ffprobe's exact decimal representation as evidence.
    return value


def _probe_container_is_consistent(format_name: str, container: str) -> bool:
    names = {part.strip().lower() for part in format_name.split(",") if part.strip()}
    if container in {"mp4", "mov"}:
        return bool(names & {"mov", "mp4", "m4a", "3gp", "3g2", "mj2"})
    if container == "mkv":
        return "matroska" in names
    if container == "webm":
        return "webm" in names
    return False


def _derive_streams(
    parsed: Mapping[str, Any],
    structural_container: str,
) -> tuple[VideoIdentity, AudioIdentity, str]:
    streams = parsed.get("streams")
    format_value = parsed.get("format")
    if not isinstance(streams, list) or not isinstance(format_value, dict):
        raise IdentityError("probe JSON must contain streams array and format object")
    if len(streams) != 2 or not all(isinstance(stream, dict) for stream in streams):
        raise IdentityError("asset must contain exactly one video and one audio stream")
    videos = [stream for stream in streams if stream.get("codec_type") == "video"]
    audios = [stream for stream in streams if stream.get("codec_type") == "audio"]
    if len(videos) != 1 or len(audios) != 1:
        raise IdentityError("asset must contain exactly one video and one audio stream")
    if format_value.get("nb_streams") not in (None, 2, "2"):
        raise IdentityError("probe format stream count does not match stream inventory")
    format_name = _required_string(format_value, "format_name", "format")
    if not _probe_container_is_consistent(format_name, structural_container):
        raise IdentityError(
            "probe container label is inconsistent with the file structure"
        )
    duration = _positive_decimal_string(format_value.get("duration"), "format.duration")

    video = videos[0]
    codec = _required_string(video, "codec_name", "video").lower()
    profile = _normalized_profile(_required_string(video, "profile", "video"))
    fourcc = _required_string(video, "codec_tag_string", "video")
    if len(fourcc.encode("utf-8")) > 16:
        raise IdentityError("video.codec_tag_string is unreasonably long")
    width = _required_positive_int(video, "width", "video")
    height = _required_positive_int(video, "height", "video")
    if width > 16384 or height > 16384:
        raise IdentityError("video dimensions exceed the accepted probe bound")
    pixel_format = _required_string(video, "pix_fmt", "video").lower()
    fps = _positive_fraction(
        _required_string(video, "avg_frame_rate", "video"),
        "video.avg_frame_rate",
    )
    if fps > 1000:
        raise IdentityError("video frame rate exceeds the accepted probe bound")

    audio = audios[0]
    audio_codec = _required_string(audio, "codec_name", "audio").lower()
    raw_audio_profile = audio.get("profile")
    if raw_audio_profile is None:
        audio_profile = None
    elif isinstance(raw_audio_profile, str) and raw_audio_profile:
        audio_profile = _normalized_profile(raw_audio_profile)
    else:
        raise IdentityError("audio.profile must be a non-empty string when present")
    sample_rate = _required_positive_int(audio, "sample_rate", "audio")
    if sample_rate > 768000:
        raise IdentityError("audio sample rate exceeds the accepted probe bound")
    channels = _required_positive_int(audio, "channels", "audio")
    if channels > 64:
        raise IdentityError("audio channel count exceeds the accepted probe bound")
    channel_layout = _required_string(audio, "channel_layout", "audio").lower()

    return (
        VideoIdentity(
            codec=codec,
            profile=profile,
            fourcc=fourcc,
            width=width,
            height=height,
            pixel_format=pixel_format,
            fps_numerator=fps.numerator,
            fps_denominator=fps.denominator,
        ),
        AudioIdentity(
            codec=audio_codec,
            profile=audio_profile,
            sample_rate_hz=sample_rate,
            channels=channels,
            channel_layout=channel_layout,
        ),
        duration,
    )


def _native_eligibility(
    container: str,
    video: VideoIdentity,
    audio: AudioIdentity,
) -> tuple[bool, tuple[str, ...]]:
    reasons: list[str] = []
    if container not in {"mp4", "mov", "mkv"}:
        reasons.append("container is not in the native shipping matrix")
    if video.codec not in {"h264", "hevc"}:
        reasons.append("video codec is not H.264 or HEVC")
    if audio.codec != "aac":
        reasons.append("audio codec is not AAC")
    if max(video.width, video.height) > 1920 or min(video.width, video.height) > 1080:
        reasons.append("video exceeds the 1920x1080 native corpus bound")
    if video.codec == "h264" and container in {"mp4", "mov"} and video.fourcc != "avc1":
        reasons.append("H.264 ISO BMFF sample entry is not avc1")
    if video.codec == "hevc":
        if video.profile not in {"main", "main10"}:
            reasons.append("HEVC profile is neither Main nor Main 10")
        if container in {"mp4", "mov"} and video.fourcc != "hvc1":
            reasons.append("HEVC ISO BMFF sample entry is not hvc1")
        # ffprobe's pixel-format name is a codec-domain identifier, not a
        # free-form bit-depth description.  Substring matching is unsafe:
        # for example yuv410p is an 8-bit 4:1:0 format even though its name
        # contains the characters "10".  Keep the shipping corpus deliberately
        # narrow and exact so a profile label cannot relabel ambiguous bytes.
        eight_bit_formats = {"nv12", "yuv420p"}
        ten_bit_formats = {
            "p010be",
            "p010le",
            "yuv420p10be",
            "yuv420p10le",
        }
        if video.pixel_format in eight_bit_formats:
            bit_depth = 8
        elif video.pixel_format in ten_bit_formats:
            bit_depth = 10
        else:
            bit_depth = None
            reasons.append(
                "HEVC pixel format does not prove an exact supported component bit depth"
            )
        if video.profile == "main10" and bit_depth != 10:
            reasons.append("HEVC Main 10 stream does not report a 10-bit pixel format")
        if video.profile == "main" and bit_depth != 8:
            reasons.append("HEVC Main stream unexpectedly reports a 10-bit pixel format")
    return not reasons, tuple(reasons)


def _is_contained(path: str, directory: str) -> bool:
    try:
        return os.path.commonpath((path, directory)) == directory and path != directory
    except ValueError:
        return False


def capture_asset_identity(
    asset_path: os.PathLike[str] | str,
    *,
    ffprobe_path: os.PathLike[str] | str,
    staged_app_identity: AppIdentity | None = None,
    staged_app_path: os.PathLike[str] | str | None = None,
    probe_runner: CommandRunner | None = None,
    timeout_s: float = DEFAULT_TOOL_TIMEOUT_S,
    max_probe_output_bytes: int = DEFAULT_MAX_TOOL_OUTPUT_BYTES,
) -> AssetIdentity:
    """Capture and strictly derive one exact playable corpus asset."""

    if staged_app_path is not None:
        raise IdentityError(
            "staged_app_path is not sufficient; supply exact staged_app_identity"
        )
    if staged_app_identity is not None and not isinstance(staged_app_identity, AppIdentity):
        raise TypeError("staged_app_identity must be an AppIdentity")
    staged_manifest: ContentsManifest | None = None
    if staged_app_identity is not None:
        staged_manifest = staged_app_identity.manifest
        _verify_source_manifest(staged_manifest)

    requested = _require_absolute_path(asset_path, "asset path")
    try:
        if stat.S_ISLNK(os.lstat(requested).st_mode):
            raise IdentityError("could not open asset without following links")
    except OSError as error:
        raise IdentityError(f"could not stat asset path: {error}") from error
    # `/private/var` is the stable canonical spelling of macOS's `/var`
    # compatibility link.  Capture the resolved path, then reject every link
    # below that boundary and prove the opened inode remains bound to it.
    canonical = os.path.realpath(requested)
    asset_fd, asset_chain = _open_absolute_nofollow(
        canonical, label="asset", final_flags=os.O_RDONLY
    )
    try:
        if not stat.S_ISREG(os.fstat(asset_fd).st_mode):
            raise IdentityError("asset is not a regular file")
        initial_stat = FileStatIdentity.from_stat(os.fstat(asset_fd))
        initial_sha = _hash_open_file(
            asset_fd, initial_stat.size_bytes, label="asset"
        )
        initial_metadata = _extended_metadata_sha256(asset_fd, label="asset")
        asset_file = FileIdentity(
            requested_path=requested,
            canonical_path=canonical,
            sha256=initial_sha,
            stat=initial_stat,
            extended_metadata_sha256=initial_metadata,
            path_ancestry=asset_chain,
        )
        prefix = _read_prefix(
            asset_fd, min(MAX_EBML_HEADER_BYTES, initial_stat.size_bytes)
        )
        container, structural_detail = _structural_container(
            prefix, initial_stat.size_bytes
        )

        probe_tool = capture_tool_identity(ffprobe_path, label="ffprobe")
        os.lseek(asset_fd, 0, os.SEEK_SET)
        probe = _run_identified_command(
            probe_tool,
            (
                "-v",
                "error",
                "-show_streams",
                "-show_format",
                "-of",
                "json",
                f"/dev/fd/{asset_fd}",
            ),
            runner=probe_runner,
            pass_fds=(asset_fd,),
            targets=(
                CommandTargetIdentity(
                    role="media_asset",
                    source_argument=f"/dev/fd/{asset_fd}",
                    executed_argument=f"/dev/fd/{asset_fd}",
                    descriptor=asset_fd,
                    file=asset_file,
                    executed_file=asset_file,
                    contents_tree_sha256=(
                        staged_manifest.tree_sha256
                        if staged_manifest is not None
                        else None
                    ),
                    executed_contents_tree_sha256=None,
                    executed_root_stat=None,
                    executed_root_extended_metadata_sha256=None,
                ),
            ),
            timeout_s=timeout_s,
            max_output_bytes=max_probe_output_bytes,
        )
        if probe.returncode != 0:
            raise IdentityError(
                f"ffprobe failed with exit status {probe.returncode}: "
                f"{probe.stderr_text.strip()}"
            )
        parsed = _strict_json_object(probe.stdout_text)
        video, audio, duration = _derive_streams(parsed, container)

        final_stat = FileStatIdentity.from_stat(os.fstat(asset_fd))
        final_sha = _hash_open_file(asset_fd, final_stat.size_bytes, label="asset")
        final_stat_after_hash = FileStatIdentity.from_stat(os.fstat(asset_fd))
        _stat_is_stable(initial_stat, final_stat, label="asset")
        _stat_is_stable(final_stat, final_stat_after_hash, label="asset")
        if initial_sha != final_sha:
            raise IdentityError("asset bytes changed while ffprobe was running")
        if _extended_metadata_sha256(asset_fd, label="asset after probe") != initial_metadata:
            raise IdentityError("asset extended metadata changed while ffprobe was running")
        _verify_absolute_binding(
            canonical,
            asset_fd,
            asset_chain,
            label="asset path after probe",
            final_flags=os.O_RDONLY,
        )
        _resolved_path_binding(requested, canonical, label="asset path after probe")
        probe_tool_after = capture_tool_identity(ffprobe_path, label="ffprobe")
        if not _same_file_identity(probe_tool_after, probe_tool):
            raise IdentityError("ffprobe changed while it was running")
    finally:
        os.close(asset_fd)

    staged_canonical: str | None = None
    contained = False
    staged_binding: StagedAppBinding | None = None
    if staged_app_identity is not None:
        assert staged_manifest is not None
        staged_canonical = staged_manifest.app_path
        contents = os.path.join(staged_canonical, "Contents")
        contained = _is_contained(canonical, contents)
        if not contained:
            raise IdentityError("staged asset is not inside the exact staged app identity")
        relative = PurePosixPath(os.path.relpath(canonical, contents)).as_posix()
        matches = [
            entry
            for entry in staged_manifest.entries
            if entry.path == relative and entry.kind == "file"
        ]
        if len(matches) != 1 or (
            matches[0].sha256 != initial_sha
            or matches[0].stat != initial_stat
            or matches[0].extended_metadata_sha256 != initial_metadata
        ):
            raise IdentityError(
                "staged asset inode/bytes are not in the supplied candidate manifest"
            )
        _verify_source_manifest(staged_manifest)
        staged_binding = StagedAppBinding(
            app_identity_sha256=staged_app_identity.candidate_sha256,
            app_path=staged_canonical,
            manifest_tree_sha256=staged_manifest.tree_sha256,
            app_root_stat=staged_manifest.app_root_stat,
            root_stat=staged_manifest.root_stat,
            entry=matches[0],
        )

    native_eligible, reasons = _native_eligibility(container, video, audio)
    return AssetIdentity(
        schema=ASSET_IDENTITY_SCHEMA,
        file=asset_file,
        container=container,
        structural_detail=structural_detail,
        duration_seconds=duration,
        video=video,
        audio=audio,
        native_eligible=native_eligible,
        native_ineligibility_reasons=reasons,
        staged_app_path=staged_canonical,
        contained_in_staged_app=contained,
        staged_app_binding=staged_binding,
        probe=probe,
        probe_raw_json=probe.stdout_text,
    )


def _entry_from_open_file(
    fd: int,
    *,
    relative_path: str,
    requested_path: str,
) -> ManifestEntry:
    identity = _identity_from_open_fd(
        fd,
        requested_path=requested_path,
        canonical_path=requested_path,
        label=f"bundle entry {relative_path}",
    )
    return ManifestEntry(
        path=relative_path,
        kind="file",
        mode=stat.S_IMODE(identity.stat.mode),
        size_bytes=identity.stat.size_bytes,
        sha256=identity.sha256,
        symlink_target=None,
        stat=identity.stat,
        extended_metadata_sha256=identity.extended_metadata_sha256,
    )


def _scan_contents_directory(
    directory_fd: int,
    *,
    relative_directory: PurePosixPath,
    contents_path: str,
    output: list[ManifestEntry],
) -> None:
    directory_before = FileStatIdentity.from_stat(os.fstat(directory_fd))
    if not stat.S_ISDIR(directory_before.mode):
        raise IdentityError("bundle traversal encountered a non-directory")
    try:
        with os.scandir(directory_fd) as iterator:
            names = sorted(entry.name for entry in iterator)
    except OSError as error:
        raise IdentityError(f"could not enumerate bundle Contents: {error}") from error

    for name in names:
        if not isinstance(name, str) or not name or name in {".", ".."}:
            raise IdentityError("bundle contains an invalid entry name")
        try:
            name.encode("utf-8", errors="strict")
        except UnicodeEncodeError as error:
            raise IdentityError("bundle path is not valid UTF-8") from error
        relative = relative_directory / name
        relative_text = relative.as_posix()
        requested_path = os.path.join(contents_path, *relative.parts)
        try:
            before_os_stat = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
        except OSError as error:
            raise IdentityError(
                f"could not stat bundle entry {relative_text}: {error}"
            ) from error
        before = FileStatIdentity.from_stat(before_os_stat)
        kind_mode = before.mode

        if stat.S_ISLNK(kind_mode):
            link_fd = -1
            try:
                link_fd = os.open(
                    name,
                    os.O_RDONLY
                    | getattr(os, "O_CLOEXEC", 0)
                    | getattr(os, "O_SYMLINK", 0),
                    dir_fd=directory_fd,
                )
                target = os.readlink(name, dir_fd=directory_fd)
                after = FileStatIdentity.from_stat(
                    os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
                )
            except OSError as error:
                if link_fd >= 0:
                    os.close(link_fd)
                raise IdentityError(
                    f"could not read bundle symlink {relative_text}: {error}"
                ) from error
            try:
                opened = FileStatIdentity.from_stat(os.fstat(link_fd))
                _stat_is_stable(before, opened, label=f"bundle symlink {relative_text}")
                metadata = _extended_metadata_sha256(
                    link_fd, label=f"bundle symlink {relative_text}"
                )
            finally:
                os.close(link_fd)
            _stat_is_stable(before, after, label=f"bundle symlink {relative_text}")
            if not isinstance(target, str) or not target or "\x00" in target:
                raise IdentityError(f"bundle symlink {relative_text} has invalid target")
            try:
                target_bytes = target.encode("utf-8", errors="strict")
            except UnicodeEncodeError as error:
                raise IdentityError(
                    f"bundle symlink {relative_text} target is not UTF-8"
                ) from error
            if len(target_bytes) != before.size_bytes:
                raise IdentityError(
                    f"bundle symlink {relative_text} size changed while reading"
                )
            output.append(
                ManifestEntry(
                    path=relative_text,
                    kind="symlink",
                    mode=stat.S_IMODE(before.mode),
                    size_bytes=before.size_bytes,
                    sha256=hashlib.sha256(target_bytes).hexdigest(),
                    symlink_target=target,
                    stat=before,
                    extended_metadata_sha256=metadata,
                )
            )
            continue

        if stat.S_ISDIR(kind_mode):
            flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0)
            flags |= getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
            try:
                child_fd = os.open(name, flags, dir_fd=directory_fd)
            except OSError as error:
                raise IdentityError(
                    f"could not open bundle directory {relative_text}: {error}"
                ) from error
            try:
                opened = FileStatIdentity.from_stat(os.fstat(child_fd))
                _stat_is_stable(before, opened, label=f"bundle directory {relative_text}")
                metadata = _extended_metadata_sha256(
                    child_fd, label=f"bundle directory {relative_text}"
                )
                output.append(
                    ManifestEntry(
                        path=relative_text,
                        kind="directory",
                        mode=stat.S_IMODE(opened.mode),
                        size_bytes=opened.size_bytes,
                        sha256=None,
                        symlink_target=None,
                        stat=opened,
                        extended_metadata_sha256=metadata,
                    )
                )
                _scan_contents_directory(
                    child_fd,
                    relative_directory=relative,
                    contents_path=contents_path,
                    output=output,
                )
                closed = FileStatIdentity.from_stat(os.fstat(child_fd))
                _stat_is_stable(opened, closed, label=f"bundle directory {relative_text}")
            finally:
                os.close(child_fd)
            continue

        if stat.S_ISREG(kind_mode):
            fd = _open_regular_nofollow(
                name,
                label=f"bundle entry {relative_text}",
                dir_fd=directory_fd,
            )
            try:
                opened = FileStatIdentity.from_stat(os.fstat(fd))
                _stat_is_stable(before, opened, label=f"bundle entry {relative_text}")
                output.append(
                    _entry_from_open_file(
                        fd,
                        relative_path=relative_text,
                        requested_path=requested_path,
                    )
                )
            finally:
                os.close(fd)
            continue

        raise IdentityError(f"bundle entry {relative_text} has unsupported file type")

    directory_after = FileStatIdentity.from_stat(os.fstat(directory_fd))
    _stat_is_stable(
        directory_before,
        directory_after,
        label=f"bundle directory {relative_directory.as_posix() or 'Contents'}",
    )


def _normalize_symlink_target(
    link_path: PurePosixPath,
    target: str,
    *,
    contents_path: str,
) -> PurePosixPath:
    if os.path.isabs(target):
        raise IdentityError(f"bundle symlink {link_path} has an absolute target")
    normalized_parts = list(link_path.parent.parts)
    for part in PurePosixPath(target).parts:
        if part in {"", "."}:
            continue
        if part == "..":
            if not normalized_parts:
                raise IdentityError(f"bundle symlink {link_path} escapes Contents")
            normalized_parts.pop()
        else:
            normalized_parts.append(part)
    if not normalized_parts:
        raise IdentityError(f"bundle symlink {link_path} targets Contents itself")
    return PurePosixPath(*normalized_parts)


def _raw_symlink_target_components(
    link_path: PurePosixPath,
    target: str,
) -> list[str]:
    if os.path.isabs(target):
        raise IdentityError(f"bundle symlink {link_path} has an absolute target")
    return [*link_path.parent.parts, *PurePosixPath(target).parts]


def _validate_manifest_symlinks(entries: tuple[ManifestEntry, ...], contents_path: str) -> None:
    by_path = {PurePosixPath(entry.path): entry for entry in entries}
    for original, entry in by_path.items():
        if entry.kind != "symlink":
            continue
        assert entry.symlink_target is not None
        pending = _raw_symlink_target_components(original, entry.symlink_target)
        resolved_parts: list[str] = []
        visited: set[PurePosixPath] = {original}
        while pending:
            component = pending.pop(0)
            if component in {"", "."}:
                continue
            if component == "..":
                if not resolved_parts:
                    raise IdentityError(f"bundle symlink {original} escapes Contents")
                resolved_parts.pop()
                continue
            candidate = PurePosixPath(*resolved_parts, component)
            target = by_path.get(candidate)
            if target is None:
                raise IdentityError(f"bundle symlink {original} has a dangling target")
            if target.kind == "symlink":
                if candidate in visited:
                    raise IdentityError(f"bundle symlink cycle includes {original}")
                visited.add(candidate)
                assert target.symlink_target is not None
                pending = [
                    *_raw_symlink_target_components(
                        candidate, target.symlink_target
                    ),
                    *pending,
                ]
                resolved_parts = []
                continue
            resolved_parts.append(component)
            if pending and target.kind != "directory":
                raise IdentityError(
                    f"bundle symlink {original} traverses a non-directory component"
                )
        resolved = PurePosixPath(*resolved_parts)
        if target.kind == "directory" and (
            resolved == original.parent
            or resolved in original.parents
            or original == resolved
            or original.is_relative_to(resolved)
        ):
            raise IdentityError(
                f"bundle symlink {original} creates an ancestor directory cycle"
            )


def _canonical_tree_hash(
    entries: tuple[ManifestEntry, ...],
    app_root_stat: FileStatIdentity,
    app_root_metadata: str,
    root_stat: FileStatIdentity,
    root_metadata: str,
) -> str:
    digest = hashlib.sha256()
    digest.update((CONTENTS_MANIFEST_SCHEMA + "\n").encode("ascii"))
    records = [
        {
            "kind": "app_directory",
            "stat": app_root_stat.as_dict(),
            "path": "@app",
            "sha256": app_root_metadata,
            "symlink_target": None,
        },
        {
            "kind": "directory",
            "stat": root_stat.as_dict(),
            "path": "",
            "sha256": root_metadata,
            "symlink_target": None,
        },
        *(
            {**entry.canonical_record(), "stat": entry.stat.as_dict()}
            for entry in entries
        ),
    ]
    for record in records:
        encoded = json.dumps(
            record,
            ensure_ascii=False,
            allow_nan=False,
            sort_keys=True,
            separators=(",", ":"),
        ).encode("utf-8")
        digest.update(struct.pack(">Q", len(encoded)))
        digest.update(encoded)
    return digest.hexdigest()


def _capture_contents_manifest_once(
    app_path: os.PathLike[str] | str,
) -> ContentsManifest:
    requested = _require_absolute_path(app_path, "app path")
    canonical_app = requested
    if not canonical_app.endswith(".app"):
        raise IdentityError("app path must name a .app bundle")
    flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0)
    app_fd, app_chain = _open_absolute_nofollow(
        requested, label="app bundle", final_flags=flags
    )
    app_before = FileStatIdentity.from_stat(os.fstat(app_fd))
    app_metadata = _extended_metadata_sha256(app_fd, label="app bundle")
    try:
        with os.scandir(app_fd) as iterator:
            app_root_names_before = sorted(entry.name for entry in iterator)
    except OSError as error:
        os.close(app_fd)
        raise IdentityError(f"could not enumerate app bundle root: {error}") from error
    if app_root_names_before != ["Contents"]:
        os.close(app_fd)
        raise IdentityError("app bundle root must contain only exact Contents")
    contents_path = os.path.join(canonical_app, "Contents")
    try:
        contents_fd = os.open(
            "Contents",
            os.O_RDONLY
            | getattr(os, "O_CLOEXEC", 0)
            | getattr(os, "O_DIRECTORY", 0)
            | getattr(os, "O_NOFOLLOW", 0),
            dir_fd=app_fd,
        )
    except OSError as error:
        raise IdentityError(
            f"could not open app Contents without following links: {error}"
        ) from error
    try:
        root_before = FileStatIdentity.from_stat(os.fstat(contents_fd))
        root_metadata = _extended_metadata_sha256(contents_fd, label="app Contents")
        entries_list: list[ManifestEntry] = []
        _scan_contents_directory(
            contents_fd,
            relative_directory=PurePosixPath(),
            contents_path=contents_path,
            output=entries_list,
        )
        root_after = FileStatIdentity.from_stat(os.fstat(contents_fd))
        _stat_is_stable(root_before, root_after, label="app Contents")
        if _extended_metadata_sha256(contents_fd, label="app Contents after scan") != root_metadata:
            raise IdentityError("app Contents extended metadata changed")
    finally:
        os.close(contents_fd)
        _verify_absolute_binding(
            requested,
            app_fd,
            app_chain,
            label="app bundle after scan",
            final_flags=flags,
        )
        app_after = FileStatIdentity.from_stat(os.fstat(app_fd))
        _stat_is_stable(app_before, app_after, label="app bundle")
        try:
            with os.scandir(app_fd) as iterator:
                app_root_names_after = sorted(entry.name for entry in iterator)
        except OSError as error:
            raise IdentityError(
                f"could not re-enumerate app bundle root: {error}"
            ) from error
        if app_root_names_after != app_root_names_before:
            raise IdentityError("app bundle root entries changed while scanning")
        if _extended_metadata_sha256(app_fd, label="app bundle after scan") != app_metadata:
            raise IdentityError("app bundle extended metadata changed")
        os.close(app_fd)
    entries = tuple(sorted(entries_list, key=lambda entry: entry.path))
    if len({entry.path for entry in entries}) != len(entries):
        raise IdentityError("bundle manifest contains duplicate paths")
    _validate_manifest_symlinks(entries, contents_path)
    return ContentsManifest(
        schema=CONTENTS_MANIFEST_SCHEMA,
        app_path=canonical_app,
        contents_path=contents_path,
        app_root_stat=app_before,
        app_root_extended_metadata_sha256=app_metadata,
        root_stat=root_before,
        root_extended_metadata_sha256=root_metadata,
        entries=entries,
        tree_sha256=_canonical_tree_hash(
            entries, app_before, app_metadata, root_before, root_metadata
        ),
    )


def _manifest_file_identity(
    manifest: ContentsManifest,
    relative_path: str,
) -> FileIdentity:
    matches = [entry for entry in manifest.entries if entry.path == relative_path]
    if len(matches) != 1 or matches[0].kind != "file":
        raise IdentityError(f"bundle manifest lacks regular file {relative_path}")
    entry = matches[0]
    assert entry.sha256 is not None
    absolute = os.path.join(manifest.contents_path, *PurePosixPath(relative_path).parts)
    return FileIdentity(
        requested_path=absolute,
        canonical_path=absolute,
        sha256=entry.sha256,
        stat=entry.stat,
        extended_metadata_sha256=entry.extended_metadata_sha256,
    )


def _read_manifest_file_exact(
    manifest: ContentsManifest,
    relative_path: str,
) -> bytes:
    expected = _manifest_file_identity(manifest, relative_path)
    fd = _open_regular_nofollow(expected.canonical_path, label=relative_path)
    try:
        actual = _identity_from_open_fd(
            fd,
            requested_path=expected.requested_path,
            canonical_path=expected.canonical_path,
            label=relative_path,
        )
        if actual != expected:
            raise IdentityError(f"bundle file {relative_path} changed after manifest capture")
        os.lseek(fd, 0, os.SEEK_SET)
        data = bytearray()
        while len(data) < expected.stat.size_bytes:
            chunk = os.read(fd, min(65536, expected.stat.size_bytes - len(data)))
            if not chunk:
                break
            data.extend(chunk)
        if len(data) != expected.stat.size_bytes:
            raise IdentityError(f"bundle file {relative_path} was truncated")
        return bytes(data)
    finally:
        os.close(fd)


def _required_plist_string(plist: Mapping[str, Any], key: str) -> str:
    value = plist.get(key)
    if not isinstance(value, str) or not value or "\x00" in value:
        raise IdentityError(f"Info.plist {key} must be a non-empty string")
    return value


def verify_contents_manifest_unchanged(
    before: ContentsManifest,
    after: ContentsManifest,
) -> None:
    """Raise unless two captures describe the exact same Contents tree."""

    if not isinstance(before, ContentsManifest) or not isinstance(after, ContentsManifest):
        raise TypeError("before and after must be ContentsManifest instances")
    if before.app_path != after.app_path or before.contents_path != after.contents_path:
        raise IdentityError("app bundle path changed between manifest captures")
    if before.tree_sha256 != after.tree_sha256:
        raise IdentityError("app Contents tree identity changed")
    if (
        before.app_root_stat != after.app_root_stat
        or before.app_root_extended_metadata_sha256
        != after.app_root_extended_metadata_sha256
        or before.root_stat != after.root_stat
        or before.root_extended_metadata_sha256
        != after.root_extended_metadata_sha256
        or before.entries != after.entries
    ):
        raise IdentityError("app Contents stat identity changed")


def capture_contents_manifest(
    app_path: os.PathLike[str] | str,
) -> ContentsManifest:
    """Capture two identical passes over Contents or fail closed."""

    before = _capture_contents_manifest_once(app_path)
    after = _capture_contents_manifest_once(app_path)
    verify_contents_manifest_unchanged(before, after)
    return before


def _manifest_payload_sha256(manifest: ContentsManifest) -> str:
    value = {
        "app_mode": stat.S_IMODE(manifest.app_root_stat.mode),
        "app_flags": manifest.app_root_stat.flags,
        "app_xattrs": manifest.app_root_extended_metadata_sha256,
        "contents_mode": stat.S_IMODE(manifest.root_stat.mode),
        "contents_flags": manifest.root_stat.flags,
        "contents_xattrs": manifest.root_extended_metadata_sha256,
        "entries": [entry.canonical_record() for entry in manifest.entries],
    }
    return _canonical_sha256(value)


def _open_manifest_node(
    manifest: ContentsManifest,
    relative_path: str | None,
    *,
    kind: str,
) -> int:
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    app_fd, _ = _open_absolute_nofollow(
        manifest.app_path,
        label="manifest app root",
        final_flags=flags | getattr(os, "O_DIRECTORY", 0),
    )
    opened: list[int] = [app_fd]
    try:
        contents_fd = os.open(
            "Contents",
            flags | getattr(os, "O_DIRECTORY", 0),
            dir_fd=app_fd,
        )
        opened.append(contents_fd)
        if relative_path is None:
            result = os.dup(contents_fd)
        else:
            parts = PurePosixPath(relative_path).parts
            if not parts or any(part in {"", ".", ".."} for part in parts):
                raise IdentityError("manifest path is not a strict relative path")
            current = contents_fd
            for component in parts[:-1]:
                child = os.open(
                    component,
                    flags | getattr(os, "O_DIRECTORY", 0),
                    dir_fd=current,
                )
                opened.append(child)
                current = child
            final_flags = flags
            if kind == "directory":
                final_flags |= getattr(os, "O_DIRECTORY", 0)
            elif kind == "symlink":
                final_flags = (
                    os.O_RDONLY
                    | getattr(os, "O_CLOEXEC", 0)
                    | getattr(os, "O_SYMLINK", 0)
                )
            result = os.open(parts[-1], final_flags, dir_fd=current)
        return result
    except OSError as error:
        raise IdentityError(f"manifest node {relative_path or 'Contents'} changed: {error}") from error
    finally:
        for descriptor in reversed(opened):
            os.close(descriptor)


def _expected_manifest_entry(
    manifest: ContentsManifest, relative_path: str, kind: str
) -> ManifestEntry:
    matches = [entry for entry in manifest.entries if entry.path == relative_path]
    if len(matches) != 1 or matches[0].kind != kind:
        raise IdentityError(f"manifest lacks {kind} entry {relative_path}")
    return matches[0]


def _verify_open_manifest_node(
    fd: int,
    expected_stat: FileStatIdentity,
    expected_metadata: str,
    *,
    label: str,
) -> None:
    if FileStatIdentity.from_stat(os.fstat(fd)) != expected_stat:
        raise IdentityError(f"{label} generation changed after manifest capture")
    if _extended_metadata_sha256(fd, label=label) != expected_metadata:
        raise IdentityError(f"{label} metadata changed after manifest capture")


def _copy_fd_bytes(source_fd: int, destination_fd: int, size: int, *, label: str) -> None:
    os.lseek(source_fd, 0, os.SEEK_SET)
    remaining = size
    while remaining:
        chunk = os.read(source_fd, min(HASH_CHUNK_BYTES, remaining))
        if not chunk:
            raise IdentityError(f"{label} was truncated during snapshot copy")
        view = memoryview(chunk)
        while view:
            written = os.write(destination_fd, view)
            if written <= 0:
                raise IdentityError(f"{label} snapshot write failed")
            view = view[written:]
        remaining -= len(chunk)


@dataclasses.dataclass(frozen=True)
class _PrivateAppSnapshot:
    directory: str
    root_fd: int
    root_stat: FileStatIdentity
    root_metadata: str
    app_path: str
    manifest: ContentsManifest
    payload_sha256: str


def _apply_flags(path: str, flags: int, *, follow_symlinks: bool = True) -> None:
    if flags:
        try:
            os.chflags(path, flags, follow_symlinks=follow_symlinks)
        except (AttributeError, NotImplementedError, OSError) as error:
            raise IdentityError(f"could not reproduce flags in private app snapshot: {error}") from error


@contextlib.contextmanager
def _private_app_snapshot(source: ContentsManifest) -> Iterator[_PrivateAppSnapshot]:
    if (
        source.app_root_stat.flags
        or source.root_stat.flags
        or any(entry.stat.flags for entry in source.entries)
    ):
        raise IdentityError(
            "app filesystem flags cannot be safely reproduced in a private snapshot"
        )
    directory = os.path.realpath(tempfile.mkdtemp(prefix="wam-shipper-app-"))
    root_fd = -1
    try:
        os.chmod(directory, 0o700)
        root_fd = os.open(
            directory,
            os.O_RDONLY
            | getattr(os, "O_CLOEXEC", 0)
            | getattr(os, "O_DIRECTORY", 0)
            | getattr(os, "O_NOFOLLOW", 0),
        )
        app_path = os.path.join(directory, "candidate.app")
        os.mkdir(app_path, 0o700)
        contents_path = os.path.join(app_path, "Contents")
        os.mkdir(contents_path, 0o700)

        source_app_fd, _ = _open_absolute_nofollow(
            source.app_path,
            label="source app root for snapshot",
            final_flags=os.O_RDONLY | getattr(os, "O_DIRECTORY", 0),
        )
        destination_app_fd = os.open(
            app_path,
            os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0),
        )
        source_contents_fd = _open_manifest_node(source, None, kind="directory")
        destination_contents_fd = os.open(
            contents_path,
            os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0),
        )
        try:
            _verify_open_manifest_node(
                source_app_fd,
                source.app_root_stat,
                source.app_root_extended_metadata_sha256,
                label="source app root",
            )
            _verify_open_manifest_node(
                source_contents_fd,
                source.root_stat,
                source.root_extended_metadata_sha256,
                label="source app Contents",
            )
            _copy_extended_metadata(source_app_fd, destination_app_fd, label="app root")
            _copy_extended_metadata(
                source_contents_fd, destination_contents_fd, label="app Contents"
            )
        finally:
            os.close(source_app_fd)
            os.close(destination_app_fd)
            os.close(source_contents_fd)
            os.close(destination_contents_fd)

        directories = sorted(
            (entry for entry in source.entries if entry.kind == "directory"),
            key=lambda entry: (len(PurePosixPath(entry.path).parts), entry.path),
        )
        for entry in directories:
            destination = os.path.join(contents_path, *PurePosixPath(entry.path).parts)
            os.mkdir(destination, 0o700)
            source_fd = _open_manifest_node(source, entry.path, kind="directory")
            destination_fd = os.open(
                destination,
                os.O_RDONLY
                | getattr(os, "O_DIRECTORY", 0)
                | getattr(os, "O_NOFOLLOW", 0),
            )
            try:
                _verify_open_manifest_node(
                    source_fd,
                    entry.stat,
                    entry.extended_metadata_sha256,
                    label=f"source directory {entry.path}",
                )
                _copy_extended_metadata(
                    source_fd, destination_fd, label=f"directory {entry.path}"
                )
            finally:
                os.close(source_fd)
                os.close(destination_fd)

        for entry in (item for item in source.entries if item.kind == "file"):
            destination = os.path.join(contents_path, *PurePosixPath(entry.path).parts)
            source_fd = _open_manifest_node(source, entry.path, kind="file")
            destination_fd = -1
            try:
                _verify_open_manifest_node(
                    source_fd,
                    entry.stat,
                    entry.extended_metadata_sha256,
                    label=f"source file {entry.path}",
                )
                destination_fd = os.open(
                    destination,
                    os.O_WRONLY
                    | os.O_CREAT
                    | os.O_EXCL
                    | getattr(os, "O_CLOEXEC", 0)
                    | getattr(os, "O_NOFOLLOW", 0),
                    0o600,
                )
                _copy_fd_bytes(
                    source_fd,
                    destination_fd,
                    entry.size_bytes,
                    label=f"bundle file {entry.path}",
                )
                _copy_extended_metadata(
                    source_fd, destination_fd, label=f"file {entry.path}"
                )
                os.fchmod(destination_fd, stat.S_IMODE(entry.stat.mode))
                os.fsync(destination_fd)
            finally:
                os.close(source_fd)
                if destination_fd >= 0:
                    os.close(destination_fd)
            _apply_flags(destination, entry.stat.flags)

        for entry in (item for item in source.entries if item.kind == "symlink"):
            assert entry.symlink_target is not None
            destination = os.path.join(contents_path, *PurePosixPath(entry.path).parts)
            os.symlink(entry.symlink_target, destination)
            source_fd = _open_manifest_node(source, entry.path, kind="symlink")
            destination_fd = os.open(
                destination,
                os.O_RDONLY
                | getattr(os, "O_CLOEXEC", 0)
                | getattr(os, "O_SYMLINK", 0),
            )
            try:
                _verify_open_manifest_node(
                    source_fd,
                    entry.stat,
                    entry.extended_metadata_sha256,
                    label=f"source symlink {entry.path}",
                )
                _copy_extended_metadata(
                    source_fd, destination_fd, label=f"symlink {entry.path}"
                )
            finally:
                os.close(source_fd)
                os.close(destination_fd)
            _apply_flags(destination, entry.stat.flags, follow_symlinks=False)

        for entry in sorted(
            directories,
            key=lambda item: (-len(PurePosixPath(item.path).parts), item.path),
        ):
            destination = os.path.join(contents_path, *PurePosixPath(entry.path).parts)
            os.chmod(destination, stat.S_IMODE(entry.stat.mode), follow_symlinks=False)
            _apply_flags(destination, entry.stat.flags)
        os.chmod(contents_path, stat.S_IMODE(source.root_stat.mode), follow_symlinks=False)
        _apply_flags(contents_path, source.root_stat.flags)
        os.chmod(app_path, stat.S_IMODE(source.app_root_stat.mode), follow_symlinks=False)
        _apply_flags(app_path, source.app_root_stat.flags)
        os.fsync(root_fd)

        snapshot_manifest = capture_contents_manifest(app_path)
        if _manifest_payload_sha256(snapshot_manifest) != _manifest_payload_sha256(source):
            raise IdentityError("private app snapshot does not match source payload")
        root_stat = FileStatIdentity.from_stat(os.fstat(root_fd))
        root_metadata = _extended_metadata_sha256(root_fd, label="private app snapshot root")
        yield _PrivateAppSnapshot(
            directory=directory,
            root_fd=root_fd,
            root_stat=root_stat,
            root_metadata=root_metadata,
            app_path=app_path,
            manifest=snapshot_manifest,
            payload_sha256=_manifest_payload_sha256(source),
        )
    finally:
        if root_fd >= 0:
            os.close(root_fd)
        shutil.rmtree(directory)


def _verify_private_app_snapshot(
    snapshot: _PrivateAppSnapshot,
    source: ContentsManifest,
) -> ContentsManifest:
    if FileStatIdentity.from_stat(os.fstat(snapshot.root_fd)) != snapshot.root_stat:
        raise IdentityError("private app snapshot root generation changed")
    if _extended_metadata_sha256(
        snapshot.root_fd, label="private app snapshot root verification"
    ) != snapshot.root_metadata:
        raise IdentityError("private app snapshot root metadata changed")
    observed = capture_contents_manifest(snapshot.app_path)
    verify_contents_manifest_unchanged(snapshot.manifest, observed)
    if _manifest_payload_sha256(observed) != _manifest_payload_sha256(source):
        raise IdentityError("private app snapshot diverged from source app")
    return observed


def _verify_source_manifest(source: ContentsManifest) -> ContentsManifest:
    observed = capture_contents_manifest(source.app_path)
    verify_contents_manifest_unchanged(source, observed)
    return observed


def _is_macho_file(manifest: ContentsManifest, entry: ManifestEntry) -> bool:
    if entry.kind != "file" or entry.size_bytes < 4:
        return False
    fd = _open_manifest_node(manifest, entry.path, kind="file")
    try:
        _verify_open_manifest_node(
            fd,
            entry.stat,
            entry.extended_metadata_sha256,
            label=f"Mach-O candidate {entry.path}",
        )
        return _macho_structure_is_valid(fd, entry.size_bytes)
    finally:
        os.close(fd)


def capture_app_identity(
    app_path: os.PathLike[str] | str,
    *,
    codesign_path: os.PathLike[str] | str = "/usr/bin/codesign",
    codesign_runner: CommandRunner | None = None,
    timeout_s: float = DEFAULT_TOOL_TIMEOUT_S,
    max_codesign_output_bytes: int = DEFAULT_MAX_TOOL_OUTPUT_BYTES,
) -> AppIdentity:
    """Capture a stable app and verify a private exact snapshot with codesign."""

    before = capture_contents_manifest(app_path)
    info_bytes = _read_manifest_file_exact(before, "Info.plist")
    try:
        plist = plistlib.loads(info_bytes)
    except (plistlib.InvalidFileException, ValueError, TypeError) as error:
        raise IdentityError(f"Info.plist is malformed: {error}") from error
    if not isinstance(plist, dict):
        raise IdentityError("Info.plist root must be a dictionary")
    bundle_identifier = _required_plist_string(plist, "CFBundleIdentifier")
    short_version = _required_plist_string(plist, "CFBundleShortVersionString")
    bundle_version = _required_plist_string(plist, "CFBundleVersion")
    executable_name = _required_plist_string(plist, "CFBundleExecutable")
    if executable_name in {".", ".."} or "/" in executable_name or "\\" in executable_name:
        raise IdentityError("Info.plist CFBundleExecutable must be a plain filename")
    executable_relative = f"MacOS/{executable_name}"
    executable = _manifest_file_identity(before, executable_relative)
    if executable.stat.mode & 0o111 == 0:
        raise IdentityError("bundle executable has no execute permission bits")
    info_identity = _manifest_file_identity(before, "Info.plist")

    codesign_tool = capture_tool_identity(codesign_path, label="codesign")
    macho_entries = tuple(entry for entry in before.entries if _is_macho_file(before, entry))
    if not any(entry.path == executable_relative for entry in macho_entries):
        raise IdentityError("bundle executable is not a Mach-O code leaf")

    leaf_evidence: list[CodeLeafEvidence] = []
    with _private_app_snapshot(before) as snapshot:
        def run_verified(
            source_arguments: tuple[str, ...],
            executed_arguments: tuple[str, ...],
            target: CommandTargetIdentity,
        ) -> CommandEvidence:
            _verify_source_manifest(before)
            _verify_private_app_snapshot(snapshot, before)
            evidence = _run_identified_command(
                codesign_tool,
                source_arguments,
                executed_arguments=executed_arguments,
                runner=codesign_runner,
                targets=(target,),
                timeout_s=timeout_s,
                max_output_bytes=max_codesign_output_bytes,
            )
            if evidence.returncode != 0:
                raise IdentityError(
                    f"codesign verification failed with exit status "
                    f"{evidence.returncode}: {evidence.stderr_text.strip()}"
                )
            _verify_source_manifest(before)
            _verify_private_app_snapshot(snapshot, before)
            return evidence

        for entry in macho_entries:
            source_file = _manifest_file_identity(before, entry.path)
            snapshot_file = _manifest_file_identity(snapshot.manifest, entry.path)
            source_target = source_file.canonical_path
            executed_target = snapshot_file.canonical_path
            arguments = (
                "--verify",
                "--strict=all",
                "--all-architectures",
                "--verbose=4",
                source_target,
            )
            executed_arguments = (*arguments[:-1], executed_target)
            command = run_verified(
                arguments,
                executed_arguments,
                CommandTargetIdentity(
                    role="mach_o_code_leaf",
                    source_argument=source_target,
                    executed_argument=executed_target,
                    descriptor=None,
                    file=source_file,
                    executed_file=snapshot_file,
                    contents_tree_sha256=before.tree_sha256,
                    executed_contents_tree_sha256=snapshot.manifest.tree_sha256,
                    executed_root_stat=snapshot.root_stat,
                    executed_root_extended_metadata_sha256=snapshot.root_metadata,
                ),
            )
            leaf_evidence.append(
                CodeLeafEvidence(
                    relative_path=entry.path,
                    sha256=entry.sha256 or "",
                    codesign=command,
                )
            )

        bundle_arguments = (
            "--verify",
            "--deep",
            "--strict=all",
            "--all-architectures",
            "--verbose=4",
            before.app_path,
        )
        executed_bundle_arguments = (*bundle_arguments[:-1], snapshot.app_path)
        codesign = run_verified(
            bundle_arguments,
            executed_bundle_arguments,
            CommandTargetIdentity(
                role="app_bundle",
                source_argument=before.app_path,
                executed_argument=snapshot.app_path,
                descriptor=None,
                file=None,
                executed_file=None,
                contents_tree_sha256=before.tree_sha256,
                executed_contents_tree_sha256=snapshot.manifest.tree_sha256,
                executed_root_stat=snapshot.root_stat,
                executed_root_extended_metadata_sha256=snapshot.root_metadata,
            ),
        )

    codesign_tool_after = capture_tool_identity(codesign_path, label="codesign")
    if not _same_file_identity(codesign_tool_after, codesign_tool):
        raise IdentityError("codesign changed while it was running")
    _verify_source_manifest(before)
    return AppIdentity(
        schema=APP_IDENTITY_SCHEMA,
        app_path=before.app_path,
        manifest=before,
        bundle_identifier=bundle_identifier,
        bundle_short_version=short_version,
        bundle_version=bundle_version,
        executable_relative_path=executable_relative,
        executable=executable,
        info_plist=info_identity,
        codesign=codesign,
        code_leaves=tuple(leaf_evidence),
    )


def _file_candidate_record(identity: FileIdentity) -> dict[str, Any]:
    return identity.as_dict()


def _command_candidate_record(evidence: CommandEvidence) -> dict[str, Any]:
    return {
        "schema": evidence.schema,
        "argv": list(evidence.argv),
        "returncode": evidence.returncode,
        "tool": _file_candidate_record(evidence.tool),
        "sanitized_environment": [list(item) for item in evidence.sanitized_environment],
        "trusted_execution": evidence.trusted_execution,
        "targets": [
            {
                "role": target.role,
                "source_argument": target.source_argument,
                "file": (
                    _file_candidate_record(target.file)
                    if target.file is not None
                    else None
                ),
                "contents_tree_sha256": target.contents_tree_sha256,
            }
            for target in evidence.targets
        ],
    }


def command_evidence_sha256(evidence: CommandEvidence) -> str:
    if not isinstance(evidence, CommandEvidence):
        raise TypeError("evidence must be CommandEvidence")
    return _canonical_sha256(evidence.as_dict())


def _external_receipt_capability_runtime():
    seal = object()

    @dataclasses.dataclass(frozen=True, slots=True)
    class TrustedCommandReceiptCapability:
        """Opaque result of matching a retained index to an external anchor."""

        validator_identity: str
        trust_index_sha256: str
        receipts: tuple[tuple[str, str, Mapping[str, Any]], ...]
        _seal: object = dataclasses.field(repr=False, compare=False)

        def __post_init__(self) -> None:
            if self._seal is not seal:
                raise IdentityError(
                    "command receipt capabilities require an external trust anchor"
                )

        def resolve(
            self, receipt_id: str, evidence_sha256: str
        ) -> Mapping[str, Any] | None:
            for candidate_id, candidate_digest, receipt in self.receipts:
                if candidate_id == receipt_id and candidate_digest == evidence_sha256:
                    return receipt
            return None

    def validate(
        index_bytes: bytes,
        *,
        expected_index_sha256_from_trust_root: str,
        expected_validator_identity_from_trust_root: str,
    ) -> TrustedCommandReceiptCapability:
        if not isinstance(index_bytes, bytes) or not index_bytes:
            raise IdentityError("external command trust index must be retained bytes")
        expected_digest = expected_index_sha256_from_trust_root
        if (
            not isinstance(expected_digest, str)
            or len(expected_digest) != 64
            or any(character not in "0123456789abcdef" for character in expected_digest)
        ):
            raise IdentityError("external command trust anchor digest is invalid")
        observed_digest = hashlib.sha256(index_bytes).hexdigest()
        if observed_digest != expected_digest:
            raise IdentityError("external command trust index misses its trust anchor")
        try:
            value = json.loads(
                index_bytes.decode("utf-8", errors="strict"),
                object_pairs_hook=_reject_duplicate_pairs,
            )
        except (UnicodeDecodeError, json.JSONDecodeError, IdentityError) as error:
            raise IdentityError(f"external command trust index is malformed: {error}") from error
        if not isinstance(value, dict) or set(value) != {
            "schema",
            "validator_identity",
            "receipts",
        }:
            raise IdentityError("external command trust index fields are not exact")
        canonical = json.dumps(
            value,
            ensure_ascii=False,
            allow_nan=False,
            sort_keys=True,
            separators=(",", ":"),
        ).encode("utf-8")
        if canonical != index_bytes:
            raise IdentityError("external command trust index is not canonical JSON")
        expected_validator = expected_validator_identity_from_trust_root
        if (
            not isinstance(expected_validator, str)
            or not expected_validator
            or len(expected_validator) > 256
            or "\x00" in expected_validator
            or value["validator_identity"] != expected_validator
        ):
            raise IdentityError("external command validator misses its trust anchor")
        if value["schema"] != TRUSTED_COMMAND_INDEX_SCHEMA:
            raise IdentityError("external command trust index schema is unsupported")
        raw_receipts = value["receipts"]
        if not isinstance(raw_receipts, list) or not raw_receipts:
            raise IdentityError("external command trust index has no receipts")
        parsed: list[tuple[str, str, Mapping[str, Any]]] = []
        expected_fields = {
            "schema",
            "receipt_id",
            "command_evidence_sha256",
            "validated_by",
            "authentication_validated",
            "producer_identity",
            "execution_kind",
        }
        for receipt in raw_receipts:
            if not isinstance(receipt, dict) or set(receipt) != expected_fields:
                raise IdentityError("external command receipt fields are not exact")
            receipt_id = receipt["receipt_id"]
            try:
                parsed_id = uuid.UUID(receipt_id)
            except (ValueError, AttributeError) as error:
                raise IdentityError("external command receipt ID is invalid") from error
            digest = receipt["command_evidence_sha256"]
            if (
                str(parsed_id) != receipt_id
                or not isinstance(digest, str)
                or len(digest) != 64
                or any(character not in "0123456789abcdef" for character in digest)
                or receipt["schema"] != TRUSTED_COMMAND_RECEIPT_SCHEMA
                or receipt["validated_by"] != expected_validator
                or receipt["authentication_validated"] is not True
                or receipt["execution_kind"] != "fd_copied_private_snapshot_v1"
                or not isinstance(receipt["producer_identity"], str)
                or not receipt["producer_identity"]
                or len(receipt["producer_identity"]) > 256
                or "\x00" in receipt["producer_identity"]
            ):
                raise IdentityError("external command receipt is invalid")
            parsed.append((receipt_id, digest, receipt))
        keys = [(receipt_id, digest) for receipt_id, digest, _ in parsed]
        receipt_ids = [receipt_id for receipt_id, _, _ in parsed]
        if (
            keys != sorted(keys)
            or len(set(keys)) != len(keys)
            or len(set(receipt_ids)) != len(receipt_ids)
        ):
            raise IdentityError("external command receipts are not unique/canonical")
        return TrustedCommandReceiptCapability(
            validator_identity=expected_validator,
            trust_index_sha256=observed_digest,
            receipts=tuple(parsed),
            _seal=seal,
        )

    def require(value: Any) -> TrustedCommandReceiptCapability:
        if type(value) is not TrustedCommandReceiptCapability or value._seal is not seal:
            raise IdentityError(
                "an externally anchored TrustedCommandReceiptCapability is required"
            )
        return value

    return TrustedCommandReceiptCapability, validate, require


(
    TrustedCommandReceiptCapability,
    validate_external_command_receipt_index,
    _require_command_receipt_capability,
) = _external_receipt_capability_runtime()


def _trusted_command_receipt(
    evidence: CommandEvidence,
    trusted_receipt_index: TrustedCommandReceiptCapability,
) -> Mapping[str, Any]:
    capability = _require_command_receipt_capability(trusted_receipt_index)
    validator_identity = capability.validator_identity
    if (
        not isinstance(validator_identity, str)
        or not validator_identity
        or len(validator_identity) > 256
        or "\x00" in validator_identity
    ):
        raise IdentityError("trusted command validator identity is invalid")
    if evidence.execution_receipt_id is None:
        raise IdentityError("injected command execution has no external receipt")
    try:
        parsed_id = uuid.UUID(evidence.execution_receipt_id)
    except (ValueError, AttributeError) as error:
        raise IdentityError("command execution receipt ID is not a canonical UUID") from error
    if str(parsed_id) != evidence.execution_receipt_id:
        raise IdentityError("command execution receipt ID is not canonical")
    digest = command_evidence_sha256(evidence)
    receipt = capability.resolve(
        evidence.execution_receipt_id, digest
    )
    if not isinstance(receipt, Mapping):
        raise IdentityError("authenticated command execution receipt is absent")
    if (
        receipt.get("schema") != TRUSTED_COMMAND_RECEIPT_SCHEMA
        or receipt.get("receipt_id") != evidence.execution_receipt_id
        or receipt.get("command_evidence_sha256") != digest
        or receipt.get("validated_by") != validator_identity
        or receipt.get("authentication_validated") is not True
        or receipt.get("execution_kind") != "fd_copied_private_snapshot_v1"
    ):
        raise IdentityError("authenticated command receipt binds different evidence")
    producer = receipt.get("producer_identity")
    if not isinstance(producer, str) or not producer or len(producer) > 256 or "\x00" in producer:
        raise IdentityError("authenticated command producer identity is invalid")
    return receipt


def _app_candidate_record(identity: AppIdentity) -> dict[str, Any]:
    return {
        "schema": identity.schema,
        "app_path": identity.app_path,
        "manifest": identity.manifest.as_dict(),
        "bundle_identifier": identity.bundle_identifier,
        "bundle_short_version": identity.bundle_short_version,
        "bundle_version": identity.bundle_version,
        "executable_relative_path": identity.executable_relative_path,
        "executable": identity.executable.as_dict(),
        "info_plist": identity.info_plist.as_dict(),
        "codesign": _command_candidate_record(identity.codesign),
        "code_leaves": [
            {
                "relative_path": leaf.relative_path,
                "sha256": leaf.sha256,
                "codesign": _command_candidate_record(leaf.codesign),
            }
            for leaf in identity.code_leaves
        ],
    }


def _app_source_record(identity: AppIdentity) -> dict[str, Any]:
    return _app_candidate_record(identity)


def validate_command_evidence_for_shipping(
    evidence: CommandEvidence,
    *,
    trusted_receipt_index: TrustedCommandReceiptCapability,
    expected_tool: FileIdentity | None = None,
) -> None:
    """Reject any command evidence not produced by the sealed runner path."""

    if not isinstance(evidence, CommandEvidence):
        raise TypeError("evidence must be CommandEvidence")
    if evidence.schema != COMMAND_EVIDENCE_SCHEMA:
        raise IdentityError("command evidence schema is not current")
    if not evidence.trusted_execution:
        raise IdentityError("injected command execution is not shipping evidence")
    if not _file_is_macho(evidence.tool):
        raise IdentityError("shipping command source tool is not a Mach-O executable")
    _trusted_command_receipt(evidence, trusted_receipt_index)
    if expected_tool is not None and not _same_file_identity(
        evidence.tool, expected_tool
    ):
        raise IdentityError("command source tool is not the trusted expected tool")
    if evidence.sanitized_environment != SANITIZED_COMMAND_ENVIRONMENT:
        raise IdentityError("command environment was not the exact sanitized environment")
    if evidence.returncode != 0:
        raise IdentityError("shipping command evidence has a nonzero exit status")
    if not evidence.argv or evidence.argv[0] != evidence.tool.canonical_path:
        raise IdentityError("source argv is not bound to the source tool")
    stdout = evidence.stdout_text.encode("utf-8")
    stderr = evidence.stderr_text.encode("utf-8")
    if (
        evidence.stdout_bytes != len(stdout)
        or evidence.stderr_bytes != len(stderr)
        or evidence.stdout_sha256 != hashlib.sha256(stdout).hexdigest()
        or evidence.stderr_sha256 != hashlib.sha256(stderr).hexdigest()
    ):
        raise IdentityError("command output transcript identity is inconsistent")
    if not evidence.executed_argv or evidence.executed_argv[0] != evidence.executed_tool.canonical_path:
        raise IdentityError("executed argv is not bound to the executed tool snapshot")
    if evidence.tool.sha256 != evidence.executed_tool.sha256:
        raise IdentityError("source and executed tool bytes differ")
    if stat.S_IMODE(evidence.executed_tool.stat.mode) != 0o500:
        raise IdentityError("executed tool snapshot is not immutable mode 0500")
    if (
        evidence.private_snapshot_root_stat is None
        or stat.S_IMODE(evidence.private_snapshot_root_stat.mode) != 0o700
        or evidence.private_snapshot_root_extended_metadata_sha256 is None
    ):
        raise IdentityError("private tool snapshot root identity is incomplete")
    for target in evidence.targets:
        if target.source_argument not in evidence.argv:
            raise IdentityError("source command target is absent from source argv")
        if target.executed_argument not in evidence.executed_argv:
            raise IdentityError("executed command target is absent from executed argv")
        if target.file is not None and target.executed_file is not None:
            if target.file.sha256 != target.executed_file.sha256:
                raise IdentityError("source and executed command targets differ")
        if target.contents_tree_sha256 is not None and (
            len(target.contents_tree_sha256) != 64
            or any(character not in "0123456789abcdef" for character in target.contents_tree_sha256)
        ):
            raise IdentityError("source target manifest digest is malformed")
        if target.executed_contents_tree_sha256 is not None and (
            len(target.executed_contents_tree_sha256) != 64
            or any(
                character not in "0123456789abcdef"
                for character in target.executed_contents_tree_sha256
            )
        ):
            raise IdentityError("executed target manifest digest is malformed")
        if target.role in {"mach_o_code_leaf", "app_bundle"} and (
            target.executed_root_stat is None
            or stat.S_IMODE(target.executed_root_stat.mode) != 0o700
            or target.executed_root_extended_metadata_sha256 is None
            or target.executed_contents_tree_sha256 is None
        ):
            raise IdentityError("private app snapshot root identity is incomplete")
        if target.descriptor is not None:
            if target.descriptor not in evidence.pass_fds:
                raise IdentityError("command target descriptor is absent from pass_fds")
            if target.executed_argument != f"/dev/fd/{target.descriptor}":
                raise IdentityError("command target descriptor argument is ambiguous")


def _file_is_macho(identity: FileIdentity) -> bool:
    fd, chain = _open_absolute_nofollow(
        identity.canonical_path,
        label="command source Mach-O",
        final_flags=os.O_RDONLY,
    )
    try:
        observed = _identity_from_open_fd(
            fd,
            requested_path=identity.requested_path,
            canonical_path=identity.canonical_path,
            label="command source Mach-O",
        )
        observed = dataclasses.replace(observed, path_ancestry=chain)
        if not _same_file_identity(observed, identity):
            raise IdentityError("command source tool identity is stale")
        return _macho_structure_is_valid(fd, identity.stat.size_bytes)
    finally:
        os.close(fd)


def validate_app_identity_for_shipping(
    identity: AppIdentity,
    *,
    trusted_receipt_index: TrustedCommandReceiptCapability,
) -> None:
    if not isinstance(identity, AppIdentity):
        raise TypeError("identity must be AppIdentity")
    if identity.schema != APP_IDENTITY_SCHEMA:
        raise IdentityError("app identity schema is not current")
    if len(identity.candidate_sha256) != 64 or any(
        character not in "0123456789abcdef" for character in identity.candidate_sha256
    ):
        raise IdentityError("candidate identity is not canonical lowerhex SHA-256")
    _verify_source_manifest(identity.manifest)
    info_bytes = _read_manifest_file_exact(identity.manifest, "Info.plist")
    try:
        plist = plistlib.loads(info_bytes)
    except (plistlib.InvalidFileException, ValueError, TypeError) as error:
        raise IdentityError(f"Info.plist is malformed: {error}") from error
    if not isinstance(plist, dict):
        raise IdentityError("Info.plist root must be a dictionary")
    executable_name = _required_plist_string(plist, "CFBundleExecutable")
    if executable_name in {".", ".."} or "/" in executable_name or "\\" in executable_name:
        raise IdentityError("Info.plist CFBundleExecutable must be a plain filename")
    expected_executable_relative = f"MacOS/{executable_name}"
    expected_executable = _manifest_file_identity(
        identity.manifest, expected_executable_relative
    )
    expected_info = _manifest_file_identity(identity.manifest, "Info.plist")
    if (
        identity.bundle_identifier
        != _required_plist_string(plist, "CFBundleIdentifier")
        or identity.bundle_short_version
        != _required_plist_string(plist, "CFBundleShortVersionString")
        or identity.bundle_version
        != _required_plist_string(plist, "CFBundleVersion")
        or identity.executable_relative_path != expected_executable_relative
        or identity.executable != expected_executable
        or identity.info_plist != expected_info
        or identity.app_path != identity.manifest.app_path
    ):
        raise IdentityError("outer app identity is not the exact manifest/plist derivation")
    if identity.executable.stat.mode & 0o111 == 0:
        raise IdentityError("bundle executable has no execute permission bits")
    expected_codesign = capture_tool_identity("/usr/bin/codesign", label="system codesign")
    validate_command_evidence_for_shipping(
        identity.codesign,
        trusted_receipt_index=trusted_receipt_index,
        expected_tool=expected_codesign,
    )
    expected = {
        entry.path: entry
        for entry in identity.manifest.entries
        if _is_macho_file(identity.manifest, entry)
    }
    observed = {leaf.relative_path: leaf.sha256 for leaf in identity.code_leaves}
    if observed != {
        path: entry.sha256 for path, entry in expected.items()
    } or len(observed) != len(identity.code_leaves):
        raise IdentityError("per-leaf codesign evidence does not cover every Mach-O leaf")
    bundle_targets = identity.codesign.targets
    expected_bundle_argv = (
        identity.codesign.tool.canonical_path,
        "--verify",
        "--deep",
        "--strict=all",
        "--all-architectures",
        "--verbose=4",
        identity.app_path,
    )
    if identity.codesign.argv != expected_bundle_argv or len(bundle_targets) != 1:
        raise IdentityError("bundle codesign command is not exact")
    bundle_target = bundle_targets[0]
    expected_executed_bundle_argv = (
        identity.codesign.executed_tool.canonical_path,
        "--verify",
        "--deep",
        "--strict=all",
        "--all-architectures",
        "--verbose=4",
        bundle_target.executed_argument,
    )
    if (
        bundle_target.role != "app_bundle"
        or bundle_target.source_argument != identity.app_path
        or bundle_target.file is not None
        or bundle_target.executed_file is not None
        or bundle_target.descriptor is not None
        or identity.codesign.pass_fds
        or bundle_target.contents_tree_sha256 != identity.manifest.tree_sha256
        or bundle_target.executed_contents_tree_sha256 is None
        or bundle_target.executed_argument
        != identity.codesign.executed_argv[-1]
        or identity.codesign.executed_argv != expected_executed_bundle_argv
    ):
        raise IdentityError("bundle codesign target is not bound to this app")
    executed_tree = bundle_target.executed_contents_tree_sha256
    executed_root_stat = bundle_target.executed_root_stat
    executed_root_metadata = bundle_target.executed_root_extended_metadata_sha256
    for leaf in identity.code_leaves:
        validate_command_evidence_for_shipping(
            leaf.codesign,
            trusted_receipt_index=trusted_receipt_index,
            expected_tool=expected_codesign,
        )
        targets = leaf.codesign.targets
        entry = expected[leaf.relative_path]
        expected_file = _manifest_file_identity(identity.manifest, leaf.relative_path)
        expected_argv = (
            leaf.codesign.tool.canonical_path,
            "--verify",
            "--strict=all",
            "--all-architectures",
            "--verbose=4",
            expected_file.canonical_path,
        )
        if leaf.codesign.argv != expected_argv or len(targets) != 1:
            raise IdentityError("Mach-O leaf codesign command is not exact")
        target = targets[0]
        relative_parts = PurePosixPath(leaf.relative_path).parts
        if (
            not relative_parts
            or any(part in {"", ".", ".."} for part in relative_parts)
            or PurePosixPath(*relative_parts).as_posix() != leaf.relative_path
        ):
            raise IdentityError("Mach-O leaf path is not a canonical bundle path")
        expected_executed_leaf_path = os.path.join(
            bundle_target.executed_argument,
            "Contents",
            *relative_parts,
        )
        expected_executed_leaf_argv = (
            leaf.codesign.executed_tool.canonical_path,
            "--verify",
            "--strict=all",
            "--all-architectures",
            "--verbose=4",
            target.executed_argument,
        )
        if (
            target.role != "mach_o_code_leaf"
            or target.descriptor is not None
            or leaf.codesign.pass_fds
            or target.source_argument != expected_file.canonical_path
            or target.executed_argument != leaf.codesign.executed_argv[-1]
            or target.executed_argument != expected_executed_leaf_path
            or target.file != expected_file
            or target.executed_file is None
            or target.executed_file.requested_path != expected_executed_leaf_path
            or target.executed_file.canonical_path != expected_executed_leaf_path
            or target.executed_file.sha256 != entry.sha256
            or leaf.sha256 != entry.sha256
            or target.contents_tree_sha256 != identity.manifest.tree_sha256
            or target.executed_contents_tree_sha256 != executed_tree
            or target.executed_root_stat != executed_root_stat
            or target.executed_root_extended_metadata_sha256
            != executed_root_metadata
            or leaf.codesign.executed_argv != expected_executed_leaf_argv
        ):
            raise IdentityError("Mach-O leaf evidence is not bound to this code leaf")


def validate_asset_identity_for_shipping(
    identity: AssetIdentity,
    *,
    expected_probe_tool: FileIdentity,
    trusted_receipt_index: TrustedCommandReceiptCapability,
    staged_app_identity: AppIdentity | None = None,
) -> None:
    if not isinstance(identity, AssetIdentity):
        raise TypeError("identity must be AssetIdentity")
    if identity.schema != ASSET_IDENTITY_SCHEMA:
        raise IdentityError("asset identity schema is not current")
    if not isinstance(expected_probe_tool, FileIdentity):
        raise TypeError("expected_probe_tool must be an exact FileIdentity")
    validate_command_evidence_for_shipping(
        identity.probe,
        trusted_receipt_index=trusted_receipt_index,
        expected_tool=expected_probe_tool,
    )
    if not _same_file_identity(
        capture_tool_identity(
            expected_probe_tool.canonical_path, label="expected media probe"
        ),
        expected_probe_tool,
    ):
        raise IdentityError("expected media probe tool identity is stale")
    if len(identity.probe.targets) != 1 or len(identity.probe.pass_fds) != 1:
        raise IdentityError("probe evidence must contain exactly one media descriptor")
    media_target = identity.probe.targets[0]
    descriptor = identity.probe.pass_fds[0]
    expected_probe_argv = (
        identity.probe.tool.canonical_path,
        "-v",
        "error",
        "-show_streams",
        "-show_format",
        "-of",
        "json",
        f"/dev/fd/{descriptor}",
    )
    if (
        identity.probe.argv != expected_probe_argv
        or identity.probe.executed_argv[1:] != expected_probe_argv[1:]
        or media_target.role != "media_asset"
        or media_target.descriptor != descriptor
        or media_target.source_argument != f"/dev/fd/{descriptor}"
        or media_target.executed_argument != f"/dev/fd/{descriptor}"
        or media_target.file is None
        or not _same_file_identity(
            media_target.file, identity.file, compare_paths=False
        )
        or media_target.executed_file is None
        or not _same_file_identity(
            media_target.executed_file, identity.file, compare_paths=False
        )
    ):
        raise IdentityError("probe descriptor evidence is not bound to this asset")
    asset_fd, asset_chain = _open_absolute_nofollow(
        identity.file.canonical_path,
        label="shipping asset",
        final_flags=os.O_RDONLY,
    )
    try:
        current = _identity_from_open_fd(
            asset_fd,
            requested_path=identity.file.requested_path,
            canonical_path=identity.file.canonical_path,
            label="shipping asset",
        )
        current = dataclasses.replace(current, path_ancestry=asset_chain)
        if not _same_file_identity(current, identity.file):
            raise IdentityError("shipping asset identity is stale")
        _verify_absolute_binding(
            identity.file.canonical_path,
            asset_fd,
            asset_chain,
            label="shipping asset",
            final_flags=os.O_RDONLY,
        )
        _resolved_path_binding(
            identity.file.requested_path,
            identity.file.canonical_path,
            label="shipping asset",
        )
        prefix = _read_prefix(
            asset_fd, min(MAX_EBML_HEADER_BYTES, identity.file.stat.size_bytes)
        )
        container, structural_detail = _structural_container(
            prefix, identity.file.stat.size_bytes
        )
    finally:
        os.close(asset_fd)
    if identity.probe_raw_json != identity.probe.stdout_text:
        raise IdentityError("probe raw JSON is not the retained command transcript")
    parsed = _strict_json_object(identity.probe_raw_json)
    video, audio, duration = _derive_streams(parsed, container)
    native_eligible, reasons = _native_eligibility(container, video, audio)
    if (
        identity.container != container
        or identity.structural_detail != structural_detail
        or identity.video != video
        or identity.audio != audio
        or identity.duration_seconds != duration
        or identity.native_eligible != native_eligible
        or identity.native_ineligibility_reasons != reasons
    ):
        raise IdentityError("asset identity is not the exact probe/byte derivation")
    if identity.staged_app_binding is None:
        if identity.staged_app_path is not None or identity.contained_in_staged_app:
            raise IdentityError("unstaged asset has inconsistent staged-app fields")
        if staged_app_identity is not None:
            raise IdentityError("unexpected staged app identity")
        if not identity.native_eligible:
            raise IdentityError(
                "non-native fallback lacks an exact staged app binding"
            )
        return
    if identity.staged_app_path != identity.staged_app_binding.app_path:
        raise IdentityError("outer staged app path does not match staged app binding")
    if not identity.contained_in_staged_app:
        raise IdentityError("outer staged containment fact is inconsistent")
    if staged_app_identity is None:
        raise IdentityError("staged asset validation requires its exact AppIdentity")
    validate_app_identity_for_shipping(
        staged_app_identity, trusted_receipt_index=trusted_receipt_index
    )
    binding = identity.staged_app_binding
    if (
        binding.app_identity_sha256 != staged_app_identity.candidate_sha256
        or binding.app_path != staged_app_identity.app_path
        or binding.manifest_tree_sha256 != staged_app_identity.manifest.tree_sha256
        or binding.app_root_stat != staged_app_identity.manifest.app_root_stat
        or binding.root_stat != staged_app_identity.manifest.root_stat
    ):
        raise IdentityError("staged asset binding does not match supplied AppIdentity")
    if media_target.contents_tree_sha256 != staged_app_identity.manifest.tree_sha256:
        raise IdentityError("probe target is not joined to the staged app manifest")
    if (
        identity.native_eligible
        or identity.container != "webm"
        or identity.structural_detail != "ebml:webm"
        or identity.video.codec != "vp9"
        or identity.video.profile not in {"profile0", "profile2"}
        or identity.video.fourcc != "[0][0][0][0]"
        or identity.video.pixel_format not in {"yuv420p", "yuv420p10le"}
        or identity.audio.codec != "opus"
        or identity.audio.profile is not None
    ):
        raise IdentityError(
            "staged fallback must be exact VP9/WebM plus Opus control media"
        )
    _verify_source_manifest(staged_app_identity.manifest)
    relative = PurePosixPath(
        os.path.relpath(identity.file.canonical_path, staged_app_identity.manifest.contents_path)
    ).as_posix()
    expected = _expected_manifest_entry(
        staged_app_identity.manifest, relative, "file"
    )
    if binding.entry != expected or (
        expected.sha256 != identity.file.sha256
        or expected.stat != identity.file.stat
        or expected.extended_metadata_sha256
        != identity.file.extended_metadata_sha256
    ):
        raise IdentityError("staged asset entry identity does not match candidate")


def verify_app_identity_unchanged(before: AppIdentity, after: AppIdentity) -> None:
    """Compare campaign preflight/postflight app identities exactly."""

    if not isinstance(before, AppIdentity) or not isinstance(after, AppIdentity):
        raise TypeError("before and after must be AppIdentity instances")
    verify_contents_manifest_unchanged(before.manifest, after.manifest)
    if not _same_file_identity(before.codesign.tool, after.codesign.tool):
        raise IdentityError("codesign tool identity changed between captures")
    if _app_source_record(before) != _app_source_record(after):
        raise IdentityError("app identity metadata changed between captures")


def verify_asset_identity_unchanged(
    before: AssetIdentity,
    after: AssetIdentity,
) -> None:
    """Compare media identity/derivation while ignoring probe transcript timing."""

    if not isinstance(before, AssetIdentity) or not isinstance(after, AssetIdentity):
        raise TypeError("before and after must be AssetIdentity instances")
    if not _same_file_identity(before.probe.tool, after.probe.tool):
        raise IdentityError("ffprobe tool identity changed between captures")
    stable_before = dataclasses.replace(
        before,
        probe=after.probe,
    )
    if stable_before != after:
        raise IdentityError("asset bytes or derived stream identity changed between captures")


__all__ = [
    "APP_IDENTITY_SCHEMA",
    "ASSET_IDENTITY_SCHEMA",
    "CONTENTS_MANIFEST_SCHEMA",
    "AppIdentity",
    "AssetIdentity",
    "AudioIdentity",
    "CommandEvidence",
    "CommandTargetIdentity",
    "CommandResult",
    "CodeLeafEvidence",
    "ContentsManifest",
    "FileIdentity",
    "FileStatIdentity",
    "IdentityError",
    "ManifestEntry",
    "StagedAppBinding",
    "VideoIdentity",
    "capture_app_identity",
    "capture_asset_identity",
    "capture_contents_manifest",
    "capture_tool_identity",
    "verify_app_identity_unchanged",
    "verify_asset_identity_unchanged",
    "verify_contents_manifest_unchanged",
    "validate_app_identity_for_shipping",
    "validate_asset_identity_for_shipping",
    "validate_command_evidence_for_shipping",
]
