#!/usr/bin/env python3

import dataclasses
import hashlib
import json
import os
import plistlib
import struct
import tempfile
import unittest
from unittest import mock
from pathlib import Path

import shipper_identity


def iso_bmff(major=b"isom", compatible=(b"isom", b"avc1"), payload=b"media"):
    brands = major + struct.pack(">I", 0) + b"".join(compatible)
    return struct.pack(">I", 8 + len(brands)) + b"ftyp" + brands + payload


def ebml(doctype, payload=b"media"):
    encoded = doctype.encode("ascii")
    doctype_element = b"\x42\x82" + bytes((0x80 | len(encoded),)) + encoded
    return (
        b"\x1a\x45\xdf\xa3"
        + bytes((0x80 | len(doctype_element),))
        + doctype_element
        + payload
    )


def macho_stub(payload=b""):
    """Return a minimal structurally valid little-endian 64-bit Mach-O."""

    return b"\xcf\xfa\xed\xfe" + struct.pack(
        "<7I",
        0x0100000C,
        0,
        2,
        0,
        0,
        0,
        0,
    ) + payload


def probe_json(
    *,
    video_codec="h264",
    video_profile="High",
    fourcc="avc1",
    pixel_format="yuv420p",
    audio_codec="aac",
    audio_profile="LC",
    format_name="mov,mp4,m4a,3gp,3g2,mj2",
):
    audio = {
        "codec_type": "audio",
        "codec_name": audio_codec,
        "sample_rate": "48000",
        "channels": 2,
        "channel_layout": "stereo",
    }
    if audio_profile is not None:
        audio["profile"] = audio_profile
    return json.dumps(
        {
            "streams": [
                {
                    "codec_type": "video",
                    "codec_name": video_codec,
                    "profile": video_profile,
                    "codec_tag_string": fourcc,
                    "width": 1920,
                    "height": 1080,
                    "pix_fmt": pixel_format,
                    "avg_frame_rate": "30000/1001",
                },
                audio,
            ],
            "format": {
                "format_name": format_name,
                "nb_streams": 2,
                "duration": "12.345000",
            },
        },
        separators=(",", ":"),
    ).encode()


class StaticRunner:
    def __init__(self, stdout=b"", stderr=b"", returncode=0, action=None):
        self.stdout = stdout
        self.stderr = stderr
        self.returncode = returncode
        self.action = action
        self.calls = []

    def __call__(self, argv, pass_fds, timeout_s, max_output_bytes):
        self.calls.append((tuple(argv), pass_fds, timeout_s, max_output_bytes))
        if self.action is not None:
            self.action()
        return shipper_identity.CommandResult(
            self.returncode, self.stdout, self.stderr
        )


class ExternalReceiptIndex:
    """Test factory modelling an externally retained, hash-anchored index."""

    def __new__(cls, evidence_values):
        receipts = []
        for evidence in evidence_values:
            if evidence.execution_receipt_id is None:
                continue
            digest = shipper_identity.command_evidence_sha256(evidence)
            receipts.append({
                "schema": shipper_identity.TRUSTED_COMMAND_RECEIPT_SCHEMA,
                "receipt_id": evidence.execution_receipt_id,
                "command_evidence_sha256": digest,
                "validated_by": "test.external.receipt-index.v1",
                "authentication_validated": True,
                "producer_identity": "test.external.command-attestor.v1",
                "execution_kind": "fd_copied_private_snapshot_v1",
            })
        receipts.sort(
            key=lambda value: (
                value["receipt_id"], value["command_evidence_sha256"]
            )
        )
        value = {
            "schema": shipper_identity.TRUSTED_COMMAND_INDEX_SCHEMA,
            "validator_identity": "test.external.receipt-index.v1",
            "receipts": receipts,
        }
        data = json.dumps(
            value,
            ensure_ascii=False,
            allow_nan=False,
            sort_keys=True,
            separators=(",", ":"),
        ).encode("utf-8")
        return shipper_identity.validate_external_command_receipt_index(
            data,
            expected_index_sha256_from_trust_root=hashlib.sha256(data).hexdigest(),
            expected_validator_identity_from_trust_root=(
                "test.external.receipt-index.v1"
            ),
        )


