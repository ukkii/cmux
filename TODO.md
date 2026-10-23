# TODO

## Privacy review follow-ups (2026-10-22)

Source: a read-only Codex audit of `281678dbbb1` ("paranoid privacy-focused DevOps"
brief: nothing shown, typed, pasted or stored in a terminal may leave the machine or
reach another process without an explicit user action), with each finding re-checked
against the code by Claude. None of these is critical: nothing sends terminal content
off the machine on its own. Numbers match the Codex report.

### 1. Quick fixes (one branch, ~1 hour)

- [ ] **#2 Omnibar search suggestions send typed text before Enter.** On by default
  (`Packages/macOS/CmuxSettings/Sources/CmuxSettings/Stores/BrowserSearchSettingsStore.swift:22`);
  typing more than one non-URL character queries Google, DuckDuckGo and Bing at once
  (`Sources/Panels/BrowserPanelView.swift:2792`, `Sources/Panels/BrowserPanel.swift:1867`).
  A pasted token can leave before submit. Fix: default off, query only the selected
  provider, longer debounce. This is the only automatic upload of user input left.
- [ ] **#13 "Copy Image" sends every cookie in the browser profile to the image host.**
  `Packages/macOS/CmuxBrowser/Sources/CmuxBrowser/WebView/CmuxWebView.swift:2132`
  uses `getAllCookies` with no domain/path/Secure filter, plus the full page URL as
  `Referer`. A bug. Fix: reuse the scoped cookie filter used by downloads, origin-only
  referrer.
- [ ] **#7 OSC 52 clipboard writes are allowed without asking.** Ghostty default
  `clipboard-write = allow`; local PTYs, including a plain `ssh` inside a terminal,
  can write to the pasteboard (`Packages/macOS/CmuxTerminal/Sources/CmuxTerminal/Surface/TerminalSurface.swift:251`,
  `Sources/GhosttyTerminalView.swift:833`). Universal Clipboard can sync it to other
  Apple devices. Reads already ask. Fix: default to `ask`. Workaround now:
  `clipboard-write = ask` in the Ghostty config.
- [ ] **#19 cmuxd-remote download fallback.** If the bundled asset is missing,
  `RemoteSessionCoordinator+Bootstrap.swift:301` downloads the manifest URL
  (SHA-256 checked). Unreachable in a complete build, since all four platforms are
  bundled. Fix: fail closed with an error instead of downloading.
- [ ] **#16 React Grab hash check is skipped for non-default versions**
  (`Sources/Panels/ReactGrab.swift:12`, `:123`). Explicitly triggered only. Fix: reject
  versions without a known hash, or bundle the script.
- [ ] **#15 Favicon fetched by cmux itself from a page-chosen host**
  (`Sources/Panels/BrowserPanel.swift:5142`, `:5251`). Only after you open a page.
  Fix: same-origin icons only, or use WebKit's cached resource.
- [ ] **REMOVED.md accuracy:** document the #19 fallback, GitHub PR polling cadence
  (10 s for the selected workspace, 60 s in the background) and its use of
  `GH_TOKEN`/`GITHUB_TOKEN`/`gh auth token`. Note that the zsh `gh pr view` loop is
  dead and the polling is native Swift (`PullRequestPollService.swift:181`).

### 2. "Paranoid mode" (one opt-in setting)

Everything below is local-only. `~/Library/Application Support/cmux` is `0700`, so other
macOS users cannot read it. The files themselves are `0644` (checked on disk). The real
risks are same-user malware and unencrypted Time Machine backups.

- [ ] Do not persist scrollback (#10: up to 4,000 lines per pane, checkpointed every
  60 s, `Sources/SessionPersistence.swift:37`, `Sources/SessionScrollbackCheckpoint.swift:5`).
- [ ] Disable the global search index (#9: plaintext SQLite with terminal scrollback,
  agent transcripts and `document.body.innerText`, `Sources/Search/SearchIndex.swift`).
- [ ] Do not keep the per-surface command history copy (#11:
  `terminal-history/surface-*.history`, written by the bash/zsh integration).
