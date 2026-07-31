#!/bin/bash
# Renders the widget layouts to PNGs for visual checking.
# Usage: Tools/render.sh [output-dir]
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
out="${1:-$root/build/previews}"
mkdir -p "$out"

swiftc -O \
  -target arm64-apple-macosx14.0 \
  -o "$out/render-previews" \
  "$root"/Shared/*.swift \
  "$root"/App/AppPreferences.swift \
  "$root"/App/WelcomeView.swift \
  "$root"/Tools/main.swift

"$out/render-previews" "$out"
