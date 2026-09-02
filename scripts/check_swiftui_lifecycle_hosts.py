#!/usr/bin/env python3
"""Reject `.task`/`.onAppear` attached to a `Group` that can render empty.

SwiftUI applies a modifier chained onto a `Group { if … }` with no `else` to the
`EmptyView` the false branch produces, and an EmptyView has no representation in
the render tree — so the modifier never runs. The failure is silent: the view
simply never loads its data, forever.

Measured on macOS 26 (2026-09-01) with two views differing only in their
container: `Group` never fired its `.task`, `VStack` did. `SceneSettingsShelf`
shipped that bug — its `schema` starts nil, so the Group was empty on first
render and the schema load never ran.

`--self-test` runs the detector against a violating and a legal fixture.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

LIFECYCLE = re.compile(r"^\.(task|onAppear|onDisappear|refreshable)\b")
GROUP_OPEN = re.compile(r"(^|[^\w.]|SwiftUI\.)Group\s*\{\s*(//.*)?$")
# A bare `else {` closes the chain; `else if` is one more branch of it, and a
# chain that ends on `else if` can still fall through to nothing.
ELSE = re.compile(r"(^|\})\s*else\s*\{")
ELSE_IF = re.compile(r"(^|\})\s*else\s+if\b")
BRANCHING = re.compile(r"^\s*(if|switch)\b")

# `switch` over a Swift enum is exhaustive by compiler rule, so it always yields
# a view; only `if` without `else` can fall through to nothing. Only the Group's
# OWN branches count — an `else` belonging to a nested `if` says nothing about
# whether the Group itself can render empty (the first version of this check
# missed the very bug it was written for that way).
def group_can_be_empty(body: list[str]) -> bool:
    depth = 0
    has_branch = False
    has_fallback = False
    for raw in body:
        stripped = raw.strip()
        lead_close = len(stripped) - len(stripped.lstrip("}"))
        level = depth - lead_close
        if level == 0:
            if stripped.lstrip("} ").startswith("switch "):
                return False
            if ELSE.search(stripped):
                has_fallback = True
            elif ELSE_IF.search(stripped) or BRANCHING.match(raw):
                has_branch = True
        depth += raw.count("{") - raw.count("}")
    return has_branch and not has_fallback


def chained_modifiers(lines: list[str], close_index: int) -> list[str]:
    """Modifier lines chained directly onto the closing brace at `close_index`."""
    out: list[str] = []
    depth = 0
    for raw in lines[close_index + 1:]:
        stripped = raw.strip()
        if depth == 0:
            if not stripped.startswith("."):
                break
            out.append(stripped)
        depth += raw.count("(") + raw.count("{") - raw.count(")") - raw.count("}")
        if depth < 0:
            break
    return out


def scan_text(text: str, name: str) -> list[str]:
    lines = text.splitlines()
    findings: list[str] = []
    for i, line in enumerate(lines):
        if not GROUP_OPEN.search(line):
            continue
        depth = 0
        close = None
        for j in range(i, len(lines)):
            depth += lines[j].count("{") - lines[j].count("}")
            if depth <= 0 and j > i:
                close = j
                break
        if close is None:
            continue
        if not group_can_be_empty(lines[i + 1:close]):
            continue
        for modifier in chained_modifiers(lines, close):
            if LIFECYCLE.match(modifier):
                findings.append(
                    f"{name}:{i + 1}: `{modifier.split('(')[0]}` is attached to a Group "
                    "whose `if` has no `else`; it never fires when the branch is false. "
                    "Use a VStack (or give the conditional an else)."
                )
    return findings


VIOLATION_FIXTURE = """
struct Bad: View {
    @State private var schema: Int?
    var body: some View {
        Group {
            if let schema {
                Text("\\(schema)")
            }
        }
        .task { schema = 1 }
    }
}

struct BadElseIfChain: View {
    @State private var a = false
    @State private var b = false
    var body: some View {
        Group {
            if a {
                Text("a")
            } else if b {
                Text("b")
            }
        }
        .task { a = true }
    }
}

struct BadQualifiedName: View {
    @State private var schema: Int?
    var body: some View {
        SwiftUI.Group {
            if let schema {
                Text("\\(schema)")
            }
        }
        .onAppear { schema = 1 }
    }
}

struct BadTrailingComment: View {
    @State private var schema: Int?
    var body: some View {
        Group { // one of the branches
            if let schema {
                Text("\\(schema)")
            }
        }
        .task { schema = 1 }
    }
}
"""
VIOLATION_FIXTURE_COUNT = 4

LEGAL_FIXTURE = """
struct GoodContainer: View {
    @State private var schema: Int?
    var body: some View {
        VStack(spacing: 0) {
            if let schema {
                Text("\\(schema)")
            }
        }
        .task { schema = 1 }
    }
}

struct GoodExhaustive: View {
    @State private var schema: Int?
    var body: some View {
        Group {
            if let schema {
                Text("\\(schema)")
            } else {
                ProgressView()
            }
        }
        .task { schema = 1 }
    }
}

struct GoodElseIfChainClosed: View {
    @State private var a = false
    @State private var b = false
    var body: some View {
        Group {
            if a {
                Text("a")
            } else if b {
                Text("b")
            } else {
                ProgressView()
            }
        }
        .task { a = true }
    }
}

struct GoodNoLifecycle: View {
    @State private var schema: Int?
    var body: some View {
        Group {
            if let schema {
                Text("\\(schema)")
            }
        }
        .padding(8)
    }
}
"""


def self_test() -> int:
    bad = scan_text(VIOLATION_FIXTURE, "fixture-bad.swift")
    good = scan_text(LEGAL_FIXTURE, "fixture-good.swift")
    ok = True
    if len(bad) != VIOLATION_FIXTURE_COUNT:
        print(f"SELF-TEST FAIL: violating fixture produced {len(bad)} findings, expected {VIOLATION_FIXTURE_COUNT}: {bad}", file=sys.stderr)
        ok = False
    if good:
        print(f"SELF-TEST FAIL: legal fixture produced findings: {good}", file=sys.stderr)
        ok = False
    print("SwiftUI lifecycle-host self-test passed." if ok else "SwiftUI lifecycle-host self-test FAILED.")
    return 0 if ok else 1


def main() -> int:
    if "--self-test" in sys.argv:
        return self_test()

    root = Path(__file__).resolve().parent.parent
    findings: list[str] = []
    for directory in ("LiveWallpaper", "Packages"):
        for path in sorted((root / directory).rglob("*.swift")):
            findings.extend(scan_text(path.read_text(encoding="utf-8"), str(path.relative_to(root))))

    if findings:
        print("ERROR: lifecycle modifier attached to a possibly-empty Group:", file=sys.stderr)
        for finding in findings:
            print(f"  {finding}", file=sys.stderr)
        return 1
    print("SwiftUI lifecycle hosts: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
