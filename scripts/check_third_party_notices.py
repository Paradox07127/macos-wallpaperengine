#!/usr/bin/env python3
"""Fail when a bundled third-party library has no notice in ThirdPartyNotices/manifest.tsv.

Static mode (default) checks the repository: every vendored license directory, Swift package
pin and pinned toolchain library maps to a manifest row whose notice sources exist and are
copied into the right SKU. `--app <bundle> --sku pro|lite` checks a built bundle.

Usage: scripts/check_third_party_notices.py [--self-test | --app BUNDLE --sku pro|lite]
"""
import argparse
import fnmatch
import json
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MANIFEST = ROOT / "ThirdPartyNotices/manifest.tsv"
PACKAGE_RESOLVED = ROOT / "LiveWallpaper.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
TOOLCHAIN_PINS = ROOT / "WPEShaderCompiler/toolchain-inputs.sha256"
EMBED_SCRIPT = ROOT / "WPEShaderCompiler/embed-in-app.sh"
COLUMNS = ["id", "skus", "version", "upstream_url", "sources", "bundle_dir"]
LICENSE_PATTERNS = ("LICENSE*", "COPYING*", "FTL.TXT")
TOOLCHAIN_PREFIX = "toolchain:"
# Binary name (toolchain lib/ pin or Contents/Frameworks entry) -> manifest id.
LIBRARY_IDS = {
    "Sparkle.framework": "sparkle",
    "libdxcompiler.dylib": "dxc",
    "libmetalirconverter.dylib": "msc",
}


def gap(library):
    return f"ERROR: bundled library {library} has no third-party notice"


def parse_manifest(text):
    lines = [line for line in text.splitlines() if line and not line.startswith("#")]
    if not lines or lines[0].split("\t") != COLUMNS:
        raise ValueError(f"manifest header must be {COLUMNS}")
    rows = []
    for line in lines[1:]:
        values = line.split("\t")
        if len(values) != len(COLUMNS):
            raise ValueError(f"manifest row needs {len(COLUMNS)} columns: {line}")
        row = dict(zip(COLUMNS, values))
        row["skus"] = set(row["skus"].split(","))
        notices = []
        for entry in row["sources"].split(","):
            name, _, source = entry.rpartition("=")
            notices.append((name or source.rsplit("/", 1)[-1], source))
        row["notices"] = notices
        rows.append(row)
    return rows


def check_static(rows, tracked, identities, pinned, embed_text):
    errors = []
    ids = {row["id"] for row in rows}
    repo_sources = {source for row in rows for _, source in row["notices"]}
    for path in sorted(tracked):
        parts = path.split("/")
        in_sources = len(parts) > 3 and parts[0] == "Packages" and parts[2] == "Sources"
        if in_sources and any(fnmatch.fnmatchcase(parts[-1], p) for p in LICENSE_PATTERNS):
            if path not in repo_sources:
                errors.append(gap(path.rsplit("/", 1)[0]))
    for identity in sorted(identities):
        if identity not in ids:
            errors.append(gap(identity))
    for pin in sorted(pinned):
        if pin.startswith("lib/") and pin.endswith(".dylib"):
            library = pin[len("lib/"):]
            if LIBRARY_IDS.get(library) not in ids:
                errors.append(gap(library))

    embed_lines = [line.split() for line in embed_text.splitlines()]
    notice_files = next((line for line in embed_text.splitlines() if line.startswith("NOTICE_FILES=(")), "")
    notice_names = notice_files.removeprefix("NOTICE_FILES=(").removesuffix(")").split()
    for row in rows:
        lite = "lite" in row["skus"]
        for name, source in row["notices"]:
            if source.startswith(TOOLCHAIN_PREFIX):
                toolchain_path = source[len(TOOLCHAIN_PREFIX):]
                if toolchain_path not in pinned:
                    errors.append(f"ERROR: {row['id']} notice {toolchain_path} is not pinned in {TOOLCHAIN_PINS.name}")
                copied = name in notice_names
            else:
                if source not in tracked:
                    errors.append(f"ERROR: {row['id']} notice {source} is not git-tracked")
                copied = [source, name] in embed_lines
            if lite:
                if source.startswith(TOOLCHAIN_PREFIX) or not source.startswith("LiveWallpaper/"):
                    errors.append(f"ERROR: Lite notice {source} for {row['id']} must live under LiveWallpaper/")
            elif not copied:
                errors.append(f"ERROR: Pro-only notice {name} for {row['id']} is not copied by {EMBED_SCRIPT.name}")
    return errors


