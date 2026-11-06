#!/bin/sh
# Builds dist/DeckReel.app (a single executable) with SwiftPM. The CLI is built by build-cli.sh.
# Requires macOS 14+ and Xcode Command Line Tools; Xcode itself is not needed.
set -eu
cd "$(dirname "$0")/.."
if [ "$(uname -s)" != Darwin ]; then
  echo 'DeckReel builds on macOS only (Xcode Command Line Tools required).' >&2
  exit 1
fi
identity="${DECKREEL_SIGN_IDENTITY:--}"
swift build -c release --product DeckReelApp
bin="$(swift build -c release --show-bin-path)"

rm -rf dist/DeckReel.app
mkdir -p dist/DeckReel.app/Contents/MacOS dist/DeckReel.app/Contents/Resources
cp "$bin/DeckReelApp" dist/DeckReel.app/Contents/MacOS/DeckReel
cp app/Info.plist dist/DeckReel.app/Contents/Info.plist
# Hardened runtime; Apple Events to PowerPoint go out under the app's identity.
codesign --force --options runtime --entitlements app/DeckReel.entitlements --sign "$identity" dist/DeckReel.app
codesign --verify --strict dist/DeckReel.app

echo 'Built dist/DeckReel.app.'
if [ "$identity" = - ]; then
  echo 'Ad-hoc signing changes identity on each build, so macOS may ask for Automation permission again.'
fi