- [ ] Generic notification previews on the lock screen, and no notification bodies in
  `notification-feed-history-*.json` (#12).
- [ ] Minimize or redact agent hook spool bodies (up to 256 KiB), add a TTL to agent
  journals (#20).
- [ ] Do not auto-reconnect restored SSH workspaces (#5) or auto-reload restored browser
  panes (#6).
- [ ] Turn off GitHub PR polling (#3: sends repo and branch names to GitHub with your
  `gh` token; kept on deliberately for now).
- [ ] Independent of the mode: create all of these files `0600` and SQLite WAL/SHM files
  with explicit modes; private `0700` temp roots for clipboard images and remote previews,
  with a stale-file sweep at startup (#21).

### 3. Per-surface socket capabilities (larger project)

- [ ] **#1 Any process in any cmux terminal gets full control of cmux.** In the default
  `cmuxOnly` mode, every descendant of cmux and every holder of the inherited capability
  is authorized (`Packages/macOS/CmuxControlSocket/Sources/CmuxControlSocket/Transport/SocketClientAuthorization.swift:46`;
  capability injected at `Sources/TerminalSurfaceRuntimeWiring.swift:81`). With that
  access a process can read the scrollback of every pane, send input to any pane, and run
  JavaScript or read storage in browser panes. Example: a malicious `npm` postinstall
  script in one pane reads secrets printed in another. This is by design, because agents,
  notifications and the CLI depend on it. Workaround: socket mode `off`, which breaks
  agent integration. Fix: capabilities scoped to the caller's own surface, narrow method
  sets, revocation, and an explicit prompt for cross-surface reads or input.

### Low priority / not leaks (keep in mind)

- #4 A remote relay can trigger a local notification command hook. This only matters if
  you configure a notification `command` hook. If you do, force it off for remote origins.
- #8 `allowAll` socket mode (`0666`): set only by tagged dev builds, never in Release.
  Consider deleting the mode.
- #14 Release webviews are inspectable, and the console-capture script is always injected.
  Disable inspection in Release and capture only during DevTools sessions.
- #17 SSH agent forwarding follows `~/.ssh/config` like plain `ssh`. Consider forcing
  `ForwardAgent=no` unless requested.
- #18 `cmuxd-remote serve --ws` accepts a non-loopback address without TLS. This only
  happens when run manually that way. Reject it without an explicit flag.
- #22 Raw `NSLog` of URLs, paths and commands. Debug builds only.
- #23 Supply chain: `cmux omo` installs unpinned npm/bun packages (user-run command);
  `scripts/install-rust-ci.sh` uses `curl | sh` with floating `stable`; `install-zig-ci.sh`
  makes signature checks optional; `skills.sh` uses `curl | bash` on upstream `main`.
  None of these is used by the local build. Pin them or delete them.
- #24 Apple intermediate certificates are imported without pinned fingerprints (release
  signing script, unused here).
- #25 AgentChat theme sync can POST appearance data to any configured host. Off by
  default.
- Leftovers from the upstream app in `~/Library/Application Support/cmux`:
  `mobile-host-device-id` and `.phone-push-queue-v1.json.lock`. Harmless, can be
  deleted.

### Checked and clean (per Codex, spot-checked)

No live Sparkle, PostHog, Sentry, remote feature flags, billing/account, crash upload or
update checks. The control socket is `~/.local/state/cmux/cmux.sock`, `0600`, with
ownership checks. Remote relay uses HMAC plus ownership checks and a closed allowlist
(except #4). Shell integration does not transmit command lines. The agent hook
environment uses an allowlist that excludes API-token variables. GhosttyKit downloads are
checksum-pinned. `Cargo.lock`, `go.sum` and `Package.resolved` are present. Nothing is
exported to Spotlight.

## Upstream roadmap (inherited from manaflow-ai/cmux, not maintained here)


### Issue 151: Remote SSH (Living Execution)
- [x] `cmux ssh` creates remote workspace metadata and does not require `--name`
- [x] Remote daemon bootstrap/upload/start path with `cmuxd-remote serve --stdio`
- [x] Reconnect/disconnect controls (CLI/API/context menu) + improved error surfacing
- [x] Retry count/time surfaced in remote daemon/probe error details
- [ ] Remove automatic remote service port mirroring (`ssh -L` from detected remote listening ports)
- [ ] Add transport-scoped proxy broker (SOCKS5 + HTTP CONNECT) for remote traffic
- [ ] Extend `cmuxd-remote` RPC beyond `hello/ping` with proxy stream methods (`proxy.open|close`)
- [ ] Auto-wire WKWebView in remote workspaces to proxy via `WKWebsiteDataStore.proxyConfigurations`
- [ ] Add browser proxy e2e tests (remote egress IP, websocket, reconnect continuity)
- [ ] Implement PTY resize coordinator with tmux semantics (`smallest screen wins`)
- [ ] Add resize tests for multi-attachment sessions (attach/detach/reconnect transitions)

### Socket API / Agent
- [x] Add window handles + `window.list/current/focus/create/close` for multi-window socket control (v2) + v1 equivalents (`list_windows`, etc) + CLI support.
- [x] Add surface move/reorder commands (move between panes, reorder within pane, move across workspaces/windows).
- [x] Add browser automation API inspired by `vercel-labs/agent-browser`, but backed by cmux's WKWebView (wait, click, type, eval, screenshot, etc.).
- [x] Finalize browser parity contract and command mapping decisions in `docs/agent-browser-port-spec.md`.
- [x] Add `cmux browser` command surface that mirrors agent-browser semantics and targets explicit `surface_id` handles.
- [x] Add short handle refs (`surface:N`, `pane:N`, `workspace:N`, `window:N`) and CLI `--id-format refs|uuids|both` output control.
- [x] Add v1->v2 compatibility shim for migrated browser/topology commands while v1 remains supported.
- [x] Port browser automation coverage to `tests_v2/` per `docs/agent-browser-port-spec.md` and keep v1 + v2 suites green.
  - Added `tests_v2/test_browser_api_comprehensive.py`, `tests_v2/test_browser_api_p0.py`, `tests_v2/test_browser_api_extended_families.py`, `tests_v2/test_browser_api_unsupported_matrix.py`, and `tests_v2/test_browser_cli_agent_port.py`.
  - Full VM runs: `./scripts/run-tests-v1.sh` and `./scripts/run-tests-v2.sh` passing (v2 visual D12 remains reported as a known non-blocking VM failure, matching v1 policy).
- [x] Fix `cmux browser open|open-split|new` URL parsing so routing flags (`--workspace`, `--window`) are removed before URL construction.
- [x] Fix `identify --workspace/--surface` caller parsing to honor ref handles (`workspace:N`, `surface:N`) instead of falling back to current/focused IDs.
- [x] Update `browser.open_split` placement policy: reuse nearest right sibling pane first (nested-aware), only create a new split when caller has no right sibling.
- [x] Upgrade `browser.snapshot` to agent-browser-style output (`snapshot` tree text + `refs`) and make non-JSON CLI output print snapshot content instead of `OK`.
- [x] Add richer selector failure diagnostics (`hint`, counts, sample, snapshot excerpt) with bounded retries for transient `not_found` races.
- [x] Add regression coverage for browser placement policy + snapshot/ref output + diagnostics in v2 tests.
- [x] Allow `browser fill` with empty text (clear input) in CLI + v2 API flows.
- [x] Make legacy `new-pane`/`new-surface` CLI output prefer short `surface:N` refs by default.
- [x] Add optional `--snapshot-after` / `snapshot_after` action feedback to include a fresh post-action browser snapshot.
- [x] Switch CLI `--json` default ID output to refs-first (UUIDs only via `--id-format uuids|both`) and add regression coverage.
- [x] Expand end-user skill docs with deep-linkable cmux-browser references/templates plus a new core `skills/cmux/` topology skill.

### Command Palette
- [ ] Add cmd+shift+p palette with all commands

### Feature Requests
- [ ] Warm pool of Claude Code instances mapped to a keyboard shortcut

### Claude Code Integration
- [ ] Add "Install Claude Code integration" menu item in menubar
  - Opens a new terminal
  - Shows user the diff to their config file (claude.json, opencode config, codex config, etc.)
  - Prompts user to type 'y' to confirm
  - Implement as part of `cmux` CLI, menubar just triggers the CLI command

### Additional Integrations
- [ ] Codex integration
- [ ] OpenCode integration

### Browser
- [ ] Per-WKWebView proxy observability/inspection once remote proxy path is shipped (URL, method, headers, body, status, timing)

### Bugs
- [ ] **P0** Terminal title updates are suppressed when workspace is not focused (e.g. Claude Code loading indicator doesn't update in sidebar until you switch to that tab)
- [ ] Sidebar tab reorder can get stuck in dragging state (dimmed tab + blue drop indicator line visible) after drag ends
- [ ] Drag-and-drop files/images into terminal shows URL instead of file path (Ghostty supports dropping files as paths)
- [ ] After opening a browser tab, up/down arrow keys (and possibly other keyboard shortcuts) stop working in the terminal
- [ ] Notification marked unread doesn't get pushed to the top of the list
- [ ] Browser cmd+shift+H ring flashes only once (should flash twice like other shortcuts)

### Refactoring
- [ ] **P0** Remove all index-based APIs in favor of short ID refs (surface:N, pane:N, workspace:N, window:N)
- [ ] **P0** CLI commands should be workspace-relative using CMUX_WORKSPACE_ID env var (not focused workspace) so agents in background workspaces don't affect the user's active workspace. Affected: send, send-key, send-panel, send-key-panel, new-split, new-pane, new-surface, close-surface, list-panes, list-pane-surfaces, list-panels, focus-pane, focus-panel, surface-health
- [ ] **P0** Remove `close-workspace` with no args — require explicit workspace short ID or UUID, with clear error message if missing

### UI/UX Improvements
- [ ] Show loading indicator in terminal while it's loading
- [ ] Add question mark icon to learn shortcuts
- [ ] Notification popover: each button item should show outline outside when focused/hovered
- [ ] Notification popover: add right-click context menu to mark as read/unread
- [ ] Right-click tab should allow renaming that workspace
- [ ] Cmd+click should open links in cmux (browser panel) instead of external browser
- [ ] "Waiting for input" notification should include custom terminal title if set
- [ ] Close button for current/active tab should always be visible (not just on hover)
- [ ] Add browser icon to the left of the plus button in the tab bar

### Analytics
- [x] Add PostHog tracking (set `PostHogAnalytics.apiKey` in `Sources/PostHogAnalytics.swift`)

### Browser Parity Completion (agent-browser port)
- [x] Implement locator family:
  - `browser.find.role`
  - `browser.find.text`
  - `browser.find.label`
  - `browser.find.placeholder`
  - `browser.find.alt`
  - `browser.find.title`
  - `browser.find.testid`
  - `browser.find.first`
  - `browser.find.last`
  - `browser.find.nth`
- [x] Implement frame/dialog/download:
  - `browser.frame.select`
  - `browser.frame.main`
  - `browser.dialog.accept`
  - `browser.dialog.dismiss`
  - `browser.download.wait|list`
- [x] Implement session/context state APIs:
  - `browser.cookies.get|set|clear`
  - `browser.storage.get|set|clear`
  - `browser.tab.new|list|switch|close`
  - `browser.state.save|load`
- [x] Implement developer/diagnostic helpers:
  - `browser.console.list|clear`
  - `browser.errors.list`
  - `browser.highlight`
  - `browser.addinitscript`
  - `browser.addscript`
  - `browser.addstyle`
- [x] Add explicit `not_supported` for WebKit/CDP-gap commands:
  - `browser.viewport.set`
  - `browser.geolocation.set`
  - `browser.offline.set`
  - `browser.trace.start|stop`
  - `browser.network.route|unroute|requests`
  - `browser.screencast.start|stop`
  - `browser.input_mouse|input_keyboard|input_touch`
- [x] Extend `cmux browser ...` CLI grammar for the new families (including aliases).
- [x] Port/add v2 tests for all newly implemented families.
- [x] Update unsupported matrix tests to assert `not_supported` for hard platform gaps (instead of `method_not_found`).
- [x] Re-run full `run-tests-v1.sh` and `run-tests-v2.sh` on `cmux-vm`.
