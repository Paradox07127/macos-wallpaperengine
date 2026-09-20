#!/usr/bin/env python3
"""Build a local Pro app without Sparkle, retaining sandbox and hardened runtime.

The tracked project remains suitable for normal Apple Development-signed builds.
Only the temporary project drops the Pro target's Sparkle link dependency.
"""

import argparse
import os
from pathlib import Path
import shutil
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archive-path", type=Path, required=True)
    parser.add_argument("--derived-data", type=Path, required=True)
    args = parser.parse_args()
    archive = args.archive_path.resolve()
    if archive.exists():
        parser.error("Choose a new archive path; existing archives are not overwritten.")

    root = Path(__file__).resolve().parent.parent
    source = root / "LiveWallpaper.xcodeproj"
    project = Path(tempfile.mkdtemp(prefix=".local-build-", suffix=".xcodeproj", dir=root))
    try:
        shutil.copytree(source, project, dirs_exist_ok=True, ignore=shutil.ignore_patterns("xcuserdata"))
        pbx = project / "project.pbxproj"
        content = pbx.read_text()
        for entry in (
            "\t\t\t\tF5EA85A1303B3613009D91C4 /* Sparkle in Frameworks */,\n",
            "\t\t\t\tF5EA85A0303B3613009D91C4 /* Sparkle */,\n",
        ):
            if content.count(entry) != 1:
                raise RuntimeError("Pro Sparkle dependency changed; review the local build recipe.")
            content = content.replace(entry, "")
        pbx.write_text(content)
        for scheme in project.rglob("*.xcscheme"):
            scheme.write_text(scheme.read_text().replace(
                "container:LiveWallpaper.xcodeproj", f"container:{project.name}"
            ))

        environment = dict(os.environ)
        environment.setdefault("DEVELOPER_DIR", "/Applications/Xcode.app/Contents/Developer")
        subprocess.run([
            "xcodebuild", "archive", "-project", str(project), "-scheme", "LiveWallpaper",
            "-configuration", "Release", "-destination", "generic/platform=macOS",
            "-archivePath", str(archive), "-derivedDataPath", str(args.derived_data.resolve()),
            "CODE_SIGN_STYLE=Manual", "CODE_SIGN_IDENTITY=-", "DEVELOPMENT_TEAM=",
            "PROVISIONING_PROFILE_SPECIFIER=", "ENABLE_HARDENED_RUNTIME=YES",
            "CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO", "ARCHS=arm64", "SWIFT_EMIT_LOC_STRINGS=NO",
            "SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) LOCAL_BUILD",
        ], cwd=root, env=environment, check=True)
        app = archive / "Products/Applications/Loomscreen Pro.app"
        links = subprocess.check_output(["otool", "-L", str(app / "Contents/MacOS/Loomscreen Pro")], text=True)
        if "Sparkle.framework" in links:
            raise RuntimeError("Local app still links Sparkle.")
        subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
        subprocess.run(["bash", "scripts/check_entitlements.sh", "--sku", "pro", "--app", str(app)],
                       cwd=root, env=environment, check=True)
    finally:
        shutil.rmtree(project)


if __name__ == "__main__":
    main()
