#!/bin/bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." >/dev/null 2>&1 && pwd -P)"
cd "$ROOT"
"$ROOT/scripts/bootstrap.sh"

SIGNING_ARGS=(CODE_SIGNING_ALLOWED=NO)
if [[ "${SIGNING:-0}" == "1" ]]; then
    SIGNING_ARGS=(-allowProvisioningUpdates)
fi

exec xcodebuild \
    -project AICamera.xcodeproj \
    -scheme AICamera \
    -configuration Debug \
    -destination 'platform=macOS' \
    -derivedDataPath "$ROOT/build/DerivedData" \
    "${SIGNING_ARGS[@]}" \
    build "$@"
