#!/usr/bin/env python3

import contextlib
import ctypes
import io
import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import run_shipper
import run_suite

TEST_RUN_ID = "123e4567-e89b-12d3-a456-426614174000"
TEST_PROCESS_ID = 4242
TEST_PROCESS_START_ABSTIME = 987654321
TEST_ASSET_SHA256 = "a" * 64


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


def parsed_native_trial(*, fallback=False, include_scrub=True):
    events = [
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
            target_seconds=0.0,
        ),
        native_event(
            "first_frame_drawn",
            1_200_000_000,
            route="native",
            source_key=7,
            attempt=11,
            serial=14,
            generation=13,
            draw_sequence=1,
            target_seconds=0.0,
        ),
    ]
    if include_scrub:
        events.extend(
            [
                native_event(
                    "preview_demanded",
                    1_300_000_000,
                    route="native",
                    gesture=21,
                    request=31,
                    target_seconds=0.2,
                ),
                native_event(
                    "preview_dispatched",
                    1_305_000_000,
                    route="native",
                    gesture=21,
                    request=31,
                    target_seconds=0.2,
                ),
                native_event(
                    "preview_admitted",
                    1_310_000_000,
                    route="native",
                    source_key=7,
                    attempt=11,
                    serial=15,
                    generation=13,
                    gesture=21,
                    request=31,
                    target_seconds=0.2,
                ),
                native_event(
                    "preview_demanded",
                    1_320_000_000,
                    route="native",
                    gesture=21,
                    request=32,
                    target_seconds=3.8,
                ),
                native_event(
                    "preview_dispatched",
                    1_325_000_000,
                    route="native",
                    gesture=21,
                    request=32,
                    target_seconds=3.8,
                ),
                native_event(
                    "preview_admitted",
                    1_330_000_000,
                    route="native",
                    source_key=7,
                    attempt=11,
                    serial=16,
                    generation=13,
                    gesture=21,
                    request=32,
                    target_seconds=3.8,
                ),
                native_event(
                    "preview_frame_drawn",
                    1_340_000_000,
                    route="native",
                    source_key=7,
                    attempt=11,
                    serial=15,
                    generation=13,
                    gesture=21,
                    request=31,
                    target_seconds=0.21,
                ),
                native_event(
                    "preview_frame_drawn",
                    1_360_000_000,
                    route="native",
                    source_key=7,
                    attempt=11,
                    serial=16,
                    generation=13,
                    gesture=21,
                    request=32,
                    target_seconds=3.8,
                ),
                native_event(
                    "commit_seek_submitted",
                    1_361_000_000,
                    route="native",
                    source_key=7,
                    attempt=11,
                    serial=17,
                    generation=13,
                    gesture=21,
                    request=33,
                    target_seconds=3.8,
                ),
                native_event(
                    "commit_ready",
                    1_364_000_000,
                    route="native",
                    source_key=7,
                    attempt=11,
                    serial=17,
                    generation=13,
                    gesture=21,
                    request=33,
                    draw_sequence=3,
                    target_seconds=3.8,
                ),
                native_event(
                    "commit_frame_drawn",
                    1_364_000_000,
                    route="native",
                    source_key=7,
                    attempt=11,
                    serial=17,
                    generation=13,
                    gesture=21,
                    request=33,
                    draw_sequence=3,
                    target_seconds=3.8,
                ),
                native_event(
                    "preview_demanded",
                    1_365_000_000,
                    route="native",
                    gesture=22,
                    request=41,
                    target_seconds=3.8,
                ),
                native_event(
                    "preview_dispatched",
                    1_367_000_000,
                    route="native",
                    gesture=22,
                    request=41,
                    target_seconds=3.8,
                ),
                native_event(
                    "preview_admitted",
                    1_370_000_000,
                    route="native",
                    source_key=7,
                    attempt=11,
                    serial=17,
                    generation=13,
                    gesture=22,
                    request=41,
                    target_seconds=3.8,
                ),
                native_event(
                    "preview_frame_drawn",
                    1_380_000_000,
                    route="native",
                    source_key=7,
                    attempt=11,
                    serial=17,
                    generation=13,
                    gesture=22,
                    request=41,
                    target_seconds=3.8,
                ),
                native_event(
                    "preview_demanded",
                    1_385_000_000,
                    route="native",
                    gesture=22,
                    request=42,
                    target_seconds=0.2,
                ),
                native_event(
                    "preview_dispatched",
                    1_387_000_000,
                    route="native",
                    gesture=22,
                    request=42,
                    target_seconds=0.2,
                ),
                native_event(
                    "preview_admitted",
                    1_390_000_000,
                    route="native",
                    source_key=7,
                    attempt=11,
                    serial=18,
                    generation=13,
                    gesture=22,
                    request=42,
                    target_seconds=0.2,
                ),
                native_event(
                    "preview_frame_drawn",
                    1_400_000_000,
                    route="native",
                    source_key=7,
                    attempt=11,
                    serial=18,
                    generation=13,
                    gesture=22,
                    request=42,
                    target_seconds=0.2,
                ),
                # Latest-only demand that is intentionally coalesced before
                # admission is a measured count, not a proof failure.
                native_event(
                    "preview_demanded",
                    1_405_000_000,
                    route="native",
                    gesture=22,
                    request=43,
                    target_seconds=0.1,
                ),
                native_event(
                    "commit_seek_submitted",
                    1_410_000_000,
                    route="native",
                    source_key=7,
                    attempt=11,
                    serial=19,
                    generation=13,
                    gesture=22,
                    request=44,
                    target_seconds=0.1,
                ),
                native_event(
                    "commit_ready",
                    1_450_000_000,
                    route="native",
                    source_key=7,
                    attempt=11,
                    serial=19,
                    generation=13,
                    gesture=22,
                    request=44,
                    draw_sequence=4,
                    target_seconds=0.1,
                ),
                native_event(
                    "commit_frame_drawn",
                    1_450_000_000,
                    route="native",
                    source_key=7,
                    attempt=11,
                    serial=19,
                    generation=13,
                    gesture=22,
                    request=44,
                    draw_sequence=4,
                    target_seconds=0.1,
                ),
            ]
        )
    if fallback:
        events.append(
            native_event(
                "fallback_selected",
                1_500_000_000,
                route="fallback",
                route_proof=True,
                source_key=7,
                attempt=91,
                serial=92,
            )
        )
    parsed = run_suite.parse_wam_native_telemetry("\n".join(events))
    parsed["availability"] = "available"
    return parsed


