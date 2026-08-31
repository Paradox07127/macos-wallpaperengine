#!/usr/bin/env bash
# Hardware-free app architecture/security shard for required PR validation.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

DERIVED_DATA="${DERIVED_DATA:-/tmp/LiveWallpaperFastAppContracts}"
RESULT_BUNDLE="${RESULT_BUNDLE:-/tmp/LiveWallpaperFastAppContracts-$$.xcresult}"
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}"
export DEVELOPER_DIR

usage() {
  cat <<'EOF'
Usage: scripts/fast_app_contract_tests.sh [--without-building|--pro-only|--list]

Runs the hardware-free architecture/security suites with concise xcresult
reporting. --without-building reuses products in DERIVED_DATA. --pro-only skips
the Lite host, which needs a real signing certificate (see below).
EOF
}

SUITES=(
  GeneralSettingsOwnershipCharacterizationTests
  InfrastructureRuntimeBoundaryTests
  ModuleImportBoundaryTests
  EntitlementAuditTests
  HTMLTrustVerdictTests
  LogPrivacySourceAuditTests
  LocalizationCoverageTests
  MonitorBoardPlacementAccessibilityCharacterizationTests
  OverlayVisibilityLifecycleCharacterizationTests
  RuntimeLeaseChurnCharacterizationTests
  MonitorSamplerOwnershipCharacterizationTests
  SuspendEnergyTests
  RepositoryRootTests
  SchemeEnvironmentContractTests
  SecurityScopedBookmarkResolverTests
  SteamCMDDoctorBoundaryCharacterizationTests
  SteamCMDDoctorLifecycleTests
  SystemMemoryPressureWatcherTests
  VideoResolutionContractCharacterizationTests
  WPECorpusManifestTests
  WPERendererOwnershipCharacterizationTests
  WPESceneScriptB2bResourceLimitTests
  WPESceneScriptContainmentCharacterizationTests
  WPEUploadCancellationOracleTests
  InstalledOwnershipCharacterizationTests
  # Persistence/config/storage correctness. Deterministic, hardware-free, and
  # each one covers a defect that shipped: a lost settings generation, a refused
  # Lite/Pro restore, a main-thread library walk.
  AtomicFileStoreTests
  ConfigurationPorterTests
  WPEStorageInventoryTests
  SettingsSearchLocalizationTests
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
    printf '%s\n' "${SUITES[@]}"
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

only_testing=()
for suite in "${SUITES[@]}"; do
  only_testing+=("-only-testing:LiveWallpaperTests/$suite")
done

echo "== Fast app architecture/security contracts (${#SUITES[@]} suites) =="
required_suites=()
for suite in "${SUITES[@]}"; do
  required_suites+=("--require-suite" "$suite")
done

python3 scripts/xcode_test_runner.py \
  --label "Fast app architecture/security contracts" \
  --result-bundle "$RESULT_BUNDLE" \
  --minimum-test-count 1 \
  --slowest 10 \
  --allow-skipped-suite WPECorpusManifestTests \
  "${required_suites[@]}" \
  -- \
  -project LiveWallpaper.xcodeproj \
  -scheme LiveWallpaper \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$DERIVED_DATA" \
  -enableCodeCoverage NO \
  -parallel-testing-enabled NO \
  "${only_testing[@]}" \
  "$action" \
  CODE_SIGN_IDENTITY=- \
  CODE_SIGN_STYLE=Manual \
  SWIFT_EMIT_LOC_STRINGS=NO

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
