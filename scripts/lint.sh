#!/bin/bash
# Run SwiftLint the way the git hooks and reviewers do.
#
#   scripts/lint.sh              staged Swift files (what pre-commit runs)
#   scripts/lint.sh all          the whole project (what CI/release should run)
#   scripts/lint.sh files a b    explicit files
#   scripts/lint.sh baseline     rewrite .swiftlint.baseline.json
#
# The baseline file records the debt that existed when the rules were added, so
# only new code has to comply. Missing SwiftLint is not an error by default (a
# fresh clone should still be able to commit); set LINT_REQUIRED=1 to enforce it.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="$ROOT/.swiftlint.yml"
BASELINE="$ROOT/.swiftlint.baseline.json"
cd "$ROOT"

if ! command -v swiftlint >/dev/null 2>&1; then
  echo "lint: 找不到 swiftlint（brew install swiftlint），已跳过。" >&2
  if [ "${LINT_REQUIRED:-0}" = "1" ]; then
    echo "lint: LINT_REQUIRED=1，按失败处理。" >&2
    exit 1
  fi
  exit 0
fi

mode="${1:-staged}"
if [ "$#" -gt 0 ]; then shift; fi

case "$mode" in
  baseline)
    swiftlint lint --config "$CONFIG" --write-baseline "$BASELINE"
    echo "lint: 基线已更新：$BASELINE"
    ;;
  all)
    swiftlint lint --config "$CONFIG" --baseline "$BASELINE" --strict
    ;;
  files)
    if [ "$#" -eq 0 ]; then
      exit 0
    fi
    swiftlint lint --config "$CONFIG" --baseline "$BASELINE" --strict -- "$@"
    ;;
  staged)
    changed=()
    while IFS= read -r file; do
      if [ -f "$file" ]; then
        changed+=("$file")
      fi
    done < <(git diff --cached --name-only --diff-filter=ACMR -- '*.swift')
    if [ "${#changed[@]}" -eq 0 ]; then
      exit 0
    fi
    swiftlint lint --config "$CONFIG" --baseline "$BASELINE" --strict -- "${changed[@]}"
    ;;
  *)
    echo "usage: scripts/lint.sh [staged|all|baseline|files <paths...>]" >&2
    exit 2
    ;;
esac