def parsed_fallback_trial():
    parsed = run_suite.parse_wam_native_telemetry(
        "\n".join(
            [
                native_event("open_requested", 1_100_000_000, source_key=7),
                native_event(
                    "fallback_selected",
                    1_120_000_000,
                    route="fallback",
                    route_proof=True,
                    source_key=7,
                    attempt=91,
                    serial=92,
                ),
            ]
        )
    )
    parsed["availability"] = "available"
    return parsed


class FakeClock:
    def __init__(self, start_ns=1_000_000_000):
        self.now_ns = start_ns

    def __call__(self):
        return self.now_ns

    def sleep(self, seconds):
        self.now_ns += round(seconds * 1_000_000_000)


class SequenceReader:
    def __init__(self, snapshots):
        self.snapshots = {pid: list(values) for pid, values in snapshots.items()}
        self.indices = {pid: 0 for pid in snapshots}

    def __call__(self, pid):
        index = self.indices[pid]
        self.indices[pid] += 1
        value = self.snapshots[pid][index]
        if isinstance(value, BaseException):
            raise value
        return value


def snapshot(cpu_ns, resident, footprint, lifetime, start=99):
    return run_shipper.RUsageSnapshot(
        user_time_ns=cpu_ns,
        system_time_ns=0,
        resident_size_bytes=resident,
        phys_footprint_bytes=footprint,
        lifetime_max_phys_footprint_bytes=lifetime,
        interval_max_phys_footprint_bytes=lifetime,
        process_start_abstime=start,
    )


def provenance(*pids, start=99):
    return {
        pid: {
            "role": run_shipper.ROLE_APP if index == 0 else run_shipper.ROLE_DECODER_HELPER,
            "coalition_id": 700,
            "identity": {
                "pid": pid,
                "ppid": 1,
                "started": "now",
                "executable": (
                    "/Applications/WAM.app/Contents/MacOS/WAM"
                    if index == 0
                    else f"/System/{run_suite.HELPER_BASENAME}"
                ),
            },
            "resource_coalition": {
                "coalition_id": 700,
                "name": "wam-test",
                "bundle_id": run_shipper.EXPECTED_WAM_BUNDLE_ID,
                "active_count": len(pids),
            },
            "expected_wam_executable": "/Applications/WAM.app/Contents/MacOS/WAM",
            "expected_wam_bundle_id": run_shipper.EXPECTED_WAM_BUNDLE_ID,
            "expected_run_id": TEST_RUN_ID,
            "expected_process_start_abstime": start,
        }
        for index, pid in enumerate(pids)
    }


def membership(*pids):
    return lambda: {
        "available": True,
        "complete": True,
        "kernel_active_count": len(pids),
        "observed_pids": sorted(pids),
        "expected_pids": sorted(pids),
        "app": {
            "pid": pids[0],
            "identity": {
                "pid": pids[0],
                "executable": "/Applications/WAM.app/Contents/MacOS/WAM",
            },
            "resource_coalition": {
                "coalition_id": 700,
                "bundle_id": run_shipper.EXPECTED_WAM_BUNDLE_ID,
                "active_count": len(pids),
            },
        },
        "helpers": [
            {
                "pid": pid,
                "role": run_shipper.ROLE_DECODER_HELPER,
                "identity": {
                    "pid": pid,
                    "executable": f"/System/{run_suite.HELPER_BASENAME}",
                },
                "resource_coalition": {
                    "coalition_id": 700,
                    "bundle_id": run_shipper.EXPECTED_WAM_BUNDLE_ID,
                    "active_count": len(pids),
                },
            }
            for pid in pids[1:]
        ],
    }


