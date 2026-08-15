#!/usr/bin/env bash
# Format ONLY changed Swift files with SwiftFormat (avoids a big-bang whole-repo
# reformat that would destroy git blame and collide with in-flight refactors).
# The god-files listed in .swiftformat are excluded automatically.
#
# Usage:
#   scripts/format-changed.sh            # format files changed vs HEAD + staged + untracked
#   scripts/format-changed.sh main       # format files changed vs origin/main
set -euo pipefail
cd "$(dirname "$0")/.."

BASE="${1:-HEAD}"

if ! command -v swiftformat >/dev/null 2>&1; then
  echo "swiftformat not found. Install with: brew install swiftformat" >&2
  exit 1
fi

# Collect changed/staged/untracked .swift files (skip deletions).
# `mapfile` is a Bash 4+ builtin; macOS ships Bash 3.2, so read the list
# line-by-line instead.
files=()
while IFS= read -r file; do
  [ -n "$file" ] && files+=("$file")
done < <(
  {
    git diff --name-only --diff-filter=d "$BASE" -- '*.swift'
    git diff --name-only --cached --diff-filter=d -- '*.swift'
    git ls-files --others --exclude-standard -- '*.swift'
  } | sort -u
)

if [ "${#files[@]}" -eq 0 ]; then
  echo "No changed Swift files to format."
  exit 0
fi

printf 'Formatting %d changed Swift file(s) (.swiftformat excludes still apply)...\n' "${#files[@]}"
swiftformat --config .swiftformat "${files[@]}"
