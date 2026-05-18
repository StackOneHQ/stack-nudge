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

  # Bundle the user-facing runtime payload (hook script, phrase pools,
  # example config) into the .app so Bootstrap.swift can copy them out
  # to ~/.stack-nudge/ on first launch. Previously these lived only at
  # the repo root and install.sh copied them; now the .app is self-
  # contained — drop in Applications/, no source clone needed.
  local repo_root
  repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  cp "$repo_root/notify.sh" "$contents/Resources/notify.sh"
  chmod +x "$contents/Resources/notify.sh"
  if [[ -d "$repo_root/phrases" ]]; then
    cp -R "$repo_root/phrases" "$contents/Resources/phrases"
  fi
  if [[ -f "$repo_root/notify.conf.example" ]]; then
    cp "$repo_root/notify.conf.example" "$contents/Resources/notify.conf.example"
  fi

  sign_bundle "$app"
}

# Sign the bundle so Info.plist is bound into the signature. Without this,
# macOS records the wrong identity for TCC (AXIsProcessTrusted = false).
#
# Resolution order:
#   1. $STACKNUDGE_SIGN_IDENTITY (explicit override — used by CI when a
#      release artifact needs to be signed with a known identity from a
#      secret-loaded keychain).
#   2. First "Developer ID Application" identity in the user's keychain
#      (devs with the cert get stable code-sig hashes across rebuilds, so
#      macOS TCC/Keychain grants stick).
#   3. Ad-hoc (`codesign -s -`) — old behaviour. Works for everyone but the
#      cdhash changes on every build, which means TCC + Keychain prompts
#      re-fire on each rebuild and each release.
#
# Hardened runtime (--options runtime) is enabled when a real identity is
# present so the signed bundle is notarisation-eligible. It's omitted from
# the ad-hoc path because it makes the binary slightly more restricted
# without any of the benefits (notarisation requires Developer ID).
sign_bundle() {
  local app="$1"
  local identity="${STACKNUDGE_SIGN_IDENTITY:-}"

  if [[ -z "$identity" ]]; then
    identity=$(
      security find-identity -v -p codesigning 2>/dev/null \
        | awk -F'"' '/"Developer ID Application/ {print $2; exit}'
    )
  fi

  if [[ -n "$identity" ]]; then
    codesign --force --deep --options runtime --sign "$identity" "$app"
    echo "  Signed: $identity"
  else
    codesign --force --deep --sign - "$app"
    echo "  Signed: ad-hoc (no Developer ID Application cert in keychain)"
  fi
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
  panel/SessionUsage.swift \
  panel/Sessions.swift \
  panel/Phrases.swift \
  panel/UpdateChecker.swift \
  panel/Updater.swift \
  panel/Welcome.swift \
  shared/AppActivator.swift \
  -framework Foundation -framework AppKit -framework SwiftUI -framework Carbon \
  -framework UserNotifications
echo "  Built $APP"
echo "  Binary: $(file "$APP/Contents/MacOS/stack-nudge")"
