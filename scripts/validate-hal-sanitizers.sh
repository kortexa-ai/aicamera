#!/bin/bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." >/dev/null 2>&1 && pwd -P)"
cd "$ROOT"

SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/aicamera-hal-sanitizers.XXXXXX")"
cleanup() {
    rm -rf "${TMP_ROOT:?}"
}
trap cleanup EXIT HUP INT TERM

run_variant() {
    variant="$1"
    sanitizers="$2"
    driver="$TMP_ROOT/AICameraAudioDriver-$variant.driver"
    harness="$TMP_ROOT/aicamera-audio-driver-harness-$variant"

    mkdir -p "$driver/Contents/MacOS"
    cp Resources/AudioDriver/Info.plist "$driver/Contents/Info.plist"
    plutil -replace CFBundleExecutable -string AICameraAudioDriver "$driver/Contents/Info.plist"
    plutil -replace LSMinimumSystemVersion -string 14.0 "$driver/Contents/Info.plist"

    xcrun --sdk macosx clang \
        -std=c11 -fblocks -g -O1 "-fsanitize=$sanitizers" \
        -isysroot "$SDKROOT" \
        Sources/AICameraAudioDriver/AICameraAudioDriver.c \
        -bundle -framework CoreAudio -framework CoreFoundation \
        -o "$driver/Contents/MacOS/AICameraAudioDriver"

    xcrun --sdk macosx clang \
        -std=c11 -g -O1 "-fsanitize=$sanitizers" \
        -isysroot "$SDKROOT" \
        Tests/AICameraAudioDriverTests/LoopbackHarness.c \
        -framework CoreAudio -framework CoreFoundation \
        -o "$harness"

    if test "$variant" = asan; then
        ASAN_OPTIONS='detect_leaks=0:halt_on_error=1' \
        UBSAN_OPTIONS='halt_on_error=1' \
            "$harness" "$driver"
    else
        TSAN_OPTIONS='halt_on_error=1' "$harness" "$driver"
    fi
}

# macOS AddressSanitizer does not implement leak detection.
run_variant asan address,undefined,float-cast-overflow
run_variant tsan thread

echo "HAL sanitizer validation passed. No driver was installed."
