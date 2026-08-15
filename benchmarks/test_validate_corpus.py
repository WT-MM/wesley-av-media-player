#!/usr/bin/env python3

import copy
import hashlib
import json
import struct
import subprocess
import tempfile
import unittest
from pathlib import Path

import validate_corpus


def box(kind, payload=b""):
    return struct.pack(">I4s", 8 + len(payload), kind) + payload


def iso_track(handler, sample_entry):
    hdlr = box(b"hdlr", b"\0" * 8 + handler)
    entry = box(sample_entry, b"fixture-entry")
    stsd = box(b"stsd", b"\0" * 4 + struct.pack(">I", 1) + entry)
    return box(b"trak", box(b"mdia", hdlr + box(b"minf", box(b"stbl", stsd))))


def iso_bmff(
    video_entry=b"avc1", *, mov=False, audio_entry=b"mp4a", include_audio=True
):
    major = b"qt  " if mov else b"isom"
    compatible = b"qt  " if mov else b"isomiso2mp41"
    ftyp = box(b"ftyp", major + struct.pack(">I", 0) + compatible)
    tracks = iso_track(b"vide", video_entry)
    if include_audio:
        tracks += iso_track(b"soun", audio_entry)
    moov = box(b"moov", tracks)
    return ftyp + box(b"mdat", b"encoded-payload") + moov


def vint_size(size):
    if not 0 <= size < 127:
        raise AssertionError("unit EBML element is unexpectedly large")
    return bytes((0x80 | size,))


def element(identifier, payload):
    return identifier + vint_size(len(payload)) + payload


def matroska(video_codec="V_MPEG4/ISO/AVC", *, doctype="matroska", audio_codec="A_AAC"):
    header = element(b"\x1a\x45\xdf\xa3", element(b"\x42\x82", doctype.encode()))

    def track(track_type, codec_id):
        return element(
            b"\xae",
            element(b"\x83", bytes((track_type,)))
            + element(b"\x86", codec_id.encode()),
        )

    tracks = element(b"\x16\x54\xae\x6b", track(1, video_codec) + track(2, audio_codec))
    return header + element(b"\x18\x53\x80\x67", tracks)


def adts(frame_count=validate_corpus.AAC_LC_PACKET_COUNT):
    # MPEG-4, AAC-LC, 48 kHz index 3, stereo, one raw block, 8-byte frame.
    header = bytes((0xFF, 0xF1, 0x4C, 0x80, 0x01, 0x1F, 0xFC))
    return (header + b"\0") * frame_count


