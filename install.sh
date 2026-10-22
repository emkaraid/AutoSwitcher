#!/usr/bin/env bash
#
# install.sh — one-shot installer for AutoSwitcher.
#
# Strategy: build the app once, move it to /Applications, reset the
# stale TCC entries, then launch from /Applications. After this you
# stop rebuilding — permissions stay granted to that path forever.
#
# Why: macOS Sequoia keys TCC entries (Accessibility / Input Monitoring)
# by the binary's cdhash. Every rebuild changes the cdhash → TCC sees a
# "new app" → asks for permissions again. The only way around it is a
# paid Apple Developer ID code-signing certificate. By installing once
# and not rebuilding, we sidestep the rebuild loop entirely.
#
# If you DO need to update the code:
#   1. Run `./install.sh --force` to overwrite the existing installation.
#   2. Re-grant Accessibility AND Input Monitoring in System Settings.
#   3. The app will auto-restart when Input Monitoring becomes granted.
#
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
INSTALLED="/Applications/AutoSwitcher.app"
BUNDLE_ID="com.autoswitcher.app"
FORCE=0

for arg in "$@"; do
    case "$arg" in
        --force|-f) FORCE=1 ;;
    esac
done

# ---------- 0. Refuse to overwrite a working install silently --------
if [[ -d "$INSTALLED" && "$FORCE" -ne 1 ]]; then
    echo
    echo "==> AutoSwitcher.app is already installed at:"
    echo "    $INSTALLED"
    echo
    echo "If it's working — DON'T rebuild. macOS will lose the granted"
    echo "permissions because the cdhash changes on every build, and"
    echo "you'll have to re-add it to Accessibility AND Input Monitoring."
    echo
    echo "If you really want to overwrite it, run:"
    echo "    ./install.sh --force"
    echo
    exit 1
fi

# ---------- 1. Build ---------------------------------------------------
echo "==> Building release"
cd "$HERE"
CLEAN=1 ./build.sh release | grep -v -e "^==>" -e "^Tip:" || true
# We re-print the headlines below so the user sees the important steps.

if [[ ! -d "$HERE/AutoSwitcher.app" ]]; then
    echo "ERROR: build did not produce AutoSwitcher.app at $HERE" >&2
    exit 1
fi

# ---------- 2. Kill any running copy -----------------------------------
echo "==> Killing any running copies"
osascript -e 'quit app "AutoSwitcher"' 2>/dev/null || true
killall AutoSwitcher 2>/dev/null || true
sleep 1

# ---------- 3. Move to /Applications -----------------------------------
echo "==> Installing to ${INSTALLED}"
if [[ -d "$INSTALLED" ]]; then
    rm -rf "$INSTALLED"
fi
cp -R "$HERE/AutoSwitcher.app" "$INSTALLED"
xattr -cr "$INSTALLED" 2>/dev/null || true

# Delete the source bundle from Desktop so the user can't accidentally
# add the wrong path to Settings → Accessibility / Input Monitoring.
# This is the #1 reason permissions appear "granted" but don't apply.
echo "==> Removing development copy at $HERE/AutoSwitcher.app to avoid path confusion"
rm -rf "$HERE/AutoSwitcher.app"

# Print the signing identity + cdhash so the user can verify the entry
# in Settings is for THIS binary.
echo
echo "==> Code signature of the installed binary:"
codesign -dv --verbose=2 "$INSTALLED" 2>&1 | sed 's/^/    /'
echo

# ---------- 4. Reset stale TCC entries (ad-hoc builds only) ------------
# An ad-hoc signature's designated requirement is its cdhash, so the old
# TCC entry can never match the new build and only gets in the way. A
# build signed with the stable "AutoSwitcher Local Dev" identity matches
# the existing entry — resetting it would throw away working permissions.
if codesign -d -r- "$INSTALLED" 2>&1 | grep -q 'designated => cdhash'; then
    echo "==> Ad-hoc build: resetting old TCC entries for ${BUNDLE_ID}"
    tccutil reset Accessibility "$BUNDLE_ID" 2>/dev/null || true
    tccutil reset ListenEvent    "$BUNDLE_ID" 2>/dev/null || true
else
    echo "==> Stable signature: keeping existing permissions"
fi

# ---------- 5. Launch from /Applications -------------------------------
echo "==> Launching"
open "$INSTALLED"
sleep 1

# ---------- 6. Open both Settings panes for the user -------------------
echo
echo "================================================================"
echo "  AutoSwitcher is now installed at /Applications/AutoSwitcher.app"
echo "  and running."
echo
echo "  Now do this ONCE — and never again unless you rebuild:"
echo
echo "  1) System Settings will open to Privacy & Security →"
echo "     Accessibility. Enable AutoSwitcher (toggle ON)."
echo
echo "  2) Then open Privacy & Security → Input Monitoring and"
echo "     enable AutoSwitcher there too."
echo
echo "  The app auto-restarts as soon as Input Monitoring is granted."
echo
echo "  Diagnostics file:  ~/Library/Logs/AutoSwitcher/debug.log"
echo "  Live view:         tail -f ~/Library/Logs/AutoSwitcher/debug.log"
echo "================================================================"
echo

# Open the Accessibility pane immediately so the user can grant it now.
open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
