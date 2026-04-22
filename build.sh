#!/usr/bin/env bash
# Builds stack-nudge.app (macOS notification binary)
# Usage: ./build.sh [arm64|x86_64]  (defaults to host arch)

set -e

ARCH="${1:-$(uname -m)}"
APP="build/stack-nudge.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"

echo "Building stack-nudge ($ARCH)..."

rm -rf build && mkdir -p "$MACOS"

swiftc \
  notifier/main.swift \
  notifier/Config.swift \
  notifier/Notifier.swift \
  notifier/AppActivator.swift \
  -o "$MACOS/stack-nudge" \
  -target "${ARCH}-apple-macos12.0" \
  -framework Foundation \
  -framework AppKit

cp notifier/Info.plist "$CONTENTS/Info.plist"

mkdir -p "$CONTENTS/Resources"
cp notifier/Icon.icns "$CONTENTS/Resources/Icon.icns"

# Sign the bundle so Info.plist is bound into the signature.
# Without this, macOS records the wrong identity for TCC (AXIsProcessTrusted = false).
codesign --force --deep --sign - "$APP"

echo "  Built $APP"
echo "  Binary: $(file "$MACOS/stack-nudge")"
