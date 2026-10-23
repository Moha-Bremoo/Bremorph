#!/bin/bash
# Builds Bremorph.app from source and installs it into ~/Applications.
# Usage: ./build.command   (or double-click it in Finder)
cd "$(dirname "$0")" || exit 1
exec > >(tee build.log) 2>&1
echo "=== Bremorph build $(date) ==="
sw_vers

if ! xcode-select -p >/dev/null 2>&1 || ! xcrun --find swiftc >/dev/null 2>&1; then
  echo "NO_SWIFT: Apple's Command Line Tools are needed. An installer window will open — click Install, then run this again."
  xcode-select --install
  exit 1
fi
swiftc --version

APP="build/Bremorph.app"
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "--- compiling"
swiftc -O -parse-as-library \
  -target "$(uname -m)-apple-macos13.0" \
  -sdk "$(xcrun --show-sdk-path)" \
  Sources/*.swift \
  -o "$APP/Contents/MacOS/Bremorph" || { echo "BUILD_FAILED"; exit 1; }

cp Info.plist "$APP/Contents/Info.plist"
iconutil -c icns AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
cp Resources/*.png "$APP/Contents/Resources/" 2>/dev/null
for L in Resources/*.lproj; do                       # translations (English, Arabic)
  cp -R "$L" "$APP/Contents/Resources/"
  for f in "$L"/*; do plutil -lint "$f" >/dev/null || { echo "BAD_STRINGS: $f"; plutil -lint "$f"; }; done
done
codesign --force --deep -s - "$APP"

echo "--- installing"
DEST="$HOME/Applications"
mkdir -p "$DEST"
pkill -x Bremorph 2>/dev/null
pkill -x Morph 2>/dev/null        # earlier name of this app
sleep 0.5
rm -rf "$DEST/Morph.app"           # remove the old build if present
rm -rf "$DEST/Bremorph.app"
cp -R "$APP" "$DEST/Bremorph.app"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST/Bremorph.app"
/System/Library/CoreServices/pbs -update 2>/dev/null
open "$DEST/Bremorph.app"
echo "BUILD_OK"
