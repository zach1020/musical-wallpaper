#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

APP_NAME="MusicalWallpaper"
CONFIG="${1:-release}"
DIST_DIR="$ROOT_DIR/dist"
STANDALONE_DIR="$DIST_DIR/${APP_NAME}-standalone"
APP_DIR="$DIST_DIR/${APP_NAME}.app"

if [[ "$CONFIG" != "release" && "$CONFIG" != "debug" ]]; then
  echo "Usage: $0 [release|debug]"
  exit 1
fi

echo "→ Building $APP_NAME ($CONFIG)..."
swift build -c "$CONFIG"

EXECUTABLE_PATH="$(find "$ROOT_DIR/.build" -type f -path "*/$CONFIG/$APP_NAME" | head -n 1)"
if [[ -z "$EXECUTABLE_PATH" ]]; then
  echo "✗ Could not locate built executable for $APP_NAME"
  exit 1
fi

RESOURCE_BUNDLE_PATH="$(find "$ROOT_DIR/.build" -type d -path "*/$CONFIG/${APP_NAME}_*.bundle" | head -n 1 || true)"

rm -rf "$STANDALONE_DIR" "$APP_DIR"
mkdir -p "$STANDALONE_DIR" "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

cp "$EXECUTABLE_PATH" "$STANDALONE_DIR/$APP_NAME"
chmod +x "$STANDALONE_DIR/$APP_NAME"

cp "$EXECUTABLE_PATH" "$APP_DIR/Contents/MacOS/$APP_NAME"
chmod +x "$APP_DIR/Contents/MacOS/$APP_NAME"

if [[ -n "$RESOURCE_BUNDLE_PATH" ]]; then
  cp -R "$RESOURCE_BUNDLE_PATH" "$STANDALONE_DIR/"
  cp -R "$RESOURCE_BUNDLE_PATH" "$APP_DIR/Contents/Resources/"
fi

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundleDisplayName</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>com.zachbohl.$APP_NAME</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0</string>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST

if command -v ditto >/dev/null 2>&1; then
  ditto -c -k --keepParent "$APP_DIR" "$DIST_DIR/${APP_NAME}.app.zip"
fi

echo "✓ Packaged outputs:"
echo "  - $STANDALONE_DIR"
echo "  - $APP_DIR"
if [[ -f "$DIST_DIR/${APP_NAME}.app.zip" ]]; then
  echo "  - $DIST_DIR/${APP_NAME}.app.zip"
fi
