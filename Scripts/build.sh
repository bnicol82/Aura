#!/usr/bin/env bash
#
# Build AURA for the iOS Simulator and write a compact error report.
#
#   ./Scripts/build.sh
#
# No Apple Developer account, signing certificate or team ID is needed — a Simulator build skips
# code signing entirely. That is deliberate: the point of this script is to find compile errors, and
# provisioning is a separate problem you only have to solve to run on a physical iPhone.
#
# Output:
#   build/errors.txt    every unique error and warning, one per line — this is the file to share
#   build/full.log      the complete xcodebuild output, for when a message needs more context

set -uo pipefail

PROJECT="AURA.xcodeproj"
SCHEME="AURA"
FULL_LOG="build/full.log"
REPORT="build/errors.txt"

cd "$(dirname "$0")/.." || exit 1
mkdir -p build

# --- Preflight -------------------------------------------------------------------------------

if ! command -v xcodebuild >/dev/null 2>&1; then
    cat <<'EOF'
xcodebuild was not found.

Install Xcode from the Mac App Store (search "Xcode" — it is a large download), open it once so it
can install its components, then point the command-line tools at it:

    sudo xcode-select -s /Applications/Xcode.app

Then run this script again.
EOF
    exit 1
fi

XCODE_VERSION=$(xcodebuild -version 2>/dev/null | head -1)
echo "==> $XCODE_VERSION"

XCODE_MAJOR=$(echo "$XCODE_VERSION" | sed -E 's/Xcode ([0-9]+).*/\1/')
if [ -n "$XCODE_MAJOR" ] && [ "$XCODE_MAJOR" -lt 26 ] 2>/dev/null; then
    echo "!!! AURA targets iOS 26 and needs Xcode 26 or later. This is Xcode $XCODE_MAJOR."
    echo "    The build will fail on the FoundationModels and Speech imports until Xcode is updated."
    echo
fi

if [ ! -d "$PROJECT" ]; then
    echo "!!! $PROJECT not found. Run this from inside the repository."
    exit 1
fi

# --- Build ------------------------------------------------------------------------------------

echo "==> Building $SCHEME for the iOS Simulator (this takes a few minutes the first time)"
echo

xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -destination 'generic/platform=iOS Simulator' \
    -configuration Debug \
    CODE_SIGNING_ALLOWED=NO \
    build \
    > "$FULL_LOG" 2>&1
STATUS=$?

# --- Report -----------------------------------------------------------------------------------

# Absolute paths are trimmed to repo-relative so the report is readable and portable.
grep -E "(error|warning): " "$FULL_LOG" \
    | sed -E 's#^.*/(AURA/|AURATests/)#\1#' \
    | sort -u \
    > "$REPORT"

ERROR_COUNT=$(grep -c "error: " "$REPORT" 2>/dev/null)
ERROR_COUNT=${ERROR_COUNT:-0}
WARNING_COUNT=$(grep -c "warning: " "$REPORT" 2>/dev/null)
WARNING_COUNT=${WARNING_COUNT:-0}

echo
if [ "$STATUS" -eq 0 ]; then
    echo "==> BUILD SUCCEEDED  ($WARNING_COUNT warning(s))"
    echo
    echo "Next: run the tests."
    echo "    ./Scripts/test.sh"
else
    echo "==> BUILD FAILED  ($ERROR_COUNT error(s), $WARNING_COUNT warning(s))"
    echo
    echo "The errors are in:  $REPORT"
    echo
    echo "First few:"
    grep "error: " "$REPORT" | head -10 | sed 's/^/    /'
    echo
    echo "To copy the whole report to your clipboard:"
    echo "    cat $REPORT | pbcopy"
fi

# The project file itself failing to parse is a distinct problem with a distinct fix, so it is
# called out rather than left buried among the compile errors.
if grep -qE "(cannot be opened because the project file cannot be parsed|does not contain a scheme named)" "$FULL_LOG"; then
    cat <<'EOF'

!!! Xcode could not read AURA.xcodeproj.

    That project file was hand-authored without Xcode, so this is a known possibility. Regenerate it
    from the checked-in declarative spec:

        brew install xcodegen
        xcodegen generate

    Then run this script again. Nothing else in the repository needs to change.
EOF
fi

exit "$STATUS"
