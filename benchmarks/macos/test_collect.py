#!/usr/bin/env python3

import contextlib
import io
import plistlib
import unittest

import collect


TOP_FIXTURE = """Processes: 500 total, 2 running, 498 sleeping, 2600 threads
2026/08/10 20:00:00
CPU usage: 10.0% user, 5.0% sys, 85.0% idle
PID COMMAND %CPU MEM POWER
101 WAM 90.0 200M 12.0
202 media helper 10.0 50M 3.0

Processes: 500 total, 2 running, 498 sleeping, 2600 threads
2026/08/10 20:00:01
CPU usage: 20.0% user, 10.0% sys, 70.0% idle
PID COMMAND %CPU MEM POWER
101 WAM 20.0 210M 5.0
202 media helper 5.0 55M 2.0

Processes: 500 total, 2 running, 498 sleeping, 2600 threads
2026/08/10 20:00:02
CPU usage: 30.0% user, 10.0% sys, 60.0% idle
PID COMMAND %CPU MEM POWER
101 WAM 30.0 220M 7.0
202 media helper 10.0 60M 3.0
"""

EXTENDED_TOP_FIXTURE = """Processes: 500 total, 2 running, 498 sleeping, 2600 threads
2026/08/10 20:00:00
CPU usage: 10.0% user, 5.0% sys, 85.0% idle
PID COMMAND %CPU MEM POWER #TH #PORTS CSW FAULTS PAGEINS PURG
101 WAM 90.0 200M 12.0 12/2 300 1000 2000 4 32K
202 media helper 10.0 50M 3.0 4/1 50 400 1000 1 0B

Processes: 500 total, 2 running, 498 sleeping, 2600 threads
2026/08/10 20:00:01
CPU usage: 20.0% user, 10.0% sys, 70.0% idle
PID COMMAND %CPU MEM POWER #TH #PORTS CSW FAULTS PAGEINS PURG
101 WAM 20.0 210M+ 5.0 12/1 301+ 1120+ 2050+ 4 48K+
202 media helper 5.0 55M 2.0 4/1 51 440+ 1010+ 1 0B

Processes: 500 total, 2 running, 498 sleeping, 2600 threads
2026/08/10 20:00:02
CPU usage: 30.0% user, 10.0% sys, 60.0% idle
PID COMMAND %CPU MEM POWER #TH #PORTS CSW FAULTS PAGEINS PURG
101 WAM 30.0 220M 7.0 13/2 305 1200+ 2100+ 6+ 64K
202 media helper 10.0 60M 3.0 4 52 20 1020+ 1 0B
"""


