#!/bin/bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." >/dev/null 2>&1 && pwd -P)"
"$ROOT/scripts/build.sh"
open "$ROOT/build/DerivedData/Build/Products/Debug/AI Camera.app"
echo "The development app is running. Use scripts/install-app.sh before activating the camera extension."
