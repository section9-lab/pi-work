#!/bin/bash
# Read-only Git integration and diff-parser checks without Xcode dependencies.
set -euo pipefail
cd "$(dirname "$0")/.."
CHECK_ROOT="$(mktemp -d)"
trap 'rm -rf "$CHECK_ROOT"' EXIT
swiftc -swift-version 5 -parse-as-library \
  PiWork/Core/UI/AppLanguage.swift \
  PiWork/Features/Changes/ProjectChangesService.swift \
  PiWork/Features/Changes/ProjectReviewLayout.swift \
  scripts/ProjectChangesChecks.swift -o "$CHECK_ROOT/project-changes-checks"
"$CHECK_ROOT/project-changes-checks"
