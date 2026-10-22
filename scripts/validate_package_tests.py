#!/usr/bin/env python3
"""Validate actual SwiftPM xUnit cases, rather than the skipped-inclusive log total."""

import argparse
from pathlib import Path
import re
import sys
import xml.etree.ElementTree as ET


def validate(path: Path, required_suite: str | None = None) -> tuple[int, list[str]]:
    root = ET.parse(path).getroot()
    cases = list(root.iter("testcase"))
    errors = []
    if not cases:
        errors.append("no test cases in package result")
    if required_suite and not any(case.get("classname", "").split(".")[-1] == required_suite for case in cases):
        errors.append(f"required package suite did not execute: {required_suite}")
    for case in cases:
        identifier = f"{case.get('classname', '')}/{case.get('name', '')}"
        if any(case.find(result) is not None for result in ("failure", "error", "skipped")):
            errors.append(f"case did not pass: {identifier}")
    return len(cases), errors


def validate_xctest_log(path: Path) -> tuple[int, list[str]]:
    """SwiftPM emits XML for Swift Testing only; inspect XCTest's actual case outcomes too."""
    log = path.read_text()
    cases = re.findall(r"^Test Case '(.+)' (passed|failed|skipped) \(", log, re.MULTILINE)
    started = re.findall(r"^Test Case '(.+)' started\.$", log, re.MULTILINE)
    errors = [f"XCTest case did not pass: {name}" for name, status in cases if status != "passed"]
    if sorted(started) != sorted(name for name, _ in cases):
        errors.append("XCTest case execution evidence is incomplete")
    # Packages consisting solely of Swift Testing legitimately have no XCTest cases.
    if not re.search(r"^Test Suite 'All tests' passed at .+\n\s*Executed \d+ tests?, "
                     r"with 0 failures \(0 unexpected\)", log, re.MULTILINE):
        errors.append("XCTest did not finish with zero failures and zero skips")
    return len(cases), errors


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("path", type=Path)
    parser.add_argument("--xctest-log", type=Path)
    parser.add_argument("--require-suite")
    args = parser.parse_args()
    path = args.path
    try:
        count, errors = validate(path, args.require_suite)
        if args.xctest_log:
            native_count, native_errors = validate_xctest_log(args.xctest_log)
            count += native_count
            errors.extend(native_errors)
    except (OSError, ET.ParseError) as error:
        count, errors = 0, [f"cannot read package execution evidence: {error}"]
    print(f"Package result: {path} — {count} cases; {'FAILED' if errors else 'passed'}")
    for error in errors:
        print(f"ERROR: {error}", file=sys.stderr)
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
