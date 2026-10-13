#!/bin/zsh
# Build VN Library.app — a native macOS app (SwiftUI, no runtime deps).
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
APP="$DIR/VN Library.app"
RES="$APP/Contents/Resources"
MACOS="$APP/Contents/MacOS"
# Use Xcode's own SDK: the Command Line Tools SDK can be newer than the
# compiler, which then refuses to load it.
XSDK="$(xcode-select -p)/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"
if [ -d "$XSDK" ]; then SDK="$XSDK"; else SDK="$(xcrun --show-sdk-path)"; fi

echo "→ Compiling Swift sources..."
rm -rf "$APP"
mkdir -p "$RES" "$MACOS"
xcrun swiftc -swift-version 5 -O \
    -target arm64-apple-macos14.0 -sdk "$SDK" \
    "$DIR"/Sources/*.swift -o "$MACOS/VNLibrary"

echo "→ Building icon..."
[ -f "$DIR/logo.png" ] || (cd "$DIR" && xcrun swiftc -sdk "$SDK" make_logo.swift -o .make_logo && ./.make_logo && rm .make_logo)
ICONSET="$DIR/AppIcon.iconset"
rm -rf "$ICONSET"; mkdir -p "$ICONSET"
for SIZE in 16 32 64 128 256 512; do
    sips -s format png -z $SIZE $SIZE "$DIR/logo.png" \
         --out "$ICONSET/icon_${SIZE}x${SIZE}.png" >/dev/null
    sips -s format png -z $((SIZE*2)) $((SIZE*2)) "$DIR/logo.png" \
         --out "$ICONSET/icon_${SIZE}x${SIZE}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$RES/AppIcon.icns"
rm -rf "$ICONSET"

echo "→ Writing Info.plist..."
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
    "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>             <string>VN Library</string>
    <key>CFBundleDisplayName</key>      <string>VN Library</string>
    <key>CFBundleIdentifier</key>       <string>dk.cadesign.vnlibrary</string>
    <key>CFBundleVersion</key>          <string>1.17</string>
    <key>CFBundleShortVersionString</key><string>1.17</string>
    <key>CFBundlePackageType</key>      <string>APPL</string>
    <key>CFBundleExecutable</key>       <string>VNLibrary</string>
    <key>CFBundleIconFile</key>         <string>AppIcon</string>
    <key>NSPrincipalClass</key>         <string>NSApplication</string>
    <key>LSMinimumSystemVersion</key>   <string>14.0</string>
    <key>NSHighResolutionCapable</key>  <true/>
    <key>LSApplicationCategoryType</key><string>public.app-category.games</string>
    <key>CFBundleDocumentTypes</key>
    <array>
      <dict>
        <key>CFBundleTypeName</key>  <string>Game folder</string>
        <key>CFBundleTypeRole</key>  <string>Viewer</string>
        <key>LSItemContentTypes</key>
        <array><string>public.folder</string><string>com.apple.application-bundle</string></array>
      </dict>
    </array>
</dict>
</plist>
PLIST

echo "→ Signing and clearing quarantine..."
# A stable identity keeps the keychain from asking again for the VNDB token
# after every rebuild (an ad-hoc signature changes with each build). Reuses
# Keiko's self-signed certificate when it's there.
if security find-identity -p codesigning 2>/dev/null | grep -q "Keiko Dev"; then
    codesign --force --sign "Keiko Dev" "$APP" >/dev/null 2>&1 || echo "  (signing failed)"
else
    codesign --force --sign - "$APP" >/dev/null 2>&1 || echo "  (codesign skipped)"
fi
xattr -cr "$APP"

echo ""
echo "✓ Built: $APP"
echo "  Drag game folders or Mac apps into the window to add them."
