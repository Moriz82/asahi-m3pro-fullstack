#!/usr/bin/env python3
"""Source-free tests of M2 extraction, lock, and output guards; private fixtures."""
import fcntl
import importlib.util
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("runner", Path(__file__).with_name("m2-driver-source-self-test.py"))
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class RunnerTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="m2-runner-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.source = self.root / "linux"
        self.source.mkdir()
        self.output = self.root / "result"

    def git(self, *args):
        return subprocess.check_output(["git", "-C", str(self.source), "-c", "core.hooksPath=/dev/null",
                                        "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
                                        *args], stderr=subprocess.STDOUT, text=True).strip()

    def repository(self):
        self.git("init", "--template=", "--initial-branch=fixture")
        (self.source / "tracked").write_text("fixture\n")
        self.git("add", "tracked")
        self.git("commit", "--no-gpg-sign", "-m", "fixture")
        lock = self.root / ".milestone0-build.lock"
        lock.touch()
        return self.git("rev-parse", "HEAD"), lock

    def test_extraction_and_source_line(self):
        source = "prefix\nBEGIN\nkept\nEND\ntail\n"
        self.assertEqual(runner.between(source, "BEGIN", "END"), (7, "BEGIN\nkept\n"))
        self.assertEqual(runner.located(Path("driver.c"), source, runner.between(source, "BEGIN", "END")),
                         '#line 2 "driver.c"\nBEGIN\nkept\n\n')
        for bad in ("BEGIN", "END BEGIN", "BEGIN BEGIN END", "BEGIN END END"):
            with self.subTest(bad=bad), self.assertRaises(ValueError):
                runner.between(bad, "BEGIN", "END")

    def test_polling_macro_boundaries(self):
        macro = "#define test(x) \\\n  (x)\n"
        self.assertEqual(runner.macro("prefix\n" + macro + "tail\n", "test"), (7, macro))
        for bad in ("#define other(x) x\n", macro + macro, "#define test(x) \\\n"):
            with self.subTest(bad=bad), self.assertRaises(ValueError):
                runner.macro(bad, "test")

    def test_path_rejection(self):
        runner.validate_paths(self.source, self.output)
        for source, output in ((Path("relative"), self.output), (self.source, Path("relative")),
                               (self.source, self.source / "result"), (self.source, self.root / "missing" / "result")):
            with self.subTest(source=source, output=output), self.assertRaises(ValueError):
                runner.validate_paths(source, output)
        alias = self.root / "alias"
        alias.symlink_to(self.source, target_is_directory=True)
        for source, output in ((alias, self.output), (self.source, alias / "result")):
            with self.subTest(source=source, output=output), self.assertRaises(ValueError):
                runner.validate_paths(source, output)
        self.output.symlink_to(self.root / "absent")
        with self.assertRaisesRegex(ValueError, "already exists"):
            runner.validate_paths(self.source, self.output)
        self.output.unlink()
        self.output.mkdir()
        with self.assertRaisesRegex(ValueError, "already exists"):
            runner.validate_paths(self.source, self.output)

    def test_existing_build_lock_exclusion(self):
        commit, lock = self.repository()
        inode = lock.stat().st_ino
        with lock.open("rb") as held:
            fcntl.flock(held, fcntl.LOCK_EX | fcntl.LOCK_NB)
            with self.assertRaises(BlockingIOError), runner.locked_source(self.source, commit):
                self.fail("exclusive build lock accepted")
        with runner.locked_source(self.source, commit):
            # Concurrent read-only users are permitted; a build is not.
            with runner.locked_source(self.source, commit), lock.open("rb") as other:
                with self.assertRaises(BlockingIOError):
                    fcntl.flock(other, fcntl.LOCK_EX | fcntl.LOCK_NB)
        with lock.open("rb") as released:
            fcntl.flock(released, fcntl.LOCK_EX | fcntl.LOCK_NB)
        self.assertEqual(lock.stat().st_ino, inode)

    def test_missing_lock_not_created(self):
        with self.assertRaises(FileNotFoundError), runner.locked_source(self.source, "0" * 40):
            self.fail("missing lock accepted")
        self.assertFalse((self.root / ".milestone0-build.lock").exists())

    def test_wrong_pin_dirty_and_untracked_source(self):
        commit, _ = self.repository()
        with self.assertRaisesRegex(ValueError, "source.*pin"), runner.locked_source(self.source, "0" * 40):
            self.fail("wrong pin accepted")
        (self.source / "tracked").write_text("changed\n")
        with self.assertRaisesRegex(ValueError, "not clean"), runner.locked_source(self.source, commit):
            self.fail("dirty source accepted")
        (self.source / "tracked").write_text("fixture\n")
        (self.source / "untracked").touch()
        with self.assertRaisesRegex(ValueError, "not clean"), runner.locked_source(self.source, commit):
            self.fail("untracked source accepted")

    def test_run_preserves_unexpected_exit_and_log(self):
        text = runner.run([sys.executable, "-c", "print('positive')"], self.root, "positive.log")
        self.assertEqual(text, "positive\n")
        runner.run([sys.executable, "-c", "raise SystemExit(1)"], self.root, "negative.log", expected=1)
        with self.assertRaisesRegex(ValueError, "unexpected exit 2"):
            runner.run([sys.executable, "-c", "print('failure'); raise SystemExit(2)"], self.root, "failure.log")
        self.assertEqual((self.root / "failure.log").read_text(), "failure\n")

    def test_atomic_publication_and_destination_preservation(self):
        publisher = Path(__file__).resolve().parents[1] / "scripts/lib/evidence.sh"
        stage = self.root / "stage"
        stage.mkdir()
        (stage / "payload").write_text("new evidence\n")
        runner.publish(stage, self.output, publisher)
        self.assertFalse(stage.exists())
        self.assertEqual((self.output / "payload").read_text(), "new evidence\n")
        self.assertEqual(self.output.stat().st_mode & 0o777, 0o500)
        self.assertEqual((self.output / "payload").stat().st_mode & 0o222, 0)
        stage.mkdir()
        (stage / "payload").write_text("must not replace\n")
        with self.assertRaises(subprocess.CalledProcessError):
            runner.publish(stage, self.output, publisher)
        self.assertEqual((self.output / "payload").read_text(), "new evidence\n")
        self.assertEqual((stage / "payload").read_text(), "must not replace\n")
        self.assertEqual(stage.stat().st_mode & 0o777, 0o700)
        self.output.chmod(0o700)  # Private fixture cleanup only.

    def test_permission_failure_cannot_publish(self):
        stage = self.root / "stage"
        stage.mkdir()
        publisher = Path(__file__).resolve().parents[1] / "scripts/lib/evidence.sh"
        with patch.object(Path, "chmod", side_effect=PermissionError("fixture")), \
                patch.object(runner.subprocess, "run") as execute, self.assertRaises(PermissionError):
            runner.publish(stage, self.output, publisher)
        execute.assert_not_called()
        self.assertFalse(self.output.exists())

    def test_behavior_summary_requires_exact_cases_and_scope(self):
        summaries = {
            "pmgr": "preliminary_fault_policy=logs_error_then_returns_final_transition_status\n"
                    "pmgr_behavior_cases=85 passed; hardware_acceptance=false",
            "dart": "dart_behavior_cases=195 passed; hardware_acceptance=false",
        }
        for kind, result in summaries.items():
            runner.validate_driver_result(kind, result + "\n")
            for bad in ("", result.replace("=85", "=84").replace("=195", "=194"), result.replace("false", "true"),
                        result + "\nunexpected", result.replace(" passed", " skipped")):
                with self.subTest(kind=kind, bad=bad), self.assertRaises(ValueError):
                    runner.validate_driver_result(kind, bad)

    def test_coverage_requires_exact_executed_function_set(self):
        names = ("apple_pmgr_ps_set", "apple_pmgr_ps_is_active", "apple_pmgr_ps_power_on", "apple_pmgr_ps_power_off",
                 "apple_pmgr_reset_assert", "apple_pmgr_reset_deassert", "apple_pmgr_reset_reset", "apple_pmgr_reset_status",
                 "apple_dart_t8020_hw_stream_command", "apple_dart_t8110_hw_tlb_command", "apple_dart_t8020_irq", "apple_dart_t8110_irq")
        rows = [f"function {name} called 1 returned 100% blocks executed 82%" for name in names]
        runner.validate_coverage(rows)
        for bad in (rows[:-1], rows + rows[:1], rows[:-1] + rows[:1],
                    [row.replace("called 1", "called 0") for row in rows],
                    [row.replace("returned 100%", "returned 0%") for row in rows],
                    [row.replace("apple_pmgr_ps_set", "apple_pmgr_unexpected") for row in rows],
                    [row.replace("executed 82%", "executed 0%") for row in rows]):
            with self.subTest(bad=bad), self.assertRaises(ValueError):
                runner.validate_coverage(bad)


if __name__ == "__main__":
    unittest.main()
