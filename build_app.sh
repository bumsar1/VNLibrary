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
    <key>CFBundleVersion</key>          <string>1.64</string>
    <key>CFBundleShortVersionString</key><string>1.64</string>
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

# Engine players built in the VN-Ports project. For each, take the newest
# version among the installed copy, VN-Ports' build output and the VN-Ports
# chat's worktrees (never building here: their builds need cargo, Java and
# Xcode). Their own signatures stay intact: VN Library is signed afterwards
# without --deep.
PORTS="$HOME/Cowork/Code/VN-Ports"
bundle_player() {   # <App name> <VN-Ports folder>
    local name="$1" dir="$2" player="" best="" c v
    echo "→ Bundling $name..."
    for c in "$HOME/Applications/$name.app" "$PORTS/$dir/build/$name.app" "$PORTS"/.claude/worktrees/*/"$dir"/build/"$name.app"; do
        [ -x "$c/Contents/MacOS/Start" ] || continue
        v="$("$c/Contents/MacOS/Start" --version 2>/dev/null | sed -n "s/^$name \([0-9.]*\).*/\1/p")"
        [ -n "$v" ] || continue
        if [ -z "$best" ] || { [ "$v" != "$best" ] && [ "$(printf '%s\n%s\n' "$best" "$v" | sort -V | tail -1)" = "$v" ]; }; then
            best="$v"; player="$c"
        fi
    done
    if [ -n "$player" ]; then
        rm -rf "$RES/$name.app"
        ditto "$player" "$RES/$name.app"
        echo "  $("$RES/$name.app/Contents/MacOS/Start" --version 2>/dev/null)"
    else
        echo "  ($name not found — build it in VN-Ports/$dir first)"
    fi
}
bundle_player "KiriKiri Player" kirikiri-player
bundle_player "BGI Player" bgi-player
bundle_player "AliceSoft Player" alicesoft-player

# siglus_engine (Siglus, with the VNLIB_TEXTHOOK text hook) and
# game_launcher_run (RealLive / AVG32 / UK2) from the siglus_rs checkout
# (github.com/bumsar1/siglus_rs, branch vnlib-texthook; MPL-2.0). Never built
# here: build them there first with
#   cargo build --release -p siglus_scene_vm --bin siglus_engine -p game_launcher --bin game_launcher_run
SIGLUS_RS="${SIGLUS_RS:-$HOME/siglus_rs}"
echo "→ Bundling siglus_engine..."
if [ -x "$SIGLUS_RS/target/release/siglus_engine" ] && [ -x "$SIGLUS_RS/target/release/game_launcher_run" ]; then
    cp "$SIGLUS_RS/target/release/siglus_engine" "$SIGLUS_RS/target/release/game_launcher_run" "$MACOS/"
    mkdir -p "$RES/licenses"
    cp "$SIGLUS_RS/LICENSE-MPL-2.0" "$RES/licenses/siglus_rs-LICENSE-MPL-2.0.txt"
    REV="$(git -C "$SIGLUS_RS" rev-parse --short HEAD 2>/dev/null || echo unknown)"
    echo "siglus_rs $REV" > "$RES/siglus-version.txt"
    printf 'siglus_engine and game_launcher_run are built from siglus_rs (MPL-2.0).\nSource: https://github.com/bumsar1/siglus_rs (branch vnlib-texthook, commit %s),\nbased on https://github.com/xmoezzz/siglus_rs.\n' "$REV" > "$RES/licenses/siglus_rs-SOURCE.txt"
    if security find-identity -p codesigning 2>/dev/null | grep -q "Keiko Dev"; then
        codesign --force --sign "Keiko Dev" "$MACOS/siglus_engine" "$MACOS/game_launcher_run" >/dev/null 2>&1
    else
        codesign --force --sign - "$MACOS/siglus_engine" "$MACOS/game_launcher_run" >/dev/null 2>&1
    fi
    echo "  siglus_rs $REV"
else
    echo "  (not found in $SIGLUS_RS/target/release — Siglus games then need a siglus_engine path in Settings)"
fi

# Japanese fonts for Whisky / CrossOver bottles (VN-Ports/wine-tools).
if [ -f "$PORTS/wine-tools/wine-jp-fonts" ]; then
    cp "$PORTS/wine-tools/wine-jp-fonts" "$RES/wine-jp-fonts" && chmod +x "$RES/wine-jp-fonts"
    echo "→ Bundled wine-jp-fonts"
fi

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
codesign --verify --deep --strict "$APP" 2>/dev/null || echo "  (warning: signature check failed with the bundled players)"

echo ""
echo "✓ Built: $APP"
echo "  Drag game folders or Mac apps into the window to add them."
