#!/usr/bin/env bash
# Replace /Applications/cmux.app with a locally built app.
#
# Usage: scripts/install-local.sh [path/to/cmux.app]   (default: build/release/cmux.app)
#
# Run it from a terminal other than cmux, after quitting cmux. The previous app is
# kept as /Applications/cmux.app.previous so the swap can be undone:
#   rm -rf /Applications/cmux.app && mv /Applications/cmux.app.previous /Applications/cmux.app
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="${1:-$ROOT/build/release/cmux.app}"
TARGET="/Applications/cmux.app"
BACKUP="/Applications/cmux.app.previous"

if [[ ! -x "$SOURCE/Contents/MacOS/cmux" ]]; then
  echo "error: $SOURCE is not a built cmux.app (run scripts/build-release-local.sh)" >&2
  exit 1
fi
if pgrep -f "$TARGET/Contents/MacOS/cmux" >/dev/null; then
  echo "error: cmux is running. Quit it (Cmd-Q) and run this from another terminal." >&2
  exit 1
fi

if [[ -d "$TARGET" ]]; then
  rm -rf "$BACKUP"
  mv "$TARGET" "$BACKUP"
fi
/bin/cp -R "$SOURCE" "$TARGET"
xattr -dr com.apple.quarantine "$TARGET" 2>/dev/null || true
# Refresh Launch Services so Finder and `open` pick up the new bundle.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$TARGET" || true

echo "Installed $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$TARGET/Contents/Info.plist") to $TARGET"
[[ -d "$BACKUP" ]] && echo "Previous app kept at $BACKUP"
echo "Start it with: open -a cmux"
