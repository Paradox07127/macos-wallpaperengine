#!/usr/bin/env bash
# Clean-clone-safe, non-building validation of the public release tooling.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

bash -n \
  scripts/release-app.sh \
  scripts/generate-appcast.sh \
  scripts/check_entitlements.sh \
  scripts/check_entitlements_self_test.sh \
  scripts/release_candidate_check.sh \
  scripts/release_contract_check.sh \
  scripts/app_tests.sh \
  scripts/fast_app_contract_tests.sh

bash scripts/release-app.sh --help >/dev/null
bash scripts/check_entitlements.sh --help >/dev/null
python3 scripts/entitlement_fingerprint.py --help >/dev/null
bash scripts/app_tests.sh --help >/dev/null
bash scripts/fast_app_contract_tests.sh --list >/dev/null

# The required PR shard must keep covering persistence, config portability,
# storage and localized search. Each of these guards a defect that already
# shipped once, and dropping one from the list would be silent.
shard_suites="$(bash scripts/fast_app_contract_tests.sh --list)"
for required_suite in \
  AtomicFileStoreTests \
  ConfigurationPorterTests \
  WPEStorageInventoryTests \
  SettingsSearchLocalizationTests; do
  if ! printf '%s\n' "$shard_suites" | grep -Fxq "$required_suite"; then
    echo "ERROR: $required_suite dropped from the required PR shard." >&2
    exit 1
  fi
done
# Metal/display suites deadlock the headless runner; keep them out by name.
if printf '%s\n' "$shard_suites" | grep -Eq 'Metal|Renderer(Frame|Pass)'; then
  echo "ERROR: the headless shard must not run Metal/display suites." >&2
  exit 1
fi
# The Lite host is a separate binary; a Pro-scheme shard cannot vouch for it.
grep -Fq 'scheme LiveWallpaperLite' scripts/fast_app_contract_tests.sh
grep -Fq 'require-suite LiteHostSmokeTests' scripts/fast_app_contract_tests.sh


# The changed-lines lint ratchet must stay wired into PR CI, and must stay a
# ratchet: a whole-repo sweep would force a one-shot reformat of 831 files.
# The invocation now lives in the Makefile so `make verify` and CI run the same
# gate; assert it there and that CI still routes through it.
python3 scripts/lint_changed_lines.py --help >/dev/null
grep -Fq 'scripts/lint_changed_lines.py --base' Makefile
grep -Fq 'make lint' .github/workflows/ci.yml
if grep -Eq 'swiftformat[^-]*\.$|swiftlint lint[[:space:]]*$' .github/workflows/ci.yml Makefile; then
  echo "ERROR: CI must lint changed lines, not the whole repository." >&2
  exit 1
fi

# Every script the Makefile reaches must be in the repository. scripts/ is
# ignored wholesale with a per-file allowlist, so a gate can be locally green and
# missing from a clean clone — which is exactly how `make fast` died on CI with
# "scripts/i18n_guard.sh: No such file or directory" (run 33422444404).
while read -r referenced_script; do
  if ! git ls-files --error-unmatch "$referenced_script" >/dev/null 2>&1; then
    echo "ERROR: Makefile runs $referenced_script, which is not tracked by git; add a .gitignore allowlist entry for it." >&2
    exit 1
  fi
done < <(grep -oE 'scripts/[A-Za-z0-9_.-]+' Makefile | sort -u)

# Gates that shell out to a non-system tool need it installed BEFORE they run.
# A missing tool exits 127, which reads as "gate failed" rather than "gate never
# ran" — scripts/i18n_guard.sh died that way on CI run 33425037452 because the
# brew step sat after `make fast` and the image ships no ripgrep.
if grep -Fq 'RG="${RG:-rg}"' scripts/i18n_guard.sh; then
  if ! grep -Eq 'brew install .*\bripgrep\b' .github/workflows/ci.yml; then
    echo "ERROR: scripts/i18n_guard.sh needs ripgrep, which CI never installs." >&2
    exit 1
  fi
  brew_line="$(grep -n 'brew install' .github/workflows/ci.yml | head -1 | cut -d: -f1)"
  fast_line="$(grep -n 'run: make fast' .github/workflows/ci.yml | head -1 | cut -d: -f1)"
  if (( brew_line > fast_line )); then
    echo "ERROR: CI installs gate tooling (line $brew_line) after 'make fast' (line $fast_line); the localization scan would exit 127." >&2
    exit 1
  fi
fi

# CI must not drift away from the Makefile: every gate the pipeline depends on
# is reached through a make target, so a locally-green `make verify` means the
# same thing as a green pipeline.
for make_target in 'make test-packages' 'make test-app-hosted' 'make contracts' 'make fast'; do
  if ! grep -Fq "$make_target" .github/workflows/ci.yml; then
    echo "ERROR: CI no longer runs '$make_target'; local and CI gates have diverged." >&2
    exit 1
  fi
