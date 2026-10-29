#!/bin/bash
set -euo pipefail
RUNTIME_REPOSITORY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNTIME_TEST_DIRECTORY="$(mktemp -d)"
trap 'rm -rf "$RUNTIME_TEST_DIRECTORY"' EXIT
cd "$RUNTIME_REPOSITORY_ROOT"
python3 scripts/runtime-test-fixtures.py "$RUNTIME_TEST_DIRECTORY"
swiftc -swift-version 5 -parse-as-library \
  PiWork/Core/UI/AppLanguage.swift PiWork/Core/Update/*.swift \
  PiWork/Core/Agent/AgentHostExecutable.swift PiWork/Core/Agent/AgentHostProtocol.swift \
  PiWork/Core/Agent/AgentHostLineFramer.swift PiWork/Core/Agent/AgentHostClient.swift \
  PiWork/Core/Agent/AgentHostService.swift scripts/AgentRuntimeChecks.swift \
  PiWork/Core/Agent/MCPService.swift \
  -o "$RUNTIME_TEST_DIRECTORY/checks"
"$RUNTIME_TEST_DIRECTORY/checks" "$RUNTIME_TEST_DIRECTORY" "${1:-}"
