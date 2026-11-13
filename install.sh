#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
SOURCE="$PWD/.build/Happ Monitor.app"
DEST="$HOME/Applications/Happ Monitor.app"
mkdir -p "$HOME/Applications"
if [[ -e "$DEST/Contents/Info.plist" ]]; then
  EXISTING_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$DEST/Contents/Info.plist")
  [[ "$EXISTING_ID" == local.deniszutaev.happ-monitor ]] || { echo 'Another application occupies the destination.' >&2; exit 1; }
fi
ditto --norsrc --noextattr "$SOURCE" "$DEST"
xattr -dr com.apple.FinderInfo "$DEST" 2>/dev/null || true
xattr -dr com.apple.ResourceFork "$DEST" 2>/dev/null || true
codesign --verify --deep --strict "$DEST"
echo "Installed: $DEST"
