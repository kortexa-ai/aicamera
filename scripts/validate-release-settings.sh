#!/bin/bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." >/dev/null 2>&1 && pwd -P)"
cd "$ROOT"
RELEASE_COMMIT=080cf1958c82956df716b65d8f2474eb9c8b4f68
test "$(git rev-parse 'v0.2.0^{commit}')" = "$RELEASE_COMMIT" || {
    echo "The local v0.2.0 tag does not match the pinned public release." >&2
    exit 1
}
FRAMEWORKS="$ROOT/build/DerivedData-Validation/Build/Products/Debug"
test -d "$FRAMEWORKS/AICameraCore.framework" || {
    echo "Run scripts/validate.sh before the release-settings fixture." >&2
    exit 1
}
umask 077
COMPAT_TMP="$(mktemp -d "${TMPDIR:-/tmp}/aicamera-release-settings.XXXXXX")"
trap 'rm -rf "${COMPAT_TMP:?}"' EXIT
git archive "$RELEASE_COMMIT" Sources/AICameraCore | tar -xf - -C "$COMPAT_TMP"
xcrun swiftc -parse-as-library -O -swift-version 5 \
    -emit-library -emit-module -module-name AICameraReleaseCore \
    "$COMPAT_TMP"/Sources/AICameraCore/*.swift \
    -emit-module-path "$COMPAT_TMP/AICameraReleaseCore.swiftmodule" \
    -o "$COMPAT_TMP/libAICameraReleaseCore.dylib"
xcrun swiftc -parse-as-library -O \
    -F "$FRAMEWORKS" -framework AICameraCore -Xlinker -rpath -Xlinker "$FRAMEWORKS" \
    -I "$COMPAT_TMP" -L "$COMPAT_TMP" -lAICameraReleaseCore \
    -Xlinker -rpath -Xlinker "$COMPAT_TMP" \
    scripts/validate-release-settings.swift -o "$COMPAT_TMP/check"
"$COMPAT_TMP/check" "$COMPAT_TMP/synthetic-settings.json"
