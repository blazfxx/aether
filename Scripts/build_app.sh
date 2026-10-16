#!/bin/bash
# Builds Aether.app from the Swift package (no Xcode needed, Command Line Tools are enough).
#   Scripts/build_app.sh            -> build/Aether.app
#   Scripts/build_app.sh --install  -> also copies it to /Applications
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
APP="$ROOT/build/Aether.app"
VERSION="1.0.1"
BUILD="$(date +%y%m%d%H%M)"

echo "› compiling (release)"
swift build -c release --product Aether
BIN="$(swift build -c release --show-bin-path)/Aether"

echo "› assembling bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Aether"

# The icon is drawn in Resources/AppIcon.svg and rendered into Resources/AppIcon.iconset (Scripts/render-icon.mjs).
mkdir -p "$ROOT/build"
iconutil -c icns "$ROOT/Resources/AppIcon.iconset" -o "$ROOT/build/AppIcon.icns"
cp "$ROOT/build/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>Aether</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIdentifier</key><string>dev.aether.Aether</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>Aether</string>
  <key>CFBundleDisplayName</key><string>Aether</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHumanReadableCopyright</key><string>Aether</string>
  <key>NSAppleEventsUsageDescription</key><string>Aether reads and removes your login items through System Events.</string>
  <key>NSDesktopFolderUsageDescription</key><string>Aether looks for large and duplicate files in your Desktop folder.</string>
  <key>NSDocumentsFolderUsageDescription</key><string>Aether looks for large and duplicate files in your Documents folder.</string>
  <key>NSDownloadsFolderUsageDescription</key><string>Aether looks for old installers and large files in your Downloads folder.</string>
  <key>NSRemovableVolumesUsageDescription</key><string>Aether can map storage on external drives you choose.</string>
</dict>
</plist>
PLIST

echo "› signing (ad-hoc)"
xattr -cr "$APP"   # Desktop/iCloud xattrs make codesign reject the bundle
codesign --force --deep --sign - "$APP"
codesign --verify --strict "$APP"
echo "  signature ok"

echo "✓ $APP"

if [ "${1:-}" = "--install" ]; then
  rm -rf /Applications/Aether.app
  cp -R "$APP" /Applications/Aether.app
  echo "✓ installed to /Applications/Aether.app"
fi
