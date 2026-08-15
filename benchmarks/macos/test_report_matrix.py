#!/usr/bin/env python3

import csv
import io
import json
import tempfile
import unittest
from pathlib import Path

import report_matrix


MIB = 1024**2


def result_payload(
    case_id,
    *,
    cpu,
    power,
    memory_mib,
    footprint_current_mib,
    footprint_peak_mib,
    footprint_shared_mib,
    context_switches,
    faults,
    pageins,
    gpu=None,
):
    measurement_elapsed = 10.0
    gpu_summary = {
        "measurement": {"elapsed_s": measurement_elapsed},
        "aggregate": {
            "delta_accumulated_gpu_time": {
                "count": 0 if gpu is None else 1,
                "mean": gpu,
                "median": gpu,
                "max": gpu,
                "p95": gpu,
            },
            "total_delta_accumulated_gpu_time": (
                None if gpu is None else gpu * measurement_elapsed
            ),
            "accumulated_gpu_time_rate_per_s": gpu,
        }
    }
    return {
        "schema": report_matrix.RESULT_SCHEMA,
        "metadata": {"clip": case_id, "player": "fixture", "pids": [123]},
        "summary": {
            "top": {
                "measurement": {"elapsed_s": measurement_elapsed},
                "aggregate": {
                    "cpu_percent": {"mean": cpu},
                    "top_power_score": {"mean": power},
                    "memory_bytes": {"mean": memory_mib * MIB},
                    "context_switch_count_delta": {"mean": context_switches},
                    "fault_count_delta": {"mean": faults},
                    "pagein_count_delta": {"mean": pageins},
                    "total_context_switch_count_delta": context_switches * measurement_elapsed,
                    "total_fault_count_delta": faults * measurement_elapsed,
                    "total_pagein_count_delta": pageins * measurement_elapsed,
                    "context_switch_count_rate_per_s": context_switches,
                    "fault_count_rate_per_s": faults,
                    "pagein_count_rate_per_s": pageins,
                }
            },
            "footprint": {
                "aggregate": {
                    "current_phys_footprint_bytes": footprint_current_mib * MIB,
                    "peak_phys_footprint_bytes": footprint_peak_mib * MIB,
                    "shared_adjusted_footprint_bytes": footprint_shared_mib * MIB,
                }
            },
            "gpu": gpu_summary,
        },
    }


def case(case_id="case-a", *, unsupported=(), repetitions=3):
    return {
        "id": case_id,
        "group": "primary",
        "default_repetitions": repetitions,
        "expected_unsupported_players": list(unsupported),
    }


def trial(case_id, player, repetition, status, result_path=None, reason=None, detail=None):
    value = {
        "id": f"{case_id}.rep-{repetition:02d}.{player}",
        "case_id": case_id,
        "case_group": "primary",
        "player": player,
        "repetition": repetition,
        "status": status,
        "support_expectation": "unsupported" if player == "quicktime" else "supported",
    }
    if result_path is not None:
        value["result_path"] = str(result_path)
    if reason is not None:
        value["n_a"] = {"reason": reason, "detail": detail or reason, "basis": "test"}
    return value


def manifest(trials, cases=None, state="running"):
    return {
        "schema": report_matrix.MATRIX_SCHEMA,
        "suite_id": "fixture-suite",
        "state": state,
        "updated_at": "2026-08-10T00:00:00+00:00",
        "configuration": {
            "repetition_override": None,
            "player_order_by_repetition": {
                "1": ["wam", "vlc", "quicktime"],
                "2": ["vlc", "quicktime", "wam"],
                "3": ["quicktime", "wam", "vlc"],
            },
        },
        "cases": cases or [case()],
        "trials": trials,
    }


class ReportFixture(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)

    def tearDown(self):
        self.temporary.cleanup()

    def write_json(self, relative, value):
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(value), encoding="utf-8")
        return path

    def write_manifest(self, value):
        return self.write_json("manifest.json", value)

    def row(self, snapshot, case_id, player):
        return next(
            row
            for row in snapshot.rows
            if row["case_id"] == case_id and row["player"] == player
        )


