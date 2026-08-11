#!/usr/bin/env python3

import argparse
import contextlib
import io
import signal
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import run_suite


class ParserTests(unittest.TestCase):
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
\t\tname = application.org.videolan.vlc.1.2
\t\tbundle ID = org.videolan.vlc
\t}
}
"""
        )
        self.assertEqual(coalition.coalition_id, 27910)
        self.assertEqual(coalition.bundle_id, "org.videolan.vlc")

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
