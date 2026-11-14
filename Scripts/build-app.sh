#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP_NAME="ChronoMac"
BUILD_DIR="$ROOT/build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
ICONSET="$BUILD_DIR/AppIcon.iconset"

echo "==> Building $APP_NAME (release, arm64, macOS 14.0+)..."
swift build -c release --arch arm64

BIN_PATH="$(swift build -c release --arch arm64 --show-bin-path)/$APP_NAME"

echo "==> Assembling $APP_BUNDLE..."
rm -rf "$APP_BUNDLE" "$ICONSET"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources" "$ROOT/docs"

cp "$BIN_PATH" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
chmod +x "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "$ROOT/Scripts/Info.plist" "$APP_BUNDLE/Contents/Info.plist"

echo "==> Generating AppIcon.icns..."
swift "$ROOT/Scripts/make-icon.swift" "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

echo "==> Ad-hoc signing & verifying..."
codesign --force --deep --sign - "$APP_BUNDLE"
codesign --verify --deep --strict "$APP_BUNDLE"

echo "==> Rendering 2x Retina screenshots (EN + zh-Hans) to docs/..."
TMP_BUILD_ISO="$(mktemp -d "${TMPDIR:-/tmp}/chronomac-buildapp.XXXXXX")"
trap 'rm -rf "$TMP_BUILD_ISO"' EXIT
CHRONOMAC_DB_PATH="$TMP_BUILD_ISO/flightbox.sqlite" \
    "$APP_BUNDLE/Contents/MacOS/$APP_NAME" --export-screenshots "$ROOT/docs" --lang en
CHRONOMAC_DB_PATH="$TMP_BUILD_ISO/flightbox.sqlite" \
    "$APP_BUNDLE/Contents/MacOS/$APP_NAME" --export-screenshots "$ROOT/docs" --lang zh

echo "✓ Built $APP_BUNDLE"
