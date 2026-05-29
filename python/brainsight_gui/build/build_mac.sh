#!/usr/bin/env bash
# build_mac.sh -- Build "Brainsight Monitor.app" + a .dmg installer.
#
# Run on macOS. PyInstaller cannot cross-compile.
#
#   cd python/brainsight_gui/build
#   bash build_mac.sh
#
# Output (relative to the repo root):
#   dist/Brainsight Monitor.app
#   dist/Brainsight Monitor.dmg

set -euo pipefail

APP_NAME="Brainsight Monitor"
ENTRY_SCRIPT="brainsight_gui/__main__.py"
DIST_DIR="dist"
BUILD_DIR="build_intermediate"

# ── Resolve paths ─────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"           # python/brainsight_gui/build
PKG_DIR="$(dirname "$SCRIPT_DIR")"                    # python/brainsight_gui
PYTHON_DIR="$(dirname "$PKG_DIR")"                    # python
REPO_ROOT="$(dirname "$PYTHON_DIR")"                  # repo root

cd "$PYTHON_DIR"   # PyInstaller resolves imports from here

# ── Resolve Python 3 ──────────────────────────────────────────────────────────
if command -v python3 >/dev/null 2>&1; then
    PY=python3
elif command -v python >/dev/null 2>&1; then
    PY=python
else
    echo "ERROR: no python3 found on PATH."
    echo "Install from https://www.python.org/downloads/macos/"
    exit 1
fi

# ── Ensure PyInstaller + Pillow are installed ────────────────────────────────
echo "==> Ensuring PyInstaller + Pillow are installed"
"$PY" -m pip install --quiet --upgrade pyinstaller pillow

# ── Generate the icon ─────────────────────────────────────────────────────────
echo "==> Generating app icon"
ICON_PNG="$SCRIPT_DIR/icon.png"
ICON_ICNS="$SCRIPT_DIR/icon.icns"
ICON_SET="$SCRIPT_DIR/icon.iconset"

"$PY" "$SCRIPT_DIR/generate_icon.py" "$ICON_PNG"

# Convert PNG -> ICNS via macOS native iconutil. Requires sips + iconutil
# which ship with macOS.
if command -v iconutil >/dev/null 2>&1 && command -v sips >/dev/null 2>&1; then
    echo "==> Converting icon.png to icon.icns"
    rm -rf "$ICON_SET"
    mkdir -p "$ICON_SET"
    sips -z 16 16     "$ICON_PNG" --out "$ICON_SET/icon_16x16.png"        > /dev/null
    sips -z 32 32     "$ICON_PNG" --out "$ICON_SET/icon_16x16@2x.png"     > /dev/null
    sips -z 32 32     "$ICON_PNG" --out "$ICON_SET/icon_32x32.png"        > /dev/null
    sips -z 64 64     "$ICON_PNG" --out "$ICON_SET/icon_32x32@2x.png"     > /dev/null
    sips -z 128 128   "$ICON_PNG" --out "$ICON_SET/icon_128x128.png"      > /dev/null
    sips -z 256 256   "$ICON_PNG" --out "$ICON_SET/icon_128x128@2x.png"   > /dev/null
    sips -z 256 256   "$ICON_PNG" --out "$ICON_SET/icon_256x256.png"      > /dev/null
    sips -z 512 512   "$ICON_PNG" --out "$ICON_SET/icon_256x256@2x.png"   > /dev/null
    sips -z 512 512   "$ICON_PNG" --out "$ICON_SET/icon_512x512.png"      > /dev/null
    cp "$ICON_PNG"    "$ICON_SET/icon_512x512@2x.png"
    iconutil -c icns "$ICON_SET" -o "$ICON_ICNS"
    rm -rf "$ICON_SET"
    ICON_FLAG=(--icon "$ICON_ICNS")
else
    echo "WARN: iconutil/sips not found; building without a custom icon."
    ICON_FLAG=()
fi

# ── Clean previous build outputs ──────────────────────────────────────────────
cd "$REPO_ROOT"
echo "==> Cleaning previous build artifacts"
rm -rf "$DIST_DIR" "$BUILD_DIR" "${APP_NAME}.spec"

# ── Run PyInstaller ───────────────────────────────────────────────────────────
echo "==> Building $APP_NAME.app with PyInstaller"
"$PY" -m PyInstaller \
    --windowed \
    --noconfirm \
    --clean \
    --name "$APP_NAME" \
    --paths "$PYTHON_DIR" \
    --workpath "$BUILD_DIR" \
    --distpath "$DIST_DIR" \
    "${ICON_FLAG[@]}" \
    --osx-bundle-identifier "com.lab.brainsight.monitor" \
    "$PYTHON_DIR/$ENTRY_SCRIPT"

APP_PATH="$DIST_DIR/$APP_NAME.app"
if [ ! -d "$APP_PATH" ]; then
    echo "ERROR: $APP_PATH was not produced"
    exit 1
fi
echo "==> Built: $APP_PATH"

# ── Build a .dmg for distribution ─────────────────────────────────────────────
echo "==> Creating .dmg installer"
DMG_PATH="$DIST_DIR/$APP_NAME.dmg"
STAGING="$DIST_DIR/dmg_staging"
rm -rf "$STAGING"
mkdir -p "$STAGING"
cp -R "$APP_PATH" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

rm -f "$DMG_PATH"
hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$STAGING" \
    -ov -format UDZO \
    "$DMG_PATH"

rm -rf "$STAGING"

echo ""
echo "Done."
echo "  App: $REPO_ROOT/$APP_PATH"
echo "  DMG: $REPO_ROOT/$DMG_PATH"
echo ""
echo "Distribute the .dmg to lab members:"
echo "  1. Double-click the .dmg in Finder"
echo "  2. Drag '$APP_NAME' into the Applications folder shortcut"
echo "  3. First launch: right-click the .app -> Open -> Open (bypasses unsigned warning)"
echo "     or run: xattr -dr com.apple.quarantine \"/Applications/$APP_NAME.app\""
