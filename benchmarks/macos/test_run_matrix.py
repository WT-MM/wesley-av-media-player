#!/usr/bin/env python3

import argparse
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import run_matrix


def runner_args(**overrides):
    values = {
        "runner": Path("/repo/run_suite.py"),
        "interval": 1,
        "launch_timeout": 20.0,
        "wam_app": Path("/tmp/WAM.app"),
        "vlc": Path("/Applications/VLC.app"),
        "quicktime": Path("/System/Applications/QuickTime Player.app"),
        "collector": None,
        "skip_expected_unsupported": False,
    }
    values.update(overrides)
    return argparse.Namespace(**values)


class ScheduleTests(unittest.TestCase):
    def test_three_repetition_counterbalance(self):
        self.assertEqual(
            run_matrix.counterbalanced_player_order(1), ("wam", "vlc", "quicktime")
        )
        self.assertEqual(
            run_matrix.counterbalanced_player_order(2), ("vlc", "quicktime", "wam")
        )
        self.assertEqual(
            run_matrix.counterbalanced_player_order(3), ("quicktime", "wam", "vlc")
        )
        self.assertEqual(
            run_matrix.counterbalanced_player_order(4), ("wam", "vlc", "quicktime")
        )

    def test_player_selection_preserves_counterbalanced_relative_order(self):
        args = argparse.Namespace(player=["wam"])
        self.assertEqual(run_matrix.selected_players(args), ("wam",))
        self.assertEqual(run_matrix.selected_player_order(2, ("wam",)), ("wam",))

    def test_primary_plan_has_27_unique_trials_and_aliases(self):
        cases = [case for case in run_matrix.CASES if case.group == "primary"]
        sources = {case.id: Path("/media") / case.filename for case in cases}
        trials = run_matrix.build_trials(
            cases,
            sources,
            Path("/results/suite"),
            Path("/private/tmp/aliases"),
        )
        self.assertEqual(len(trials), 27)
        self.assertEqual(len({trial.id for trial in trials}), 27)
        self.assertEqual(len({trial.alias for trial in trials}), 27)
        self.assertEqual(len({trial.output for trial in trials}), 27)

        first_case_orders = {}
        for repetition in (1, 2, 3):
            first_case_orders[repetition] = tuple(
                trial.player
                for trial in trials
                if trial.case.id == "tos-h264-4k24-1x"
                and trial.repetition == repetition
            )
        self.assertEqual(
            first_case_orders,
            {
                1: ("wam", "vlc", "quicktime"),
                2: ("vlc", "quicktime", "wam"),
                3: ("quicktime", "wam", "vlc"),
            },
        )

    def test_build_trials_can_create_wam_only_experiment_schedule(self):
        case = run_matrix.CASE_BY_ID["tos-h264-4k24-1x"]
        trials = run_matrix.build_trials(
            [case],
            {case.id: Path("/media") / case.filename},
            Path("/results/suite"),
            Path("/private/tmp/aliases"),
            repetition_override=3,
            players=("wam",),
        )
        self.assertEqual(len(trials), 3)
        self.assertEqual([trial.player for trial in trials], ["wam", "wam", "wam"])

    def test_duration_guard_accounts_for_playback_speed(self):
        case = run_matrix.CASE_BY_ID["tos-h264-4k24-2x"]
        run_matrix.validate_playback_window(case, 12.0, 20.0)
        with self.assertRaisesRegex(run_matrix.MatrixError, "needs 200.000s"):
            run_matrix.validate_playback_window(case, 50.0, 50.0)


