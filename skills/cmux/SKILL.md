---
name: cmux
description: End-user control of cmux topology and routing (windows, workspaces, panes/surfaces, focus, moves, reorder, identify, trigger flash). Use when automation needs deterministic placement and navigation in a multi-pane cmux layout.
---

# cmux Core Control

Non-browser cmux topology and routing.

- **Window**: top-level macOS cmux window.
- **Workspace**: tab-like group within a window.
- **Pane**: split container in a workspace.
- **Surface**: a tab within a pane (terminal or browser panel).

## Fast start

```bash
cmux identify --json                              # current caller context
cmux list-windows / list-workspaces / list-panes
cmux list-pane-surfaces --pane pane:1
cmux new-workspace
cmux new-split right --surface surface:1
cmux new-split down --command "npm run dev"       # new terminal runs the command in a live shell
cmux move-surface --surface surface:7 --pane pane:2 --focus true
cmux split-off --surface surface:7 right
cmux reorder-surface --surface surface:7 --before surface:3

# workspace context-menu actions (color, description, rename, pin, ...)
cmux workspace-action --action set-color --color Blue
cmux workspace-action --action set-description --description "Ship checklist"

# attention cue
cmux trigger-flash --surface surface:7
```

## Handle model

Output defaults to short refs (`window:N`, `workspace:N`, `pane:N`, `surface:N`). UUIDs are accepted as input; request UUID output only when needed with `--id-format uuids|both`.

## Initial command on new terminals

`new-workspace`, `new-split`, `new-pane`, and `new-surface` accept `--command <text>`. cmux starts the terminal's normal interactive shell and delivers the text plus one Enter at spawn time, so the command runs immediately and the shell stays alive after it exits. No follow-up `send` or `send-key enter` is needed, and the text is passed literally (quoting, `&&`, pipes, and `$VARS` are interpreted by the new shell). The flag is terminal-only: it is rejected with `--type browser|simulator|agent-session`, blank text is ignored, and `new-workspace --layout` ignores it because layout surfaces define their own commands. Details: [references/panes-surfaces.md](references/panes-surfaces.md).

## Settings

cmux-owned settings live in `~/.config/cmux/cmux.json`. `cmux docs settings` prints the docs URL, schema URL, raw GitHub resources, cmux.json paths, and reload command. `cmux settings`, `cmux settings cmux-json`, and `cmux settings shortcuts` open the UI.

`cmux reload-config` reloads both `cmux.json` and `~/.config/ghostty/config`, refreshing terminals in place with no app restart.

Terminal rendering (font, cursor style, theme, scrollback, `background-opacity`, `background-blur`) belongs in Ghostty config, not cmux settings. Everything else (app behavior, sidebar, notifications, browser behavior, automation, workspace colors, cmux-owned shortcuts) is cmux settings. Before editing, copy any existing `cmux.json` to a timestamped `.bak` next to it. Legacy `~/.config/cmux/settings.json` and `~/Library/Application Support/com.cmuxterm.app/settings.json` are read only as fallback for missing keys.

For a completed download, the CLI can inspect the bounded history owned by the
target browser surface without consuming a waiter:

```bash
cmux browser --surface <surface> download list
cmux browser --surface <surface> download list --limit 5 --json
```

Use the browser skill for the full response fields and wait/path compatibility
details.

## Safebox

Safebox holds secrets the user stored in cmux (Vault → Safebox). Use it whenever a command needs a token, key or password, so the value never passes through you.

```bash
cmux safebox list [--json]
cmux safebox run NAME [NAME ...] [--as ENV=NAME ...] -- <command> [args...]
```

- `list` shows names, notes and dates, never values. It never needs approval.
- `run` starts `<command>` with each secret in an environment variable named after it (`--as ENV=NAME` renames the variable) and exits with the command's status. Example:

```bash
cmux safebox run CLOUDFLARE_TOKEN -- sh -c 'curl -H "Authorization: Bearer $CLOUDFLARE_TOKEN" https://api.cloudflare.com/client/v4/user/tokens/verify'
```

- Expand `$VAR` inside the child (`sh -c '...'` with single quotes). Your own shell would expand it before cmux runs, to nothing. Tools that read the variable themselves can run directly.
- Output is masked: every occurrence of a value becomes `***`. Values shorter than 4 bytes are not masked.
- The first use of a secret in a session waits for the user to Allow it in cmux (60 s timeout, then it counts as denied). Later uses in the same session do not ask again.
- Interactive full-screen programs (TUIs) are not supported. `run` waits for every process holding its output, so a background daemon it starts keeps it waiting.
- Errors (the command is not run): `not_approved` (the user denied it or did not answer), `unknown_secret` (no stored value; check `list`), `not_in_cmux_terminal` (run it from a cmux terminal), `keychain_unavailable` (cmux cannot read the Keychain), `invalid_params` (a secret name or another argument is malformed), `not_authorized` (Safebox is not available through a remote `cmux ssh` session).
- Inside tmux, screen or mosh running in a cmux pane, Safebox fails closed with `not_in_cmux_terminal`: those sessions are not the pane's own terminal. Run `cmux safebox` directly in the cmux pane.

Rules for agents:

- Never print, echo or log a secret value. Never write one to a file. Never pass one as an argument.
- Do not try to read the Keychain or the Safebox files directly.
- If a secret is missing, tell the user to add it in Vault → Safebox. You cannot add or change secrets.

## Deep-dive references

| Reference | When to Use |
|-----------|-------------|
| [references/handles-and-identify.md](references/handles-and-identify.md) | Handle syntax, self-identify, caller targeting |
| [references/windows-workspaces.md](references/windows-workspaces.md) | Window/workspace lifecycle, reorder/move, and context-menu actions (color, description, rename) |
| [references/panes-surfaces.md](references/panes-surfaces.md) | Splits, surfaces, move/reorder, focus routing |
| [references/trigger-flash-and-health.md](references/trigger-flash-and-health.md) | Flash cue and surface health checks |
| [../cmux-workspace/SKILL.md](../cmux-workspace/SKILL.md) | Current caller workspace rules and non-disruptive automation |
| [../cmux-settings/SKILL.md](../cmux-settings/SKILL.md) | Safe cmux.json settings edits and validation |
| [../cmux-browser/SKILL.md](../cmux-browser/SKILL.md) | Browser automation on surface-backed webviews |
| [../cmux-markdown/SKILL.md](../cmux-markdown/SKILL.md) | Markdown viewer panel with live file watching |
| [../cmux-capture/SKILL.md](../cmux-capture/SKILL.md) | Screenshots and clips of a cmux window for evidence |