class TopParserTests(unittest.TestCase):
    def test_byte_sizes(self):
        self.assertEqual(collect.parse_byte_size("512K"), 512 * 1024)
        self.assertEqual(collect.parse_byte_size("1.5G+"), int(1.5 * 1024**3))
        self.assertEqual(collect.parse_byte_size("43M-"), 43 * 1024**2)
        self.assertEqual(collect.parse_byte_size("43M+"), 43 * 1024**2)
        self.assertEqual(collect.parse_byte_size("42"), 42)
        self.assertIsNone(collect.parse_byte_size("N/A"))

    def test_compact_counts_and_thread_counts(self):
        self.assertEqual(collect.parse_count("5565296+"), 5_565_296)
        self.assertEqual(collect.parse_count("1.5K+"), 1_500)
        self.assertEqual(collect.parse_count("-10"), -10)
        self.assertIsNone(collect.parse_count("-"))
        self.assertEqual(collect.parse_thread_count("12/2"), (12, 2))
        self.assertEqual(collect.parse_thread_count("4"), (4, 0))

    def test_parses_top_and_discards_first_cpu_sample(self):
        samples = collect.parse_top_output(TOP_FIXTURE, [101, 202])
        self.assertEqual(len(samples), 3)
        self.assertEqual(samples[0]["processes"][1]["command"], "media helper")
        self.assertEqual(samples[1]["system_cpu"]["active_percent"], 30.0)

        summary = collect.summarize_top(samples, [101, 202])
        aggregate = summary["aggregate"]
        # Warmup CPU of 100% is excluded; later totals are 25% and 40%.
        self.assertEqual(aggregate["cpu_percent"]["count"], 2)
        self.assertEqual(aggregate["cpu_percent"]["mean"], 32.5)
        self.assertEqual(
            aggregate["cpu_percent"]["mean_method"], "time_weighted_interval_ending"
        )
        # Memory retains all three top samples.
        self.assertEqual(aggregate["memory_bytes"]["count"], 3)
        self.assertEqual(
            aggregate["memory_bytes"]["mean_method"], "time_weighted_trapezoidal"
        )
        self.assertEqual(aggregate["top_power_score"]["max"], 15.0)
        self.assertEqual(summary["measurement"]["elapsed_s"], 2.0)

    def test_irregular_top_intervals_weight_cpu_power_and_gauges_by_time(self):
        samples = collect.parse_top_output(
            TOP_FIXTURE.replace("2026/08/10 20:00:02", "2026/08/10 20:00:04"),
            [101, 202],
        )
        aggregate = collect.summarize_top(samples, [101, 202])["aggregate"]

        # CPU interval totals are 25% for one second and 40% for three seconds.
        self.assertAlmostEqual(aggregate["cpu_percent"]["mean"], 36.25)
        self.assertEqual(aggregate["cpu_percent"]["arithmetic_mean"], 32.5)
        # Aggregate memory is 250, 265, 280 MiB and uses trapezoidal integration.
        self.assertAlmostEqual(
            aggregate["memory_bytes"]["mean"] / 1024**2,
            268.75,
        )
        # Aggregate POWER is 15, 7, 10 and is also an instantaneous gauge.
        self.assertAlmostEqual(aggregate["top_power_score"]["mean"], 9.125)

    def test_top_without_power(self):
        raw = TOP_FIXTURE.replace(" POWER", "").replace(" 12.0", "").replace(" 3.0", "").replace(" 5.0", "").replace(" 2.0", "").replace(" 7.0", "")
        samples = collect.parse_top_output(raw, [101])
        self.assertEqual(len(samples), 3)
        self.assertIsNone(samples[0]["processes"][0]["top_power_score"])

    def test_extended_top_metrics_and_counter_deltas(self):
        samples = collect.parse_top_output(EXTENDED_TOP_FIXTURE, [101, 202])
        self.assertEqual(len(samples), 3)
        helper = samples[0]["processes"][1]
        self.assertEqual(helper["command"], "media helper")
        self.assertEqual(helper["thread_count"], 4)
        self.assertEqual(helper["running_thread_count"], 1)
        self.assertEqual(helper["port_count"], 50)
        self.assertEqual(samples[1]["processes"][0]["purgeable_bytes"], 48 * 1024)

        summary = collect.summarize_top(samples, [101, 202])
        aggregate = summary["aggregate"]
        self.assertEqual(aggregate["thread_count"]["max"], 17.0)
        self.assertAlmostEqual(aggregate["running_thread_count"]["mean"], 2.25)
        self.assertEqual(aggregate["port_count"]["max"], 357.0)
        # Interval totals are 160, then 80. The helper counter reset is excluded.
        self.assertEqual(aggregate["context_switch_count_delta"]["mean"], 120.0)
        self.assertEqual(aggregate["context_switch_count_delta"]["max"], 160.0)
        self.assertEqual(aggregate["total_context_switch_count_delta"], 240.0)
        self.assertEqual(aggregate["context_switch_count_rate_per_s"], 120.0)
        self.assertEqual(summary["processes"]["202"]["context_switch_count_delta"]["count"], 1)
        self.assertEqual(summary["processes"]["202"]["total_context_switch_count_delta"], 40)
        self.assertEqual(summary["processes"]["202"]["context_switch_count_rate_per_s"], 20.0)
        self.assertEqual(aggregate["fault_count_delta"]["mean"], 60.0)
        self.assertEqual(aggregate["total_fault_count_delta"], 120.0)
        self.assertEqual(aggregate["fault_count_rate_per_s"], 60.0)
        self.assertEqual(aggregate["pagein_count_delta"]["max"], 2.0)
        self.assertEqual(aggregate["pagein_count_rate_per_s"], 1.0)

    def test_percentile_and_empty_summary(self):
        self.assertEqual(collect.percentile([0, 10], 0.95), 9.5)
        self.assertEqual(collect.metric_summary([])["count"], 0)
        self.assertIsNone(collect.metric_summary([])["p95"])

    def test_top_interval_is_formatted_as_an_integer(self):
        parser = collect.build_parser()
        args = parser.parse_args(
            [
                "--pid",
                "101",
                "--player",
                "WAM",
                "--clip",
                "sample",
                "--run",
                "1",
                "--speed",
                "1",
                "--interval",
                "1.0",
                "--output",
                "result.json",
            ]
        )
        self.assertEqual(args.interval, 1)
        self.assertEqual(str(args.interval), "1")
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            parser.parse_args(
                [
                    "--pid",
                    "101",
                    "--player",
                    "WAM",
                    "--clip",
                    "sample",
                    "--run",
                    "1",
                    "--speed",
                    "1",
                    "--interval",
                    "0.5",
                    "--output",
                    "result.json",
                ]
            )


