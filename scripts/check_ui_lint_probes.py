#!/usr/bin/env python3
"""Exercise UI guards through SwiftLint, including allowed glyph/token forms.

This uses the checked-in custom rules in an isolated temporary directory; no
whole-repository lint or compilation of deliberately invalid examples is needed.
"""
import re
import shutil
import subprocess
import tempfile
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PROBE = """import SwiftUI
let bare = Text("Bare").font(.caption)
let chainedBare = Text("Metric").font(.caption.monospacedDigit())
let textSize = Text("Text").font(.system(size: 11))
let labelSize = Label("Action", systemImage: "plus")
    .foregroundStyle(DesignTokens.Colors.textPrimary)
    .font(.system(size: 12))
let radius = RoundedRectangle(cornerRadius: 12)
let shaped = view.adaptiveGlassSurface(.roundedRectangle(12))
let modifier = view.cornerRadius(12)
let glyph = Image(systemName: "plus").font(.system(size: 12))
let semantic = Text("Body").font(DesignTokens.Typography.body)
let metric = Text("10").font(DesignTokens.Typography.metric)
let sharedShape = view.adaptiveGlassSurface(.roundedRectangle(DesignTokens.Corner.panel))
let sharedRadius = RoundedRectangle(cornerRadius: DesignTokens.Corner.panel)
// Text("Comment").font(.caption)
let documentation = "Text(\\"String\\").font(.caption)"
"""
EXPECTED = Counter({
    "token_bypass_bare_font": 2,
    "token_bypass_text_point_size": 2,
    "token_bypass_literal_corner_radius": 3,
})


def main():
    if not shutil.which("swiftlint"):
        raise SystemExit("SwiftLint is required to verify UI lint probes")
    config = (ROOT / ".swiftlint.yml").read_text()
    custom = "custom_rules:" + config.split("custom_rules:", 1)[1]
    with tempfile.TemporaryDirectory(prefix="lw-ui-lint-probes-") as folder:
        directory = Path(folder)
        path = directory / "StyleGuardProbe.swift"
        path.write_text(PROBE)
        probe_config = directory / "probe.yml"
        probe_config.write_text("only_rules:\n  - custom_rules\n" + custom)
        result = subprocess.run(
            ["swiftlint", "lint", "--quiet", "--no-cache", "--config", str(probe_config), str(path)],
            cwd=directory, capture_output=True, text=True,
        )
    if result.returncode not in {0, 2, 3}:
        raise SystemExit(result.stdout + result.stderr)
    found = Counter(re.findall(r"\((token_bypass_[a-z_]+)\)\s*$", result.stdout, re.MULTILINE))
    if found != EXPECTED:
        print(result.stdout + result.stderr)
        raise SystemExit(f"UI lint probes failed: expected {dict(EXPECTED)}, got {dict(found)}")
    print("UI lint probes passed: bare fonts, text point sizes and radii caught; glyphs, tokens, comments and strings allowed")


if __name__ == "__main__":
    main()
