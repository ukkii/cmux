#!/usr/bin/env python3
"""Behavior tests for scripts/reconcile-entitlements-with-profile.py.

The helper passes the desired entitlements through unchanged and reports any
restricted entitlement the provisioning profile does not grant.
"""
import json
import plistlib
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "reconcile-entitlements-with-profile.py"

DESIRED = {
    "com.apple.application-identifier": "7WLXT3NR37.com.cmuxterm.app",
    "com.apple.developer.team-identifier": "7WLXT3NR37",
    "keychain-access-groups": ["7WLXT3NR37.com.cmuxterm.app"],
    "com.apple.developer.web-browser.public-key-credential": True,
    "com.apple.security.cs.allow-jit": True,
    "com.apple.security.cs.allow-unsigned-executable-memory": True,
    "com.apple.security.cs.disable-library-validation": True,
}

PROFILE = {
    "Entitlements": {
        "com.apple.application-identifier": "7WLXT3NR37.com.cmuxterm.app",
        "com.apple.developer.team-identifier": "7WLXT3NR37",
        "keychain-access-groups": ["7WLXT3NR37.*"],
        "com.apple.developer.web-browser.public-key-credential": True,
    },
    "ProvisionsAllDevices": True,
}


def run(entitlements, profile=None, no_profile=False):
    with tempfile.TemporaryDirectory() as tmp:
        tmp_path = Path(tmp)
        desired = tmp_path / "desired.plist"
        output = tmp_path / "effective.plist"
        with desired.open("wb") as handle:
            plistlib.dump(entitlements, handle)
        cmd = [sys.executable, str(SCRIPT), "--entitlements", str(desired), "--output", str(output), "--json"]
        if no_profile:
            cmd.append("--no-profile")
        else:
            profile_path = tmp_path / "embedded.provisionprofile"
            with profile_path.open("wb") as handle:
                plistlib.dump(profile, handle)
            cmd += ["--profile", str(profile_path)]
        proc = subprocess.run(cmd, capture_output=True, text=True, check=False)
        effective = plistlib.load(output.open("rb")) if output.exists() else None
        return proc, effective


class ReconcileEntitlementsTests(unittest.TestCase):
    def test_granted_entitlements_pass_through_unchanged(self):
        proc, effective = run(DESIRED, PROFILE)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        summary = json.loads(proc.stdout)
        self.assertEqual(effective, DESIRED)
        self.assertEqual(summary["missing_restricted"], [])
        self.assertEqual(summary["profile_app_id"], "7WLXT3NR37.com.cmuxterm.app")
        self.assertNotIn("::warning::", proc.stderr)

    def test_no_profile_passes_entitlements_through(self):
        proc, effective = run(DESIRED, no_profile=True)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        summary = json.loads(proc.stdout)
        self.assertEqual(effective, DESIRED)
        self.assertIsNone(summary["profile_app_id"])

    def test_missing_restricted_entitlement_is_reported_not_dropped(self):
        profile = {"Entitlements": {k: v for k, v in PROFILE["Entitlements"].items()
                                    if k != "com.apple.developer.web-browser.public-key-credential"}}
        proc, effective = run(DESIRED, profile)
        summary = json.loads(proc.stdout)
        self.assertEqual(summary["missing_restricted"], ["com.apple.developer.web-browser.public-key-credential"])
        self.assertIn("com.apple.developer.web-browser.public-key-credential", effective)
        self.assertIn("::warning::", proc.stderr)

    def test_repo_entitlement_files_request_no_tunnel(self):
        for name in ("cmux.release.entitlements", "cmux.nightly.entitlements", "cmux.rc.entitlements"):
            desired = plistlib.load((ROOT / name).open("rb"))
            for key in ("com.apple.developer.networking.networkextension",
                        "com.apple.developer.system-extension.install",
                        "com.apple.security.application-groups"):
                self.assertNotIn(key, desired, name)


if __name__ == "__main__":
    unittest.main()
