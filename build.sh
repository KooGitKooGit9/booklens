#!/bin/bash
# Builds BookLens.app, signs it, and installs it to /Applications.
#   ./build.sh            build + install + launch
#   ./build.sh --no-open  build + install only
#   ./build.sh --test     run the test suite first
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="BookLens"
DIST="dist"
APP="$DIST/$APP_NAME.app"
INSTALL_DIR="${BOOKLENS_INSTALL_DIR:-/Applications}"
OPEN=1
for arg in "$@"; do
  case "$arg" in
    --no-open) OPEN=0 ;;
    --test) swift test ;;
  esac
done

echo "▸ Building (release)…"
swift build -c release --product BookLens
BIN="$(swift build -c release --show-bin-path)/BookLens"

echo "▸ Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# A stable signing identity keeps the Screen Recording permission across rebuilds.
IDENTITY="${BOOKLENS_SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
  IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | grep -E '"(Developer ID Application|Apple Development)' | head -1 | awk '{print $2}' || true)"
fi
if [ -n "$IDENTITY" ]; then
  echo "▸ Signing with $IDENTITY"
  codesign --force --options runtime --timestamp=none --sign "$IDENTITY" "$APP"
else
  echo "▸ No signing certificate found; using ad-hoc signature (Screen Recording permission resets on each rebuild)."
  codesign --force --sign - "$APP"
fi
codesign --verify --strict "$APP"

echo "▸ Installing to $INSTALL_DIR"
if pgrep -x "$APP_NAME" >/dev/null; then
  pkill -x "$APP_NAME" || true
  sleep 0.5
fi
rm -rf "$INSTALL_DIR/$APP_NAME.app"
cp -R "$APP" "$INSTALL_DIR/"

if [ "$OPEN" = 1 ]; then
  open "$INSTALL_DIR/$APP_NAME.app"
fi
echo "✓ $INSTALL_DIR/$APP_NAME.app"
