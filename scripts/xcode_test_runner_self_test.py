#!/usr/bin/env python3
"""Unit tests for the structured Xcode test reporter."""

from __future__ import annotations

from contextlib import redirect_stderr, redirect_stdout
import io
import os
import re
import shlex
import subprocess
from pathlib import Path
import sys
import tempfile
import types
import unittest
from unittest import mock

import xcode_test_runner as runner


PASSING_SUMMARY = {
    "result": "Passed",
    "totalTestCount": 3,
    "passedTests": 3,
    "failedTests": 0,
    "skippedTests": 0,
}


def run_main(required_suite: str, present_suite: str, result: str = "Passed",
             allow_skipped: bool = False) -> int:
    """Drive main() end to end with xcodebuild stubbed out as a clean pass.

    Guards the exit code itself, not just the helpers: a required suite that
    never appears in the xcresult must not exit 0, or `-only-testing` with a
    misspelled suite name reports success having run none of those tests.
    """
    tests_report = {
        "testNodes": [
            {
                "children": [
                    {
                        "nodeType": "Test Case",
                        "nodeIdentifier": f"{present_suite}/onlyTest()",
                        "durationInSeconds": 0.1,
                        "result": result,
                    }
                ]
            }
        ]
    }
    with tempfile.TemporaryDirectory() as directory:
        bundle = Path(directory) / "run.xcresult"
        argv = [
            "xcode_test_runner.py",
            "--label", "self-test",
            "--result-bundle", str(bundle),
            "--minimum-test-count", "1",
            "--require-suite", required_suite,
            "--", "test",
        ]
        if allow_skipped:
            argv[1:1] = ["--allow-skipped-suite", required_suite]
        with mock.patch.object(sys, "argv", argv), mock.patch.object(
            runner.subprocess,
            "run",
            return_value=types.SimpleNamespace(returncode=0),
        ), mock.patch.object(
            runner,
            "xcresult_json",
            side_effect=lambda _bundle, report: (
                PASSING_SUMMARY if report == "summary" else tests_report
            ),
        ), redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()):
            return runner.main()