class IdentityTestCase(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.ffprobe = self.make_tool("ffprobe")
        self.codesign = self.make_tool("codesign")

    def tearDown(self):
        self.temporary.cleanup()

    def make_tool(self, name):
        path = self.root / name
        path.write_bytes((name + " exact tool bytes").encode())
        path.chmod(0o755)
        return path

    def make_script_tool(self, name, *, stdout=b"", stderr=b""):
        path = self.root / name
        if b"'" in stdout or b"'" in stderr:
            raise ValueError("test script output must not contain a single quote")
        script = bytearray(b"#!/bin/sh\n")
        if stdout:
            script.extend(b"printf '%s' '" + stdout + b"'\n")
        if stderr:
            script.extend(b"printf '%s' '" + stderr + b"' >&2\n")
        script.extend(b"exit 0\n")
        path.write_bytes(bytes(script))
        path.chmod(0o755)
        return path

    def capture_asset(self, path, output=None, **kwargs):
        runner = StaticRunner(stdout=output or probe_json())
        identity = shipper_identity.capture_asset_identity(
            path.absolute(),
            ffprobe_path=self.ffprobe.resolve(),
            probe_runner=runner,
            **kwargs,
        )
        return identity, runner

    def make_app(self):
        app = self.root / "WAM.app"
        contents = app / "Contents"
        (contents / "MacOS").mkdir(parents=True)
        (contents / "Resources").mkdir()
        executable = contents / "MacOS" / "WAM"
        executable.write_bytes(macho_stub(b"exact executable bytes"))
        executable.chmod(0o755)
        (contents / "Resources" / "payload.bin").write_bytes(b"payload-v1")
        (contents / "Info.plist").write_bytes(
            plistlib.dumps(
                {
                    "CFBundleIdentifier": "com.wesleymaa.wam",
                    "CFBundleShortVersionString": "1.2.3",
                    "CFBundleVersion": "456",
                    "CFBundleExecutable": "WAM",
                },
                fmt=plistlib.FMT_BINARY,
                sort_keys=True,
            )
        )
        return app

    def receipt_index_for(self, *identities_or_commands):
        commands = []
        for value in identities_or_commands:
            if isinstance(value, shipper_identity.CommandEvidence):
                commands.append(value)
            elif isinstance(value, shipper_identity.AssetIdentity):
                commands.append(value.probe)
            elif isinstance(value, shipper_identity.AppIdentity):
                commands.append(value.codesign)
                commands.extend(leaf.codesign for leaf in value.code_leaves)
            else:
                raise TypeError(f"unsupported receipt fixture {type(value)!r}")
        return ExternalReceiptIndex(commands)


class AssetIdentityTests(IdentityTestCase):
    def test_captures_exact_h264_mp4_and_probe_tool(self):
        asset = self.root / "sample.mp4"
        asset.write_bytes(iso_bmff())

        identity, runner = self.capture_asset(asset)

        self.assertEqual(identity.container, "mp4")
        self.assertEqual(identity.video.codec, "h264")
        self.assertEqual(identity.video.profile, "high")
        self.assertEqual(identity.video.fps_numerator, 30000)
        self.assertEqual(identity.video.fps_denominator, 1001)
        self.assertEqual(identity.audio.codec, "aac")
        self.assertTrue(identity.native_eligible)
        self.assertEqual(identity.file.sha256, hashlib.sha256(asset.read_bytes()).hexdigest())
        self.assertEqual(identity.probe_raw_json, probe_json().decode())
        self.assertEqual(
            identity.probe.tool.sha256,
            hashlib.sha256(self.ffprobe.read_bytes()).hexdigest(),
        )
        argv, pass_fds, _, _ = runner.calls[0]
        self.assertEqual(argv[0], str(self.ffprobe.resolve()))
        self.assertEqual(pass_fds, (int(argv[-1].rsplit("/", 1)[1]),))

    def test_default_bounded_runner_retains_exact_probe_json(self):
        asset = self.root / "sample.mp4"
        asset.write_bytes(iso_bmff())
        raw = probe_json()
        fake_probe = self.root / "absolute-ffprobe"
        fake_probe.write_bytes(macho_stub(b"probe"))
        fake_probe.chmod(0o755)
        def produce_probe(argv, pass_fds, timeout_s, max_output_bytes):
            return shipper_identity.CommandResult(0, raw, b"")
        with mock.patch.object(
            shipper_identity, "_bounded_command_runner", produce_probe
        ):
            identity = shipper_identity.capture_asset_identity(
                asset.resolve(),
                ffprobe_path=fake_probe.resolve(),
            )

        self.assertEqual(identity.probe_raw_json.encode(), raw)
        self.assertEqual(identity.probe.stdout_bytes, len(raw))
        self.assertTrue(identity.probe.trusted_execution)
        shipper_identity.validate_asset_identity_for_shipping(
            identity,
            expected_probe_tool=identity.probe.tool,
            trusted_receipt_index=self.receipt_index_for(identity),
        )
        self.assertEqual(identity.probe.sanitized_environment, (
            ("LANG", "C"),
            ("LC_ALL", "C"),
            ("PATH", "/usr/bin:/bin"),
        ))
        self.assertEqual(identity.probe.pass_fds, (identity.probe.targets[0].descriptor,))

    def test_structurally_distinguishes_mov_from_mp4(self):
        asset = self.root / "misleading.mp4"
        asset.write_bytes(iso_bmff(major=b"qt  ", compatible=(b"qt  ",)))

        identity, _ = self.capture_asset(asset)

        self.assertEqual(identity.container, "mov")
        self.assertEqual(identity.structural_detail, "ftyp:qt")

    def test_relabelled_ebml_uses_doctype_not_extension(self):
        asset = self.root / "actually-matroska.mp4"
        asset.write_bytes(ebml("matroska"))
        output = probe_json(format_name="matroska,webm")

        identity, _ = self.capture_asset(asset, output)

        self.assertEqual(identity.container, "mkv")
        self.assertEqual(identity.structural_detail, "ebml:matroska")

    def test_webm_fallback_is_staged_and_not_native(self):
        app = self.make_app()
        asset = app / "Contents" / "Resources" / "fallback.webm"
        asset.write_bytes(ebml("webm"))
        output = probe_json(
            video_codec="vp9",
            video_profile="Profile 0",
            fourcc="[0][0][0][0]",
            audio_codec="opus",
            audio_profile=None,
            format_name="matroska,webm",
        )

        app_identity = shipper_identity.capture_app_identity(
            app.resolve(),
            codesign_path=self.codesign.resolve(),
            codesign_runner=StaticRunner(),
        )
        identity, _ = self.capture_asset(
            asset,
            output,
            staged_app_identity=app_identity,
        )

        self.assertEqual(identity.container, "webm")
        self.assertTrue(identity.contained_in_staged_app)
        self.assertEqual(
            identity.staged_app_binding.app_identity_sha256,
            app_identity.candidate_sha256,
        )
        self.assertFalse(identity.native_eligible)
        self.assertIn("video codec is not H.264 or HEVC", identity.native_ineligibility_reasons)
        self.assertIn("audio codec is not AAC", identity.native_ineligibility_reasons)

    def test_hevc_bit_depth_is_derived_from_an_exact_pixel_format(self):
        asset = self.root / "main10.mp4"
        asset.write_bytes(iso_bmff(compatible=(b"isom", b"hvc1")))

        valid, _ = self.capture_asset(
            asset,
            probe_json(
                video_codec="hevc",
                video_profile="Main 10",
                fourcc="hvc1",
                pixel_format="yuv420p10le",
            ),
        )
        self.assertTrue(valid.native_eligible)

        for ambiguous_or_eight_bit in ("yuv410p", "yuv420p", "gbrp10le"):
            with self.subTest(pixel_format=ambiguous_or_eight_bit):
                observed, _ = self.capture_asset(
                    asset,
                    probe_json(
                        video_codec="hevc",
                        video_profile="Main 10",
                        fourcc="hvc1",
                        pixel_format=ambiguous_or_eight_bit,
                    ),
                )
                self.assertFalse(observed.native_eligible)

        main_eight, _ = self.capture_asset(
            asset,
            probe_json(
                video_codec="hevc",
                video_profile="Main",
                fourcc="hvc1",
                pixel_format="yuv420p",
            ),
        )
        self.assertTrue(main_eight.native_eligible)
        main_ten, _ = self.capture_asset(
            asset,
            probe_json(
                video_codec="hevc",
                video_profile="Main",
                fourcc="hvc1",
                pixel_format="p010le",
            ),
        )
        self.assertFalse(main_ten.native_eligible)

    def test_all_nine_native_shipping_variants_are_derived_from_exact_probe_facts(self):
        variants = (
            ("h264", "mp4", "High", "avc1", "yuv420p", "mov,mp4", iso_bmff()),
            ("h264", "mov", "High", "avc1", "yuv420p", "mov", iso_bmff(b"qt  ", (b"qt  ",))),
            ("h264", "mkv", "High", "avc1", "yuv420p", "matroska", ebml("matroska")),
            ("hevc", "mp4", "Main", "hvc1", "yuv420p", "mov,mp4", iso_bmff(compatible=(b"isom", b"hvc1"))),
            ("hevc", "mov", "Main", "hvc1", "yuv420p", "mov", iso_bmff(b"qt  ", (b"qt  ",))),
            ("hevc", "mkv", "Main", "hev1", "yuv420p", "matroska", ebml("matroska")),
            ("hevc", "mp4", "Main 10", "hvc1", "yuv420p10le", "mov,mp4", iso_bmff(compatible=(b"isom", b"hvc1"))),
            ("hevc", "mov", "Main 10", "hvc1", "p010le", "mov", iso_bmff(b"qt  ", (b"qt  ",))),
            ("hevc", "mkv", "Main 10", "hev1", "p010le", "matroska", ebml("matroska")),
        )
        for index, (codec, container, profile, fourcc, pixfmt, fmt, payload) in enumerate(variants):
            with self.subTest(codec=codec, container=container, profile=profile):
                asset = self.root / f"matrix-{index}"
                asset.write_bytes(payload)
                identity, _ = self.capture_asset(
                    asset,
                    probe_json(
                        video_codec=codec,
                        video_profile=profile,
                        fourcc=fourcc,
                        pixel_format=pixfmt,
                        format_name=fmt,
                    ),
                )
                self.assertEqual(identity.container, container)
                self.assertTrue(identity.native_eligible)
                self.assertEqual(identity.video.fps_numerator, 30000)
                self.assertEqual(identity.video.fps_denominator, 1001)

    def test_native_matrix_rejects_wrong_fourcc_profile_pixel_depth_or_audio(self):
        asset = self.root / "negative.mp4"
        asset.write_bytes(iso_bmff(compatible=(b"isom", b"hvc1")))
        cases = (
            {"fourcc": "hev1"},
            {"video_profile": "Rext"},
            {"video_profile": "Main 10", "pixel_format": "yuv410p"},
            {"audio_codec": "opus", "audio_profile": None},
        )
        for changes in cases:
            with self.subTest(changes=changes):
                values = {
                    "video_codec": "hevc",
                    "video_profile": "Main",
                    "fourcc": "hvc1",
                    "pixel_format": "yuv420p",
                }
                values.update(changes)
                identity, _ = self.capture_asset(asset, probe_json(**values))
                self.assertFalse(identity.native_eligible)

    def test_rejects_asset_symlink(self):
        real = self.root / "real.mp4"
        real.write_bytes(iso_bmff())
        linked = self.root / "linked.mp4"
        linked.symlink_to(real.name)

        with self.assertRaisesRegex(shipper_identity.IdentityError, "without following"):
            self.capture_asset(linked)

    def test_rejects_in_place_mutation_during_probe(self):
        asset = self.root / "sample.mp4"
        asset.write_bytes(iso_bmff())

        def mutate():
            with asset.open("r+b") as stream:
                stream.seek(-1, os.SEEK_END)
                stream.write(b"X")
                stream.flush()
                os.fsync(stream.fileno())

        runner = StaticRunner(stdout=probe_json(), action=mutate)
        with self.assertRaisesRegex(shipper_identity.IdentityError, "changed"):
            shipper_identity.capture_asset_identity(
                asset.resolve(),
                ffprobe_path=self.ffprobe.resolve(),
                probe_runner=runner,
            )

    def test_rejects_path_replacement_during_probe(self):
        asset = self.root / "sample.mp4"
        asset.write_bytes(iso_bmff(payload=b"old!!"))

        def replace():
            replacement = self.root / "replacement"
            replacement.write_bytes(iso_bmff(payload=b"new!!"))
            os.replace(replacement, asset)

        runner = StaticRunner(stdout=probe_json(), action=replace)
        with self.assertRaises(shipper_identity.IdentityError):
            shipper_identity.capture_asset_identity(
                asset.resolve(),
                ffprobe_path=self.ffprobe.resolve(),
                probe_runner=runner,
            )

    def test_rejects_asset_ancestor_symlink_rebind(self):
        left = self.root / "left"
        right = self.root / "right"
        left.mkdir()
        right.mkdir()
        (left / "sample.mp4").write_bytes(iso_bmff(payload=b"left"))
        (right / "sample.mp4").write_bytes(iso_bmff(payload=b"right"))
        linked = self.root / "linked-dir"
        linked.symlink_to(left.name)

        def rebind():
            linked.unlink()
            linked.symlink_to(right.name)

        runner = StaticRunner(stdout=probe_json(), action=rebind)
        with self.assertRaisesRegex(shipper_identity.IdentityError, "rebound"):
            shipper_identity.capture_asset_identity(
                (linked / "sample.mp4").absolute(),
                ffprobe_path=self.ffprobe.resolve(),
                probe_runner=runner,
            )

    def test_rejects_malformed_and_ambiguous_probe(self):
        asset = self.root / "sample.mp4"
        asset.write_bytes(iso_bmff())
        malformed = b'{"streams":[],"streams":[],"format":{}}'

        with self.assertRaisesRegex(shipper_identity.IdentityError, "duplicate key"):
            self.capture_asset(asset, malformed)

        value = json.loads(probe_json())
        value["streams"].append({"codec_type": "subtitle"})
        with self.assertRaisesRegex(shipper_identity.IdentityError, "exactly one"):
            self.capture_asset(asset, json.dumps(value).encode())

    def test_rejects_probe_container_claim_inconsistent_with_structure(self):
        asset = self.root / "sample.mp4"
        asset.write_bytes(iso_bmff())

        with self.assertRaisesRegex(shipper_identity.IdentityError, "inconsistent"):
            self.capture_asset(asset, probe_json(format_name="matroska,webm"))

    def test_rejects_runner_output_beyond_bound(self):
        asset = self.root / "sample.mp4"
        asset.write_bytes(iso_bmff())

        with self.assertRaisesRegex(shipper_identity.IdentityError, "beyond"):
            self.capture_asset(
                asset,
                b"{}" * 20,
                max_probe_output_bytes=8,
            )

    def test_injected_evidence_cannot_be_upgraded_to_shipping_evidence(self):
        asset = self.root / "sample.mp4"
        asset.write_bytes(iso_bmff())
        identity, _ = self.capture_asset(asset)

        self.assertFalse(identity.probe.trusted_execution)
        with self.assertRaisesRegex(shipper_identity.IdentityError, "injected"):
            shipper_identity.validate_asset_identity_for_shipping(
                identity,
                expected_probe_tool=identity.probe.tool,
                trusted_receipt_index=None,
            )
        forged = dataclasses.replace(identity.probe, trusted_execution=True)
        forged_tool = dataclasses.replace(
            forged.tool,
            sha256=hashlib.sha256(b"\xcf\xfa\xed\xfeforged").hexdigest(),
        )
        forged = dataclasses.replace(forged, tool=forged_tool)
        with self.assertRaises(shipper_identity.IdentityError):
            shipper_identity.validate_command_evidence_for_shipping(
                forged, trusted_receipt_index=None
            )

    def test_production_evidence_seal_detects_post_capture_rewrite(self):
        asset = self.root / "sample.mp4"
        asset.write_bytes(iso_bmff())
        probe = self.root / "production-ffprobe"
        probe.write_bytes(macho_stub(b"probe"))
        probe.chmod(0o755)
        def produce_probe(argv, pass_fds, timeout_s, max_output_bytes):
            return shipper_identity.CommandResult(0, probe_json(), b"")
        with mock.patch.object(
            shipper_identity, "_bounded_command_runner", produce_probe
        ):
            identity = shipper_identity.capture_asset_identity(
                asset.resolve(), ffprobe_path=probe.resolve()
            )

        rewritten = dataclasses.replace(identity.probe, stdout_text="{}")
        with self.assertRaisesRegex(shipper_identity.IdentityError, "absent"):
            shipper_identity.validate_command_evidence_for_shipping(
                rewritten,
                trusted_receipt_index=self.receipt_index_for(identity),
            )

        fake_expected = dataclasses.replace(identity.probe.tool, sha256="0" * 64)
        with self.assertRaisesRegex(shipper_identity.IdentityError, "expected tool"):
            shipper_identity.validate_command_evidence_for_shipping(
                identity.probe,
                trusted_receipt_index=self.receipt_index_for(identity),
                expected_tool=fake_expected,
            )

    def test_plain_mapping_or_fake_index_cannot_authenticate_execution(self):
        asset = self.root / "sample.mp4"
        asset.write_bytes(iso_bmff())
        probe = self.root / "production-ffprobe"
        probe.write_bytes(macho_stub(b"probe"))
        probe.chmod(0o755)
        def produce_probe(argv, pass_fds, timeout_s, max_output_bytes):
            return shipper_identity.CommandResult(0, probe_json(), b"")
        with mock.patch.object(shipper_identity, "_bounded_command_runner", produce_probe):
            identity = shipper_identity.capture_asset_identity(
                asset.resolve(), ffprobe_path=probe.resolve()
            )

        class FakeIndex:
            validator_identity = "fake"
            def resolve(self, receipt_id, evidence_sha256):
                return {
                    "schema": shipper_identity.TRUSTED_COMMAND_RECEIPT_SCHEMA,
                    "receipt_id": receipt_id,
                    "command_evidence_sha256": evidence_sha256,
                    "validated_by": "fake",
                    "authentication_validated": True,
                    "producer_identity": "fake",
                    "execution_kind": "fd_copied_private_snapshot_v1",
                }

        for fake in ({}, FakeIndex()):
            with self.subTest(fake=type(fake).__name__):
                with self.assertRaisesRegex(shipper_identity.IdentityError, "externally anchored"):
                    shipper_identity.validate_command_evidence_for_shipping(
                        identity.probe, trusted_receipt_index=fake
                    )

    def test_external_receipt_uuid_binds_exactly_one_evidence_digest(self):
        receipt_id = "d73ecde6-171e-4f22-bd03-894ad40e4186"
        receipts = []
        for digest in ("1" * 64, "2" * 64):
            receipts.append(
                {
                    "schema": shipper_identity.TRUSTED_COMMAND_RECEIPT_SCHEMA,
                    "receipt_id": receipt_id,
                    "command_evidence_sha256": digest,
                    "validated_by": "test.external.receipt-index.v1",
                    "authentication_validated": True,
                    "producer_identity": "test.external.command-attestor.v1",
                    "execution_kind": "fd_copied_private_snapshot_v1",
                }
            )
        value = {
            "schema": shipper_identity.TRUSTED_COMMAND_INDEX_SCHEMA,
            "validator_identity": "test.external.receipt-index.v1",
            "receipts": receipts,
        }
        data = json.dumps(
            value,
            ensure_ascii=False,
            allow_nan=False,
            sort_keys=True,
            separators=(",", ":"),
        ).encode("utf-8")
        with self.assertRaisesRegex(shipper_identity.IdentityError, "unique"):
            shipper_identity.validate_external_command_receipt_index(
                data,
                expected_index_sha256_from_trust_root=hashlib.sha256(data).hexdigest(),
                expected_validator_identity_from_trust_root=(
                    "test.external.receipt-index.v1"
                ),
            )

    def test_rejects_tool_ancestor_rebind_during_execution(self):
        asset = self.root / "sample.mp4"
        asset.write_bytes(iso_bmff())
        tool_parent = self.root / "tool-parent"
        tool_parent.mkdir()
        tool = tool_parent / "ffprobe"
        tool.write_bytes(b"exact tool")
        tool.chmod(0o755)

        def rebind():
            retired = self.root / "retired-tool-parent"
            tool_parent.rename(retired)
            tool_parent.mkdir()
            replacement = tool_parent / "ffprobe"
            replacement.write_bytes(b"exact tool")
            replacement.chmod(0o755)

        with self.assertRaisesRegex(shipper_identity.IdentityError, "rebound|changed"):
            shipper_identity.capture_asset_identity(
                asset.resolve(),
                ffprobe_path=tool.resolve(),
                probe_runner=StaticRunner(stdout=probe_json(), action=rebind),
            )

    def test_shipping_validation_rejects_asset_ancestor_aba_with_same_inode(self):
        left = self.root / "left"
        right = self.root / "right"
        left.mkdir()
        right.mkdir()
        source = left / "sample.mp4"
        source.write_bytes(iso_bmff())
        os.link(source, right / "sample.mp4")
        probe = self.root / "real-ffprobe"
        probe.write_bytes(macho_stub(b"probe"))
        probe.chmod(0o755)
        def produce_probe(argv, pass_fds, timeout_s, max_output_bytes):
            return shipper_identity.CommandResult(0, probe_json(), b"")
        with mock.patch.object(shipper_identity, "_bounded_command_runner", produce_probe):
            identity = shipper_identity.capture_asset_identity(
                source.resolve(), ffprobe_path=probe.resolve()
            )
        left.rename(self.root / "retired-left")
        right.rename(left)

        with self.assertRaisesRegex(shipper_identity.IdentityError, "stale|rebound"):
            shipper_identity.validate_asset_identity_for_shipping(
                identity,
                expected_probe_tool=identity.probe.tool,
                trusted_receipt_index=self.receipt_index_for(identity),
            )

    def test_shipping_validation_rejects_unsnapshotted_script_interpreter(self):
        asset = self.root / "sample.mp4"
        asset.write_bytes(iso_bmff())
        probe = self.make_script_tool("script-ffprobe", stdout=probe_json())
        identity = shipper_identity.capture_asset_identity(
            asset.resolve(), ffprobe_path=probe.resolve()
        )
        with self.assertRaisesRegex(shipper_identity.IdentityError, "Mach-O"):
            shipper_identity.validate_asset_identity_for_shipping(
                identity,
                expected_probe_tool=identity.probe.tool,
                trusted_receipt_index=self.receipt_index_for(identity),
            )

    def test_rejects_private_tool_snapshot_or_root_mutation_after_exec(self):
        asset = self.root / "sample.mp4"
        asset.write_bytes(iso_bmff())
        probe = self.make_script_tool("production-ffprobe", stdout=probe_json())

        def mutate_tool(argv, pass_fds, timeout_s, max_output_bytes):
            Path(argv[0]).chmod(0o700)
            return shipper_identity.CommandResult(0, probe_json(), b"")

        with mock.patch.object(shipper_identity, "_bounded_command_runner", mutate_tool):
            with self.assertRaisesRegex(shipper_identity.IdentityError, "snapshot changed"):
                shipper_identity.capture_asset_identity(
                    asset.resolve(), ffprobe_path=probe.resolve()
                )

        def mutate_root(argv, pass_fds, timeout_s, max_output_bytes):
            Path(argv[0]).parent.chmod(0o755)
            return shipper_identity.CommandResult(0, probe_json(), b"")

        with mock.patch.object(shipper_identity, "_bounded_command_runner", mutate_root):
            with self.assertRaisesRegex(shipper_identity.IdentityError, "snapshot root changed"):
                shipper_identity.capture_asset_identity(
                    asset.resolve(), ffprobe_path=probe.resolve()
                )

    def test_path_only_staging_is_permanently_rejected(self):
        app = self.make_app()
        asset = app / "Contents" / "Resources" / "fallback.webm"
        asset.write_bytes(ebml("webm"))
        with self.assertRaisesRegex(shipper_identity.IdentityError, "not sufficient"):
            self.capture_asset(
                asset,
                probe_json(
                    video_codec="vp9",
                    video_profile="Profile 0",
                    fourcc="[0][0][0][0]",
                    audio_codec="opus",
                    audio_profile=None,
                    format_name="matroska,webm",
                ),
                staged_app_path=app.resolve(),
            )

    def test_staged_asset_rejects_unrelated_candidate_generation_change(self):
        app = self.make_app()
        asset = app / "Contents" / "Resources" / "fallback.webm"
        asset.write_bytes(ebml("webm"))
        app_identity = shipper_identity.capture_app_identity(
            app.resolve(),
            codesign_path=self.codesign.resolve(),
            codesign_runner=StaticRunner(),
        )
        (app / "Contents" / "Resources" / "payload.bin").write_bytes(b"unrelated-v2")

        with self.assertRaisesRegex(shipper_identity.IdentityError, "changed"):
            self.capture_asset(
                asset,
                probe_json(
                    video_codec="vp9",
                    video_profile="Profile 0",
                    fourcc="[0][0][0][0]",
                    audio_codec="opus",
                    audio_profile=None,
                    format_name="matroska,webm",
                ),
                staged_app_identity=app_identity,
            )

    def test_trusted_fallback_joins_exact_trusted_app_identity(self):
        app = self.make_app()
        asset = app / "Contents" / "Resources" / "fallback.webm"
        asset.write_bytes(ebml("webm"))
        def successful_system_tool(argv, pass_fds, timeout_s, max_output_bytes):
            return shipper_identity.CommandResult(0, b"", b"")

        with mock.patch.object(
            shipper_identity, "_bounded_command_runner", successful_system_tool
        ):
            app_identity = shipper_identity.capture_app_identity(
                app.resolve(), codesign_path=Path("/usr/bin/codesign")
            )
        fallback_probe = probe_json(
            video_codec="vp9",
            video_profile="Profile 0",
            fourcc="[0][0][0][0]",
            audio_codec="opus",
            audio_profile=None,
            format_name="matroska,webm",
        )
        probe = self.root / "real-ffprobe"
        probe.write_bytes(macho_stub(b"probe"))
        probe.chmod(0o755)
        def produce_fallback_probe(argv, pass_fds, timeout_s, max_output_bytes):
            return shipper_identity.CommandResult(0, fallback_probe, b"")
        with mock.patch.object(
            shipper_identity, "_bounded_command_runner", produce_fallback_probe
        ):
            identity = shipper_identity.capture_asset_identity(
                asset.resolve(),
                ffprobe_path=probe.resolve(),
                staged_app_identity=app_identity,
            )

        shipper_identity.validate_asset_identity_for_shipping(
            identity,
            expected_probe_tool=identity.probe.tool,
            trusted_receipt_index=self.receipt_index_for(identity, app_identity),
            staged_app_identity=app_identity,
        )
        self.assertEqual(
            identity.staged_app_binding.manifest_tree_sha256,
            app_identity.manifest.tree_sha256,
        )

    def test_shipping_validator_rejects_wrong_staged_fallback_codec(self):
        app = self.make_app()
        asset = app / "Contents" / "Resources" / "fallback.webm"
        asset.write_bytes(ebml("webm"))
        def successful_system_tool(argv, pass_fds, timeout_s, max_output_bytes):
            return shipper_identity.CommandResult(0, b"", b"")
        with mock.patch.object(
            shipper_identity, "_bounded_command_runner", successful_system_tool
        ):
            app_identity = shipper_identity.capture_app_identity(
                app.resolve(), codesign_path=Path("/usr/bin/codesign")
            )
        wrong_output = probe_json(
            video_codec="av1",
            video_profile="Main",
            fourcc="av01",
            audio_codec="opus",
            audio_profile=None,
            format_name="webm",
        )
        probe = self.root / "real-ffprobe"
        probe.write_bytes(macho_stub(b"probe"))
        probe.chmod(0o755)
        def produce_probe(argv, pass_fds, timeout_s, max_output_bytes):
            return shipper_identity.CommandResult(0, wrong_output, b"")
        with mock.patch.object(shipper_identity, "_bounded_command_runner", produce_probe):
            identity = shipper_identity.capture_asset_identity(
                asset.resolve(),
                ffprobe_path=probe.resolve(),
                staged_app_identity=app_identity,
            )
        with self.assertRaisesRegex(shipper_identity.IdentityError, "exact VP9"):
            shipper_identity.validate_asset_identity_for_shipping(
                identity,
                expected_probe_tool=identity.probe.tool,
                trusted_receipt_index=self.receipt_index_for(identity, app_identity),
                staged_app_identity=app_identity,
            )

    def test_validator_rederives_outer_asset_and_rejects_fallback_relabel(self):
        asset = self.root / "fallback.webm"
        asset.write_bytes(ebml("webm"))
        output = probe_json(
            video_codec="vp9",
            video_profile="Profile 0",
            fourcc="[0][0][0][0]",
            audio_codec="opus",
            audio_profile=None,
            format_name="matroska,webm",
        )
        probe = self.root / "real-ffprobe"
        probe.write_bytes(macho_stub(b"probe"))
        probe.chmod(0o755)
        def produce_probe(argv, pass_fds, timeout_s, max_output_bytes):
            return shipper_identity.CommandResult(0, output, b"")
        with mock.patch.object(shipper_identity, "_bounded_command_runner", produce_probe):
            identity = shipper_identity.capture_asset_identity(
                asset.resolve(), ffprobe_path=probe.resolve()
            )
        with self.assertRaisesRegex(shipper_identity.IdentityError, "staged app binding"):
            shipper_identity.validate_asset_identity_for_shipping(
                identity,
                expected_probe_tool=identity.probe.tool,
                trusted_receipt_index=self.receipt_index_for(identity),
            )
        relabelled = dataclasses.replace(
            identity,
            native_eligible=True,
            native_ineligibility_reasons=(),
        )
        with self.assertRaisesRegex(shipper_identity.IdentityError, "exact probe"):
            shipper_identity.validate_asset_identity_for_shipping(
                relabelled,
                expected_probe_tool=relabelled.probe.tool,
                trusted_receipt_index=self.receipt_index_for(identity),
            )

        forged_file = dataclasses.replace(
            identity.file,
            sha256="0" * 64,
        )
        forged = dataclasses.replace(identity, file=forged_file)
        with self.assertRaisesRegex(shipper_identity.IdentityError, "bound|stale"):
            shipper_identity.validate_asset_identity_for_shipping(
                forged,
                expected_probe_tool=forged.probe.tool,
                trusted_receipt_index=self.receipt_index_for(identity),
            )

    def test_validator_rejects_outer_staging_fields_without_binding(self):
        asset = self.root / "sample.mp4"
        asset.write_bytes(iso_bmff())
        probe = self.root / "real-ffprobe"
        probe.write_bytes(macho_stub(b"probe"))
        probe.chmod(0o755)
        def produce_probe(argv, pass_fds, timeout_s, max_output_bytes):
            return shipper_identity.CommandResult(0, probe_json(), b"")
        with mock.patch.object(shipper_identity, "_bounded_command_runner", produce_probe):
            identity = shipper_identity.capture_asset_identity(
                asset.resolve(), ffprobe_path=probe.resolve()
            )

        for forged in (
            dataclasses.replace(identity, staged_app_path="/tmp/forged.app"),
            dataclasses.replace(identity, contained_in_staged_app=True),
        ):
            with self.subTest(forged=forged):
                with self.assertRaisesRegex(shipper_identity.IdentityError, "inconsistent"):
                    shipper_identity.validate_asset_identity_for_shipping(
                        forged,
                        expected_probe_tool=forged.probe.tool,
                        trusted_receipt_index=self.receipt_index_for(identity),
                    )


class AppIdentityTests(IdentityTestCase):
    def test_captures_manifest_executable_plist_and_strict_codesign(self):
        app = self.make_app()
        runner = StaticRunner(stderr=b"valid on disk\nsatisfies its Designated Requirement\n")

        identity = shipper_identity.capture_app_identity(
            app.resolve(),
            codesign_path=self.codesign.resolve(),
            codesign_runner=runner,
        )

        self.assertEqual(identity.bundle_identifier, "com.wesleymaa.wam")
        self.assertEqual(identity.bundle_short_version, "1.2.3")
        self.assertEqual(identity.bundle_version, "456")
        self.assertEqual(identity.executable_relative_path, "MacOS/WAM")
        self.assertEqual(len(identity.manifest.tree_sha256), 64)
        self.assertEqual(
            identity.codesign.stderr_text,
            "valid on disk\nsatisfies its Designated Requirement\n",
        )
        self.assertEqual(len(identity.code_leaves), 1)
        self.assertEqual(identity.code_leaves[0].relative_path, "MacOS/WAM")
        self.assertEqual(len(runner.calls), 2)
        argv = runner.calls[-1][0]
        self.assertEqual(
            argv[1:-1],
            (
                "--verify",
                "--deep",
                "--strict=all",
                "--all-architectures",
                "--verbose=4",
            ),
        )
        self.assertTrue(argv[-1].endswith("/candidate.app"))
        self.assertEqual(identity.codesign.argv[-1], str(app.resolve()))
        self.assertFalse(identity.codesign.trusted_execution)
        with self.assertRaisesRegex(shipper_identity.IdentityError, "injected"):
            shipper_identity.validate_app_identity_for_shipping(
                identity, trusted_receipt_index=None
            )

    def test_records_safe_internal_symlink_without_following_it(self):
        app = self.make_app()
        versions = app / "Contents" / "Frameworks" / "Demo.framework" / "Versions"
        (versions / "A").mkdir(parents=True)
        (versions / "A" / "Demo").write_bytes(b"framework")
        (versions / "Current").symlink_to("A")

        manifest = shipper_identity.capture_contents_manifest(app.resolve())

        link = next(
            entry
            for entry in manifest.entries
            if entry.path.endswith("Versions/Current")
        )
        self.assertEqual(link.kind, "symlink")
        self.assertEqual(link.symlink_target, "A")

    def test_resolves_valid_nested_internal_symlinks_component_by_component(self):
        app = self.make_app()
        resources = app / "Contents" / "Resources"
        (resources / "real").mkdir()
        (resources / "real" / "file").write_bytes(b"value")
        (resources / "directory-link").symlink_to("real")
        (resources / "file-link").symlink_to("directory-link/file")

        manifest = shipper_identity.capture_contents_manifest(app.resolve())
        self.assertEqual(
            next(entry for entry in manifest.entries if entry.path == "Resources/file-link").kind,
            "symlink",
        )

    def test_rejects_absolute_symlink_even_when_target_is_inside_contents(self):
        app = self.make_app()
        payload = app / "Contents" / "Resources" / "payload.bin"
        (app / "Contents" / "Resources" / "absolute").symlink_to(payload.resolve())

        with self.assertRaisesRegex(shipper_identity.IdentityError, "absolute"):
            shipper_identity.capture_contents_manifest(app.resolve())

    def test_rejects_lexical_leave_then_reentry_symlink(self):
        app = self.make_app()
        resources = app / "Contents" / "Resources"
        (resources / "reentry").symlink_to("../../Contents/Resources/payload.bin")

        with self.assertRaisesRegex(shipper_identity.IdentityError, "escapes Contents"):
            shipper_identity.capture_contents_manifest(app.resolve())

    def test_rejects_missing_or_non_directory_symlink_hop(self):
        app = self.make_app()
        resources = app / "Contents" / "Resources"
        (resources / "missing-hop").symlink_to("missing/file")
        with self.assertRaisesRegex(shipper_identity.IdentityError, "dangling"):
            shipper_identity.capture_contents_manifest(app.resolve())
        (resources / "missing-hop").unlink()
        (resources / "non-directory-hop").symlink_to("payload.bin/child")
        with self.assertRaisesRegex(shipper_identity.IdentityError, "non-directory"):
            shipper_identity.capture_contents_manifest(app.resolve())

    def test_rejects_escaping_bundle_symlink(self):
        app = self.make_app()
        (app / "Contents" / "Resources" / "escape").symlink_to("../../../outside")

        with self.assertRaisesRegex(shipper_identity.IdentityError, "escapes Contents"):
            shipper_identity.capture_contents_manifest(app.resolve())

    def test_rejects_intermediate_symlink_then_parent_escape(self):
        app = self.make_app()
        resources = app / "Contents" / "Resources"
        (resources / "dir").mkdir()
        (resources / "top").mkdir()
        (resources / "dir" / "link").symlink_to("../top")
        (resources / "s").symlink_to("dir/link/../../../../outside")

        with self.assertRaisesRegex(shipper_identity.IdentityError, "escapes Contents"):
            shipper_identity.capture_contents_manifest(app.resolve())

    def test_rejects_parent_resolution_after_nested_symlink_expansion(self):
        app = self.make_app()
        contents = app / "Contents"
        resources = contents / "Resources"
        (contents / "X").mkdir()
        (resources / "a").mkdir()
        (resources / "a" / "link").symlink_to("../../X")
        (resources / "s").symlink_to("a/link/../..")

        with self.assertRaisesRegex(shipper_identity.IdentityError, "escapes Contents"):
            shipper_identity.capture_contents_manifest(app.resolve())

    def test_manifest_binds_app_root_mode_flags_and_extended_metadata(self):
        app = self.make_app()
        before = shipper_identity.capture_contents_manifest(app.resolve())
        app.chmod(0o700)
        after_mode = shipper_identity.capture_contents_manifest(app.resolve())
        with self.assertRaisesRegex(shipper_identity.IdentityError, "changed"):
            shipper_identity.verify_contents_manifest_unchanged(before, after_mode)

        app.chmod(0o755)
        before_xattr = shipper_identity.capture_contents_manifest(app.resolve())
        import subprocess
        subprocess.run(
            ["/usr/bin/xattr", "-w", "com.wam.identity-test", "changed", str(app)],
            check=True,
        )
        try:
            after_xattr = shipper_identity.capture_contents_manifest(app.resolve())
            with self.assertRaisesRegex(shipper_identity.IdentityError, "changed"):
                shipper_identity.verify_contents_manifest_unchanged(
                    before_xattr, after_xattr
                )
        finally:
            subprocess.run(
                ["/usr/bin/xattr", "-d", "com.wam.identity-test", str(app)],
                check=True,
            )

    def test_manifest_verifier_binds_every_app_root_stat_field(self):
        app = self.make_app()
        before = shipper_identity.capture_contents_manifest(app.resolve())
        for field in (
            "device",
            "inode",
            "mode",
            "uid",
            "gid",
            "size_bytes",
            "mtime_ns",
            "ctime_ns",
            "birthtime_ns",
            "flags",
        ):
            forged_stat = dataclasses.replace(
                before.app_root_stat,
                **{field: getattr(before.app_root_stat, field) + 1},
            )
            forged = dataclasses.replace(before, app_root_stat=forged_stat)
            with self.subTest(field=field):
                with self.assertRaisesRegex(shipper_identity.IdentityError, "changed"):
                    shipper_identity.verify_contents_manifest_unchanged(before, forged)

    def test_manifest_detects_top_level_app_change_outside_contents(self):
        app = self.make_app()
        shipper_identity.capture_contents_manifest(app.resolve())
        (app / "top-level-generation-change").write_bytes(b"not under Contents")
        with self.assertRaisesRegex(shipper_identity.IdentityError, "only exact Contents"):
            shipper_identity.capture_contents_manifest(app.resolve())

    def test_rejects_any_app_root_entry_outside_exact_contents(self):
        app = self.make_app()
        (app / "outside.bin").write_bytes(b"AAAA")
        with self.assertRaisesRegex(shipper_identity.IdentityError, "only exact Contents"):
            shipper_identity.capture_contents_manifest(app.resolve())

    def test_symlink_generation_change_between_manifest_passes_is_rejected(self):
        app = self.make_app()
        resources = app / "Contents" / "Resources"
        (resources / "a").write_bytes(b"a")
        (resources / "b").write_bytes(b"b")
        link = resources / "current"
        link.symlink_to("a")
        original = shipper_identity._capture_contents_manifest_once
        calls = 0

        def capture_then_rebind(path):
            nonlocal calls
            result = original(path)
            calls += 1
            if calls == 1:
                link.unlink()
                link.symlink_to("b")
            return result

        with mock.patch.object(
            shipper_identity,
            "_capture_contents_manifest_once",
            capture_then_rebind,
        ):
            with self.assertRaisesRegex(shipper_identity.IdentityError, "changed"):
                shipper_identity.capture_contents_manifest(app.resolve())

    def test_rejects_dangling_and_cyclic_bundle_symlinks(self):
        app = self.make_app()
        resources = app / "Contents" / "Resources"
        (resources / "dangling").symlink_to("missing")
        with self.assertRaisesRegex(shipper_identity.IdentityError, "dangling"):
            shipper_identity.capture_contents_manifest(app.resolve())
        (resources / "dangling").unlink()
        (resources / "one").symlink_to("two")
        (resources / "two").symlink_to("one")
        with self.assertRaisesRegex(shipper_identity.IdentityError, "cycle"):
            shipper_identity.capture_contents_manifest(app.resolve())

    def test_rejects_symlink_to_its_parent_or_ancestor_directory(self):
        for target in (".", ".."):
            with self.subTest(target=target):
                app = self.root / f"cycle-{target.replace('.', 'dot')}.app"
                contents = app / "Contents"
                (contents / "MacOS").mkdir(parents=True)
                resources = contents / "Resources"
                resources.mkdir()
                (contents / "Info.plist").write_bytes(b"plist")
                resources = app / "Contents" / "Resources"
                (resources / "self").symlink_to(target)
                with self.assertRaisesRegex(shipper_identity.IdentityError, "cycle"):
                    shipper_identity.capture_contents_manifest(app.resolve())

    def test_rejects_bundle_byte_mutation_during_codesign(self):
        app = self.make_app()
        payload = app / "Contents" / "Resources" / "payload.bin"

        def mutate():
            payload.write_bytes(b"payload-v2")

        runner = StaticRunner(action=mutate)
        with self.assertRaisesRegex(shipper_identity.IdentityError, "changed"):
            shipper_identity.capture_app_identity(
                app.resolve(),
                codesign_path=self.codesign.resolve(),
                codesign_runner=runner,
            )

    def test_codesigns_every_macho_leaf_then_the_exact_private_bundle(self):
        app = self.make_app()
        helper = app / "Contents" / "MacOS" / "helper"
        helper.write_bytes(macho_stub(b"helper"))
        helper.chmod(0o755)
        runner = StaticRunner()

        identity = shipper_identity.capture_app_identity(
            app.resolve(),
            codesign_path=self.codesign.resolve(),
            codesign_runner=runner,
        )

        self.assertEqual(
            [leaf.relative_path for leaf in identity.code_leaves],
            ["MacOS/WAM", "MacOS/helper"],
        )
        self.assertEqual(len(runner.calls), 3)
        self.assertNotIn("--deep", runner.calls[0][0])
        self.assertNotIn("--deep", runner.calls[1][0])
        self.assertIn("--deep", runner.calls[2][0])
        self.assertTrue(all("/candidate.app/" in call[0][-1] for call in runner.calls[:2]))
        self.assertTrue(runner.calls[-1][0][-1].endswith("/candidate.app"))

    def test_rejects_source_or_private_snapshot_mutation_between_codesign_calls(self):
        app = self.make_app()
        helper = app / "Contents" / "MacOS" / "helper"
        helper.write_bytes(macho_stub(b"helper"))
        helper.chmod(0o755)
        source_payload = app / "Contents" / "Resources" / "payload.bin"
        source_calls = 0

        def mutate_source_on_second_call():
            nonlocal source_calls
            source_calls += 1
            if source_calls == 2:
                source_payload.write_bytes(b"changed-between-leaves")

        with self.assertRaisesRegex(shipper_identity.IdentityError, "changed"):
            shipper_identity.capture_app_identity(
                app.resolve(),
                codesign_path=self.codesign.resolve(),
                codesign_runner=StaticRunner(action=mutate_source_on_second_call),
            )

        source_payload.write_bytes(b"payload-v1")

        def mutate_private_snapshot(argv, pass_fds, timeout_s, max_output_bytes):
            target = Path(argv[-1])
            candidate = next(parent for parent in target.parents if parent.suffix == ".app")
            (candidate / "Contents" / "Resources" / "payload.bin").write_bytes(
                b"private-snapshot-change"
            )
            return shipper_identity.CommandResult(0, b"", b"")

        with mock.patch.object(shipper_identity, "_bounded_command_runner", mutate_private_snapshot):
            production_codesign = self.make_script_tool("production-codesign")
            with self.assertRaisesRegex(shipper_identity.IdentityError, "changed|diverged"):
                shipper_identity.capture_app_identity(
                    app.resolve(), codesign_path=production_codesign.resolve()
                )

    def test_trusted_app_identity_has_complete_canonical_candidate_digest(self):
        app = self.make_app()
        def successful_system_tool(argv, pass_fds, timeout_s, max_output_bytes):
            return shipper_identity.CommandResult(0, b"", b"")

        with mock.patch.object(
            shipper_identity, "_bounded_command_runner", successful_system_tool
        ):
            identity = shipper_identity.capture_app_identity(
                app.resolve(), codesign_path=Path("/usr/bin/codesign")
            )

        index = self.receipt_index_for(identity)
        shipper_identity.validate_app_identity_for_shipping(
            identity, trusted_receipt_index=index
        )
        record = identity.as_dict()
        observed = record.pop("candidate_sha256")
        self.assertEqual(record["candidate_record"], shipper_identity._app_candidate_record(identity))
        expected = hashlib.sha256(
            json.dumps(
                record["candidate_record"],
                ensure_ascii=False,
                allow_nan=False,
                sort_keys=True,
                separators=(",", ":"),
            ).encode("utf-8")
        ).hexdigest()
        self.assertEqual(observed, expected)
        self.assertRegex(observed, r"^[0-9a-f]{64}$")

        omitted = dataclasses.replace(identity, code_leaves=())
        with self.assertRaisesRegex(shipper_identity.IdentityError, "cover every"):
            shipper_identity.validate_app_identity_for_shipping(
                omitted, trusted_receipt_index=index
            )

        for forged in (
            dataclasses.replace(identity, bundle_identifier="forged.id"),
            dataclasses.replace(identity, bundle_short_version="9.9.9"),
            dataclasses.replace(identity, bundle_version="999"),
            dataclasses.replace(
                identity, executable_relative_path="MacOS/not-WAM"
            ),
            dataclasses.replace(
                identity,
                executable=dataclasses.replace(identity.executable, sha256="0" * 64),
            ),
            dataclasses.replace(
                identity,
                info_plist=dataclasses.replace(identity.info_plist, sha256="0" * 64),
            ),
        ):
            with self.subTest(forged=forged):
                with self.assertRaisesRegex(shipper_identity.IdentityError, "exact manifest"):
                    shipper_identity.validate_app_identity_for_shipping(
                        forged, trusted_receipt_index=index
                    )

        substituted_bundle = dataclasses.replace(
            identity, codesign=identity.code_leaves[0].codesign
        )
        with self.assertRaises(shipper_identity.IdentityError):
            shipper_identity.validate_app_identity_for_shipping(
                substituted_bundle, trusted_receipt_index=index
            )

        helper = app / "Contents" / "MacOS" / "helper"
        helper.write_bytes(macho_stub(b"helper"))
        helper.chmod(0o755)
        with mock.patch.object(
            shipper_identity, "_bounded_command_runner", successful_system_tool
        ):
            two_leaf_identity = shipper_identity.capture_app_identity(
                app.resolve(), codesign_path=Path("/usr/bin/codesign")
            )
        duplicate_command = dataclasses.replace(
            two_leaf_identity,
            code_leaves=(
                two_leaf_identity.code_leaves[0],
                dataclasses.replace(
                    two_leaf_identity.code_leaves[1],
                    codesign=two_leaf_identity.code_leaves[0].codesign,
                ),
            ),
        )
        with self.assertRaisesRegex(shipper_identity.IdentityError, "code leaf|leaf codesign"):
            shipper_identity.validate_app_identity_for_shipping(
                duplicate_command,
                trusted_receipt_index=self.receipt_index_for(two_leaf_identity),
            )

        policy_identity = two_leaf_identity
        bundle_target = policy_identity.codesign.targets[0]
        extra_bundle_flag = dataclasses.replace(
            policy_identity.codesign,
            executed_argv=(
                *policy_identity.codesign.executed_argv[:-1],
                "--ignore-resources",
                policy_identity.codesign.executed_argv[-1],
            ),
        )
        forged_bundle = dataclasses.replace(
            policy_identity, codesign=extra_bundle_flag
        )
        with self.assertRaisesRegex(shipper_identity.IdentityError, "bundle codesign"):
            shipper_identity.validate_app_identity_for_shipping(
                forged_bundle,
                trusted_receipt_index=self.receipt_index_for(forged_bundle),
            )

        leaf = policy_identity.code_leaves[0]
        omitted_strict = dataclasses.replace(
            leaf.codesign,
            executed_argv=tuple(
                item for item in leaf.codesign.executed_argv if item != "--strict=all"
            ),
        )
        forged_leaf_identity = dataclasses.replace(
            policy_identity,
            code_leaves=(
                dataclasses.replace(leaf, codesign=omitted_strict),
                *policy_identity.code_leaves[1:],
            ),
        )
        with self.assertRaises(shipper_identity.IdentityError):
            shipper_identity.validate_app_identity_for_shipping(
                forged_leaf_identity,
                trusted_receipt_index=self.receipt_index_for(forged_leaf_identity),
            )

        inherited_fd = dataclasses.replace(
            policy_identity.codesign, pass_fds=(99,)
        )
        forged_fd_identity = dataclasses.replace(
            policy_identity, codesign=inherited_fd
        )
        with self.assertRaisesRegex(shipper_identity.IdentityError, "bundle codesign"):
            shipper_identity.validate_app_identity_for_shipping(
                forged_fd_identity,
                trusted_receipt_index=self.receipt_index_for(forged_fd_identity),
            )

        self.assertEqual(bundle_target.descriptor, None)

    def test_candidate_digest_is_stable_across_ephemeral_execution_receipts(self):
        app = self.make_app()

        def path_reporting_codesign(argv, pass_fds, timeout_s, max_output_bytes):
            return shipper_identity.CommandResult(
                0, b"", (argv[-1] + ": valid on disk\n").encode()
            )

        with mock.patch.object(
            shipper_identity, "_bounded_command_runner", path_reporting_codesign
        ):
            before = shipper_identity.capture_app_identity(
                app.resolve(), codesign_path=Path("/usr/bin/codesign")
            )
            after = shipper_identity.capture_app_identity(
                app.resolve(), codesign_path=Path("/usr/bin/codesign")
            )

        self.assertNotEqual(
            before.codesign.execution_receipt_id,
            after.codesign.execution_receipt_id,
        )
        self.assertNotEqual(
            before.codesign.stderr_text,
            after.codesign.stderr_text,
        )
        self.assertEqual(before.candidate_sha256, after.candidate_sha256)
        shipper_identity.verify_app_identity_unchanged(before, after)

    def test_identical_leaf_bytes_cannot_substitute_executed_snapshot_path(self):
        app = self.make_app()
        executable = app / "Contents" / "MacOS" / "WAM"
        helper = app / "Contents" / "MacOS" / "helper"
        helper.write_bytes(executable.read_bytes())
        helper.chmod(0o755)

        def successful_system_tool(argv, pass_fds, timeout_s, max_output_bytes):
            return shipper_identity.CommandResult(0, b"", b"")

        with mock.patch.object(
            shipper_identity, "_bounded_command_runner", successful_system_tool
        ):
            identity = shipper_identity.capture_app_identity(
                app.resolve(), codesign_path=Path("/usr/bin/codesign")
            )

        leaves = {leaf.relative_path: leaf for leaf in identity.code_leaves}
        victim = leaves["MacOS/WAM"]
        substitute = leaves["MacOS/helper"]
        substitute_target = substitute.codesign.targets[0]
        forged_target = dataclasses.replace(
            victim.codesign.targets[0],
            executed_argument=substitute_target.executed_argument,
            executed_file=substitute_target.executed_file,
        )
        forged_command = dataclasses.replace(
            victim.codesign,
            executed_argv=(
                *victim.codesign.executed_argv[:-1],
                substitute_target.executed_argument,
            ),
            targets=(forged_target,),
        )
        forged = dataclasses.replace(
            identity,
            code_leaves=tuple(
                dataclasses.replace(leaf, codesign=forged_command)
                if leaf.relative_path == victim.relative_path
                else leaf
                for leaf in identity.code_leaves
            ),
        )
        with self.assertRaisesRegex(shipper_identity.IdentityError, "code leaf"):
            shipper_identity.validate_app_identity_for_shipping(
                forged,
                trusted_receipt_index=self.receipt_index_for(forged),
            )

    def test_manifest_verifier_rejects_bundle_byte_change(self):
        app = self.make_app()
        before = shipper_identity.capture_contents_manifest(app.resolve())
        payload = app / "Contents" / "Resources" / "payload.bin"
        payload.write_bytes(b"different bytes")
        after = shipper_identity.capture_contents_manifest(app.resolve())

        with self.assertRaisesRegex(shipper_identity.IdentityError, "changed"):
            shipper_identity.verify_contents_manifest_unchanged(before, after)

    def test_rejects_invalid_plist_executable_and_codesign_failure(self):
        app = self.make_app()
        info = app / "Contents" / "Info.plist"
        info.write_bytes(b"not a plist")
        with self.assertRaisesRegex(shipper_identity.IdentityError, "malformed"):
            shipper_identity.capture_app_identity(
                app.resolve(),
                codesign_path=self.codesign.resolve(),
                codesign_runner=StaticRunner(),
            )

        info.write_bytes(
            plistlib.dumps(
                {
                    "CFBundleIdentifier": "com.wesleymaa.wam",
                    "CFBundleShortVersionString": "1.2.3",
                    "CFBundleVersion": "456",
                    "CFBundleExecutable": "WAM",
                },
                fmt=plistlib.FMT_BINARY,
            )
        )
        runner = StaticRunner(stderr=b"bad signature", returncode=1)
        with self.assertRaisesRegex(shipper_identity.IdentityError, "exit status 1"):
            shipper_identity.capture_app_identity(
                app.resolve(),
                codesign_path=self.codesign.resolve(),
                codesign_runner=runner,
            )

    def test_rejects_codesign_output_beyond_bound(self):
        app = self.make_app()
        runner = StaticRunner(stderr=b"0123456789")
        with self.assertRaisesRegex(shipper_identity.IdentityError, "beyond"):
            shipper_identity.capture_app_identity(
                app.resolve(),
                codesign_path=self.codesign.resolve(),
                codesign_runner=runner,
                max_codesign_output_bytes=4,
            )


if __name__ == "__main__":
    unittest.main()
