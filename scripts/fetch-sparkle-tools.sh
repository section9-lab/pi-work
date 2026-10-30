#!/bin/bash
# Pinned to the same release as the application's Swift package dependency.
set -euo pipefail
SPARKLE_TOOLS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/build/Sparkle-2.10.1"
mkdir -p "$SPARKLE_TOOLS_ROOT"
if [ ! -x "$SPARKLE_TOOLS_ROOT/bin/sign_update" ]; then
  curl --fail --location --retry 3 --output "$SPARKLE_TOOLS_ROOT/Sparkle-2.10.1.tar.xz" \
    https://github.com/sparkle-project/Sparkle/releases/download/2.10.1/Sparkle-2.10.1.tar.xz
  printf '%s  %s\n' 1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27 \
    "$SPARKLE_TOOLS_ROOT/Sparkle-2.10.1.tar.xz" | shasum -a 256 --check >&2
  tar -xJf "$SPARKLE_TOOLS_ROOT/Sparkle-2.10.1.tar.xz" -C "$SPARKLE_TOOLS_ROOT"
fi
printf '%s\n' "$SPARKLE_TOOLS_ROOT/bin/sign_update"
