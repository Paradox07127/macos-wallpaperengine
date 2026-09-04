#!/usr/bin/env python3
"""Fail only on lint/format violations that sit on lines this change touched.

The repository is not formatter-clean: `swiftformat --lint .` reports 827 of 940
files needing changes (measured 2026-08-31). A whole-file gate would therefore
either be permanently red or force a one-shot reformat that buries semantic
diffs. This ratchets instead — new and modified lines must be clean, untouched
lines are left alone.

Usage: scripts/lint_changed_lines.py [--base REV] [--tool swiftlint|swiftformat]
"""
import argparse
import re
import shutil
import subprocess
import sys
from collections import defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
HUNK = re.compile(r"^@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@")
# Both tools emit `path:line:col: severity: message`.
VIOLATION = re.compile(r"^(?P<path>[^:]+):(?P<line>\d+):(?:\d+:)?\s*(?P<rest>.*)$")


def changed_lines(base):
    """Map each changed Swift file to the set of line numbers it added."""
    if base:
        diff_cmd = ["git", "diff", "--find-renames", "-U0", base, "--", "*.swift"]
    else:
        diff_cmd = ["git", "diff", "--find-renames", "-U0", "HEAD", "--", "*.swift"]
    diff = subprocess.run(diff_cmd, cwd=ROOT, capture_output=True, text=True).stdout

    result = defaultdict(set)
    current = None
    for line in diff.splitlines():
        if line.startswith("+++ b/"):
            current = line[6:]
        elif current and (match := HUNK.match(line)):
            start = int(match.group(1))
            count = int(match.group(2) or 1)
            result[current].update(range(start, start + count))

    # Untracked files are entirely new, so every line counts.
    untracked = subprocess.run(
        ["git", "ls-files", "--others", "--exclude-standard", "--", "*.swift"],
        cwd=ROOT, capture_output=True, text=True,
    ).stdout.split()
    for path in untracked:
        try:
            total = len((ROOT / path).read_text(encoding="utf-8").splitlines())
        except OSError:
            continue
        result[path].update(range(1, total + 1))

    return {p: lines for p, lines in result.items() if lines and (ROOT / p).exists()}


# Exit codes that mean "ran, and here is the verdict". Anything else is the tool
# itself failing — a bad config or an internal crash — and must not be read as a
# clean bill of health: its output would not match VIOLATION either, so without
# this check a broken linter reports zero violations and the gate passes.
TOOL_ARGV = {
    # Avoid writing SwiftLint's global cache: the gate is deterministic without
    # it and also runs in read-only homes on CI and in sandboxed worktrees.
    "swiftlint": (["lint", "--quiet", "--no-cache"], {0, 2, 3}),
    "swiftformat": (["--lint"], {0, 1}),
}


def run_tool(tool, paths):
    if not shutil.which(tool):
        print(f"note: {tool} not installed; skipping that half of the gate")
        return []
    flags, expected = TOOL_ARGV[tool]
    argv = [tool] + flags + [str(ROOT / p) for p in paths]
    proc = subprocess.run(argv, cwd=ROOT, capture_output=True, text=True)
    output = (proc.stdout + proc.stderr).splitlines()
    if proc.returncode not in expected:
        for line in output:
            print(line, file=sys.stderr)
        raise SystemExit(
            f"{tool} exited {proc.returncode}, which is not a lint verdict; "
            "treating the gate as failed rather than clean"
        )
    return output


def violations_on_changed_lines(tool, files):
    findings = []
    for raw in run_tool(tool, sorted(files)):
        match = VIOLATION.match(raw.strip())
        if not match:
            continue
        try:
            path = str(Path(match.group("path")).resolve().relative_to(ROOT))
        except ValueError:
            continue
        if int(match.group("line")) in files.get(path, ()):
            findings.append(f"{path}:{match.group('line')}: {match.group('rest')}")
    return findings


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--base", default=None, help="revision to diff against (default: HEAD)")
    parser.add_argument("--tool", choices=["swiftlint", "swiftformat"], action="append")
    args = parser.parse_args()

    files = changed_lines(args.base)
    if not files:
        print("No changed Swift lines to lint.")
        return 0

    findings = []
    for tool in args.tool or ["swiftlint", "swiftformat"]:
        findings += violations_on_changed_lines(tool, files)

    print(f"Changed-line lint: {len(files)} Swift file(s), {len(findings)} violation(s) on touched lines")
    for finding in findings:
        print(f"  ! {finding}")
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main())
