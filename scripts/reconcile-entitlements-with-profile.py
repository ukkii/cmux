#!/usr/bin/env python3
"""Reconcile a cmux entitlements file with the provisioning profile it ships with.

macOS refuses to launch a Developer ID app whose signature claims a restricted
entitlement (`com.apple.developer.*`) that its embedded provisioning profile
does not grant. The cmux entitlement files declare the *desired* state and
this script produces the *effective* entitlements for one signing run, and
reports any restricted entitlement the profile does not grant so the operator
sees a broken profile before notarization.

Usage:
  reconcile-entitlements-with-profile.py --entitlements cmux.release.entitlements \
      --profile "cmux.app/Contents/embedded.provisionprofile" --output /tmp/effective.plist [--json]

`--profile` accepts either the CMS-wrapped `.provisionprofile` (decoded with
`security cms -D`) or an already-decoded XML plist. `--no-profile` produces the
effective entitlements for an unprovisioned signing run.

Prints a JSON summary on stdout with `--json`:
  {"missing_restricted": [keys], "profile_app_id": str|null}

Exit codes: 0 reconciled; 1 the profile could not be read; 2 usage error.
"""
from __future__ import annotations

import argparse
import json
import plistlib
import subprocess
import sys
from pathlib import Path

# Restricted entitlements the profile must grant for the app to launch at all.
# Reported (not dropped) so the operator sees a broken profile before notarization.
RESTRICTED_PREFIXES = ("com.apple.developer.",)


def load_profile_entitlements(path: Path) -> tuple[dict, str | None]:
    """Return (entitlements dict, application-identifier) from a profile."""
    raw = path.read_bytes()
    try:
        decoded = plistlib.loads(raw)
    except Exception:  # noqa: BLE001 - CMS-wrapped profile; decode with security(1)
        try:
            result = subprocess.run(
                ["/usr/bin/security", "cms", "-D", "-i", str(path)],
                check=True,
                capture_output=True,
            )
        except (OSError, subprocess.CalledProcessError) as exc:
            raise SystemExit(f"error: could not decode provisioning profile {path}: {exc}") from exc
        try:
            decoded = plistlib.loads(result.stdout)
        except Exception as exc:  # noqa: BLE001
            raise SystemExit(f"error: decoded profile {path} is not a plist: {exc}") from exc
    entitlements = decoded.get("Entitlements")
    if not isinstance(entitlements, dict):
        raise SystemExit(f"error: provisioning profile {path} has no Entitlements dictionary")
    app_id = entitlements.get("com.apple.application-identifier")
    return entitlements, app_id if isinstance(app_id, str) else None


def reconcile(entitlements: dict, profile_entitlements: dict | None) -> tuple[dict, dict]:
    """Return (effective entitlements, summary)."""
    effective = dict(entitlements)
    missing_restricted: list[str] = []
    if profile_entitlements is not None:
        for key in effective:
            if key.startswith(RESTRICTED_PREFIXES) and key not in profile_entitlements:
                missing_restricted.append(key)
    summary = {
        "missing_restricted": sorted(missing_restricted),
    }
    return effective, summary


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--entitlements", required=True, type=Path, help="desired entitlements plist")
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--profile", type=Path, help="embedded.provisionprofile or decoded plist")
    source.add_argument("--no-profile", action="store_true", help="signing run without a provisioning profile")
    parser.add_argument("--output", required=True, type=Path, help="where to write the effective entitlements plist")
    parser.add_argument("--json", action="store_true", help="print a JSON summary on stdout")
    args = parser.parse_args(argv)

    try:
        with args.entitlements.open("rb") as handle:
            entitlements = plistlib.load(handle)
    except (OSError, plistlib.InvalidFileException) as exc:
        print(f"error: could not read entitlements {args.entitlements}: {exc}", file=sys.stderr)
        return 2
    if not isinstance(entitlements, dict):
        print(f"error: entitlements {args.entitlements} is not a dictionary plist", file=sys.stderr)
        return 2

    profile_entitlements = None
    profile_app_id = None
    if args.profile is not None:
        try:
            profile_entitlements, profile_app_id = load_profile_entitlements(args.profile)
        except SystemExit as exc:
            print(exc, file=sys.stderr)
            return 1

    effective, summary = reconcile(entitlements, profile_entitlements)
    summary["profile_app_id"] = profile_app_id
    with args.output.open("wb") as handle:
        plistlib.dump(effective, handle, fmt=plistlib.FMT_XML, sort_keys=False)

    for key in summary["missing_restricted"]:
        print(f"::warning::restricted entitlement {key} is not granted by the provisioning profile; the signed app may not launch", file=sys.stderr)
    if args.json:
        print(json.dumps(summary, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