done

# CI must use the hosted variant, never the bare target: `make test-app` runs the
# Lite host, whose assertions read runtime entitlements and therefore need a real
# certificate. Hosted runners have none, and ad-hoc signing hangs its test runner
# (measured 2026-08-31 — ad-hoc 1 failed, control on real signing 3/3).
if grep -Eq 'make test-app([^-]|$)' .github/workflows/ci.yml; then
  echo "ERROR: CI runs the bare 'make test-app'; hosted runners cannot sign the Lite host — use make test-app-hosted." >&2
  exit 1
fi
# ...and the variant must actually skip it, rather than being a renamed alias.
for lite_skip in '--pro-only' 'run_lite=0' 'if [[ "$run_lite" == "0" ]]; then'; do
  if ! grep -Fq -- "$lite_skip" scripts/fast_app_contract_tests.sh; then
    echo "ERROR: fast_app_contract_tests.sh lost '$lite_skip'; --pro-only would run the certificate-bound Lite host." >&2
    exit 1
  fi
done
python3 scripts/xcode_test_runner_self_test.py
bash scripts/check_entitlements.sh --sku pro --source
bash scripts/check_entitlements.sh --sku lite --source
bash scripts/check_entitlements_self_test.sh

app_test_script="scripts/app_tests.sh"
grep -Fq 'scripts/app_tests.sh full' scripts/release_candidate_check.sh
grep -Fq 'minimum_test_count=2400' "$app_test_script"
grep -Fq -- '-only-testing:LiveWallpaperTests/$suite' "$app_test_script"
grep -Fq -- '-configuration Debug' "$app_test_script"
grep -Fq -- "-destination 'platform=macOS,arch=arm64'" "$app_test_script"
grep -Fq -- '-enableCodeCoverage NO' "$app_test_script"
grep -Fq 'SWIFT_EMIT_LOC_STRINGS=NO' "$app_test_script"
grep -Fq 'test-without-building' "$app_test_script"
full_test_command="$(scripts/app_tests.sh full --dry-run)"
targeted_test_command="$(scripts/app_tests.sh suites ContractProbeSuite --dry-run)"
grep -Fq -- ' test ' <<<"$full_test_command"
if grep -Fq -- '-only-testing:' <<<"$full_test_command"; then
  echo "ERROR: full app-test mode unexpectedly filters the test target." >&2
  exit 1
fi
grep -Fq -- '-only-testing:LiveWallpaperTests/ContractProbeSuite' <<<"$targeted_test_command"
grep -Fq -- '--require-suite ContractProbeSuite' <<<"$targeted_test_command"

candidate_script="scripts/release_candidate_check.sh"
grep -Fq 'MACOS_DESTINATION="platform=macOS,arch=arm64"' "$candidate_script"
grep -Fq 'MACOS_ARCHIVE_DESTINATION="generic/platform=macOS"' "$candidate_script"
grep -Fq -- "-destination 'platform=macOS,arch=arm64'" scripts/fast_app_contract_tests.sh
grep -Fq -- '-enableCodeCoverage NO' scripts/fast_app_contract_tests.sh
if grep -q 'CODE_SIGNING_ALLOWED=NO' "$candidate_script"; then
  echo "ERROR: release link/archive gates must exercise signing; CODE_SIGNING_ALLOWED=NO is forbidden." >&2
  exit 1
fi

pro_release_block="$(sed -n '/^echo "== Link matrix + archive smoke: Pro Release =="/,/^PRO_XPC_SERVICE=/p' "$candidate_script")"
lite_debug_block="$(sed -n '/^echo "== Link matrix: Lite Debug =="/,/^LITE_DEBUG_BIN=/p' "$candidate_script")"
lite_release_block="$(sed -n '/^echo "== Link matrix + archive smoke: Lite Release =="/,/^LITE_ARCHIVED_APP=/p' "$candidate_script")"

grep -q 'xcodebuild archive' <<<"$pro_release_block"
grep -q -- '-scheme LiveWallpaper' <<<"$pro_release_block"
grep -q -- '-configuration Release' <<<"$pro_release_block"
grep -q -- '-destination "$MACOS_ARCHIVE_DESTINATION"' <<<"$pro_release_block"
grep -q -- '-archivePath "$PRO_ARCHIVE_PATH"' <<<"$pro_release_block"
grep -q 'CODE_SIGN_IDENTITY="-"' <<<"$pro_release_block"
grep -q 'ARCHS=arm64' <<<"$pro_release_block"
grep -q 'SWIFT_EMIT_LOC_STRINGS=NO' <<<"$pro_release_block"
# The SceneScript XPC helper was retired 2026-07-23 (a corpus audit found it
# isolated only provably-inert scripts while the dynamic ones ran in-process
# anyway). The RC gate now asserts its ABSENCE from both archives, and the
# project must not grow the target back.
grep -Fq 'unexpectedly embeds an XPC service.' "$candidate_script"
if grep -q 'SceneScriptXPC' "LiveWallpaper.xcodeproj/project.pbxproj"; then
  echo "ERROR: the retired SceneScript XPC service reappeared in project.pbxproj." >&2
  exit 1
