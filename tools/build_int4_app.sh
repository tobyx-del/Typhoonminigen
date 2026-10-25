#!/bin/bash
# Build the modified standalone App into this project's 成果 folder.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/../../成果/Typhoonminigen-9B-Int4.app"

if ! xcodebuild -version >/dev/null 2>&1; then
  echo "Full Xcode 26+ is required. Currently only Command Line Tools are selected."
  echo "Install Xcode, then set its active developer directory with xcode-select."
  exit 1
fi
if ! xcrun --find metal >/dev/null 2>&1; then
  echo "The Xcode Metal Toolchain is missing. Install it before building."
  exit 1
fi
mkdir -p "$(dirname "$OUT")"
"$ROOT/tools/bundle_app.sh" Release "$OUT"
echo "Build output: $OUT"
