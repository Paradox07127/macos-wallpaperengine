#!/usr/bin/env bash
# Small daily shard for data safety, trust boundaries and app/session behavior.
set -euo pipefail

# The required shard always uses synthetic fixtures, even in an opted-in shell.
unset LIVEWALLPAPER_EXTERNAL_FIXTURES TEST_RUNNER_LIVEWALLPAPER_EXTERNAL_FIXTURES

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

DERIVED_DATA="${DERIVED_DATA:-/tmp/LiveWallpaperFastAppContracts}"
RESULT_BUNDLE="${RESULT_BUNDLE:-/tmp/LiveWallpaperFastAppContracts-$$.xcresult}"
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export DEVELOPER_DIR

usage() {
  cat <<'EOF'
Usage: scripts/fast_app_contract_tests.sh [--without-building|--pro-only|--list]

Runs the critical data/security/apply/session suites with concise xcresult
reporting. --without-building reuses products in DERIVED_DATA. --pro-only skips
the Lite host, which needs a real signing certificate (see below).
EOF
}

# The daily shard protects data, trust boundaries and core apply/session behavior.
# Feature-specific import formats, layout, parser, renderer and stress suites stay available via
# app_tests.sh suites/full rather than accumulating in every PR run.
PARALLEL_SUITES=(
  AtomicFileStoreTests
  SettingsPersistenceFailureTests
  SettingsManagerParkedConfigurationTests
  DisplayConfigurationControllerTests
  ConfigurationPorterTests
  ScreenSchemePersistenceTests
  EntitlementAuditTests
  HTMLTrustVerdictTests
  LogPrivacySourceAuditTests
  SecurityScopedBookmarkResolverTests
  SteamLibraryPathsTests
  SteamLibrarySymlinkContainmentTests
  SteamWriteOwnershipTests
)

# These share settings, AppKit/WebKit delivery, or process-wide factories.
SERIAL_SUITES=(
  DefaultsIsolationTests
  PersistentUserPauseTests
  ScreenManagerCoordinationTests
  ScreenRuntimeOwnershipTests
  RuntimeTests
  ApplyRouterTests
  DeferredApplyCoordinatorTests
  WallpaperAutomationCoordinatorTests
  WallpaperManualSwitchGroupTests
  NetworkIsolationEnforcementTests
  FolderURLSchemeHandlerIsolationTests
  HTMLWallpaperNavigationPolicyTests
  HTMLWallpaperViewSourceIsolationTests
  ConfigurationPorterBookmarkMergeTests
  WorkshopMutationGateTests
  WorkshopDownloadQueueTests
  SteamConnectorClientCancellationTests
  WallpaperVideoPlayerStartupPolicyTests
  WPESceneScriptB2bResourceLimitTests
  WPESceneScriptContainmentCharacterizationTests
)

action="test"
run_lite=1
case "${1:-}" in
  "") ;;
  --without-building)
    action="test-without-building"
    ;;
  --pro-only)
    run_lite=0
    ;;
  --list)
    printf '%s\n' "${PARALLEL_SUITES[@]}" "${SERIAL_SUITES[@]}"
    exit 0
    ;;
  -h|--help)
    usage
    exit 0
    ;;
  *)
    echo "ERROR: unknown argument '$1'" >&2
    exit 64
    ;;
esac

# run_pass LABEL RESULT_BUNDLE ACTION PARALLEL(YES|NO) SUITE...
run_pass() {
  local label="$1" result_bundle="$2" pass_action="$3" parallel="$4"
  shift 4
  local parallel_flags=(-parallel-testing-enabled "$parallel")
  if [[ "$parallel" == "YES" ]]; then
    # One host process: clones would all share one app container and defaults domain.
    parallel_flags+=(-parallel-testing-worker-count 1)
  fi
  local only_testing=() required_suites=() suite
  for suite in "$@"; do
    only_testing+=("-only-testing:LiveWallpaperTests/$suite")
    required_suites+=("--require-suite" "$suite")
  done

  python3 scripts/xcode_test_runner.py \
    --label "$label" \
    --result-bundle "$result_bundle" \
    --minimum-test-count 1 \
    --skip-policy scripts/app_test_skip_policy.json \
    --slowest 10 \
    "${required_suites[@]}" \
    -- \
    -project LiveWallpaper.xcodeproj \
    -scheme LiveWallpaper \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$DERIVED_DATA" \
    -enableCodeCoverage NO \
    "${parallel_flags[@]}" \
    "${only_testing[@]}" \
    "$pass_action" \
    CODE_SIGN_IDENTITY=- \
    CODE_SIGN_STYLE=Manual \
    SWIFT_EMIT_LOC_STRINGS=NO
}

echo "== Fast app architecture/security contracts (${#PARALLEL_SUITES[@]} parallel + ${#SERIAL_SUITES[@]} serial suites) =="
run_pass "Fast app architecture/security contracts (parallel)" \
  "$RESULT_BUNDLE" "$action" YES "${PARALLEL_SUITES[@]}"
# The pass above already built into DERIVED_DATA with the same settings.
run_pass "Fast app architecture/security contracts (serial)" \
  "${RESULT_BUNDLE%.xcresult}-serial.xcresult" test-without-building NO "${SERIAL_SUITES[@]}"

# The Lite host is a different binary, so a Pro-scheme pass says nothing about
# it. Own derived data: sharing one build.db across two schemes deadlocks.
#
# Certificate-bound, so hosted runners must pass --pro-only: LiteHostSmokeTests
# reads runtime grants through SecTaskCopyValueForEntitlement, which needs the
# host signed for real. Ad-hoc is not a substitute — measured 2026-08-31, the
# ad-hoc run's test runner hung before connecting (1 failed) while the control
# run on the project's own signing passed 3/3.
if [[ "$run_lite" == "0" ]]; then
  echo "== Lite host smoke: SKIPPED (--pro-only; needs a signing certificate) =="
  exit 0
fi

echo "== Lite host smoke =="
python3 scripts/xcode_test_runner.py \
  --label "Lite host smoke" \
  --result-bundle "${RESULT_BUNDLE%.xcresult}-lite.xcresult" \
  --minimum-test-count 3 \
  --require-suite LiteHostSmokeTests \
  -- \
  -project LiveWallpaper.xcodeproj \
  -scheme LiveWallpaperLite \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "${DERIVED_DATA}Lite" \
  -enableCodeCoverage NO \
  -parallel-testing-enabled NO \
  test \
  SWIFT_EMIT_LOC_STRINGS=NO
