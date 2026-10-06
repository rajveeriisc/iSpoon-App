#!/bin/bash
# scripts/build_release.sh
# Standardized build script for SmartSpoon production releases.
# This script injects the necessary obfuscation and debug-info splitting flags
# to protect the Dart code from trivial reverse engineering.

set -e

echo "Building SmartSpoon for Production (Obfuscated)..."

# Ensure dependencies are up to date
flutter pub get

# Build Android APK and AppBundle
echo "Building Android APK..."
flutter build apk --release --obfuscate --split-debug-info=./build/debug-info
echo "Building Android AppBundle..."
flutter build appbundle --release --obfuscate --split-debug-info=./build/debug-info

# Build iOS IPA (Requires macOS environment with Xcode)
if [ "$(uname)" == "Darwin" ]; then
  echo "Building iOS IPA..."
  flutter build ipa --release --obfuscate --split-debug-info=./build/debug-info
else
  echo "Skipping iOS build (not on macOS)."
fi

echo "Build complete! Debug info saved to ./build/debug-info. Store this safely for symbolication."
