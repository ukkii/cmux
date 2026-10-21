# cmux agent notes (ukkii/cmux fork)

This repository is a fork of [manaflow-ai/cmux](https://github.com/manaflow-ai/cmux)
stripped down to the local desktop terminal. [REMOVED.md](REMOVED.md) lists every
removed feature and what changed for the user. Read it before changing behaviour.

## Fork rules

- **All commits, branches and pull requests go to `ukkii/cmux` only.** Never push to,
  open PRs against, or comment on `manaflow-ai/cmux`. The `upstream` remote is a
  read-only source of changes.
- **Do not bring removed functionality back.** No auto-update (Sparkle), analytics,
  crash reporting or telemetry (PostHog, Sentry, any metrics upload), remote feature
  flags, feedback upload, cmux Cloud, mobile pairing/devices/iroh, SSH-TUI, CodeRouter,
  sign-in/account/teams, Pro/pricing/billing. Nothing may contact cmux or Manaflow
  servers, or a third party, without an explicit user action. A new network call
  needs a line in REMOVED.md "Remaining network behaviour".
- When you remove something, delete it (code, packages, pbxproj entries, tests,
  strings) rather than hiding it behind a flag, add its paths to
  [.strip/removed-paths.txt](.strip/removed-paths.txt) and describe it in REMOVED.md.
- Fill the PR's `## Changelog` section with one `Added`/`Changed`/`Fixed`/`Removed`
  line for user-visible changes, otherwise `none`. Do not edit `CHANGELOG.md`.

## Merging upstream

Run `scripts/merge-upstream.sh` (optionally `--ref <tag-or-branch>`). It creates an
`upstream-sync/<date>` branch from `main`, merges `upstream/main` without committing,
drops upstream changes under `.strip/removed-paths.txt`, union-resolves pbxproj and
test-registry list conflicts, and warns about added lines matching
`.strip/forbidden-patterns.txt`. Then resolve what is left, check that new upstream
features don't talk to cmux services (remove them if they do), build, and open a PR
against `main` in `ukkii/cmux`.

## Build and verification

- Requirements: Xcode, rustup (Rust toolchain on `~/.cargo/bin`), Go (bundles
  cmuxd-remote), Python 3. GhosttyKit comes prebuilt:
  `./scripts/download-prebuilt-ghosttykit.sh`.
- Compile check (never bare `xcodebuild`, never an untagged `cmux DEV.app`):
  `PATH=~/.cargo/bin:$PATH CMUX_DEV_BACKEND_MODE=local CMUX_GHOSTTYKIT_PREPROVISIONED=1 CMUX_SKIP_ZIG_BUILD=1 ./scripts/reload.sh --tag <tag> --build-only`
  (drop `--build-only` to build the tagged app, add `--launch` to open it). Follow
  [tagged builds](skills/cmux-dev-workflow/references/tagged-builds.md).
- Portable checks: `CI=1 python3 scripts/verify-local.py` (also run by
  `.github/workflows/fork-ci.yml`). For tests see [cmux-testing](skills/cmux-testing/SKILL.md).
- Never quit, kill or replace the user's running `/Applications/cmux.app`
  (`com.cmuxterm.app`) yourself. Installing a new build there is done by the user
  (see README "Install").
- Dogfood through `CMUX_TAG=<tag> scripts/cmux-debug-cli.sh`, never `/tmp/cmux-cli`.
- App-linked code (`Sources/`, `CLI/` and their packages) must remain
  [Swift 6.0 compatible](skills/cmux-architecture/references/swift-6-0-compatibility.md).
- Commit the failing behavioral regression before its fix when fixing a bug, and list
  what you ran and what you didn't in the PR body (`### Observed / Not run`).

## Implementation rules by task

Use these existing owners instead of duplicating their checklists here:

| Touching | Read before editing |
| --- | --- |
| Typing paths, SwiftUI list/store boundaries, rendering, find layering, UTTypes or OS-specific bugs | [cmux-debugging](skills/cmux-debugging/SKILL.md) |
| Packages, workspace groups, lockfiles or feature flags | [cmux-architecture](skills/cmux-architecture/SKILL.md) |
| Submodules or GhosttyKit | [cmux-ghostty](skills/cmux-ghostty/SKILL.md) |
| User-facing strings, docs or help | [cmux-localization](skills/cmux-localization/SKILL.md); report the localization audit |
| New cmux shortcuts | [cmux-keyboard-shortcuts](skills/cmux-keyboard-shortcuts/SKILL.md) |
| Tests or target wiring | [cmux-testing](skills/cmux-testing/SKILL.md); run `scripts/sync-test-wiring` after adding, renaming or deleting a `cmuxTests/` file |
| Multiple entrypoints or a bug that tests previously missed | [cmux-shared-behavior](skills/cmux-shared-behavior/SKILL.md); share action/mutation paths, verify every entrypoint, and cover the missed repro |

## Remote CLI relay

For v2 socket methods and remote CLI changes, read [relay authorization](skills/cmux-socket-policy/references/remote-relay-authorization.md).
`RemoteRelayCommandPolicy` defaults to deny. Allowlist only for a needed remote
flow, scoped to the session's objects; command-bearing params stay denied on
every method. The PR must analyze local command/content
execution, access to unowned objects and local-state exposure, and include the
required policy tests and ID scoping. Unsafe local effects must be redesigned.
Never allowlist terminal spawn/respawn without live verification that it executes
on the remote host. An allowlist addition without this analysis blocks review.
