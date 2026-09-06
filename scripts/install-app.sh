#!/bin/bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." >/dev/null 2>&1 && pwd -P)"
CONFIGURATION="Release"
SOURCE="$ROOT/build/DerivedData/Build/Products/$CONFIGURATION/AI Camera.app"
DESTINATION="/Applications/AI Camera.app"
EXPECTED_ID="ai.kortexa.aicamera"
EXPECTED_EXTENSION_ID="ai.kortexa.aicamera.camera-extension"

verify_signed_product() {
    app="$1"
    extension="$app/Contents/Library/SystemExtensions/$EXPECTED_EXTENSION_ID.systemextension"
    team=$(/usr/bin/codesign -d --verbose=4 "$app" 2>&1 | /usr/bin/sed -n 's/^TeamIdentifier=//p')
    extension_team=$(/usr/bin/codesign -d --verbose=4 "$extension" 2>&1 | /usr/bin/sed -n 's/^TeamIdentifier=//p')
    test "$team" = "$extension_team"
    case "$team" in ''|*[!A-Za-z0-9-]*) return 1 ;; esac
    host_requirement="identifier \"$EXPECTED_ID\" and anchor apple generic and certificate leaf[subject.OU] = \"$team\" and entitlement[\"com.apple.security.get-task-allow\"] absent"
    extension_requirement="identifier \"$EXPECTED_EXTENSION_ID\" and anchor apple generic and certificate leaf[subject.OU] = \"$team\" and entitlement[\"com.apple.security.get-task-allow\"] absent"
    /usr/bin/codesign --verify --deep --strict "$app"
    /usr/bin/codesign --verify --strict -R "=$host_requirement" "$app"
    /usr/bin/codesign --verify --strict -R "=$extension_requirement" "$extension"
}

CONFIGURATION="$CONFIGURATION" SIGNING=1 "$ROOT/scripts/build.sh"
verify_signed_product "$SOURCE"
test "$(plutil -extract CFBundleIdentifier raw "$SOURCE/Contents/Info.plist")" = "$EXPECTED_ID"

# Stop only this application before replacing its bundle. It is fine when it is not running.
osascript -e 'tell application id "ai.kortexa.aicamera" to quit' >/dev/null 2>&1 || true
sleep 1

# The privileged transaction invalidates the prior generation marker before the app swap and
# confirms that no old AI Camera process survives before committing the new marker.
INSTALL_COMMAND="$(osascript "$ROOT/scripts/installer-transaction.applescript" \
    "$SOURCE" "$DESTINATION" "$EXPECTED_ID" "$EXPECTED_EXTENSION_ID" render)"

if sudo -n true >/dev/null 2>&1; then
    /usr/bin/printf '%s\n' "$INSTALL_COMMAND" | sudo -n /bin/sh
else
    osascript \
        -e 'on run argv' \
        -e 'do shell script (item 1 of argv) with administrator privileges' \
        -e 'end run' \
        "$INSTALL_COMMAND"
fi
open "$DESTINATION"