class AggregateTests(ReportFixture):
    def test_median_of_run_means_with_min_max_and_real_zero(self):
        trials = []
        values = [
            (10, 1, 100, 400, 450, 390, 1000, 1, 0, 10),
            (30, 4, 200, 500, 550, 490, 2000, 2, 0, None),
            (100, 9, 300, 600, 650, 590, 3000, 3, 2, 30),
        ]
        for repetition, value in enumerate(values, 1):
            result = result_payload(
                "case-a",
                cpu=value[0],
                power=value[1],
                memory_mib=value[2],
                footprint_current_mib=value[3],
                footprint_peak_mib=value[4],
                footprint_shared_mib=value[5],
                context_switches=value[6],
                faults=value[7],
                pageins=value[8],
                gpu=value[9],
            )
            # Exercise manifest-relative result paths.
            relative = Path("results") / f"wam-{repetition}.json"
            self.write_json(relative, result)
            trials.append(trial("case-a", "wam", repetition, "completed", relative))
        path = self.write_manifest(manifest(trials, state="completed"))

        snapshot = report_matrix.build_report(path)
        row = self.row(snapshot, "case-a", "wam")

        self.assertEqual(row["report_status"], "complete")
        self.assertEqual(row["completed_repetitions"], 3)
        self.assertEqual(row["measured_repetitions"], 3)
        self.assertEqual(row["cpu_percent"], report_matrix.Aggregate(3, 30.0, 10.0, 100.0))
        self.assertEqual(row["energy_impact"].median, 4.0)
        self.assertEqual(row["memory_mib"].median, 200.0)
        self.assertEqual(row["footprint_current_mib"].median, 500.0)
        self.assertEqual(row["footprint_peak_mib"].median, 550.0)
        self.assertEqual(row["footprint_shared_adjusted_mib"].median, 490.0)
        self.assertEqual(row["context_switch_rate"].median, 2000.0)
        self.assertEqual(row["fault_rate"].median, 2.0)
        self.assertEqual(row["pagein_rate"], report_matrix.Aggregate(3, 0.0, 0.0, 2.0))
        self.assertEqual(
            row["process_gpu_counter_rate"],
            report_matrix.Aggregate(2, 20.0, 10.0, 30.0),
        )
        self.assertIn(report_matrix.GPU_METRIC, snapshot.metrics)

        rendered = report_matrix.markdown_text(snapshot)
        self.assertIn("30.00 [10.00–100.00]", rendered)
        self.assertIn("0.00 [0.00–2.00]", rendered)
        self.assertIn("AGX process counter", rendered)

    def test_legacy_result_derives_rates_from_raw_totals_and_sample_timestamps(self):
        result = result_payload(
            "case-a",
            cpu=1,
            power=2,
            memory_mib=3,
            footprint_current_mib=4,
            footprint_peak_mib=5,
            footprint_shared_mib=6,
            context_switches=7,
            faults=8,
            pageins=9,
            gpu=10,
        )
        top = result["summary"]["top"]
        gpu_summary = result["summary"]["gpu"]
        del top["measurement"]
        del top["aggregate"]["context_switch_count_rate_per_s"]
        del top["aggregate"]["fault_count_rate_per_s"]
        del top["aggregate"]["pagein_count_rate_per_s"]
        del gpu_summary["measurement"]
        del gpu_summary["aggregate"]["accumulated_gpu_time_rate_per_s"]
        result["samples"] = {
            "top": [
                {"timestamp": "2026/08/10 20:00:00"},
                {"timestamp": "2026/08/10 20:00:10"},
            ],
            "gpu": [{"elapsed_s": 0.2}, {"elapsed_s": 10.2}],
        }
        relative = Path("results") / "legacy.json"
        self.write_json(relative, result)
        path = self.write_manifest(
            manifest([trial("case-a", "wam", 1, "completed", relative)])
        )
        row = self.row(report_matrix.build_report(path), "case-a", "wam")
        self.assertEqual(row["context_switch_rate"].median, 7.0)
        self.assertEqual(row["fault_rate"].median, 8.0)
        self.assertEqual(row["pagein_rate"].median, 9.0)
        self.assertEqual(row["process_gpu_counter_rate"].median, 10.0)

    def test_raw_footprint_fallback_sums_only_requested_processes(self):
        result = result_payload(
            "case-a",
            cpu=1,
            power=2,
            memory_mib=3,
            footprint_current_mib=4,
            footprint_peak_mib=5,
            footprint_shared_mib=6,
            context_switches=7,
            faults=8,
            pageins=9,
        )
        del result["summary"]["footprint"]
        result["metadata"]["pids"] = [123, 456]
        result["footprint"] = {
            "bytes per unit": 2,
            "total footprint": 350 * MIB,
            "processes": [
                {"pid": 123, "auxiliary": {"phys_footprint": 50 * MIB, "phys_footprint_peak": 60 * MIB}},
                {"pid": 456, "auxiliary": {"phys_footprint": 75 * MIB, "phys_footprint_peak": 90 * MIB}},
                {"pid": 999, "auxiliary": {"phys_footprint": 1000 * MIB, "phys_footprint_peak": 1000 * MIB}},
            ],
        }
        values = report_matrix.footprint_values(result)
        self.assertEqual(values["footprint_current_mib"], 250.0)
        self.assertEqual(values["footprint_peak_mib"], 300.0)
        self.assertEqual(values["footprint_shared_adjusted_mib"], 700.0)

    def test_native_startup_latency_is_reported_and_missing_warm_stays_na(self):
        result = result_payload(
            "case-a",
            cpu=1,
            power=2,
            memory_mib=3,
            footprint_current_mib=4,
            footprint_peak_mib=5,
            footprint_shared_mib=6,
            context_switches=7,
            faults=8,
            pageins=9,
        )
        result["orchestration"] = {
            "native_startup": {
                "latencies": {
                    "cold_request_to_first_draw_ms": 240.0,
                    "open_request_to_first_draw_ms": 80.0,
                    "warm_request_to_first_draw_ms": None,
                }
            }
        }
        relative = Path("results") / "native-startup.json"
        self.write_json(relative, result)
        path = self.write_manifest(
            manifest([trial("case-a", "wam", 1, "completed", relative)])
        )
        snapshot = report_matrix.build_report(path)
        row = self.row(snapshot, "case-a", "wam")
        self.assertEqual(row["cold_request_to_first_draw_ms"].median, 240.0)
        self.assertEqual(row["open_request_to_first_draw_ms"].median, 80.0)
        self.assertEqual(row["warm_request_to_first_draw_ms"].count, 0)
        self.assertIn("warm_request_to_first_draw_ms", [
            metric.key for metric in snapshot.metrics
        ])
        self.assertIn("Warm N/A", report_matrix.markdown_text(snapshot))