def check_app(rows, sku, frameworks, present):
    """`present` holds bundle-relative file paths such as Contents/Resources/x."""
    errors = []
    sku_ids = {row["id"] for row in rows if sku in row["skus"]}
    for entry in sorted(frameworks):
        if LIBRARY_IDS.get(entry) not in sku_ids:
            errors.append(gap(entry))
    for row in rows:
        for name, _ in row["notices"]:
            path = f"{row['bundle_dir']}/{name}"
            if sku in row["skus"] and path not in present:
                errors.append(gap(row["id"]) + f" ({path} is missing)")
            if sku == "lite" and "lite" not in row["skus"] and path in present:
                errors.append(f"ERROR: Lite bundle carries Pro-only notice {path}")
    return errors


def load_static_inputs():
    tracked = set(subprocess.run(["git", "ls-files"], cwd=ROOT, check=True, capture_output=True,
                                 text=True).stdout.splitlines())
    identities = {pin["identity"] for pin in json.loads(PACKAGE_RESOLVED.read_text())["pins"]}
    pinned = {line.split(None, 1)[1].strip() for line in TOOLCHAIN_PINS.read_text().splitlines() if line.strip()}
    return tracked, identities, pinned, EMBED_SCRIPT.read_text()


def load_app_inputs(app):
    frameworks_dir = app / "Contents/Frameworks"
    frameworks = [p.name for p in frameworks_dir.iterdir()] if frameworks_dir.is_dir() else []
    present = {str(p.relative_to(app)) for p in (app / "Contents/Resources").rglob("*") if p.is_file()}
    return frameworks, present