class XcodeTestRunnerTests(unittest.TestCase):
    def setUp(self) -> None:
        self.summary = {
            "result": "Passed",
            "totalTestCount": 3,
            "passedTests": 3,
            "failedTests": 0,
            "skippedTests": 0,
        }
        self.tests = {
            "testNodes": [
                {
                    "children": [
                        {
                            "nodeType": "Test Case",
                            "nodeIdentifier": "RequiredSuite/fastTest()",
                            "durationInSeconds": 0.1,
                            "result": "Passed",
                        },
                        {
                            "nodeType": "Test Case",
                            "nodeIdentifier": "RequiredSuite/slowTest()",
                            "durationInSeconds": 1.5,
                            "result": "Passed",
                        },
                    ]
                }
            ]
        }

    def test_valid_summary_and_required_suite_pass(self) -> None:
        self.assertEqual(runner.validate_summary(self.summary, 3), [])
        self.assertEqual(
            runner.required_suites_missing(self.tests, ["RequiredSuite"]), []
        )

    def test_zero_or_incomplete_run_fails(self) -> None:
        self.assertIn("below required minimum", runner.validate_summary(self.summary, 4)[0])
        self.assertEqual(
            runner.required_suites_missing(self.tests, ["MissingSuite"]),
            ["MissingSuite"],
        )

    def test_failed_result_fails_even_with_a_nonzero_count(self) -> None:
        failed = dict(self.summary, result="Failed", failedTests=1)
        errors = runner.validate_summary(failed, 1)
        self.assertEqual(len(errors), 2)

    def test_skipped_cases_do_not_satisfy_minimum(self) -> None:
        summary = dict(self.summary, totalTestCount=2400, passedTests=2300, skippedTests=100)
        self.assertTrue(runner.validate_summary(summary, 2400))

    def test_missing_passed_count_is_not_execution_evidence(self) -> None:
        summary = dict(self.summary)
        del summary["passedTests"]
        self.assertTrue(runner.validate_summary(summary, 1))

    def test_required_suite_needs_a_passed_case(self) -> None:
        tests = {"testNodes": [{"nodeType": "Test Case", "nodeIdentifier": "RequiredSuite/test()"}]}
        self.assertEqual(runner.required_suites_without_passes(tests, ["RequiredSuite"]), ["RequiredSuite"])
        tests["testNodes"][0]["result"] = "Skipped"
        self.assertEqual(runner.required_suites_without_passes(tests, ["RequiredSuite"]), ["RequiredSuite"])
        tests["testNodes"].append({"nodeType": "Test Case", "nodeIdentifier": "RequiredSuite/other()",
                                   "result": "Passed"})
        self.assertEqual(runner.required_suites_without_passes(tests, ["RequiredSuite"]), [])

    def test_parameterized_case_can_prove_execution_through_its_run(self) -> None:
        tests = {"testNodes": [{"nodeType": "Test Case", "nodeIdentifier": "RequiredSuite/test()",
                                "children": [{"nodeType": "Test Case Run", "result": "Passed"}]}]}
        self.assertEqual(runner.required_suites_without_passes(tests, ["RequiredSuite"]), [])

    def test_skip_exception_does_not_allow_unknown_results(self) -> None:
        tests = {"testNodes": [{"nodeType": "Test Case", "nodeIdentifier": "RequiredSuite/test()"}]}
        self.assertEqual(runner.required_suites_without_passes(
            tests, ["RequiredSuite"], ["RequiredSuite"]), ["RequiredSuite"])

    def test_skip_policy_controls_the_exit_code(self) -> None:
        self.assertNotEqual(run_main("RequiredSuite", "RequiredSuite", "Skipped"), 0)
        self.assertEqual(run_main("RequiredSuite", "RequiredSuite", "Skipped", True), 0)
        self.assertNotEqual(run_main("RequiredSuite", "RequiredSuite", "unknown", True), 0)
        self.assertNotEqual(run_main("RequiredSuite", "OtherSuite", "Skipped", True), 0)

    def test_slowest_tests_are_sorted(self) -> None:
        self.assertEqual(
            runner.slowest_tests(self.tests, 1),
            [(1.5, "RequiredSuite/slowTest()")],
        )

    def test_missing_required_suite_exits_nonzero(self) -> None:
        self.assertNotEqual(
            run_main("WallpaperArchitectureTests", "InfrastructureRuntimeBoundaryTests"),
            0,
        )

    def test_present_required_suite_exits_zero(self) -> None:
        self.assertEqual(
            run_main("InfrastructureRuntimeBoundaryTests", "InfrastructureRuntimeBoundaryTests"),
            0,
        )

    def test_failure_excerpt_includes_nearby_assertion_context(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory) / "test.log"
            log.write_text(
                "unrelated\nsetup\nExpectation failed: value was 2\n"
                "at ExampleTests.swift:42\nteardown\nunrelated tail\n",
                encoding="utf-8",
            )
            excerpt = runner.failure_excerpt(log)
        self.assertIn("setup", excerpt)
        self.assertIn("Expectation failed: value was 2", excerpt)
        self.assertIn("at ExampleTests.swift:42", excerpt)


ROOT = Path(__file__).resolve().parent.parent


