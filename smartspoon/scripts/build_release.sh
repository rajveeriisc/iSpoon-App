#!/bin/bash
# scripts/build_release.sh
# Standardized build script for SmartSpoon production releases.
# This script injects the necessary obfuscation and debug-info splitting flags
# to protect the Dart code from trivial reverse engineering.

set -euo pipefail

# --- Required build-time configuration -------------------------------------
#
# AppConfig.baseUrl falls back to http://127.0.0.1:5001 when API_BASE_URL is
# absent, so a release built without it ships an app that tries to reach a
# backend on the handset itself and every login fails. Refuse to build rather
# than produce that artifact.
#
# HMAC_SECRET must match the value the server validates (see
# ispoon-backend/src/middleware/hmacMiddleware.js). Without it a release build
# signs requests with the publicly leaked development literal.
missing=()
[ -n "${API_BASE_URL:-}" ] || missing+=("API_BASE_URL")
[ -n "${HMAC_SECRET:-}" ]  || missing+=("HMAC_SECRET")

if [ ${#missing[@]} -gt 0 ]; then
  echo "ERROR: missing required environment variable(s): ${missing[*]}" >&2
  echo >&2
  echo "Usage:" >&2
  echo "  API_BASE_URL=https://api.example.com \\" >&2
  echo "  HMAC_SECRET=<same value as the server> \\" >&2
  echo "    ./scripts/build_release.sh" >&2
  exit 1
fi

case "$API_BASE_URL" in
  https://*) ;;
  *)
    echo "ERROR: API_BASE_URL must be https:// for a release build (got: $API_BASE_URL)" >&2
    exit 1
    ;;
esac

DEFINES=(
  "--dart-define=API_BASE_URL=$API_BASE_URL"
  "--dart-define=HMAC_SECRET=$HMAC_SECRET"
)

COMMON=(--release --obfuscate --split-debug-info=./build/debug-info "${DEFINES[@]}")

# Which artifacts to build. Default is everything; TARGETS lets you ask for
# just the APK when you only need something installable to test with, e.g.
#   TARGETS=apk API_BASE_URL=... HMAC_SECRET=... ./scripts/build_release.sh
TARGETS="${TARGETS:-apk,appbundle,ipa}"
wants() { case ",$TARGETS," in *",$1,"*) return 0;; *) return 1;; esac; }

echo "Building SmartSpoon for Production (Obfuscated)..."
echo "  API_BASE_URL = $API_BASE_URL"
echo "  HMAC_SECRET  = (${#HMAC_SECRET} chars, not echoed)"

# Ensure dependencies are up to date
flutter pub get

# Build Android artifacts
if wants apk; then
  echo "Building Android APK..."
  flutter build apk "${COMMON[@]}"
fi
if wants appbundle; then
  echo "Building Android AppBundle..."
  flutter build appbundle "${COMMON[@]}"
fi

# Build iOS IPA (Requires macOS environment with Xcode)
if wants ipa; then
  if [ "$(uname)" == "Darwin" ]; then
    echo "Building iOS IPA..."
    flutter build ipa "${COMMON[@]}"
  else
    echo "Skipping iOS build (not on macOS)."
  fi
fi

echo "Build complete! Debug info saved to ./build/debug-info. Store this safely for symbolication."
