#!/bin/bash
# Run SwiftLint the way the git hooks and reviewers do.
#
#   scripts/lint.sh              staged Swift files (what pre-commit runs)
#   scripts/lint.sh all          the whole project (what CI/release should run)
#   scripts/lint.sh files a b    explicit files
#   scripts/lint.sh baseline     rewrite scripts/lint-budget.json
#
# Grandfathered violations live in `scripts/lint-budget.json` and are counted per
# (rule, file) by `scripts/lint_gate.py`, not by SwiftLint's own `--baseline`.
# Size-based rules (file_length, type_body_length, …) report their violation at
# the last line and quote the measured size, so SwiftLint's baseline goes stale
# whenever a baselined file changes size — which is every commit on a large view.
# The count-based budget keeps the same promise without that drift.
#
# Missing SwiftLint is not an error by default (a fresh clone should still be
# able to commit); set LINT_REQUIRED=1 to enforce it.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="$ROOT/.swiftlint.yml"
BUDGET="$ROOT/scripts/lint-budget.json"
GATE="$ROOT/scripts/lint_gate.py"
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

report="$(mktemp "${TMPDIR:-/tmp}/pi-work-lint.XXXXXX")"
trap 'rm -f "$report"' EXIT

# SwiftLint exits 2 as soon as it finds a serious violation, including the
# grandfathered ones, so the exit status cannot decide anything here. The gate
# reads the JSON report instead; a report that cannot be parsed fails loudly in
# lint_gate.py.
swiftlint_lint() {
  set +e
  swiftlint lint --config "$CONFIG" --reporter json --output "$report" "$@" >/dev/null
  local status=$?
  set -e
  if [ ! -s "$report" ]; then
    echo "lint: SwiftLint 没有产出报告（exit $status），按失败处理。" >&2
    exit 1
  fi
}

case "$mode" in
  baseline)
    swiftlint_lint
    python3 "$GATE" write --report "$report" --budget "$BUDGET" --root "$ROOT"
    ;;
  all)
    swiftlint_lint
    python3 "$GATE" check --report "$report" --budget "$BUDGET" --root "$ROOT"
    ;;
  files)
    if [ "$#" -eq 0 ]; then
      exit 0
    fi
    swiftlint_lint -- "$@"
    python3 "$GATE" check --partial --report "$report" --budget "$BUDGET" --root "$ROOT"
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
    swiftlint_lint -- "${changed[@]}"
    python3 "$GATE" check --partial --report "$report" --budget "$BUDGET" --root "$ROOT"
    ;;
  *)
    echo "usage: scripts/lint.sh [staged|all|baseline|files <paths...>]" >&2
    exit 2
    ;;
esac
