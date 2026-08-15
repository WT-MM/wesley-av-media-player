#!/usr/bin/env python3

import argparse
import contextlib
import io
import json
import signal
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import run_suite

TEST_RUN_ID = "123e4567-e89b-12d3-a456-426614174000"
TEST_PROCESS_ID = 4242
TEST_PROCESS_START_ABSTIME = 987654321
TEST_ASSET_SHA256 = "ab" * 32
TEST_CANDIDATE_ID = "cd" * 32


def native_event(event, monotonic_ns, **overrides):
    value = {
        "schema": run_suite.NATIVE_TELEMETRY_SCHEMA,
        "event": event,
        "monotonic_ns": monotonic_ns,
        "route": "undecided",
        "route_proof": False,
        "source_key": 0,
        "attempt": 0,
        "serial": 0,
        "generation": 0,
        "gesture": 0,
        "request": 0,
        "draw_sequence": 0,
        "target_seconds": None,
        "libmpv_initialized": False,
        "run_id": TEST_RUN_ID,
        "process_id": TEST_PROCESS_ID,
        "process_start_abstime": TEST_PROCESS_START_ABSTIME,
        "asset_sha256": TEST_ASSET_SHA256,
    }
    value.update(overrides)
    return json.dumps(value, separators=(",", ":"))


def framed_native_stream(event_lines, *, terminal=True, candidate_id=TEST_CANDIDATE_ID):
    identity = {
        "run_id": TEST_RUN_ID,
        "process_id": TEST_PROCESS_ID,
        "process_start_abstime": TEST_PROCESS_START_ABSTIME,
        "asset_sha256": TEST_ASSET_SHA256,
        "candidate_id": candidate_id,
    }
    records = [
        json.dumps(
            {
                "schema": run_suite.NATIVE_TELEMETRY_FRAMED_SCHEMA,
                "record": "stream_header",
                "format_version": 2,
                **identity,
            },
            separators=(",", ":"),
        )
    ]
    events = []
    for sequence, raw in enumerate(event_lines, start=1):
        value = json.loads(raw)
        value.update(
            {
                "schema": run_suite.NATIVE_TELEMETRY_FRAMED_SCHEMA,
                "record": "event",
                "batch": 1,
                "event_sequence": sequence,
                **identity,
            }
        )
        events.append(json.dumps(value, separators=(",", ":")) + "\n")
    count = len(events)
    records.append(
        json.dumps(
            {
                "schema": run_suite.NATIVE_TELEMETRY_FRAMED_SCHEMA,
                "record": "batch_begin",
                "batch": 1,
                "event_count": count,
                "first_sequence": 1,
                "last_sequence": count,
                "previous_chain_sha256": "00" * 32,
                **identity,
            },
            separators=(",", ":"),
        )
    )
    records.extend(line.removesuffix("\n") for line in events)
    payload = "".join(events).encode()
    payload_digest = run_suite.hashlib.sha256(payload).digest()
    chain_hasher = run_suite.hashlib.sha256()
    chain_hasher.update(bytes(32))
    chain_hasher.update(payload_digest)
    chain_hasher.update(run_suite.struct.pack(">QQQQ", 1, count, 1, count))
    chain = chain_hasher.hexdigest()
    records.append(
        json.dumps(
            {
                "schema": run_suite.NATIVE_TELEMETRY_FRAMED_SCHEMA,
                "record": "batch_commit",
                "batch": 1,
                "event_count": count,
                "first_sequence": 1,
                "last_sequence": count,
                "payload_sha256": payload_digest.hex(),
                "chain_sha256": chain,
                **identity,
            },
            separators=(",", ":"),
        )
    )
    if terminal:
        records.append(
            json.dumps(
                {
                    "schema": run_suite.NATIVE_TELEMETRY_FRAMED_SCHEMA,
                    "record": "stream_commit",
                    "batch_count": 1,
                    "event_count": count,
                    "first_sequence": 1,
                    "last_sequence": count,
                    "chain_sha256": chain,
                    **identity,
                },
                separators=(",", ":"),
            )
        )
    return "\n".join(records) + "\n"


