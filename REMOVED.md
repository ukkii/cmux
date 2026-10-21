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
