#!/usr/bin/env bash
#
# package.sh — build a release AutoSwitcher.app and wrap it into a
# distributable DMG with the classic "drag to Applications" layout.
#
# Output: dist/AutoSwitcher-<version>.dmg
#
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
cd "${HERE}"

APP_NAME="AutoSwitcher"
PLIST="Sources/AutoSwitcher/Resources/Info.plist"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${PLIST}")"

# ---------- 1. Build the app bundle -------------------------------------
./build.sh release

if [[ ! -d "${APP_NAME}.app" ]]; then
    echo "error: build did not produce ${APP_NAME}.app" >&2
    exit 1
fi

# ---------- 2. Stage the DMG contents -----------------------------------
# Stage in /tmp, not inside the (possibly iCloud-synced) project folder:
# the file provider re-attaches FinderInfo xattrs that would end up baked
# into the DMG and break the code signature for downloaders.
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/autoswitcher-dmg.XXXXXX")"
trap 'rm -rf "${STAGE}"' EXIT
rm -rf dist
mkdir -p dist
ditto "${APP_NAME}.app" "${STAGE}/${APP_NAME}.app"
xattr -cr "${STAGE}/${APP_NAME}.app" 2>/dev/null || true
ln -s /Applications "${STAGE}/Applications"

# ---------- 3. Create the DMG -------------------------------------------
DMG="dist/${APP_NAME}-${VERSION}.dmg"
hdiutil create \
    -volname "${APP_NAME}" \
    -srcfolder "${STAGE}" \
    -ov -format UDZO \
    "${DMG}"

echo
echo "==> Done: ${HERE}/${DMG}"
echo "    Users install by opening the DMG and dragging ${APP_NAME}"
echo "    onto the Applications shortcut."
