#!/usr/bin/env bash
#
# Builds a distributable "Claude Proxy.app" and zips it.
#
#   ./Scripts/package-app.sh [version]
#
# Produces:
#   dist/Claude Proxy.app
#   dist/Claude-Proxy-<version>.zip
#
# The app is a universal (arm64 + x86_64) binary. It is NOT code-signed or
# notarized — see the README for the Gatekeeper note users will hit.
set -euo pipefail

VERSION="${1:-0.0.0}"
APP_NAME="Claude Proxy"
EXEC_NAME="ClaudeProxy"
BUNDLE_ID="com.zeus12.claude-proxy"
ICON_SRC="Assets/AppIcon-1024.png"

DIST="dist"
APP="$DIST/$APP_NAME.app"

# Universal (arm64 + x86_64) builds need the full Xcode build system. When only
# the Command Line Tools are installed (no Xcode.app), fall back to a native
# single-arch build so the script still works locally. CI runners have Xcode, so
# release artifacts there are universal.
ARCH_FLAGS=(--arch arm64 --arch x86_64)
echo "==> Building universal release binary"
if ! swift build -c release "${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}" 2>/tmp/cp_build.err; then
    if grep -qi xcbuild /tmp/cp_build.err; then
        echo "    universal build needs full Xcode; falling back to native single-arch"
        ARCH_FLAGS=()
        swift build -c release
    else
        cat /tmp/cp_build.err >&2
        exit 1
    fi
fi
BIN_DIR="$(swift build -c release "${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}" --show-bin-path)"

echo "==> Assembling app bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$EXEC_NAME" "$APP/Contents/MacOS/$EXEC_NAME"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>     <string>$APP_NAME</string>
    <key>CFBundleExecutable</key>      <string>$EXEC_NAME</string>
    <key>CFBundleIdentifier</key>      <string>$BUNDLE_ID</string>
    <key>CFBundleVersion</key>         <string>$VERSION</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleIconFile</key>        <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>  <string>14.0</string>
    <key>LSUIElement</key>             <true/>
    <key>NSHighResolutionCapable</key> <true/>
</dict>
</plist>
PLIST

echo "==> Generating AppIcon.icns from $ICON_SRC"
ICONSET="$DIST/AppIcon.iconset"
rm -rf "$ICONSET"; mkdir -p "$ICONSET"
gen() { sips -z "$1" "$1" "$ICON_SRC" --out "$ICONSET/$2" >/dev/null; }
gen 16   icon_16x16.png
gen 32   icon_16x16@2x.png
gen 32   icon_32x32.png
gen 64   icon_32x32@2x.png
gen 128  icon_128x128.png
gen 256  icon_128x128@2x.png
gen 256  icon_256x256.png
gen 512  icon_256x256@2x.png
gen 512  icon_512x512.png
gen 1024 icon_512x512@2x.png
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

# Code signing. macOS ties Keychain "Always Allow" and TCC permissions
# (Microphone, Accessibility, Input Monitoring) to the app's signing identity.
# An UNSIGNED app has no stable identity, so every launch/rebuild looks like a
# brand-new app and macOS re-prompts forever — permissions can never stick.
#
# Signing with a stable self-signed certificate fixes that: approve once, and
# the grants persist across launches and rebuilds. Create the cert once with:
#   Keychain Access → Certificate Assistant → Create a Certificate…
#   Name: "Claude Proxy Dev", Type: Self Signed Root, Certificate Type: Code Signing
# (or override the name via CODESIGN_IDENTITY).
# A self-signed cert shows as "untrusted" (it isn't from Apple), so it won't
# appear in `security find-identity -p codesigning` — but codesign can still USE
# it to sign, and that's all we need. So we just attempt the real signature and
# only fall back to ad-hoc if signing actually fails. Run Scripts/setup-signing.sh
# once to create the cert.
SIGN_ID="${CODESIGN_IDENTITY:-Claude Proxy Dev}"
echo "==> Code signing"
if codesign --force --deep --sign "$SIGN_ID" "$APP" 2>/dev/null; then
    echo "    signed with '$SIGN_ID' — Mic/Accessibility/Keychain grants persist across rebuilds"
    codesign --verify "$APP" 2>/dev/null || true
else
    echo "    WARNING: identity '$SIGN_ID' not found — run Scripts/setup-signing.sh."
    echo "    Falling back to ad-hoc; macOS will RE-PROMPT for permissions on every rebuild."
    codesign --force --deep --sign - "$APP"
fi

echo "==> Zipping"
ZIP="$DIST/Claude-Proxy-$VERSION.zip"
rm -f "$ZIP"
( cd "$DIST" && ditto -c -k --keepParent "$APP_NAME.app" "$(basename "$ZIP")" )

echo "==> Done: $ZIP"
