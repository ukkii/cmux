# Removed functionality

This fork (`ukkii/cmux`) strips cmux down to the terminal itself. Everything that
updates the app on its own, asks you to sign in or buy something, or sends
telemetry, metrics or crash reports off the machine is removed. This file records
what was removed and what changes for the user.

## Auto-update (Sparkle)

cmux no longer contains a built-in updater. The Sparkle framework and the app's own
updater packages (`CmuxUpdater`, `CmuxUpdaterUI`) are removed from the app and the
Xcode project, so the app never contacts an update feed.

What users see:

- **No update checks.** The app never checks for, downloads or installs updates,
  and no Sparkle helper processes or XPC services ship in the bundle. To update,
  build and install a newer version by hand.
- **Menu items removed:** "Check for Updates…" (app menu, Help menu, sidebar Help
  popover, menu-bar status item), "Install Update", and the debug "Copy Update Logs"
  ("Copy Focus Logs" stays).
- **Sidebar and command palette:** the update pill in the sidebar footer and its
  popover are gone, as are the palette commands "Check for Updates", "Apply Update
  (If Available)" and "Attempt Update".
- **MDM policy key:** `DisableAutoUpdate` no longer exists.
- **Quitting:** no special "update relaunch" quit path or session save.
- **Info.plist:** no `SU*` keys (feed URL, public EdDSA key, check schedule) and no
  `SPARKLE_PUBLIC_KEY` build setting.
- **Release pipeline:** no appcasts or delta updates are generated, signed or
  uploaded; Sparkle-only scripts, their tests and the appcast repair workflow are
  deleted.
- **Logs:** `~/Library/Logs/cmux-update.log` is no longer written.

Kept on purpose: `Sources/Update/UpdateTitlebarAccessory.swift` and its neighbours
host the general titlebar controls and the notifications popover, not update UI.
`UpdateLogStore.swift` was renamed to `FocusLogStore.swift`, keeping only the focus
log.

## Analytics, telemetry, crash reporting and feedback

cmux no longer sends anything about you or your usage off the machine. The Sentry
crash-reporting SDK (`sentry-cocoa`) and the PostHog analytics SDK (`posthog-ios`)
are removed from the app, CLI and Xcode project, along with cmux's own
product-analytics, feedback and Sentry helper packages (`CmuxProductAnalytics`,
`CmuxFeedback`, `CmuxSentryTelemetry`) and the iOS crash/analytics packages that
depended on them (`CmuxMobileCrashReporting`, `CmuxMobileAnalytics`).

What users see:

- **No crash reports or usage analytics.** The app and the `cmux` CLI no longer
  start Sentry, record breadcrumbs, upload crash or hang reports, or send PostHog
  events (launches, daily activity, feature use, sign-in, upgrade clicks, Cloud
  funnel). A Ghostty crash from the previous run is still detected locally.
- **No remote feature flags.** cmux no longer contacts `cmux.com/api/client-config`
  and no longer creates an anonymous install id. Flags use built-in defaults or
  local overrides; values cached from earlier remote fetches are cleared at launch.
- **No Cloud span uploads.** Cloud operations are recorded only for the local
  diagnostics view.
- **No feedback submission.** Help → "Send Feedback", the sidebar Help popover item,
  the Cloud loading panel button, the Send Feedback shortcut, the `cmux feedback`
  CLI command and the `feedback.open`, `feedback.submit` and
  `dogfood.feedback.submit` socket methods are removed. (Settings → "Send Feedback"
  only opens the GitHub issues page and stays.)
- **Profiling stays local.** "Profile cmux" in the menu bar still records an
  Instruments capture but no longer offers to email it; the window shows
  "Show in Finder" instead, and the `submit-cmux-profile` helper is gone.
- **Settings:** "Send anonymous telemetry" (`app.sendAnonymousTelemetry`) is gone
  from Settings, the command palette, settings search and the `cmux.json` schema.
  A leftover key in an existing `cmux.json` is ignored.
- **MDM policy key:** `DisableTelemetry` no longer exists.
- **CodeRouter CLI:** `coderouter` no longer posts lifecycle events to
  `/api/coderouter/analytics`.
- **Debug builds:** `CMUX_RUNTIME_DEBUG_*` no longer posts debug events to a log
  server; they go to the local debug log only.
- **Release pipeline:** dSYMs are no longer uploaded to Sentry; Sentry-only helper
  scripts and the terminal-hang release gate are deleted.

Kept on purpose: local diagnostics that never leave the machine (debug log, startup
breadcrumb log, local Ghostty crash marker scan, memory-pressure and main-thread
hang monitoring, the Cloud diagnostics view). GhosttyKit is still built with its
own Sentry turned off.

## Cloud tunnel and SSH transport

The cmux Cloud packet-tunnel system extension (`cmuxTunnel.systemextension`, built on
WireGuardKit/wireguard-go) is gone. The app no longer bundles or installs a system
extension, never asks for System Extension or VPN approval, and its signature no
longer claims the NetworkExtension, system-extension install or app-group
entitlements. The `NSSystemExtensionUsageDescription` prompt string and the "Cloud
VPN" setup pane are removed, and a VPN configuration saved by an earlier version is
no longer adopted or managed.

