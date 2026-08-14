#!/bin/bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." >/dev/null 2>&1 && pwd -P)"
cd "$ROOT"
"$ROOT/scripts/bootstrap.sh"

CONFIGURATION="${CONFIGURATION:-Debug}"
case "$CONFIGURATION" in
    Debug|Release) ;;
    *) printf 'Unsupported build configuration: %s\n' "$CONFIGURATION" >&2; exit 2 ;;
esac

SIGNING_ARGS=(CODE_SIGNING_ALLOWED=NO)
if [[ "${SIGNING:-0}" == "1" ]]; then
    SIGNING_ARGS=(-allowProvisioningUpdates)
fi

exec xcodebuild \
    -project AICamera.xcodeproj \
    -scheme AICamera \
    -configuration "$CONFIGURATION" \
    -destination 'platform=macOS' \
    -derivedDataPath "$ROOT/build/DerivedData" \
    "${SIGNING_ARGS[@]}" \
    build "$@"
