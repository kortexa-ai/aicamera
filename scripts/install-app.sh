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
INSTALL_COMMAND="$(osascript - "$SOURCE" "$DESTINATION" "$EXPECTED_ID" "$EXPECTED_EXTENSION_ID" render <<'APPLESCRIPT'
on run argv
    set sourcePath to item 1 of argv
    set destinationPath to item 2 of argv
    set expectedID to item 3 of argv
    set expectedExtensionID to item 4 of argv
    set commandText to "set -eu; src=" & quoted form of sourcePath & "; dst=" & quoted form of destinationPath & "; expected=" & quoted form of expectedID & "; expected_ext=" & quoted form of expectedExtensionID
    set commandText to commandText & "; stage_dir=''; tmp=''; bak=''; had=0; marker_had=0; marker_invalidated=0; destination_changed=0; committed=0; lock_acquired=0; marker_dir='/Library/Application Support/AI Camera'; marker=\"${marker_dir}/install-generation\"; marker_tmp=\"${marker}.installing\"; marker_bak=\"${marker}.backup\"; lock=\"${marker_dir}/install.lock\""
    set commandText to commandText & "; restore_marker () { test \"$marker_invalidated\" = 1 || return 0; if test -L \"$marker\"; then /bin/rm -f \"$marker\"; elif test -e \"$marker\"; then /usr/bin/chflags nouchg \"$marker\" 2>/dev/null || true; /bin/rm -f \"$marker\"; fi; /usr/bin/chflags nouchg \"$marker_tmp\" 2>/dev/null || true; /bin/rm -f \"$marker_tmp\"; if test \"$marker_had\" = 1 && test -e \"$marker_bak\"; then /bin/mv \"$marker_bak\" \"$marker\" && /usr/bin/chflags uchg \"$marker\"; else /usr/bin/chflags nouchg \"$marker_bak\" 2>/dev/null || true; /bin/rm -f \"$marker_bak\"; fi; marker_invalidated=0; }"
    set commandText to commandText & "; rollback_app () { test \"$destination_changed\" = 1 || return 0; if test -L \"$dst\"; then /bin/rm -f \"$dst\"; elif test -e \"$dst\"; then /usr/bin/chflags -R nouchg \"$dst\" 2>/dev/null || true; /bin/rm -rf \"$dst\"; fi; if test \"$had\" = 1 && test -e \"$bak\" && test ! -e \"$dst\" && test ! -L \"$dst\"; then /bin/mv -h \"$bak\" \"$dst\" && /usr/bin/chflags -h uchg \"$dst\"; fi; destination_changed=0; }"
    set commandText to commandText & "; cleanup () { status=$?; trap - 0 1 2 15; if test \"$committed\" != 1; then rollback_app || true; restore_marker || true; fi; if test -n \"$stage_dir\" && test ! -e \"$bak\"; then case \"$stage_dir\" in \"$marker_dir\"/.install.*) /usr/bin/chflags -R nouchg \"$stage_dir\" 2>/dev/null || true; /bin/rm -rf \"$stage_dir\" ;; esac; fi; if test \"$lock_acquired\" = 1; then /bin/rm -f \"$lock\" 2>/dev/null || true; fi; exit \"$status\"; }; trap cleanup 0; trap 'exit 1' 1 2 15"
    set commandText to commandText & "; test -n \"$dst\"; test \"$dst\" != /; ext=\"$src/Contents/Library/SystemExtensions/$expected_ext.systemextension\"; actual=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \"$src/Contents/Info.plist\"); test \"$actual\" = \"$expected\"; ext_actual=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \"$ext/Contents/Info.plist\"); test \"$ext_actual\" = \"$expected_ext\"; version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' \"$src/Contents/Info.plist\"); case \"$version\" in ''|*[!0-9]*) exit 1 ;; esac; ext_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' \"$ext/Contents/Info.plist\"); case \"$ext_version\" in ''|*[!0-9]*) exit 1 ;; esac"
    set commandText to commandText & "; team=$(/usr/bin/codesign -d --verbose=4 \"$src\" 2>&1 | /usr/bin/sed -n 's/^TeamIdentifier=//p'); ext_team=$(/usr/bin/codesign -d --verbose=4 \"$ext\" 2>&1 | /usr/bin/sed -n 's/^TeamIdentifier=//p'); test \"$team\" = \"$ext_team\"; case \"$team\" in ''|*[!A-Za-z0-9-]*) exit 1 ;; esac; dq=$(/usr/bin/printf '\\042'); host_req=\"identifier ${dq}${expected}${dq} and anchor apple generic and certificate leaf[subject.OU] = ${dq}${team}${dq}\"; ext_req=\"identifier ${dq}${expected_ext}${dq} and anchor apple generic and certificate leaf[subject.OU] = ${dq}${team}${dq}\""
    set commandText to commandText & "; reject_debug_entitlement () { if /usr/bin/codesign -d --entitlements :- \"$1\" 2>/dev/null | /usr/bin/plutil -extract 'com\\.apple\\.security\\.get-task-allow' raw -o - - >/dev/null 2>&1; then return 1; fi; }; verify_identity () { app=\"$1\"; camera_extension=\"$2\"; /usr/bin/codesign --verify --deep --strict \"$app\" && /usr/bin/codesign --verify --strict -R \"=$host_req\" \"$app\" && /usr/bin/codesign --verify --strict -R \"=$ext_req\" \"$camera_extension\"; }; verify_product () { verify_identity \"$1\" \"$2\" && reject_debug_entitlement \"$1\" && reject_debug_entitlement \"$2\"; }; verify_product \"$src\" \"$ext\""
    set commandText to commandText & "; if ! { test ! -L \"$marker_dir\" && /bin/mkdir -p \"$marker_dir\" && /usr/sbin/chown root:wheel \"$marker_dir\" && /bin/chmod -N \"$marker_dir\" && /bin/chmod 0755 \"$marker_dir\"; }; then exit 1; fi; /usr/bin/shlock -p $$ -f \"$lock\"; lock_acquired=1; /usr/sbin/chown root:wheel \"$lock\"; /bin/chmod 0600 \"$lock\""
    set commandText to commandText & "; stage_dir=$(/usr/bin/mktemp -d \"$marker_dir/.install.XXXXXX\"); case \"$stage_dir\" in \"$marker_dir\"/.install.*) ;; *) exit 1 ;; esac; test \"$(/usr/bin/stat -f %d \"$stage_dir\")\" = \"$(/usr/bin/stat -f %d /Applications)\"; /usr/sbin/chown root:wheel \"$stage_dir\"; /bin/chmod -N \"$stage_dir\"; /bin/chmod 0700 \"$stage_dir\"; tmp=\"$stage_dir/new.app\"; bak=\"$stage_dir/previous.app\""
    set commandText to commandText & "; /usr/bin/ditto \"$src\" \"$tmp\"; /usr/bin/chflags -R nouchg \"$tmp\"; /usr/sbin/chown -R root:wheel \"$tmp\"; /bin/chmod -RN \"$tmp\"; /bin/chmod -R go-w \"$tmp\"; tmp_ext=\"$tmp/Contents/Library/SystemExtensions/$expected_ext.systemextension\"; test \"$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \"$tmp/Contents/Info.plist\")\" = \"$expected\"; test \"$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' \"$tmp/Contents/Info.plist\")\" = \"$version\"; test \"$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \"$tmp_ext/Contents/Info.plist\")\" = \"$expected_ext\"; test \"$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' \"$tmp_ext/Contents/Info.plist\")\" = \"$ext_version\""
    set commandText to commandText & "; tmp_team=$(/usr/bin/codesign -d --verbose=4 \"$tmp\" 2>&1 | /usr/bin/sed -n 's/^TeamIdentifier=//p'); tmp_ext_team=$(/usr/bin/codesign -d --verbose=4 \"$tmp_ext\" 2>&1 | /usr/bin/sed -n 's/^TeamIdentifier=//p'); test \"$tmp_team\" = \"$team\"; test \"$tmp_ext_team\" = \"$team\"; verify_product \"$tmp\" \"$tmp_ext\"; staged_identity=$(/usr/bin/stat -f '%d:%i' \"$tmp\")"
    set commandText to commandText & "; if test -e \"$dst\"; then test ! -L \"$dst\"; installed=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \"$dst/Contents/Info.plist\"); test \"$installed\" = \"$expected\"; installed_ext=\"$dst/Contents/Library/SystemExtensions/$expected_ext.systemextension\"; installed_team=$(/usr/bin/codesign -d --verbose=4 \"$dst\" 2>&1 | /usr/bin/sed -n 's/^TeamIdentifier=//p'); installed_ext_team=$(/usr/bin/codesign -d --verbose=4 \"$installed_ext\" 2>&1 | /usr/bin/sed -n 's/^TeamIdentifier=//p'); test \"$installed_team\" = \"$team\"; test \"$installed_ext_team\" = \"$team\"; verify_identity \"$dst\" \"$installed_ext\"; fi"
    set commandText to commandText & "; /usr/bin/chflags nouchg \"$marker_tmp\" \"$marker_bak\" 2>/dev/null || true; /bin/rm -f \"$marker_tmp\" \"$marker_bak\"; if test -e \"$marker\" || test -L \"$marker\"; then test ! -L \"$marker\"; /usr/bin/chflags nouchg \"$marker\"; /bin/mv \"$marker\" \"$marker_bak\"; marker_had=1; marker_invalidated=1; else marker_invalidated=1; fi"
    set commandText to commandText & "; if test -e \"$dst\"; then /usr/bin/chflags -R nouchg \"$dst\"; /bin/mv \"$dst\" \"$bak\"; had=1; destination_changed=1; fi; /bin/mv -h \"$tmp\" \"$dst\"; destination_changed=1; /usr/bin/chflags -h uchg \"$dst\"; test ! -L \"$dst\"; test \"$(/usr/bin/stat -f '%d:%i' \"$dst\")\" = \"$staged_identity\"; final_ext=\"$dst/Contents/Library/SystemExtensions/$expected_ext.systemextension\"; verify_product \"$dst\" \"$final_ext\"; test \"$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \"$dst/Contents/Info.plist\")\" = \"$expected\"; test \"$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' \"$dst/Contents/Info.plist\")\" = \"$version\"; test \"$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' \"$final_ext/Contents/Info.plist\")\" = \"$ext_version\""
    set commandText to commandText & "; companion_pids () { for candidate in $(/usr/bin/pgrep -x 'AI Camera' 2>/dev/null || true); do case \"$candidate\" in ''|*[!0-9]*) continue ;; esac; executable=$(/bin/ps -p \"$candidate\" -o comm= 2>/dev/null | /usr/bin/sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'); if test \"$executable\" = \"$dst/Contents/MacOS/AI Camera\" || test \"$executable\" = \"$bak/Contents/MacOS/AI Camera\"; then /usr/bin/printf '%s\\n' \"$candidate\"; fi; done; }; pids=$(companion_pids); if test -n \"$pids\"; then /bin/kill -TERM $pids 2>/dev/null || true; fi; /bin/sleep 1; pids=$(companion_pids); if test -n \"$pids\"; then /bin/kill -KILL $pids 2>/dev/null || true; fi; /bin/sleep 1; test -z \"$(companion_pids)\""
    set commandText to commandText & "; /usr/bin/printf '%s\\n' \"$version\" > \"$marker_tmp\"; /usr/sbin/chown root:wheel \"$marker_tmp\"; /bin/chmod -N \"$marker_tmp\"; /bin/chmod 0444 \"$marker_tmp\"; /bin/mv \"$marker_tmp\" \"$marker\"; /usr/bin/chflags uchg \"$marker\"; committed=1; marker_invalidated=0; /usr/bin/chflags nouchg \"$marker_bak\" \"$bak\" 2>/dev/null || true; /bin/rm -f \"$marker_bak\"; /bin/rm -rf \"$bak\""
    if (count argv) > 4 and item 5 of argv is "render" then return commandText
    do shell script commandText with administrator privileges
end run
APPLESCRIPT
)"

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
