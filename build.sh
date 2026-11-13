#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
STAGING=$(mktemp -d /private/tmp/happ-monitor.XXXXXX)
trap 'rm -rf "$STAGING"' EXIT
APP="$STAGING/Happ Monitor.app"
SIGNING_IDENTITY="${HAPP_SIGNING_IDENTITY:-Happ Monitor Local Signing}"
BUILD_ARCH="${HAPP_BUILD_ARCH:-$(uname -m)}"
case "$BUILD_ARCH" in
  arm64|x86_64) ;;
  *) echo 'HAPP_BUILD_ARCH must be arm64 or x86_64.' >&2; exit 1 ;;
esac
mkdir -p "$APP/Contents/MacOS"
xcrun swiftc Sources/*.swift -target "$BUILD_ARCH-apple-macosx13.0" -module-cache-path "$PWD/.build/ModuleCache" -O -framework AppKit -framework ApplicationServices -framework SystemConfiguration -framework ServiceManagement -framework UserNotifications -o "$APP/Contents/MacOS/HappMonitor"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>HappMonitor</string>
<key>CFBundleIdentifier</key><string>local.deniszutaev.happ-monitor</string>
<key>CFBundleName</key><string>Happ Monitor</string>
<key>CFBundleVersion</key><string>2</string>
<key>CFBundleShortVersionString</key><string>2.0</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
xattr -cr "$APP"
codesign --force --sign "$SIGNING_IDENTITY" --identifier local.deniszutaev.happ-monitor "$APP"
codesign --verify --deep --strict "$APP"
ditto --norsrc --noextattr "$APP" "$PWD/.build/Happ Monitor.app"
echo "Built: $PWD/.build/Happ Monitor.app"