class LiveAndFailureTests(ReportFixture):
    def test_partial_live_manifest_preserves_failure_pending_and_unsupported_rows(self):
        trials = [
            trial("case-a", "vlc", 1, "n/a", reason="failure", detail="decoder crashed"),
            trial("case-a", "vlc", 2, "running"),
            trial("case-a", "vlc", 3, "pending"),
            trial(
                "case-b",
                "quicktime",
                1,
                "n/a",
                reason="unsupported",
                detail="format is not supported",
            ),
        ]
        path = self.write_manifest(
            manifest(
                trials,
                cases=[case(), case("case-b", unsupported=("quicktime",), repetitions=1)],
            )
        )

        snapshot = report_matrix.build_report(path)
        vlc = self.row(snapshot, "case-a", "vlc")
        quicktime = self.row(snapshot, "case-b", "quicktime")

        self.assertEqual(vlc["report_status"], "partial")
        self.assertEqual(vlc["observed_support"], "failed")
        self.assertEqual(vlc["n_a_reasons"], "failure (1)")
        self.assertIn("failure: decoder crashed", vlc["issues"])
        self.assertEqual(vlc["cpu_percent"].count, 0)
        self.assertEqual(quicktime["report_status"], "N/A")
        self.assertEqual(quicktime["expected_support"], "unsupported")
        self.assertEqual(quicktime["observed_support"], "unsupported")

        rendered = report_matrix.markdown_text(snapshot)
        self.assertIn("failure: decoder crashed", rendered)
        self.assertIn("unsupported / unsupported", rendered)

    def test_completed_missing_artifact_is_explicit_na_not_zero(self):
        path = self.write_manifest(
            manifest([trial("case-a", "wam", 1, "completed", "missing.json")])
        )
        snapshot = report_matrix.build_report(path)
        row = self.row(snapshot, "case-a", "wam")

        self.assertEqual(row["completed_repetitions"], 1)
        self.assertEqual(row["measured_repetitions"], 0)
        self.assertEqual(row["report_status"], "N/A (artifact error)")
        self.assertIsNone(row["cpu_percent"].median)
        self.assertIn("artifact:", row["issues"])

        csv_output = report_matrix.csv_text(snapshot)
        csv_row = next(csv.DictReader(io.StringIO(csv_output)))
        self.assertEqual(csv_row["cpu_percent_available_repetitions"], "0")
        self.assertEqual(csv_row["cpu_percent_median"], "")
        self.assertNotIn("process_gpu_counter_rate_median", csv_row)
        self.assertIn("N/A", report_matrix.markdown_text(snapshot))

    def test_native_proof_ineligibility_remains_explicit(self):
        path = self.write_manifest(
            manifest(
                [
                    trial(
                        "case-a",
                        "wam",
                        1,
                        "n/a",
                        reason="ineligible",
                        detail="native route proof absent",
                    )
                ]
            )
        )
        row = self.row(report_matrix.build_report(path), "case-a", "wam")
        self.assertEqual(row["observed_support"], "ineligible")
        self.assertIn("ineligible: native route proof absent", row["issues"])

    def test_preparing_manifest_with_no_trials_is_safe(self):
        path = self.write_manifest(manifest([], state="preparing"))
        snapshot = report_matrix.build_report(path)
        self.assertEqual(len(snapshot.rows), 3)
        self.assertTrue(all(row["report_status"] == "not scheduled" for row in snapshot.rows))
        self.assertTrue(all(row["planned_repetitions"] == 3 for row in snapshot.rows))