class RUsageTests(unittest.TestCase):
    def test_ctypes_reader_uses_v4_and_extracts_exact_fields(self):
        class FakeFunction:
            argtypes = None
            restype = None

            def __call__(self, pid, flavor, pointer):
                self.pid = pid
                self.flavor = flavor
                info = ctypes.cast(
                    pointer, ctypes.POINTER(run_shipper._RUsageInfoV4)
                ).contents
                info.ri_user_time = 11
                info.ri_system_time = 12
                info.ri_resident_size = 13
                info.ri_phys_footprint = 14
                info.ri_lifetime_max_phys_footprint = 15
                info.ri_interval_max_phys_footprint = 16
                info.ri_proc_start_abstime = 17
                return 0

        function = FakeFunction()
        result = run_shipper.ProcPidRUsageReader(function)(123)
        self.assertEqual(function.pid, 123)
        self.assertEqual(function.flavor, run_shipper.RUSAGE_INFO_V4)
        self.assertEqual(result.cpu_time_ns, 23)
        self.assertEqual(result.resident_size_bytes, 13)
        self.assertEqual(result.phys_footprint_bytes, 14)
        self.assertEqual(result.lifetime_max_phys_footprint_bytes, 15)
        self.assertEqual(result.interval_max_phys_footprint_bytes, 16)
        self.assertEqual(result.process_start_abstime, 17)

    def test_process_specs_are_verified_against_identity_and_coalition(self):
        executable = Path("/Applications/WAM.app/Contents/MacOS/WAM")
        app = run_suite.ProcessIdentity(10, 1, "now", str(executable))
        helper = run_suite.ProcessIdentity(
            20, 1, "now", f"/System/{run_suite.HELPER_BASENAME}"
        )

        def coalition(pid):
            return run_suite.ResourceCoalition(
                700, f"p{pid}", run_shipper.EXPECTED_WAM_BUNDLE_ID, 2
            )

        with mock.patch.object(
            run_shipper.run_suite,
            "process_table",
            return_value={10: app, 20: helper},
        ), mock.patch.object(
            run_shipper.run_suite,
            "process_resource_coalition",
            side_effect=coalition,
        ):
            pids, observed = run_shipper.capture_process_provenance(
                [(10, "app", 700), (20, "decoder_helper", 700)],
                executable,
                expected_run_id=TEST_RUN_ID,
                expected_process_start_abstime=99,
            )
        self.assertEqual(pids, [10, 20])
        self.assertEqual(observed[20]["role"], "decoder_helper")
        self.assertEqual(observed[20]["resource_coalition"]["coalition_id"], 700)

    def test_trusted_discovery_rejects_an_omitted_same_coalition_helper(self):
        executable = Path("/Applications/WAM.app/Contents/MacOS/WAM")
        table = {
            10: run_suite.ProcessIdentity(10, 1, "now", str(executable)),
            20: run_suite.ProcessIdentity(
                20, 1, "now", f"/System/{run_suite.HELPER_BASENAME}"
            ),
        }

        def coalition(pid):
            return run_suite.ResourceCoalition(
                700, f"p{pid}", run_shipper.EXPECTED_WAM_BUNDLE_ID, 2
            )

        with mock.patch.object(
            run_shipper.run_suite, "process_table", return_value=table
        ), mock.patch.object(
            run_shipper.run_suite,
            "process_resource_coalition",
            side_effect=coalition,
        ), self.assertRaisesRegex(run_shipper.ShipperError, r"missing=\[20\]"):
            run_shipper.capture_process_provenance(
                [(10, "app", 700)],
                executable,
                expected_run_id=TEST_RUN_ID,
                expected_process_start_abstime=99,
            )

    def test_kernel_coalition_count_rejects_an_unclassified_member(self):
        executable = Path("/Applications/WAM.app/Contents/MacOS/WAM")
        app = run_suite.ProcessIdentity(10, 1, "now", str(executable))
        coalition = run_suite.ResourceCoalition(
            700, "wam", run_shipper.EXPECTED_WAM_BUNDLE_ID, 2
        )
        with mock.patch.object(
            run_shipper.run_suite, "process_table", return_value={10: app}
        ), mock.patch.object(
            run_shipper.run_suite,
            "process_resource_coalition",
            return_value=coalition,
        ), self.assertRaisesRegex(run_shipper.ShipperError, "unenumerated"):
            run_shipper.capture_process_provenance(
                [(10, "app", 700)],
                executable,
                expected_run_id=TEST_RUN_ID,
                expected_process_start_abstime=99,
            )

    def test_synchronized_20hz_sampling_sums_app_and_helper(self):
        mib = 1024 * 1024
        clock = FakeClock()
        reader = SequenceReader(
            {
                100: [
                    snapshot(10_000_000, 80 * mib, 90 * mib, 100 * mib),
                    snapshot(12_000_000, 81 * mib, 91 * mib, 101 * mib),
                    snapshot(14_000_000, 82 * mib, 92 * mib, 102 * mib),
                ],
                200: [
                    snapshot(5_000_000, 30 * mib, 40 * mib, 50 * mib, start=199),
                    snapshot(6_000_000, 31 * mib, 41 * mib, 51 * mib, start=199),
                    snapshot(7_000_000, 32 * mib, 42 * mib, 52 * mib, start=199),
                ],
            }
        )
        result = run_shipper.sample_processes(
            [100, 200],
            duration_s=0.1,
            interval_s=0.05,
            reader=reader,
            clock_ns=clock,
            sleeper=clock.sleep,
            process_provenance=provenance(100, 200),
            coalition_membership_reader=membership(100, 200),
        )

        self.assertEqual(len(result["samples"]), 3)
        self.assertEqual(
            result["samples"][1]["scheduled_monotonic_ns"]
            - result["samples"][0]["scheduled_monotonic_ns"],
            50_000_000,
        )
        self.assertEqual(result["samples"][0]["coalition_active_count"], 2)
        self.assertEqual(result["samples"][0]["coalition_observed_pids"], [100, 200])
        self.assertEqual(result["samples"][0]["processes"]["100"]["role"], "app")
        self.assertEqual(
            result["samples"][0]["processes"]["200"]["role"],
            "decoder_helper",
        )
        self.assertEqual(result["summary"]["sampling"]["effective_rate_hz"], 20.0)
        self.assertAlmostEqual(
            result["summary"]["cpu_percent"]["time_weighted_mean"], 6.0
        )
        self.assertEqual(
            result["summary"]["memory"]["synchronized_peak_phys_footprint_bytes"],
            134 * mib,
        )
        self.assertEqual(
            result["summary"]["memory"]["conservative_peak_phys_footprint_bytes"],
            154 * mib,
        )
        self.assertEqual(
            result["summary"]["memory"]["hard_gate_peak_bytes"], 154 * mib
        )
        self.assertTrue(result["summary"]["gates"]["cpu_under_limit"])
        self.assertTrue(result["summary"]["gates"]["memory_under_limit"])
        self.assertTrue(result["summary"]["eligible"])

    def test_sampler_retains_nonzero_query_brackets_for_conservative_reduction(self):
        clock = FakeClock()

        def measured_reader(pid):
            clock.now_ns += 2_000_000
            return snapshot(clock.now_ns, 1, 1, 1)

        result = run_shipper.sample_processes(
            [1],
            duration_s=0.05,
            reader=measured_reader,
            clock_ns=clock,
            sleeper=clock.sleep,
            process_provenance=provenance(1),
            coalition_membership_reader=membership(1),
        )

        first = result["samples"][0]
        self.assertEqual(first["scheduled_monotonic_ns"], 1_000_000_000)
        self.assertLess(
            first["query_started_monotonic_ns"],
            first["query_finished_monotonic_ns"],
        )
        self.assertEqual(first["query_duration_ns"], 2_000_000)
        self.assertGreaterEqual(
            first["monotonic_ns"], first["scheduled_monotonic_ns"]
        )

    def test_missing_helper_never_becomes_a_partial_sum(self):
        clock = FakeClock()
        reader = SequenceReader(
            {
                1: [snapshot(0, 10, 10, 10), snapshot(1, 10, 10, 10)],
                2: [snapshot(0, 20, 20, 20), OSError("gone")],
            }
        )
        result = run_shipper.sample_processes(
            [1, 2],
            duration_s=0.05,
            reader=reader,
            clock_ns=clock,
            sleeper=clock.sleep,
            process_provenance=provenance(1, 2),
        )
        final = result["samples"][-1]["aggregate"]
        self.assertFalse(final["complete"])
        self.assertIsNone(final["phys_footprint_bytes"])
        self.assertFalse(result["summary"]["eligible"])
        self.assertFalse(result["summary"]["gates"]["cpu_under_limit"])

    def test_missing_or_cross_coalition_provenance_is_ineligible(self):
        clock = FakeClock()
        reader = SequenceReader(
            {1: [snapshot(0, 1, 1, 1), snapshot(1, 1, 1, 1)]}
        )
        with self.assertRaisesRegex(run_shipper.ShipperError, "provenance"):
            run_shipper.sample_processes(
                [1], duration_s=0.05, reader=reader, clock_ns=clock, sleeper=clock.sleep
            )

        clock = FakeClock()
        reader = SequenceReader(
            {
                1: [snapshot(0, 1, 1, 1), snapshot(1, 1, 1, 1)],
                2: [snapshot(0, 1, 1, 1), snapshot(1, 1, 1, 1)],
            }
        )
        with self.assertRaises(run_shipper.ShipperError):
            run_shipper.sample_processes(
                [1, 2],
                duration_s=0.05,
                reader=reader,
                clock_ns=clock,
                sleeper=clock.sleep,
                process_provenance={
                    1: {"role": "app", "coalition_id": 7},
                    2: {"role": "decoder_helper", "coalition_id": 8},
                },
            )

    def test_sampling_interval_is_fixed_at_20hz(self):
        with self.assertRaisesRegex(ValueError, "fixed 0.05s interval"):
            run_shipper.sample_processes(
                [1],
                duration_s=0.1,
                interval_s=0.1,
                reader=lambda pid: snapshot(0, 1, 1, 1),
                process_provenance=provenance(1),
            )

    def test_sampler_lateness_invalidates_evidence(self):
        class SlowClock(FakeClock):
            pass

        clock = SlowClock()

        def slow_reader(pid):
            clock.now_ns += 120_000_000
            return snapshot(clock.now_ns, 1, 1, 1)

        result = run_shipper.sample_processes(
            [1],
            duration_s=0.1,
            interval_s=0.05,
            reader=slow_reader,
            clock_ns=clock,
            sleeper=clock.sleep,
            process_provenance=provenance(1),
        )
        self.assertLess(result["summary"]["sampling"]["effective_rate_hz"], 10.0)
        self.assertFalse(result["summary"]["sampling"]["timing_valid"])
        self.assertFalse(result["summary"]["eligible"])

    def test_helper_appearing_during_sampling_invalidates_partial_totals(self):
        clock = FakeClock()
        observations = iter(
            [
                {"available": True, "complete": True, "observed_pids": [1]},
                {"available": True, "complete": False, "observed_pids": [1, 2]},
            ]
        )
        result = run_shipper.sample_processes(
            [1],
            duration_s=0.05,
            reader=SequenceReader(
                {1: [snapshot(0, 1, 1, 1), snapshot(1, 1, 1, 1)]}
            ),
            clock_ns=clock,
            sleeper=clock.sleep,
            process_provenance=provenance(1),
            coalition_membership_reader=lambda: next(observations),
        )
        self.assertFalse(result["summary"]["eligible"])
        self.assertFalse(
            result["summary"]["provenance"]["coalition_enumeration_complete"]
        )