class FixtureRunner:
    def __init__(self):
        self.calls = []
        self.packet_mutation = None
        self.packet_document_mutation = None
        self.metadata_mutation = None

    @staticmethod
    def _family(path):
        name = path.name
        if "main10" in name:
            return "hevc-main10"
        if "hevc-main" in name:
            return "hevc-main"
        return "h264-high"

    def metadata(self, path):
        family = self._family(path)
        codec = "h264" if family == "h264-high" else "hevc"
        profile = {
            "h264-high": "High",
            "hevc-main": "Main",
            "hevc-main10": "Main 10",
        }[family]
        pixel_format = "yuv420p10le" if family == "hevc-main10" else "yuv420p"
        format_name = "matroska,webm" if path.suffix == ".mkv" else "mov,mp4,m4a,3gp,3g2,mj2"
        video = {
                    "index": 0,
                    "codec_type": "video",
                    "codec_name": codec,
                    "profile": profile,
                    "codec_tag_string": "avc1" if codec == "h264" else "hvc1",
                    "width": 1920,
                    "height": 1080,
                    "pix_fmt": pixel_format,
                    "r_frame_rate": "30/1",
                    "avg_frame_rate": "30/1",
                    "field_order": "progressive",
                    "sample_aspect_ratio": "1:1",
                    "color_range": "tv",
                    "color_space": "bt709",
                    "color_transfer": "bt709",
                    "color_primaries": "bt709",
                }
        audio = {
                    "index": 1,
                    "codec_type": "audio",
                    "codec_name": "aac",
                    "profile": "LC",
                    "sample_rate": "48000",
                    "channels": 2,
                    "channel_layout": "stereo",
                }
        if path.suffix == ".aac":
            audio["index"] = 0
            streams = [audio]
            format_name = "aac"
        elif "_masters" in path.parts:
            streams = [video]
        else:
            streams = [video, audio]
        value = {
            "streams": streams,
            "format": {
                "format_name": format_name,
                "nb_streams": 2,
                "duration": (
                    "75.294517"
                    if path.suffix == ".aac"
                    else "72.021000"
                    if path.suffix == ".mkv"
                    else "72.000000"
                ),
            },
        }
        if self.metadata_mutation is not None:
            self.metadata_mutation(path, value)
        return value

    def packets(self, path):
        family = self._family(path)
        video_hashes = [
            hashlib.sha256(f"{family}:video:{index}".encode()).hexdigest()
            for index in range(validate_corpus.VIDEO_PACKET_COUNT)
        ]
        if self.packet_mutation is not None:
            video_hashes = self.packet_mutation(path, video_hashes)
        audio_hashes = [
            hashlib.sha256(f"audio:{index}".encode()).hexdigest()
            for index in range(validate_corpus.AAC_LC_PACKET_COUNT)
        ]
        if path.suffix == ".aac":
            value = {
                "packets": [
                    {
                        "stream_index": 0,
                        "size": "512",
                        "flags": "K__",
                        "data_hash": f"SHA256:{value}",
                    }
                    for value in audio_hashes
                ]
            }
            if self.packet_document_mutation is not None:
                self.packet_document_mutation(path, value)
            return value
        video_only = "_masters" in path.parts
        packets = []
        for index in range(max(len(video_hashes), len(audio_hashes))):
            if index < len(video_hashes):
                packets.append(
                    {
                        "stream_index": 0,
                        "size": "4096",
                        "flags": "K__" if index % 60 == 0 else "___",
                        "data_hash": f"SHA256:{video_hashes[index]}",
                    }
                )
            if not video_only and index < len(audio_hashes):
                packets.append(
                    {
                        "stream_index": 1,
                        "size": "512",
                        "flags": "K__",
                        "data_hash": f"SHA256:{audio_hashes[index]}",
                    }
                )
        value = {"packets": packets}
        if self.packet_document_mutation is not None:
            self.packet_document_mutation(path, value)
        return value

    def __call__(self, argv, timeout_s, max_output_bytes):
        self.calls.append((tuple(argv), timeout_s, max_output_bytes))
        self_path = Path(argv[0])
        if tuple(argv[1:]) == ("-version",):
            return validate_corpus.CommandResult(
                0,
                f"{self_path.name} version fixture-1\nconfiguration fixture\n".encode(),
                b"",
            )
        asset = Path(argv[-1])
        if "-show_streams" in argv:
            value = self.metadata(asset)
        elif "-show_packets" in argv:
            value = self.packets(asset)
        else:
            return validate_corpus.CommandResult(2, b"", b"unexpected argv")
        return validate_corpus.CommandResult(
            0,
            json.dumps(value, separators=(",", ":")).encode() + b"\n",
            b"",
        )