class MetadataAndValidationTests(ReportFixture):
    def test_architecture_and_bundle_columns_only_appear_when_passed(self):
        path = self.write_manifest(manifest([]))
        plain = report_matrix.build_report(path)
        plain_fields, _ = report_matrix.csv_rows(plain)
        self.assertNotIn("architecture", plain_fields)
        self.assertNotIn("bundle_size_mib", plain_fields)
        self.assertNotIn("Architecture", report_matrix.markdown_text(plain))

        explicit = report_matrix.build_report(
            path,
            architectures={"wam": "arm64", "vlc": "x86_64"},
            bundle_size_bytes={"wam": 350 * MIB},
        )
        fields, _ = report_matrix.csv_rows(explicit)
        self.assertIn("architecture", fields)
        self.assertIn("bundle_size_mib", fields)
        wam = self.row(explicit, "case-a", "wam")
        quicktime = self.row(explicit, "case-a", "quicktime")
        self.assertEqual(wam["architecture"], "arm64")
        self.assertEqual(wam["bundle_size_mib"], 350.0)
        self.assertIsNone(quicktime["architecture"])
        self.assertIsNone(quicktime["bundle_size_mib"])

    def test_invalid_manifest_schema_is_rejected(self):
        path = self.write_manifest({"schema": "wrong", "trials": []})
        with self.assertRaisesRegex(report_matrix.ReportError, "unsupported matrix schema"):
            report_matrix.build_report(path)

    def test_metadata_assignment_validation(self):
        self.assertEqual(
            report_matrix._architecture_assignments(["wam=arm64"]), {"wam": "arm64"}
        )
        self.assertEqual(
            report_matrix._bundle_assignments(["wam=1048576"]), {"wam": 1048576}
        )
        with self.assertRaisesRegex(report_matrix.ReportError, "duplicate"):
            report_matrix._architecture_assignments(["wam=arm64", "wam=x86_64"])
        with self.assertRaisesRegex(report_matrix.ReportError, "PLAYER=VALUE"):
            report_matrix._architecture_assignments(["wam"])
        with self.assertRaisesRegex(report_matrix.ReportError, "nonnegative"):
            report_matrix._bundle_assignments(["wam=-1"])


if __name__ == "__main__":
    unittest.main()
