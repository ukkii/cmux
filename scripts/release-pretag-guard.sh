#!/usr/bin/env bash
set -euo pipefail

# The only pre-tag check was the Sparkle build-number monotonic guard, which was
# removed together with the auto-updater. The script stays as a stable hook for
# the release commands that call it.
echo "Running release pre-tag checks..."
echo "Release pre-tag checks passed."
