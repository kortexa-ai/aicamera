#!/bin/bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." >/dev/null 2>&1 && pwd -P)"
SOURCE="$ROOT/build/DerivedData/Build/Products/Debug/AI Camera.app"
DESTINATION="/Applications/AI Camera.app"
EXPECTED_ID="ai.kortexa.aicamera"

SIGNING=1 "$ROOT/scripts/build.sh"
codesign --verify --deep --strict --verbose=2 "$SOURCE"
test "$(plutil -extract CFBundleIdentifier raw "$SOURCE/Contents/Info.plist")" = "$EXPECTED_ID"

# Stop only this application before replacing its bundle. It is fine when it is not running.
osascript -e 'tell application id "ai.kortexa.aicamera" to quit' >/dev/null 2>&1 || true
sleep 1

osascript - "$SOURCE" "$DESTINATION" "$EXPECTED_ID" <<'APPLESCRIPT'
on run argv
    set sourcePath to item 1 of argv
    set destinationPath to item 2 of argv
    set expectedID to item 3 of argv
    set commandText to "set -eu; src=" & quoted form of sourcePath & "; dst=" & quoted form of destinationPath & "; expected=" & quoted form of expectedID & "; tmp=\"${dst}.installing\"; bak=\"${dst}.backup\"; test -n \"$dst\"; test \"$dst\" != /; actual=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \"$src/Contents/Info.plist\"); test \"$actual\" = \"$expected\"; /usr/bin/codesign --verify --deep --strict \"$src\"; if test -e \"$dst\"; then installed=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \"$dst/Contents/Info.plist\"); test \"$installed\" = \"$expected\"; fi; /bin/rm -rf \"$tmp\" \"$bak\"; /usr/bin/ditto \"$src\" \"$tmp\"; /usr/bin/codesign --verify --deep --strict \"$tmp\"; had=0; if test -e \"$dst\"; then /bin/mv \"$dst\" \"$bak\"; had=1; fi; if /bin/mv \"$tmp\" \"$dst\"; then /bin/rm -rf \"$bak\"; else if test \"$had\" = 1; then /bin/mv \"$bak\" \"$dst\"; fi; exit 1; fi"
    do shell script commandText with administrator privileges
end run
APPLESCRIPT
open "$DESTINATION"