class ReviewGateTests(unittest.TestCase):
    def run_package_gate(self, core: int, wpe: int, summary: str = "passed"):
        with tempfile.TemporaryDirectory(prefix="loomscreen-gate-test-") as temporary:
            scratch = Path(temporary)
            fake = scratch / "swift"
            fake.write_text('''#!/usr/bin/env bash
case "$*" in
  *LiveWallpaperProWPE*) label=ProWPE; code="$PROBE_WPE_EXIT" ;;
  *LiveWallpaperCore*) label=Core; code="$PROBE_CORE_EXIT" ;;
  *) exit 99 ;;
esac
echo "$label" >> "$PROBE_CALLS"
case "$PROBE_SUMMARY" in
  passed) echo 'Test run with 3 tests in 1 suite passed after 0.1 seconds.' ;;
  zero) echo 'Test run with 0 tests passed after 0.1 seconds.' ;;
  skipped) echo 'Test run with 3 tests skipped after 0.1 seconds.' ;;
esac
exit "$code"
''')
            fake.chmod(0o755)
            calls = scratch / "calls"
            environment = dict(os.environ, PATH=f"{scratch}:{os.environ['PATH']}",
                               PROBE_CORE_EXIT=str(core), PROBE_WPE_EXIT=str(wpe),
                               PROBE_SUMMARY=summary, PROBE_CALLS=str(calls))
            result = subprocess.run(
                ["/usr/bin/make", "test-packages", f"SWIFTPM_SCRATCH={scratch / 'products'}"],
                cwd=ROOT, env=environment, text=True, capture_output=True, timeout=20,
            )
            return result, calls.read_text().splitlines() if calls.exists() else []

    def test_each_package_failure_stops_the_gate(self):
        for core, wpe, expected in [(42, 0, ["Core"]), (0, 43, ["Core", "ProWPE"]),
                                     (42, 43, ["Core"])]:
            with self.subTest(core=core, wpe=wpe):
                result, calls = self.run_package_gate(core, wpe)
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertEqual(calls, expected)

    def test_package_success_requires_nonzero_passed_summary(self):
        for summary in ["missing", "zero", "skipped"]:
            with self.subTest(summary=summary):
                result, calls = self.run_package_gate(0, 0, summary)
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertEqual(calls, ["Core"])

    def test_two_real_package_summaries_pass(self):
        result, calls = self.run_package_gate(0, 0)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls, ["Core", "ProWPE"])

    def test_full_command_requires_security_suites(self):
        command = self.app_command("full")
        required = [command[index + 1] for index, value in enumerate(command)
                    if value == "--require-suite"]
        self.assertIn("EntitlementAuditTests", required)
        self.assertIn("HTMLTrustVerdictTests", required)
        self.assertIn("ScreenRuntimeOwnershipTests", required)
        self.assertIn("WPESceneScriptB2bResourceLimitTests", required)
        self.assertFalse(any(arg.startswith("-only-testing:") for arg in command))
        self.assertNotIn("--allow-skipped-suite", command)

    def app_command(self, *arguments):
        result = subprocess.run(["bash", "scripts/app_tests.sh", *arguments, "--dry-run"],
                                cwd=ROOT, capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        return shlex.split(result.stdout)

    def test_hosted_full_keeps_runner_and_entitlements(self):
        command = self.app_command("full", "--hosted")
        self.assertIn("scripts/xcode_test_runner.py", command)
        self.assertIn("CODE_SIGN_IDENTITY=-", command)
        self.assertIn("CODE_SIGN_STYLE=Manual", command)
        self.assertNotIn("CODE_SIGNING_ALLOWED=NO", command)
        self.assertIn("--require-suite", command)
        self.assertNotIn("CODE_SIGN_IDENTITY=-", self.app_command("full"))

    def test_ci_full_uses_the_checked_hosted_entry_point(self):
        workflow = (ROOT / ".github/workflows/ci.yml").read_text()
        full_job = workflow.split("\n  app-tests:", 1)[1]
        self.assertIn("scripts/app_tests.sh full --hosted", full_job)
        self.assertNotIn("xcodebuild test", full_job)

    def test_lite_archive_requires_both_slices(self):
        source = (ROOT / "scripts/release_candidate_check.sh").read_text()
        function = re.search(r"^(assert_(?:contains_arm64|universal_binary))\(\) \{\n.*?^\}",
                             source, re.M | re.S)
        self.assertIsNotNone(function)
        for archs, should_pass in [("arm64", False), ("x86_64", False),
                                   ("arm64 x86_64", True), ("x86_64 arm64", True),
                                   ("arm64 x86_64 arm64e", False), ("", False)]:
            with self.subTest(archs=archs):
                # Source only this pure assertion; lipo never runs.
                program = ('set -euo pipefail\nlipo() { printf "%s\\n" "$PROBE_ARCHS"; }\n'
                           + function.group(0) + f'\n{function.group(1)} fixture Lite\n')
                result = subprocess.run(["bash", "-c", program], text=True, capture_output=True,
                                        env=dict(os.environ, PROBE_ARCHS=archs), timeout=10)
                self.assertEqual(result.returncode == 0, should_pass, result.stdout + result.stderr)

    def test_pro_archive_contract_does_not_read_lite_block(self):
        source = (ROOT / "scripts/release_contract_check.sh").read_text()
        assignment = next(line for line in source.splitlines() if line.startswith("pro_release_block="))
        program = 'candidate_script=scripts/release_candidate_check.sh\n' + assignment
        program += '\nprintf "%s\\n" "$pro_release_block"\n'
        result = subprocess.run(["bash", "-c", program], cwd=ROOT, text=True,
                                capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("PRO_ARCHIVE_PATH", result.stdout)
        self.assertNotIn("Lite", result.stdout)


if __name__ == "__main__":
    unittest.main()
