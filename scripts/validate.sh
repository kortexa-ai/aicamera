#!/bin/bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." >/dev/null 2>&1 && pwd -P)"
cd "$ROOT"

swift test
"$ROOT/scripts/bootstrap.sh"

for script in scripts/*.sh; do
    bash -n "$script"
done
bash -n Resources/Installer/postinstall
xmllint --noout Resources/Installer/Distribution.xml
python3 - <<'PY'
import ast
from pathlib import Path
for script in Path('scripts').glob('*.py'):
    ast.parse(script.read_text(), filename=str(script))
PY
VALIDATION_TMP="$(mktemp -d "${TMPDIR:-/tmp}/aicamera-validation.XXXXXX")"
trap 'rm -rf "$VALIDATION_TMP"' EXIT
cp scripts/installer-transaction.applescript "$VALIDATION_TMP/install-app.applescript"
osacompile \
    -o "$VALIDATION_TMP/install-app.scpt" \
    "$VALIDATION_TMP/install-app.applescript"
sed 's/do shell script commandText with administrator privileges/return commandText/' \
    "$VALIDATION_TMP/install-app.applescript" \
    > "$VALIDATION_TMP/install-app-render.applescript"
osascript "$VALIDATION_TMP/install-app-render.applescript" \
    "$ROOT/build/DerivedData/Build/Products/Release/AI Camera.app" \
    '/Applications/AI Camera.app' \
    'ai.kortexa.aicamera' \
    'ai.kortexa.aicamera.camera-extension' \
    > "$VALIDATION_TMP/install-app-root-command.sh"
/bin/sh -n "$VALIDATION_TMP/install-app-root-command.sh"
python3 scripts/validate-install-versions.py "$VALIDATION_TMP/install-app-root-command.sh"
grep -Fq 'certificate leaf[subject.OU] = ${dq}${team}${dq}' \
    "$VALIDATION_TMP/install-app-root-command.sh"
grep -Fq 'verify_identity "$dst" "$installed_ext"' \
    "$VALIDATION_TMP/install-app-root-command.sh"
if grep -Fq 'verify_product "$dst" "$installed_ext"' \
    "$VALIDATION_TMP/install-app-root-command.sh"; then
    echo "The installer must allow a strictly identified signed Debug predecessor to upgrade." >&2
    exit 1
fi
grep -Fq '/bin/mv -h "$tmp" "$dst"' \
    "$VALIDATION_TMP/install-app-root-command.sh"
grep -Fq '/usr/bin/chflags -h uchg "$dst"' \
    "$VALIDATION_TMP/install-app-root-command.sh"

find Resources \( -name '*.plist' -o -name '*.entitlements' \) -print0 \
    | while IFS= read -r -d '' plist; do
        plutil -lint "$plist"
    done

SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
xcrun --sdk macosx clang \
    -std=c11 -fsyntax-only -Wall -Wextra -Wpedantic -Werror \
    -isysroot "$SDKROOT" \
    Sources/AICameraAudioDriver/AICameraAudioDriver.c

xcodebuild \
    -project AICamera.xcodeproj \
    -scheme AICamera \
    -configuration Debug \
    -destination 'platform=macOS' \
    -derivedDataPath "$ROOT/build/DerivedData-Validation" \
    CODE_SIGNING_ALLOWED=NO \
    build

APP="$ROOT/build/DerivedData-Validation/Build/Products/Debug/AI Camera.app"
DRIVER="$APP/Contents/Resources/AICameraAudioDriver.driver"
CAMERA_EXTENSION="$APP/Contents/Library/SystemExtensions/ai.kortexa.aicamera.camera-extension.systemextension"
test -d "${APP:?}"
test -d "${DRIVER:?}"
test -d "${CAMERA_EXTENSION:?}"
test -f "$DRIVER/Contents/Resources/en.lproj/Localizable.strings"
test -f "$DRIVER/Contents/Resources/APPLE_NULLAUDIO_LICENSE.txt"
plutil -extract CFBundleIdentifier raw "$APP/Contents/Info.plist" \
    | grep -qx 'ai.kortexa.aicamera'
plutil -extract CFBundleIdentifier raw "$DRIVER/Contents/Info.plist" \
    | grep -qx 'ai.kortexa.aicamera.audio.driver'
plutil -extract CFBundleIdentifier raw "$CAMERA_EXTENSION/Contents/Info.plist" \
    | grep -qx 'ai.kortexa.aicamera.camera-extension'
nm -gU "$DRIVER/Contents/MacOS/AICameraAudioDriver" \
    | grep -q '_AICameraAudioDriver_Create'

HARNESS="$ROOT/build/aicamera-audio-driver-harness"
xcrun --sdk macosx clang \
    -std=c11 -Wall -Wextra -Wpedantic -Werror \
    -isysroot "$SDKROOT" \
    Tests/AICameraAudioDriverTests/LoopbackHarness.c \
    -framework CoreAudio -framework CoreFoundation \
    -o "$HARNESS"
"$HARNESS" "$DRIVER"

FRAMEWORKS="$ROOT/build/DerivedData-Validation/Build/Products/Debug"
xcrun swiftc -parse-as-library -O \
    Sources/AICameraApp/PCMBufferConverter.swift scripts/validate-audio-conversion.swift \
    -o "$VALIDATION_TMP/audio-conversion"
"$VALIDATION_TMP/audio-conversion"
xcrun swiftc -parse-as-library -O \
    -F "$FRAMEWORKS" -framework AICameraCore -Xlinker -rpath -Xlinker "$FRAMEWORKS" \
    Sources/AICameraApp/AgentNotesController.swift Sources/AICameraApp/OverlayRenderer.swift \
    Sources/AICameraApp/AgentCardRenderer.swift Sources/AICameraApp/AgentStatusRenderer.swift \
    scripts/validate-agent-tools.swift -o "$VALIDATION_TMP/agent-tools"
"$VALIDATION_TMP/agent-tools" "$VALIDATION_TMP/synthetic-cards"
xcrun swiftc -parse-as-library -O \
    -F "$FRAMEWORKS" -framework AICameraCore -Xlinker -rpath -Xlinker "$FRAMEWORKS" \
    Sources/AICameraApp/AgentCardRenderer.swift scripts/validate-agent-weather.swift \
    -o "$VALIDATION_TMP/agent-weather"
"$VALIDATION_TMP/agent-weather" --fixture "$VALIDATION_TMP/synthetic-weather"
xcrun swiftc -parse-as-library -O \
    -F "$FRAMEWORKS" -framework AICameraCore -Xlinker -rpath -Xlinker "$FRAMEWORKS" \
    Sources/AICameraApp/OverlayScriptRenderer.swift scripts/validate-overlay-runtime.swift \
    -o "$VALIDATION_TMP/overlay-runtime"
"$VALIDATION_TMP/overlay-runtime" "$ROOT/Resources/Overlay/overlay.html"
xcrun swiftc -parse-as-library -O \
    -F "$FRAMEWORKS" -framework AICameraCore -Xlinker -rpath -Xlinker "$FRAMEWORKS" \
    Sources/AICameraApp/FaceAnchorDetector.swift Sources/AICameraApp/OverlayScriptRenderer.swift \
    Sources/AICameraApp/OverlayRenderer.swift Sources/AICameraApp/AgentCardRenderer.swift \
    Sources/AICameraApp/AgentStatusRenderer.swift scripts/validate-face-anchors.swift \
    -o "$VALIDATION_TMP/face-anchors"
"$VALIDATION_TMP/face-anchors" "$ROOT/Resources/Overlay/overlay.html"
xcrun swiftc -parse-as-library -O \
    -F "$FRAMEWORKS" -framework AICameraCore -Xlinker -rpath -Xlinker "$FRAMEWORKS" \
    Sources/AICameraApp/RealtimeConversationSession.swift scripts/validate-realtime-activation.swift \
    -o "$VALIDATION_TMP/realtime-activation"
"$VALIDATION_TMP/realtime-activation"
xcrun swiftc -parse-as-library -O \
    -F "$FRAMEWORKS" -framework AICameraCore -framework llama -Xlinker -rpath -Xlinker "$FRAMEWORKS" \
    Sources/AICameraApp/PipelineCoordinator.swift \
    Sources/AICameraApp/AudioPipelineController.swift Sources/AICameraApp/PCMBufferConverter.swift \
    Sources/AICameraApp/SpeechOutputMonitor.swift Sources/AICameraApp/DeviceDiscovery.swift \
    Sources/AICameraApp/AudioDriverManager.swift Sources/AICameraShared/VirtualCameraConstants.swift \
    Sources/AICameraShared/MediaDemandState.swift Sources/AICameraApp/BuiltinTranslationClient.swift \
    Sources/AICameraApp/BuiltinTranslationModelController.swift scripts/validate-realtime-captions.swift \
    -o "$VALIDATION_TMP/realtime-captions"
"$VALIDATION_TMP/realtime-captions" --controlled-only

echo "Validation passed. No driver or system extension was installed."