fi

grep -q 'xcodebuild build' <<<"$lite_debug_block"
grep -q -- '-scheme LiveWallpaperLite' <<<"$lite_debug_block"
grep -q -- '-configuration Debug' <<<"$lite_debug_block"
grep -q -- '-destination "$MACOS_DESTINATION"' <<<"$lite_debug_block"
grep -q 'SWIFT_EMIT_LOC_STRINGS=NO' <<<"$lite_debug_block"

grep -q 'xcodebuild archive' <<<"$lite_release_block"
grep -q -- '-scheme LiveWallpaperLite' <<<"$lite_release_block"
grep -q -- '-configuration Release' <<<"$lite_release_block"
grep -q -- '-destination "$MACOS_ARCHIVE_DESTINATION"' <<<"$lite_release_block"
grep -q -- '-archivePath "$LITE_ARCHIVE_PATH"' <<<"$lite_release_block"
grep -q 'CODE_SIGN_IDENTITY="-"' <<<"$lite_release_block"
# Lite ships universal (ARCHS_STANDARD) so it runs on Intel Macs; Pro stays
# pinned to arm64 above. The gate keeps its teeth by requiring the archive to be
# checked for an arm64 slice — pinning the arch here would contradict the SKU.
if grep -q 'ARCHS=' <<<"$lite_release_block"; then
  echo "ERROR: Lite archive must not pin ARCHS — it ships universal for Intel support." >&2
  exit 1
fi
# Lives just past the block's end marker, so assert against the whole script.
grep -Fq 'assert_contains_arm64 "$LITE_RELEASE_BIN"' "$candidate_script"
grep -q 'SWIFT_EMIT_LOC_STRINGS=NO' <<<"$lite_release_block"

for scheme_file in \
  LiveWallpaper.xcodeproj/xcshareddata/xcschemes/LiveWallpaper.xcscheme \
  LiveWallpaper.xcodeproj/xcshareddata/xcschemes/LiveWallpaperLite.xcscheme; do
  grep -A2 '<ArchiveAction' "$scheme_file" | grep -q 'buildConfiguration = "Release"'
done

python3 scripts/check_quality_exclusions.py --self-test
python3 scripts/check_quality_exclusions.py
python3 scripts/check_module_import_boundaries.py --self-test
python3 scripts/check_module_import_boundaries.py

# Nested Sparkle helpers must be re-signed (Code Sign on Copy leaves them
# ad-hoc). The outer app must NOT be re-signed from a source entitlements
# plist — that strips the processed sandbox.
if grep -E 'codesign .*(LiveWallpaper/LiveWallpaper\.entitlements|LiveWallpaper/LiveWallpaperLite\.entitlements)' scripts/release-app.sh; then
  echo "ERROR: release-app.sh must not re-sign with a source entitlements plist." >&2
  exit 1
fi
if ! grep -q 'XPCServices/Installer.xpc' scripts/release-app.sh; then
  echo "ERROR: release-app.sh no longer re-signs Sparkle's Installer XPC; installs would fail." >&2
  exit 1
fi
if ! grep -q 'loomscreen-sparkle-ent' scripts/release-app.sh; then
  echo "ERROR: release-app.sh no longer extracts archive entitlements before Sparkle helper re-sign." >&2
  exit 1
fi
if ! grep -q 'entitlements :-' scripts/release-app.sh; then
  echo "ERROR: entitlement extraction must use ':-' (XML). Bare '-' dumps a blob codesign will not re-apply." >&2
  exit 1
fi
if ! grep -q 'appcast-lite.xml' scripts/release-app.sh || ! grep -q 'appcast-pro.xml' scripts/release-app.sh; then
  echo "ERROR: release-app.sh must allow dirty appcast files so both SKUs can be packaged back-to-back." >&2
  exit 1
fi
if ! grep -q 'ACTUAL_BUNDLE_VERSION' scripts/release-app.sh; then
  echo "ERROR: release-app.sh no longer asserts CFBundleVersion equals the marketing version." >&2
  exit 1