class ArtifactSafetyTests(unittest.TestCase):
    def test_output_suite_directory_is_exclusive(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            reserved = run_matrix.reserve_output_directory(root, "suite-one")
            self.assertTrue(reserved.is_dir())
            with self.assertRaisesRegex(run_matrix.MatrixError, "refusing to reuse"):
                run_matrix.reserve_output_directory(root, "suite-one")

    def test_per_trial_aliases_are_real_unique_hardlinks(self):
        case = run_matrix.CASE_BY_ID["wam-test-h264-1x"]
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "source.mp4"
            source.write_bytes(b"identical media bytes")
            alias_dir = root / "aliases"
            alias_dir.mkdir()
            output_dir = root / "results"
            trials = run_matrix.build_trials(
                [case],
                {case.id: source},
                output_dir,
                alias_dir,
                repetition_override=1,
            )
            run_matrix.create_hardlink_aliases(trials)
            self.assertEqual(len({trial.alias for trial in trials}), 3)
            source_identity = (source.stat().st_dev, source.stat().st_ino)
            for trial in trials:
                self.assertEqual(
                    (trial.alias.stat().st_dev, trial.alias.stat().st_ino), source_identity
                )
            cleanup = run_matrix.cleanup_aliases(trials, alias_dir)
            self.assertEqual(cleanup["removed_alias_count"], 3)
            self.assertTrue(cleanup["alias_directory_removed"])

    def test_atomic_manifest_is_valid_json(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "manifest.json"
            run_matrix.atomic_write_json(path, {"state": "first"})
            run_matrix.atomic_write_json(path, {"state": "second", "value": 2})
            self.assertEqual(json.loads(path.read_text()), {"state": "second", "value": 2})
            self.assertEqual(list(path.parent.glob(".manifest.json.*.tmp")), [])


class RunnerTests(unittest.TestCase):
    def make_trial(self, root: Path, case_id: str, player: str) -> run_matrix.Trial:
        case = run_matrix.CASE_BY_ID[case_id]
        source = root / case.filename
        source.write_bytes(b"media")
        alias = root / f"alias-{player}{source.suffix}"
        os.link(source, alias)
        output = root / "results" / "trial.json"
        return run_matrix.Trial(
            ordinal=1,
            id=f"{case.id}.rep-01.{player}",
            case=case,
            repetition=1,
            player=player,
            player_position=1,
            warmup_s=case.warmup_s,
            measurement_s=case.measurement_s,
            source=source,
            alias=alias,
            output=output,
            runner_log=output.with_name("trial.matrix-runner.log"),
        )

    def test_runner_command_matches_run_suite_cli(self):
        with tempfile.TemporaryDirectory() as temporary:
            trial = self.make_trial(
                Path(temporary), "tos-h264-4k24-2x", "wam"
            )
            command = run_matrix.build_runner_command(trial, runner_args())
            self.assertEqual(command[:2], [run_matrix.sys.executable, "/repo/run_suite.py"])
            self.assertEqual(command[command.index("--player") + 1], "wam")
            self.assertEqual(command[command.index("--speed") + 1], "2")
            self.assertEqual(command[command.index("--warmup") + 1], "12")
            self.assertEqual(command[command.index("--duration") + 1], "20")
            self.assertEqual(command[command.index("--window") + 1], "1180x720")
            self.assertEqual(command[command.index("--wam-app") + 1], "/tmp/WAM.app")

    def test_success_requires_result_artifact(self):
        with tempfile.TemporaryDirectory() as temporary:
            trial = self.make_trial(Path(temporary), "tos-h264-4k24-1x", "vlc")
            entry = trial.as_manifest_entry()

            def successful(command, **kwargs):
                trial.output.parent.mkdir(parents=True, exist_ok=True)
                trial.output.write_text("{}\n", encoding="utf-8")
                return subprocess.CompletedProcess(command, 0, "result\n", "")

            completed = run_matrix.execute_trial(
                trial, entry, runner_args(), run_process=successful
            )
            self.assertTrue(completed)
            self.assertEqual(entry["status"], "completed")
            self.assertTrue(entry["performance_metrics_available"])
            self.assertTrue(trial.runner_log.is_file())

    def test_failure_is_na_never_zero(self):
        with tempfile.TemporaryDirectory() as temporary:
            trial = self.make_trial(Path(temporary), "tos-hevc-4k24-1x", "wam")
            entry = trial.as_manifest_entry()

            def failed(command, **kwargs):
                return subprocess.CompletedProcess(command, 2, "", "decoder failed")

            completed = run_matrix.execute_trial(
                trial, entry, runner_args(), run_process=failed
            )
            self.assertFalse(completed)
            self.assertEqual(entry["status"], "n/a")
            self.assertEqual(entry["n_a"]["reason"], "failure")
            self.assertFalse(entry["performance_metrics_available"])
            self.assertNotIn("value", entry)

    def test_expected_unsupported_failure_has_distinct_na_reason(self):
        with tempfile.TemporaryDirectory() as temporary:
            trial = self.make_trial(Path(temporary), "nasa-minute-av1-1x", "quicktime")
            entry = trial.as_manifest_entry()

            def failed(command, **kwargs):
                return subprocess.CompletedProcess(command, 2, "", "could not open media")

            completed = run_matrix.execute_trial(
                trial, entry, runner_args(), run_process=failed
            )
            self.assertFalse(completed)
            self.assertEqual(entry["status"], "n/a")
            self.assertEqual(entry["n_a"]["reason"], "unsupported")
            self.assertIn("expectation", entry["n_a"]["basis"])

    def test_expected_unsupported_can_be_recorded_without_invocation(self):
        with tempfile.TemporaryDirectory() as temporary:
            trial = self.make_trial(Path(temporary), "noaa-octopus-vp9-1x", "quicktime")
            entry = trial.as_manifest_entry()
            invoked = False

            def must_not_run(command, **kwargs):
                nonlocal invoked
                invoked = True
                raise AssertionError("runner should not be called")

            completed = run_matrix.execute_trial(
                trial,
                entry,
                runner_args(skip_expected_unsupported=True),
                run_process=must_not_run,
            )
            self.assertFalse(completed)
            self.assertFalse(invoked)
            self.assertEqual(entry["n_a"]["reason"], "unsupported")

    def test_nasa_av1_declares_vlc_and_quicktime_unsupported(self):
        case = run_matrix.CASE_BY_ID["nasa-minute-av1-1x"]
        self.assertEqual(case.expected_unsupported_players, frozenset({"vlc", "quicktime"}))


class MatrixIntegrationTests(unittest.TestCase):
    def test_fake_runner_completes_manifest_without_launching_players(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            media = root / "media"
            media.mkdir()
            (media / "wam-test-h264-180s.mp4").write_bytes(b"fixture")
            alias_parent = root / "temporary-aliases"
            alias_parent.mkdir()
            fake_runner = root / "fake_runner.py"
            fake_runner.write_text(
                """\
import pathlib
import sys

output = pathlib.Path(sys.argv[sys.argv.index('--output') + 1])
output.parent.mkdir(parents=True, exist_ok=True)
output.write_text('{}\\n', encoding='utf-8')
""",
                encoding="utf-8",
            )
            args = run_matrix.build_parser().parse_args(
                [
                    "--case",
                    "wam-test-h264-1x",
                    "--repetitions",
                    "1",
                    "--media-dir",
                    str(media),
                    "--output-root",
                    str(root / "results"),
                    "--suite-id",
                    "integration",
                    "--runner",
                    str(fake_runner),
                    "--cooldown",
                    "0",
                ]
            )
            with mock.patch.object(run_matrix.sys, "platform", "darwin"):
                result = run_matrix.run_matrix(args, alias_parent=alias_parent)

            self.assertEqual(result, 0)
            manifest_path = root / "results" / "integration" / "manifest.json"
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            self.assertEqual(manifest["state"], "completed")
            self.assertEqual(
                [trial["player"] for trial in manifest["trials"]],
                ["wam", "vlc", "quicktime"],
            )
            self.assertEqual(
                {trial["status"] for trial in manifest["trials"]}, {"completed"}
            )
            self.assertEqual(manifest["alias_cleanup"]["removed_alias_count"], 3)
            self.assertTrue(manifest["alias_cleanup"]["alias_directory_removed"])

    def test_fail_fast_continues_across_expected_unsupported_trials(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            media = root / "media"
            media.mkdir()
            (media / "nasa-minute-av1.webm").write_bytes(b"fixture")
            alias_parent = root / "temporary-aliases"
            alias_parent.mkdir()
            fake_runner = root / "fake_runner.py"
            fake_runner.write_text(
                """\
import pathlib
import sys

player = sys.argv[sys.argv.index('--player') + 1]
if player != 'wam':
    raise SystemExit(2)
output = pathlib.Path(sys.argv[sys.argv.index('--output') + 1])
output.parent.mkdir(parents=True, exist_ok=True)
output.write_text('{}\\n', encoding='utf-8')
""",
                encoding="utf-8",
            )
            args = run_matrix.build_parser().parse_args(
                [
                    "--case",
                    "nasa-minute-av1-1x",
                    "--repetitions",
                    "1",
                    "--media-dir",
                    str(media),
                    "--output-root",
                    str(root / "results"),
                    "--suite-id",
                    "expected-unsupported",
                    "--runner",
                    str(fake_runner),
                    "--cooldown",
                    "0",
                    "--fail-fast",
                ]
            )
            with mock.patch.object(run_matrix.sys, "platform", "darwin"):
                result = run_matrix.run_matrix(args, alias_parent=alias_parent)

            self.assertEqual(result, 0)
            manifest = json.loads(
                (root / "results" / "expected-unsupported" / "manifest.json").read_text(
                    encoding="utf-8"
                )
            )
            self.assertEqual(manifest["state"], "completed_with_na")
            self.assertEqual(
                [trial["status"] for trial in manifest["trials"]],
                ["completed", "n/a", "n/a"],
            )
            self.assertEqual(
                [
                    trial.get("n_a", {}).get("reason")
                    for trial in manifest["trials"][1:]
                ],
                ["unsupported", "unsupported"],
            )


if __name__ == "__main__":
    unittest.main()
