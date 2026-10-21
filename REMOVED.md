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