Cloud machines, iOS pairing, My Devices and workspace presence are switched off:
cmux no longer restores a cmux account session at launch and opens no connections
to cmux services. (Their code is deleted in the following steps.)

`cmux ssh` (and `ssh://` links) now always use the classic cmuxd-remote transport,
interactive sessions included, instead of the cmux-tui SSH carrier, which was built
on Cloud code. Workspaces saved by the cmux-tui carrier still restore, but reconnect
with a plain `ssh` command rather than reattaching to the old cmux-tui session.

## Mobile app pairing, devices and peer networking

- The Mac can no longer pair with or be controlled from the cmux iPhone/iPad app.
  The Mobile Pairing workspace, the sidebar iPhone button, the "Open Mobile Pairing"
  palette and menu actions and the `cmux.mobileconnect` tab-bar action are gone;
  configs that still name that action ignore it.
- Agent notifications are no longer forwarded to the phone, and phone replies to
  notifications are no longer received. The "Forward notifications to my iPhone"
  controls are gone.
- My Devices is gone: no discovery of or connection to your other Macs, no Devices
  section in the sidebar, no Settings › Devices pane.
- Iroh/relay peer networking is gone, including Settings › Networking, the
  Debug › Iroh Transport menu and `cmux iroh-diag`. The app no longer bundles
  iroh-ffi or embeds Iroh relay-policy keys.
- Shared terminal sizing is gone: the size panel and bounds overlay, "Size Terminal
  to My Window" (Ctrl+Opt+Cmd+=), "Show Terminal Size Panel", "Disconnect Other
  Terminal Clients", and `cmux surface size|participants|size-policy|size-to-me|size-counts|disconnect-participant|disconnect-others`.
- Workspace presence avatars are gone.
- Removed CLI commands: `cmux mobile …`. `cmux settings open` no longer accepts
  `networking`, `computers` or `devices`.
- Removed socket methods: every `mobile.*` method, the `terminal.create/input/replay/viewport/scroll/mouse/paste_image`
  aliases, `terminal.size_*`, `terminal.participant(s).disconnect*`,
  `debug.mobile.transport.*`, the `mobile_connect` workspace action and v1
  `iroh_diag`. `terminal.paste` is kept (used by `cmux paste`).
- Removed settings: the cmux.json `mobile` section and the feature flags
  `mobile-connect-button`, `mobile-workspace-changes`, `ios-artifact-chip`,
  `mobile-task-composer`, `mac-account-directory`. A leftover `mobile` key in
  cmux.json is reported as unknown by schema validation.
- MDM keys DisableRemoteControl, DisableDeviceDiscovery, DisableIncomingDeviceAccess
  and DisableIrohNetworking are removed.

## cmux Cloud

cmux no longer includes cmux Cloud. Cloud machines and VMs, Cloud workspaces, the
Cloud sidebar, the private network and every client of the cmux Cloud backend are
removed from the app, the `cmux` CLI and the Xcode project, including the packages
`CmuxCloud`, `CmuxCloudBannerCore`, `CmuxCloudImagePaste`, `CmuxCloudMachines`,
`CmuxCloudResizeCore`, `CmuxCloudTui` and `CmuxTerminalSizing`.

What users see:

- **No Cloud machines.** No creating, opening, attaching to, snapshotting, forking,
  resizing or deleting Cloud VMs; no Cloud desktops, port forwarding, published
  domains, or file push/pull / drag-and-drop to a VM.
- **UI removed:** the right-sidebar Cloud/Machines tab, the sidebar Cloud button,
  Cloud workspace badges, the Cloud team picker, "New Cloud Workspace" / "New Cloud
  Machine", the Cloud welcome window, Cloud loading/failure panes, the Cloud
  reconnect overlay, Settings → Cloud Machines and its beta toggle, Cloud palette
  commands, and the shortcuts for the team picker, new Cloud workspace/machine, the
  Machines sidebar and Cmd+Y.
- **CLI commands removed:** `cmux vm`, `cmux cloud`, `cmux remotes`,
  `cmux ai-accounts`, `cmux billing`, `cmux vpn`, `cmux surface ls/open/new-terminal`,
  and the hidden `vm-pty-*`, `vm-tui-*`, `vm-ssh-attach` helpers. `cmux agent` only
  handles local agents (message, inbox, messages, hibernate, wake).
- **Socket API:** `vm.*`, `cloud.*`, `remotes.*`, `aiAccounts.*`, `coderouter.*`,
  `workspace.cloud_vm_*`, `workspace.ssh.open` and Cloud catalog listings now answer
  `method_not_found`.
- **CodeRouter removed.** `cmux coderouter`, `cr`, the CodeRouter guide pane, the
  socket handoff, and the bundled CodeRouter CLI and its `coderouter/` crate are gone
  (CodeRouter required the hosted `coderouter.dev` account backend).
