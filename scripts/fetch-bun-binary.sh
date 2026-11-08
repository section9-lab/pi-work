#!/bin/bash
# Downloads the pinned official Bun runtime and package-manager binary used by pi-work.
# The staged files live under build/ and are copied into the app by Xcode.
#
# Usage: scripts/fetch-bun-binary.sh [version]

set -euo pipefail

BUN_VERSION="${1:-1.4.2}"
REPOSITORY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DESTINATION_ROOT="$REPOSITORY_ROOT/build/Bun"
RELEASE_URL="https://github.com/oven-sh/bun/releases/download/bun-v${BUN_VERSION}"
TEMPORARY_DIRECTORIES=()

cleanup() {
  for directory in "${TEMPORARY_DIRECTORIES[@]}"; do
    rm -rf "$directory"
  done
}
trap cleanup EXIT

fetch_architecture() {
  local architecture="$1"
  local asset_architecture

  case "$architecture" in
    arm64) asset_architecture="aarch64" ;;
    x64) asset_architecture="x64" ;;
    *)
      echo "error: unsupported Bun architecture $architecture" >&2
      exit 1
      ;;
  esac

  local archive="bun-darwin-${asset_architecture}.zip"
  local temporary_directory
  temporary_directory="$(mktemp -d)"
  TEMPORARY_DIRECTORIES+=("$temporary_directory")

  echo "Fetching Bun ${BUN_VERSION} for darwin-${architecture}..."
  curl -fsSL --retry 8 --retry-delay 5 --retry-all-errors     --connect-timeout 30 --max-time 600     -o "$temporary_directory/$archive" "$RELEASE_URL/$archive"
  curl -fsSL --retry 8 --retry-delay 5 --retry-all-errors     --connect-timeout 30 --max-time 600     -o "$temporary_directory/SHASUMS256.txt" "$RELEASE_URL/SHASUMS256.txt"

  local expected_checksum
  local actual_checksum
  expected_checksum="$(awk -v archive="$archive" '$2 == archive { print $1 }' "$temporary_directory/SHASUMS256.txt")"
  actual_checksum="$(shasum -a 256 "$temporary_directory/$archive" | awk '{ print $1 }')"
  if [ -z "$expected_checksum" ] || [ "$actual_checksum" != "$expected_checksum" ]; then
    echo "error: checksum verification failed for $archive" >&2
    exit 1
  fi

  /usr/bin/ditto -x -k "$temporary_directory/$archive" "$temporary_directory/extracted"
  local source="$temporary_directory/extracted/bun-darwin-${asset_architecture}/bun"
  local destination="$DESTINATION_ROOT/$architecture/bun"
  if [ ! -f "$source" ]; then
    echo "error: Bun archive did not contain the expected executable" >&2
    exit 1
  fi

  mkdir -p "$(dirname "$destination")"
  install -m 755 "$source" "$destination"
  if [ "$("$destination" --version)" != "$BUN_VERSION" ]; then
    echo "error: staged Bun did not report version $BUN_VERSION" >&2
    exit 1
  fi
  echo "Staged Bun ${BUN_VERSION} at $destination"
}

BUN_ARCHS="${BUN_ARCHS:-arm64 x64}"
for architecture in $BUN_ARCHS; do
  fetch_architecture "$architecture"
done
