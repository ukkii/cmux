<h1 align="center">cmux (local fork)</h1>
<p align="center">A Ghostty-based macOS terminal with vertical tabs and notifications for AI coding agents, stripped down to a local desktop app</p>

<p align="center">
  <img src="./docs/assets/main-first-image.png" alt="cmux screenshot" width="900" />
</p>

## What this fork is

This repository is a fork of [manaflow-ai/cmux](https://github.com/manaflow-ai/cmux)
that keeps only the local terminal. Everything that talks to cmux's servers or
asks you to sign in is removed:

- no auto-updater (Sparkle), no update checks;
- no analytics, telemetry, crash reporting (Sentry, PostHog) or feedback upload;
- no cmux Cloud machines, VPN, Cloud workspaces or the SSH-TUI client;
- no account, sign-in, teams, Pro plan or billing;
- no iOS app, device pairing, terminal sharing or iroh networking;
- no server code (`web/`, workers, relay services) and none of upstream's CI.

[REMOVED.md](REMOVED.md) lists exactly what was removed and what changes for the
user. There are no prebuilt releases: build the app yourself as described below.

## Features

- **Notification rings and panel**: panes get a ring and tabs light up when a coding
  agent needs your attention; all pending notifications are in one panel.
- **Vertical and horizontal tabs**: the sidebar shows git branch, PR status, working
  directory, listening ports and the latest notification; split panes freely.
- **In-app browser**: a scriptable browser pane next to your terminal.
- **SSH**: `cmux ssh user@remote` opens a workspace for a remote machine (your own
  SSH, no cmux service involved).
- **Agent integrations**: Claude Code, Codex, OpenCode and others, including
  `cmux claude-teams` teammate splits.
- **Programmable**: a CLI and a local Unix socket API for workspaces, panes, keys
  and the browser.
- **Ghostty compatible**: reads `~/.config/ghostty/config` for themes, fonts and
  colors; rendering is libghostty, GPU-accelerated.
- **Native**: Swift and AppKit, not Electron.

## Building locally

Requirements:

- macOS 14 or later and Xcode 26 (with its Metal toolchain component).
- [Rust via rustup](https://rustup.rs) (`~/.cargo/bin` on `PATH`): the build
  compiles the bundled Rust helpers with `cargo`.
- Python 3 (ships with the Xcode command line tools).

```bash
git clone --recursive https://github.com/ukkii/cmux.git
cd cmux
git submodule update --init --recursive

# Fetch the pinned, checksum-verified GhosttyKit.xcframework instead of
# building Ghostty with Zig.
./scripts/download-prebuilt-ghosttykit.sh

# Build a tagged Debug app ("cmux DEV dev.app"); add --launch to open it.
PATH=~/.cargo/bin:$PATH \
CMUX_DEV_BACKEND_MODE=local \
CMUX_GHOSTTYKIT_PREPROVISIONED=1 \
CMUX_SKIP_ZIG_BUILD=1 \
./scripts/reload.sh --tag dev --build-only
```

What the environment variables do:

- `CMUX_DEV_BACKEND_MODE=local`: do not look for upstream's shared dev backend.
- `CMUX_GHOSTTYKIT_PREPROVISIONED=1`: use the GhosttyKit you downloaded above.
- `CMUX_SKIP_ZIG_BUILD=1`: skip the Zig build of Ghostty's helper binaries.

A tagged build runs side by side with any installed cmux and uses its own bundle id,
socket and settings domain. Do not build with bare `xcodebuild`; always go through
`scripts/reload.sh --tag <name>`. Before a native build, `python3 scripts/verify-local.py`
runs the fast static checks; [CONTRIBUTING.md](CONTRIBUTING.md) has more detail.

## Install

There are no published releases. Build a Release app and install it over
`/Applications/cmux.app`:

```bash
brew install go zig@0.16      # Go bundles cmuxd-remote, Zig builds the ghostty CLI helper
./scripts/build-release-local.sh   # -> build/release/cmux.app
# Quit cmux, then from another terminal (e.g. Terminal.app):
./scripts/install-local.sh
```

The app keeps the stock bundle id `com.cmuxterm.app`, so settings, sessions and
granted permissions carry over. It is signed ad hoc (no Apple team), so macOS may ask
again for folder, accessibility or automation access on first launch. The previous app
is kept as `/Applications/cmux.app.previous`. To update, pull and run both scripts again.

## Documentation

- [Configuration](docs/configuration.md) and [customizing the look](docs/customizing-appearance.md)
- [Shell integration](docs/shell-integration.md) and [notifications](docs/notifications.md)
- [Agent hooks](docs/agent-hooks.md) and the [CLI contract](docs/cli-contract.md)
- [Managed device policies (MDM)](docs/managed-device-policies.md)

Upstream's online docs at cmux.com describe the full product, including features
this fork removed.

## License

cmux is open source under [GPL-3.0-or-later](LICENSE). Third-party components are
listed in [THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md).
