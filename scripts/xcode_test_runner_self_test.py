#!/usr/bin/env python3
"""Unit tests for the structured Xcode test reporter."""

from __future__ import annotations

from contextlib import redirect_stderr, redirect_stdout
import io
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


def run_main(required_suite: str, present_suite: str) -> int:
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
                        },
                        {
                            "nodeType": "Test Case",
                            "nodeIdentifier": "RequiredSuite/slowTest()",
                            "durationInSeconds": 1.5,
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


if __name__ == "__main__":
    unittest.main()
