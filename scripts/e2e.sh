#!/usr/bin/env bash
#
# e2e.sh — end-to-end test of the INSTALLED, RUNNING AutoSwitcher.
#
# Builds scripts/e2e/main.swift and runs it as a child process (it opens its
# own window and types into it with real key events), then prints the
# report. Takes ~1 minute; don't touch the keyboard
# or mouse meanwhile — the driver aborts if its window loses focus.
#
# Requirements: AutoSwitcher running with its permissions; the process
# that runs this script must be allowed to post events (Accessibility).
#
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/autoswitcher-e2e.XXXXXX")"
trap 'rm -rf "${WORK}"' EXIT

BIN="${WORK}/AutoSwitcherE2E"
swiftc -O -o "${BIN}" "${HERE}/scripts/e2e/main.swift"

if ! pgrep -x AutoSwitcher >/dev/null; then
    echo "AutoSwitcher is not running — nothing to test." >&2
    exit 2
fi
echo "Testing AutoSwitcher $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' /Applications/AutoSwitcher.app/Contents/Info.plist 2>/dev/null || echo '?')"

REPORT="${WORK}/report.txt"
"${BIN}" "${REPORT}" 2>/dev/null || true
cat "${REPORT}"
grep -q "failed" "${REPORT}" && grep -q "RESULT: .* 0 failed" "${REPORT}"
