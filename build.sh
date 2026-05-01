#!/usr/bin/env bash
# Builds stack-nudge.app (single persistent binary: panel + banners + voice)
# Usage: ./build.sh [arm64|x86_64]  (defaults to host arch)

set -e

ARCH="${1:-$(uname -m)}"
APP="build/stack-nudge.app"

build_app() {
  local app="$1"
  local binary_name="$2"
  local plist_path="$3"
  local icon_path="$4"
  local target="$5"
  local contents="$app/Contents"
  local macos="$contents/MacOS"

  mkdir -p "$macos" "$contents/Resources"

  shift 5
  swiftc "$@" \
    -o "$macos/$binary_name" \
    -target "${ARCH}-apple-macos${target}"

  cp "$plist_path" "$contents/Info.plist"
  if [[ -f "$icon_path" ]]; then
    cp "$icon_path" "$contents/Resources/Icon.icns"
  fi

  # Sign the bundle so Info.plist is bound into the signature.
  # Without this, macOS records the wrong identity for TCC (AXIsProcessTrusted = false).
  codesign --force --deep --sign - "$app"
}

echo "Building stack-nudge ($ARCH)..."
rm -rf build

build_app "$APP" "stack-nudge" \
  "panel/Info.plist" "notifier/Icon.icns" "13.0" \
  panel/main.swift \
  panel/Config.swift \
  panel/Hotkey.swift \
  panel/EventStore.swift \
  panel/EventListener.swift \
  panel/Panel.swift \
  panel/PanelNav.swift \
  panel/Components.swift \
  panel/Speaker.swift \
  panel/MenuBar.swift \
  panel/Permissions.swift \
  panel/Settings.swift \
  panel/SessionStore.swift \
  panel/Sessions.swift \
  panel/Welcome.swift \
  shared/AppActivator.swift \
  -framework Foundation -framework AppKit -framework SwiftUI -framework Carbon \
  -framework UserNotifications
echo "  Built $APP"
echo "  Binary: $(file "$APP/Contents/MacOS/stack-nudge")"
