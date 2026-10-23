#!/usr/bin/env bash
# Build a Release cmux.app for daily use on this machine, without a signing team.
#
# Usage: scripts/build-release-local.sh [--output <dir>] [--derived-data <path>]
#
# The app keeps the stock bundle id (com.cmuxterm.app) so settings, sessions and
# permissions carry over, is signed ad hoc, and has its team-only entitlements
# dropped. The result lands in build/release/cmux.app (or <dir>/cmux.app); install
# it with scripts/install-local.sh while cmux is not running.
#
# Requirements: Xcode, rustup on ~/.cargo/bin, Go, Zig 0.16 (brew install zig@0.16;
# override with CMUX_ZIG). Without Zig the bundled `ghostty` CLI helper is a stub.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

OUTPUT_DIR="$ROOT/build/release"
DERIVED_DATA="$HOME/Library/Developer/Xcode/DerivedData/cmux-release-local"
BUNDLE_ID="com.cmuxterm.app"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output) OUTPUT_DIR="$2"; shift 2 ;;
    --derived-data) DERIVED_DATA="$2"; shift 2 ;;
    -h|--help) sed -n '2,/^set -euo/p' "$0" | grep '^#'; exit 0 ;;
    *) echo "error: unknown argument $1" >&2; exit 2 ;;
  esac
done

export PATH="$HOME/.cargo/bin:/opt/homebrew/bin:$PATH"
if [[ -z "${CMUX_ZIG:-}" && -x /opt/homebrew/opt/zig@0.16/bin/zig ]]; then
  export CMUX_ZIG=/opt/homebrew/opt/zig@0.16/bin/zig
fi
if [[ -z "${CMUX_ZIG:-}" ]] && ! command -v zig >/dev/null 2>&1; then
  echo "warning: Zig not found; the bundled ghostty CLI helper will be a stub" >&2
  export CMUX_SKIP_ZIG_BUILD=1
fi
command -v go >/dev/null 2>&1 || echo "warning: Go not found; cmuxd-remote will not be bundled (SSH workspaces need it)" >&2

if [[ ! -d GhosttyKit.xcframework ]]; then
  ./scripts/download-prebuilt-ghosttykit.sh
fi
export CMUX_GHOSTTYKIT_PREPROVISIONED=1
export CMUX_DEV_BACKEND_MODE=local

LOG="$OUTPUT_DIR/build.log"
mkdir -p "$OUTPUT_DIR"
echo "==> Building Release (log: $LOG)"
XCODEBUILD_ARGS=(
  -project cmux.xcodeproj
  -scheme cmux
  -configuration Release
  -destination 'platform=macOS'
  -derivedDataPath "$DERIVED_DATA"
  PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID"
  CODE_SIGN_IDENTITY=-
  CODE_SIGN_STYLE=Manual
  DEVELOPMENT_TEAM=
  CODE_SIGN_ENTITLEMENTS=
  CMUX_CUA_HELPER_DISPLAY_NAME="cmux Computer Use"
)
if [[ "${CMUX_SKIP_ZIG_BUILD:-}" == "1" ]]; then
  XCODEBUILD_ARGS+=(CMUX_SKIP_ZIG_BUILD=1)
fi
if ! xcodebuild "${XCODEBUILD_ARGS[@]}" build >"$LOG" 2>&1; then
  grep -E 'error:|BUILD FAILED' "$LOG" | head -40 >&2
  echo "error: build failed, see $LOG" >&2
  exit 1
fi

BUILT_APP="$DERIVED_DATA/Build/Products/Release/cmux.app"
APP="$OUTPUT_DIR/cmux.app"
rm -rf "$APP"
/bin/cp -cR "$BUILT_APP" "$APP"

# Xcode normally assembles these helpers; build them here if it did not.
if [[ ! -x "$APP/Contents/Resources/bin/ghostty" && "${CMUX_SKIP_ZIG_BUILD:-}" != "1" ]]; then
  mkdir -p "$APP/Contents/Resources/bin"
  ./scripts/build-ghostty-cli-helper.sh --output "$APP/Contents/Resources/bin/ghostty"
fi
CUA_APP="$APP/Contents/Library/cmux Computer Use.app"
if [[ ! -x "$CUA_APP/Contents/MacOS/cmux-cua" ]]; then
  ./scripts/build-cmux-cua.sh --output "$ROOT/build/cmux-cua/cmux-cua" --helper-app "$CUA_APP"
fi

xattr -cr "$APP" || true
/usr/bin/codesign --force --sign - --timestamp=none --generate-entitlement-der "$APP"
/usr/bin/codesign --verify --deep --strict "$APP"

version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
commit="$(git rev-parse --short HEAD)"
echo "==> Built cmux $version ($commit): $APP"
echo "    Install (quit cmux first): scripts/install-local.sh \"$APP\""
