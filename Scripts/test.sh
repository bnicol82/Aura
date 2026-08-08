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

xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -destination "id=$UDID" \
    -configuration Debug \
    CODE_SIGNING_ALLOWED=NO \
    test \
    > "$FULL_LOG" 2>&1
STATUS=$?

# --- Report -----------------------------------------------------------------------------------

# Compile errors and test failures both matter, and a compile error means the tests never ran at all
# — so both are collected rather than only the failures.
grep -E "(error: |Test [Cc]ase.*failed|✘|failed after|Testing failed)" "$FULL_LOG" \
    | sed -E 's#^.*/(AURA/|AURATests/)#\1#' \
    | sort -u \
    > "$REPORT"

PASSED=$(grep -cE "✔|passed after" "$FULL_LOG" 2>/dev/null)
PASSED=${PASSED:-0}

echo
if [ "$STATUS" -eq 0 ]; then
    echo "==> TESTS PASSED  ($PASSED test(s) recorded)"
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
