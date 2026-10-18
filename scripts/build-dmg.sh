#!/bin/bash
# Build build/Rainbarrel-<version>.dmg: a compressed disk image that holds Rainbarrel.app and a
# shortcut to the Applications folder, so installing is a drag. macOS only. It runs
# scripts/build-app.sh first; pass --skip-build to reuse an existing build/Rainbarrel.app.
# An optional path argument chooses the output file.
#
# Usage: scripts/build-dmg.sh [--skip-build] [output.dmg]
set -euo pipefail

cd "$(dirname "$0")/.."

SKIP_BUILD=0
OUT=""
for arg in "$@"; do
    case "$arg" in
        --skip-build) SKIP_BUILD=1 ;;
        -*) echo "Unknown option: $arg" >&2; exit 2 ;;
        *) OUT="$arg" ;;
    esac
done

if [ "$SKIP_BUILD" -eq 0 ]; then
    scripts/build-app.sh
fi

APP="build/Rainbarrel.app"
if [ ! -d "$APP" ]; then
    echo "$APP does not exist; run scripts/build-app.sh first." >&2
    exit 1
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
OUT="${OUT:-build/Rainbarrel-${VERSION}.dmg}"

STAGE="build/dmg-stage"
rm -rf "$STAGE"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Rainbarrel.app"
ln -s /Applications "$STAGE/Applications"

mkdir -p "$(dirname "$OUT")"
hdiutil create -volname "Rainbarrel" -srcfolder "$STAGE" -ov -format UDZO "$OUT" >/dev/null
rm -rf "$STAGE"

echo "$OUT"