class ParserTests(unittest.TestCase):
    def test_framed_native_stream_is_terminally_committed_and_candidate_bound(self):
        raw = framed_native_stream(
            [
                native_event("open_requested", 1_100_000_000, source_key=7),
                native_event(
                    "native_selected",
                    1_120_000_000,
                    route="native",
                    route_proof=True,
                    source_key=7,
                    attempt=11,
                    serial=12,
                    generation=13,
                ),
                native_event(
                    "first_frame_drawn",
                    1_150_000_000,
                    route="native",
                    attempt=11,
                    serial=14,
                    generation=13,
                    draw_sequence=1,
                ),
            ]
        )
        parsed = run_suite.parse_wam_native_telemetry(raw)
        parsed["availability"] = "available"
        report = run_suite.summarize_wam_native_proof(
            parsed,
            1_000_000_000,
            TEST_RUN_ID,
            TEST_PROCESS_ID,
            TEST_PROCESS_START_ABSTIME,
            TEST_ASSET_SHA256,
            TEST_CANDIDATE_ID,
        )
        self.assertTrue(parsed["stream_complete"])
        self.assertTrue(report["eligible"])
        self.assertFalse(report["provisional"])
        self.assertTrue(report["required_evidence"]["terminal_stream_commit"])
        self.assertEqual(report["candidate_identity"]["sha256"], TEST_CANDIDATE_ID)
        run_suite.require_wam_native_proof(report)

    def test_framed_live_checkpoint_is_provisional_never_ship_eligible(self):
        raw = framed_native_stream(
            [
                native_event("open_requested", 1_100_000_000, source_key=7),
                native_event(
                    "native_selected", 1_120_000_000, route="native",
                    route_proof=True, source_key=7, attempt=11, serial=12,
                    generation=13,
                ),
                native_event(
                    "first_frame_drawn", 1_150_000_000, route="native",
                    attempt=11, serial=14, generation=13, draw_sequence=1,
                ),
            ],
            terminal=False,
        )
        parsed = run_suite.parse_wam_native_telemetry(raw)
        parsed["availability"] = "available"
        report = run_suite.summarize_wam_native_proof(
            parsed, 1_000_000_000, TEST_RUN_ID, TEST_PROCESS_ID,
            TEST_PROCESS_START_ABSTIME, TEST_ASSET_SHA256, TEST_CANDIDATE_ID,
            require_stream_complete=False,
        )
        self.assertFalse(parsed["stream_complete"])
        self.assertFalse(report["eligible"])
        self.assertTrue(report["provisional_eligible"])
        run_suite.require_wam_native_provisional_proof(report)
        with self.assertRaises(run_suite.NativeProofIneligible):
            run_suite.require_wam_native_proof(report)

    def test_framed_parser_rejects_prefix_replay_order_chain_and_trailing_data(self):
        event_lines = [native_event("open_requested", 1_100_000_000, source_key=7)]
        valid = framed_native_stream(event_lines)
        mutations = {
            "partial final line": valid[:-2],
            "duplicate terminal commit": valid + valid.splitlines()[-1] + "\n",
            "trailing framed bytes": valid
            + json.dumps(
                {
                    "schema": run_suite.NATIVE_TELEMETRY_FRAMED_SCHEMA,
                    "record": "stream_commit",
                },
                separators=(",", ":"),
            )
            + "\n",
            "trailing diagnostic bytes": valid + "ordinary Qt diagnostic\n",
            "surrounding framed whitespace": " " + valid,
            "event sequence gap": valid.replace('"event_sequence":1', '"event_sequence":2'),
            "batch id mismatch": valid.replace('"batch":1', '"batch":2', 1),
            "boolean batch id": valid.replace('"batch":1', '"batch":true', 1),
            "candidate mismatch": valid.replace(TEST_CANDIDATE_ID, "ef" * 32, 1),
            "chain discontinuity": valid.replace(
                '"previous_chain_sha256":"' + "00" * 32 + '"',
                '"previous_chain_sha256":"' + "11" * 32 + '"',
            ),
        }
        for label, raw in mutations.items():
            with self.subTest(label=label):
                parsed = run_suite.parse_wam_native_telemetry(raw)
                self.assertFalse(parsed["stream_complete"])
                self.assertTrue(parsed["parse_errors"])
                self.assertEqual(parsed["events"], [])

    def test_legacy_v1_is_diagnostics_only_even_when_route_lineage_is_valid(self):
        raw = "\n".join(
            [
                native_event("open_requested", 1_100_000_000, source_key=7),
                native_event(
                    "native_selected", 1_120_000_000, route="native",
                    route_proof=True, source_key=7, attempt=11, serial=12,
                    generation=13,
                ),
                native_event(
                    "first_frame_drawn", 1_150_000_000, route="native",
                    attempt=11, serial=14, generation=13, draw_sequence=1,
                ),
            ]
        )
        parsed = run_suite.parse_wam_native_telemetry(raw)
        parsed["availability"] = "available"
        report = run_suite.summarize_wam_native_proof(parsed, 1_000_000_000)
        self.assertFalse(report["eligible"])
        self.assertTrue(report["provisional_eligible"])
        self.assertEqual(parsed["framing_schema"], "legacy_uncommitted")

    def test_window_and_cli_defaults(self):
        self.assertEqual(run_suite.window_size("1180x720"), (1180, 720))
        parser = run_suite.build_parser()
        args = parser.parse_args(
            ["--player", "wam", "--clip", "movie.mp4", "--run", "1", "--output", "out.json"]
        )
        self.assertEqual(args.window, (1180, 720))
        self.assertEqual(args.speed, 1.0)

        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            parser.parse_args(
                [
                    "--player",
                    "wam",
                    "--clip",
                    "movie.mp4",
                    "--run",
                    "1",
                    "--window",
                    "wide",
                    "--output",
                    "out.json",
                ]
            )

    def test_wam_accepts_rate_but_rejects_uncontrolled_start_and_geometry(self):
        base = argparse.Namespace(
            player="wam", speed=2.0, start_time=0.0, window=(1180, 720)
        )
        run_suite.validate_player_options(base)
        base.start_time = 3.0
        with self.assertRaisesRegex(run_suite.SuiteError, "start-time 0"):
            run_suite.validate_player_options(base)
        base.start_time = 0.0
        base.window = (800, 600)
        with self.assertRaisesRegex(run_suite.SuiteError, "1180x720"):
            run_suite.validate_player_options(base)

    def test_native_jsonl_proves_cold_and_internal_open_latency(self):
        raw = "\n".join(
            [
                "ordinary Qt diagnostic",
                native_event("open_requested", 1_100_000_000, source_key=7),
                native_event(
                    "native_selected",
                    1_140_000_000,
                    route="native",
                    route_proof=True,
                    source_key=7,
                    attempt=11,
                    serial=12,
                    generation=13,
                    target_seconds=0.0,
                ),
                native_event(
                    "first_frame_drawn",
                    1_200_000_000,
                    route="native",
                    attempt=11,
                    # Prepare serial 12 reserves generation 13; the real
                    # Start/SetRunState path advances before draw proof.
                    serial=14,
                    generation=13,
                    draw_sequence=1,
                    target_seconds=0.0,
                ),
            ]
        )
        parsed = run_suite.parse_wam_native_telemetry(raw)
        parsed["availability"] = "available"
        report = run_suite.summarize_wam_native_proof(
            parsed,
            1_000_000_000,
            TEST_RUN_ID,
            TEST_PROCESS_ID,
            TEST_PROCESS_START_ABSTIME,
            TEST_ASSET_SHA256,
        )

        self.assertFalse(report["eligible"])
        self.assertTrue(report["provisional_eligible"])
        self.assertFalse(report["stream_complete"])
        self.assertEqual(report["route"], "native")
        self.assertEqual(parsed["matching_event_count"], 3)
        self.assertEqual(parsed["ignored_line_count"], 1)
        self.assertEqual(
            report["latencies"]["cold_request_to_first_draw_ms"], 200.0
        )
        self.assertEqual(
            report["latencies"]["open_request_to_first_draw_ms"], 100.0
        )
        self.assertIsNone(
            report["latencies"]["warm_request_to_first_draw_ms"]
        )
        self.assertFalse(report["latencies"]["warm_measurement_available"])
        self.assertEqual(report["sessions"][0]["serial"], 12)
        self.assertEqual(report["sessions"][0]["native_selected_serial"], 12)
        self.assertEqual(report["sessions"][0]["first_frame_drawn_serial"], 14)
        with self.assertRaises(run_suite.NativeProofIneligible):
            run_suite.require_wam_native_proof(report)
        run_suite.require_wam_native_provisional_proof(report)

    def test_native_proof_rejects_same_label_with_different_exact_bytes(self):
        with tempfile.TemporaryDirectory() as temporary:
            first = Path(temporary) / "first" / "movie.mkv"
            second = Path(temporary) / "second" / "movie.mkv"
            first.parent.mkdir()
            second.parent.mkdir()
            first.write_bytes(b"first exact media bytes")
            second.write_bytes(b"second exact media bytes")
            first_identity = run_suite._clip_metadata(first.resolve())
            second_identity = run_suite._clip_metadata(second.resolve())

        self.assertEqual(first.name, second.name)
        self.assertNotEqual(first_identity["sha256"], second_identity["sha256"])
        raw = "\n".join(
            [
                native_event(
                    "open_requested",
                    1_100_000_000,
                    source_key=7,
                    asset_sha256=first_identity["sha256"],
                ),
                native_event(
                    "native_selected",
                    1_120_000_000,
                    route="native",
                    route_proof=True,
                    source_key=7,
                    attempt=11,
                    serial=12,
                    generation=13,
                    asset_sha256=first_identity["sha256"],
                ),
                native_event(
                    "first_frame_drawn",
                    1_150_000_000,
                    route="native",
                    attempt=11,
                    serial=14,
                    generation=13,
                    draw_sequence=1,
                    asset_sha256=first_identity["sha256"],
                ),
            ]
        )
        parsed = run_suite.parse_wam_native_telemetry(raw)
        parsed["availability"] = "available"
        report = run_suite.summarize_wam_native_proof(
            parsed,
            1_000_000_000,
            TEST_RUN_ID,
            TEST_PROCESS_ID,
            TEST_PROCESS_START_ABSTIME,
            second_identity["sha256"],
        )
        self.assertFalse(report["eligible"])
        self.assertFalse(report["required_evidence"]["expected_asset_identity"])
        self.assertIn("launched clip bytes", "; ".join(report["reasons"]))

    def test_native_proof_rejects_mixed_asset_identity_in_raw_events(self):
        raw = "\n".join(
            [
                native_event("open_requested", 1_100_000_000, source_key=7),
                native_event(
                    "native_selected",
                    1_120_000_000,
                    route="native",
                    route_proof=True,
                    source_key=7,
                    attempt=11,
                    serial=12,
                    generation=13,
                ),
                native_event(
                    "first_frame_drawn",
                    1_150_000_000,
                    route="native",
                    attempt=11,
                    serial=14,
                    generation=13,
                    draw_sequence=1,
                    asset_sha256="cd" * 32,
                ),
            ]
        )
        parsed = run_suite.parse_wam_native_telemetry(raw)
        parsed["availability"] = "available"
        report = run_suite.summarize_wam_native_proof(
            parsed, 1_000_000_000, expected_asset_sha256=TEST_ASSET_SHA256
        )
        self.assertFalse(report["eligible"])
        self.assertFalse(report["required_evidence"]["single_asset_identity"])

    def test_native_parser_rejects_noncanonical_asset_sha256(self):
        parsed = run_suite.parse_wam_native_telemetry(
            native_event(
                "open_requested",
                1_100_000_000,
                source_key=7,
                asset_sha256=TEST_ASSET_SHA256.upper(),
            )
        )
        self.assertEqual(parsed["matching_event_count"], 0)
        self.assertIn("64 lowercase hex", parsed["parse_errors"][0])

    def test_native_proof_rejects_swapped_run_or_process_identity(self):
        raw = "\n".join(
            [
                native_event("open_requested", 1_100_000_000, source_key=7),
                native_event(
                    "native_selected",
                    1_120_000_000,
                    route="native",
                    route_proof=True,
                    source_key=7,
                    attempt=11,
                    serial=12,
                    generation=13,
                ),
                native_event(
                    "first_frame_drawn",
                    1_150_000_000,
                    route="native",
                    attempt=11,
                    serial=14,
                    generation=13,
                    draw_sequence=1,
                ),
            ]
        )
        parsed = run_suite.parse_wam_native_telemetry(raw)
        parsed["availability"] = "available"

        wrong_run = run_suite.summarize_wam_native_proof(
            parsed,
            1_000_000_000,
            "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
            TEST_PROCESS_ID,
            TEST_PROCESS_START_ABSTIME,
        )
        wrong_process = run_suite.summarize_wam_native_proof(
            parsed,
            1_000_000_000,
            TEST_RUN_ID,
            TEST_PROCESS_ID + 1,
            TEST_PROCESS_START_ABSTIME,
        )
        wrong_start = run_suite.summarize_wam_native_proof(
            parsed,
            1_000_000_000,
            TEST_RUN_ID,
            TEST_PROCESS_ID,
            TEST_PROCESS_START_ABSTIME + 1,
        )

        for report in (wrong_run, wrong_process, wrong_start):
            self.assertFalse(report["eligible"])
            self.assertFalse(report["required_evidence"]["expected_process_identity"])
            self.assertIn("does not match", "; ".join(report["reasons"]))

    def test_native_proof_rejects_mixed_telemetry_processes(self):
        raw = "\n".join(
            [
                native_event("open_requested", 1_100_000_000, source_key=7),
                native_event(
                    "native_selected",
                    1_120_000_000,
                    route="native",
                    route_proof=True,
                    source_key=7,
                    attempt=11,
                    serial=12,
                    generation=13,
                ),
                native_event(
                    "first_frame_drawn",
                    1_150_000_000,
                    route="native",
                    attempt=11,
                    serial=14,
                    generation=13,
                    draw_sequence=1,
                    process_id=TEST_PROCESS_ID + 1,
                ),
            ]
        )
        parsed = run_suite.parse_wam_native_telemetry(raw)
        parsed["availability"] = "available"
        report = run_suite.summarize_wam_native_proof(
            parsed, 1_000_000_000, TEST_RUN_ID, TEST_PROCESS_ID
        )
        self.assertFalse(report["eligible"])
        self.assertFalse(report["required_evidence"]["single_process_identity"])

    def test_second_in_process_open_is_the_only_warm_latency_source(self):
        raw = "\n".join(
            [
                native_event("open_requested", 1_100_000_000, source_key=7),
                native_event(
                    "native_selected",
                    1_110_000_000,
                    route="native",
                    route_proof=True,
                    source_key=7,
                    attempt=11,
                    serial=12,
                    generation=13,
                ),
                native_event(
                    "first_frame_drawn",
                    1_150_000_000,
                    route="native",
                    attempt=11,
                    serial=14,
                    generation=13,
                    draw_sequence=1,
                ),
                native_event("open_requested", 2_000_000_000, source_key=8),
                native_event(
                    "native_selected",
                    2_010_000_000,
                    route="native",
                    route_proof=True,
                    source_key=8,
                    attempt=21,
                    serial=22,
                    generation=23,
                ),
                native_event(
                    "first_frame_drawn",
                    2_050_000_000,
                    route="native",
                    attempt=21,
                    serial=24,
                    generation=23,
                    draw_sequence=2,
                ),
            ]
        )
        parsed = run_suite.parse_wam_native_telemetry(raw)
        parsed["availability"] = "available"
        report = run_suite.summarize_wam_native_proof(parsed, 1_000_000_000)
        self.assertFalse(report["eligible"])
        self.assertTrue(report["provisional_eligible"])
        self.assertTrue(report["latencies"]["warm_measurement_available"])
        self.assertEqual(
            report["latencies"]["warm_request_to_first_draw_ms"], 50.0
        )

    def test_matching_fallback_makes_proven_native_run_ineligible(self):
        raw = "\n".join(
            [
                native_event("open_requested", 1_100_000_000, source_key=7),
                native_event(
                    "native_selected",
                    1_120_000_000,
                    route="native",
                    route_proof=True,
                    source_key=7,
                    attempt=11,
                    serial=12,
                    generation=13,
                ),
                native_event(
                    "first_frame_drawn",
                    1_125_000_000,
                    route="native",
                    attempt=11,
                    serial=14,
                    generation=13,
                    draw_sequence=1,
                ),
                native_event(
                    "fallback_selected",
                    1_130_000_000,
                    route="fallback",
                    route_proof=True,
                    source_key=7,
                    # Compatibility fallback owns a fresh Router attempt even
                    # though it is replacing this exact source/open segment.
                    attempt=21,
                    serial=14,
                ),
            ]
        )
        parsed = run_suite.parse_wam_native_telemetry(raw)
        parsed["availability"] = "available"
        report = run_suite.summarize_wam_native_proof(parsed, 1_000_000_000)
        self.assertFalse(report["eligible"])
        self.assertEqual(report["route"], "fallback")
        self.assertTrue(report["required_evidence"]["first_frame_drawn"])
        self.assertFalse(report["required_evidence"]["no_fallback_selected"])
        with self.assertRaisesRegex(run_suite.NativeProofIneligible, "fallback_selected"):
            run_suite.require_wam_native_proof(report)

    def test_draw_must_advance_same_attempt_and_generation(self):
        raw = "\n".join(
            [
                native_event("open_requested", 1_100_000_000, source_key=7),
                native_event(
                    "native_selected",
                    1_120_000_000,
                    route="native",
                    route_proof=True,
                    source_key=7,
                    attempt=11,
                    serial=12,
                    generation=13,
                ),
                native_event(
                    "first_frame_drawn",
                    1_130_000_000,
                    route="native",
                    attempt=11,
                    serial=12,
                    generation=13,
                    draw_sequence=1,
                ),
                native_event(
                    "first_frame_drawn",
                    1_140_000_000,
                    route="native",
                    attempt=11,
                    serial=14,
                    generation=99,
                    draw_sequence=2,
                ),
                native_event(
                    "first_frame_drawn",
                    1_150_000_000,
                    route="native",
                    attempt=99,
                    serial=14,
                    generation=13,
                    draw_sequence=3,
                ),
            ]
        )
        parsed = run_suite.parse_wam_native_telemetry(raw)
        parsed["availability"] = "available"
        report = run_suite.summarize_wam_native_proof(parsed, 1_000_000_000)
        self.assertFalse(report["eligible"])
        self.assertFalse(report["required_evidence"]["first_frame_drawn"])
        self.assertEqual(report["sessions"], [])

    def test_any_valid_fallback_after_initial_open_poisons_native_trial(self):
        raw = "\n".join(
            [
                native_event("open_requested", 1_100_000_000, source_key=7),
                native_event(
                    "native_selected",
                    1_120_000_000,
                    route="native",
                    route_proof=True,
                    source_key=7,
                    attempt=11,
                    serial=12,
                    generation=13,
                ),
                native_event(
                    "fallback_selected",
                    1_130_000_000,
                    route="fallback",
                    route_proof=True,
                    source_key=99,
                    attempt=51,
                    serial=52,
                ),
                native_event(
                    "first_frame_drawn",
                    1_150_000_000,
                    route="native",
                    attempt=11,
                    serial=14,
                    generation=13,
                    draw_sequence=1,
                ),
                native_event("open_requested", 2_000_000_000, source_key=8),
                native_event(
                    "fallback_selected",
                    2_010_000_000,
                    route="fallback",
                    route_proof=True,
                    source_key=8,
                    attempt=21,
                    serial=22,
                ),
            ]
        )
        parsed = run_suite.parse_wam_native_telemetry(raw)
        parsed["availability"] = "available"
        report = run_suite.summarize_wam_native_proof(parsed, 1_000_000_000)
        self.assertFalse(report["eligible"])
        self.assertEqual(report["route"], "fallback")
        self.assertEqual(len(report["fallback_events"]), 2)
        self.assertEqual(report["unrelated_fallback_events"], [])
        self.assertFalse(report["required_evidence"]["no_fallback_selected"])

    def test_preopen_and_nonproof_fallback_records_are_diagnostic_only(self):
        raw = "\n".join(
            [
                native_event(
                    "fallback_selected",
                    1_000_000_000,
                    route="fallback",
                    route_proof=True,
                    source_key=99,
                    attempt=98,
                    serial=97,
                ),
                native_event("open_requested", 1_100_000_000, source_key=7),
                native_event(
                    "fallback_selected",
                    1_110_000_000,
                    route="fallback",
                    route_proof=False,
                    source_key=7,
                    attempt=8,
                    serial=9,
                ),
                native_event(
                    "native_selected",
                    1_120_000_000,
                    route="native",
                    route_proof=True,
                    source_key=7,
                    attempt=11,
                    serial=12,
                    generation=13,
                ),
                native_event(
                    "first_frame_drawn",
                    1_150_000_000,
                    route="native",
                    attempt=11,
                    serial=14,
                    generation=13,
                    draw_sequence=1,
                ),
            ]
        )
        parsed = run_suite.parse_wam_native_telemetry(raw)
        parsed["availability"] = "available"
        report = run_suite.summarize_wam_native_proof(parsed, 1_000_000_000)
        self.assertFalse(report["eligible"])
        self.assertTrue(report["provisional_eligible"])
        self.assertEqual(report["fallback_events"], [])
        self.assertEqual(len(report["unrelated_fallback_events"]), 2)

    def test_libmpv_initialized_in_initial_lineage_is_ineligible(self):
        raw = "\n".join(
            [
                native_event("open_requested", 1_100_000_000, source_key=7),
                native_event(
                    "native_selected",
                    1_120_000_000,
                    route="native",
                    route_proof=True,
                    source_key=7,
                    attempt=11,
                    serial=12,
                    generation=13,
                ),
                native_event(
                    "first_frame_drawn",
                    1_150_000_000,
                    route="native",
                    attempt=11,
                    serial=14,
                    generation=13,
                    draw_sequence=1,
                    libmpv_initialized=True,
                ),
            ]
        )
        parsed = run_suite.parse_wam_native_telemetry(raw)
        parsed["availability"] = "available"
        report = run_suite.summarize_wam_native_proof(parsed, 1_000_000_000)
        self.assertFalse(report["eligible"])
        self.assertFalse(report["libmpv_never_initialized"])
        self.assertFalse(
            report["required_evidence"]["libmpv_never_initialized"]
        )
        with self.assertRaisesRegex(run_suite.NativeProofIneligible, "libmpv"):
            run_suite.require_wam_native_proof(report)

    def test_libmpv_initialized_on_later_open_poisons_entire_trial(self):
        raw = "\n".join(
            [
                native_event("open_requested", 1_100_000_000, source_key=7),
                native_event(
                    "native_selected",
                    1_120_000_000,
                    route="native",
                    route_proof=True,
                    source_key=7,
                    attempt=11,
                    serial=12,
                    generation=13,
                ),
                native_event(
                    "first_frame_drawn",
                    1_150_000_000,
                    route="native",
                    attempt=11,
                    serial=14,
                    generation=13,
                    draw_sequence=1,
                ),
                native_event("open_requested", 2_000_000_000, source_key=8),
                native_event(
                    "native_selected",
                    2_010_000_000,
                    route="native",
                    route_proof=True,
                    source_key=8,
                    attempt=21,
                    serial=22,
                    generation=23,
                ),
                native_event(
                    "first_frame_drawn",
                    2_050_000_000,
                    route="native",
                    attempt=21,
                    serial=24,
                    generation=23,
                    draw_sequence=2,
                ),
                native_event(
                    "preview_demanded",
                    2_100_000_000,
                    source_key=8,
                    attempt=21,
                    gesture=31,
                    request=32,
                    libmpv_initialized=True,
                ),
            ]
        )
        parsed = run_suite.parse_wam_native_telemetry(raw)
        parsed["availability"] = "available"
        report = run_suite.summarize_wam_native_proof(parsed, 1_000_000_000)
        self.assertFalse(report["eligible"])
        self.assertFalse(report["libmpv_never_initialized"])
        self.assertEqual(len(report["sessions"]), 2)
        self.assertIn("after the trial's initial open", "; ".join(report["reasons"]))


