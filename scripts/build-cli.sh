#!/bin/sh
# Builds the dist/deckreel CLI with SwiftPM. Run from a terminal, macOS attributes
# PowerPoint automation to that terminal app; prefer DeckReel.app (build-app.sh).
set -eu
cd "$(dirname "$0")/.."
if [ "$(uname -s)" != Darwin ]; then
  echo 'DeckReel builds on macOS only (Xcode Command Line Tools required).' >&2
  exit 1
fi
identity="${DECKREEL_SIGN_IDENTITY:--}"
swift build -c release --product DeckReelCLI
bin="$(swift build -c release --show-bin-path)"
mkdir -p dist
cp "$bin/DeckReelCLI" dist/deckreel
codesign --force --options runtime --entitlements app/DeckReel.entitlements --sign "$identity" dist/deckreel
echo 'Built dist/deckreel.'
