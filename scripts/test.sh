#!/usr/bin/env bash
#
# test.sh — compile the detection core together with scripts/tests/main.swift
# and run it. Prints every check; exits non-zero if any check fails.
#
#   ./scripts/test.sh            # all checks
#   ./scripts/test.sh --quiet    # only failures + summary
#
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${HERE}/Sources/AutoSwitcher"
OUT="$(mktemp -d "${TMPDIR:-/tmp}/autoswitcher-tests.XXXXXX")"
trap 'rm -rf "${OUT}"' EXIT

swiftc -O -o "${OUT}/detector_tests" \
    "${SRC}/Core/LayoutDetector.swift" \
    "${SRC}/Core/WordChecker.swift" \
    "${SRC}/Core/LayoutManager.swift" \
    "${SRC}/Core/SelectionConverter.swift" \
    "${SRC}/Core/AutoCorrector.swift" \
    "${SRC}/Core/UpdateChecker.swift" \
    "${SRC}/Models/Stats.swift" \
    "${SRC}/Models/AppSettings.swift" \
    "${SRC}/Models/Localization.swift" \
    "${SRC}/Diagnostics.swift" \
    "${HERE}/scripts/tests/main.swift"

status=0
"${OUT}/detector_tests" > "${OUT}/report.txt" 2>/dev/null || status=$?

if [[ "${1:-}" == "--quiet" ]]; then
    grep -E "FAIL|got:|PASSED" "${OUT}/report.txt" || true
else
    cat "${OUT}/report.txt"
fi
exit "${status}"