class IORegParserTests(unittest.TestCase):
    def plist_fixture(self):
        return [
            {
                "IORegistryEntryName": "AGXAccelerator",
                "PerformanceStatistics": {
                    "Device Utilization %": 44,
                    "Renderer Utilization %": 40,
                    "Tiler Utilization %": 12,
                },
                "IORegistryEntryChildren": [
                    {
                        "IOUserClientCreator": "pid 101, WAM",
                        "AppUsage": [
                            {"API": "Metal", "accumulatedGPUTime": 1_000},
                            {"API": "Metal", "accumulatedGPUTime": 250},
                        ],
                    },
                    {
                        "IOUserClientCreator": "pid 101, WAM",
                        "AppUsage": [{"API": "Metal", "accumulatedGPUTime": 50}],
                    },
                    {
                        "IOUserClientCreator": "pid 999, WindowServer",
                        "AppUsage": [{"API": "Metal", "accumulatedGPUTime": 99_000}],
                    },
                ],
            }
        ]

    def test_parses_plist_utilization_and_target_app_usage(self):
        data = plistlib.dumps(self.plist_fixture())
        parsed = collect.parse_ioreg_plist(data, [101])
        self.assertEqual(parsed["system"]["device_utilization_percent"], 44.0)
        self.assertEqual(parsed["system"]["renderer_utilization_percent"], 40.0)
        self.assertEqual(parsed["per_pid_accumulated_gpu_time"], {"101": 1_300})

    def test_merges_separate_accelerator_and_user_client_queries(self):
        accelerator = collect.parse_ioreg_object(
            [
                {
                    "IORegistryEntryName": "AGXAccelerator",
                    "PerformanceStatistics": {
                        "Device Utilization %": 55,
                        "Renderer Utilization %": 50,
                        "Tiler Utilization %": 15,
                    },
                }
            ],
            [101],
        )
        first_clients = collect.parse_ioreg_object(
            [
                {
                    "IOUserClientCreator": "pid 101, WAM",
                    "AppUsage": [{"accumulatedGPUTime": 1_000}],
                }
            ],
            [101],
        )
        second_clients = collect.parse_ioreg_object(
            [
                {
                    "IOUserClientCreator": "pid 101, WAM",
                    "AppUsage": [{"accumulatedGPUTime": 1_075}],
                }
            ],
            [101],
        )

        first = collect.merge_ioreg_results(accelerator, first_clients)
        second = collect.merge_ioreg_results(accelerator, second_clients)
        first["elapsed_s"] = 0.25
        second["elapsed_s"] = 2.75
        self.assertEqual(first["system"]["device_utilization_percent"], 55.0)
        self.assertEqual(first["per_pid_accumulated_gpu_time"], {"101": 1_000})
        warnings = collect.add_gpu_deltas([first, second], [101])
        self.assertEqual(warnings, [])
        self.assertEqual(second["per_pid_delta_accumulated_gpu_time"]["101"], 75)
        summary = collect.summarize_gpu([first, second], [101])
        self.assertEqual(summary["aggregate"]["total_delta_accumulated_gpu_time"], 75.0)
        self.assertEqual(summary["measurement"]["elapsed_s"], 2.5)
        self.assertEqual(summary["aggregate"]["accumulated_gpu_time_rate_per_s"], 30.0)
        self.assertEqual(summary["processes"]["101"]["accumulated_gpu_time_rate_per_s"], 30.0)

    def test_parses_text_fallback(self):
        text = '''
+-o AGXAcceleratorG15X
  | "PerformanceStatistics" = {"Tiler Utilization %"=3,"Renderer Utilization %"=20,"Device Utilization %"=21}
  +-o AGXDeviceUserClient
  | {"AppUsage"=({"accumulatedGPUTime"=100},{"accumulatedGPUTime"=25})
  | "IOUserClientCreator" = "pid 101, WAM"}
  +-o AGXDeviceUserClient
  | {"AppUsage"=({"accumulatedGPUTime"=900})
  | "IOUserClientCreator" = "pid 999, WindowServer"}
'''
        parsed = collect.parse_ioreg_text(text, [101])
        self.assertEqual(parsed["system"]["tiler_utilization_percent"], 3.0)
        self.assertEqual(parsed["per_pid_accumulated_gpu_time"], {"101": 125})

    def test_gpu_deltas_and_counter_reset(self):
        samples = [
            {"per_pid_accumulated_gpu_time": {"101": 100}},
            {"per_pid_accumulated_gpu_time": {"101": 160}},
            {"per_pid_accumulated_gpu_time": {"101": 10}},
        ]
        warnings = collect.add_gpu_deltas(samples, [101])
        self.assertIsNone(samples[0]["per_pid_delta_accumulated_gpu_time"]["101"])
        self.assertEqual(samples[1]["per_pid_delta_accumulated_gpu_time"]["101"], 60)
        self.assertIsNone(samples[2]["per_pid_delta_accumulated_gpu_time"]["101"])
        self.assertEqual(len(warnings), 1)