- **SSH:** the bundled `cmux-tui` client (SSH-TUI) is no longer installed; `cmux ssh`
  always uses cmuxd-remote.
- **MDM policy keys:** `DisableCloud` and `DisableAICredentialUpload` are removed;
  `DisableRemoteConnections` and `DisableFileTransfer` still work.
- **Session restore:** Cloud workspaces and panes saved by older versions are dropped
  on restore and from "Reopen Closed"; the rest of the session restores normally.
- **Config:** a `cmux.json` action using `cmux.cloudvm` no longer resolves.

## Account, sign-in, teams, Pro and billing

- The sidebar footer no longer shows the account avatar, the account/team popover or
  the Pro/Upgrade badge. In minimal mode the footer is empty.
- The sidebar Help popover and the Help menu no longer offer "Upgrade…", "Upgrade to
  Pro/Max", "Preview Native Pro Pricing…" or "Show Pro Welcome Checklist…". The native
  pricing window and the Pro welcome checklist are gone.
- Settings has no Account section (no sign-in/out, profile, team management,
  invitations, plan card or billing portal). Settings opens on App by default;
  `cmux settings open account` is no longer accepted.
- The command palette no longer offers sign in/out, team picker, team members or Pro
  upgrade commands.
- The "Sign In" workspace pane is gone; saved sessions containing one restore
  without it.
- Removed CLI commands: `cmux auth status|login|logout|team …`, `cmux login`,
  `cmux logout`. Removed socket methods: `auth.status`, `auth.sign_in_url`,
  `auth.begin_sign_in`, `auth.sign_out`, `auth.team.*`,
  `mobile.dev_stack_auth.configure`, `debug.pro_welcome_checklist.show`,
  `debug.native_pricing.show`. `auth.login` (socket password) still works.
- The embedded browser no longer intercepts `cmux://auth-callback` links, exchanges a
  signed-in session for cmux.com app pages, themes cmux.com pricing pages or opens
  cmux.com app links in a split.
- The app makes no requests to the cmux account, billing or team backend or to Stack
  Auth. The Stack Auth SDK and the `CmuxAuthRuntime`, `CMUXAuthCore`, `CmuxAPIClient`
  and `CmuxClientConfig` packages are gone.
- Feature flags "Sidebar account button" and "Go plan" are removed.
- The setting "Show Cloud and Device Icons in Sidebar" (`sidebar.showCloudDeviceIcons`)
  is removed; `cmux.json` validation now rejects it, along with
  `cloud.beta.machines.enabled` and the shortcut bindings `newCloudWorkspace`,
  `newCloudMachine`, `openTeamPicker`, `switchRightSidebarToMachines`.
- `cmux://` deep links for SSH, workspaces, panes and surfaces still work; the URL
  scheme is now registered as `.links` (build setting `CMUX_URL_SCHEME`).
- The config schema source moved from `web/data/cmux.schema.json` to
  `schemas/cmux.schema.json`.
- The one-time terminal welcome banner still shows once and keeps its "already shown"
  state.

## Repository cleanup

The repository now holds only what the macOS app build and its local tooling need.

- **iOS app:** `ios/`, `Packages/iOS/` and the iOS-only shared packages (`CmuxSyncStore`,
  `CmuxTerminalClient`) are deleted, with the iOS entries in `cmux.xcworkspace`, the App
  Store workflow config (`.asc/`), iOS/iPhone/mobile scripts and their tests.
- **Server and web:** `web/` (website, API and Cloud backend, BUSL-licensed), `services/`,
  `vault/`, `cmux-tui/` (SSH-TUI and Cloud client) and the control-plane schemas are deleted.
- **Workers:** `workers/ci-artifacts`, `fleet-artifacts`, `iroh-v2` and `presence` are
  deleted. `workers/cmux-paste-text` stays: the app build compiles it.
- **Upstream CI:** all upstream GitHub Actions workflows, actions and runner config, the
  fleet/testbox/merge-gate scripts, most of `scripts/ci/` and the tests of that
  infrastructure are deleted. `.github/workflows/fork-ci.yml` runs the portable static
  checks (`scripts/verify-local.py --all`, `plutil -lint`) on GitHub-hosted macOS runners
  with no secrets. `scripts/reload.sh` no longer has `--prod-auth`, `--credentials-file`,
  `--auth-profile` or `--expected-account`; tagged launches need no credentials. The
  `homebrew-cmux` submodule and review-bot configs (CodeRabbit, Greptile) are removed.
- **Docs:** Cloud, iroh, presence, mobile, CodeRouter, PostHog/Sentry and fleet CI docs are
  deleted; the MDM policy doc, `THIRD_PARTY_LICENSES.md` and the Chief prompt no longer
  describe removed features.
- **Translated READMEs:** the 20 `README.*.md` translations described upstream's product
  and pricing and are deleted. `README.md` describes this fork and how to build it.
