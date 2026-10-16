#!/bin/bash
# Build build/PhotoMirror.app: a release build of the menu-bar app wrapped in an app bundle and
# signed ad hoc. macOS only. Run from anywhere; the output goes to <repo>/build/PhotoMirror.app.
set -euo pipefail

cd "$(dirname "$0")/.."

swift build -c release --product apmirror
swift build -c release --product PhotoMirrorBar
BIN="$(swift build -c release --show-bin-path)"

# One version constant (MirrorInfo.version) serves the CLI, the MCP server and the app.
VERSION="$("$BIN/apmirror" --version)"
BUNDLE_ID="io.github.amazon-photos-sync.photomirror"
APP="build/PhotoMirror.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/PhotoMirrorBar" "$APP/Contents/MacOS/PhotoMirror"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>PhotoMirror</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleName</key>
    <string>PhotoMirror</string>
    <key>CFBundleDisplayName</key>
    <string>PhotoMirror</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright 2026 PhotoMirror contributors. MIT License.</string>
    <key>NSRemovableVolumesUsageDescription</key>
    <string>PhotoMirror reads your backup drive to find out which photos and videos are already backed up. It never writes to the drive.</string>
</dict>
</plist>
PLIST

plutil -lint "$APP/Contents/Info.plist" >/dev/null
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --strict "$APP"

echo "Built $APP (version $VERSION)"
echo "Open it with: open $APP"
