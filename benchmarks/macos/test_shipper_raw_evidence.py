#!/usr/bin/env python3

import hashlib
import ctypes
import json
import math
import os
import struct
import tempfile
import unittest
import uuid
import wave
import zlib
from pathlib import Path

import shipper_raw_evidence as raw


RUN_ID = "123e4567-e89b-12d3-a456-426614174000"
ASSET_SHA256 = "ab" * 32
CAPTURE_NONCE = "12" * 32
AUDIT_TOKEN_SHA256 = "56" * 32
WINDOW_ID = 903
DISPLAY_ID = 1
PROCESS_TAP_ID = "process-tap-4242"
OUTPUT_ROUTE_UID = "BuiltInSpeakerDevice"


def canonical_json(value):
    return (
        json.dumps(value, sort_keys=True, separators=(",", ":"), allow_nan=False) + "\n"
    ).encode("ascii")


def set_xattr(path, name, value):
    library = ctypes.CDLL(None, use_errno=True)
    library.fsetxattr.argtypes = [
        ctypes.c_int,
        ctypes.c_char_p,
        ctypes.c_void_p,
        ctypes.c_size_t,
        ctypes.c_uint32,
        ctypes.c_int,
    ]
    library.fsetxattr.restype = ctypes.c_int
    descriptor = os.open(path, os.O_RDONLY)
    try:
        buffer = ctypes.create_string_buffer(value)
        if library.fsetxattr(descriptor, name.encode(), buffer, len(value), 0, 0) != 0:
            raise OSError(ctypes.get_errno(), "fsetxattr failed")
    finally:
        os.close(descriptor)


def png_chunk(kind, payload):
    return (
        struct.pack(">I", len(payload))
        + kind
        + payload
        + struct.pack(">I", zlib.crc32(kind + payload) & 0xFFFFFFFF)
    )


def rgba_png(*, width=64, height=64, filter_type=0, compressed=None, truncate_row=False):
    ihdr = struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)
    pixels = bytearray()
    scanlines = bytearray()
    previous = bytes(width * 4)
    for y in range(height):
        row = bytes(
            component
            for x in range(width)
            for component in ((x * 3) & 0xFF, (y * 5) & 0xFF, 127, 255)
        )
        pixels.extend(row)
        encoded = bytearray(len(row))
        for index, value in enumerate(row):
            left = row[index - 4] if index >= 4 else 0
            above = previous[index]
            upper_left = previous[index - 4] if index >= 4 else 0
            if filter_type == 0:
                predictor = 0
            elif filter_type == 1:
                predictor = left
            elif filter_type == 2:
                predictor = above
            elif filter_type == 3:
                predictor = (left + above) // 2
            elif filter_type == 4:
                prediction = left + above - upper_left
                distances = (
                    abs(prediction - left),
                    abs(prediction - above),
                    abs(prediction - upper_left),
                )
                predictor = (left, above, upper_left)[distances.index(min(distances))]
            else:
                predictor = 0
            encoded[index] = (value - predictor) & 0xFF
        scanlines.append(filter_type)
        scanlines.extend(encoded)
        previous = row
    if truncate_row:
        scanlines.pop()
    idat = zlib.compress(bytes(scanlines)) if compressed is None else compressed
    return (
        b"\x89PNG\r\n\x1a\n"
        + png_chunk(b"IHDR", ihdr)
        + png_chunk(b"IDAT", idat)
        + png_chunk(b"IEND", b"")
    ), hashlib.sha256(pixels).hexdigest()


def pcm_wav(*, seconds=0.5, sample_rate=8000, amplitude=2000, mode="sine", channels=1):
    frame_count = round(seconds * sample_rate)
    frames = bytearray()
    for index in range(frame_count):
        for channel in range(channels):
            if mode == "sine":
                sample = round(
                    amplitude * math.sin(2.0 * math.pi * 440.0 * index / sample_rate)
                )
            elif mode == "dc":
                sample = amplitude
            elif mode == "stereo_dc":
                sample = amplitude if channel == 0 else -amplitude
            elif mode == "impulse":
                sample = amplitude if index == frame_count // 2 else 0
            elif mode == "pulse_train":
                window_frames = round(sample_rate * raw.HARD_AUDIO_WINDOW_SECONDS)
                sample = amplitude if index % window_frames == 0 else 0
            else:
                raise ValueError(mode)
            frames.extend(struct.pack("<h", sample))
    with tempfile.SpooledTemporaryFile() as output:
        with wave.open(output, "wb") as writer:
            writer.setnchannels(channels)
            writer.setsampwidth(2)
            writer.setframerate(sample_rate)
            writer.writeframes(bytes(frames))
        output.seek(0)
        return output.read()


class RawEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.base = Path(self.temp.name).resolve()
        self.root = self.base / "campaign"
        self.root.mkdir()
        self.campaign_id = str(uuid.uuid4())
        self.binding = raw.EvidenceBinding(
            run_id=RUN_ID,
            process_id=4242,
            process_start_abstime=987654321,
            source_key=7,
            asset_sha256=ASSET_SHA256,
            candidate_id="candidate-release-42",
        )
        self.bounds = raw.CaptureBounds(1_000_000_000, 5_000_000_000)
        self.registry = None
        self.tools_dir = self.base / "tools"
        self.tools_dir.mkdir()
        self.tools = {}
        for index, role in enumerate(sorted(raw._TRUST_TOOL_ROLES), start=1):
            executable = self.tools_dir / role
            executable.write_bytes(f"trusted-{role}-executable\n".encode())
            self.tools[role] = raw.capture_trusted_tool_identity(
                role=role,
                process_id=8000 + index,
                process_start_abstime=900_000 + index,
                executable_argv_sha256=hashlib.sha256(
                    f"{executable}\0--campaign\0{self.campaign_id}".encode()
                ).hexdigest(),
                executable_path=str(executable),
                audit_token_sha256=AUDIT_TOKEN_SHA256,
            )
        app_root = self.base / "Candidate.app" / "Contents" / "Frameworks"
        app_root.mkdir(parents=True)
        self.dylib_path = app_root / "WAMMpvFallback.dylib"
        self.dylib_path.write_bytes(b"exact staged fallback dylib bytes\n")
        self.dylib = raw.capture_candidate_dylib_identity(str(self.dylib_path))

    def tearDown(self):
        if self.registry is not None:
            self.registry.close()
        self.temp.cleanup()

    def write(self, ref, data):
        if self.registry is not None and self.registry._manifest is not None:
            raise AssertionError("test attempted to mutate a sealed campaign")
        path = self.root / ref
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        return path

    def reference(
        self,
        evidence_id,
        ref,
        data,
        media_type,
        *,
        binding=None,
        capture_start=1_500_000_000,
        capture_end=1_600_000_000,
    ):
        return {
            "schema": raw.SCHEMA,
            "evidence_id": evidence_id,
            "ref": ref,
            "sha256": hashlib.sha256(data).hexdigest(),
            "byte_length": len(data),
            "media_type": media_type,
            "binding": (binding or self.binding).as_dict(),
            "capture_started_monotonic_ns": capture_start,
            "capture_ended_monotonic_ns": capture_end,
        }

    def artifact_identity(self, reference):
        path = self.root / reference["ref"]
        observed = path.stat()
        descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_CLOEXEC", 0))
        try:
            xattr_sha256 = raw._xattr_digest_fd(descriptor)
        finally:
            os.close(descriptor)
        return {
            "evidence_id": reference["evidence_id"],
            "ref": reference["ref"],
            "device": observed.st_dev,
            "inode": observed.st_ino,
            "mode": observed.st_mode,
            "uid": observed.st_uid,
            "gid": observed.st_gid,
            "nlink": observed.st_nlink,
            "byte_length": reference["byte_length"],
            "mtime_ns": observed.st_mtime_ns,
            "ctime_ns": observed.st_ctime_ns,
            "flags": int(getattr(observed, "st_flags", 0)),
            "xattr_sha256": xattr_sha256,
            "sha256": reference["sha256"],
            "media_type": reference["media_type"],
            "capture_started_monotonic_ns": reference[
                "capture_started_monotonic_ns"
            ],
            "capture_ended_monotonic_ns": reference["capture_ended_monotonic_ns"],
            "campaign_id": self.campaign_id,
        }

    def seal(self):
        if self.registry is None:
            self.registry = raw.EvidenceRegistry(
                self.root, campaign_id=self.campaign_id
            )
        return self.registry.seal_campaign()

    def trust(self, receipt_sha256, *, tools=None, candidate=None, mutate=None):
        index = raw.make_external_trust_index_bytes(
            campaign_id=self.campaign_id,
            binding=self.binding,
            capture_nonce=CAPTURE_NONCE,
            audit_token_sha256=AUDIT_TOKEN_SHA256,
            tools=tuple((tools or self.tools).values()),
            receipt_sha256=receipt_sha256,
            candidate_dylib=candidate,
        )
        if mutate is not None:
            index = mutate(index)
        return raw.validate_external_trust_index(
            index,
            expected_index_sha256=hashlib.sha256(index).hexdigest(),
            expected_campaign_id=self.campaign_id,
            expected_binding=self.binding,
        )

    def validate_reference(self, reference, media_type="text/plain"):
        self.seal()
        return self.registry.validate_reference(
            reference,
            expected_binding=self.binding,
            expected_media_type=media_type,
            allowed_capture_bounds=self.bounds,
        )

    def test_sealed_manifest_rehashes_regular_file_and_requires_explicit_seal(self):
        data = b"pid image list\n"
        self.write("run/loader.txt", data)
        reference = self.reference("loader-pre", "run/loader.txt", data, "text/plain")
        self.registry = raw.EvidenceRegistry(self.root, campaign_id=self.campaign_id)
        with self.assertRaisesRegex(raw.RawEvidenceError, "explicitly sealed"):
            self.registry.validate_reference(
                reference,
                expected_binding=self.binding,
                expected_media_type="text/plain",
                allowed_capture_bounds=self.bounds,
            )
        manifest = self.registry.seal_campaign()
        validated = self.registry.validate_reference(
            reference,
            expected_binding=self.binding,
            expected_media_type="text/plain",
            allowed_capture_bounds=self.bounds,
        )
        self.assertEqual(validated.data, data)
        self.assertEqual(validated.campaign_id, self.campaign_id)
        self.assertEqual(validated.campaign_manifest_sha256, manifest["manifest_sha256"])

    def test_root_nested_directory_and_leaf_generation_swaps_fail_closed(self):
        data = b"original retained proof\n"
        path = self.write("nested/deep/proof.txt", data)
        reference = self.reference("proof", "nested/deep/proof.txt", data, "text/plain")
        self.seal()

        original_root = self.base / "old-root"
        self.root.rename(original_root)
        self.root.mkdir()
        (self.root / "nested/deep").mkdir(parents=True)
        (self.root / "nested/deep/proof.txt").write_bytes(data)
        with self.assertRaisesRegex(raw.RawEvidenceError, "root was replaced"):
            self.registry.validate_reference(
                reference,
                expected_binding=self.binding,
                expected_media_type="text/plain",
                allowed_capture_bounds=self.bounds,
            )
        self.registry.close()
        self.registry = None

        # A new campaign demonstrates nested directory and same-byte leaf swaps.
        self.root = self.base / "campaign-two"
        self.root.mkdir()
        self.campaign_id = str(uuid.uuid4())
        path = self.write("nested/deep/proof.txt", data)
        reference = self.reference("proof-two", "nested/deep/proof.txt", data, "text/plain")
        self.seal()
        deep = path.parent
        old_deep = deep.with_name("old-deep")
        deep.rename(old_deep)
        deep.mkdir()
        (deep / "proof.txt").write_bytes(data)
        with self.assertRaisesRegex(
            raw.RawEvidenceError, "root was replaced|manifest generation changed"
        ):
            self.registry.validate_reference(
                reference,
                expected_binding=self.binding,
                expected_media_type="text/plain",
                allowed_capture_bounds=self.bounds,
            )

    def test_leaf_same_bytes_replacement_after_seal_fails(self):
        data = b"same bytes\n"
        path = self.write("leaf.txt", data)
        reference = self.reference("leaf", "leaf.txt", data, "text/plain")
        self.seal()
        old = self.root / "old-leaf.txt"
        path.rename(old)
        path.write_bytes(data)
        with self.assertRaisesRegex(
            raw.RawEvidenceError, "root was replaced|manifest generation changed"
        ):
            self.registry.validate_reference(
                reference,
                expected_binding=self.binding,
                expected_media_type="text/plain",
                allowed_capture_bounds=self.bounds,
            )

    def test_manifest_rejects_late_file_and_xattr_generation_changes(self):
        data = b"stable\n"
        path = self.write("proof.txt", data)
        reference = self.reference("proof", "proof.txt", data, "text/plain")
        self.seal()
        (self.root / "late.txt").write_bytes(b"late\n")
        with self.assertRaisesRegex(
            raw.RawEvidenceError, "root was replaced|manifest generation changed"
        ):
            self.registry.validate_reference(
                reference,
                expected_binding=self.binding,
                expected_media_type="text/plain",
                allowed_capture_bounds=self.bounds,
            )
        (self.root / "late.txt").unlink()
        set_xattr(path, "com.wam.test-generation", b"changed")
        with self.assertRaisesRegex(
            raw.RawEvidenceError, "root was replaced|manifest generation changed"
        ):
            self.registry.validate_reference(
                reference,
                expected_binding=self.binding,
                expected_media_type="text/plain",
                allowed_capture_bounds=self.bounds,
            )

    def test_hardlink_and_cross_registry_campaign_aliases_fail_closed(self):
        first = self.write("first.txt", b"same inode\n")
        os.link(first, self.root / "second.txt")
        self.registry = raw.EvidenceRegistry(self.root, campaign_id=self.campaign_id)
        with self.assertRaisesRegex(raw.RawEvidenceError, "hard-linked"):
            self.registry.seal_campaign()
        self.registry.close()
        self.registry = None

        self.root = self.base / "unique-campaign"
        self.root.mkdir()
        self.campaign_id = str(uuid.uuid4())
        self.write("proof.txt", b"proof\n")
        self.registry = raw.EvidenceRegistry(self.root, campaign_id=self.campaign_id)
        with self.assertRaisesRegex(raw.RawEvidenceError, "already has a registry"):
            raw.EvidenceRegistry(self.root, campaign_id=self.campaign_id)
        with self.assertRaisesRegex(raw.RawEvidenceError, "root generation"):
            raw.EvidenceRegistry(self.root, campaign_id=str(uuid.uuid4()))

    def test_campaign_root_rejects_symlinked_parent_and_symlink_reentry(self):
        real_parent = self.base / "real-parent"
        real_root = real_parent / "campaign"
        real_root.mkdir(parents=True)
        (real_root / "proof.txt").write_bytes(b"proof\n")
        linked_parent = self.base / "linked-parent"
        linked_parent.symlink_to(real_parent, target_is_directory=True)
        with self.assertRaisesRegex(raw.RawEvidenceError, "symlinked path component"):
            raw.EvidenceRegistry(
                linked_parent / "campaign", campaign_id=str(uuid.uuid4())
            )

        stable_parent = self.base / "stable-parent"
        stable_root = stable_parent / "campaign"
        stable_root.mkdir(parents=True)
        proof = b"stable proof\n"
        (stable_root / "proof.txt").write_bytes(proof)
        registry = raw.EvidenceRegistry(stable_root, campaign_id=str(uuid.uuid4()))
        try:
            registry.seal_campaign()
            moved_parent = self.base / "moved-parent"
            stable_parent.rename(moved_parent)
            stable_parent.symlink_to(moved_parent, target_is_directory=True)
            with self.assertRaisesRegex(raw.RawEvidenceError, "no longer names"):
                registry.assert_campaign_unchanged()
        finally:
            registry.close()

    def test_campaign_global_id_ref_and_inode_reuse_rejected(self):
        one = b"one\n"
        two = b"two\n"
        self.write("one.txt", one)
        self.write("two.txt", two)
        first = self.reference("same-id", "one.txt", one, "text/plain")
        duplicate_id = self.reference("same-id", "two.txt", two, "text/plain")
        self.seal()
        self.registry.validate_reference(
            first,
            expected_binding=self.binding,
            expected_media_type="text/plain",
            allowed_capture_bounds=self.bounds,
        )
        with self.assertRaisesRegex(raw.RawEvidenceError, "evidence_id"):
            self.registry.validate_reference(
                duplicate_id,
                expected_binding=self.binding,
                expected_media_type="text/plain",
                allowed_capture_bounds=self.bounds,
            )

    def test_missing_outside_symlink_and_hash_mismatch_fail_closed(self):
        data = b"retained\n"
        target = self.write("target.txt", data)
        os.symlink(target, self.root / "leaf.txt")
        self.registry = raw.EvidenceRegistry(self.root, campaign_id=self.campaign_id)
        with self.assertRaisesRegex(raw.RawEvidenceError, "only real directories"):
            self.registry.seal_campaign()
        self.registry.close()
        self.registry = None

        self.root = self.base / "clean-campaign"
        self.root.mkdir()
        self.campaign_id = str(uuid.uuid4())
        self.write("proof.txt", data)
        missing = self.reference("missing", "missing.txt", data, "text/plain")
        bad_hash = self.reference("hash", "proof.txt", data, "text/plain")
        bad_hash["sha256"] = "00" * 32
        self.seal()
        with self.assertRaisesRegex(raw.RawEvidenceError, "absent from the sealed"):
            self.registry.validate_reference(
                missing,
                expected_binding=self.binding,
                expected_media_type="text/plain",
                allowed_capture_bounds=self.bounds,
            )
        with self.assertRaisesRegex(raw.RawEvidenceError, "sha256"):
            self.registry.validate_reference(
                bad_hash,
                expected_binding=self.binding,
                expected_media_type="text/plain",
                allowed_capture_bounds=self.bounds,
            )

    def stage_screen(
        self,
        *,
        png=None,
        pixel_sha=None,
        width=64,
        height=64,
        state_start=1_500_000_000,
        state_end=1_600_000_000,
        png_start=1_520_000_000,
        png_end=1_580_000_000,
        mutate_state=None,
        mutate_receipt=None,
    ):
        if png is None:
            png, pixel_sha = rgba_png(width=width, height=height)
        state_value = {
            "schema": raw.WINDOW_STATE_SCHEMA,
            "window_id": WINDOW_ID,
            "owner_process_id": self.binding.process_id,
            "owner_process_start_abstime": self.binding.process_start_abstime,
            "display_id": DISPLAY_ID,
            "on_screen": True,
            "frontmost": True,
            "bounds": {"x": 10, "y": 20, "width": width, "height": height},
            "backing_scale_factor": 1.0,
            "sampled_monotonic_ns": 1_550_000_000,
            "audit_token_sha256": AUDIT_TOKEN_SHA256,
        }
        if mutate_state:
            mutate_state(state_value)
        state = canonical_json(state_value)
        self.write("screen/frame.png", png)
        self.write("screen/window.json", state)
        png_ref = self.reference(
            "screen-png", "screen/frame.png", png, "image/png",
            capture_start=png_start, capture_end=png_end,
        )
        state_ref = self.reference(
            "window-state", "screen/window.json", state, "application/json",
            capture_start=state_start, capture_end=state_end,
        )
        receipt_value = {
            "schema": raw.WINDOW_CAPTURE_RECEIPT_SCHEMA,
            "binding": self.binding.as_dict(),
            "receipt_id": "screen-receipt",
            "capture_nonce": CAPTURE_NONCE,
            "screen_capture_tool": self.tools["screen_capture"].as_dict(),
            "window_audit_tool": self.tools["window_audit"].as_dict(),
            "audit_token_sha256": AUDIT_TOKEN_SHA256,
            "window_id": WINDOW_ID,
            "owner_process_id": self.binding.process_id,
            "owner_process_start_abstime": self.binding.process_start_abstime,
            "display_id": DISPLAY_ID,
            "window_bounds": {"x": 10, "y": 20, "width": width, "height": height},
            "backing_scale_factor": 1.0,
            "pixel_width": width,
            "pixel_height": height,
            "png_artifact": self.artifact_identity(png_ref),
            "window_state_artifact": self.artifact_identity(state_ref),
            "decoded_pixel_sha256": pixel_sha or "00" * 32,
            "capture_started_monotonic_ns": png_start,
            "capture_ended_monotonic_ns": png_end,
        }
        if mutate_receipt:
            mutate_receipt(receipt_value)
        receipt = canonical_json(receipt_value)
        self.write("screen/receipt.json", receipt)
        receipt_ref = self.reference(
            "screen-receipt", "screen/receipt.json", receipt, "application/json",
            capture_start=png_start, capture_end=png_end,
        )
        return png_ref, state_ref, receipt_ref, receipt

    def validate_screen(self, staged, *, trust_receipt=None):
        png_ref, state_ref, receipt_ref, receipt = staged
        attestation = self.trust(
            {"window_capture": trust_receipt or hashlib.sha256(receipt).hexdigest()}
        )
        self.seal()
        return raw.validate_png_window_proof(
            self.registry,
            png_reference=png_ref,
            window_state_reference=state_ref,
            capture_receipt_reference=receipt_ref,
            expected_binding=self.binding,
            allowed_capture_bounds=self.bounds,
            attestation=attestation,
        )

    def test_screen_png_all_filters_decode_and_authenticated_receipt_binds_window(self):
        for filter_type in range(5):
            with self.subTest(filter_type=filter_type):
                if filter_type:
                    self.tearDown()
                    self.setUp()
                png, pixels = rgba_png(filter_type=filter_type)
                result = self.validate_screen(
                    self.stage_screen(png=png, pixel_sha=pixels)
                )
                self.assertTrue(result["eligible"])
                self.assertEqual(result["decoded_pixel_sha256"], pixels)
                self.assertEqual(result["window_id"], WINDOW_ID)

    def test_screen_rejects_corrupt_zlib_filter_scanline_one_pixel_geometry_overlap(self):
        bad_pngs = (
            (rgba_png(compressed=b"not-zlib")[0], "zlib"),
            (rgba_png(filter_type=5)[0], "filter"),
            (rgba_png(truncate_row=True)[0], "scanline"),
            (rgba_png(width=1, height=1)[0], "bounded"),
        )
        for index, (png, pattern) in enumerate(bad_pngs):
            with self.subTest(pattern=pattern):
                if index:
                    self.tearDown()
                    self.setUp()
                staged = self.stage_screen(
                    png=png,
                    width=1 if pattern == "bounded" else 64,
                    height=1 if pattern == "bounded" else 64,
                )
                with self.assertRaisesRegex(raw.RawEvidenceError, pattern):
                    self.validate_screen(staged)

    def test_screen_rejects_unretained_plain_mapping_and_fake_trust_digest(self):
        staged = self.stage_screen()
        self.seal()
        with self.assertRaisesRegex(raw.RawEvidenceError, "capability"):
            raw.validate_png_window_proof(
                self.registry,
                png_reference=staged[0],
                window_state_reference=staged[1],
                capture_receipt_reference=staged[2],
                expected_binding=self.binding,
                allowed_capture_bounds=self.bounds,
                attestation={"captured_by_harness": True},
            )
        with self.assertRaisesRegex(raw.RawEvidenceError, "trust-anchor digest"):
            raw.validate_external_trust_index(
                raw.make_external_trust_index_bytes(
                    campaign_id=self.campaign_id,
                    binding=self.binding,
                    capture_nonce=CAPTURE_NONCE,
                    audit_token_sha256=AUDIT_TOKEN_SHA256,
                    tools=tuple(self.tools.values()),
                    receipt_sha256={"window_capture": hashlib.sha256(staged[3]).hexdigest()},
                ),
                expected_index_sha256="00" * 32,
                expected_campaign_id=self.campaign_id,
                expected_binding=self.binding,
            )
        wrong_receipt_capability = self.trust({"window_capture": "00" * 32})
        with self.assertRaisesRegex(raw.RawEvidenceError, "producer receipt"):
            raw.validate_png_window_proof(
                self.registry,
                png_reference=staged[0],
                window_state_reference=staged[1],
                capture_receipt_reference=staged[2],
                expected_binding=self.binding,
                allowed_capture_bounds=self.bounds,
                attestation=wrong_receipt_capability,
            )

    def test_external_trust_index_binds_exact_campaign_binding_nonce_and_tool_argv(self):
        staged = self.stage_screen()
        receipt_hash = hashlib.sha256(staged[3]).hexdigest()
        index = raw.make_external_trust_index_bytes(
            campaign_id=self.campaign_id,
            binding=self.binding,
            capture_nonce=CAPTURE_NONCE,
            audit_token_sha256=AUDIT_TOKEN_SHA256,
            tools=tuple(self.tools.values()),
            receipt_sha256={"window_capture": receipt_hash},
        )
        digest = hashlib.sha256(index).hexdigest()
        with self.assertRaisesRegex(raw.RawEvidenceError, "different campaign"):
            raw.validate_external_trust_index(
                index,
                expected_index_sha256=digest,
                expected_campaign_id=str(uuid.uuid4()),
                expected_binding=self.binding,
            )
        wrong_binding = raw.EvidenceBinding(
            run_id=self.binding.run_id,
            process_id=self.binding.process_id,
            process_start_abstime=self.binding.process_start_abstime,
            source_key=self.binding.source_key + 1,
            asset_sha256=self.binding.asset_sha256,
            candidate_id=self.binding.candidate_id,
        )
        with self.assertRaisesRegex(raw.RawEvidenceError, "different evidence binding"):
            raw.validate_external_trust_index(
                index,
                expected_index_sha256=digest,
                expected_campaign_id=self.campaign_id,
                expected_binding=wrong_binding,
            )
        changed_tool = dict(self.tools["screen_capture"].as_dict())
        changed_tool["executable_argv_sha256"] = "00" * 32
        staged = self.stage_screen(
            mutate_receipt=lambda receipt: receipt.update(
                screen_capture_tool=changed_tool
            )
        )
        with self.assertRaisesRegex(raw.RawEvidenceError, "trusted screen_capture"):
            self.validate_screen(staged)

    def test_screen_rejects_receipt_tool_and_artifact_generation_substitution(self):
        other_tool = dict(self.tools["screen_capture"].as_dict())
        other_tool["process_id"] += 1
        cases = (
            (
                lambda receipt: receipt.update(screen_capture_tool=other_tool),
                "trusted screen_capture",
            ),
            (
                lambda receipt: receipt["png_artifact"].update(
                    mtime_ns=receipt["png_artifact"]["mtime_ns"] + 1
                ),
                "exact retained artifact generation",
            ),
        )
        for index, (mutation, pattern) in enumerate(cases):
            with self.subTest(pattern=pattern):
                if index:
                    self.tearDown()
                    self.setUp()
                with self.assertRaisesRegex(raw.RawEvidenceError, pattern):
                    self.validate_screen(
                        self.stage_screen(mutate_receipt=mutation)
                    )

    def test_screen_rejects_window_geometry_and_nonoverlap_substitution(self):
        cases = (
            (
                dict(
                    mutate_receipt=lambda receipt: receipt.update(
                        window_id=WINDOW_ID + 1
                    )
                ),
                "exact window",
            ),
            (
                dict(
                    mutate_receipt=lambda receipt: receipt.update(
                        window_bounds={"x": 10, "y": 20, "width": 65, "height": 64}
                    )
                ),
                "geometry",
            ),
            (
                dict(
                    state_start=1_400_000_000,
                    state_end=1_500_000_000,
                    png_start=1_500_000_000,
                    png_end=1_560_000_000,
                    mutate_state=lambda state: state.update(
                        sampled_monotonic_ns=1_500_000_000
                    ),
                ),
                "do not overlap",
            ),
        )
        for index, (arguments, pattern) in enumerate(cases):
            with self.subTest(pattern=pattern):
                if index:
                    self.tearDown()
                    self.setUp()
                with self.assertRaisesRegex(raw.RawEvidenceError, pattern):
                    self.validate_screen(self.stage_screen(**arguments))

    def test_screen_rejects_trusted_tool_executable_replacement_after_attestation(self):
        staged = self.stage_screen()
        capability = self.trust(
            {"window_capture": hashlib.sha256(staged[3]).hexdigest()}
        )
        tool_path = Path(self.tools["screen_capture"].executable_path)
        original = tool_path.with_name("screen_capture.old")
        tool_path.rename(original)
        tool_path.write_bytes(b"replacement executable generation\n")
        self.seal()
        with self.assertRaisesRegex(raw.RawEvidenceError, "executable generation changed"):
            raw.validate_png_window_proof(
                self.registry,
                png_reference=staged[0],
                window_state_reference=staged[1],
                capture_receipt_reference=staged[2],
                expected_binding=self.binding,
                allowed_capture_bounds=self.bounds,
                attestation=capability,
            )

    def stage_loader(
        self,
        *,
        pre_start=1_875_000_000,
        pre_end=1_975_000_000,
        post_start=2_025_000_000,
        post_end=2_125_000_000,
        observation_dylib_sha256=None,
        pre_loaded=False,
        mutate_receipt=None,
    ):
        observation_hash = observation_dylib_sha256 or self.dylib.sha256
        pre = raw.make_loader_observation_text(
            binding=self.binding,
            canonical_dylib_path=str(self.dylib_path),
            dylib_sha256=observation_hash,
            started_monotonic_ns=pre_start,
            ended_monotonic_ns=pre_end,
            sample_period_ns=50_000_000,
            sample_clocks=(pre_start, pre_start + 50_000_000, pre_end),
            loaded=pre_loaded,
        )
        post = raw.make_loader_observation_text(
            binding=self.binding,
            canonical_dylib_path=str(self.dylib_path),
            dylib_sha256=observation_hash,
            started_monotonic_ns=post_start,
            ended_monotonic_ns=post_end,
            sample_period_ns=50_000_000,
            sample_clocks=(post_start, post_start + 50_000_000, post_end),
            loaded=True,
        )
        self.write("loader/pre.txt", pre)
        self.write("loader/post.txt", post)
        pre_ref = self.reference(
            "loader-pre", "loader/pre.txt", pre, "text/plain",
            capture_start=pre_start, capture_end=pre_end,
        )
        post_ref = self.reference(
            "loader-post", "loader/post.txt", post, "text/plain",
            capture_start=post_start, capture_end=post_end,
        )
        receipt_value = {
            "schema": raw.LOADER_INSPECTOR_RECEIPT_SCHEMA,
            "binding": self.binding.as_dict(),
            "receipt_id": "loader-receipt",
            "capture_nonce": CAPTURE_NONCE,
            "audit_token_sha256": AUDIT_TOKEN_SHA256,
            "loader_inspector_tool": self.tools["loader_inspector"].as_dict(),
            "candidate_dylib": self.dylib.as_dict(),
            "route_selection_monotonic_ns": 2_000_000_000,
            "pre_artifact": self.artifact_identity(pre_ref),
            "post_artifact": self.artifact_identity(post_ref),
            "capture_started_monotonic_ns": pre_start,
            "capture_ended_monotonic_ns": post_end,
        }
        if mutate_receipt:
            mutate_receipt(receipt_value)
        receipt = canonical_json(receipt_value)
        self.write("loader/receipt.json", receipt)
        receipt_ref = self.reference(
            "loader-receipt", "loader/receipt.json", receipt, "application/json",
            capture_start=pre_start, capture_end=post_end,
        )
        return pre_ref, post_ref, receipt_ref, receipt

    def validate_loader(self, staged, **changes):
        pre_ref, post_ref, receipt_ref, receipt = staged
        attestation = self.trust(
            {"loader_inspector": hashlib.sha256(receipt).hexdigest()},
            candidate=self.dylib,
        )
        self.seal()
        arguments = dict(
            registry=self.registry,
            pre_route_reference=pre_ref,
            post_route_reference=post_ref,
            inspector_receipt_reference=receipt_ref,
            expected_binding=self.binding,
            allowed_capture_bounds=self.bounds,
            route_selection_monotonic_ns=2_000_000_000,
            canonical_dylib_path=str(self.dylib_path),
            attestation=attestation,
        )
        arguments.update(changes)
        return raw.validate_lazy_load_proof(**arguments)

    def test_loader_authenticated_receipt_binds_pid_start_candidate_path_hash_and_timing(self):
        result = self.validate_loader(self.stage_loader())
        self.assertTrue(result["eligible"])
        self.assertEqual(result["candidate_dylib"], self.dylib.as_dict())
        self.assertEqual(result["pre_route_sample_count"], 3)

    def test_loader_missing_or_replaced_dylib_fails_closed(self):
        staged = self.stage_loader()
        self.dylib_path.unlink()
        with self.assertRaisesRegex(raw.RawEvidenceError, "missing"):
            self.validate_loader(staged)

    def test_loader_pidless_text_wrong_hash_and_equality_fail_closed(self):
        staged = self.stage_loader()
        pidless = b"schema=wam.macos.loader-observation.v1\n"
        self.write("loader/pre.txt", pidless)
        staged[0]["sha256"] = hashlib.sha256(pidless).hexdigest()
        staged[0]["byte_length"] = len(pidless)
        with self.assertRaisesRegex(raw.RawEvidenceError, "artifact|sample series|header"):
            self.validate_loader(staged)

    def test_loader_wrong_dylib_hash_loaded_before_and_route_equality_fail_closed(self):
        cases = (
            (dict(observation_dylib_sha256="00" * 32), "hash"),
            (dict(pre_loaded=True), "contradictory"),
            (
                dict(pre_start=1_900_000_000, pre_end=2_000_000_000),
                "strictly before",
            ),
            (
                dict(post_start=2_000_000_000, post_end=2_100_000_000),
                "strictly after",
            ),
        )
        for index, (arguments, pattern) in enumerate(cases):
            with self.subTest(pattern=pattern):
                if index:
                    self.tearDown()
                    self.setUp()
                with self.assertRaisesRegex(raw.RawEvidenceError, pattern):
                    self.validate_loader(self.stage_loader(**arguments))

    def test_loader_rejects_receipt_candidate_and_inspector_tool_substitution(self):
        changed_candidate = dict(self.dylib.as_dict())
        changed_candidate["sha256"] = "00" * 32
        changed_tool = dict(self.tools["loader_inspector"].as_dict())
        changed_tool["process_start_abstime"] += 1
        cases = (
            (
                lambda receipt: receipt.update(candidate_dylib=changed_candidate),
                "different candidate",
            ),
            (
                lambda receipt: receipt.update(loader_inspector_tool=changed_tool),
                "trusted loader_inspector",
            ),
            (
                lambda receipt: receipt["pre_artifact"].update(
                    inode=receipt["pre_artifact"]["inode"] + 1
                ),
                "exact retained artifact generation",
            ),
        )
        for index, (mutation, pattern) in enumerate(cases):
            with self.subTest(pattern=pattern):
                if index:
                    self.tearDown()
                    self.setUp()
                    if pattern == "trusted loader_inspector":
                        changed_tool = dict(
                            self.tools["loader_inspector"].as_dict()
                        )
                        changed_tool["process_start_abstime"] += 1

                        def mutation(receipt):
                            receipt.update(loader_inspector_tool=changed_tool)
                    else:

                        def mutation(receipt):
                            receipt["pre_artifact"].update(
                                inode=receipt["pre_artifact"]["inode"] + 1
                            )
                with self.assertRaisesRegex(raw.RawEvidenceError, pattern):
                    self.validate_loader(
                        self.stage_loader(mutate_receipt=mutation)
                    )

    def test_loader_synthetic_receipt_without_external_attestation_never_eligible(self):
        staged = self.stage_loader()
        self.seal()
        with self.assertRaisesRegex(raw.RawEvidenceError, "capability"):
            raw.validate_lazy_load_proof(
                self.registry,
                pre_route_reference=staged[0],
                post_route_reference=staged[1],
                inspector_receipt_reference=staged[2],
                expected_binding=self.binding,
                allowed_capture_bounds=self.bounds,
                route_selection_monotonic_ns=2_000_000_000,
                canonical_dylib_path=str(self.dylib_path),
                attestation={"integrity_only": True},
            )

    def stage_audio(
        self,
        data,
        *,
        evidence_id="audio",
        capture_duration_seconds=0.5,
        mutate_receipt=None,
    ):
        start = 1_500_000_000
        end = start + round(capture_duration_seconds * 1_000_000_000)
        self.write(f"audio/{evidence_id}.wav", data)
        wav_ref = self.reference(
            evidence_id, f"audio/{evidence_id}.wav", data, "audio/wav",
            capture_start=start, capture_end=end,
        )
        with wave.open(str(self.root / wav_ref["ref"]), "rb") as reader:
            sample_rate = reader.getframerate()
            channels = reader.getnchannels()
            frame_count = reader.getnframes()
        first_sample = start
        last_sample = start + round((frame_count - 1) * 1_000_000_000 / sample_rate)
        receipt_value = raw.make_audio_capture_provenance(
            binding=self.binding,
            provenance_id=f"provenance-{evidence_id}",
            capture_nonce=CAPTURE_NONCE,
            system_audio_capture_tool=self.tools["system_audio_capture"],
            process_tap_tool=self.tools["process_tap"],
            process_tap_id=PROCESS_TAP_ID,
            audit_token_sha256=AUDIT_TOKEN_SHA256,
            output_route_uid=OUTPUT_ROUTE_UID,
            output_device_id=57,
            capture_started_monotonic_ns=start,
            capture_ended_monotonic_ns=end,
            stream_sample_rate_hz=sample_rate,
            stream_channels=channels,
            stream_frame_count=frame_count,
            first_sample_monotonic_ns=first_sample,
            last_sample_monotonic_ns=last_sample,
            output_latency_frames=64,
            wav_artifact=self.artifact_identity(wav_ref),
        )
        if mutate_receipt:
            mutate_receipt(receipt_value)
        receipt = canonical_json(receipt_value)
        self.write(f"audio/{evidence_id}-receipt.json", receipt)
        receipt_ref = self.reference(
            f"{evidence_id}-receipt",
            f"audio/{evidence_id}-receipt.json",
            receipt,
            "application/json",
            capture_start=start,
            capture_end=end,
        )
        return wav_ref, receipt_ref, receipt

    def validate_audio(self, staged, **changes):
        wav_ref, receipt_ref, receipt = staged
        attestation = self.trust(
            {"process_audio": hashlib.sha256(receipt).hexdigest()}
        )
        self.seal()
        arguments = dict(
            registry=self.registry,
            wav_reference=wav_ref,
            provenance_reference=receipt_ref,
            expected_binding=self.binding,
            allowed_capture_bounds=self.bounds,
            attestation=attestation,
        )
        arguments.update(changes)
        return raw.validate_process_audio_wav(**arguments)

    def test_audio_authenticated_receipt_binds_pcm_process_tap_route_and_stream_timing(self):
        result = self.validate_audio(self.stage_audio(pcm_wav()))
        self.assertTrue(result["eligible"])
        self.assertEqual(result["process_tap_id"], PROCESS_TAP_ID)
        self.assertEqual(result["output_route_uid"], OUTPUT_ROUTE_UID)
        self.assertGreaterEqual(result["active_window_fraction"], 0.8)

    def test_audio_silence_impulse_pulse_and_dc_fail_closed(self):
        cases = (
            (pcm_wav(amplitude=0), "silent"),
            (pcm_wav(amplitude=32767, mode="impulse"), "sustained"),
            (pcm_wav(amplitude=32767, mode="pulse_train"), "sustained"),
            (pcm_wav(amplitude=2000, mode="dc"), "DC"),
            (pcm_wav(amplitude=2000, mode="stereo_dc", channels=2), "DC"),
        )
        for index, (data, pattern) in enumerate(cases):
            with self.subTest(pattern=pattern):
                if index:
                    self.tearDown()
                    self.setUp()
                with self.assertRaisesRegex(raw.RawEvidenceError, pattern):
                    self.validate_audio(self.stage_audio(data))

    def test_audio_zero_thresholds_cannot_weaken_floors(self):
        for field in ("minimum_duration_seconds", "minimum_rms", "minimum_peak"):
            with self.subTest(field=field):
                if self.registry is not None:
                    self.tearDown()
                    self.setUp()
                with self.assertRaisesRegex(raw.RawEvidenceError, "positive|hard audio floor"):
                    self.validate_audio(self.stage_audio(pcm_wav()), **{field: 0.0})

    def test_audio_rejects_fake_tool_route_binding_and_stream_timing(self):
        changed_tool = dict(self.tools["process_tap"].as_dict())
        changed_tool["process_id"] += 1
        cases = (
            (
                lambda receipt: receipt.update(process_tap_tool=changed_tool),
                "trusted process_tap",
            ),
            (
                lambda receipt: receipt.update(output_route_active=False),
                "active trusted output route",
            ),
            (
                lambda receipt: receipt["binding"].update(source_key=999),
                "binding does not match",
            ),
            (
                lambda receipt: receipt.update(last_sample_monotonic_ns=1_600_000_000),
                "span the PCM frames",
            ),
            (
                lambda receipt: receipt["wav_artifact"].update(
                    ctime_ns=receipt["wav_artifact"]["ctime_ns"] + 1
                ),
                "exact retained artifact generation",
            ),
        )
        for index, (mutation, pattern) in enumerate(cases):
            with self.subTest(pattern=pattern):
                if index:
                    self.tearDown()
                    self.setUp()
                    if pattern == "trusted process_tap":
                        changed_tool = dict(self.tools["process_tap"].as_dict())
                        changed_tool["process_id"] += 1

                        def mutation(receipt):
                            receipt.update(process_tap_tool=changed_tool)
                with self.assertRaisesRegex(raw.RawEvidenceError, pattern):
                    self.validate_audio(
                        self.stage_audio(pcm_wav(), mutate_receipt=mutation)
                    )

    def test_audio_truncated_and_too_short_pcm_fail_closed(self):
        cases = (
            (pcm_wav()[:-4], "truncated"),
            (pcm_wav(seconds=0.1), "too short"),
        )
        for index, (data, pattern) in enumerate(cases):
            with self.subTest(pattern=pattern):
                if index:
                    self.tearDown()
                    self.setUp()
                if pattern == "too short":
                    # Keep receipt interval and stream metadata exact to isolate the floor.
                    with self.assertRaisesRegex(raw.RawEvidenceError, pattern):
                        self.validate_audio(
                            self.stage_audio(data, capture_duration_seconds=0.1)
                        )
                else:
                    with self.assertRaisesRegex(raw.RawEvidenceError, pattern):
                        self.validate_audio(self.stage_audio(data))

    def test_synthetic_tone_and_fake_provenance_without_external_capability_fail(self):
        staged = self.stage_audio(pcm_wav())
        self.seal()
        with self.assertRaisesRegex(raw.RawEvidenceError, "capability"):
            raw.validate_process_audio_wav(
                self.registry,
                wav_reference=staged[0],
                provenance_reference=staged[1],
                expected_binding=self.binding,
                allowed_capture_bounds=self.bounds,
                attestation={"integrity_only": True, "audio_active": True},
            )


if __name__ == "__main__":
    unittest.main()
