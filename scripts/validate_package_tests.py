#!/usr/bin/env python3
"""Validate actual SwiftPM xUnit cases, rather than the skipped-inclusive log total."""

from pathlib import Path
import sys
import xml.etree.ElementTree as ET


def validate(path: Path) -> tuple[int, list[str]]:
    root = ET.parse(path).getroot()
    cases = list(root.iter("testcase"))
    errors = []
    if not cases:
        errors.append("no test cases in package result")
    for case in cases:
        identifier = f"{case.get('classname', '')}/{case.get('name', '')}"
        if any(case.find(result) is not None for result in ("failure", "error", "skipped")):
            errors.append(f"case did not pass: {identifier}")
    return len(cases), errors


def main() -> int:
    path = Path(sys.argv[1])
    try:
        count, errors = validate(path)
    except (OSError, ET.ParseError) as error:
        count, errors = 0, [f"cannot read package execution evidence: {error}"]
    print(f"Package result: {path} — {count} cases; {'FAILED' if errors else 'passed'}")
    for error in errors:
        print(f"ERROR: {error}", file=sys.stderr)
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
