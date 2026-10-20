#!/bin/bash
# Build build/Rainbarrel.app: a release build of the menu-bar app wrapped in an app bundle and
# signed ad hoc. macOS only. Run from anywhere; the output goes to <repo>/build/Rainbarrel.app.
set -euo pipefail

cd "$(dirname "$0")/.."

swift build -c release --product rainbarrel
swift build -c release --product RainbarrelBar
BIN="$(swift build -c release --show-bin-path)"

# One version constant (RainbarrelInfo.version) serves the CLI, the MCP server and the app.
VERSION="$("$BIN/rainbarrel" --version)"
BUNDLE_ID="io.github.eugertjani-lab.rainbarrel"
APP="build/Rainbarrel.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/RainbarrelBar" "$APP/Contents/MacOS/Rainbarrel"
# The icon is drawn by scripts/make-icon.swift; regenerate it with: swift scripts/make-icon.swift Resources
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>Rainbarrel</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIconName</key>
    <string>AppIcon</string>
    <key>CFBundleName</key>
    <string>Rainbarrel</string>
    <key>CFBundleDisplayName</key>
    <string>Rainbarrel</string>
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
    <string>Copyright 2026 Rainbarrel contributors. MIT License.</string>
    <key>NSRemovableVolumesUsageDescription</key>
    <string>Rainbarrel reads your backup drive to find out which photos and videos are already backed up, and writes the missing ones there when you download them.</string>
</dict>
</plist>
PLIST

plutil -lint "$APP/Contents/Info.plist" >/dev/null
# Sign with a stable identity when one is available. macOS ties a Keychain "Always Allow" to the
# app's code signature; an ad-hoc signature changes with every build, so each new build would ask
# for the Keychain password again. RAINBARREL_SIGN_IDENTITY picks an identity (use "-" for ad hoc);
# otherwise the first Developer ID Application or Apple Development identity is used, if any.
IDENTITY="${RAINBARREL_SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
    IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
        | sed -n -E 's/^ *[0-9]+\) ([0-9A-F]{40}) "(Developer ID Application|Apple Development): .*"$/\1/p' | head -n 1)"
fi
if [ -n "$IDENTITY" ] && [ "$IDENTITY" != "-" ]; then
    codesign --force --sign "$IDENTITY" --timestamp=none "$APP"
    echo "Signed with identity $IDENTITY"
else
    codesign --force --sign - --timestamp=none "$APP"
    echo "Signed ad hoc (no signing identity found); macOS asks for Keychain access again after each build"
fi
codesign --verify --strict "$APP"

# Keep the build copy out of Spotlight and the Open With list, so only the copy in /Applications
# is offered. Harmless when lsregister is missing or fails.
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [ -x "$LSREGISTER" ]; then
    "$LSREGISTER" -u "$APP" >/dev/null 2>&1 || true
fi

echo "Built $APP (version $VERSION)"
echo "Open it with: open $APP"