class CorpusFixture(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.benchmarks = self.root / "benchmarks"
        self.benchmarks.mkdir()
        subprocess.run(
            ["git", "init", "--quiet", str(self.root)], check=True
        )
        (self.root / ".gitignore").write_text("/.cache/\n", encoding="utf-8")
        self.recipe_script = self.benchmarks / "prepare_corpus.zsh"
        self.recipe_script.write_text("#!/bin/zsh\n# exact fixture recipe\n", encoding="utf-8")
        self.recipe_script.chmod(0o755)
        self.media_root = self.root / ".cache" / "benchmarks" / "media"
        self.output = self.media_root / "native-1080p-sdr-v1"
        (self.output / "_masters").mkdir(parents=True)
        self.ffmpeg = self.make_tool("ffmpeg")
        self.ffprobe = self.make_tool("ffprobe")
        self.corpus = self.make_corpus()
        self.corpus_path = self.benchmarks / "corpus.json"
        self.write_json(self.corpus_path, self.corpus)
        self.create_assets()
        self.ledger_path = self.output / "command-ledger.json"
        self.write_ledger()
        self.runtime_receipt_path = self.output / "runtime-receipt.json"
        runtime_receipt = validate_corpus.capture_runtime_identity(
            self.corpus_path,
            ffmpeg_path=self.ffmpeg,
            ffprobe_path=self.ffprobe,
            recipe_script_path=self.recipe_script,
        )
        validate_corpus.write_runtime_receipt(
            runtime_receipt,
            self.runtime_receipt_path,
            corpus_path=self.corpus_path,
        )
        self.manifest_path = self.output / "preparation-manifest.json"
        self.runner = FixtureRunner()

    def tearDown(self):
        self.temporary.cleanup()

    def make_tool(self, name):
        path = self.root / "tools" / name
        path.parent.mkdir(exist_ok=True)
        path.write_bytes((f"#!/bin/sh\n# exact {name} fixture\n").encode())
        path.chmod(0o755)
        return path.resolve()

    @staticmethod
    def write_json(path, value):
        path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")

    def make_corpus(self):
        recipes = copy.deepcopy(validate_corpus.EXPECTED_RECIPES)
        intermediates = []
        for recipe, suffix, group in (
            ("h264-high", "h264-high.mp4", "h264-high-1080p30"),
            ("hevc-main", "hevc-main.mp4", "hevc-main-1080p30"),
            ("hevc-main10", "hevc-main10.mp4", "hevc-main10-1080p30"),
            ("aac-lc", "aac-lc.aac", "aac-lc-48k-stereo"),
        ):
            intermediates.append(
                {
                    "id": f"master-{recipe}",
                    "kind": "locally-generated-native-v1-intermediate",
                    "path": f"native-1080p-sdr-v1/_masters/{suffix}",
                    "recipe": recipe,
                    "payload_identity_group": group,
                }
            )
        entries = []
        for codec, profile, profile_label, pixel, family in (
            ("h264", "high", "High", "yuv420p", "h264-high"),
            ("hevc", "main", "Main", "yuv420p", "hevc-main"),
            ("hevc", "main10", "Main 10", "yuv420p10le", "hevc-main10"),
        ):
            for container in ("mp4", "mov", "mkv"):
                video = {
                    "codec": codec,
                    "profile": profile_label,
                    "pixel_format": pixel,
                    "width": 1920,
                    "height": 1080,
                    "fps": "30/1",
                    "payload_identity_group": f"{family}-1080p30",
                }
                audio = {
                    "codec": "aac",
                    "profile": "LC",
                    "sample_rate_hz": 48000,
                    "channels": 2,
                    "channel_layout": "stereo",
                    "payload_identity_group": "aac-lc-48k-stereo",
                }
                if container == "mkv":
                    video["matroska_codec_id"] = (
                        "V_MPEG4/ISO/AVC" if codec == "h264" else "V_MPEGH/ISO/HEVC"
                    )
                    audio["matroska_codec_id"] = "A_AAC"
                else:
                    video["sample_entry"] = "avc1" if codec == "h264" else "hvc1"
                    audio["sample_entry"] = "mp4a"
                entries.append(
                    {
                        "id": f"native-{family}-{container}",
                        "kind": "locally-generated-native-v1",
                        "path": f"native-1080p-sdr-v1/{family}.{container}",
                        "container": container,
                        "duration_seconds": 72.0,
                        "video_recipe": family,
                        "audio_recipe": "aac-lc",
                        "video": video,
                        "audio": audio,
                    }
                )
        return {
            "schema_version": 1,
            "entries": [],
            "native_generated_corpus": {
                "schema": validate_corpus.CORPUS_SCHEMA,
                "id": "native-1080p-sdr-v1",
                "kind": "deterministic-local-generation",
                "output_subdirectory": "native-1080p-sdr-v1",
                "preparation_manifest": "native-1080p-sdr-v1/preparation-manifest.json",
                "command_ledger": "native-1080p-sdr-v1/command-ledger.json",
                "runtime_receipt": "native-1080p-sdr-v1/runtime-receipt.json",
                "duration_seconds": 72.0,
                "minimum_duration_seconds": 71.9,
                "frame_rate": "30/1",
                "video_source_filter": validate_corpus.EXPECTED_VIDEO_SOURCE_FILTER,
                "audio_source_filter": validate_corpus.EXPECTED_AUDIO_SOURCE_FILTER,
                "stream_identity_policy": validate_corpus.EXPECTED_STREAM_IDENTITY_POLICY,
                "recipes": recipes,
                "intermediates": intermediates,
                "entries": entries,
            },
        }

    def create_assets(self):
        native = self.corpus["native_generated_corpus"]
        for intermediate in native["intermediates"]:
            destination = self.media_root / intermediate["path"]
            if intermediate["recipe"] == "aac-lc":
                destination.write_bytes(adts())
            else:
                destination.write_bytes(
                    iso_bmff(
                        b"avc1" if intermediate["recipe"] == "h264-high" else b"hvc1",
                        include_audio=False,
                    )
                )
        for entry in native["entries"]:
            destination = self.media_root / entry["path"]
            codec = entry["video"]["codec"]
            if entry["container"] == "mkv":
                destination.write_bytes(
                    matroska(
                        "V_MPEG4/ISO/AVC" if codec == "h264" else "V_MPEGH/ISO/HEVC"
                    )
                )
            else:
                destination.write_bytes(
                    iso_bmff(
                        b"avc1" if codec == "h264" else b"hvc1",
                        mov=entry["container"] == "mov",
                    )
                )

    def write_ledger(self, mutate=None):
        native = self.corpus["native_generated_corpus"]
        items = native["intermediates"] + native["entries"]
        expected = validate_corpus._expected_command_argv(native, self.ffmpeg)
        commands = [
            {
                "id": (
                    f"encode-{item['recipe']}"
                    if "recipe" in item
                    else item["id"].replace("native-", "mux-", 1)
                ),
                "argv": list(
                    expected[
                        f"encode-{item['recipe']}"
                        if "recipe" in item
                        else item["id"].replace("native-", "mux-", 1)
                    ]
                ),
                "outputs": [output],
            }
            for item in items
            for output in (item["path"],)
        ]
        ledger = {
            "schema": validate_corpus.LEDGER_SCHEMA,
            "path_placeholders": validate_corpus.MEDIA_ROOT_PLACEHOLDERS,
            "commands": commands,
        }
        if mutate is not None:
            mutate(ledger)
        self.write_json(self.output / "command-ledger.json", ledger)

    def build(self, runner=None):
        return validate_corpus.build_preparation_manifest(
            self.corpus_path,
            self.media_root,
            command_ledger_path=self.ledger_path,
            runtime_receipt_path=self.runtime_receipt_path,
            recipe_script_path=self.recipe_script,
            ffprobe_path=self.ffprobe,
            ffmpeg_path=self.ffmpeg,
            runner=runner or self.runner,
        )

    def test_directly_parses_iso_sample_entries_and_matroska_codec_ids(self):
        mp4 = self.output / "h264-high.mp4"
        mov = self.output / "hevc-main.mov"
        mkv = self.output / "hevc-main10.mkv"

        self.assertEqual(validate_corpus.inspect_iso_bmff(mp4)["video_sample_entry"], "avc1")
        self.assertEqual(validate_corpus.inspect_iso_bmff(mov)["major_brand"], "qt  ")
        structure = validate_corpus.inspect_matroska(mkv)
        self.assertEqual(structure["doctype"], "matroska")
        self.assertEqual(structure["video_codec_id"], "V_MPEGH/ISO/HEVC")
        self.assertEqual(structure["audio_codec_id"], "A_AAC")

    def test_builds_and_revalidates_exact_manifest_without_encoding(self):
        manifest = self.build()
        self.assertEqual(manifest["schema"], validate_corpus.MANIFEST_SCHEMA)
        self.assertEqual(len(manifest["files"]), 9)
        self.assertEqual(len(manifest["intermediates"]), 4)
        self.assertEqual(len(manifest["commands"]), 13)
        self.assertEqual(len(manifest["payload_equivalence"]["video_families"]), 3)
        self.assertEqual(len(manifest["payload_equivalence"]["audio"]["members"]), 10)
        self.assertEqual(
            manifest["payload_equivalence"]["audio"]["packet_count"], 3375
        )
        self.assertEqual(
            manifest["payload_equivalence"]["audio"]["grid_duration"], "72/1"
        )
        first = manifest["files"]["native-h264-high-mp4"]
        self.assertEqual(
            first["raw_ffprobe_sha256"],
            hashlib.sha256(first["raw_ffprobe_json"].encode()).hexdigest(),
        )
        self.assertEqual(first["structure"]["video_sample_entry"], "avc1")
        self.assertEqual(first["ffprobe_argv"][-1], "native-1080p-sdr-v1/h264-high.mp4")
        validate_corpus.write_preparation_manifest(
            manifest,
            self.manifest_path,
            corpus_path=self.corpus_path,
            require_ignored=False,
        )
        validated = validate_corpus.validate_preparation_manifest(
            self.corpus_path,
            self.media_root,
            self.manifest_path,
            command_ledger_path=self.ledger_path,
            runtime_receipt_path=self.runtime_receipt_path,
            recipe_script_path=self.recipe_script,
            ffprobe_path=self.ffprobe,
            ffmpeg_path=self.ffmpeg,
            runner=self.runner,
        )
        self.assertEqual(validated, manifest)
        self.assertTrue(all(isinstance(call[0], tuple) for call in self.runner.calls))
        self.assertTrue(all(call[0][0] in {str(self.ffmpeg), str(self.ffprobe)} for call in self.runner.calls))

    def test_rejects_wrong_iso_sample_entries_without_trusting_probe(self):
        path = self.output / "h264-high.mp4"
        path.write_bytes(iso_bmff(b"avc3"))
        with self.assertRaisesRegex(validate_corpus.CorpusError, "sample entry must be avc1"):
            self.build()

    def test_rejects_wrong_matroska_doctype_and_codec_id(self):
        path = self.output / "h264-high.mkv"
        path.write_bytes(matroska(doctype="webm"))
        with self.assertRaisesRegex(validate_corpus.CorpusError, "DocType"):
            self.build()
        path.write_bytes(matroska("V_VP9"))
        with self.assertRaisesRegex(validate_corpus.CorpusError, "CodecID"):
            self.build()

    def test_rejects_incomplete_or_duplicate_matrix(self):
        value = copy.deepcopy(self.corpus)
        value["native_generated_corpus"]["entries"].pop()
        with self.assertRaisesRegex(validate_corpus.CorpusError, "nine required rows"):
            validate_corpus.parse_declarations(value)

    def test_rejects_recipe_drift_and_command_argv_or_order_drift(self):
        value = copy.deepcopy(self.corpus)
        value["native_generated_corpus"]["recipes"]["h264-high"]["crf"] = 21
        with self.assertRaisesRegex(validate_corpus.CorpusError, "frozen native-v1"):
            validate_corpus.parse_declarations(value)
        for field, replacement in (
            ("video_source_filter", "color=black:size=1920x1080:rate=30"),
            ("audio_source_filter", "anullsrc=sample_rate=48000"),
            ("stream_identity_policy", "trust timestamps"),
        ):
            with self.subTest(field=field):
                value = copy.deepcopy(self.corpus)
                value["native_generated_corpus"][field] = replacement
                with self.assertRaises(validate_corpus.CorpusError):
                    validate_corpus.parse_declarations(value)

        def argv_mutation(ledger):
            ledger["commands"][0]["argv"][ledger["commands"][0]["argv"].index("20")] = "21"

        self.write_ledger(argv_mutation)
        with self.assertRaisesRegex(validate_corpus.CorpusError, "exact native-v1 recipe"):
            self.build()
        self.write_ledger(lambda ledger: ledger["commands"].__setitem__(
            slice(0, 2), list(reversed(ledger["commands"][:2]))
        ))
        with self.assertRaisesRegex(validate_corpus.CorpusError, "canonical native-v1 order"):
            self.build()
        self.write_ledger()

    def test_adts_duration_uses_exact_grid_not_ffprobe_estimate(self):
        manifest = self.build()
        audio = manifest["intermediates"]["master-aac-lc"]
        self.assertIn('"duration":"75.294517"', audio["raw_ffprobe_json"])
        self.assertEqual(audio["streams"]["duration"], "72/1")
        self.assertEqual(audio["structure"]["grid_duration"], "72/1")
        value = copy.deepcopy(self.corpus)
        value["native_generated_corpus"]["entries"][1]["container"] = "mp4"
        with self.assertRaisesRegex(validate_corpus.CorpusError, "duplicate native-v1 matrix"):
            validate_corpus.parse_declarations(value)

    def test_rejects_packet_payload_change_with_timing_excluded(self):
        def mutate(path, values):
            if path.name == "h264-high.mov":
                values[1] = hashlib.sha256(b"different-payload").hexdigest()
            return values

        self.runner.packet_mutation = mutate
        with self.assertRaisesRegex(validate_corpus.CorpusError, "video packet payloads differ"):
            self.build()

    def test_rejects_packet_count_keyframe_grid_and_size_bounds(self):
        def missing_packet(path, value):
            if path.name == "hevc-main.mp4" and "_masters" not in path.parts:
                value["packets"] = value["packets"][:-1]

        def shifted_keyframe(path, value):
            if path.name == "hevc-main.mov":
                for packet in value["packets"]:
                    if packet["stream_index"] == 0:
                        packet["flags"] = "___"
                        break

        def oversized_audio(path, value):
            if path.name == "h264-high.mkv":
                for packet in value["packets"]:
                    if packet["stream_index"] == 1:
                        packet["size"] = str(validate_corpus.MAX_AUDIO_PACKET_BYTES + 1)
                        break

        for mutation in (missing_packet, shifted_keyframe, oversized_audio):
            with self.subTest(mutation=mutation):
                runner = FixtureRunner()
                runner.packet_document_mutation = mutation
                with self.assertRaises(validate_corpus.CorpusError):
                    self.build(runner)

    def test_rejects_malformed_or_short_adts_master(self):
        audio_master = self.output / "_masters" / "aac-lc.aac"
        raw = bytearray(audio_master.read_bytes())
        raw[2] = (raw[2] & 0x3F) | (0 << 6)  # AAC Main, not AAC-LC.
        audio_master.write_bytes(raw)
        with self.assertRaisesRegex(validate_corpus.CorpusError, "AAC-LC"):
            self.build()

    def test_rejects_probe_profile_timing_geometry_and_color_contradictions(self):
        mutations = (
            lambda _path, value: value["streams"][0].__setitem__("avg_frame_rate", "30000/1001"),
            lambda _path, value: value["streams"][0].__setitem__("width", 1280),
            lambda _path, value: value["streams"][0].__setitem__("color_space", "bt2020nc"),
            lambda _path, value: value["format"].__setitem__("duration", "71.800000"),
        )
        for mutation in mutations:
            with self.subTest(mutation=mutation):
                runner = FixtureRunner()
                runner.metadata_mutation = mutation
                with self.assertRaises(validate_corpus.CorpusError):
                    self.build(runner)

    def test_rejects_ledger_missing_duplicate_or_foreign_output(self):
        cases = (
            lambda ledger: ledger["commands"].pop(),
            lambda ledger: ledger["commands"][1]["outputs"].__setitem__(
                0, ledger["commands"][0]["outputs"][0]
            ),
            lambda ledger: ledger["commands"][0]["outputs"].__setitem__(0, "foreign.bin"),
        )
        for mutation in cases:
            with self.subTest(mutation=mutation):
                self.write_ledger(mutation)
                with self.assertRaises(validate_corpus.CorpusError):
                    self.build()
                self.write_ledger()

    def test_manifest_validation_detects_recorded_or_recipe_drift(self):
        manifest = self.build()
        validate_corpus.write_preparation_manifest(
            manifest,
            self.manifest_path,
            corpus_path=self.corpus_path,
            require_ignored=False,
        )
        recorded = json.loads(self.manifest_path.read_text())
        recorded["files"]["native-h264-high-mp4"]["sha256"] = "0" * 64
        self.write_json(self.manifest_path, recorded)
        with self.assertRaisesRegex(validate_corpus.CorpusError, "does not match"):
            validate_corpus.validate_preparation_manifest(
                self.corpus_path,
                self.media_root,
                self.manifest_path,
                command_ledger_path=self.ledger_path,
                runtime_receipt_path=self.runtime_receipt_path,
                recipe_script_path=self.recipe_script,
                ffprobe_path=self.ffprobe,
                ffmpeg_path=self.ffmpeg,
                runner=self.runner,
            )

    def test_declared_manifest_and_asset_paths_cannot_escape_media_root(self):
        expected = validate_corpus.declared_manifest_path(self.corpus_path, self.media_root)
        self.assertEqual(expected, self.manifest_path.resolve(strict=False))
        value = copy.deepcopy(self.corpus)
        value["native_generated_corpus"]["preparation_manifest"] = "../outside.json"
        self.write_json(self.corpus_path, value)
        with self.assertRaises(validate_corpus.CorpusError):
            validate_corpus.declared_manifest_path(self.corpus_path, self.media_root)


if __name__ == "__main__":
    unittest.main()
