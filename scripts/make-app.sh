#!/bin/bash
# Builds ChessAi in release and wraps it as dist/ChessAi.app. With --install, also copies it to /Applications.
set -euo pipefail

cd "$(dirname "$0")/.."

if [ "${1:-}" != "" ] && [ "$1" != "--install" ]; then
    echo "usage: scripts/make-app.sh [--install]" >&2
    exit 2
fi

# xcode-select may point at the command line tools; prefer Xcode when it is there.
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app ]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

swift build -c release --product ChessAi

app=dist/ChessAi.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/ChessAi" "$app/Contents/MacOS/ChessAi"
cp Assets/AppIcon/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"

# The identifier matches the name `swift run` stores settings under, so both share the same settings.
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>ChessAi</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIdentifier</key><string>ChessAi</string>
    <key>CFBundleName</key><string>ChessAi</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$app"
echo "Built $app"

if [ "${1:-}" = "--install" ]; then
    rm -rf /Applications/ChessAi.app
    cp -R "$app" /Applications/
    echo "Installed /Applications/ChessAi.app"
fi
