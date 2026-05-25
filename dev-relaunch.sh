#!/bin/bash
#
# Kill any running DroidProxy, rebuild the .app bundle, and launch the fresh
# build straight from the repo root. Intended for tight dev-loop testing —
# do not use for releases (see release skill / .github/workflows/release.yml).
#

set -e

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_BUNDLE="$PROJECT_DIR/DroidProxy.app"

echo "🛑 Stopping any running DroidProxy..."
# Match by exact process name so we don't accidentally hit this script itself.
pkill -x CLIProxyMenuBar 2>/dev/null || true
pkill -x cli-proxy-api-plus 2>/dev/null || true
sleep 1
pkill -9 -x CLIProxyMenuBar 2>/dev/null || true
pkill -9 -x cli-proxy-api-plus 2>/dev/null || true

# create-app-bundle.sh runs `swift build -c release` and assembles the .app.
"$PROJECT_DIR/create-app-bundle.sh"

echo "🚀 Launching freshly built DroidProxy.app..."
open "$APP_BUNDLE"
