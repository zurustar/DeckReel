#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
if [ "$(uname -s)" != Darwin ]; then
  echo 'Build the runnable macOS binary on macOS (Xcode Command Line Tools + Go required at build time).' >&2
  exit 1
fi
arch="$(go env GOARCH)"
case "$arch" in arm64) target=arm64-apple-macosx12.0 ;; amd64) target=x86_64-apple-macosx12.0 ;; *) exit 1 ;; esac
helper="internal/native/assets/deckreel-native-$arch"
xcrun swiftc -swift-version 5 -O -target "$target" native/main.swift -o "$helper" \
  -framework Foundation -framework AVFoundation -framework AppKit -framework CoreText -framework CryptoKit
codesign --force --sign "${DECKREEL_SIGN_IDENTITY:--}" "$helper"
mkdir -p dist
CGO_ENABLED=0 go build -trimpath -ldflags='-s -w' -o dist/deckreel ./cmd/deckreel
codesign --force --sign "${DECKREEL_SIGN_IDENTITY:--}" dist/deckreel
echo 'Built dist/deckreel. Ad-hoc signing is for development; distribution signing/notarization remains a release step.'
