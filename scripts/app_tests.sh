#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

run_package_tests() {
  # A developer's shell cannot turn required regression into a local corpus run.
  if [[ "$mode" == "packages-corpus" ]]; then
    export LIVEWALLPAPER_EXTERNAL_FIXTURES=1
    # SwiftPM starts tests in the package directory. Resolve caller-supplied
    # relative roots before crossing that working-directory boundary.
    while IFS= read -r key; do
      case "$key" in
        WPE_WORKSHOP_ROOT|WPE_ASSETS_DIR|WPE_HLSL_CAPTURE_DIR|LOOMSCREEN_WPE_*_ORACLE_DIR)
          value="${!key}"
          if [[ -n "$value" && "$value" != /* ]]; then
            export "$key=$ROOT/$value"
          fi
          ;;
      esac
    done < <(compgen -e)
  else
    unset LIVEWALLPAPER_EXTERNAL_FIXTURES TEST_RUNNER_LIVEWALLPAPER_EXTERNAL_FIXTURES
  fi
  if [[ $# -lt 2 ]]; then
    echo "Usage: scripts/app_tests.sh packages <scratch-root> <package>..." >&2
    exit 64
  fi
  if [[ "$mode" == "packages-corpus" && ( $# -ne 2 || "$2" != "LiveWallpaperProWPE" ) ]]; then
    echo "ERROR: packages-corpus requires exactly the LiveWallpaperProWPE package." >&2
    exit 64
  fi
  scratch_root="$1"
  shift
  mkdir -p "$scratch_root"
  scratch_root="$(cd "$scratch_root" && pwd)"
  for package in "$@"; do
    # Names, not arbitrary paths: products and logs stay below this run's scratch.
    if ! [[ "$package" =~ ^[A-Za-z][A-Za-z0-9]*$ ]]; then
      echo "ERROR: invalid package name '$package'." >&2
      exit 64
    fi
    package_log="$scratch_root/${package}-tests.log"
    echo "== Package tests: $package =="
    echo "Raw log: $package_log"
    package_result="$scratch_root/${package}-tests.xml"
    swift_testing_result="$scratch_root/${package}-tests-swift-testing.xml"
    rm -f "$package_result" "$swift_testing_result"
    if swift test --package-path "Packages/$package" \
      --scratch-path "$scratch_root/$package" --xunit-output "$package_result" > "$package_log" 2>&1; then
      :
    else
      package_status=$?
      tail -80 "$package_log" >&2
      exit "$package_status"
    fi
    validation_args=("$swift_testing_result" --xctest-log "$package_log")
    if [[ "$mode" == "packages-corpus" ]]; then
      validation_args+=(--require-suite WPEWorkshopMdlTests)
    fi
    python3 scripts/validate_package_tests.py "${validation_args[@]}"
  done
}

usage() {
  cat <<'EOF'
Usage:
  scripts/app_tests.sh packages <scratch-root> <package>...
  scripts/app_tests.sh packages-corpus <scratch-root> LiveWallpaperProWPE
  scripts/app_tests.sh full [--without-building] [--hosted] [--slowest N] [--dry-run]
  scripts/app_tests.sh suites <Suite>... [--without-building] [--hosted] [--slowest N] [--dry-run]

Environment:
  DERIVED_DATA   Persistent build location (default: system temporary directory/LiveWallpaperAppTests)
  RESULT_BUNDLE  Fresh .xcresult path; defaults to a unique system temporary path

packages is self-contained. packages-corpus additionally compiles ExternalCorpus:
  WPE_WORKSHOP_ROOT  Directory containing <Workshop ID>/scene.pkg
  WPE_ASSETS_DIR     Wallpaper Engine assets directory
  WPE_HLSL_CAPTURE_DIR and LOOMSCREEN_WPE_*_ORACLE_DIR: pinned oracle inputs
Missing/invalid corpus inputs and skipped cases fail acceptance. Nothing is downloaded.
All fixture paths are explicit and may be relative to the repository root.

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
  packages|packages-corpus)
    run_package_tests "$@"
    exit 0
    ;;
  full|suites) ;;
  *)
    echo "ERROR: mode must be 'packages', 'packages-corpus', 'full' or 'suites'." >&2
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

temporary_root="${TMPDIR:-$(getconf DARWIN_USER_TEMP_DIR)}"
derived_data="${DERIVED_DATA:-${temporary_root%/}/LiveWallpaperAppTests}"
result_bundle="${RESULT_BUNDLE:-${temporary_root%/}/LiveWallpaperAppTests-${mode}-$(date +%Y%m%d-%H%M%S)-$$.xcresult}"
minimum_test_count=1
label="LiveWallpaper full app tests"
selectors=()
required_suites=()

if [[ "$mode" == "suites" ]]; then
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
  # Both capture harnesses assert on the state of THIS Mac's Workshop corpus and
  # oracle config, not on product code, so drift there fails the release gate for
  # a reason no shipped binary can be wrong about. They are already
  # `.enabled(if:)` opt-in; skipping keeps them runnable on demand via `suites`
  # mode. The MDL tests that pinned a corpus COUNT were deleted instead — a
  # number that changes when Steam downloads one more item tests nothing.
  selectors+=(
    "-skip-testing:LiveWallpaperTests/WPECameraEvidenceCaptureTests/emitCameraEvidenceManifest()"
  )
fi

command=(
  python3 scripts/xcode_test_runner.py
  --label "$label"
  --result-bundle "$result_bundle"
  --minimum-test-count "$minimum_test_count"
  --skip-policy scripts/app_test_skip_policy.json
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
# Full product tests compile real scene shaders. Their SDK is a declared build
# dependency; failing early must not turn these assertions into skipped cases.
if [[ "$mode" == "full" ]]; then
  WPE_SHADER_TOOLCHAIN_ROOT="${WPE_SHADER_TOOLCHAIN_ROOT:-$ROOT/build/wpe-shader-toolchain-inputs}"
  if [[ "$dry_run" == "0" && "$action" == "test" ]]; then
    WPE_SHADER_TOOLCHAIN_ROOT="$WPE_SHADER_TOOLCHAIN_ROOT" bash WPEShaderCompiler/build.sh --check-inputs
  fi
fi
if [[ -n "${WPE_SHADER_TOOLCHAIN_ROOT:-}" ]]; then
  toolchain_root="$WPE_SHADER_TOOLCHAIN_ROOT"
  [[ "$toolchain_root" == /* ]] || toolchain_root="$ROOT/$toolchain_root"
  command+=("WPE_SHADER_TOOLCHAIN_ROOT=$toolchain_root")
fi
if [[ "$hosted" == "1" ]]; then
  command+=(CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual)
fi

if [[ "$dry_run" == "1" ]]; then
  printf '%q ' "${command[@]}"
  printf '\n'
  exit 0
fi

"${command[@]}"