class DragPlanTests(unittest.TestCase):
    def test_plan_is_bounded_repeatable_and_forward_then_reverse(self):
        left = run_shipper.build_drag_plan(
            rate_hz=4.0, leg_duration_s=1.0, inter_gesture_gap_s=0.25
        )
        right = run_shipper.build_drag_plan(
            rate_hz=4.0, leg_duration_s=1.0, inter_gesture_gap_s=0.25
        )
        self.assertEqual(left, right)
        self.assertEqual(len(left), 12)
        self.assertEqual((left[0].action, left[0].normalized_position), ("down", 0.05))
        self.assertEqual((left[5].action, left[5].normalized_position), ("up", 0.95))
        self.assertEqual((left[6].action, left[6].normalized_position), ("down", 0.95))
        self.assertEqual((left[-1].action, left[-1].normalized_position), ("up", 0.05))
        self.assertEqual(left[6].offset_ns, 1_250_000_000)

    def test_driver_requires_an_injected_sink_and_follows_deadlines(self):
        clock = FakeClock(start_ns=0)
        steps = run_shipper.build_drag_plan(
            rate_hz=2.0, leg_duration_s=0.5, inter_gesture_gap_s=0.25
        )
        observed = []
        run_shipper.drive_drag_plan(
            steps,
            lambda step: observed.append((clock(), step)),
            clock_ns=clock,
            sleeper=clock.sleep,
        )
        self.assertEqual(len(observed), len(steps))
        self.assertEqual([at for at, _ in observed], [step.offset_ns for step in steps])

    def test_delivery_requires_every_interval_near_120hz_not_only_the_mean(self):
        plan = run_shipper.build_drag_plan()
        clocks = []
        now = 1_000_000_000
        for index, step in enumerate(plan):
            if index:
                previous = plan[index - 1]
                if step.gesture == previous.gesture and step.action == "move":
                    now += 1_000_000 if index % 2 else 15_666_666
                else:
                    now += max(0, step.offset_ns - previous.offset_ns)
            clocks.append(now)
        evidence = {
            "telemetry_gesture_ids": [21, 22],
            "screen_driver": {
                "screen_backed": True,
                "window_visible": True,
                "approved_computer_use": True,
            },
            "events": [
                {**step.as_dict(), "delivered_monotonic_ns": clock}
                for step, clock in zip(plan, clocks)
            ],
        }
        report, errors = run_shipper._validate_drag_schedule_evidence(evidence)
        self.assertFalse(report["eligible"])
        self.assertTrue(any("intervals" in error for error in errors))


