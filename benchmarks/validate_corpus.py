#!/usr/bin/env python3
"""Create and validate the deterministic WAM native-v1 media corpus receipt.

The checked-in corpus is a declaration.  The preparation manifest is an
ignored, machine-local receipt made from the bytes that were actually
generated.  This module deliberately verifies the facts that ffprobe could
otherwise merely assert:

* ISO BMFF track sample entries are read from ``stsd`` (``avc1``/``hvc1`` and
  ``mp4a``);
* Matroska's EBML DocType and TrackEntry CodecID values are read directly;
* encoded packet payload hashes are compared without timestamps so the three
  re-containers for a codec family must contain the same elementary stream.

No command is evaluated through a shell.  Tool and recipe identities, exact
raw probe JSON, and every generated file hash are retained in the receipt.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import stat
import struct
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from fractions import Fraction
from pathlib import Path, PurePosixPath
from typing import Any, Callable, Iterable, Mapping, Sequence


CORPUS_SCHEMA = "wam.native.corpus.v1"
MANIFEST_SCHEMA = "wam.native.corpus.preparation.v1"
LEDGER_SCHEMA = "wam.native.corpus.command-ledger.v1"
RUNTIME_SCHEMA = "wam.native.corpus.runtime.v1"
MEDIA_ROOT_PLACEHOLDER = "{{MEDIA_ROOT}}"
MEDIA_ROOT_PLACEHOLDERS = {
    MEDIA_ROOT_PLACEHOLDER: "absolute output media root chosen at replay time"
}
DEFAULT_TIMEOUT_SECONDS = 60.0
DEFAULT_MAX_PROBE_BYTES = 64 * 1024 * 1024
MAX_SMALL_BOX_BYTES = 16 * 1024 * 1024
AAC_LC_PACKET_COUNT = 3375
AAC_LC_SAMPLES_PER_PACKET = 1024
AAC_LC_SAMPLE_RATE_HZ = 48000
VIDEO_PACKET_COUNT = 2160
VIDEO_KEYFRAME_ORDINALS = tuple(range(0, VIDEO_PACKET_COUNT, 60))
MAX_VIDEO_PACKET_BYTES = 8 * 1024 * 1024
MAX_AUDIO_PACKET_BYTES = 256 * 1024

EXPECTED_VIDEO_SOURCE_FILTER = (
    "testsrc2=size=1920x1080:rate=30:duration=72:sar=1/1,format=yuv420p,"
    "setpts=N/(30*TB),setparams=field_mode=prog:range=limited:"
    "color_primaries=bt709:color_trc=bt709:colorspace=bt709:"
    "chroma_location=left,drawbox=x=32:y=32:w=744:h=112:color=black:t=fill,"
    "drawbox=x=40:y=48:w=8:h=80:color=red:t=fill,"
    "drawbox=x=760:y=48:w=8:h=80:color=red:t=fill"
    + "".join(
        f",drawbox=x={64 + bit * 56}:y=56:w=40:h=64:color=white:t=fill:"
        f"enable=gte(mod(floor((t+0.000001)*30/{1 << bit})\\,2)\\,1)"
        for bit in range(12)
    )
)
EXPECTED_AUDIO_SOURCE_FILTER = (
    "sine=frequency=997:sample_rate=48000:duration=72,"
    "atrim=end_sample=3454976,pan=stereo|c0=c0|c1=c0,"
    "volume=0.125,asetpts=N/SR/TB"
)
EXPECTED_STREAM_IDENTITY_POLICY = (
    "Each codec profile is encoded once. Its encoded video packets and the one "
    "AAC-LC packet stream are then stream-copied into MP4, MOV, and Matroska. "
    "Preparation validates ordered packet-payload hashes without using container "
    "timestamps."
)

EXPECTED_MATRIX = frozenset(
    {
        ("h264", "high", "mp4"),
        ("h264", "high", "mov"),
        ("h264", "high", "mkv"),
        ("hevc", "main", "mp4"),
        ("hevc", "main", "mov"),
        ("hevc", "main", "mkv"),
        ("hevc", "main10", "mp4"),
        ("hevc", "main10", "mov"),
        ("hevc", "main10", "mkv"),
    }
)

EXPECTED_RECIPES: Mapping[str, Mapping[str, Any]] = {
    "h264-high": {
        "encoder": "libx264",
        "profile": "high",
        "level": "4.0",
        "pixel_format": "yuv420p",
        "crf": 20,
        "preset": "veryfast",
        "gop_frames": 60,
        "minimum_gop_frames": 60,
        "b_frames": 3,
        "closed_gop": True,
        "scene_cut": False,
        "encoder_threads": 1,
        "filter_threads": 1,
        "color_range": "tv",
        "color_primaries": "bt709",
        "color_transfer": "bt709",
        "color_space": "bt709",
    },
    "hevc-main": {
        "encoder": "libx265",
        "profile": "main",
        "level": "4.0",
        "pixel_format": "yuv420p",
        "crf": 22,
        "preset": "veryfast",
        "gop_frames": 60,
        "minimum_gop_frames": 60,
        "b_frames": 4,
        "closed_gop": True,
        "scene_cut": False,
        "encoder_threads": 1,
        "worker_pools": "none",
        "wavefront_parallel_processing": False,
        "filter_threads": 1,
        "color_range": "tv",
        "color_primaries": "bt709",
        "color_transfer": "bt709",
        "color_space": "bt709",
    },
    "hevc-main10": {
        "encoder": "libx265",
        "profile": "main10",
        "level": "4.0",
        "pixel_format": "yuv420p10le",
        "crf": 22,
        "preset": "veryfast",
        "gop_frames": 60,
        "minimum_gop_frames": 60,
        "b_frames": 4,
        "closed_gop": True,
        "scene_cut": False,
        "encoder_threads": 1,
        "worker_pools": "none",
        "wavefront_parallel_processing": False,
        "filter_threads": 1,
        "color_range": "tv",
        "color_primaries": "bt709",
        "color_transfer": "bt709",
        "color_space": "bt709",
    },
    "aac-lc": {
        "encoder": "aac",
        "profile": "aac_low",
        "sample_rate_hz": 48000,
        "channels": 2,
        "channel_layout": "stereo",
        "bit_rate": "128k",
        "coder": "twoloop",
        "encoder_threads": 1,
        "source_samples": 3454976,
        "encoded_access_units": 3375,
        "encoded_duration_seconds": 72.0,
        "master_format": "adts",
    },
}


class CorpusError(RuntimeError):
    """A declaration, asset, probe, or preparation receipt is invalid."""


@dataclass(frozen=True)
class CommandResult:
    returncode: int
    stdout: bytes
    stderr: bytes


CommandRunner = Callable[[Sequence[str], float, int], CommandResult]


@dataclass(frozen=True)
class Declaration:
    identifier: str
    relative_path: str
    container: str
    codec: str
    profile: str
    pixel_format: str
    width: int
    height: int
    fps: Fraction
    audio_codec: str
    audio_profile: str
    sample_rate_hz: int
    channels: int
    channel_layout: str
    duration_seconds: Fraction
    minimum_duration_seconds: Fraction
    duration_tolerance_seconds: Fraction
    video_payload_family: str
    audio_payload_family: str
    video_recipe: str
    audio_recipe: str
    declared_video_sample_entry: str | None
    declared_audio_sample_entry: str | None
    declared_video_codec_id: str | None
    declared_audio_codec_id: str | None

    @property
    def matrix_key(self) -> tuple[str, str, str]:
        return self.codec, self.profile, self.container


@dataclass(frozen=True)
class Intermediate:
    identifier: str
    relative_path: str
    kind: str
    recipe: str
    payload_identity_group: str


@dataclass(frozen=True)
class LedgerCommand:
    identifier: str
    argv: tuple[str, ...]
    outputs: tuple[str, ...]


@dataclass(frozen=True)
class Box:
    kind: bytes
    start: int
    payload_start: int
    end: int


def _reject_constant(value: str) -> Any:
    raise CorpusError(f"JSON contains non-finite value {value}")


def _unique_pairs(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise CorpusError(f"JSON contains duplicate key {key!r}")
        result[key] = value
    return result


def _parse_json_bytes(raw: bytes, label: str) -> Mapping[str, Any]:
    try:
        text = raw.decode("utf-8", errors="strict")
        value = json.loads(
            text,
            object_pairs_hook=_unique_pairs,
            parse_constant=_reject_constant,
        )
    except CorpusError:
        raise
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise CorpusError(f"{label} is not strict UTF-8 JSON: {error}") from error
    if not isinstance(value, dict):
        raise CorpusError(f"{label} root must be an object")
    return value


def _load_json(path: Path, label: str) -> tuple[Mapping[str, Any], bytes]:
    try:
        raw = path.read_bytes()
    except OSError as error:
        raise CorpusError(f"cannot read {label} {path}: {error}") from error
    return _parse_json_bytes(raw, label), raw


def _canonical_json_bytes(value: Any) -> bytes:
    return json.dumps(
        value,
        ensure_ascii=False,
        allow_nan=False,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")


def _sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def _sha256_file(path: Path) -> tuple[int, str]:
    digest = hashlib.sha256()
    size = 0
    try:
        with path.open("rb") as source:
            while True:
                block = source.read(1024 * 1024)
                if not block:
                    break
                size += len(block)
                digest.update(block)
    except OSError as error:
        raise CorpusError(f"cannot hash {path}: {error}") from error
    return size, digest.hexdigest()


def _file_identity(path: Path, label: str) -> Mapping[str, Any]:
    try:
        resolved = path.resolve(strict=True)
        before = resolved.stat()
    except OSError as error:
        raise CorpusError(f"cannot resolve {label} {path}: {error}") from error
    if not stat.S_ISREG(before.st_mode):
        raise CorpusError(f"{label} is not a regular file: {resolved}")
    size, sha256 = _sha256_file(resolved)
    try:
        after = resolved.stat()
    except OSError as error:
        raise CorpusError(f"cannot restat {label} {resolved}: {error}") from error
    before_key = (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns)
    after_key = (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns)
    if before_key != after_key:
        raise CorpusError(f"{label} changed while it was hashed")
    return {"canonical_path": str(resolved), "bytes": size, "sha256": sha256}


_MACHO_MAGICS = {
    b"\xce\xfa\xed\xfe": ("<", False),
    b"\xcf\xfa\xed\xfe": ("<", True),
    b"\xfe\xed\xfa\xce": (">", False),
    b"\xfe\xed\xfa\xcf": (">", True),
}
_FAT_MAGICS = {
    b"\xca\xfe\xba\xbe": (">", False),
    b"\xbe\xba\xfe\xca": ("<", False),
    b"\xca\xfe\xba\xbf": (">", True),
    b"\xbf\xba\xfe\xca": ("<", True),
}
_DYLIB_LOAD_COMMANDS = {0xC, 0x18, 0x1F, 0x20, 0x23}
_LC_UUID = 0x1B
_LC_RPATH = 0x1C


@dataclass(frozen=True)
class MachOSlice:
    cpu_type: int
    cpu_subtype: int
    uuids: tuple[str, ...]
    dependencies: tuple[str, ...]
    rpaths: tuple[str, ...]


def _macho_slices(path: Path) -> tuple[MachOSlice, ...]:
    """Parse Mach-O UUID, dylib, and rpath load commands without otool."""

    try:
        size = path.stat().st_size
        with path.open("rb") as source:
            magic = _read_exact(source, 0, 4, "Mach-O magic")
            if magic in _MACHO_MAGICS:
                slice_ranges = [(0, size)]
            elif magic in _FAT_MAGICS:
                endian, is_64 = _FAT_MAGICS[magic]
                count = struct.unpack(f"{endian}I", _read_exact(source, 4, 4, "fat count"))[0]
                if count < 1 or count > 64:
                    raise CorpusError("fat Mach-O architecture count is invalid")
                entry_size = 32 if is_64 else 20
                table_end = 8 + count * entry_size
                if table_end > size:
                    raise CorpusError("fat Mach-O architecture table is truncated")
                slice_ranges = []
                for index in range(count):
                    raw = _read_exact(
                        source,
                        8 + index * entry_size,
                        entry_size,
                        "fat architecture",
                    )
                    if is_64:
                        _, _, offset, slice_size, _, _ = struct.unpack(
                            f"{endian}iiQQII", raw
                        )
                    else:
                        _, _, offset, slice_size, _ = struct.unpack(
                            f"{endian}iiIII", raw
                        )
                    if (
                        slice_size < 28
                        or offset < table_end
                        or offset + slice_size > size
                    ):
                        raise CorpusError("fat Mach-O slice escapes its file")
                    slice_ranges.append((offset, slice_size))
                sorted_ranges = sorted(slice_ranges)
                for first, second in zip(sorted_ranges, sorted_ranges[1:]):
                    if first[0] + first[1] > second[0]:
                        raise CorpusError("fat Mach-O slices overlap")
            else:
                return ()

            slices: list[MachOSlice] = []
            for slice_offset, slice_size in slice_ranges:
                slice_magic = _read_exact(source, slice_offset, 4, "Mach-O slice magic")
                if slice_magic not in _MACHO_MAGICS:
                    raise CorpusError("fat slice is not a supported Mach-O image")
                endian, is_64 = _MACHO_MAGICS[slice_magic]
                header_size = 32 if is_64 else 28
                header = _read_exact(source, slice_offset, header_size, "Mach-O header")
                cpu_type, cpu_subtype = struct.unpack(f"{endian}ii", header[4:12])
                ncmds, sizeofcmds = struct.unpack(f"{endian}II", header[16:24])
                if ncmds > 65536 or sizeofcmds > slice_size - header_size:
                    raise CorpusError("Mach-O load-command table is invalid")
                command_start = slice_offset + header_size
                command_end = command_start + sizeofcmds
                cursor = command_start
                dependencies: list[str] = []
                rpaths: list[str] = []
                uuids: list[str] = []
                for _ in range(ncmds):
                    if command_end - cursor < 8:
                        raise CorpusError("Mach-O load command is truncated")
                    command, command_size = struct.unpack(
                        f"{endian}II",
                        _read_exact(source, cursor, 8, "Mach-O load command"),
                    )
                    base_command = command & 0x7FFFFFFF
                    if command_size < 8 or cursor + command_size > command_end:
                        raise CorpusError("Mach-O load command has an invalid size")
                    if base_command in _DYLIB_LOAD_COMMANDS:
                        if command_size < 24:
                            raise CorpusError("Mach-O dylib command is truncated")
                        string_offset = struct.unpack(
                            f"{endian}I",
                            _read_exact(source, cursor + 8, 4, "dylib name offset"),
                        )[0]
                        dependencies.append(
                            _macho_command_string(
                                source,
                                cursor,
                                command_size,
                                string_offset,
                                "dylib name",
                            )
                        )
                    elif base_command == _LC_RPATH:
                        if command_size < 12:
                            raise CorpusError("Mach-O rpath command is truncated")
                        string_offset = struct.unpack(
                            f"{endian}I",
                            _read_exact(source, cursor + 8, 4, "rpath offset"),
                        )[0]
                        rpaths.append(
                            _macho_command_string(
                                source,
                                cursor,
                                command_size,
                                string_offset,
                                "rpath",
                            )
                        )
                    elif base_command == _LC_UUID:
                        if command_size != 24:
                            raise CorpusError("Mach-O UUID command has an invalid size")
                        raw_uuid = _read_exact(source, cursor + 8, 16, "Mach-O UUID")
                        hexadecimal = raw_uuid.hex()
                        uuids.append(
                            "-".join(
                                (
                                    hexadecimal[:8],
                                    hexadecimal[8:12],
                                    hexadecimal[12:16],
                                    hexadecimal[16:20],
                                    hexadecimal[20:],
                                )
                            )
                        )
                    cursor += command_size
                if cursor != command_end:
                    raise CorpusError("Mach-O load commands do not fill sizeofcmds")
                if len(uuids) > 1:
                    raise CorpusError("Mach-O slice contains duplicate UUID commands")
                slices.append(
                    MachOSlice(
                        cpu_type,
                        cpu_subtype,
                        tuple(uuids),
                        tuple(dependencies),
                        tuple(rpaths),
                    )
                )
    except CorpusError:
        raise
    except OSError as error:
        raise CorpusError(f"cannot parse Mach-O file {path}: {error}") from error
    return tuple(slices)


def _macho_command_string(
    source: Any,
    command_start: int,
    command_size: int,
    string_offset: int,
    label: str,
) -> str:
    if string_offset < 8 or string_offset >= command_size:
        raise CorpusError(f"Mach-O {label} offset is invalid")
    raw = _read_exact(
        source,
        command_start + string_offset,
        command_size - string_offset,
        f"Mach-O {label}",
    )
    terminator = raw.find(b"\0")
    if terminator < 1:
        raise CorpusError(f"Mach-O {label} is not NUL terminated")
    if any(raw[terminator + 1 :]):
        raise CorpusError(f"Mach-O {label} has nonzero command padding")
    try:
        return raw[:terminator].decode("utf-8", errors="strict")
    except UnicodeDecodeError as error:
        raise CorpusError(f"Mach-O {label} is not UTF-8") from error


def _is_system_path(path: Path) -> bool:
    value = str(path)
    return value.startswith("/System/Library/") or value.startswith("/usr/lib/")


def _expand_dyld_token(value: str, *, loader_dir: Path, executable_dir: Path) -> Path:
    if value == "@loader_path":
        return loader_dir
    if value.startswith("@loader_path/"):
        return loader_dir / value[len("@loader_path/") :]
    if value == "@executable_path":
        return executable_dir
    if value.startswith("@executable_path/"):
        return executable_dir / value[len("@executable_path/") :]
    return Path(value)


def _resolve_dependency(
    load_name: str,
    *,
    loader_path: Path,
    executable_path: Path,
    rpaths: Sequence[str],
) -> tuple[Path | None, tuple[str, ...]]:
    loader_dir = loader_path.parent
    executable_dir = executable_path.parent
    candidates: list[Path] = []
    if load_name.startswith("@rpath/"):
        suffix = load_name[len("@rpath/") :]
        for rpath in rpaths:
            expanded = _expand_dyld_token(
                rpath, loader_dir=loader_dir, executable_dir=executable_dir
            )
            if expanded.is_absolute():
                candidates.append(expanded / suffix)
    elif load_name.startswith("@loader_path") or load_name.startswith(
        "@executable_path"
    ):
        expanded = _expand_dyld_token(
            load_name, loader_dir=loader_dir, executable_dir=executable_dir
        )
        if expanded.is_absolute():
            candidates.append(expanded)
    elif load_name.startswith("/"):
        candidates.append(Path(load_name))
    else:
        raise CorpusError(
            f"Mach-O dependency uses an unsupported relative install name: {load_name!r}"
        )

    tried: list[str] = []
    for candidate in candidates:
        tried.append(str(candidate))
        try:
            resolved = candidate.resolve(strict=True)
        except OSError:
            continue
        if not resolved.is_file():
            continue
        return resolved, tuple(tried)
    if load_name.startswith("/usr/lib/") or load_name.startswith("/System/Library/"):
        return None, tuple(tried)
    if candidates and all(_is_system_path(candidate) for candidate in candidates):
        # Modern macOS may expose a system dylib only through the shared cache.
        return None, tuple(tried)
    raise CorpusError(
        f"could not resolve non-system Mach-O dependency {load_name!r}; tried={tried}"
    )


def _macho_facts(slices: Sequence[MachOSlice]) -> Mapping[str, Any] | None:
    if not slices:
        return None
    return {
        "slices": [
            {
                "cpu_type": item.cpu_type,
                "cpu_subtype": item.cpu_subtype,
                "uuids": list(item.uuids),
                "dependencies": list(item.dependencies),
                "rpaths": list(item.rpaths),
            }
            for item in slices
        ]
    }


def capture_runtime_identity(
    corpus_path: Path,
    *,
    ffmpeg_path: Path,
    ffprobe_path: Path,
    recipe_script_path: Path | None,
) -> Mapping[str, Any]:
    """Capture roots and recursive non-system Mach-O dependency closure."""

    corpus_path = corpus_path.resolve(strict=True)
    corpus, corpus_raw = _load_json(corpus_path, "corpus")
    native = _native_section(corpus)
    corpus_id = _required_string(native, "id", "corpus.native_generated_corpus")
    recipe_script = _resolve_recipe_script(corpus_path, recipe_script_path)
    root_paths = {
        "ffmpeg": _resolve_tool(ffmpeg_path, "ffmpeg"),
        "ffprobe": _resolve_tool(ffprobe_path, "ffprobe"),
        "python": Path(sys.executable).resolve(strict=True),
        "validator": Path(__file__).resolve(strict=True),
        "recipe_script": recipe_script,
    }
    roots: dict[str, Mapping[str, Any]] = {}
    dependencies: dict[str, Mapping[str, Any]] = {}

    for root_name, root_path in root_paths.items():
        root_identity = dict(_file_identity(root_path, f"runtime root {root_name}"))
        root_slices = _macho_slices(root_path)
        root_identity["mach_o"] = _macho_facts(root_slices)
        closure_paths: set[str] = set()
        system_loads: set[str] = set()
        # (image, inherited rpaths).  The executable path remains the root so
        # @executable_path has dyld's actual meaning throughout the closure.
        pending: list[tuple[Path, tuple[str, ...]]] = [(root_path, ())]
        visited_contexts: set[tuple[str, tuple[str, ...]]] = set()
        while pending:
            image_path, inherited_rpaths = pending.pop()
            slices = _macho_slices(image_path)
            local_rpaths: list[str] = []
            for image_slice in slices:
                for rpath in image_slice.rpaths:
                    if rpath not in local_rpaths:
                        local_rpaths.append(rpath)
            combined_rpaths = tuple(local_rpaths) + inherited_rpaths
            context = (str(image_path), combined_rpaths)
            if context in visited_contexts:
                continue
            visited_contexts.add(context)
            for image_slice in slices:
                for load_name in image_slice.dependencies:
                    resolved, _ = _resolve_dependency(
                        load_name,
                        loader_path=image_path,
                        executable_path=root_path,
                        rpaths=combined_rpaths,
                    )
                    if resolved is None or _is_system_path(resolved):
                        system_loads.add(load_name)
                        continue
                    canonical = str(resolved)
                    closure_paths.add(canonical)
                    if canonical not in dependencies:
                        identity = dict(
                            _file_identity(resolved, "runtime dependency")
                        )
                        dependency_slices = _macho_slices(resolved)
                        if not dependency_slices:
                            raise CorpusError(
                                f"non-system Mach-O dependency is not Mach-O: {resolved}"
                            )
                        identity["mach_o"] = _macho_facts(dependency_slices)
                        dependencies[canonical] = identity
                    pending.append((resolved, combined_rpaths))
        root_identity["non_system_dependency_paths"] = sorted(closure_paths)
        root_identity["system_dependency_loads"] = sorted(system_loads)
        roots[root_name] = root_identity

    return {
        "schema": RUNTIME_SCHEMA,
        "corpus": {
            "id": corpus_id,
            "canonical_path": str(corpus_path),
            "sha256": _sha256_bytes(corpus_raw),
        },
        "roots": roots,
        "non_system_dependencies": {
            path: dependencies[path] for path in sorted(dependencies)
        },
    }


def write_runtime_receipt(
    receipt: Mapping[str, Any],
    path: Path,
    *,
    corpus_path: Path,
    require_ignored: bool = True,
) -> None:
    write_preparation_manifest(
        receipt,
        path,
        corpus_path=corpus_path,
        require_ignored=require_ignored,
    )


def validate_runtime_receipt(
    receipt_path: Path,
    corpus_path: Path,
    *,
    ffmpeg_path: Path,
    ffprobe_path: Path,
    recipe_script_path: Path | None,
    require_ignored: bool = True,
) -> tuple[Mapping[str, Any], bytes]:
    if require_ignored:
        _require_ignored_manifest(receipt_path, corpus_path)
    recorded, raw = _load_json(receipt_path, "runtime receipt")
    if recorded.get("schema") != RUNTIME_SCHEMA:
        raise CorpusError(f"runtime receipt schema must equal {RUNTIME_SCHEMA!r}")
    actual = capture_runtime_identity(
        corpus_path,
        ffmpeg_path=ffmpeg_path,
        ffprobe_path=ffprobe_path,
        recipe_script_path=recipe_script_path,
    )
    if _canonical_json_bytes(recorded) != _canonical_json_bytes(actual):
        raise CorpusError(
            "runtime closure differs from the pre-encoding runtime receipt"
        )
    return recorded, raw


def _required_mapping(value: Mapping[str, Any], key: str, label: str) -> Mapping[str, Any]:
    item = value.get(key)
    if not isinstance(item, dict):
        raise CorpusError(f"{label}.{key} must be an object")
    return item


def _required_string(value: Mapping[str, Any], key: str, label: str) -> str:
    item = value.get(key)
    if not isinstance(item, str) or not item or "\x00" in item:
        raise CorpusError(f"{label}.{key} must be a non-empty string")
    return item


def _required_integer(value: Mapping[str, Any], key: str, label: str) -> int:
    item = value.get(key)
    if isinstance(item, bool) or not isinstance(item, int):
        raise CorpusError(f"{label}.{key} must be an integer")
    return item


def _fraction(value: Any, label: str, *, positive: bool = True) -> Fraction:
    if isinstance(value, bool) or not isinstance(value, (int, float, str)):
        raise CorpusError(f"{label} must be a decimal number or rational string")
    if isinstance(value, float) and not math.isfinite(value):
        raise CorpusError(f"{label} must be finite")
    try:
        result = Fraction(str(value))
    except (ValueError, ZeroDivisionError) as error:
        raise CorpusError(f"{label} is not a valid number") from error
    if positive and result <= 0:
        raise CorpusError(f"{label} must be positive")
    if not positive and result < 0:
        raise CorpusError(f"{label} must not be negative")
    return result


def _normalized_profile(value: str) -> str:
    return "".join(character for character in value.lower() if character.isalnum())


def _native_section(corpus: Mapping[str, Any]) -> Mapping[str, Any]:
    # Native-v1 is nested so the pre-existing compatibility corpus can remain
    # in the same checked-in document without becoming part of this matrix.
    native = corpus.get("native_generated_corpus")
    if not isinstance(native, dict):
        raise CorpusError("corpus.native_generated_corpus must be an object")
    if native.get("schema") != CORPUS_SCHEMA:
        raise CorpusError(
            f"corpus.native_generated_corpus.schema must equal {CORPUS_SCHEMA!r}"
        )
    return native


def parse_declarations(corpus: Mapping[str, Any]) -> tuple[Declaration, ...]:
    native = _native_section(corpus)
    native_label = "corpus.native_generated_corpus"
    if _required_string(native, "id", native_label) != "native-1080p-sdr-v1":
        raise CorpusError("native generated corpus id must be 'native-1080p-sdr-v1'")
    if _required_string(native, "kind", native_label) != "deterministic-local-generation":
        raise CorpusError("native generated corpus kind must be deterministic-local-generation")
    output_subdirectory = _required_string(native, "output_subdirectory", native_label)
    output_path = PurePosixPath(output_subdirectory)
    if (
        output_path.is_absolute()
        or ".." in output_path.parts
        or "." in output_path.parts
        or str(output_path) != output_subdirectory
    ):
        raise CorpusError("native output_subdirectory must be a normalized relative path")
    manifest_relative = _required_string(native, "preparation_manifest", native_label)
    manifest_pure = PurePosixPath(manifest_relative)
    if (
        manifest_pure.is_absolute()
        or ".." in manifest_pure.parts
        or str(manifest_pure) != manifest_relative
        or not manifest_pure.parts
        or manifest_pure.parts[0] != output_subdirectory
    ):
        raise CorpusError("native preparation_manifest must be inside output_subdirectory")
    if manifest_pure.name != "preparation-manifest.json":
        raise CorpusError("native preparation_manifest must end in preparation-manifest.json")
    runtime_relative = _required_string(native, "runtime_receipt", native_label)
    runtime_pure = PurePosixPath(runtime_relative)
    if (
        runtime_pure.is_absolute()
        or ".." in runtime_pure.parts
        or "." in runtime_pure.parts
        or str(runtime_pure) != runtime_relative
        or not runtime_pure.parts
        or runtime_pure.parts[0] != output_subdirectory
        or runtime_pure.name != "runtime-receipt.json"
    ):
        raise CorpusError("native runtime_receipt must be normalized inside output_subdirectory")
    root_duration = _fraction(native.get("duration_seconds"), f"{native_label}.duration_seconds")
    if root_duration != 72:
        raise CorpusError("native duration_seconds must be exactly 72.0")
    root_fps = _fraction(native.get("frame_rate"), f"{native_label}.frame_rate")
    if root_fps != 30:
        raise CorpusError("native frame_rate must be exactly 30/1")
    if (
        _required_string(native, "video_source_filter", native_label)
        != EXPECTED_VIDEO_SOURCE_FILTER
    ):
        raise CorpusError("native video_source_filter differs from the frozen marker")
    if (
        _required_string(native, "audio_source_filter", native_label)
        != EXPECTED_AUDIO_SOURCE_FILTER
    ):
        raise CorpusError("native audio_source_filter differs from the frozen source")
    if (
        _required_string(native, "stream_identity_policy", native_label)
        != EXPECTED_STREAM_IDENTITY_POLICY
    ):
        raise CorpusError("native stream_identity_policy differs from the frozen policy")
    recipes = _required_mapping(native, "recipes", native_label)
    expected_recipes = set(EXPECTED_RECIPES)
    if set(recipes) != expected_recipes:
        raise CorpusError(
            "native recipes must contain exactly h264-high, hevc-main, hevc-main10, and aac-lc"
        )
    for recipe_name, recipe in recipes.items():
        if recipe != EXPECTED_RECIPES[recipe_name]:
            raise CorpusError(
                f"native recipe {recipe_name!r} does not match the frozen native-v1 contract"
            )
    entries = native.get("entries")
    if not isinstance(entries, list):
        raise CorpusError("corpus.native_generated_corpus.entries must be an array")

    default_required = _fraction(
        native.get("minimum_duration_seconds"),
        "corpus.native_generated_corpus.minimum_duration_seconds",
    )
    if default_required != Fraction(719, 10):
        raise CorpusError("native minimum_duration_seconds must be exactly 71.9")
    # The checked-in minimum fixes the only allowed slop around the declared
    # duration.  It is deliberately not caller-configurable at validation
    # time.
    default_tolerance = root_duration - default_required
    if default_tolerance < 0:
        raise CorpusError("native minimum_duration_seconds exceeds duration_seconds")
    declarations: list[Declaration] = []
    identifiers: set[str] = set()
    paths: set[str] = set()
    matrix: set[tuple[str, str, str]] = set()

    for index, raw_entry in enumerate(entries):
        label = f"corpus.native_generated_corpus.entries[{index}]"
        if not isinstance(raw_entry, dict):
            raise CorpusError(f"{label} must be an object")
        identifier = _required_string(raw_entry, "id", label)
        if identifier in identifiers:
            raise CorpusError(f"duplicate native-v1 id {identifier!r}")
        identifiers.add(identifier)
        if _required_string(raw_entry, "kind", label) != "locally-generated-native-v1":
            raise CorpusError(f"{label}.kind must equal 'locally-generated-native-v1'")

        relative_path = _required_string(raw_entry, "path", label)
        pure_path = PurePosixPath(relative_path)
        if pure_path.is_absolute() or ".." in pure_path.parts or "." in pure_path.parts:
            raise CorpusError(f"{label}.path must be a normalized relative path")
        if str(pure_path) != relative_path or "\\" in relative_path:
            raise CorpusError(f"{label}.path must use normalized POSIX separators")
        if not pure_path.parts or pure_path.parts[0] != output_subdirectory:
            raise CorpusError(f"{label}.path must be inside output_subdirectory")
        if relative_path in paths:
            raise CorpusError(f"duplicate native-v1 path {relative_path!r}")
        paths.add(relative_path)

        container = _required_string(raw_entry, "container", label).lower()
        video = _required_mapping(raw_entry, "video", label)
        audio = _required_mapping(raw_entry, "audio", label)
        codec = _required_string(video, "codec", f"{label}.video").lower()
        profile = _normalized_profile(
            _required_string(video, "profile", f"{label}.video")
        )
        pixel_format = _required_string(
            video, "pixel_format", f"{label}.video"
        ).lower()
        width = _required_integer(video, "width", f"{label}.video")
        height = _required_integer(video, "height", f"{label}.video")
        fps = _fraction(video.get("fps"), f"{label}.video.fps")
        audio_codec = _required_string(audio, "codec", f"{label}.audio").lower()
        audio_profile = _normalized_profile(
            _required_string(audio, "profile", f"{label}.audio")
        )
        sample_rate = _required_integer(
            audio, "sample_rate_hz", f"{label}.audio"
        )
        channels = _required_integer(audio, "channels", f"{label}.audio")
        channel_layout = _required_string(
            audio, "channel_layout", f"{label}.audio"
        ).lower()
        duration = _fraction(
            raw_entry.get("duration_seconds"), f"{label}.duration_seconds"
        )
        minimum = default_required
        tolerance = default_tolerance
        payload_family = _required_string(
            video, "payload_identity_group", f"{label}.video"
        )
        audio_payload_family = _required_string(
            audio, "payload_identity_group", f"{label}.audio"
        )
        video_recipe = _required_string(raw_entry, "video_recipe", label)
        audio_recipe = _required_string(raw_entry, "audio_recipe", label)
        if video_recipe not in recipes or audio_recipe not in recipes:
            raise CorpusError(f"{label} references an undeclared recipe")
        if audio_recipe != "aac-lc":
            raise CorpusError(f"{label}.audio_recipe must equal 'aac-lc'")
        declared_video_sample_entry = video.get("sample_entry")
        declared_audio_sample_entry = audio.get("sample_entry")
        declared_video_codec_id = video.get("matroska_codec_id")
        declared_audio_codec_id = audio.get("matroska_codec_id")
        optional_values = {
            "video.sample_entry": declared_video_sample_entry,
            "audio.sample_entry": declared_audio_sample_entry,
            "video.matroska_codec_id": declared_video_codec_id,
            "audio.matroska_codec_id": declared_audio_codec_id,
        }
        for field, value in optional_values.items():
            if value is not None and (not isinstance(value, str) or not value):
                raise CorpusError(f"{label}.{field} must be a non-empty string when present")

        declaration = Declaration(
            identifier=identifier,
            relative_path=relative_path,
            container=container,
            codec=codec,
            profile=profile,
            pixel_format=pixel_format,
            width=width,
            height=height,
            fps=fps,
            audio_codec=audio_codec,
            audio_profile=audio_profile,
            sample_rate_hz=sample_rate,
            channels=channels,
            channel_layout=channel_layout,
            duration_seconds=duration,
            minimum_duration_seconds=minimum,
            duration_tolerance_seconds=tolerance,
            video_payload_family=payload_family,
            audio_payload_family=audio_payload_family,
            video_recipe=video_recipe,
            audio_recipe=audio_recipe,
            declared_video_sample_entry=declared_video_sample_entry,
            declared_audio_sample_entry=declared_audio_sample_entry,
            declared_video_codec_id=declared_video_codec_id,
            declared_audio_codec_id=declared_audio_codec_id,
        )
        if declaration.matrix_key in matrix:
            raise CorpusError(f"duplicate native-v1 matrix row {declaration.matrix_key}")
        matrix.add(declaration.matrix_key)
        declarations.append(declaration)

    if matrix != EXPECTED_MATRIX or len(declarations) != len(EXPECTED_MATRIX):
        missing = sorted(EXPECTED_MATRIX - matrix)
        extra = sorted(matrix - EXPECTED_MATRIX)
        raise CorpusError(
            f"native-v1 must contain exactly the nine required rows; "
            f"missing={missing}, extra={extra}"
        )

    for declaration in declarations:
        if declaration.width != 1920 or declaration.height != 1080:
            raise CorpusError(f"{declaration.identifier}: dimensions must be exactly 1920x1080")
        if declaration.width > 1920 or declaration.height > 1080:
            raise CorpusError(f"{declaration.identifier}: exceeds the native-v1 dimension cap")
        if declaration.fps != 30:
            raise CorpusError(f"{declaration.identifier}: frame rate must be exactly 30 fps")
        if declaration.duration_seconds != root_duration:
            raise CorpusError(
                f"{declaration.identifier}: duration must equal the native corpus duration"
            )
        expected_pixel = "yuv420p10le" if declaration.profile == "main10" else "yuv420p"
        if declaration.pixel_format != expected_pixel:
            raise CorpusError(
                f"{declaration.identifier}: pixel format must be {expected_pixel}"
            )
        if declaration.audio_codec != "aac" or declaration.audio_profile != "lc":
            raise CorpusError(f"{declaration.identifier}: audio must be AAC-LC")
        if declaration.sample_rate_hz != 48000 or declaration.channels != 2:
            raise CorpusError(f"{declaration.identifier}: audio must be 48 kHz stereo")
        if declaration.channel_layout != "stereo":
            raise CorpusError(f"{declaration.identifier}: channel layout must be stereo")
        expected_recipe = (
            "h264-high" if declaration.codec == "h264" else f"hevc-{declaration.profile}"
        )
        expected_family = f"{expected_recipe}-1080p30"
        expected_identifier = f"native-{expected_recipe}-{declaration.container}"
        expected_path = f"{output_subdirectory}/{expected_recipe}.{declaration.container}"
        if declaration.identifier != expected_identifier or declaration.relative_path != expected_path:
            raise CorpusError(
                f"native matrix row must use id {expected_identifier!r} and path {expected_path!r}"
            )
        if declaration.video_payload_family != expected_family:
            raise CorpusError(
                f"{declaration.identifier}: video_payload_family must be {expected_family!r}"
            )
        if declaration.audio_payload_family != "aac-lc-48k-stereo":
            raise CorpusError(
                f"{declaration.identifier}: audio payload_identity_group must be 'aac-lc-48k-stereo'"
            )
        if declaration.video_recipe != expected_recipe:
            raise CorpusError(
                f"{declaration.identifier}: video_recipe must be {expected_recipe!r}"
            )
        expected_video_entry = "avc1" if declaration.codec == "h264" else "hvc1"
        expected_video_codec_id = (
            "V_MPEG4/ISO/AVC" if declaration.codec == "h264" else "V_MPEGH/ISO/HEVC"
        )
        if declaration.container in {"mp4", "mov"}:
            if (
                declaration.declared_video_sample_entry != expected_video_entry
                or declaration.declared_audio_sample_entry != "mp4a"
                or declaration.declared_video_codec_id is not None
                or declaration.declared_audio_codec_id is not None
            ):
                raise CorpusError(
                    f"{declaration.identifier}: ISO row must declare exact sample entries only"
                )
        else:
            if (
                declaration.declared_video_codec_id != expected_video_codec_id
                or declaration.declared_audio_codec_id != "A_AAC"
                or declaration.declared_video_sample_entry is not None
                or declaration.declared_audio_sample_entry is not None
            ):
                raise CorpusError(
                    f"{declaration.identifier}: Matroska row must declare exact CodecIDs only"
                )
        if declaration.duration_seconds < declaration.minimum_duration_seconds:
            raise CorpusError(
                f"{declaration.identifier}: declared duration is below the required duration"
            )
    return tuple(declarations)


def parse_intermediates(corpus: Mapping[str, Any]) -> tuple[Intermediate, ...]:
    native = _native_section(corpus)
    values = native.get("intermediates")
    if not isinstance(values, list):
        raise CorpusError("corpus.native_generated_corpus.intermediates must be an array")
    output_subdirectory = _required_string(
        native, "output_subdirectory", "corpus.native_generated_corpus"
    )
    recipes = _required_mapping(
        native, "recipes", "corpus.native_generated_corpus"
    )
    expected = {
        "_masters/h264-high.mp4": ("h264-high", "h264-high-1080p30"),
        "_masters/hevc-main.mp4": ("hevc-main", "hevc-main-1080p30"),
        "_masters/hevc-main10.mp4": ("hevc-main10", "hevc-main10-1080p30"),
        "_masters/aac-lc.aac": ("aac-lc", "aac-lc-48k-stereo"),
    }
    result: list[Intermediate] = []
    seen_ids: set[str] = set()
    seen_suffixes: set[str] = set()
    for index, value in enumerate(values):
        label = f"corpus.native_generated_corpus.intermediates[{index}]"
        if not isinstance(value, dict):
            raise CorpusError(f"{label} must be an object")
        identifier = _required_string(value, "id", label)
        kind = _required_string(value, "kind", label)
        if kind != "locally-generated-native-v1-intermediate":
            raise CorpusError(
                f"{label}.kind must equal 'locally-generated-native-v1-intermediate'"
            )
        relative_path = _required_string(value, "path", label)
        pure = PurePosixPath(relative_path)
        if (
            pure.is_absolute()
            or ".." in pure.parts
            or "." in pure.parts
            or str(pure) != relative_path
            or "\\" in relative_path
            or not pure.parts
            or pure.parts[0] != output_subdirectory
        ):
            raise CorpusError(f"{label}.path must be normalized inside output_subdirectory")
        suffix = str(PurePosixPath(*pure.parts[1:]))
        recipe = _required_string(value, "recipe", label)
        payload_identity_group = _required_string(
            value, "payload_identity_group", label
        )
        if suffix not in expected or expected[suffix] != (
            recipe,
            payload_identity_group,
        ):
            raise CorpusError(f"{label} is not one of the four exact master recipes")
        if recipe not in recipes:
            raise CorpusError(f"{label}.recipe is not declared")
        if identifier in seen_ids or suffix in seen_suffixes:
            raise CorpusError(f"duplicate native-v1 intermediate {identifier!r}")
        if identifier != f"master-{recipe}":
            raise CorpusError(f"{label}.id must equal 'master-{recipe}'")
        seen_ids.add(identifier)
        seen_suffixes.add(suffix)
        result.append(
            Intermediate(
                identifier,
                relative_path,
                kind,
                recipe,
                payload_identity_group,
            )
        )
    if seen_suffixes != set(expected) or len(result) != 4:
        raise CorpusError("native-v1 must declare exactly the four encoded masters")
    return tuple(result)


def parse_command_ledger(
    ledger: Mapping[str, Any],
    *,
    declared_outputs: Mapping[str, str],
    ffmpeg_canonical_path: Path,
    expected_argv: Mapping[str, Sequence[str]] | None = None,
) -> tuple[LedgerCommand, ...]:
    if ledger.get("schema") != LEDGER_SCHEMA:
        raise CorpusError(f"command ledger schema must equal {LEDGER_SCHEMA!r}")
    if ledger.get("path_placeholders") != MEDIA_ROOT_PLACEHOLDERS:
        raise CorpusError(
            "command ledger path_placeholders must contain the exact {{MEDIA_ROOT}} contract"
        )
    raw_commands = ledger.get("commands")
    if not isinstance(raw_commands, list):
        raise CorpusError("command ledger commands must be an array")
    commands: list[LedgerCommand] = []
    identifiers: set[str] = set()
    produced: set[str] = set()
    for index, raw in enumerate(raw_commands):
        label = f"command-ledger.commands[{index}]"
        if not isinstance(raw, dict) or set(raw) != {"id", "argv", "outputs"}:
            raise CorpusError(f"{label} must contain exactly id, argv, and outputs")
        identifier = _required_string(raw, "id", label)
        if identifier in identifiers:
            raise CorpusError(f"duplicate command ledger id {identifier!r}")
        identifiers.add(identifier)
        argv_value = raw.get("argv")
        outputs_value = raw.get("outputs")
        if (
            not isinstance(argv_value, list)
            or not argv_value
            or not all(isinstance(item, str) and item and "\x00" not in item for item in argv_value)
        ):
            raise CorpusError(f"{label}.argv must be a non-empty string array")
        first = Path(argv_value[0])
        if not first.is_absolute():
            raise CorpusError(f"{label}.argv[0] must be the canonical absolute ffmpeg path")
        try:
            command_tool = first.resolve(strict=True)
        except OSError as error:
            raise CorpusError(f"{label}.argv[0] cannot be resolved: {error}") from error
        if command_tool != ffmpeg_canonical_path:
            raise CorpusError(f"{label} was not produced by the captured ffmpeg tool")
        if (
            not isinstance(outputs_value, list)
            or not outputs_value
            or not all(isinstance(item, str) and item for item in outputs_value)
        ):
            raise CorpusError(f"{label}.outputs must be a non-empty string array")
        normalized_outputs: list[str] = []
        for output in outputs_value:
            pure = PurePosixPath(output)
            if (
                pure.is_absolute()
                or ".." in pure.parts
                or "." in pure.parts
                or str(pure) != output
                or "\\" in output
            ):
                raise CorpusError(f"{label}.outputs contains a non-normalized relative path")
            if output not in declared_outputs:
                raise CorpusError(f"{label} declares an output not present in the corpus: {output}")
            if output in produced:
                raise CorpusError(f"command ledger has two producers for {output}")
            produced.add(output)
            normalized_outputs.append(output)
        commands.append(LedgerCommand(identifier, tuple(argv_value), tuple(normalized_outputs)))
        if len(normalized_outputs) != 1:
            raise CorpusError(f"{label} must have exactly one declared output")
        output = normalized_outputs[0]
        if identifier != declared_outputs[output]:
            raise CorpusError(
                f"{label}.id must equal the declared producer {declared_outputs[output]!r}"
            )
        if expected_argv is not None:
            expected = tuple(expected_argv.get(identifier, ()))
            if not expected or tuple(argv_value) != expected:
                raise CorpusError(f"{label}.argv does not match the exact native-v1 recipe")
        expected_output_argument = f"{MEDIA_ROOT_PLACEHOLDER}/{output}"
        if argv_value[-1] != expected_output_argument:
            raise CorpusError(
                f"{label}.argv must end in exact placeholder output {expected_output_argument!r}"
            )
        for argument in argv_value:
            if MEDIA_ROOT_PLACEHOLDER in argument:
                if not argument.startswith(f"{MEDIA_ROOT_PLACEHOLDER}/"):
                    raise CorpusError(
                        f"{label}.argv uses the media-root placeholder in a non-path position"
                    )
                suffix = argument[len(MEDIA_ROOT_PLACEHOLDER) + 1 :]
                pure = PurePosixPath(suffix)
                if (
                    pure.is_absolute()
                    or ".." in pure.parts
                    or "." in pure.parts
                    or str(pure) != suffix
                    or suffix not in declared_outputs
                ):
                    raise CorpusError(
                        f"{label}.argv references an undeclared or non-normalized placeholder path"
                    )
            elif "{{" in argument or "}}" in argument:
                raise CorpusError(f"{label}.argv contains an undeclared placeholder")
    declared_paths = set(declared_outputs)
    if produced != declared_paths:
        missing = sorted(declared_paths - produced)
        extra = sorted(produced - declared_paths)
        raise CorpusError(
            f"command ledger must produce every declared file exactly once; missing={missing}, extra={extra}"
        )
    # The preparation contract currently has one encoding command per master
    # and one deterministic re-container command per final matrix row.
    if len(commands) != 13:
        raise CorpusError("command ledger must contain exactly thirteen ffmpeg commands")
    canonical_order = (
        "encode-h264-high",
        "encode-hevc-main",
        "encode-hevc-main10",
        "encode-aac-lc",
        "mux-h264-high-mp4",
        "mux-h264-high-mov",
        "mux-h264-high-mkv",
        "mux-hevc-main-mp4",
        "mux-hevc-main-mov",
        "mux-hevc-main-mkv",
        "mux-hevc-main10-mp4",
        "mux-hevc-main10-mov",
        "mux-hevc-main10-mkv",
    )
    if tuple(command.identifier for command in commands) != canonical_order:
        raise CorpusError("command ledger is not in the canonical native-v1 order")
    return tuple(commands)


def _expected_command_argv(
    native: Mapping[str, Any],
    ffmpeg: Path,
) -> Mapping[str, tuple[str, ...]]:
    """Reconstruct the 13 exact canonical argv arrays emitted by preparation."""

    video_filter = _required_string(
        native, "video_source_filter", "corpus.native_generated_corpus"
    )
    audio_filter = _required_string(
        native, "audio_source_filter", "corpus.native_generated_corpus"
    )
    tool = str(ffmpeg)

    common_video_output = (
        "-map",
        "0:v:0",
        "-an",
        "-frames:v",
        "2160",
        "-fps_mode",
        "cfr",
        "-color_range",
        "tv",
        "-color_primaries",
        "bt709",
        "-color_trc",
        "bt709",
        "-colorspace",
        "bt709",
        "-map_metadata",
        "-1",
        "-map_chapters",
        "-1",
        "-video_track_timescale",
        "30000",
        "-movflags",
        "+faststart",
        "-f",
        "mp4",
    )

    commands: dict[str, tuple[str, ...]] = {}
    video_specs = {
        "h264-high": (
            "libx264",
            "high",
            "yuv420p",
            "20",
            "-x264-params",
            "threads=1:sliced-threads=0:lookahead-threads=1:keyint=60:min-keyint=60:scenecut=0:open-gop=0:bframes=3:b-adapt=0:ref=3:repeat-headers=0:aud=0:nal-hrd=none:force-cfr=1",
            "avc1",
        ),
        "hevc-main": (
            "libx265",
            "main",
            "yuv420p",
            "22",
            "-x265-params",
            "pools=none:frame-threads=1:wpp=0:pmode=0:pme=0:keyint=60:min-keyint=60:scenecut=0:open-gop=0:bframes=4:b-adapt=0:ref=3:repeat-headers=0:aud=0:hrd=0",
            "hvc1",
        ),
        "hevc-main10": (
            "libx265",
            "main10",
            "yuv420p10le",
            "22",
            "-x265-params",
            "pools=none:frame-threads=1:wpp=0:pmode=0:pme=0:keyint=60:min-keyint=60:scenecut=0:open-gop=0:bframes=4:b-adapt=0:ref=3:repeat-headers=0:aud=0:hrd=0",
            "hvc1",
        ),
    }
    for recipe, (
        encoder,
        profile,
        pixel_format,
        crf,
        parameter_flag,
        parameter_value,
        tag,
    ) in video_specs.items():
        commands[f"encode-{recipe}"] = (
            tool,
            "-hide_banner",
            "-loglevel",
            "error",
            "-nostdin",
            "-y",
            "-filter_threads",
            "1",
            "-f",
            "lavfi",
            "-i",
            video_filter,
            "-fflags",
            "+bitexact",
            "-flags:v",
            "+bitexact",
            *common_video_output,
            "-c:v",
            encoder,
            "-preset",
            "veryfast",
            "-profile:v",
            profile,
            "-level:v",
            "4.0",
            "-pix_fmt",
            pixel_format,
            "-crf",
            crf,
            "-threads:v",
            "1",
            parameter_flag,
            parameter_value,
            "-tag:v",
            tag,
            f"{MEDIA_ROOT_PLACEHOLDER}/native-1080p-sdr-v1/_masters/{recipe}.mp4",
        )

    commands["encode-aac-lc"] = (
        tool,
        "-hide_banner",
        "-loglevel",
        "error",
        "-nostdin",
        "-y",
        "-filter_threads",
        "1",
        "-f",
        "lavfi",
        "-i",
        audio_filter,
        "-fflags",
        "+bitexact",
        "-flags:a",
        "+bitexact",
        "-map",
        "0:a:0",
        "-vn",
        "-c:a",
        "aac",
        "-profile:a",
        "aac_low",
        "-b:a",
        "128k",
        "-aac_coder",
        "twoloop",
        "-ar",
        "48000",
        "-ac",
        "2",
        "-threads:a",
        "1",
        "-map_metadata",
        "-1",
        "-map_chapters",
        "-1",
        "-f",
        "adts",
        f"{MEDIA_ROOT_PLACEHOLDER}/native-1080p-sdr-v1/_masters/aac-lc.aac",
    )

    for recipe, video_tag in (
        ("h264-high", "avc1"),
        ("hevc-main", "hvc1"),
        ("hevc-main10", "hvc1"),
    ):
        video_master = f"{MEDIA_ROOT_PLACEHOLDER}/native-1080p-sdr-v1/_masters/{recipe}.mp4"
        audio_master = f"{MEDIA_ROOT_PLACEHOLDER}/native-1080p-sdr-v1/_masters/aac-lc.aac"
        for container in ("mp4", "mov", "mkv"):
            base = (
                tool,
                "-hide_banner",
                "-loglevel",
                "error",
                "-nostdin",
                "-y",
                "-i",
                video_master,
                "-i",
                audio_master,
                "-fflags",
                "+bitexact",
                "-map",
                "0:v:0",
                "-map",
                "1:a:0",
                "-map_metadata",
                "-1",
                "-map_chapters",
                "-1",
                "-c",
                "copy",
                "-disposition:v:0",
                "default",
                "-disposition:a:0",
                "default",
            )
            if container == "mp4":
                suffix = (
                    "-tag:v",
                    video_tag,
                    "-tag:a",
                    "mp4a",
                    "-brand",
                    "isom",
                    "-video_track_timescale",
                    "30000",
                    "-movflags",
                    "+faststart",
                    "-f",
                    "mp4",
                )
            elif container == "mov":
                suffix = (
                    "-tag:v",
                    video_tag,
                    "-tag:a",
                    "mp4a",
                    "-brand",
                    "qt  ",
                    "-video_track_timescale",
                    "30000",
                    "-movflags",
                    "+faststart",
                    "-f",
                    "mov",
                )
            else:
                suffix = (
                    "-reserve_index_space",
                    "65536",
                    "-cues_to_front",
                    "1",
                    "-cluster_time_limit",
                    "1000",
                    "-write_crc32",
                    "0",
                    "-default_mode",
                    "passthrough",
                    "-f",
                    "matroska",
                )
            output = f"{MEDIA_ROOT_PLACEHOLDER}/native-1080p-sdr-v1/{recipe}.{container}"
            commands[f"mux-{recipe}-{container}"] = (*base, *suffix, output)
    return commands


def _read_exact(source: Any, offset: int, size: int, label: str) -> bytes:
    if size < 0:
        raise CorpusError(f"negative read size for {label}")
    source.seek(offset)
    value = source.read(size)
    if len(value) != size:
        raise CorpusError(f"truncated {label}")
    return value


def _iter_boxes(source: Any, start: int, end: int, label: str) -> Iterable[Box]:
    cursor = start
    while cursor < end:
        if end - cursor < 8:
            raise CorpusError(f"truncated ISO BMFF box header in {label}")
        header = _read_exact(source, cursor, 8, f"{label} box header")
        size32, kind = struct.unpack(">I4s", header)
        header_size = 8
        if size32 == 1:
            if end - cursor < 16:
                raise CorpusError(f"truncated extended ISO BMFF box header in {label}")
            size = struct.unpack(">Q", _read_exact(source, cursor + 8, 8, "box size"))[0]
            header_size = 16
            if size < 16:
                raise CorpusError(f"invalid extended ISO BMFF box size in {label}")
        elif size32 == 0:
            size = end - cursor
        else:
            size = size32
            if size < 8:
                raise CorpusError(f"invalid ISO BMFF box size in {label}")
        box_end = cursor + size
        if box_end > end or box_end <= cursor:
            raise CorpusError(f"ISO BMFF box escapes {label}")
        yield Box(kind=kind, start=cursor, payload_start=cursor + header_size, end=box_end)
        cursor = box_end
    if cursor != end:
        raise CorpusError(f"ISO BMFF boxes do not exactly fill {label}")


def _only_box(boxes: Iterable[Box], kind: bytes, label: str) -> Box:
    matches = [box for box in boxes if box.kind == kind]
    if len(matches) != 1:
        raise CorpusError(f"{label} must contain exactly one {kind.decode('latin1')} box")
    return matches[0]


def _parse_stsd(source: Any, box: Box, label: str) -> str:
    length = box.end - box.payload_start
    if length < 8 or length > MAX_SMALL_BOX_BYTES:
        raise CorpusError(f"{label} stsd has an invalid size")
    prefix = _read_exact(source, box.payload_start, 8, f"{label} stsd")
    if prefix[:4] != b"\0\0\0\0":
        raise CorpusError(f"{label} stsd must use version 0 and flags 0")
    entry_count = struct.unpack(">I", prefix[4:])[0]
    entries = list(_iter_boxes(source, box.payload_start + 8, box.end, f"{label} stsd"))
    if entry_count != 1 or len(entries) != 1:
        raise CorpusError(f"{label} stsd must contain exactly one sample entry")
    try:
        return entries[0].kind.decode("ascii", errors="strict")
    except UnicodeDecodeError as error:
        raise CorpusError(f"{label} sample entry is not ASCII") from error


def inspect_iso_bmff(
    path: Path,
    *,
    require_video: bool = True,
    require_audio: bool = True,
) -> Mapping[str, Any]:
    """Return independently parsed ISO BMFF brands and A/V sample entries."""

    try:
        file_size = path.stat().st_size
        with path.open("rb") as source:
            top = list(_iter_boxes(source, 0, file_size, "file"))
            ftyp = _only_box(top, b"ftyp", "file")
            moov = _only_box(top, b"moov", "file")
            ftyp_size = ftyp.end - ftyp.payload_start
            if ftyp_size < 8 or ftyp_size > 1024 or (ftyp_size - 8) % 4:
                raise CorpusError("ftyp has an invalid brand table")
            brand_bytes = _read_exact(source, ftyp.payload_start, ftyp_size, "ftyp")
            brands = [brand_bytes[:4]] + [
                brand_bytes[offset : offset + 4]
                for offset in range(8, len(brand_bytes), 4)
            ]

            moov_children = list(_iter_boxes(source, moov.payload_start, moov.end, "moov"))
            tracks: list[tuple[str, str]] = []
            for track_number, trak in enumerate(
                (box for box in moov_children if box.kind == b"trak"), start=1
            ):
                trak_children = list(
                    _iter_boxes(source, trak.payload_start, trak.end, f"trak[{track_number}]")
                )
                mdia = _only_box(trak_children, b"mdia", f"trak[{track_number}]")
                mdia_children = list(
                    _iter_boxes(source, mdia.payload_start, mdia.end, f"trak[{track_number}].mdia")
                )
                hdlr = _only_box(mdia_children, b"hdlr", f"trak[{track_number}].mdia")
                if hdlr.end - hdlr.payload_start < 12:
                    raise CorpusError("truncated hdlr")
                handler = _read_exact(source, hdlr.payload_start + 8, 4, "handler type")
                if handler not in {b"vide", b"soun"}:
                    continue
                minf = _only_box(mdia_children, b"minf", f"trak[{track_number}].mdia")
                minf_children = list(
                    _iter_boxes(source, minf.payload_start, minf.end, f"trak[{track_number}].minf")
                )
                stbl = _only_box(minf_children, b"stbl", f"trak[{track_number}].minf")
                stbl_children = list(
                    _iter_boxes(source, stbl.payload_start, stbl.end, f"trak[{track_number}].stbl")
                )
                stsd = _only_box(stbl_children, b"stsd", f"trak[{track_number}].stbl")
                tracks.append((handler.decode("ascii"), _parse_stsd(source, stsd, handler.decode("ascii"))))
    except CorpusError:
        raise
    except OSError as error:
        raise CorpusError(f"cannot inspect ISO BMFF asset {path}: {error}") from error

    videos = [entry for handler, entry in tracks if handler == "vide"]
    audios = [entry for handler, entry in tracks if handler == "soun"]
    expected_video_count = 1 if require_video else 0
    expected_audio_count = 1 if require_audio else 0
    if (
        len(videos) != expected_video_count
        or len(audios) != expected_audio_count
        or len(tracks) != expected_video_count + expected_audio_count
    ):
        raise CorpusError(
            "ISO BMFF asset does not contain the exact required video/audio track inventory"
        )
    return {
        "kind": "iso-bmff",
        "major_brand": brands[0].decode("latin1"),
        "compatible_brands": [brand.decode("latin1") for brand in brands[1:]],
        "video_sample_entry": videos[0] if videos else None,
        "audio_sample_entry": audios[0] if audios else None,
    }


def inspect_adts(path: Path) -> Mapping[str, Any]:
    """Parse every ADTS header and prove an exact AAC-LC 48 kHz stereo grid."""

    frames = 0
    cursor = 0
    try:
        file_size = path.stat().st_size
        with path.open("rb") as source:
            while cursor < file_size:
                header = _read_exact(source, cursor, 7, "ADTS header")
                if (
                    header[0] != 0xFF
                    or header[1] & 0xF6 != 0xF0
                    or header[1] & 0x08
                ):
                    raise CorpusError("ADTS syncword, MPEG-4 ID, or layer is invalid")
                protection_absent = header[1] & 1
                if protection_absent != 1:
                    raise CorpusError("ADTS master must use the recipe's CRC-absent headers")
                profile = (header[2] >> 6) & 0x03
                sample_rate_index = (header[2] >> 2) & 0x0F
                channel_configuration = ((header[2] & 1) << 2) | (header[3] >> 6)
                frame_length = (
                    ((header[3] & 0x03) << 11)
                    | (header[4] << 3)
                    | (header[5] >> 5)
                )
                raw_blocks = header[6] & 0x03
                header_size = 7 if protection_absent else 9
                if profile != 1:
                    raise CorpusError("ADTS master profile must be AAC-LC")
                if sample_rate_index != 3:
                    raise CorpusError("ADTS master sample rate must be 48 kHz")
                if channel_configuration != 2:
                    raise CorpusError("ADTS master channel configuration must be stereo")
                if raw_blocks != 0:
                    raise CorpusError("ADTS master must carry one raw data block per frame")
                if frame_length <= header_size or cursor + frame_length > file_size:
                    raise CorpusError("ADTS frame length is invalid")
                cursor += frame_length
                frames += 1
    except CorpusError:
        raise
    except OSError as error:
        raise CorpusError(f"cannot inspect ADTS asset {path}: {error}") from error
    if cursor != file_size or frames != AAC_LC_PACKET_COUNT:
        raise CorpusError(
            f"ADTS master must contain exactly {AAC_LC_PACKET_COUNT} complete frames"
        )
    return {
        "kind": "adts",
        "codec": "aac",
        "profile": "lc",
        "sample_rate_hz": AAC_LC_SAMPLE_RATE_HZ,
        "channels": 2,
        "frame_count": frames,
        "samples_per_frame": AAC_LC_SAMPLES_PER_PACKET,
        "grid_duration": "72/1",
    }


def _vint_length(first: int, maximum: int, label: str) -> int:
    mask = 0x80
    for length in range(1, maximum + 1):
        if first & mask:
            return length
        mask >>= 1
    raise CorpusError(f"invalid EBML {label} VINT")


def _read_ebml_element_header(source: Any, offset: int, end: int) -> tuple[int, int | None, int]:
    if offset >= end:
        raise CorpusError("truncated EBML element")
    first = _read_exact(source, offset, 1, "EBML ID")[0]
    id_length = _vint_length(first, 4, "ID")
    if offset + id_length >= end:
        raise CorpusError("truncated EBML element header")
    raw_id = _read_exact(source, offset, id_length, "EBML ID")
    element_id = int.from_bytes(raw_id, "big")
    size_first = _read_exact(source, offset + id_length, 1, "EBML size")[0]
    size_length = _vint_length(size_first, 8, "size")
    if offset + id_length + size_length > end:
        raise CorpusError("truncated EBML size")
    raw_size = _read_exact(source, offset + id_length, size_length, "EBML size")
    marker = 1 << (8 - size_length)
    size_value = raw_size[0] & (marker - 1)
    for octet in raw_size[1:]:
        size_value = (size_value << 8) | octet
    unknown = size_value == (1 << (7 * size_length)) - 1
    return element_id, None if unknown else size_value, id_length + size_length


def _iter_ebml_elements(source: Any, start: int, end: int, label: str) -> Iterable[tuple[int, int, int]]:
    cursor = start
    while cursor < end:
        element_id, size, header_size = _read_ebml_element_header(source, cursor, end)
        if size is None:
            raise CorpusError(f"unknown-sized EBML child is not allowed in {label}")
        payload_start = cursor + header_size
        element_end = payload_start + size
        if element_end > end or element_end < payload_start:
            raise CorpusError(f"EBML element escapes {label}")
        yield element_id, payload_start, element_end
        cursor = element_end
    if cursor != end:
        raise CorpusError(f"EBML elements do not exactly fill {label}")


def _decode_ebml_uint(source: Any, start: int, end: int, label: str) -> int:
    size = end - start
    if size < 1 or size > 8:
        raise CorpusError(f"{label} has an invalid integer width")
    return int.from_bytes(_read_exact(source, start, size, label), "big")


def inspect_matroska(path: Path) -> Mapping[str, Any]:
    """Return the exact EBML DocType and Matroska A/V TrackEntry CodecIDs."""

    try:
        file_size = path.stat().st_size
        with path.open("rb") as source:
            cursor = 0
            element_id, size, header_size = _read_ebml_element_header(source, cursor, file_size)
            if element_id != 0x1A45DFA3 or size is None:
                raise CorpusError("file does not start with a bounded EBML header")
            ebml_start = cursor + header_size
            ebml_end = ebml_start + size
            if ebml_end > file_size:
                raise CorpusError("EBML header escapes file")
            doctypes: list[str] = []
            for child_id, start, end in _iter_ebml_elements(source, ebml_start, ebml_end, "EBML header"):
                if child_id == 0x4282:
                    try:
                        doctypes.append(
                            _read_exact(source, start, end - start, "DocType").decode(
                                "ascii", errors="strict"
                            )
                        )
                    except UnicodeDecodeError as error:
                        raise CorpusError("EBML DocType is not ASCII") from error
            if doctypes != ["matroska"]:
                raise CorpusError("EBML DocType must occur once and equal 'matroska'")

            segment_offset = ebml_end
            segment_id, segment_size, segment_header = _read_ebml_element_header(
                source, segment_offset, file_size
            )
            if segment_id != 0x18538067:
                raise CorpusError("EBML header is not followed by a Segment")
            segment_start = segment_offset + segment_header
            segment_end = file_size if segment_size is None else segment_start + segment_size
            if segment_end > file_size:
                raise CorpusError("Matroska Segment escapes file")

            tracks_ranges: list[tuple[int, int]] = []
            scan = segment_start
            while scan < segment_end:
                child_id, child_size, child_header = _read_ebml_element_header(source, scan, segment_end)
                if child_size is None:
                    raise CorpusError("unknown-sized Segment child prevents exact Tracks parsing")
                child_start = scan + child_header
                child_end = child_start + child_size
                if child_end > segment_end or child_end < child_start:
                    raise CorpusError("Segment child escapes Segment")
                if child_id == 0x1654AE6B:
                    tracks_ranges.append((child_start, child_end))
                scan = child_end
            if len(tracks_ranges) != 1:
                raise CorpusError("Matroska Segment must contain exactly one Tracks element")

            track_entries: list[tuple[int, str]] = []
            for child_id, start, end in _iter_ebml_elements(
                source, tracks_ranges[0][0], tracks_ranges[0][1], "Tracks"
            ):
                if child_id != 0xAE:
                    continue
                track_types: list[int] = []
                codec_ids: list[str] = []
                for field_id, field_start, field_end in _iter_ebml_elements(
                    source, start, end, "TrackEntry"
                ):
                    if field_id == 0x83:
                        track_types.append(
                            _decode_ebml_uint(source, field_start, field_end, "TrackType")
                        )
                    elif field_id == 0x86:
                        try:
                            codec_ids.append(
                                _read_exact(
                                    source, field_start, field_end - field_start, "CodecID"
                                ).decode("ascii", errors="strict")
                            )
                        except UnicodeDecodeError as error:
                            raise CorpusError("TrackEntry CodecID is not ASCII") from error
                if len(track_types) != 1 or len(codec_ids) != 1:
                    raise CorpusError("each TrackEntry must contain one TrackType and CodecID")
                track_entries.append((track_types[0], codec_ids[0]))
    except CorpusError:
        raise
    except OSError as error:
        raise CorpusError(f"cannot inspect Matroska asset {path}: {error}") from error

    videos = [codec_id for track_type, codec_id in track_entries if track_type == 1]
    audios = [codec_id for track_type, codec_id in track_entries if track_type == 2]
    if len(videos) != 1 or len(audios) != 1 or len(track_entries) != 2:
        raise CorpusError("Matroska asset must contain exactly one video and one audio TrackEntry")
    return {
        "kind": "matroska",
        "doctype": "matroska",
        "video_codec_id": videos[0],
        "audio_codec_id": audios[0],
    }


def inspect_structure(path: Path, declaration: Declaration) -> Mapping[str, Any]:
    if declaration.container in {"mp4", "mov"}:
        result = inspect_iso_bmff(path)
        expected_video = "avc1" if declaration.codec == "h264" else "hvc1"
        if result["video_sample_entry"] != expected_video:
            raise CorpusError(
                f"{declaration.identifier}: ISO BMFF video sample entry must be {expected_video}"
            )
        if result["audio_sample_entry"] != "mp4a":
            raise CorpusError(
                f"{declaration.identifier}: ISO BMFF audio sample entry must be mp4a"
            )
        major = result["major_brand"]
        brands = {major, *result["compatible_brands"]}
        if declaration.container == "mov" and major != "qt  ":
            raise CorpusError(f"{declaration.identifier}: MOV major brand must be 'qt  '")
        if declaration.container == "mp4":
            if major == "qt  " or not brands.intersection({"isom", "iso2", "mp41", "mp42"}):
                raise CorpusError(
                    f"{declaration.identifier}: MP4 must carry an ISO/MP4 brand and not a QuickTime major brand"
                )
        return result

    if declaration.container == "mkv":
        result = inspect_matroska(path)
        expected_video = (
            "V_MPEG4/ISO/AVC" if declaration.codec == "h264" else "V_MPEGH/ISO/HEVC"
        )
        if result["video_codec_id"] != expected_video:
            raise CorpusError(
                f"{declaration.identifier}: Matroska video CodecID must be {expected_video}"
            )
        if result["audio_codec_id"] != "A_AAC":
            raise CorpusError(f"{declaration.identifier}: Matroska audio CodecID must be A_AAC")
        return result
    raise CorpusError(f"{declaration.identifier}: unsupported container {declaration.container}")


def _default_runner(argv: Sequence[str], timeout_s: float, max_output_bytes: int) -> CommandResult:
    if not argv or not all(isinstance(item, str) and item and "\x00" not in item for item in argv):
        raise CorpusError("command argv contains an invalid argument")
    try:
        completed = subprocess.run(
            list(argv),
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=timeout_s,
            check=False,
            shell=False,
            env={"LC_ALL": "C", "LANG": "C", "PATH": "/usr/bin:/bin"},
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise CorpusError(f"command failed to execute: {error}") from error
    if len(completed.stdout) > max_output_bytes or len(completed.stderr) > max_output_bytes:
        raise CorpusError("command output exceeds the validation bound")
    return CommandResult(completed.returncode, completed.stdout, completed.stderr)


def _resolve_tool(path: Path, label: str) -> Path:
    try:
        resolved = path.resolve(strict=True)
        mode = resolved.stat().st_mode
    except OSError as error:
        raise CorpusError(f"cannot resolve {label} tool {path}: {error}") from error
    if not stat.S_ISREG(mode) or not os.access(resolved, os.X_OK):
        raise CorpusError(f"{label} tool is not an executable regular file: {resolved}")
    return resolved


def capture_tool_identity(
    path: Path,
    label: str,
    runner: CommandRunner = _default_runner,
) -> tuple[Path, Mapping[str, Any]]:
    resolved = _resolve_tool(path, label)
    before = resolved.stat()
    size, sha256 = _sha256_file(resolved)
    result = runner((str(resolved), "-version"), DEFAULT_TIMEOUT_SECONDS, 1024 * 1024)
    after = resolved.stat()
    before_key = (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns)
    after_key = (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns)
    if before_key != after_key:
        raise CorpusError(f"{label} tool changed while its identity was captured")
    if result.returncode != 0:
        raise CorpusError(f"{label} -version failed with exit status {result.returncode}")
    if result.stderr:
        # ffmpeg-family builds normally put version text on stdout.  Preserve
        # stderr in the hash surface but reject diagnostics for determinism.
        raise CorpusError(f"{label} -version unexpectedly wrote to stderr")
    try:
        version = result.stdout.decode("utf-8", errors="strict")
    except UnicodeDecodeError as error:
        raise CorpusError(f"{label} version output is not UTF-8") from error
    version_lines = version.splitlines()
    if not version_lines or not version_lines[0]:
        raise CorpusError(f"{label} version output has no first line")
    return resolved, {
        "canonical_path": str(resolved),
        "bytes": size,
        "sha256": sha256,
        "version_first_line": version_lines[0],
        "version_output_sha256": _sha256_bytes(result.stdout),
    }


def _run_probe(
    ffprobe: Path,
    asset: Path,
    runner: CommandRunner,
) -> tuple[Mapping[str, Any], bytes, Mapping[str, Any], bytes, list[str], list[str]]:
    metadata_args = [
        str(ffprobe),
        "-v",
        "error",
        "-show_streams",
        "-show_format",
        "-show_entries",
        "stream=index,codec_type,codec_name,profile,codec_tag_string,width,height,pix_fmt,r_frame_rate,avg_frame_rate,field_order,sample_aspect_ratio,color_range,color_space,color_transfer,color_primaries,sample_rate,channels,channel_layout:format=format_name,nb_streams,duration",
        "-of",
        "json",
        str(asset),
    ]
    packet_args = [
        str(ffprobe),
        "-v",
        "error",
        "-show_packets",
        "-show_data_hash",
        "sha256",
        "-show_entries",
        "packet=stream_index,size,flags,data_hash",
        "-of",
        "json",
        str(asset),
    ]
    metadata_result = runner(metadata_args, DEFAULT_TIMEOUT_SECONDS, DEFAULT_MAX_PROBE_BYTES)
    if metadata_result.returncode != 0:
        raise CorpusError(f"ffprobe metadata failed for {asset.name}: {metadata_result.stderr!r}")
    if metadata_result.stderr:
        raise CorpusError(f"ffprobe metadata emitted diagnostics for {asset.name}")
    packet_result = runner(packet_args, DEFAULT_TIMEOUT_SECONDS, DEFAULT_MAX_PROBE_BYTES)
    if packet_result.returncode != 0:
        raise CorpusError(f"ffprobe packets failed for {asset.name}: {packet_result.stderr!r}")
    if packet_result.stderr:
        raise CorpusError(f"ffprobe packets emitted diagnostics for {asset.name}")
    metadata = _parse_json_bytes(metadata_result.stdout, f"ffprobe metadata for {asset.name}")
    packets = _parse_json_bytes(packet_result.stdout, f"ffprobe packets for {asset.name}")
    return metadata, metadata_result.stdout, packets, packet_result.stdout, metadata_args, packet_args


def _required_probe_string(value: Mapping[str, Any], key: str, label: str) -> str:
    item = value.get(key)
    if not isinstance(item, str) or not item:
        raise CorpusError(f"{label}.{key} must be a non-empty string")
    return item


def _probe_int(value: Mapping[str, Any], key: str, label: str) -> int:
    item = value.get(key)
    if isinstance(item, str) and item.isascii() and item.isdigit():
        item = int(item)
    if isinstance(item, bool) or not isinstance(item, int):
        raise CorpusError(f"{label}.{key} must be an integer")
    return item


def _reported(value: Any) -> bool:
    return isinstance(value, str) and value.lower() not in {"", "n/a", "unknown", "unspecified"}


def _validate_probe(
    metadata: Mapping[str, Any], declaration: Declaration
) -> tuple[Mapping[str, Any], int, int]:
    streams = metadata.get("streams")
    format_value = metadata.get("format")
    if not isinstance(streams, list) or not isinstance(format_value, dict):
        raise CorpusError(f"{declaration.identifier}: probe needs streams and format")
    if len(streams) != 2 or not all(isinstance(stream, dict) for stream in streams):
        raise CorpusError(f"{declaration.identifier}: probe must report exactly two streams")
    videos = [stream for stream in streams if stream.get("codec_type") == "video"]
    audios = [stream for stream in streams if stream.get("codec_type") == "audio"]
    if len(videos) != 1 or len(audios) != 1:
        raise CorpusError(f"{declaration.identifier}: probe must report one video and one audio stream")
    video, audio = videos[0], audios[0]
    video_index = _probe_int(video, "index", "video")
    audio_index = _probe_int(audio, "index", "audio")
    if video_index == audio_index:
        raise CorpusError(f"{declaration.identifier}: stream indexes collide")

    codec = _required_probe_string(video, "codec_name", "video").lower()
    profile = _normalized_profile(_required_probe_string(video, "profile", "video"))
    pixel_format = _required_probe_string(video, "pix_fmt", "video").lower()
    width = _probe_int(video, "width", "video")
    height = _probe_int(video, "height", "video")
    avg_fps = _fraction(_required_probe_string(video, "avg_frame_rate", "video"), "video.avg_frame_rate")
    real_fps = _fraction(_required_probe_string(video, "r_frame_rate", "video"), "video.r_frame_rate")
    if (codec, profile, pixel_format) != (
        declaration.codec,
        declaration.profile,
        declaration.pixel_format,
    ):
        raise CorpusError(f"{declaration.identifier}: probe video codec/profile/pixel format contradicts declaration")
    if width != 1920 or height != 1080 or width > 1920 or height > 1080:
        raise CorpusError(f"{declaration.identifier}: probe dimensions are not exact 1920x1080")
    if avg_fps != 30 or real_fps != 30:
        raise CorpusError(f"{declaration.identifier}: both reported frame rates must equal 30")
    if _required_probe_string(video, "field_order", "video").lower() != "progressive":
        raise CorpusError(f"{declaration.identifier}: video must be progressive")
    if _required_probe_string(video, "sample_aspect_ratio", "video") != "1:1":
        raise CorpusError(f"{declaration.identifier}: sample aspect ratio must be 1:1")

    expected_colors = {
        "color_range": {"tv", "limited"},
        "color_space": {"bt709"},
        "color_transfer": {"bt709"},
        "color_primaries": {"bt709"},
    }
    observed_colors: dict[str, str | None] = {}
    for key, allowed in expected_colors.items():
        raw = video.get(key)
        if _reported(raw):
            normalized = str(raw).lower()
            if normalized not in allowed:
                raise CorpusError(f"{declaration.identifier}: reported {key} is not BT.709/limited")
            observed_colors[key] = normalized
        else:
            observed_colors[key] = None

    audio_codec = _required_probe_string(audio, "codec_name", "audio").lower()
    audio_profile = _normalized_profile(_required_probe_string(audio, "profile", "audio"))
    sample_rate = _probe_int(audio, "sample_rate", "audio")
    channels = _probe_int(audio, "channels", "audio")
    layout = _required_probe_string(audio, "channel_layout", "audio").lower()
    if (audio_codec, audio_profile, sample_rate, channels, layout) != (
        "aac",
        "lc",
        48000,
        2,
        "stereo",
    ):
        raise CorpusError(f"{declaration.identifier}: probe audio is not exact AAC-LC 48 kHz stereo")

    duration = _fraction(format_value.get("duration"), "format.duration")
    if duration < declaration.minimum_duration_seconds:
        raise CorpusError(f"{declaration.identifier}: asset is shorter than required")
    if abs(duration - declaration.duration_seconds) > declaration.duration_tolerance_seconds:
        raise CorpusError(f"{declaration.identifier}: asset duration is outside declared tolerance")
    format_name = _required_probe_string(format_value, "format_name", "format").lower()
    names = {part.strip() for part in format_name.split(",")}
    if declaration.container in {"mp4", "mov"} and not names.intersection(
        {"mov", "mp4", "m4a", "3gp", "3g2", "mj2"}
    ):
        raise CorpusError(f"{declaration.identifier}: probe container contradicts ISO BMFF")
    if declaration.container == "mkv" and "matroska" not in names:
        raise CorpusError(f"{declaration.identifier}: probe container contradicts Matroska")

    return {
        "video": {
            "stream_index": video_index,
            "codec": codec,
            "profile": profile,
            "pixel_format": pixel_format,
            "width": width,
            "height": height,
            "avg_frame_rate": f"{avg_fps.numerator}/{avg_fps.denominator}",
            "real_frame_rate": f"{real_fps.numerator}/{real_fps.denominator}",
            "field_order": "progressive",
            "sample_aspect_ratio": "1:1",
            **observed_colors,
        },
        "audio": {
            "stream_index": audio_index,
            "codec": audio_codec,
            "profile": audio_profile,
            "sample_rate_hz": sample_rate,
            "channels": channels,
            "channel_layout": layout,
        },
        "duration": f"{duration.numerator}/{duration.denominator}",
        "format_name": format_name,
    }, video_index, audio_index


def _validate_intermediate_probe(
    metadata: Mapping[str, Any], intermediate: Intermediate
) -> tuple[Mapping[str, Any], int | None, int | None]:
    streams = metadata.get("streams")
    format_value = metadata.get("format")
    if (
        not isinstance(streams, list)
        or len(streams) != 1
        or not isinstance(streams[0], dict)
        or not isinstance(format_value, dict)
    ):
        raise CorpusError(
            f"{intermediate.identifier}: master probe must report exactly one stream and format"
        )
    stream = streams[0]
    stream_index = _probe_int(stream, "index", "master stream")

    if intermediate.recipe == "aac-lc":
        observed = {
            "stream_index": stream_index,
            "codec": _required_probe_string(stream, "codec_name", "master audio").lower(),
            "profile": _normalized_profile(
                _required_probe_string(stream, "profile", "master audio")
            ),
            "sample_rate_hz": _probe_int(stream, "sample_rate", "master audio"),
            "channels": _probe_int(stream, "channels", "master audio"),
            "channel_layout": _required_probe_string(
                stream, "channel_layout", "master audio"
            ).lower(),
        }
        if tuple(observed[key] for key in ("codec", "profile", "sample_rate_hz", "channels", "channel_layout")) != (
            "aac",
            "lc",
            AAC_LC_SAMPLE_RATE_HZ,
            2,
            "stereo",
        ):
            raise CorpusError(f"{intermediate.identifier}: audio master is not exact AAC-LC 48 kHz stereo")
        # Raw ADTS has no container duration.  ffprobe estimates it from byte
        # rate and may report ~75.29 s for this exact 72 s access-unit grid.
        # Duration authority is the independently parsed 3375*1024/48000 grid.
        return {"audio": observed, "duration": "72/1"}, None, stream_index

    duration = _fraction(format_value.get("duration"), "master format.duration")
    if duration < Fraction(719, 10) or duration > Fraction(721, 10):
        raise CorpusError(f"{intermediate.identifier}: master duration is outside 71.9..72.1 seconds")
    expected = {
        "h264-high": ("h264", "high", "yuv420p"),
        "hevc-main": ("hevc", "main", "yuv420p"),
        "hevc-main10": ("hevc", "main10", "yuv420p10le"),
    }[intermediate.recipe]
    avg_fps = _fraction(
        _required_probe_string(stream, "avg_frame_rate", "master video"),
        "master video.avg_frame_rate",
    )
    real_fps = _fraction(
        _required_probe_string(stream, "r_frame_rate", "master video"),
        "master video.r_frame_rate",
    )
    observed_video: dict[str, Any] = {
        "stream_index": stream_index,
        "codec": _required_probe_string(stream, "codec_name", "master video").lower(),
        "profile": _normalized_profile(
            _required_probe_string(stream, "profile", "master video")
        ),
        "pixel_format": _required_probe_string(
            stream, "pix_fmt", "master video"
        ).lower(),
        "width": _probe_int(stream, "width", "master video"),
        "height": _probe_int(stream, "height", "master video"),
        "avg_frame_rate": f"{avg_fps.numerator}/{avg_fps.denominator}",
        "real_frame_rate": f"{real_fps.numerator}/{real_fps.denominator}",
        "field_order": _required_probe_string(
            stream, "field_order", "master video"
        ).lower(),
        "sample_aspect_ratio": _required_probe_string(
            stream, "sample_aspect_ratio", "master video"
        ),
    }
    if tuple(observed_video[key] for key in ("codec", "profile", "pixel_format")) != expected:
        raise CorpusError(f"{intermediate.identifier}: video master codec facts contradict its recipe")
    if (
        observed_video["width"] != 1920
        or observed_video["height"] != 1080
        or avg_fps != 30
        or real_fps != 30
        or observed_video["field_order"] != "progressive"
        or observed_video["sample_aspect_ratio"] != "1:1"
    ):
        raise CorpusError(f"{intermediate.identifier}: video master geometry/timing is invalid")
    for key, allowed in {
        "color_range": {"tv", "limited"},
        "color_space": {"bt709"},
        "color_transfer": {"bt709"},
        "color_primaries": {"bt709"},
    }.items():
        raw = stream.get(key)
        if _reported(raw):
            normalized = str(raw).lower()
            if normalized not in allowed:
                raise CorpusError(f"{intermediate.identifier}: master {key} is invalid")
            observed_video[key] = normalized
        else:
            observed_video[key] = None
    return {
        "video": observed_video,
        "duration": f"{duration.numerator}/{duration.denominator}",
    }, stream_index, None


def _packet_sequence(
    packet_document: Mapping[str, Any],
    video_index: int | None,
    audio_index: int | None,
    label: str,
) -> Mapping[str, Mapping[str, Any]]:
    packets = packet_document.get("packets")
    if not isinstance(packets, list):
        raise CorpusError(f"{label}: packet probe must contain a packets array")
    if video_index is None and audio_index is None:
        raise CorpusError(f"{label}: no stream was selected for packet validation")
    indexes = [index for index in (video_index, audio_index) if index is not None]
    if len(indexes) != len(set(indexes)):
        raise CorpusError(f"{label}: packet stream indexes collide")
    sequences: dict[int, list[tuple[str, int, str]]] = {
        index: [] for index in indexes
    }
    for index, packet in enumerate(packets):
        if not isinstance(packet, dict):
            raise CorpusError(f"{label}: packet[{index}] must be an object")
        stream_index = _probe_int(packet, "stream_index", f"packet[{index}]")
        if stream_index not in sequences:
            raise CorpusError(f"{label}: packet belongs to an undeclared stream")
        packet_size = _probe_int(packet, "size", f"packet[{index}]")
        if packet_size <= 0:
            raise CorpusError(f"{label}: packet size must be positive")
        flags = _required_probe_string(packet, "flags", f"packet[{index}]")
        if len(flags) > 16 or not flags.isascii():
            raise CorpusError(f"{label}: packet flags are malformed")
        data_hash = _required_probe_string(packet, "data_hash", f"packet[{index}]")
        prefix = "SHA256:"
        if not data_hash.startswith(prefix):
            raise CorpusError(f"{label}: packet hash must use SHA256")
        value = data_hash[len(prefix) :]
        if len(value) != 64 or any(character not in "0123456789abcdef" for character in value):
            raise CorpusError(f"{label}: packet hash is not lowercase SHA-256")
        sequences[stream_index].append((value, packet_size, flags))

    result: dict[str, Mapping[str, Any]] = {}
    for kind, stream_index in (("video", video_index), ("audio", audio_index)):
        if stream_index is None:
            continue
        values = sequences[stream_index]
        if not values:
            raise CorpusError(f"{label}: {kind} packet sequence is empty")
        packet_hashes = [value[0] for value in values]
        packet_sizes = [value[1] for value in values]
        keyframe_ordinals = [
            ordinal for ordinal, value in enumerate(values) if "K" in value[2]
        ]
        expected_count = VIDEO_PACKET_COUNT if kind == "video" else AAC_LC_PACKET_COUNT
        maximum_size = MAX_VIDEO_PACKET_BYTES if kind == "video" else MAX_AUDIO_PACKET_BYTES
        if len(values) != expected_count:
            raise CorpusError(
                f"{label}: {kind} packet count must be exactly {expected_count}"
            )
        if max(packet_sizes) > maximum_size:
            raise CorpusError(
                f"{label}: {kind} packet exceeds the {maximum_size}-byte bound"
            )
        if kind == "video" and keyframe_ordinals != list(VIDEO_KEYFRAME_ORDINALS):
            raise CorpusError(
                f"{label}: video keyframes must occur exactly every 60 packets"
            )
        digest = hashlib.sha256()
        digest.update(b"wam-packet-sequence-v1\0")
        digest.update(kind.encode("ascii") + b"\0")
        digest.update(struct.pack(">Q", len(packet_hashes)))
        for value in packet_hashes:
            digest.update(bytes.fromhex(value))
        result[kind] = {
            "packet_count": len(packet_hashes),
            "maximum_packet_bytes": max(packet_sizes),
            "keyframe_ordinals": keyframe_ordinals if kind == "video" else None,
            "sequence_sha256": digest.hexdigest(),
        }
    return result


def _asset_path(media_dir: Path, relative_path: str) -> Path:
    try:
        root = media_dir.resolve(strict=True)
    except OSError as error:
        raise CorpusError(f"cannot resolve media directory {media_dir}: {error}") from error
    candidate = root.joinpath(*PurePosixPath(relative_path).parts)
    try:
        if stat.S_ISLNK(candidate.lstat().st_mode):
            raise CorpusError(f"asset path must not be a symbolic link: {candidate}")
        resolved = candidate.resolve(strict=True)
        mode = resolved.stat().st_mode
    except OSError as error:
        raise CorpusError(f"cannot resolve asset {candidate}: {error}") from error
    try:
        if os.path.commonpath((str(root), str(resolved))) != str(root):
            raise CorpusError(f"asset escapes media directory: {candidate}")
    except ValueError as error:
        raise CorpusError(f"asset escapes media directory: {candidate}") from error
    if not stat.S_ISREG(mode):
        raise CorpusError(f"asset is not a regular file: {candidate}")
    return resolved


def _validate_output_inventory(
    media_root: Path,
    native: Mapping[str, Any],
    declarations: Sequence[Declaration],
    intermediates: Sequence[Intermediate],
) -> None:
    output_subdirectory = _required_string(
        native, "output_subdirectory", "corpus.native_generated_corpus"
    )
    root = media_root.joinpath(*PurePosixPath(output_subdirectory).parts)
    try:
        if stat.S_ISLNK(root.lstat().st_mode) or not root.is_dir():
            raise CorpusError("native-v1 output root must be a real directory")
    except OSError as error:
        raise CorpusError(f"cannot inspect native-v1 output root: {error}") from error

    expected_files = {
        PurePosixPath(declaration.relative_path).relative_to(output_subdirectory)
        for declaration in declarations
    }
    expected_files.update(
        PurePosixPath(intermediate.relative_path).relative_to(output_subdirectory)
        for intermediate in intermediates
    )
    for field in ("command_ledger", "runtime_receipt"):
        expected_files.add(
            PurePosixPath(
                _required_string(native, field, "corpus.native_generated_corpus")
            ).relative_to(output_subdirectory)
        )
    manifest_relative = PurePosixPath(
        _required_string(
            native, "preparation_manifest", "corpus.native_generated_corpus"
        )
    ).relative_to(output_subdirectory)

    observed_files: set[PurePosixPath] = set()
    try:
        root_entries = list(root.iterdir())
    except OSError as error:
        raise CorpusError(f"cannot enumerate native-v1 output root: {error}") from error
    for entry in root_entries:
        relative = PurePosixPath(entry.name)
        try:
            mode = entry.lstat().st_mode
        except OSError as error:
            raise CorpusError(f"cannot inspect native-v1 output entry: {error}") from error
        if stat.S_ISLNK(mode):
            raise CorpusError(f"native-v1 output contains a symbolic link: {relative}")
        if stat.S_ISDIR(mode):
            if entry.name != "_masters":
                raise CorpusError(f"native-v1 output contains an undeclared directory: {relative}")
            for child in entry.iterdir():
                child_relative = PurePosixPath("_masters", child.name)
                child_mode = child.lstat().st_mode
                if not stat.S_ISREG(child_mode):
                    raise CorpusError(
                        f"native-v1 masters contains a symlink or special entry: {child_relative}"
                    )
                observed_files.add(child_relative)
        elif stat.S_ISREG(mode):
            observed_files.add(relative)
        else:
            raise CorpusError(f"native-v1 output contains a special entry: {relative}")
    if manifest_relative in observed_files:
        observed_files.remove(manifest_relative)
    if observed_files != expected_files:
        missing = sorted(str(value) for value in expected_files - observed_files)
        extra = sorted(str(value) for value in observed_files - expected_files)
        raise CorpusError(
            f"native-v1 output inventory differs from its declaration; missing={missing}, extra={extra}"
        )


def _contained_path(root: Path, path: Path, label: str, *, must_exist: bool) -> Path:
    try:
        resolved_root = root.resolve(strict=True)
        resolved = path.resolve(strict=must_exist)
    except OSError as error:
        raise CorpusError(f"cannot resolve {label}: {error}") from error
    try:
        contained = os.path.commonpath((str(resolved_root), str(resolved))) == str(
            resolved_root
        )
    except ValueError:
        contained = False
    if not contained or resolved == resolved_root:
        raise CorpusError(f"{label} must be inside the media root")
    return resolved


def declared_manifest_path(corpus_path: Path, media_root: Path) -> Path:
    corpus, _ = _load_json(corpus_path.resolve(strict=True), "corpus")
    native = _native_section(corpus)
    relative = _required_string(
        native, "preparation_manifest", "corpus.native_generated_corpus"
    )
    return _contained_path(
        media_root,
        media_root.joinpath(*PurePosixPath(relative).parts),
        "preparation manifest",
        must_exist=False,
    )


def _preparation_script(corpus_path: Path, corpus: Mapping[str, Any]) -> Path:
    del corpus  # The recipe script is deliberately not caller-selectable.
    path = corpus_path.parent / "prepare_corpus.zsh"
    try:
        resolved = path.resolve(strict=True)
    except OSError as error:
        raise CorpusError(f"cannot resolve preparation script {path}: {error}") from error
    if not resolved.is_file():
        raise CorpusError("preparation script is not a regular file")
    return resolved


def _resolve_recipe_script(corpus_path: Path, recipe_script_path: Path | None) -> Path:
    expected = _preparation_script(corpus_path, {})
    if recipe_script_path is None:
        return expected
    try:
        supplied = recipe_script_path.resolve(strict=True)
    except OSError as error:
        raise CorpusError(f"cannot resolve --recipe-script: {error}") from error
    if supplied != expected:
        raise CorpusError("--recipe-script must identify benchmarks/prepare_corpus.zsh")
    return supplied


def build_preparation_manifest(
    corpus_path: Path,
    media_dir: Path,
    *,
    command_ledger_path: Path,
    runtime_receipt_path: Path,
    recipe_script_path: Path | None = None,
    ffprobe_path: Path,
    ffmpeg_path: Path,
    runner: CommandRunner = _default_runner,
) -> Mapping[str, Any]:
    corpus_path = corpus_path.resolve(strict=True)
    corpus, corpus_raw = _load_json(corpus_path, "corpus")
    declarations = parse_declarations(corpus)
    intermediates = parse_intermediates(corpus)
    native = _native_section(corpus)
    corpus_id = _required_string(
        native, "id", "corpus.native_generated_corpus"
    )
    recipes = _required_mapping(
        native, "recipes", "corpus.native_generated_corpus"
    )
    preparation_script = _resolve_recipe_script(corpus_path, recipe_script_path)
    script_size, script_sha = _sha256_file(preparation_script)
    ffprobe, ffprobe_identity = capture_tool_identity(ffprobe_path, "ffprobe", runner)
    ffmpeg, ffmpeg_identity = capture_tool_identity(ffmpeg_path, "ffmpeg", runner)
    declared_ledger_relative = _required_string(
        native, "command_ledger", "corpus.native_generated_corpus"
    )
    declared_ledger_pure = PurePosixPath(declared_ledger_relative)
    if (
        declared_ledger_pure.is_absolute()
        or ".." in declared_ledger_pure.parts
        or "." in declared_ledger_pure.parts
        or str(declared_ledger_pure) != declared_ledger_relative
    ):
        raise CorpusError("native command_ledger must be a normalized relative path")
    expected_ledger_path = _contained_path(
        media_dir,
        media_dir.joinpath(*declared_ledger_pure.parts),
        "command ledger",
        must_exist=True,
    )
    ledger_path = _contained_path(
        media_dir, command_ledger_path, "command ledger", must_exist=True
    )
    if ledger_path != expected_ledger_path:
        raise CorpusError("--command-ledger contradicts native_generated_corpus.command_ledger")
    ledger, ledger_raw = _load_json(ledger_path, "command ledger")
    declared_outputs = {
        declaration.relative_path: declaration.identifier.replace("native-", "mux-", 1)
        for declaration in declarations
    }
    declared_outputs.update(
        {
            intermediate.relative_path: f"encode-{intermediate.recipe}"
            for intermediate in intermediates
        }
    )
    ledger_commands = parse_command_ledger(
        ledger,
        declared_outputs=declared_outputs,
        ffmpeg_canonical_path=ffmpeg,
        expected_argv=_expected_command_argv(native, ffmpeg),
    )
    runtime_path = _contained_path(
        media_dir, runtime_receipt_path, "runtime receipt", must_exist=True
    )
    declared_runtime_relative = _required_string(
        native, "runtime_receipt", "corpus.native_generated_corpus"
    )
    expected_runtime_path = _contained_path(
        media_dir,
        media_dir.joinpath(*PurePosixPath(declared_runtime_relative).parts),
        "runtime receipt",
        must_exist=True,
    )
    if runtime_path != expected_runtime_path:
        raise CorpusError("runtime receipt path contradicts the corpus declaration")
    runtime_receipt, runtime_raw = validate_runtime_receipt(
        runtime_path,
        corpus_path,
        ffmpeg_path=ffmpeg,
        ffprobe_path=ffprobe,
        recipe_script_path=recipe_script_path,
    )
    commands_by_output = {
        output: command
        for command in ledger_commands
        for output in command.outputs
    }

    intermediate_files: dict[str, Mapping[str, Any]] = {}
    for intermediate in intermediates:
        asset = _asset_path(media_dir, intermediate.relative_path)
        before = asset.stat()
        size, sha = _sha256_file(asset)
        command = commands_by_output[intermediate.relative_path]
        if intermediate.recipe == "aac-lc":
            structure = inspect_adts(asset)
        else:
            structure = inspect_iso_bmff(
                asset, require_video=True, require_audio=False
            )
            expected_entry = "avc1" if intermediate.recipe == "h264-high" else "hvc1"
            if structure["video_sample_entry"] != expected_entry:
                raise CorpusError(
                    f"{intermediate.identifier}: video master sample entry must be {expected_entry}"
                )
        metadata, metadata_raw, packets, packets_raw, metadata_argv, packet_argv = _run_probe(
            ffprobe, asset, runner
        )
        observed, video_index, audio_index = _validate_intermediate_probe(
            metadata, intermediate
        )
        payloads = _packet_sequence(
            packets,
            video_index,
            audio_index,
            intermediate.identifier,
        )
        after_size, after_sha = _sha256_file(asset)
        after = asset.stat()
        before_key = (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns)
        after_key = (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns)
        if before_key != after_key or (size, sha) != (after_size, after_sha):
            raise CorpusError(f"{intermediate.identifier}: master changed during validation")
        intermediate_files[intermediate.identifier] = {
            "kind": intermediate.kind,
            "path": intermediate.relative_path,
            "recipe": intermediate.recipe,
            "payload_identity_group": intermediate.payload_identity_group,
            "recipe_sha256": _sha256_bytes(
                _canonical_json_bytes(recipes[intermediate.recipe])
            ),
            "producer_command_id": command.identifier,
            "producer_argv_sha256": _sha256_bytes(
                _canonical_json_bytes(list(command.argv))
            ),
            "bytes": size,
            "sha256": sha,
            "structure": structure,
            "ffprobe_argv": [*metadata_argv[:-1], intermediate.relative_path],
            "raw_ffprobe_json": metadata_raw.decode("utf-8"),
            "raw_ffprobe_sha256": _sha256_bytes(metadata_raw),
            "packet_ffprobe_argv": [*packet_argv[:-1], intermediate.relative_path],
            "raw_packet_ffprobe_json": packets_raw.decode("utf-8"),
            "raw_packet_ffprobe_sha256": _sha256_bytes(packets_raw),
            "streams": observed,
            "packet_payloads": payloads,
        }

    files: dict[str, Mapping[str, Any]] = {}
    for declaration in declarations:
        asset = _asset_path(media_dir, declaration.relative_path)
        before = asset.stat()
        file_size, file_sha = _sha256_file(asset)
        structure = inspect_structure(asset, declaration)
        metadata, metadata_raw, packets, packets_raw, metadata_argv, packet_argv = _run_probe(
            ffprobe, asset, runner
        )
        observed, video_index, audio_index = _validate_probe(metadata, declaration)
        payloads = _packet_sequence(packets, video_index, audio_index, declaration.identifier)
        after_size, after_sha = _sha256_file(asset)
        after = asset.stat()
        before_key = (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns)
        after_key = (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns)
        if before_key != after_key or (file_size, file_sha) != (after_size, after_sha):
            raise CorpusError(f"{declaration.identifier}: asset changed during validation")
        command = commands_by_output[declaration.relative_path]
        video_recipe_sha = _sha256_bytes(
            _canonical_json_bytes(recipes[declaration.video_recipe])
        )
        audio_recipe_sha = _sha256_bytes(
            _canonical_json_bytes(recipes[declaration.audio_recipe])
        )
        files[declaration.identifier] = {
                "path": declaration.relative_path,
                "matrix": {
                    "codec": declaration.codec,
                    "profile": declaration.profile,
                    "container": declaration.container,
                },
                "video_payload_family": declaration.video_payload_family,
                "audio_payload_family": declaration.audio_payload_family,
                "video_recipe": declaration.video_recipe,
                "video_recipe_sha256": video_recipe_sha,
                "audio_recipe": declaration.audio_recipe,
                "audio_recipe_sha256": audio_recipe_sha,
                "producer_command_id": command.identifier,
                "producer_argv_sha256": _sha256_bytes(
                    _canonical_json_bytes(list(command.argv))
                ),
                "bytes": file_size,
                "sha256": file_sha,
                "structure": structure,
                "ffprobe_argv": [*metadata_argv[:-1], declaration.relative_path],
                "raw_ffprobe_json": metadata_raw.decode("utf-8"),
                "raw_ffprobe_sha256": _sha256_bytes(metadata_raw),
                "packet_ffprobe_argv": [*packet_argv[:-1], declaration.relative_path],
                "raw_packet_ffprobe_json": packets_raw.decode("utf-8"),
                "raw_packet_ffprobe_sha256": _sha256_bytes(packets_raw),
                "streams": observed,
                "packet_payloads": payloads,
        }

    video_groups: dict[str, list[Mapping[str, Any]]] = {}
    audio_entries: list[Mapping[str, Any]] = []
    for identifier, entry in intermediate_files.items():
        entry_with_id = {**entry, "id": identifier}
        if "video" in entry["packet_payloads"]:
            video_groups.setdefault(
                str(entry["payload_identity_group"]), []
            ).append(entry_with_id)
        if "audio" in entry["packet_payloads"]:
            audio_entries.append(entry_with_id)
    for identifier, entry in files.items():
        entry_with_id = {**entry, "id": identifier}
        video_groups.setdefault(str(entry["video_payload_family"]), []).append(entry_with_id)
        audio_entries.append(entry_with_id)
    equivalence_video: list[Mapping[str, Any]] = []
    for family, members in sorted(video_groups.items()):
        if len(members) != 4:
            raise CorpusError(
                f"video payload family {family!r} must contain one master and three containers"
            )
        signatures = {
            (
                member["packet_payloads"]["video"]["packet_count"],
                member["packet_payloads"]["video"]["sequence_sha256"],
            )
            for member in members
        }
        if len(signatures) != 1:
            raise CorpusError(f"video packet payloads differ within family {family!r}")
        packet_count, sequence_sha = signatures.pop()
        equivalence_video.append(
            {
                "family": family,
                "members": sorted(str(member["id"]) for member in members),
                "packet_count": packet_count,
                "sequence_sha256": sequence_sha,
            }
        )
    audio_signatures = {
        (
            entry["packet_payloads"]["audio"]["packet_count"],
            entry["packet_payloads"]["audio"]["sequence_sha256"],
        )
        for entry in audio_entries
    }
    if len(audio_signatures) != 1:
        raise CorpusError("audio packet payloads differ across native-v1 assets")
    if len(audio_entries) != 10:
        raise CorpusError("audio payload group must contain one master and all nine final assets")
    audio_count, audio_sha = audio_signatures.pop()
    if audio_count != AAC_LC_PACKET_COUNT:
        raise CorpusError(
            f"AAC-LC payload sequence must contain exactly {AAC_LC_PACKET_COUNT} packets"
        )
    audio_grid_duration = Fraction(
        audio_count * AAC_LC_SAMPLES_PER_PACKET,
        AAC_LC_SAMPLE_RATE_HZ,
    )
    if audio_grid_duration != 72:
        raise CorpusError("AAC-LC packet grid duration must equal exactly 72 seconds")

    _validate_output_inventory(media_dir, native, declarations, intermediates)

    return {
        "schema": MANIFEST_SCHEMA,
        "corpus": {
            "id": corpus_id,
            "path": str(corpus_path),
            "sha256": _sha256_bytes(corpus_raw),
        },
        "recipe": {
            "script_path": str(preparation_script),
            "script_sha256": script_sha,
            "script_bytes": script_size,
            "declarations_sha256": _sha256_bytes(_canonical_json_bytes(recipes)),
            "command_ledger_path": _required_string(
                native, "command_ledger", "corpus.native_generated_corpus"
            ),
            "command_ledger_sha256": _sha256_bytes(ledger_raw),
            "runtime_receipt_path": str(
                PurePosixPath(*runtime_path.relative_to(media_dir.resolve()).parts)
            ),
            "runtime_receipt_sha256": _sha256_bytes(runtime_raw),
        },
        "tools": {"ffmpeg": ffmpeg_identity, "ffprobe": ffprobe_identity},
        "runtime": runtime_receipt,
        "commands": [
            {
                "id": command.identifier,
                "argv": list(command.argv),
                "argv_sha256": _sha256_bytes(
                    _canonical_json_bytes(list(command.argv))
                ),
                "outputs": list(command.outputs),
            }
            for command in ledger_commands
        ],
        "intermediates": intermediate_files,
        "files": files,
        "payload_equivalence": {
            "video_families": equivalence_video,
            "audio": {
                "members": sorted(str(entry["id"]) for entry in audio_entries),
                "packet_count": audio_count,
                "samples_per_packet": AAC_LC_SAMPLES_PER_PACKET,
                "sample_rate_hz": AAC_LC_SAMPLE_RATE_HZ,
                "grid_duration": (
                    f"{audio_grid_duration.numerator}/{audio_grid_duration.denominator}"
                ),
                "sequence_sha256": audio_sha,
            },
        },
    }


def _repository_root(path: Path) -> Path | None:
    for candidate in (path, *path.parents):
        if (candidate / ".git").exists():
            return candidate
    return None


def _require_ignored_manifest(path: Path, corpus_path: Path) -> None:
    repository = _repository_root(corpus_path.resolve())
    if repository is None:
        raise CorpusError("cannot prove preparation manifest is Git-ignored")
    absolute = path.absolute()
    try:
        relative = absolute.relative_to(repository)
    except ValueError:
        # An external media root is outside the repository's tracking surface.
        # It is therefore inherently uncommittable by this repository.
        return
    result = subprocess.run(
        ["git", "-C", str(repository), "check-ignore", "--quiet", "--no-index", "--", str(relative)],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
        check=False,
        shell=False,
    )
    if result.returncode != 0:
        raise CorpusError(f"preparation manifest path is not Git-ignored: {absolute}")


def write_preparation_manifest(
    manifest: Mapping[str, Any],
    path: Path,
    *,
    corpus_path: Path,
    require_ignored: bool = True,
) -> None:
    if require_ignored:
        _require_ignored_manifest(path, corpus_path)
    path.parent.mkdir(parents=True, exist_ok=True)
    output = json.dumps(
        manifest,
        ensure_ascii=False,
        allow_nan=False,
        sort_keys=True,
        indent=2,
    ).encode("utf-8") + b"\n"
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(descriptor, "wb") as destination:
            destination.write(output)
            destination.flush()
            os.fsync(destination.fileno())
        os.replace(temporary_name, path)
    except BaseException:
        try:
            os.unlink(temporary_name)
        except OSError:
            pass
        raise


def validate_preparation_manifest(
    corpus_path: Path,
    media_dir: Path,
    manifest_path: Path,
    *,
    command_ledger_path: Path,
    runtime_receipt_path: Path,
    recipe_script_path: Path | None = None,
    ffprobe_path: Path,
    ffmpeg_path: Path,
    runner: CommandRunner = _default_runner,
) -> Mapping[str, Any]:
    _require_ignored_manifest(manifest_path, corpus_path)
    recorded, _ = _load_json(manifest_path, "preparation manifest")
    if recorded.get("schema") != MANIFEST_SCHEMA:
        raise CorpusError(f"preparation manifest schema must equal {MANIFEST_SCHEMA!r}")
    actual = build_preparation_manifest(
        corpus_path,
        media_dir,
        command_ledger_path=command_ledger_path,
        runtime_receipt_path=runtime_receipt_path,
        recipe_script_path=recipe_script_path,
        ffprobe_path=ffprobe_path,
        ffmpeg_path=ffmpeg_path,
        runner=runner,
    )
    if _canonical_json_bytes(recorded) != _canonical_json_bytes(actual):
        raise CorpusError("preparation manifest does not match the current declaration, tools, or assets")
    return actual


def _default_paths() -> tuple[Path, Path]:
    script = Path(__file__).resolve()
    repository = script.parent.parent
    return (
        script.parent / "corpus.json",
        repository / ".cache" / "benchmarks" / "media",
    )


def _parser() -> argparse.ArgumentParser:
    corpus, media = _default_paths()
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("runtime", "manifest", "validate"))
    parser.add_argument("--corpus", type=Path, default=corpus)
    parser.add_argument("--media-root", type=Path, default=media)
    parser.add_argument("--manifest", type=Path)
    parser.add_argument("--command-ledger", type=Path)
    parser.add_argument("--runtime-receipt", type=Path)
    parser.add_argument("--recipe-script", type=Path)
    parser.add_argument("--ffprobe", type=Path, default=Path("/opt/homebrew/bin/ffprobe"))
    parser.add_argument("--ffmpeg", type=Path, default=Path("/opt/homebrew/bin/ffmpeg"))
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    arguments = _parser().parse_args(argv)
    try:
        media_root = arguments.media_root.resolve(strict=True)
        corpus_value, _ = _load_json(arguments.corpus.resolve(strict=True), "corpus")
        native_value = _native_section(corpus_value)
        relative_runtime = _required_string(
            native_value, "runtime_receipt", "corpus.native_generated_corpus"
        )
        default_runtime = media_root.joinpath(*PurePosixPath(relative_runtime).parts)
        runtime_receipt = (
            default_runtime
            if arguments.runtime_receipt is None
            else arguments.runtime_receipt
        )
        runtime_receipt = _contained_path(
            media_root,
            runtime_receipt,
            "runtime receipt",
            must_exist=arguments.mode != "runtime",
        )
        if runtime_receipt != default_runtime.resolve(strict=False):
            raise CorpusError(
                "--runtime-receipt must be native-1080p-sdr-v1/runtime-receipt.json under --media-root"
            )
        if arguments.mode == "runtime":
            if runtime_receipt.exists():
                raise CorpusError("refusing to replace an existing runtime receipt")
            receipt = capture_runtime_identity(
                arguments.corpus,
                ffmpeg_path=arguments.ffmpeg,
                ffprobe_path=arguments.ffprobe,
                recipe_script_path=arguments.recipe_script,
            )
            write_runtime_receipt(
                receipt,
                runtime_receipt,
                corpus_path=arguments.corpus,
            )
            print(f"wrote {runtime_receipt}")
            return 0
        expected_manifest = declared_manifest_path(arguments.corpus, media_root)
        manifest_path = (
            expected_manifest
            if arguments.manifest is None
            else _contained_path(
                media_root,
                arguments.manifest,
                "preparation manifest",
                must_exist=arguments.mode == "validate",
            )
        )
        if manifest_path != expected_manifest:
            raise CorpusError(
                "--manifest must equal native_generated_corpus.preparation_manifest under --media-root"
            )
        command_ledger = arguments.command_ledger
        if command_ledger is None:
            relative_ledger = _required_string(
                native_value, "command_ledger", "corpus.native_generated_corpus"
            )
            command_ledger = media_root.joinpath(
                *PurePosixPath(relative_ledger).parts
            )
        command_ledger = _contained_path(
            media_root, command_ledger, "command ledger", must_exist=True
        )
        if arguments.mode == "manifest":
            manifest = build_preparation_manifest(
                arguments.corpus,
                media_root,
                command_ledger_path=command_ledger,
                runtime_receipt_path=runtime_receipt,
                recipe_script_path=arguments.recipe_script,
                ffprobe_path=arguments.ffprobe,
                ffmpeg_path=arguments.ffmpeg,
            )
            write_preparation_manifest(
                manifest,
                manifest_path,
                corpus_path=arguments.corpus,
            )
            print(f"wrote {manifest_path}")
        else:
            validate_preparation_manifest(
                arguments.corpus,
                media_root,
                manifest_path,
                command_ledger_path=command_ledger,
                runtime_receipt_path=runtime_receipt,
                recipe_script_path=arguments.recipe_script,
                ffprobe_path=arguments.ffprobe,
                ffmpeg_path=arguments.ffmpeg,
            )
            print(f"validated {manifest_path}")
        return 0
    except CorpusError as error:
        print(f"corpus validation failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
