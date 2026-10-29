#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
analytics_check_dir="$(mktemp -d)"
trap 'rm -rf "$analytics_check_dir"' EXIT
swiftc -parse-as-library PiWork/Core/Analytics/AnalyticsState.swift scripts/AnalyticsChecks.swift -o "$analytics_check_dir/checks"
"$analytics_check_dir/checks"
