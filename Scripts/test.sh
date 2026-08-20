#!/usr/bin/env bash
#
# Run AURA's test suites on an iOS Simulator.
#
#   ./Scripts/test.sh
#
# Picks the first available iPhone simulator automatically, so there is no device name to look up.
#
# Output:
#   build/test-results.txt   failures and the build errors that prevented them, one per line
#   build/test-full.log      the complete xcodebuild output

set -uo pipefail

PROJECT="AURA.xcodeproj"
SCHEME="AURA"
FULL_LOG="build/test-full.log"
REPORT="build/test-results.txt"

cd "$(dirname "$0")/.." || exit 1
mkdir -p build

if ! command -v xcodebuild >/dev/null 2>&1; then
    echo "xcodebuild not found. See Scripts/build.sh for setup instructions."
    exit 1
fi

# --- Pick a simulator -------------------------------------------------------------------------

# Matching by UDID rather than by name: device names change between Xcode releases ("iPhone 17 Pro"
# will not exist forever), but "the first booted-capable iPhone" is stable.
UDID=$(xcrun simctl list devices available \
    | grep -E "iPhone" \
    | head -1 \
    | sed -E 's/.*\(([0-9A-Fa-f-]{36})\).*/\1/')

if [ -z "$UDID" ]; then
    cat <<'EOF'
No iPhone simulator is available.

Open Xcode, then: Xcode → Settings → Components, and install an iOS Simulator runtime.
Or from the command line:

    xcodebuild -downloadPlatform iOS

Then run this script again.
EOF
    exit 1
fi

DEVICE_NAME=$(xcrun simctl list devices available | grep "$UDID" | sed -E 's/^ *(.*) \(.*/\1/')
echo "==> Simulator: $DEVICE_NAME"
echo "==> Running tests (this builds first, so allow a few minutes)"
echo

# --- Test -------------------------------------------------------------------------------------

# Split deliberately into build-for-testing and test-without-building.
#
# `xcodebuild test` does both in one opaque step, which meant a suite that grew from four minutes to over
# forty gave no way to tell whether the time was compilation or execution. Four CI runs were spent
# guessing at that. Two invocations, each timed, answer it in the first line of output — and the split
# costs nothing, because the work is identical either way.
COMPILE_START=$(date +%s)
xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -destination "id=$UDID" \
    -configuration Debug \
    CODE_SIGNING_ALLOWED=NO \
    build-for-testing \
    > "$FULL_LOG" 2>&1
COMPILE_STATUS=$?
echo "==> Compiling the test bundle took $(( $(date +%s) - COMPILE_START ))s (status $COMPILE_STATUS)"

if [ "$COMPILE_STATUS" -ne 0 ]; then
    # Nothing ran, so the report below will show compile errors rather than failures.
    STATUS=$COMPILE_STATUS
else
    RUN_START=$(date +%s)
    xcodebuild \
        -project "$PROJECT" \
        -scheme "$SCHEME" \
        -destination "id=$UDID" \
        -configuration Debug \
        CODE_SIGNING_ALLOWED=NO \
        test-without-building \
        >> "$FULL_LOG" 2>&1
    STATUS=$?
    echo "==> Running the tests took $(( $(date +%s) - RUN_START ))s (status $STATUS)"
fi

# --- Report -----------------------------------------------------------------------------------

# Compile errors and test failures both matter, and a compile error means the tests never ran at all
# — so both are collected rather than only the failures.
# `CoreData: error:` lines are excluded deliberately. SwiftData logs a wall of them while probing
# store locations in the simulator, then reports "Recovery attempt ... was successful!" — they are
# noise from a sequence that worked, and they buried the one real failure in the last run.
# `appintentsmetadataprocessor` is excluded for the same reason it is in build.sh.
grep -E "(error: |✘|failed after|Testing failed)" "$FULL_LOG" \
    | grep -v "CoreData: error:" \
    | grep -v "appintentsmetadataprocessor" \
    | sed -E 's#^.*/(AURA/|AURATests/)#\1#' \
    | sort -u \
    > "$REPORT"

# Swift Testing prints its own authoritative total — "Test run with N tests passed after ..." — so parse
# that line instead of counting ticks.
#
# The previous version counted lines matching `✔`, which also matches one line per *suite* plus the run
# summary. That inflates the figure and, worse, makes it drift for reasons unrelated to the tests: the
# same unchanged suite reported 210 one run and 241 another. Both numbers were quoted as a test count in
# the README before the discrepancy was noticed. A number nobody can reproduce is worse than no number.
TEST_COUNT=$(grep -oE "Test run with [0-9]+ test" "$FULL_LOG" | tail -1 | grep -oE "[0-9]+")
SUITE_COUNT=$(grep -cE "✔ Suite " "$FULL_LOG")

echo
if [ "$STATUS" -eq 0 ]; then
    if [ -n "${TEST_COUNT:-}" ]; then
        echo "==> TESTS PASSED  ($TEST_COUNT tests in ${SUITE_COUNT:-0} suites)"
    else
        # Reaching here means xcodebuild succeeded but the summary line was not found — report that
        # honestly rather than printing a zero that looks like a real count.
        echo "==> TESTS PASSED  (count unavailable — no Swift Testing summary line in $FULL_LOG)"
    fi
    echo
    echo "That is the whole Phase 1 and Phase 2 acceptance bar. Tell Claude and it will start Phase 3."
else
    echo "==> TESTS FAILED"
    echo
    echo "Details are in:  $REPORT"
    echo
    head -20 "$REPORT" | sed 's/^/    /'
    echo
    echo "To copy the whole report to your clipboard:"
    echo "    cat $REPORT | pbcopy"
fi

exit "$STATUS"
