#!/bin/sh
# Builds dist/DeckReel.app: the SwiftUI app with the deckreel CLI in Contents/Helpers.
set -eu
cd "$(dirname "$0")/.."
./scripts/build.sh
arch="$(go env GOARCH)"
case "$arch" in arm64) target=arm64-apple-macos14.0 ;; amd64) target=x86_64-apple-macos14.0 ;; *) exit 1 ;; esac
identity="${DECKREEL_SIGN_IDENTITY:--}"
app=dist/DeckReel.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Helpers" "$app/Contents/Resources"
xcrun swiftc -swift-version 5 -parse-as-library -O -target "$target" app/DeckReelApp.swift \
  -o "$app/Contents/MacOS/DeckReel" -framework SwiftUI -framework AppKit -framework UniformTypeIdentifiers
cp app/Info.plist "$app/Contents/Info.plist"
cp dist/deckreel "$app/Contents/Helpers/deckreel"
# Sign inside-out with the hardened runtime. Apple Events go out under the app's identity.
codesign --force --options runtime --entitlements app/DeckReel.entitlements --sign "$identity" "$app/Contents/Helpers/deckreel"
codesign --force --options runtime --entitlements app/DeckReel.entitlements --sign "$identity" "$app"
codesign --verify --strict "$app"
echo "Built $app. Ad-hoc signing changes identity on each build, so macOS may ask for Automation permission again."