class FootprintParserTests(unittest.TestCase):
    def test_normalizes_ledger_totals_and_filters_targets(self):
        report = {
            "unit": "Kbyte",
            "bytes per unit": 1024,
            "total footprint": 130,
            "processes": [
                {
                    "pid": 101,
                    "name": "WAM",
                    "translated": False,
                    "footprint": 90,
                    "auxiliary": {"phys_footprint": 100, "phys_footprint_peak": 150},
                },
                {
                    "pid": 202,
                    "name": "helper",
                    "translated": True,
                    "footprint": 45,
                    "auxiliary": {"phys_footprint": 50, "phys_footprint_peak": 70},
                },
                {
                    "pid": 999,
                    "name": "unrelated",
                    "translated": False,
                    "footprint": 500,
                    "auxiliary": {"phys_footprint": 500, "phys_footprint_peak": 600},
                },
            ],
        }
        summary = collect.summarize_footprint(report, [101, 202])
        self.assertTrue(summary["available"])
        self.assertEqual(summary["process_count"], 2)
        self.assertEqual(summary["translated_process_count"], 1)
        self.assertEqual(summary["aggregate"]["current_phys_footprint_bytes"], 150 * 1024)
        self.assertEqual(summary["aggregate"]["peak_phys_footprint_bytes"], 220 * 1024)
        self.assertEqual(summary["aggregate"]["categorized_footprint_bytes"], 135 * 1024)
        self.assertEqual(summary["aggregate"]["shared_adjusted_footprint_bytes"], 130 * 1024)
        self.assertNotIn("999", summary["processes"])

    def test_unavailable_footprint_is_explicit(self):
        summary = collect.summarize_footprint(None, [101])
        self.assertFalse(summary["available"])
        self.assertIsNone(summary["aggregate"]["current_phys_footprint_bytes"])


if __name__ == "__main__":
    unittest.main()
