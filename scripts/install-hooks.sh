#!/bin/bash
# Point git at the checked-in hooks (.githooks/) instead of copying files into
# .git/hooks, so hook changes are reviewed like any other code.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
chmod +x .githooks/pre-commit .githooks/pre-push scripts/lint.sh scripts/check-local.sh
git config core.hooksPath .githooks
echo "hooks: core.hooksPath = .githooks"
echo "hooks: pre-commit = scripts/lint.sh staged"
echo "hooks: pre-push   = tag v* → scripts/check-local.sh, 分支 → 只 lint 改动文件"
