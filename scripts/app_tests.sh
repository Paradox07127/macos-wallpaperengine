#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

run_package_tests() {
  if [[ $# -lt 2 ]]; then
    echo "Usage: scripts/app_tests.sh packages <scratch-root> <package>..." >&2
    exit 64
  fi
  scratch_root="$1"
  shift
  mkdir -p "$scratch_root"
  for package in "$@"; do
    # Names, not arbitrary paths: products and logs stay below this run's scratch.
    if ! [[ "$package" =~ ^[A-Za-z][A-Za-z0-9]*$ ]]; then
      echo "ERROR: invalid package name '$package'." >&2
      exit 64
    fi
    package_log="$(mktemp "$scratch_root/${package}-tests.XXXXXX")"
    echo "== Package tests: $package =="
    echo "Raw log: $package_log"
    if swift test --package-path "Packages/$package" \
      --scratch-path "$scratch_root/$package" > "$package_log" 2>&1; then
      :
    else
      package_status=$?
      tail -80 "$package_log" >&2
      exit "$package_status"
    fi
    # XCTest may report zero while Swift Testing ran the package's real suites.
    # Require the final Swift Testing summary to be nonzero AND passing.
    package_summary="$(grep -E 'Test run with ' "$package_log" | tail -1 || true)"
    if ! grep -Eq 'Test run with [1-9][0-9]* tests?( in [1-9][0-9]* suites?)? passed after ' <<< "$package_summary"; then
      echo "ERROR: $package reported success without a non-zero passing Swift Testing summary." >&2
      tail -80 "$package_log" >&2
      exit 1
    fi
    echo "$package_summary"
  done
}

usage() {
  cat <<'EOF'
Usage:
  scripts/app_tests.sh packages <scratch-root> <package>...
  scripts/app_tests.sh full [--without-building] [--hosted] [--slowest N] [--dry-run]
  scripts/app_tests.sh suites <Suite>... [--without-building] [--hosted] [--slowest N] [--dry-run]

Environment:
  DERIVED_DATA   Persistent build location (default: /tmp/LiveWallpaperAppTests)
  RESULT_BUNDLE  Fresh .xcresult path; defaults to a unique /tmp path

--hosted uses Pro ad-hoc manual signing while retaining entitlements.
EOF
}

mode="${1:-}"
if [[ -z "$mode" || "$mode" == "-h" || "$mode" == "--help" ]]; then
  usage
  exit 0
fi
shift

case "$mode" in
  packages)
    run_package_tests "$@"
    exit 0
    ;;
  full|suites) ;;
  *)
    echo "ERROR: mode must be 'packages', 'full' or 'suites'." >&2
    usage >&2
    exit 64
    ;;
esac

action="test"
slowest=10
dry_run=0
hosted=0
suites=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --without-building)
      action="test-without-building"
      shift
      ;;
    --hosted)
      hosted=1
      shift
      ;;
    --slowest)
      [[ $# -ge 2 ]] || { echo "ERROR: --slowest requires a value." >&2; exit 64; }
      slowest="$2"
      shift 2
      ;;
    --dry-run)
      dry_run=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --*)
      echo "ERROR: unknown option '$1'." >&2
      exit 64
      ;;
    *)
      suites+=("$1")
      shift
      ;;
  esac
done

# Full gates never inherit external corpus authorization. Explicit corpus work
# uses suites mode with TEST_RUNNER_LIVEWALLPAPER_EXTERNAL_FIXTURES=1 and paths.
if [[ "$mode" == "full" ]]; then
  unset LIVEWALLPAPER_EXTERNAL_FIXTURES TEST_RUNNER_LIVEWALLPAPER_EXTERNAL_FIXTURES
fi

if [[ "$mode" == "full" && ${#suites[@]} -ne 0 ]]; then
  echo "ERROR: full mode does not accept suite names." >&2
  exit 64
fi
if [[ "$mode" == "suites" && ${#suites[@]} -eq 0 ]]; then
  echo "ERROR: suites mode requires at least one suite." >&2
  exit 64
fi
if ! [[ "$slowest" =~ ^[0-9]+$ ]]; then
  echo "ERROR: --slowest must be a non-negative integer." >&2
  exit 64
fi

derived_data="${DERIVED_DATA:-/tmp/LiveWallpaperAppTests}"
result_bundle="${RESULT_BUNDLE:-/tmp/LiveWallpaperAppTests-${mode}-$(date +%Y%m%d-%H%M%S)-$$.xcresult}"
minimum_test_count=2400
label="LiveWallpaper full app tests"
selectors=()
required_suites=()

if [[ "$mode" == "suites" ]]; then
  minimum_test_count=1
  label="LiveWallpaper targeted suites"
  for suite in "${suites[@]}"; do
    selectors+=("-only-testing:LiveWallpaperTests/$suite")
    required_suites+=("--require-suite" "$suite")
  done
else
  # Full must execute the same critical security/lifecycle suites as the fast
  # shard. --list reads its single source of truth without starting a host.
  suite_manifest="$(bash scripts/fast_app_contract_tests.sh --list)"
  while IFS= read -r suite; do
    [[ -n "$suite" ]] && required_suites+=("--require-suite" "$suite")
  done <<< "$suite_manifest"
  # The corpus suite also has synthetic cases, so it must show a pass even
  # without a local corpus. Optional GPU/capture suites may still report skips.
  # Both capture harnesses assert on the state of THIS Mac's Workshop corpus and
  # oracle config, not on product code, so drift there fails the release gate for
  # a reason no shipped binary can be wrong about. They are already
  # `.enabled(if:)` opt-in; skipping keeps them runnable on demand via `suites`
  # mode. The MDL tests that pinned a corpus COUNT were deleted instead — a
  # number that changes when Steam downloads one more item tests nothing.
  selectors+=(
    "-skip-testing:LiveWallpaperTests/OracleCorpusCaptureTests/captureCorpus()"
    "-skip-testing:LiveWallpaperTests/WPECameraEvidenceCaptureTests/emitCameraEvidenceManifest()"
  )
fi

command=(
  python3 scripts/xcode_test_runner.py
  --label "$label"
  --result-bundle "$result_bundle"
  --minimum-test-count "$minimum_test_count"
  --slowest "$slowest"
)
if [[ ${#required_suites[@]} -gt 0 ]]; then
  command+=("${required_suites[@]}")
fi
command+=(
  --
  -project LiveWallpaper.xcodeproj
  -scheme LiveWallpaper
  -configuration Debug
  -destination 'platform=macOS,arch=arm64'
  -derivedDataPath "$derived_data"
  -enableCodeCoverage NO
)
if [[ ${#selectors[@]} -gt 0 ]]; then
  command+=("${selectors[@]}")
fi
command+=("$action" SWIFT_EMIT_LOC_STRINGS=NO)
if [[ "$hosted" == "1" ]]; then
  command+=(CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual)
fi

if [[ "$dry_run" == "1" ]]; then
  printf '%q ' "${command[@]}"
  printf '\n'
  exit 0
fi

"${command[@]}"
