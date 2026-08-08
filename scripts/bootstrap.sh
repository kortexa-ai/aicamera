#!/bin/bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." >/dev/null 2>&1 && pwd -P)"
cd "$ROOT"

if [ "$(uname -s)" != "Darwin" ]; then
    echo "AICamera requires macOS." >&2
    exit 1
fi
if ! command -v xcodegen >/dev/null 2>&1; then
    echo "Install XcodeGen first: brew install xcodegen" >&2
    exit 1
fi

if [ ! -f Config/Local.xcconfig ]; then
    team_id="$(security find-identity -v -p codesigning 2>/dev/null \
        | sed -nE 's/.*Apple (Development|Distribution):.*\(([A-Z0-9]{10})\).*/\2/p' \
        | head -n 1 || true)"
    {
        echo "// Generated locally by scripts/bootstrap.sh. This file is gitignored."
        echo "DEVELOPMENT_TEAM = ${team_id}"
        echo "CODE_SIGN_STYLE = Automatic"
    } > Config/Local.xcconfig
    if [ -n "$team_id" ]; then
        echo "Created Config/Local.xcconfig from an installed signing identity."
    else
        echo "Created Config/Local.xcconfig without a team. Set DEVELOPMENT_TEAM before installing extensions."
    fi
fi

xcodegen generate
