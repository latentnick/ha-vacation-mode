#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP="build/LightsMenubar.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/release/LightsMenubar" "$APP/Contents/MacOS/LightsMenubar"
cp "Resources/Info.plist" "$APP/Contents/Info.plist"

echo "Built $APP"