class TelemetryTests(unittest.TestCase):
    @staticmethod
    def _two_leg_windows():
        return {
            21: {"down_monotonic_ns": 1_295_000_000, "up_monotonic_ns": 1_361_000_000},
            22: {"down_monotonic_ns": 1_365_000_000, "up_monotonic_ns": 1_410_000_000},
        }

    def test_native_startup_and_visible_scrub_distributions(self):
        report = run_shipper.summarize_native_telemetry(
            parsed_native_trial(), 1_000_000_000,
            scrub_gesture_windows=self._two_leg_windows(),
            source_fps=30.0,
        )
        self.assertFalse(report["native_proof"]["eligible"])
        self.assertTrue(report["native_proof"]["provisional_eligible"])
        self.assertEqual(report["native_proof"]["route"], "native")
        self.assertEqual(
            report["startup"]["external_request_to_first_visible_frame_ms"], 200.0
        )
        scrub = report["scrub"]
        self.assertTrue(scrub["eligible"])
        self.assertEqual(scrub["counts"]["demanded"], 5)
        self.assertEqual(scrub["counts"]["coalesced_before_dispatch"], 1)
        self.assertEqual(scrub["distributions"]["request_to_draw_ms"]["p50"], 27.5)
        self.assertEqual(scrub["distributions"]["visible_frame_cadence_ms"]["max"], 45.0)
        self.assertAlmostEqual(scrub["distributions"]["target_error_ms"]["max"], 10.0)
        self.assertAlmostEqual(
            scrub["distributions"]["commit_to_draw_ms"]["p95"], 38.15
        )

    def test_missing_external_launch_clock_does_not_invent_cold_latency(self):
        report = run_shipper.summarize_native_telemetry(parsed_native_trial(), None)
        self.assertFalse(report["native_proof"]["eligible"])
        self.assertTrue(report["native_proof"]["provisional_eligible"])
        self.assertFalse(report["startup"]["eligible"])
        self.assertFalse(report["startup"]["launch_request_clock_available"])
        self.assertIsNone(
            report["startup"]["external_request_to_first_visible_frame_ms"]
        )

    def test_fallback_is_distinguished_and_invalidates_native_proof(self):
        report = run_shipper.summarize_native_telemetry(
            parsed_native_trial(fallback=True), 1_000_000_000
        )
        self.assertFalse(report["native_proof"]["eligible"])
        self.assertEqual(report["native_proof"]["route"], "fallback")

    def test_startup_requires_distinct_second_same_process_warm_open(self):
        report = run_shipper.summarize_native_telemetry(
            parsed_native_trial(include_scrub=False),
            1_000_000_000,
            TEST_RUN_ID,
            TEST_PROCESS_ID,
            TEST_PROCESS_START_ABSTIME,
            TEST_ASSET_SHA256,
        )

        self.assertFalse(report["startup"]["warm_open"]["eligible"])
        self.assertFalse(report["startup"]["warm_open"]["measurement_available"])
        self.assertEqual(
            report["startup"]["measurements"][
                "warm_open_to_first_visible_frame_ms"
            ],
            [],
        )

    def test_distinct_second_same_process_open_is_warm_loading_measurement(self):
        parsed = parsed_native_trial(include_scrub=False)
        parsed["events"].extend(
            json.loads(line)
            for line in (
                native_event("open_requested", 1_300_000_000, source_key=8),
                native_event(
                    "native_selected",
                    1_320_000_000,
                    route="native",
                    route_proof=True,
                    source_key=8,
                    attempt=21,
                    serial=22,
                    generation=23,
                    target_seconds=0.0,
                ),
                native_event(
                    "first_frame_drawn",
                    1_380_000_000,
                    route="native",
                    source_key=8,
                    attempt=21,
                    serial=24,
                    generation=23,
                    draw_sequence=2,
                    target_seconds=0.0,
                ),
            )
        )
        parsed["matching_event_count"] = len(parsed["events"])
        report = run_shipper.summarize_native_telemetry(
            parsed,
            1_000_000_000,
            TEST_RUN_ID,
            TEST_PROCESS_ID,
            TEST_PROCESS_START_ABSTIME,
            TEST_ASSET_SHA256,
        )

        self.assertFalse(report["startup"]["warm_open"]["eligible"])
        self.assertTrue(report["native_proof"]["provisional_eligible"])
        self.assertTrue(report["startup"]["warm_open"]["measurement_available"])
        self.assertEqual(
            report["startup"]["warm_open"]["open_to_first_visible_frame_ms"],
            80.0,
        )

    def test_startup_latency_thresholds_have_exact_release_boundaries(self):
        values = [750.0] * 96 + [1500.0] * 5
        measured = run_shipper.distribution(values)
        self.assertLessEqual(measured["p95"], run_shipper.MAX_STARTUP_P95_MS)
        self.assertLessEqual(measured["max"], run_shipper.MAX_STARTUP_SINGLE_MS)

        values[-1] = 1500.001
        measured = run_shipper.distribution(values)
        self.assertGreater(measured["max"], run_shipper.MAX_STARTUP_SINGLE_MS)

    def test_warm_loading_thresholds_have_exact_goal_boundaries(self):
        measured = run_shipper.distribution([100.0] * 96 + [200.0] * 5)
        self.assertLessEqual(measured["p95"], run_shipper.MAX_WARM_OPEN_P95_MS)
        self.assertLessEqual(measured["max"], run_shipper.MAX_WARM_OPEN_SINGLE_MS)

        measured = run_shipper.distribution([100.0] * 96 + [200.0] * 4 + [200.001])
        self.assertGreater(measured["max"], run_shipper.MAX_WARM_OPEN_SINGLE_MS)

    def test_unmatched_visible_draw_is_ineligible(self):
        parsed = parsed_native_trial(include_scrub=False)
        parsed["events"].append(
            {
                "event": "preview_frame_drawn",
                "monotonic_ns": 2_000_000_000,
                "route": "native",
                "gesture": 1,
                "request": 2,
                "target_seconds": 1.0,
                "libmpv_initialized": False,
            }
        )
        report = run_shipper.summarize_scrub_telemetry(parsed)
        self.assertFalse(report["eligible"])
        self.assertIn("no matching demand, dispatch, and admission", report["errors"][0])

    def test_preview_failure_is_counted_and_invalidates_scrub(self):
        parsed = parsed_native_trial()
        extra = run_suite.parse_wam_native_telemetry(
            "\n".join(
                [
                    native_event(
                        "preview_demanded",
                        1_500_000_000,
                        route="native",
                        gesture=22,
                        request=40,
                        target_seconds=4.0,
                    ),
                    native_event(
                        "preview_dispatched",
                        1_505_000_000,
                        route="native",
                        gesture=22,
                        request=40,
                        target_seconds=4.0,
                    ),
                    native_event(
                        "preview_admitted",
                        1_510_000_000,
                        route="native",
                        attempt=11,
                        serial=18,
                        generation=13,
                        gesture=22,
                        request=40,
                        target_seconds=4.0,
                    ),
                    native_event(
                        "preview_failed",
                        1_520_000_000,
                        route="native",
                        attempt=11,
                        serial=18,
                        generation=13,
                        gesture=22,
                        request=40,
                        target_seconds=4.0,
                    ),
                ]
            )
        )
        parsed["events"].extend(extra["events"])
        report = run_shipper.summarize_scrub_telemetry(parsed)
        self.assertFalse(report["eligible"])
        self.assertEqual(report["counts"]["failed"], 1)
        self.assertEqual(report["counts"]["superseded_after_admission"], 0)
        self.assertEqual(
            report["distributions"]["request_to_failure_ms"]["p50"], 20.0
        )
        self.assertTrue(
            any("preview failure observed" in error for error in report["errors"])
        )

    def test_demand_convergence_counts_coalesced_request_and_rejects_stale_draw(self):
        parsed = parsed_native_trial()
        report = run_shipper.summarize_scrub_telemetry(
            parsed, self._two_leg_windows(), 30.0
        )
        self.assertEqual(report["counts"]["demanded"], 5)
        self.assertEqual(report["counts"]["dispatched"], 4)
        self.assertEqual(report["counts"]["unresolved_demands"], 0)
        self.assertEqual(len(report["measurements"]["latest_demand_to_visible_ms"]), 5)
        self.assertEqual(report["convergence"][-1]["terminal"], "commit")

        parsed = parsed_native_trial()
        parsed["events"] = [
            event
            for event in parsed["events"]
            if not (
                event.get("gesture") == 22
                and event.get("event") in {
                    "commit_seek_submitted", "commit_ready", "commit_frame_drawn"
                }
            )
        ]
        report = run_shipper.summarize_scrub_telemetry(
            parsed, self._two_leg_windows(), 30.0
        )
        self.assertFalse(report["eligible"])
        self.assertEqual(report["counts"]["unresolved_demands"], 1)

    def test_boundary_gaps_include_leg_start_and_release(self):
        windows = self._two_leg_windows()
        windows[21]["up_monotonic_ns"] = 1_500_000_000
        report = run_shipper.summarize_scrub_telemetry(
            parsed_native_trial(), windows, 5.0
        )
        self.assertFalse(
            report["quality_gates"][
                "boundary_inclusive_visible_gap_within_50ms_p95_100ms_max"
            ]
        )