class ProcessTests(unittest.TestCase):
    PS_FIXTURE = """\
  101     1 Sun Aug 10 19:23:09 2026 /Applications/VLC.app/Contents/MacOS/VLC
  202     1 Sun Aug 10 19:23:10 2026 /System/Applications/QuickTime Player.app/Contents/MacOS/QuickTime Player
  303     1 Sun Aug 10 19:23:11 2026 /System/Library/Frameworks/VideoToolbox.framework/XPCServices/VTDecoderXPCService.xpc/Contents/MacOS/VTDecoderXPCService
"""

    def test_process_table_preserves_executable_spaces(self):
        table = run_suite.parse_process_table(self.PS_FIXTURE)
        self.assertEqual(table[202].ppid, 1)
        self.assertEqual(
            table[202].executable,
            "/System/Applications/QuickTime Player.app/Contents/MacOS/QuickTime Player",
        )
        self.assertEqual(list(run_suite.helper_processes(table)), [303])

    def test_resource_coalition_parser_reads_id_and_bundle(self):
        coalition = run_suite.parse_resource_coalition(
            """\
pid/42 = {
\tresource coalition = {
\t\tID = 27910
\t\ttype = resource
\t\tactive count = 2
\t\tname = application.org.videolan.vlc.1.2
\t\tbundle ID = org.videolan.vlc
\t}
}
"""
        )
        self.assertEqual(coalition.coalition_id, 27910)
        self.assertEqual(coalition.bundle_id, "org.videolan.vlc")
        self.assertEqual(coalition.active_count, 2)

    def test_resource_coalition_parser_fails_closed_without_active_count(self):
        with self.assertRaisesRegex(ValueError, "active process count"):
            run_suite.parse_resource_coalition(
                """\
pid/42 = {
\tresource coalition = {
\t\tID = 27910
\t\ttype = resource
\t\tbundle ID = com.wesleymaa.wam
\t}
}
"""
            )

    def test_helper_partition_uses_exact_resource_coalition(self):
        helper = "/System/VTDecoderXPCService"
        owned = run_suite.ProcessIdentity(301, 1, "start one", helper)
        unrelated = run_suite.ProcessIdentity(302, 1, "start two", helper)
        coalitions = {
            301: run_suite.ResourceCoalition(77, "target", "com.example.wam"),
            302: run_suite.ResourceCoalition(88, "other", "org.videolan.vlc"),
        }
        with mock.patch.object(
            run_suite,
            "process_resource_coalition",
            side_effect=lambda pid: coalitions[pid],
        ):
            target, ignored = run_suite.partition_new_helpers_by_coalition(
                [owned, unrelated], 77
            )
        self.assertEqual(target, [owned])
        self.assertEqual(ignored[0]["process"]["pid"], 302)
        self.assertEqual(ignored[0]["resource_coalition"]["coalition_id"], 88)

    def test_decoder_helper_continuity_retains_exact_identity_samples(self):
        main = run_suite.ProcessIdentity(101, 1, "main start", "/app/WAM")
        helper = run_suite.ProcessIdentity(
            202,
            1,
            "helper start",
            "/System/Library/VTDecoderXPCService",
        )
        tracker = run_suite.DecoderHelperContinuityTracker(
            {},
            main,
            [helper],
            77,
            require_helper=True,
            table_reader=lambda: {101: main, 202: helper},
            coalition_reader=lambda pid: run_suite.ResourceCoalition(
                77, "target", "com.example.wam", 2
            ),
            clock_ns=iter((100, 200)).__next__,
        )
        tracker.sample()
        tracker.sample()
        report = tracker.report()

        self.assertTrue(report["valid"])
        self.assertEqual(report["sample_count"], 2)
        self.assertEqual(report["expected_helpers"], [helper.as_dict()])
        for sample in report["samples"]:
            evidence = sample["helpers"][0]
            self.assertEqual(evidence["process"], helper.as_dict())
            self.assertEqual(evidence["resource_coalition"]["coalition_id"], 77)
            active_count = sample["coalition_active_count_check"]
            self.assertEqual(active_count["expected_active_count"], 2)
            self.assertTrue(active_count["all_observations_present"])
            self.assertTrue(active_count["all_match"])
            self.assertEqual(
                [item["role"] for item in active_count["observations"]],
                ["app", "decoder_helper"],
            )
        run_suite.require_clean_decoder_helper_continuity(report)

    def test_decoder_helper_continuity_rejects_missing_active_count(self):
        main = run_suite.ProcessIdentity(101, 1, "main start", "/app/WAM")
        helper = run_suite.ProcessIdentity(
            202, 1, "helper start", "/System/VTDecoderXPCService"
        )
        coalitions = {
            101: run_suite.ResourceCoalition(77, "target", "com.example.wam", 2),
            202: run_suite.ResourceCoalition(77, "target", "com.example.wam", None),
        }
        tracker = run_suite.DecoderHelperContinuityTracker(
            {},
            main,
            [helper],
            77,
            require_helper=True,
            table_reader=lambda: {101: main, 202: helper},
            coalition_reader=lambda pid: coalitions[pid],
            clock_ns=lambda: 100,
        )
        tracker.sample()
        report = tracker.report()

        self.assertFalse(report["valid"])
        self.assertFalse(report["samples"][0]["coalition_active_count_check"]["all_match"])
        self.assertIn(
            "resource_coalition_active_count_missing",
            [item["reason"] for item in report["violations"]],
        )

    def test_decoder_helper_continuity_rejects_unclassified_surplus_member(self):
        main = run_suite.ProcessIdentity(101, 1, "main start", "/app/WAM")
        helper = run_suite.ProcessIdentity(
            202, 1, "helper start", "/System/VTDecoderXPCService"
        )
        tracker = run_suite.DecoderHelperContinuityTracker(
            {},
            main,
            [helper],
            77,
            require_helper=True,
            table_reader=lambda: {101: main, 202: helper},
            coalition_reader=lambda pid: run_suite.ResourceCoalition(
                77, "target", "com.example.wam", 3
            ),
            clock_ns=lambda: 100,
        )
        tracker.sample()
        report = tracker.report()

        self.assertFalse(report["valid"])
        check = report["samples"][0]["coalition_active_count_check"]
        self.assertEqual(check["expected_active_count"], 2)
        self.assertEqual(
            {item["active_count"] for item in check["observations"]}, {3}
        )
        self.assertIn(
            "resource_coalition_surplus_member",
            [item["reason"] for item in report["violations"]],
        )

    def test_decoder_helper_continuity_rechecks_active_count_every_sample(self):
        main = run_suite.ProcessIdentity(101, 1, "main start", "/app/WAM")
        helper = run_suite.ProcessIdentity(
            202, 1, "helper start", "/System/VTDecoderXPCService"
        )
        coalitions = iter(
            (
                run_suite.ResourceCoalition(77, "target", "com.example.wam", 2),
                run_suite.ResourceCoalition(77, "target", "com.example.wam", 2),
                run_suite.ResourceCoalition(77, "target", "com.example.wam", 3),
                run_suite.ResourceCoalition(77, "target", "com.example.wam", 3),
            )
        )
        tracker = run_suite.DecoderHelperContinuityTracker(
            {},
            main,
            [helper],
            77,
            require_helper=True,
            table_reader=lambda: {101: main, 202: helper},
            coalition_reader=lambda pid: next(coalitions),
            clock_ns=iter((100, 200)).__next__,
        )
        tracker.sample()
        tracker.sample()
        report = tracker.report()

        self.assertTrue(report["samples"][0]["coalition_active_count_check"]["all_match"])
        self.assertFalse(report["samples"][1]["coalition_active_count_check"]["all_match"])
        surplus = next(
            item
            for item in report["violations"]
            if item["reason"] == "resource_coalition_surplus_member"
        )
        self.assertEqual(surplus["first_observed_sample"], 1)

    def test_decoder_helper_continuity_rejects_transient_late_helper(self):
        main = run_suite.ProcessIdentity(101, 1, "main start", "/app/WAM")
        helper = run_suite.ProcessIdentity(
            202, 1, "helper start", "/System/VTDecoderXPCService"
        )
        late = run_suite.ProcessIdentity(
            303, 1, "late start", "/System/VTDecoderXPCService"
        )
        tables = iter(
            (
                {101: main, 202: helper},
                {101: main, 202: helper, 303: late},
                {101: main, 202: helper},
            )
        )
        tracker = run_suite.DecoderHelperContinuityTracker(
            {},
            main,
            [helper],
            77,
            require_helper=True,
            table_reader=lambda: next(tables),
            coalition_reader=lambda pid: run_suite.ResourceCoalition(
                77, "target", "com.example.wam", 3
            ),
            clock_ns=iter((100, 200, 300)).__next__,
        )
        tracker.sample()
        tracker.sample()
        tracker.sample()
        report = tracker.report()

        self.assertFalse(report["valid"])
        self.assertEqual(
            [item["process"]["pid"] for item in report["ever_seen_same_coalition_helpers"]],
            [202, 303],
        )
        self.assertIn(
            "late_same_coalition_decoder_helper",
            [item["reason"] for item in report["violations"]],
        )
        with self.assertRaisesRegex(run_suite.SuiteError, "late_same_coalition"):
            run_suite.require_clean_decoder_helper_continuity(report)

    def test_decoder_helper_pid_start_swap_is_not_the_same_identity(self):
        main = run_suite.ProcessIdentity(101, 1, "main start", "/app/WAM")
        expected = run_suite.ProcessIdentity(
            202, 1, "old helper start", "/System/VTDecoderXPCService"
        )
        swapped = run_suite.dataclasses.replace(expected, started="new helper start")
        tracker = run_suite.DecoderHelperContinuityTracker(
            {},
            main,
            [expected],
            77,
            require_helper=True,
            table_reader=lambda: {101: main, 202: swapped},
            coalition_reader=lambda pid: run_suite.ResourceCoalition(
                77, "target", "com.example.wam", 2
            ),
            clock_ns=lambda: 100,
        )
        sample = tracker.sample()
        report = tracker.report()

        self.assertFalse(report["valid"])
        violation = report["violations"][0]
        self.assertEqual(violation["reason"], "decoder_helper_identity_changed")
        self.assertEqual(violation["process"]["started"], "new helper start")
        self.assertEqual(sample["helpers"][0]["process"]["started"], "new helper start")
        self.assertFalse(sample["helpers"][0]["expected_at_measurement_start"])

    def test_decoder_helper_continuity_accepts_exact_maximum_observation_gap(self):
        main = run_suite.ProcessIdentity(101, 1, "main start", "/app/WAM")
        helper = run_suite.ProcessIdentity(
            202, 1, "helper start", "/System/VTDecoderXPCService"
        )
        tracker = run_suite.DecoderHelperContinuityTracker(
            {},
            main,
            [helper],
            77,
            require_helper=True,
            table_reader=lambda: {101: main, 202: helper},
            coalition_reader=lambda pid: run_suite.ResourceCoalition(
                77, "target", "com.example.wam", 2
            ),
            clock_ns=iter(
                (100, 100 + run_suite.DECODER_HELPER_MAX_OBSERVATION_GAP_NS)
            ).__next__,
        )
        tracker.sample()
        tracker.sample()
        report = tracker.report()
        self.assertTrue(report["valid"])
        self.assertEqual(
            report["maximum_observation_gap_ns"],
            run_suite.DECODER_HELPER_MAX_OBSERVATION_GAP_NS,
        )

    def test_decoder_helper_continuity_rejects_one_ns_over_maximum_gap(self):
        main = run_suite.ProcessIdentity(101, 1, "main start", "/app/WAM")
        helper = run_suite.ProcessIdentity(
            202, 1, "helper start", "/System/VTDecoderXPCService"
        )
        tracker = run_suite.DecoderHelperContinuityTracker(
            {},
            main,
            [helper],
            77,
            require_helper=True,
            table_reader=lambda: {101: main, 202: helper},
            coalition_reader=lambda pid: run_suite.ResourceCoalition(
                77, "target", "com.example.wam", 2
            ),
            clock_ns=iter(
                (
                    100,
                    101 + run_suite.DECODER_HELPER_MAX_OBSERVATION_GAP_NS,
                )
            ).__next__,
        )
        tracker.sample()
        tracker.sample()
        report = tracker.report()
        self.assertFalse(report["valid"])
        self.assertIn(
            "decoder_helper_observation_gap",
            [item["reason"] for item in report["violations"]],
        )

    def test_decoder_helper_expected_pid_identity_must_be_unique(self):
        main = run_suite.ProcessIdentity(101, 1, "main start", "/app/WAM")
        first = run_suite.ProcessIdentity(
            202, 1, "old helper start", "/System/VTDecoderXPCService"
        )
        reused = run_suite.dataclasses.replace(first, started="new helper start")
        with self.assertRaisesRegex(run_suite.SuiteError, "unique by PID and start"):
            run_suite.DecoderHelperContinuityTracker(
                {}, main, [first, reused], 77, require_helper=True
            )

    def test_relative_command_never_matches_by_basename(self):
        self.assertFalse(
            run_suite.same_executable(
                "build/WAM.app/Contents/MacOS/WAM",
                Path("/private/tmp/benchmark/WAM.app/Contents/MacOS/WAM"),
            )
        )

    def test_relative_process_path_is_resolved_from_kernel(self):
        relative = run_suite.ProcessIdentity(
            404, 1, "start", "build/WAM.app/Contents/MacOS/WAM"
        )
        resolved = run_suite.resolve_relative_process_paths(
            {404: relative}, lambda pid: "/repo/build/WAM.app/Contents/MacOS/WAM"
        )
        self.assertEqual(
            resolved[404].executable,
            "/repo/build/WAM.app/Contents/MacOS/WAM",
        )

    def test_termination_never_signals_changed_identity(self):
        original = run_suite.ProcessIdentity(101, 1, "Sun Aug 10 19:23:09 2026", "/app/WAM")
        reused = run_suite.ProcessIdentity(101, 1, "Sun Aug 10 20:00:00 2026", "/app/WAM")
        with mock.patch.object(run_suite, "process_table", return_value={101: reused}), mock.patch.object(
            run_suite.os, "kill"
        ) as kill:
            result = run_suite.terminate_exact(original, timeout=0)
        self.assertEqual(result["status"], "identity_changed_not_signaled")
        kill.assert_not_called()

    def test_termination_uses_sigterm_for_exact_identity(self):
        identity = run_suite.ProcessIdentity(101, 1, "Sun Aug 10 19:23:09 2026", "/app/WAM")
        states = iter(({101: identity}, {}))
        with mock.patch.object(run_suite, "process_table", side_effect=lambda: next(states)), mock.patch.object(
            run_suite.os, "kill"
        ) as kill:
            result = run_suite.terminate_exact(identity, timeout=1)
        self.assertEqual(result["status"], "exited_after_sigterm")
        kill.assert_called_once_with(101, signal.SIGTERM)

    def test_companion_player_allows_lstart_rounding_but_rejects_later_launch(self):
        executable = Path("/Applications/VLC.app/Contents/MacOS/VLC")
        main = run_suite.ProcessIdentity(
            101, 1, "Mon Aug 10 22:17:06 2026", str(executable)
        )
        companion = run_suite.ProcessIdentity(
            102, 1, "Mon Aug 10 22:17:07 2026", str(executable)
        )
        with mock.patch.object(
            run_suite, "process_table", return_value={101: main, 102: companion}
        ):
            found = run_suite.discover_companion_players_during_warmup(
                {}, main, executable, 0
            )
        self.assertEqual(found, {102: companion})

        unrelated = run_suite.ProcessIdentity(
            103, 1, "Mon Aug 10 22:17:10 2026", str(executable)
        )
        with mock.patch.object(
            run_suite, "process_table", return_value={101: main, 103: unrelated}
        ), self.assertRaisesRegex(run_suite.SuiteError, "outside the launch grace"):
            run_suite.discover_companion_players_during_warmup(
                {}, main, executable, 0
            )

    def test_vlc_launch_log_rejects_audio_only_clock_progress(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "vlc.log"
            path.write_text(
                "main decoder error: failed to create video output\n"
                "main decoder error: buffer deadlock prevented\n",
                encoding="utf-8",
            )
            with self.assertRaisesRegex(run_suite.SuiteError, "fatal video-output"):
                run_suite.require_viable_video_output("vlc", path)

            path.write_text("ordinary informational output\n", encoding="utf-8")
            validation = run_suite.require_viable_video_output("vlc", path)
            self.assertEqual(validation["fatal_video_patterns"], [])

    def test_clock_progress_is_rate_and_wall_time_aware(self):
        validation = run_suite.require_clock_progress(
            "quicktime",
            {"current_time_s": 4.0},
            {"current_time_s": 44.3},
            elapsed_s=20.0,
            speed=2.0,
        )
        self.assertAlmostEqual(validation["residual_s"], 0.3)

        with self.assertRaisesRegex(run_suite.SuiteError, "timeline did not match"):
            run_suite.require_clock_progress(
                "vlc",
                {"current_time_s": 4.0},
                {"current_time_s": 7.0},
                elapsed_s=20.0,
                speed=1.0,
            )


class CommandTests(unittest.TestCase):
    def test_osascript_timeout_is_retryable_result(self):
        with mock.patch.object(
            run_suite.subprocess,
            "run",
            side_effect=run_suite.subprocess.TimeoutExpired(["osascript"], 3),
        ):
            result = run_suite._osascript("return 1")
        self.assertEqual(result.returncode, 124)
        self.assertIn("timed out", result.stderr)

    def test_exact_wam_orderly_quit_requires_pid_bundle_and_exit(self):
        identity = run_suite.ProcessIdentity(42, 1, "now", "/WAM.app/Contents/MacOS/WAM")
        with (
            mock.patch.object(run_suite, "process_table", side_effect=[{42: identity}, {}]),
            mock.patch.object(
                run_suite,
                "_osascript",
                return_value=run_suite.subprocess.CompletedProcess([], 0, "", ""),
            ) as invoke,
        ):
            report = run_suite.quit_exact_wam_orderly(identity, timeout=0.1)
        self.assertEqual(report["status"], "exited_after_orderly_quit")
        args = invoke.call_args.kwargs["arguments"]
        self.assertEqual(args, ("42", "com.wesleymaa.wam"))

    def test_exact_wam_orderly_quit_failure_never_falls_through_as_success(self):
        identity = run_suite.ProcessIdentity(42, 1, "now", "/WAM.app/Contents/MacOS/WAM")
        with (
            mock.patch.object(run_suite, "process_table", return_value={42: identity}),
            mock.patch.object(
                run_suite,
                "_osascript",
                return_value=run_suite.subprocess.CompletedProcess([], 1, "", "denied"),
            ),
        ):
            report = run_suite.quit_exact_wam_orderly(identity, timeout=0.1)
        self.assertEqual(report["status"], "orderly_quit_not_requested")
        self.assertEqual(report["error"], "denied")

    def test_exact_wam_orderly_quit_rejects_pid_reuse_before_request(self):
        identity = run_suite.ProcessIdentity(42, 1, "now", "/WAM.app/Contents/MacOS/WAM")
        replacement = run_suite.ProcessIdentity(
            42, 2, "later", "/WAM.app/Contents/MacOS/WAM"
        )
        with (
            mock.patch.object(run_suite, "process_table", return_value={42: replacement}),
            mock.patch.object(run_suite, "_osascript") as invoke,
        ):
            report = run_suite.quit_exact_wam_orderly(identity, timeout=0.1)
        self.assertEqual(report["status"], "identity_changed_not_requested")
        invoke.assert_not_called()

    def test_wam_command_has_exact_rate(self):
        command = run_suite.build_player_command(
            "wam",
            Path("/Applications/WAM.app/Contents/MacOS/WAM"),
            Path("/tmp/movie.mp4"),
            2.0,
            0.0,
            (1180, 720),
        )
        self.assertEqual(
            command,
            [
                "/usr/bin/open",
                "-n",
                "-W",
                "-a",
                "/Applications/WAM.app",
                "--args",
                "--rate=2",
                "/tmp/movie.mp4",
            ],
        )

    def test_wam_telemetry_command_rejects_bad_candidate_identity(self):
        with self.assertRaisesRegex(run_suite.SuiteError, "candidate ID"):
            run_suite.build_player_command(
                "wam",
                Path("/Applications/WAM.app/Contents/MacOS/WAM"),
                Path("/tmp/movie.mp4"),
                1.0,
                0.0,
                (1180, 720),
                Path("/tmp/result.wam.native.jsonl"),
                TEST_RUN_ID,
                TEST_ASSET_SHA256,
                TEST_CANDIDATE_ID.upper(),
            )

    def test_wam_telemetry_command_uses_launchservices_env_and_separate_stderr(self):
        telemetry = Path("/tmp/result.wam.native.jsonl")
        command = run_suite.build_player_command(
            "wam",
            Path("/Applications/WAM.app/Contents/MacOS/WAM"),
            Path("/tmp/movie.mp4"),
            1.0,
            0.0,
            (1180, 720),
            telemetry,
            TEST_RUN_ID,
            TEST_ASSET_SHA256,
            TEST_CANDIDATE_ID,
        )
        self.assertEqual(
            command,
            [
                "/usr/bin/open",
                "-n",
                "-W",
                "--env",
                "WAM_NATIVE_BENCHMARK_TELEMETRY=1",
                "--env",
                f"WAM_NATIVE_BENCHMARK_RUN_ID={TEST_RUN_ID}",
                "--env",
                f"WAM_NATIVE_BENCHMARK_ASSET_SHA256={TEST_ASSET_SHA256}",
                "--env",
                f"WAM_NATIVE_BENCHMARK_CANDIDATE_ID={TEST_CANDIDATE_ID}",
                "--stderr",
                str(telemetry),
                "-a",
                "/Applications/WAM.app",
                "--args",
                "--rate=1",
                "/tmp/movie.mp4",
            ],
        )

    def test_wam_telemetry_command_requires_complete_asset_bound_identity(self):
        with self.assertRaisesRegex(run_suite.SuiteError, "must be supplied together"):
            run_suite.build_player_command(
                "wam",
                Path("/Applications/WAM.app/Contents/MacOS/WAM"),
                Path("/tmp/movie.mp4"),
                1.0,
                0.0,
                (1180, 720),
                Path("/tmp/result.wam.native.jsonl"),
                TEST_RUN_ID,
            )
        with self.assertRaisesRegex(run_suite.SuiteError, "lowercase hex"):
            run_suite.build_player_command(
                "wam",
                Path("/Applications/WAM.app/Contents/MacOS/WAM"),
                Path("/tmp/movie.mp4"),
                1.0,
                0.0,
                (1180, 720),
                Path("/tmp/result.wam.native.jsonl"),
                TEST_RUN_ID,
                TEST_ASSET_SHA256.upper(),
                TEST_CANDIDATE_ID,
            )

    def test_vlc_command_has_controlled_rate_start_and_size(self):
        command = run_suite.build_player_command(
            "vlc",
            Path("/Applications/VLC.app/Contents/MacOS/VLC"),
            Path("/tmp/movie.mp4"),
            2.0,
            7.5,
            (1180, 720),
        )
        self.assertIn("--rate=2", command)
        self.assertIn("--start-time=7.5", command)
        self.assertIn("--width=1180", command)
        self.assertIn("--height=720", command)
        self.assertIn("--no-macosx-video-autoresize", command)
        self.assertEqual(command[-1], "/tmp/movie.mp4")

    def test_quicktime_uses_supported_launchservices_route(self):
        command = run_suite.build_player_command(
            "quicktime",
            Path("/System/Applications/QuickTime Player.app/Contents/MacOS/QuickTime Player"),
            Path("/tmp/movie.mp4"),
            2.0,
            0.0,
            (1180, 720),
        )
        self.assertEqual(command[:5], [
            "/usr/bin/open",
            "-n",
            "-W",
            "-a",
            "/System/Applications/QuickTime Player.app",
        ])
        self.assertEqual(command[5], "/tmp/movie.mp4")
        self.assertEqual(
            command[6:],
            ["--args", "-ApplePersistenceIgnoreState", "YES"],
        )

    def test_collector_receives_only_explicit_identities(self):
        identities = [
            run_suite.ProcessIdentity(101, 1, "start", "/app/WAM"),
            run_suite.ProcessIdentity(202, 1, "start", "/system/VTDecoderXPCService"),
        ]
        command = run_suite.build_collector_command(
            Path("/repo/collect.py"),
            identities,
            "wam",
            "clip-id",
            "3",
            1.0,
            30.0,
            1,
            Path("/tmp/out.json"),
        )
        pid_pairs = [command[index + 1] for index, value in enumerate(command) if value == "--pid"]
        self.assertEqual(pid_pairs, ["101", "202"])
        self.assertIn("clip-id", command)

    def test_quicktime_state_parser(self):
        parsed = run_suite.parse_quicktime_state("12.5\t60\t2\ttrue\t80\t80\t1260\t800\n")
        self.assertEqual(parsed["current_time_s"], 12.5)
        self.assertEqual(parsed["rate"], 2.0)
        self.assertTrue(parsed["playing"])
        self.assertEqual(parsed["bounds"], [80, 80, 1260, 800])

    def test_vlc_state_parser(self):
        parsed = run_suite.parse_vlc_state(
            "12\t180\ttrue\t80\t80\t1260\t800\t/tmp/movie.mp4\n"
        )
        self.assertEqual(parsed["current_time_s"], 12.0)
        self.assertEqual(parsed["duration_s"], 180.0)
        self.assertTrue(parsed["playing"])
        self.assertEqual(parsed["bounds"], [80, 80, 1260, 800])
        self.assertEqual(parsed["path"], "/tmp/movie.mp4")

    def test_wam_window_state_parser(self):
        parsed = run_suite.parse_wam_window_state(
            "true\t80\t80\t1180\t720\tWAM\n"
        )
        self.assertTrue(parsed["frontmost"])
        self.assertEqual(parsed["position"], [80, 80])
        self.assertEqual(parsed["size"], [1180, 720])
        self.assertEqual(parsed["bounds"], [80, 80, 1260, 800])
        self.assertEqual(parsed["process_name"], "WAM")

    def test_target_window_state_prefers_non_activating_native_reader(self):
        native = mock.Mock()
        native.state.return_value = {
            "frontmost": True,
            "bounds": [80, 80, 1260, 800],
            "query_backend": "NSWorkspace+CoreGraphics",
        }
        with mock.patch.object(run_suite.sys, "platform", "darwin"), mock.patch.object(
            run_suite, "_NATIVE_WINDOW_READER", native
        ), mock.patch.object(run_suite, "_osascript") as osascript:
            state = run_suite.target_window_state(101)
        self.assertEqual(state["query_backend"], "NSWorkspace+CoreGraphics")
        native.state.assert_called_once_with(101)
        osascript.assert_not_called()

    def test_target_window_state_records_system_events_fallback(self):
        native = mock.Mock()
        native.state.side_effect = OSError("native unavailable")
        apple_result = run_suite.subprocess.CompletedProcess(
            ["osascript"], 0, "true\t80\t80\t1180\t720\tWAM\n", ""
        )
        with mock.patch.object(run_suite.sys, "platform", "darwin"), mock.patch.object(
            run_suite, "_NATIVE_WINDOW_READER", native
        ), mock.patch.object(run_suite, "_osascript", return_value=apple_result):
            state = run_suite.target_window_state(101)
        self.assertEqual(state["query_backend"], "System Events AppleScript fallback")
        self.assertEqual(state["native_query_error"], "native unavailable")

    def test_wam_window_validation_requires_frontmost_and_exact_bounds(self):
        expected = {
            "frontmost": True,
            "bounds": [80, 80, 1260, 800],
        }
        run_suite.require_expected_wam_window_state(expected, (1180, 720))

        with self.assertRaisesRegex(run_suite.SuiteError, "frontmost"):
            run_suite.require_expected_wam_window_state(
                {**expected, "frontmost": False}, (1180, 720)
            )
        with self.assertRaisesRegex(run_suite.SuiteError, "bounds changed"):
            run_suite.require_expected_wam_window_state(
                {**expected, "bounds": [80, 80, 1200, 800]}, (1180, 720)
            )

    def test_periodic_runner_uses_fixed_50ms_deadlines_despite_callback_cost(self):
        now = [0.0]
        callback_times = []

        class FakeProcess:
            returncode = 0

            def poll(self):
                return 0 if now[0] >= 0.149 else None

            def communicate(self):
                return "", ""

            def kill(self):
                raise AssertionError("fake process must not be killed")

        def monotonic():
            return now[0]

        def sleep(seconds):
            now[0] += seconds

        def callback():
            callback_times.append(now[0])
            # A fixed-sleep loop would drift to 60 ms. Deadline scheduling
            # must absorb this 10 ms proof-query cost.
            now[0] += 0.01

        with mock.patch.object(
            run_suite.subprocess, "Popen", return_value=FakeProcess()
        ), mock.patch.object(
            run_suite.time, "monotonic", side_effect=monotonic
        ), mock.patch.object(run_suite.time, "sleep", side_effect=sleep):
            result = run_suite.run_with_periodic_callback(
                ["collector"],
                timeout=1.0,
                callback=callback,
                poll_interval_s=run_suite.DECODER_HELPER_SAMPLE_INTERVAL_S,
            )

        self.assertEqual(result.returncode, 0)
        self.assertEqual(len(callback_times), 4)
        for observed, expected in zip(callback_times, (0.0, 0.05, 0.10, 0.15)):
            self.assertAlmostEqual(observed, expected, places=9)


class _FakeClock:
    def __init__(self):
        self.value = 0.0

    def __call__(self):
        return self.value

    def advance(self, seconds):
        self.value += seconds


class ForegroundValidityTests(unittest.TestCase):
    def setUp(self):
        self.clock = _FakeClock()
        self.identity = run_suite.ProcessIdentity(
            101,
            1,
            "Mon Aug 10 22:17:06 2026",
            "/Applications/WAM.app/Contents/MacOS/WAM",
        )
        self.state = {
            "frontmost": True,
            "bounds": [80, 80, 1260, 800],
            "process_name": "WAM",
        }

    def tracker(self, identity_reader=None):
        return run_suite.ForegroundWindowValidityTracker(
            self.identity,
            (1180, 720),
            sample_interval_s=0.5,
            identity_reader=identity_reader or (lambda pid: self.identity),
            state_reader=lambda pid: dict(self.state),
            clock=self.clock,
            timestamp=lambda: "2026-08-11T00:00:00+00:00",
        )

    def test_clean_phase_has_exact_pid_samples_and_no_contamination(self):
        tracker = self.tracker()
        tracker.begin_phase("warmup")
        self.clock.advance(0.5)
        tracker.sample_if_due()
        self.clock.advance(0.5)
        tracker.end_phase()

        report = tracker.report()
        self.assertTrue(report["valid"])
        self.assertEqual(report["contamination_intervals"], [])
        self.assertEqual(report["sample_count"], 3)
        self.assertEqual(report["sampler_overhead"]["total_query_s"], 0.0)
        self.assertFalse(
            report["sampler_overhead"]["included_in_target_process_metrics"]
        )
        self.assertTrue(
            all(sample["target_pid"] == self.identity.pid for sample in report["samples"])
        )
        run_suite.require_clean_foreground_validity(report, "warmup")

    def test_20hz_callback_does_not_overdrive_half_second_ui_queries(self):
        state_reader = mock.Mock(return_value=dict(self.state))
        tracker = run_suite.ForegroundWindowValidityTracker(
            self.identity,
            (1180, 720),
            sample_interval_s=0.5,
            identity_reader=lambda pid: self.identity,
            state_reader=state_reader,
            clock=self.clock,
            timestamp=lambda: "2026-08-11T00:00:00+00:00",
        )
        tracker.begin_phase("measurement")
        for _ in range(9):
            self.clock.advance(run_suite.DECODER_HELPER_SAMPLE_INTERVAL_S)
            tracker.sample_if_due()
        self.assertEqual(state_reader.call_count, 1)

        self.clock.value = 0.5
        tracker.sample_if_due()
        self.assertEqual(state_reader.call_count, 2)

    def test_focus_loss_is_recorded_as_an_interval_and_rejected(self):
        tracker = self.tracker()
        tracker.begin_phase("measurement")
        self.clock.advance(0.5)
        self.state["frontmost"] = False
        tracker.sample_if_due()
        self.clock.advance(0.5)
        self.state["frontmost"] = True
        tracker.sample_if_due()
        tracker.end_phase()

        report = tracker.report()
        self.assertFalse(report["valid"])
        self.assertEqual(len(report["contamination_intervals"]), 1)
        contamination = report["contamination_intervals"][0]
        self.assertEqual(contamination["phase"], "measurement")
        self.assertEqual(contamination["reasons"], ["not_frontmost"])
        self.assertAlmostEqual(contamination["duration_s"], 1.0)
        self.assertAlmostEqual(contamination["first_observed_offset_s"], 0.5)
        self.assertEqual(
            contamination["boundary_precision"], "bounded_by_adjacent_samples"
        )
        with self.assertRaisesRegex(run_suite.SuiteError, "metrics rejected"):
            run_suite.require_clean_foreground_validity(report, "measurement")

    def test_unobserved_polling_gap_is_contamination(self):
        tracker = self.tracker()
        tracker.begin_phase("warmup")
        self.clock.advance(2.0)
        tracker.sample_if_due()
        tracker.end_phase()

        report = tracker.report()
        self.assertFalse(report["valid"])
        interval = report["contamination_intervals"][0]
        self.assertIn("sampling_coverage_gap", interval["reasons"])
        self.assertEqual(interval["maximum_observed_gap_s"], 2.0)

    def test_changed_process_identity_is_contamination(self):
        changed = run_suite.dataclasses.replace(
            self.identity, started="Mon Aug 10 22:18:06 2026"
        )
        tracker = self.tracker(identity_reader=lambda pid: changed)
        tracker.begin_phase("measurement")
        tracker.end_phase()

        report = tracker.report()
        self.assertFalse(report["valid"])
        self.assertIn(
            "process_identity_changed",
            report["contamination_intervals"][0]["reasons"],
        )

    def test_render_frame_counters_are_explicitly_unavailable_without_debug_modes(self):
        for player in ("wam", "vlc", "quicktime"):
            telemetry = run_suite.render_telemetry_availability(player)
            self.assertEqual(telemetry["availability"], "unavailable")
            self.assertIsNone(telemetry["dropped_frames"])
            self.assertFalse(telemetry["playback_configuration_changed_for_telemetry"])
            self.assertTrue(telemetry["reason"])


if __name__ == "__main__":
    unittest.main()
