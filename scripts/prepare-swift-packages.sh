#!/bin/bash
# Share dependency checkouts and binary artifacts between Debug tests and the
# Release archive. Never cache compiled products or permit implicit pin updates.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
: "${SWIFT_PACKAGE_CACHE_PATH:?Set SWIFT_PACKAGE_CACHE_PATH to the shared package directory}"

resolved_path="pi-work.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
mkdir -p "$(dirname "$resolved_path")" "$SWIFT_PACKAGE_CACHE_PATH"
cp ci/Package.resolved "$resolved_path"

xcodebuild -resolvePackageDependencies \
  -project pi-work.xcodeproj \
  -scheme PiWork \
  -clonedSourcePackagesDirPath "$SWIFT_PACKAGE_CACHE_PATH" \
  -onlyUsePackageVersionsFromResolvedFile \
  -disableAutomaticPackageResolution

# Ignore serialization/version-format changes by Xcode, but reject any change
# to the dependency identities, locations or pinned states.
python3 - "$resolved_path" <<'PY'
import json
from pathlib import Path
import sys


def pins(path):
    return sorted(json.loads(Path(path).read_text())["pins"], key=lambda pin: pin["identity"])


if pins("ci/Package.resolved") != pins(sys.argv[1]):
    sys.exit("Package.resolved changed during resolution. Update ci/Package.resolved deliberately before releasing.")
PY