class ReportAndCliTests(unittest.TestCase):
    def _artifact(
        self,
        phase,
        telemetry,
        *,
        codec,
        container,
        profile,
        run,
        cpu=5.0,
        peak=100 * 1024 * 1024,
    ):
        return {
            "schema": run_shipper.SCHEMA,
            "kind": "process_samples",
            "phase": phase,
            "metadata": {
                "codec": codec,
                "container": container,
                "profile": profile,
                "clip_id": f"{codec}-{container}-{profile}",
                "run": str(run),
            },
            "native_telemetry": telemetry,
            "summary": {
                "eligible": True,
                "cpu_percent": {"time_weighted_mean": cpu},
                "memory": {"hard_gate_peak_bytes": peak},
            },
        }

    def _raw_artifact(
        self,
        phase,
        parsed,
        *,
        codec,
        container,
        profile,
        run,
    ):
        duration = {
            "startup": 0.25,
            "steady": run_shipper.DEFAULT_STEADY_DURATION_S,
            "scrub": run_shipper.build_drag_plan()[-1].offset_ns / 1_000_000_000.0,
            run_shipper.FALLBACK_PHASE: run_shipper.DEFAULT_FALLBACK_DURATION_S,
        }[phase]
        clock = FakeClock(
            start_ns=20_000_000_000 if phase == "steady" else 1_000_000_000
        )
        calls = 0

        def reader(pid):
            nonlocal calls
            calls += 1
            return snapshot(
                calls * 2_500_000,
                50 * 1024 * 1024,
                60 * 1024 * 1024,
                70 * 1024 * 1024,
                start=TEST_PROCESS_START_ABSTIME,
            )

        artifact = run_shipper.sample_processes(
            [TEST_PROCESS_ID],
            duration_s=duration,
            phase=phase,
            reader=reader,
            clock_ns=clock,
            sleeper=clock.sleep,
            process_provenance=provenance(
                TEST_PROCESS_ID, start=TEST_PROCESS_START_ABSTIME
            ),
            coalition_membership_reader=membership(TEST_PROCESS_ID),
        )
        artifact["metadata"] = {
            "codec": codec,
            "container": container,
            "profile": profile,
            "clip_id": f"{codec}-{container}-{profile}",
            "run": str(run),
            "warmup_s": run_shipper.DEFAULT_STEADY_WARMUP_S,
            "clip_duration_s": 4.0,
            "asset": {
                "sha256": "b" * 64 if phase == run_shipper.FALLBACK_PHASE else "a" * 64,
                "byte_length": 4096,
                "codec": codec,
                "container": container,
                "profile": profile,
                "audio_codec": (
                    "opus" if phase == run_shipper.FALLBACK_PHASE else "aac"
                ),
                "native_eligible": phase != run_shipper.FALLBACK_PHASE,
                "staged_bundle_asset": phase == run_shipper.FALLBACK_PHASE,
                "coded_width": 1920,
                "coded_height": 1080,
                **(
                    {"fourcc": "hvc1"}
                    if codec == "hevc" and container in {"mp4", "mov"}
                    else {}
                ),
            },
        }
        artifact["native_telemetry_raw"] = parsed
        artifact["launch_request_monotonic_ns"] = 1_000_000_000
        artifact["native_telemetry"] = run_shipper.summarize_native_telemetry(
            parsed,
            1_000_000_000,
            TEST_RUN_ID,
            TEST_PROCESS_ID,
            TEST_PROCESS_START_ABSTIME,
        )
        if phase == "scrub":
            artifact["drag_schedule_evidence"] = {
                "run_id": TEST_RUN_ID,
                "process_id": TEST_PROCESS_ID,
                "process_start_abstime": TEST_PROCESS_START_ABSTIME,
                "telemetry_gesture_ids": [21, 22],
                "screen_driver": {
                    "screen_backed": True,
                    "window_visible": True,
                    "approved_computer_use": True,
                    "run_id": TEST_RUN_ID,
                    "process_id": TEST_PROCESS_ID,
                    "process_start_abstime": TEST_PROCESS_START_ABSTIME,
                },
                "events": [
                    {
                        **step.as_dict(),
                        "delivered_monotonic_ns": 1_000_000_000 + step.offset_ns,
                    }
                    for step in run_shipper.build_drag_plan()
                ]
            }
        if phase == run_shipper.FALLBACK_PHASE:
            artifact["fallback_control"] = {
                "screen_driver": {
                    "screen_backed": True,
                    "window_visible": True,
                    "approved_computer_use": True,
                    "run_id": TEST_RUN_ID,
                    "process_id": TEST_PROCESS_ID,
                    "process_start_abstime": TEST_PROCESS_START_ABSTIME,
                },
                "staged_bundle": True,
                "verify_runtime_mode": False,
                "route": "fallback",
                "fallback_selected": True,
                "native_selected": False,
                "route_selection_monotonic_ns": 1_120_000_000,
                "fallback_library": {
                    "loaded": True,
                    "canonical_path": "/Applications/WAM.app/Contents/Frameworks/WAMMpvFallback.dylib",
                    "loaded_by_process_id": TEST_PROCESS_ID,
                    "observed_after_route_selection": True,
                    "not_loaded_before_route_selection": True,
                    "observation_method": "dyld_image_list",
                    "pre_route_observed_monotonic_ns": 1_110_000_000,
                    "observed_monotonic_ns": 1_500_000_000,
                },
                "visible_frame": {
                    "observed": True,
                    "monotonic_ns": 2_000_000_000,
                    "screen_capture_sha256": "a" * 64,
                },
                "audio": {
                    "active": True,
                    "audible": True,
                    "monotonic_ns": 2_100_000_000,
                    "active_proof": "mpv audio-output-active property",
                    "audible_proof": "approved screen-run operator witness",
                },
            }
        if phase == "steady":
            artifact["warmup_evidence"] = {
                "playback_started_monotonic_ns": (
                    artifact["samples"][0]["monotonic_ns"]
                    - round(run_shipper.DEFAULT_STEADY_WARMUP_S * 1_000_000_000)
                ),
                "measurement_started_monotonic_ns": artifact["samples"][0][
                    "monotonic_ns"
                ],
                "continuous_playback": True,
                "run_id": TEST_RUN_ID,
                "process_id": TEST_PROCESS_ID,
                "process_start_abstime": TEST_PROCESS_START_ABSTIME,
            }
        return artifact

    def test_legacy_shape_cannot_claim_complete_shipping_evidence(self):
        native_parsed = parsed_native_trial()
        fallback_parsed = parsed_fallback_trial()
        variant = ("h264", "mp4", "any")
        with mock.patch.object(run_shipper, "REQUIRED_VARIANTS", (variant,)), mock.patch.object(
            run_shipper,
            "REQUIRED_REPLICATES",
            {"startup": 1, "steady": 1, "scrub": 1},
        ), mock.patch.object(run_shipper, "DEFAULT_FALLBACK_RUNS", 1), mock.patch.object(
            run_shipper, "MIN_SCRUB_REQUESTS_PER_LEG", 2
        ):
            artifacts = [
                self._raw_artifact(
                    phase,
                    native_parsed,
                    codec=variant[0],
                    container=variant[1],
                    profile=variant[2],
                    run=1,
                )
                for phase in ("startup", "steady", "scrub")
            ]
            artifacts.append(
                self._raw_artifact(
                    run_shipper.FALLBACK_PHASE,
                    fallback_parsed,
                    codec=run_shipper.FALLBACK_VARIANT[0],
                    container=run_shipper.FALLBACK_VARIANT[1],
                    profile=run_shipper.FALLBACK_VARIANT[2],
                    run=1,
                )
            )
            report = run_shipper.summarize_artifacts(artifacts)
        self.assertEqual(report["route_counts"]["native"], 3)
        self.assertEqual(
            report["startup"]["external_request_to_first_visible_frame_ms"]["count"],
            1,
        )
        self.assertEqual(
            report["steady"]["per_run_time_weighted_cpu_percent"]["p50"], 5.0
        )
        # Matrix cardinality and native route facts alone are deliberately
        # insufficient: the final gate additionally needs the real second
        # in-process warm open, exact phase CPU windows, memory reconciliation,
        # and trusted screen/loader/audio capture receipts.
        self.assertFalse(report["shipping_evidence_complete"])

    def test_one_fallback_keeps_summary_from_shipping(self):
        native = run_shipper.summarize_native_telemetry(
            parsed_native_trial(), 1_000_000_000
        )
        fallback = run_shipper.summarize_native_telemetry(
            parsed_native_trial(fallback=True), 1_000_000_000
        )
        artifacts = []
        for phase, count in run_shipper.REQUIRED_REPLICATES.items():
            for codec, container, profile in run_shipper.REQUIRED_VARIANTS:
                for run in range(count):
                    selected = fallback if not artifacts else native
                    artifacts.append(
                        self._artifact(
                            phase, selected, codec=codec, container=container,
                            profile=profile, run=run
                        )
                    )
        report = run_shipper.summarize_artifacts(artifacts)
        self.assertEqual(report["route_counts"]["fallback"], 1)
        self.assertFalse(report["gates"]["native_route_all_telemetry_trials"])
        self.assertFalse(report["shipping_evidence_complete"])

    def test_metadata_free_or_ineligible_native_proof_cannot_ship(self):
        telemetry = run_shipper.summarize_native_telemetry(
            parsed_native_trial(), 1_000_000_000
        )
        artifact = self._artifact(
            "startup", telemetry, codec="h264", container="mp4",
            profile="any", run=1
        )
        artifact.pop("metadata")
        report = run_shipper.summarize_artifacts([artifact])
        self.assertFalse(report["gates"]["required_variant_replicate_matrix_complete"])
        self.assertFalse(report["shipping_evidence_complete"])

        telemetry["native_proof"]["eligible"] = False
        telemetry["native_proof"]["route"] = "native"
        artifact = self._artifact(
            "startup", telemetry, codec="h264", container="mp4",
            profile="any", run=1
        )
        report = run_shipper.summarize_artifacts([artifact])
        self.assertFalse(report["gates"]["native_route_all_telemetry_trials"])

    def test_missing_memory_peak_cannot_ship(self):
        telemetry = run_shipper.summarize_native_telemetry(
            parsed_native_trial(), 1_000_000_000
        )
        artifacts = []
        for phase, count in run_shipper.REQUIRED_REPLICATES.items():
            for codec, container, profile in run_shipper.REQUIRED_VARIANTS:
                for run in range(count):
                    artifacts.append(
                        self._artifact(
                            phase, telemetry, codec=codec, container=container,
                            profile=profile, run=run
                        )
                    )
        artifacts[0]["summary"]["memory"]["hard_gate_peak_bytes"] = None
        report = run_shipper.summarize_artifacts(artifacts)
        self.assertFalse(report["gates"]["all_sampled_memory_peaks_under_300_mib"])
        self.assertFalse(report["shipping_evidence_complete"])

    def test_summary_only_artifact_is_never_shipping_evidence(self):
        telemetry = run_shipper.summarize_native_telemetry(
            parsed_native_trial(), 1_000_000_000
        )
        artifact = self._artifact(
            "startup",
            telemetry,
            codec="h264",
            container="mp4",
            profile="any",
            run=1,
        )
        report = run_shipper.summarize_artifacts([artifact])
        self.assertTrue(
            any("raw" in error for error in report["evidence_errors"])
        )
        self.assertFalse(report["shipping_evidence_complete"])

    def test_verify_runtime_fallback_claim_is_rejected(self):
        report, errors = run_shipper._validate_fallback_control(
            {
                "fallback_control": {
                    "eligible": True,
                    "screen_driver": {
                        "screen_backed": True,
                        "window_visible": True,
                        "approved_computer_use": True,
                        "run_id": TEST_RUN_ID,
                        "process_id": TEST_PROCESS_ID,
                        "process_start_abstime": TEST_PROCESS_START_ABSTIME,
                    },
                    "staged_bundle": True,
                    "verify_runtime_mode": True,
                    "route": "fallback",
                    "fallback_selected": True,
                    "native_selected": False,
                }
            },
            TEST_PROCESS_ID,
            parsed_fallback_trial(),
            "/Applications/WAM.app/Contents/MacOS/WAM",
        )
        self.assertFalse(report["eligible"])
        self.assertTrue(any("verify-runtime" in error for error in errors))

    def test_sparse_scrub_telemetry_cannot_claim_the_120hz_protocol(self):
        artifact = self._raw_artifact(
            "scrub",
            parsed_native_trial(),
            codec="h264",
            container="mp4",
            profile="any",
            run=1,
        )
        _, errors = run_shipper._recompute_artifact(artifact, 0)
        self.assertTrue(any("too few requests" in error for error in errors))

    def test_plan_cli_prints_without_launching_and_sample_requires_pids(self):
        stdout = io.StringIO()
        with contextlib.redirect_stdout(stdout):
            self.assertEqual(run_shipper.main(["plan"]), 0)
        value = json.loads(stdout.getvalue())
        self.assertTrue(value["does_not_launch_or_generate_input"])
        self.assertEqual(value["phases"]["steady"]["sample_interval_s"], 0.05)
        self.assertGreater(value["drag_schedule"]["event_count"], 900)
        self.assertFalse(value["comparative_appendix"]["gating"])
        self.assertFalse(
            value["comparative_appendix"]["optional_ffmpeg_lab"]["gating"]
        )

        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            run_shipper.build_parser().parse_args(
                ["sample", "--phase", "steady", "--duration", "1", "--output", "x"]
            )

    def test_valid_sample_cli_uses_the_fixed_interval_and_identity_arguments(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            executable = root / "WAM"
            executable.write_text("fixture", encoding="utf-8")
            output = root / "sample.json"
            captured = {}

            def fake_sample(pids, **kwargs):
                captured.update(kwargs)
                return {
                    "schema": run_shipper.SCHEMA,
                    "kind": "process_samples",
                    "phase": kwargs["phase"],
                }

            with mock.patch.object(
                run_shipper,
                "capture_process_provenance",
                return_value=([1], provenance(1)),
            ), mock.patch.object(
                run_shipper, "sample_processes", side_effect=fake_sample
            ):
                status = run_shipper.main(
                    [
                        "sample",
                        "--process",
                        "1:app:700",
                        "--phase",
                        "startup",
                        "--duration",
                        "0.05",
                        "--wam-executable",
                        str(executable),
                        "--expected-run-id",
                        TEST_RUN_ID,
                        "--expected-process-start-abstime",
                        str(TEST_PROCESS_START_ABSTIME),
                        "--output",
                        str(output),
                    ]
                )
            self.assertEqual(status, 0)
            self.assertEqual(captured["interval_s"], 0.05)
            self.assertEqual(json.loads(output.read_text())["phase"], "startup")

    def test_summarize_cli_refuses_to_overwrite_output(self):
        telemetry = run_shipper.summarize_native_telemetry(
            parsed_native_trial(), 1_000_000_000
        )
        artifact = self._artifact(
            "startup", telemetry, codec="h264", container="mp4",
            profile="any", run=1
        )
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "source.json"
            output = root / "out.json"
            source.write_text(json.dumps(artifact), encoding="utf-8")
            output.write_text("keep", encoding="utf-8")
            with contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(
                    run_shipper.main(
                        ["summarize", str(source), "--output", str(output)]
                    ),
                    2,
                )
            self.assertEqual(output.read_text(encoding="utf-8"), "keep")

    def test_incomparable_native_fallback_appendix_is_non_gating(self):
        appendix = run_shipper._summarize_comparative_appendix(
            [
                {
                    "kind": "comparative_trial",
                    "mode": "native_wam",
                    "pair_id": "same-bytes",
                    "asset": {"sha256": "a" * 64, "byte_length": 10, "codec": "h264"},
                    "hardware_policy": "videotoolbox_required",
                },
                {
                    "kind": "comparative_trial",
                    "mode": "bundled_fallback_wam",
                    "pair_id": "same-bytes",
                    "asset": {"sha256": "b" * 64, "byte_length": 10, "codec": "h264"},
                    "hardware_policy": "videotoolbox_required",
                },
            ]
        )
        self.assertFalse(appendix["gating"])
        self.assertFalse(appendix["pairs"][0]["comparable"])
        self.assertEqual(appendix["pairs"][0]["metrics"], {})


if __name__ == "__main__":
    unittest.main()
