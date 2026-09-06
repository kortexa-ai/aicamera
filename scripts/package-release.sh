#!/bin/bash
set -euo pipefail

# Build and notarize release artifacts only. This never installs the app, changes
# repository visibility, pushes a tag, or publishes a GitHub release.
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)"
cd "$ROOT"
if [[ -n "$(git status --porcelain --untracked-files=normal)" ]]; then
    echo "Release input must be a clean, reviewed commit." >&2
    exit 1
fi
RELEASE_COMMIT="$(git rev-parse HEAD)"
RELEASE_VERSION="$(awk '/MARKETING_VERSION:/ {gsub(/"/, "", $2); print $2; exit}' project.yml)"
RELEASE_BUILD="$(awk '/CURRENT_PROJECT_VERSION:/ {gsub(/"/, "", $2); print $2; exit}' project.yml)"
[[ "$RELEASE_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$RELEASE_BUILD" =~ ^[0-9]+$ ]]
NOTARY_PROFILE="${AICAMERA_NOTARY_PROFILE:-notarytool}"
INSTALLER_IDENTITY="${AICAMERA_INSTALLER_IDENTITY:-}"
if [[ -z "$INSTALLER_IDENTITY" ]]; then
    INSTALLER_IDENTITY="$(security find-identity -v -p basic | sed -n 's/.*"\(Developer ID Installer:.*\)"/\1/p')"
fi
[[ -n "$INSTALLER_IDENTITY" && "$INSTALLER_IDENTITY" != *$'\n'* ]]
mkdir -p "$ROOT/build"
RELEASE_OUTPUT="$(mktemp -d "$ROOT/build/release-$RELEASE_VERSION.XXXXXX")"
echo "Release artifacts: $RELEASE_OUTPUT"
printf '%s\n' "$RELEASE_COMMIT" > "$RELEASE_OUTPUT/source-commit.txt"
scripts/validate.sh > "$RELEASE_OUTPUT/validation.log" 2>&1
scripts/bootstrap.sh
xcodebuild -project AICamera.xcodeproj -scheme AICamera -configuration Release \
    -destination 'generic/platform=macOS' -archivePath "$RELEASE_OUTPUT/AICamera.xcarchive" \
    -allowProvisioningUpdates archive > "$RELEASE_OUTPUT/archive.log" 2>&1
ARCHIVED_APP="$RELEASE_OUTPUT/AICamera.xcarchive/Products/Applications/AI Camera.app"
RELEASE_TEAM="$(codesign -d --verbose=4 "$ARCHIVED_APP" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
[[ "$RELEASE_TEAM" =~ ^[A-Z0-9]+$ ]]
[[ "$INSTALLER_IDENTITY" == *"($RELEASE_TEAM)" ]]
python3 - "$RELEASE_OUTPUT/ExportOptions.plist" "$RELEASE_TEAM" <<'PY'
import plistlib,sys
with open(sys.argv[1],'wb') as f:
    plistlib.dump({'method':'developer-id','signingStyle':'automatic','teamID':sys.argv[2]},f)
PY
xcodebuild -exportArchive -archivePath "$RELEASE_OUTPUT/AICamera.xcarchive" \
    -exportPath "$RELEASE_OUTPUT/export" -exportOptionsPlist "$RELEASE_OUTPUT/ExportOptions.plist" \
    -allowProvisioningUpdates > "$RELEASE_OUTPUT/export.log" 2>&1
RELEASE_APP="$RELEASE_OUTPUT/export/AI Camera.app"
python3 scripts/verify-release.py "$RELEASE_APP" --version "$RELEASE_VERSION" --build "$RELEASE_BUILD" \
    > "$RELEASE_OUTPUT/app-verification.json"

notarize() {
    local artifact="$1" name="$2" submission
    xcrun notarytool submit "$artifact" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json \
        > "$RELEASE_OUTPUT/$name-notary.json"
    submission="$(python3 - "$RELEASE_OUTPUT/$name-notary.json" <<'PY'
import json,sys
r=json.load(open(sys.argv[1])); print(r['id'])
PY
)"
    xcrun notarytool log "$submission" --keychain-profile "$NOTARY_PROFILE" \
        "$RELEASE_OUTPUT/$name-notary-log.json"
    python3 - "$RELEASE_OUTPUT/$name-notary.json" <<'PY'
import json,sys
assert json.load(open(sys.argv[1]))['status']=='Accepted', 'Notarization was not accepted'
PY
}

# Staple the inner app before building the final package, giving both their own
# offline tickets. Notarizing the package also scans its nested application code.
ditto -c -k --keepParent "$RELEASE_APP" "$RELEASE_OUTPUT/app-submission.zip"
notarize "$RELEASE_OUTPUT/app-submission.zip" app
xcrun stapler staple "$RELEASE_APP"
xcrun stapler validate "$RELEASE_APP"
spctl --assess --type execute --verbose=2 "$RELEASE_APP"

PACKAGE_SCRIPTS="$RELEASE_OUTPUT/package-scripts"
PACKAGE_RESOURCES="$RELEASE_OUTPUT/package-resources"
mkdir -p "$PACKAGE_SCRIPTS" "$PACKAGE_RESOURCES"
ditto "$RELEASE_APP" "$PACKAGE_SCRIPTS/AI Camera.app"
cp scripts/installer-transaction.applescript "$PACKAGE_SCRIPTS/"
cp Resources/Installer/postinstall "$PACKAGE_SCRIPTS/"
chmod 755 "$PACKAGE_SCRIPTS/postinstall"
cp Resources/Installer/welcome.html Resources/Installer/conclusion.html LICENSE "$PACKAGE_RESOURCES/"
pkgbuild --nopayload --scripts "$PACKAGE_SCRIPTS" --identifier ai.kortexa.aicamera.installer \
    --version "$RELEASE_VERSION" --sign "$INSTALLER_IDENTITY" --timestamp \
    "$RELEASE_OUTPUT/AI Camera Component.pkg"
RELEASE_PACKAGE="$RELEASE_OUTPUT/AICamera-$RELEASE_VERSION.pkg"
productbuild --distribution Resources/Installer/Distribution.xml --resources "$PACKAGE_RESOURCES" \
    --package-path "$RELEASE_OUTPUT" --sign "$INSTALLER_IDENTITY" --timestamp "$RELEASE_PACKAGE"
python3 scripts/validate-installer-package.py "$RELEASE_PACKAGE" --version "$RELEASE_VERSION" --build "$RELEASE_BUILD"
notarize "$RELEASE_PACKAGE" installer
xcrun stapler staple "$RELEASE_PACKAGE"
xcrun stapler validate "$RELEASE_PACKAGE"
pkgutil --check-signature "$RELEASE_PACKAGE"
spctl --assess --type install --verbose=2 "$RELEASE_PACKAGE"
python3 scripts/verify-release.py "$RELEASE_APP" --version "$RELEASE_VERSION" --build "$RELEASE_BUILD" \
    > "$RELEASE_OUTPUT/app-verification.json"
cp docs/releases/0.2.0.md "$RELEASE_OUTPUT/RELEASE-NOTES.md"
cp NOTICE "$RELEASE_OUTPUT/NOTICE"
(cd "$RELEASE_OUTPUT" && shasum -a 256 "AICamera-$RELEASE_VERSION.pkg" > SHA256SUMS)
echo "Verified and notarized: $RELEASE_PACKAGE"
