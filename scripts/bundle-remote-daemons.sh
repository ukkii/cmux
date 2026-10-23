#!/bin/bash
# Cross-compile cmuxd-remote for every supported SSH target and seal the
# binaries into the app bundle, so `cmux ssh` works in a locally built app
# without downloading anything.
#
# Runs from scripts/build-app-bundled-resources.sh (an Xcode build phase, so
# before code signing). It:
#   1. builds darwin/linux x arm64/amd64 daemons with the release asset script,
#      versioned with the app's CFBundleShortVersionString (the version the
#      session coordinator asks for);
#   2. embeds the matching CMUXRemoteDaemonManifestJSON into the built
#      Info.plist and writes Contents/Resources/remote-daemons/*.deflate, which
#      RemoteDaemonManifestRepository installs before it would ever download.
#
# Missing Go is not fatal: the phase prints a warning and the app keeps the
# previous behaviour (no manifest, `cmux ssh` reports a missing daemon).
# Set CMUX_SKIP_REMOTE_DAEMON_BUNDLE=1 to skip the step entirely.
set -euo pipefail

warn() {
  echo "warning: cmuxd-remote bundling skipped: $*" >&2
}

if [ "${CMUX_SKIP_REMOTE_DAEMON_BUNDLE:-}" = "1" ]; then
  warn "CMUX_SKIP_REMOTE_DAEMON_BUNDLE=1"
  exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SRCROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
DAEMON_ROOT="$REPO_ROOT/daemon/remote"
RELEASE_ASSETS_SCRIPT="$REPO_ROOT/scripts/build_remote_daemon_release_assets.sh"
VERIFY_SCRIPT="$REPO_ROOT/scripts/verify_remote_daemon_release.py"

if [ -z "${TARGET_BUILD_DIR:-}" ] || [ -z "${WRAPPER_NAME:-}" ]; then
  warn "TARGET_BUILD_DIR/WRAPPER_NAME are not set (not an app build phase)"
  exit 0
fi
APP="$TARGET_BUILD_DIR/$WRAPPER_NAME"
INFO_PLIST="$APP/Contents/Info.plist"
BUNDLED_DIR="$APP/Contents/Resources/remote-daemons"
if [ ! -f "$INFO_PLIST" ]; then
  warn "missing $INFO_PLIST"
  exit 0
fi
if [ ! -f "$DAEMON_ROOT/go.mod" ] || [ ! -f "$RELEASE_ASSETS_SCRIPT" ] || [ ! -f "$VERIFY_SCRIPT" ]; then
  warn "daemon sources or release scripts are missing under $REPO_ROOT"
  exit 0
fi

# Xcode script phases do not inherit a login-shell PATH.
export PATH="${PATH:+${PATH}:}/opt/homebrew/bin:/usr/local/bin:/usr/local/go/bin"
if ! command -v go >/dev/null 2>&1; then
  warn "go was not found on PATH ($PATH); install Go to bundle the SSH daemon"
  exit 0
fi
# Go's caches default under $HOME; keep that explicit for non-login shells.
export HOME="${HOME:-$(cd ~ && pwd)}"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST" 2>/dev/null || true)"
if [ -z "$VERSION" ]; then
  warn "CFBundleShortVersionString is missing from $INFO_PLIST"
  exit 0
fi

ASSETS_DIR="${DERIVED_FILE_DIR:-${TARGET_TEMP_DIR:-$TARGET_BUILD_DIR}}/cmuxd-remote-assets"
STAMP="$ASSETS_DIR/.cmux-source-fingerprint"
MANIFEST="$ASSETS_DIR/cmuxd-remote-manifest.json"

run_git() (
  unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE
  unset GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_PREFIX
  command git "$@"
)

# Key the cross-compiled assets to the daemon sources, the Go toolchain, the
# version baked into the binaries and the scripts that produce them.
source_fingerprint() {
  {
    printf 'version=%s\n' "$VERSION"
    printf 'go=%s\n' "$(go version 2>/dev/null || echo unknown)"
    shasum "$RELEASE_ASSETS_SCRIPT" "$VERIFY_SCRIPT" "$REPO_ROOT/scripts/generate_remote_daemon_release_manifest.py" 2>/dev/null || true
    if run_git -C "$REPO_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      run_git -C "$REPO_ROOT" ls-files -s -- daemon/remote 2>/dev/null || true
      run_git -C "$REPO_ROOT" diff --binary HEAD -- daemon/remote 2>/dev/null || true
      (cd "$REPO_ROOT" && run_git ls-files --others --exclude-standard -z -- daemon/remote 2>/dev/null | xargs -0 shasum) || true
    else
      find "$DAEMON_ROOT" -type f \( -name '*.go' -o -name 'go.mod' -o -name 'go.sum' \) -print0 \
        | LC_ALL=C sort -z | xargs -0 shasum
    fi
  } | shasum | awk '{print $1}'
}

fingerprint="$(source_fingerprint)"
if [ -f "$STAMP" ] && [ -f "$MANIFEST" ] && [ "$(cat "$STAMP")" = "$fingerprint" ]; then
  echo "cmuxd-remote $VERSION assets unchanged; reusing $ASSETS_DIR"
else
  echo "Building cmuxd-remote $VERSION for darwin/linux x arm64/amd64"
  rm -f "$STAMP"
  mkdir -p "$ASSETS_DIR"
  # The release tag and repo only shape the manifest's informational URLs.
  # The bundled assets are installed first, so these URLs are never fetched.
  if ! bash "$RELEASE_ASSETS_SCRIPT" \
    --version "$VERSION" \
    --release-tag local \
    --repo ukkii/cmux \
    --output-dir "$ASSETS_DIR"; then
    echo "error: failed to build cmuxd-remote assets (see output above)" >&2
    exit 1
  fi
  printf '%s\n' "$fingerprint" > "$STAMP"
fi

# Re-embed on every build: Xcode regenerates Info.plist whenever its inputs
# change. Recompress the sealed copies only when they are missing or stale.
if python3 "$VERIFY_SCRIPT" --manifest "$MANIFEST" --assets-dir "$ASSETS_DIR" \
  --app "$APP" --embed --require-bundled-assets >/dev/null 2>&1; then
  echo "Embedded cmuxd-remote $VERSION manifest; bundled daemons are current"
else
  rm -rf "$BUNDLED_DIR"
  python3 "$VERIFY_SCRIPT" --manifest "$MANIFEST" --assets-dir "$ASSETS_DIR" \
    --app "$APP" --embed --bundle-assets
fi
