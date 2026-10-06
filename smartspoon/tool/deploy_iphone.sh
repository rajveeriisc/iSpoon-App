#!/bin/bash
# One-command deploy to Rajveer's iPhone (USB or same-network Wi-Fi).
#
# Usage:
#   tool/deploy_iphone.sh            # debug build
#   tool/deploy_iphone.sh --release  # release build
#
# Handles the quirks discovered on this machine:
#  - Flutter's native-assets framework (objective_c.framework) is sometimes
#    only ad-hoc signed, which physical iPhones reject -> re-sign it.
#  - `flutter run` hangs at "Installing and launching..." (Xcode debugger
#    attach) -> install + launch directly via devicectl instead.
#  - Concurrent xcodebuild processes corrupt DerivedData -> refuse to start
#    if another build is running.
set -euo pipefail
cd "$(dirname "$0")/.."

MODE="debug"
BUNDLE_ID="ispoon"

# Everything that isn't --release is forwarded verbatim to `flutter build ios`.
# This exists so --dart-define=API_BASE_URL=... can reach the build: without it
# the iPhone build silently falls back to AppConfig's 127.0.0.1 dev URL, which
# can never work on a physical device (no adb reverse on iOS) — the app installs
# and runs but every backend call fails with connection refused.
BUILD_ARGS=()
for arg in "$@"; do
  if [ "$arg" = "--release" ]; then
    MODE="release"
  else
    BUILD_ARGS+=("$arg")
  fi
done

# 0. Refuse to run alongside another build (concurrent builds corrupt DerivedData)
if pgrep -x xcodebuild >/dev/null; then
  echo "ERROR: another xcodebuild is already running. Stop it first (or wait)." >&2
  exit 1
fi

# 1. Find the iPhone (CoreDevice UUID works over USB and Wi-Fi)
DEVICE=$(xcrun devicectl list devices 2>/dev/null | grep -E "iPhone.*(connected|available)" | grep -oE '[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}' | head -1)
if [ -z "$DEVICE" ]; then
  echo "ERROR: no iPhone found. Check USB cable or that phone+Mac are on the same Wi-Fi." >&2
  exit 1
fi
echo "==> Device: $DEVICE"

# 2. Build
echo "==> Building ($MODE)..."
flutter build ios --$MODE --no-version-check "${BUILD_ARGS[@]+"${BUILD_ARGS[@]}"}"

if [ "$MODE" = "release" ]; then
  APP="build/ios/Release-iphoneos/Runner.app"
else
  APP="build/ios/Debug-iphoneos/Runner.app"
fi
[ -d "$APP" ] || APP="build/ios/iphoneos/Runner.app"

# 3. Re-sign any ad-hoc frameworks (iPhones reject ad-hoc signatures)
IDENTITY=$(security find-identity -v -p codesigning | awk '/Apple Development/ {print $2; exit}')
for f in "$APP"/Frameworks/*.framework; do
  if codesign -dv "$f" 2>&1 | grep -q "Signature=adhoc"; then
    echo "==> Re-signing $(basename "$f") (was ad-hoc)"
    codesign -f -s "$IDENTITY" "$f"
  fi
done

# 4. Install + launch (bypasses the hanging Xcode debugger attach)
echo "==> Installing..."
xcrun devicectl device install app --device "$DEVICE" "$APP"
echo "==> Launching..."
xcrun devicectl device process launch --device "$DEVICE" "$BUNDLE_ID"
echo "==> Done. App is running on the iPhone."
