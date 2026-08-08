#!/usr/bin/env bash
#
# Capture a screenshot of every screen in AURA, on an iOS Simulator.
#
#   ./Scripts/screenshots.sh
#
# How it works: the app has a debug-only launch flag (`-AURAScreenshotScreen <name>`) that renders one
# screen directly, with seeded data. So each screenshot is a fresh launch rather than a simulated tap —
# fast, deterministic, and needing no UI-test target.
#
# The screen list is read out of the Swift enum below rather than duplicated here, so adding a screen in
# one place is enough.
#
# Output:
#   docs/screenshots/*.png    the images
#   docs/SCREENSHOTS.md       an index that renders on github.com, including from a phone

set -uo pipefail

PROJECT="AURA.xcodeproj"
SCHEME="AURA"
BUNDLE_ID="com.aura.assistant"
DERIVED="build/screenshot-dd"
APP="$DERIVED/Build/Products/Debug-iphonesimulator/AURA.app"
OUT="docs/screenshots"
SOURCE="AURA/Core/Support/ScreenshotMode.swift"
LOG="build/screenshots.log"

cd "$(dirname "$0")/.." || exit 1
mkdir -p "$OUT" build

if ! command -v xcodebuild >/dev/null 2>&1; then
    echo "xcodebuild not found. See Scripts/build.sh for setup instructions."
    exit 1
fi

# --- Screens, read from the Swift enum ---------------------------------------------------------

SCREENS=$(sed -n '/enum Screen: String, CaseIterable {/,/^    }/p' "$SOURCE" \
    | grep -E '^\s+case ' \
    | sed -E 's/^[[:space:]]*case //' \
    | tr -d ' ')

if [ -z "$SCREENS" ]; then
    echo "!!! Could not read the screen list from $SOURCE."
    exit 1
fi

SCREEN_COUNT=$(echo "$SCREENS" | wc -l | tr -d ' ')
echo "==> $SCREEN_COUNT screens to capture"

# --- Simulator ---------------------------------------------------------------------------------

# Matched by UDID rather than name: device names change with every Xcode release.
UDID=$(xcrun simctl list devices available \
    | grep -E "iPhone" \
    | head -1 \
    | sed -E 's/.*\(([0-9A-Fa-f-]{36})\).*/\1/')

if [ -z "$UDID" ]; then
    echo "!!! No iPhone simulator available. Run: xcodebuild -downloadPlatform iOS"
    exit 1
fi

DEVICE_NAME=$(xcrun simctl list devices available | grep "$UDID" | sed -E 's/^ *(.*) \(.*/\1/')
echo "==> Simulator: $DEVICE_NAME"

# --- Build -------------------------------------------------------------------------------------

echo "==> Building for the simulator"
xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -destination "id=$UDID" \
    -configuration Debug \
    -derivedDataPath "$DERIVED" \
    CODE_SIGNING_ALLOWED=NO \
    build \
    > "$LOG" 2>&1
BUILD_STATUS=$?

if [ "$BUILD_STATUS" -ne 0 ] || [ ! -d "$APP" ]; then
    echo "!!! Build failed, or $APP was not produced. Tail of $LOG:"
    tail -25 "$LOG"
    exit 1
fi

# --- Boot and install --------------------------------------------------------------------------

echo "==> Booting"
xcrun simctl boot "$UDID" >/dev/null 2>&1 || true
xcrun simctl bootstatus "$UDID" -b >/dev/null 2>&1 || true

# A fixed status bar keeps the images comparable between runs — otherwise every screenshot differs by
# its clock and a visual diff is useless.
xcrun simctl status_bar "$UDID" override \
    --time "9:41" \
    --batteryState charged \
    --batteryLevel 100 \
    --cellularBars 4 \
    --wifiBars 3 >/dev/null 2>&1 || true

echo "==> Installing"
xcrun simctl uninstall "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
if ! xcrun simctl install "$UDID" "$APP"; then
    echo "!!! Install failed."
    exit 1
fi

# --- Capture -----------------------------------------------------------------------------------

capture() {
    local screen="$1"
    local filename="$2"
    local appearance="${3:-light}"

    xcrun simctl ui "$UDID" appearance "$appearance" >/dev/null 2>&1 || true
    xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true

    if ! xcrun simctl launch "$UDID" "$BUNDLE_ID" -AURAScreenshotScreen "$screen" >/dev/null 2>&1; then
        echo "    !! launch failed for $screen"
        return 1
    fi

    # The seeded store is built asynchronously on appear, so the first frame is deliberately blank.
    # Waiting is what makes the screenshot show real content.
    sleep 4
    xcrun simctl io "$UDID" screenshot --type=png "$OUT/$filename.png" >/dev/null 2>&1
}

rm -f "$OUT"/*.png
INDEX=0
CAPTURED=0

while IFS= read -r screen; do
    [ -z "$screen" ] && continue
    INDEX=$((INDEX + 1))
    NAME=$(printf "%02d-%s" "$INDEX" "$screen")
    printf "    [%02d/%s] %s\n" "$INDEX" "$SCREEN_COUNT" "$screen"
    if capture "$screen" "$NAME" light; then
        CAPTURED=$((CAPTURED + 1))
    fi
done <<< "$SCREENS"

# A few in dark mode. Not all of them — the point is to prove the palette holds, and doubling every
# image would make the index tedious to scroll on a phone.
for screen in home conversation memoryHome privacy; do
    printf "    [dark] %s\n" "$screen"
    capture "$screen" "dark-$screen" dark && CAPTURED=$((CAPTURED + 1))
done

xcrun simctl ui "$UDID" appearance light >/dev/null 2>&1 || true
xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true

echo
echo "==> Captured $CAPTURED image(s) into $OUT"

# --- Index -----------------------------------------------------------------------------------

{
    echo "# AURA — screens"
    echo
    echo "Captured automatically by \`Scripts/screenshots.sh\` on every CI run."
    echo "Device: **$DEVICE_NAME**. Status bar is pinned to 9:41 so images stay comparable between runs."
    echo
    echo "The data is seeded, using the specification's own example: the assistant is called **Nova**,"
    echo "**Blake** is the user's son studying mechanical engineering at Tennessee, and the garage"
    echo "renovation is on hold until October."
    echo
    echo "> The conversation screen shows a canned reply from a mock provider. A simulator has no Apple"
    echo "> Intelligence, so these images cannot show the real on-device model answering."
    echo
    echo "## Light"
    echo
    for file in "$OUT"/[0-9]*.png; do
        [ -f "$file" ] || continue
        base=$(basename "$file" .png)
        title=$(echo "$base" | sed -E 's/^[0-9]+-//')
        echo "### $title"
        echo
        echo "<img src=\"screenshots/$(basename "$file")\" width=\"320\" alt=\"$title\">"
        echo
    done

    if ls "$OUT"/dark-*.png >/dev/null 2>&1; then
        echo "## Dark"
        echo
        for file in "$OUT"/dark-*.png; do
            [ -f "$file" ] || continue
            base=$(basename "$file" .png)
            title=$(echo "$base" | sed -E 's/^dark-//')
            echo "### $title"
            echo
            echo "<img src=\"screenshots/$(basename "$file")\" width=\"320\" alt=\"$title dark\">"
            echo
        done
    fi
} > docs/SCREENSHOTS.md

echo "==> Wrote docs/SCREENSHOTS.md"

if [ "$CAPTURED" -eq 0 ]; then
    echo "!!! Nothing was captured."
    exit 1
fi
