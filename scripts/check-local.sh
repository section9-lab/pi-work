#!/bin/bash
# Reproduce the release workflow's "Validate release source" job locally.
#
#   scripts/check-local.sh            # everything except the native test run
#   scripts/check-local.sh v0.1.55    # also assert tag == MARKETING_VERSION
#   WITH_TESTS=1 scripts/check-local.sh   # add `xcodebuild test`
#
# `.githooks/pre-push` calls this before a `v*` tag leaves the machine, so a
# release cannot fail on the runner for a reason that was knowable locally.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

fail() {
  echo "check-local: $*" >&2
  exit 1
}

step() {
  printf '\n==> %s\n' "$*"
}

if [ "$#" -gt 0 ] && [ -n "${1:-}" ]; then
  version="$(awk '$1 == "MARKETING_VERSION:" { print $2; exit }' project.yml)"
  [ -n "$version" ] || fail "project.yml 缺少 MARKETING_VERSION"
  [ "$1" = "v$version" ] || fail "tag $1 与 project.yml 的 v$version 不一致"
  echo "check-local: tag $1 == MARKETING_VERSION $version"
fi

echo "check-local: Xcode $(xcodebuild -version | head -1 | sed 's/Xcode //'), bun $(bun --version)"
echo "check-local: CI 使用 Xcode 26；本地版本更新时，个别 UI 布局测试可能表现不同。"

step "Agent Host typecheck"
(cd AgentHost && bun run typecheck)

step "Agent Host tests"
(cd AgentHost && bun test)

step "Release workflow / packaging / appcast unit tests"
python3 -m unittest scripts/test_agent_runtime_package.py scripts/test_release_workflow.py \
  scripts/test_appcast.py scripts/test_ci_dependencies.py

step "App update checks"
bash scripts/test-app-updates.sh

step "Project change checks"
bash scripts/test-project-changes.sh

step "Agent runtime recovery"
# This check spawns real processes with a 1s handshake budget and has been seen
# to time out on a loaded laptop. One retry keeps a slow machine from blocking a
# tag push; a real regression still fails both attempts.
if ! bash scripts/test-agent-runtime.sh; then
  echo "check-local: agent runtime 检查失败，重试一次（本机负载下偶发 handshake 超时）"
  bash scripts/test-agent-runtime.sh
fi

step "SwiftLint (baseline)"
LINT_REQUIRED=1 scripts/lint.sh all

if [ "${WITH_TESTS:-0}" = "1" ]; then
  step "Native XCTest"
  command -v xcodegen >/dev/null 2>&1 || fail "需要 xcodegen（brew install xcodegen）"
  [ -d pi-work.xcodeproj ] || xcodegen generate
  xcodebuild test -project pi-work.xcodeproj -scheme PiWork -configuration Debug \
    -destination 'platform=macOS' -derivedDataPath build/DerivedDataStore -quiet
fi

echo
echo "check-local: 全部通过"