def self_test():
    rows = parse_manifest(
        "\t".join(COLUMNS) + "\n"
        "sparkle\tpro,lite\t1\tu\tLiveWallpaper/Resources/Sparkle-LICENSE.txt\tContents/Resources\n"
        "zlib\tpro\t1\tu\tZlib-LICENSE=Packages/P/Sources/CZ/LICENSE\tContents/Resources/ThirdPartyNotices\n"
        "dxc\tpro\t1\tu\ttoolchain:licenses/DXC-LICENSE.TXT\tContents/Resources/WPEShaderCompilerNotices\n")
    tracked = {"LiveWallpaper/Resources/Sparkle-LICENSE.txt", "Packages/P/Sources/CZ/LICENSE"}
    pinned = {"lib/libdxcompiler.dylib", "licenses/DXC-LICENSE.TXT"}
    embed = "NOTICE_FILES=(DXC-LICENSE.TXT)\nPackages/P/Sources/CZ/LICENSE Zlib-LICENSE\n"
    pro_files = {"Contents/Resources/Sparkle-LICENSE.txt", "Contents/Resources/ThirdPartyNotices/Zlib-LICENSE",
                 "Contents/Resources/WPEShaderCompilerNotices/DXC-LICENSE.TXT"}
    lite_files = {"Contents/Resources/Sparkle-LICENSE.txt"}
    pro_frameworks = ["Sparkle.framework", "libdxcompiler.dylib"]
    probes = [
        ("control static", check_static(rows, tracked, {"sparkle"}, pinned, embed), None),
        ("control pro app", check_app(rows, "pro", pro_frameworks, pro_files), None),
        ("control lite app", check_app(rows, "lite", ["Sparkle.framework"], lite_files), None),
        ("untracked vendored license",
         check_static(rows, tracked | {"Packages/P/Sources/CFoo/LICENSE"}, {"sparkle"}, pinned, embed),
         gap("Packages/P/Sources/CFoo")),
        ("unknown package pin", check_static(rows, tracked, {"sparkle", "yams"}, pinned, embed), gap("yams")),
        ("unknown toolchain dylib",
         check_static(rows, tracked, {"sparkle"}, pinned | {"lib/libfoo.dylib"}, embed), gap("libfoo.dylib")),
        ("notice source not tracked", check_static(rows, tracked - {"Packages/P/Sources/CZ/LICENSE"},
                                                   {"sparkle"}, pinned, embed),
         "ERROR: zlib notice Packages/P/Sources/CZ/LICENSE is not git-tracked"),
        ("toolchain notice not pinned",
         check_static(rows, tracked, {"sparkle"}, pinned - {"licenses/DXC-LICENSE.TXT"}, embed),
         "ERROR: dxc notice licenses/DXC-LICENSE.TXT is not pinned in toolchain-inputs.sha256"),
        ("toolchain notice not copied",
         check_static(rows, tracked, {"sparkle"}, pinned, embed.replace("DXC-LICENSE.TXT", "")),
         "ERROR: Pro-only notice DXC-LICENSE.TXT for dxc is not copied by embed-in-app.sh"),
        ("repo notice not copied",
         check_static(rows, tracked, {"sparkle"}, pinned, embed.replace(" Zlib-LICENSE", " Other")),
         "ERROR: Pro-only notice Zlib-LICENSE for zlib is not copied by embed-in-app.sh"),
        ("unmapped framework", check_app(rows, "pro", pro_frameworks + ["Foo.framework"], pro_files),
         gap("Foo.framework")),
        ("missing notice in app",
         check_app(rows, "pro", pro_frameworks, pro_files - {"Contents/Resources/ThirdPartyNotices/Zlib-LICENSE"}),
         gap("zlib") + " (Contents/Resources/ThirdPartyNotices/Zlib-LICENSE is missing)"),
        ("pro framework in lite", check_app(rows, "lite", pro_frameworks, lite_files), gap("libdxcompiler.dylib")),
        ("pro notice in lite", check_app(rows, "lite", ["Sparkle.framework"], pro_files),
         "ERROR: Lite bundle carries Pro-only notice Contents/Resources/ThirdPartyNotices/Zlib-LICENSE"),
    ]
    lite_row = parse_manifest("\t".join(COLUMNS) + "\nx\tlite\t1\tu\tPackages/P/Sources/CZ/LICENSE\tContents/Resources\n")
    probes.append(("lite notice outside LiveWallpaper/", check_static(lite_row, tracked, set(), set(), ""),
                   "ERROR: Lite notice Packages/P/Sources/CZ/LICENSE for x must live under LiveWallpaper/"))
    failures = 0
    for label, errors, expected in probes:
        ok = errors == [] if expected is None else expected in errors
        if not ok:
            failures += 1
            print(f"self-test probe '{label}' failed: {errors}", file=sys.stderr)
    with tempfile.TemporaryDirectory() as scratch:
        app = Path(scratch) / "Probe.app"
        (app / "Contents/Resources/ThirdPartyNotices").mkdir(parents=True)
        (app / "Contents/Resources/ThirdPartyNotices/Zlib-LICENSE").write_text("x")
        if load_app_inputs(app) != ([], {"Contents/Resources/ThirdPartyNotices/Zlib-LICENSE"}):
            failures += 1
            print("self-test probe 'bundle listing' failed", file=sys.stderr)
    checks = len(probes) + 1
    if failures:
        print(f"third-party notice gate self-test: FAIL ({failures}/{checks})", file=sys.stderr)
        return 1
    print(f"third-party notice gate self-test: PASS ({checks}/{checks})")
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--self-test", action="store_true", help="run control and negative probes")
    parser.add_argument("--app", type=Path, help="built .app bundle to check")
    parser.add_argument("--sku", choices=["pro", "lite"], help="SKU of the --app bundle")
    args = parser.parse_args()
    if args.self_test:
        return self_test()
    if (args.app is None) != (args.sku is None):
        parser.error("--app and --sku go together")
    rows = parse_manifest(MANIFEST.read_text())
    if args.app:
        errors = check_app(rows, args.sku, *load_app_inputs(args.app))
        scope = f"{args.sku} bundle {args.app}"
    else:
        errors = check_static(rows, *load_static_inputs())
        scope = "repository"
    for error in errors:
        print(error, file=sys.stderr)
    if errors:
        return 1
    print(f"third-party notices: OK ({len(rows)} manifest rows, {scope})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
