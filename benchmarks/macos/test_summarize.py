#!/usr/bin/env python3

import unittest
from pathlib import Path

import summarize


class ResultRowTests(unittest.TestCase):
    def base_result(self):
        return {
            "schema": summarize.SCHEMA,
            "metadata": {
                "player": "WAM",
                "clip": "sample",
                "run": "1",
                "speed": 1.0,
                "pids": [101, 202],
                "requested_duration_s": 20,
            },
            "collection": {"elapsed_s": 21},
            "samples": {"top": [{}, {}], "gpu": [{}]},
            "summary": {
                "top": {
                    "measurement": {"elapsed_s": 20, "source": "top timestamps"},
                    "aggregate": {
                        "thread_count": {"mean": 10, "median": 10, "p95": 12, "max": 12},
                        "port_count": {"mean": 200, "median": 200, "p95": 220, "max": 225},
                        "context_switch_count_delta": {
                            "mean": 50,
                            "median": 45,
                            "p95": 80,
                            "max": 90,
                        },
                        "total_context_switch_count_delta": 100,
                        "context_switch_count_rate_per_s": 5,
                    }
                },
                "gpu": {
                    "measurement": {"elapsed_s": 19.5, "source": "ioreg timestamps"},
                    "aggregate": {
                        "total_delta_accumulated_gpu_time": 195,
                        "accumulated_gpu_time_rate_per_s": 10,
                    },
                },
            },
            "warnings": [],
        }

    def test_extended_top_metrics_are_flattened(self):
        row = summarize.result_row(self.base_result(), Path("result.json"))
        self.assertEqual(row["threads_mean"], 10.0)
        self.assertEqual(row["ports_max"], 225.0)
        self.assertEqual(row["context_switches_per_interval_p95"], 80.0)
        self.assertEqual(row["context_switches_total"], 100)
        self.assertEqual(row["context_switches_per_s"], 5.0)
        self.assertEqual(row["gpu_time_counter_units_per_s"], 10.0)
        self.assertEqual(row["top_measurement_elapsed_s"], 20.0)
        self.assertEqual(row["gpu_measurement_elapsed_s"], 19.5)
        self.assertIsNone(row["pageins_per_interval_mean"])

    def test_legacy_counter_rate_uses_sample_span_before_collection_elapsed(self):
        result = self.base_result()
        del result["summary"]["top"]["measurement"]
        del result["summary"]["top"]["aggregate"]["context_switch_count_rate_per_s"]
        result["samples"]["top"] = [
            {"timestamp": "2026/08/10 20:00:01"},
            {"timestamp": "2026/08/10 20:00:05"},
        ]
        row = summarize.result_row(result, Path("legacy-timing.json"))
        self.assertEqual(row["top_measurement_elapsed_s"], 4.0)
        self.assertEqual(row["context_switches_per_s"], 25.0)
        self.assertEqual(
            row["top_measurement_elapsed_source"], "derived top wall-clock timestamps"
        )

    def test_legacy_raw_footprint_fallback_is_scaled_and_filtered(self):
        result = self.base_result()
        result["footprint"] = {
            "bytes per unit": 1024,
            "total footprint": 130,
            "processes": [
                {
                    "pid": 101,
                    "translated": False,
                    "auxiliary": {"phys_footprint": 100, "phys_footprint_peak": 150},
                },
                {
                    "pid": 202,
                    "translated": True,
                    "auxiliary": {"phys_footprint": 50, "phys_footprint_peak": 70},
                },
                {
                    "pid": 999,
                    "translated": False,
                    "auxiliary": {"phys_footprint": 500, "phys_footprint_peak": 600},
                },
            ],
        }
        row = summarize.result_row(result, Path("legacy.json"))
        self.assertAlmostEqual(row["footprint_current_mib"], 150 / 1024)
        self.assertAlmostEqual(row["footprint_peak_mib"], 220 / 1024)
        self.assertAlmostEqual(row["footprint_shared_adjusted_mib"], 130 / 1024)
        self.assertEqual(row["footprint_process_count"], 2)
        self.assertEqual(row["translated_process_count"], 1)

    def test_normalized_footprint_summary_takes_precedence(self):
        result = self.base_result()
        result["summary"]["footprint"] = {
            "process_count": 3,
            "translated_process_count": 2,
            "aggregate": {
                "current_phys_footprint_bytes": 4 * 1024**2,
                "peak_phys_footprint_bytes": 6 * 1024**2,
                "shared_adjusted_footprint_bytes": 3 * 1024**2,
            },
        }
        row = summarize.result_row(result, Path("new.json"))
        self.assertEqual(row["footprint_current_mib"], 4.0)
        self.assertEqual(row["footprint_peak_mib"], 6.0)
        self.assertEqual(row["footprint_shared_adjusted_mib"], 3.0)
        self.assertEqual(row["footprint_process_count"], 3.0)
        self.assertEqual(row["translated_process_count"], 2.0)


if __name__ == "__main__":
    unittest.main()