fi
grep -q 'scripts/check_entitlements.sh --sku "$SKU" --app' scripts/release-app.sh
grep -q '<key>com.apple.security.app-sandbox</key>' LiveWallpaper/LiveWallpaper.entitlements
grep -q '<key>com.apple.security.app-sandbox</key>' LiveWallpaper/LiveWallpaperLite.entitlements

project_file="LiveWallpaper.xcodeproj/project.pbxproj"
[[ "$(grep -c 'CODE_SIGN_ENTITLEMENTS = LiveWallpaper/LiveWallpaper.entitlements;' "$project_file")" == "2" ]]
[[ "$(grep -c 'CODE_SIGN_ENTITLEMENTS = LiveWallpaper/LiveWallpaperLite.entitlements;' "$project_file")" == "2" ]]


# Sparkle is shipped deliberately as of 2026-08-23, so the gate asserts it is
# wired rather than absent. It was banned here before, from a removal whose
# reason the squashed history no longer records; the ban was lifted only after
# an end-to-end install was verified under App Sandbox + Hardened Runtime.
# That combination only works because the app is signed with a real Team ID —
# two ad-hoc signatures read as "different teams" to library validation and the
# framework will not load, which is the most likely thing the original removal
# ran into.
for plist in LiveWallpaperInfo.plist LoomscreenInfo.plist; do
  if ! grep -q '<key>SUPublicEDKey</key>' "$plist"; then
    echo "ERROR: $plist has no SUPublicEDKey; Sparkle would accept unsigned updates." >&2
    exit 1
  fi
  if ! grep -q '<key>SUEnableInstallerLauncherService</key>' "$plist"; then
    echo "ERROR: $plist is missing SUEnableInstallerLauncherService; a sandboxed app cannot install its own update without it." >&2
    exit 1
  fi
  if ! awk '/<key>CFBundleVersion<\/key>/{getline; if ($0 ~ /\$\(MARKETING_VERSION\)/) found=1} END{exit found?0:1}' "$plist"; then
    echo "ERROR: $plist CFBundleVersion must track MARKETING_VERSION (Sparkle compares CFBundleVersion)." >&2
    exit 1
  fi
done
for ent in LiveWallpaper/LiveWallpaper.entitlements LiveWallpaper/LiveWallpaperLite.entitlements; do
  if ! grep -q 'PRODUCT_BUNDLE_IDENTIFIER)-spki' "$ent"; then
    echo "ERROR: $ent cannot reach Sparkle's Installer XPC service; updates would fail to install." >&2
    exit 1
  fi
done
# A release whose appcast is not regenerated ships to nobody.
if ! grep -q 'scripts/generate-appcast.sh' scripts/release-app.sh; then
  echo "ERROR: release-app.sh no longer regenerates the Sparkle appcast." >&2
  exit 1
fi
if ! grep -q 'must equal --version' scripts/generate-appcast.sh; then
  echo "ERROR: generate-appcast.sh no longer requires sparkle:version to match the marketing version." >&2
  exit 1
fi
# Nothing here is notarized, so a hand-installed DMG stays quarantined. The
# update dialog is the only place a user reliably reads before installing.
if ! grep -q 'xattr -dr com.apple.quarantine' scripts/generate-appcast.sh; then
  echo "ERROR: generate-appcast.sh no longer puts the quarantine command in the update notes." >&2
  exit 1
fi

if grep -Eq -- '(^|[ ="])-lc\+\+|CLANG_CXX_LIBRARY|c\+\+17|gnu\+\+17' "$project_file"; then
  echo "ERROR: removed manual libc++/target C++17 settings resurfaced." >&2
  exit 1
fi

if grep -q 'AppIntents' "$project_file"; then
  echo "ERROR: source-unused AppIntents framework link resurfaced." >&2
  exit 1
fi

lite_plan="$(bash scripts/release-app.sh --sku lite --version 0.0.0 --plan)"
pro_plan="$(bash scripts/release-app.sh --sku pro --version 0.0.0 --plan)"

grep -q '^scheme=LiveWallpaperLite$' <<<"$lite_plan"
grep -q '^app=Loomscreen.app$' <<<"$lite_plan"
grep -q '^bundle_id=com.loomscreen$' <<<"$lite_plan"
grep -q '^dmg=Loomscreen-0.0.0.dmg$' <<<"$lite_plan"
grep -q '^scheme=LiveWallpaper$' <<<"$pro_plan"
grep -q '^app=Loomscreen Pro.app$' <<<"$pro_plan"
grep -q '^bundle_id=com.loomscreen.pro$' <<<"$pro_plan"
grep -q '^dmg=Loomscreen-Pro-0.0.0.dmg$' <<<"$pro_plan"

echo "Release tooling contract passed for Lite and Pro."
