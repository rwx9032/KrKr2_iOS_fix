#!/usr/bin/env python3
"""Synthetic unit tests for prepare_launch_variant.py.

Every fixture here is generated locally from a Python dictionary.  No app IPA,
game data, save, certificate, or copied production Info.plist is read.
"""
from __future__ import annotations

import copy
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest

from prepare_launch_variant import (
    LEGACY_LAUNCH_IMAGE_KEYS,
    LaunchVariantError,
    prepare_launch_variant,
)

HERE = Path(__file__).resolve().parent
SCRIPT = HERE / "prepare_launch_variant.py"


def synthetic_info() -> dict:
    """A plausible XP3Player-shaped plist, entirely synthetic."""
    return {
        "CFBundleIdentifier": "tvp.XP3Player.Compat",
        "CFBundleExecutable": "XP3Player",
        "CFBundleShortVersionString": "1.3.11",
        "CFBundleVersion": "15",
        "CFBundleName": "XP3Player",
        "CFBundleDisplayName": "XP3Player",
        "CFBundlePackageType": "APPL",
        "UIDeviceFamily": [1, 2],
        "UISupportedInterfaceOrientations": [
            "UIInterfaceOrientationPortrait",
            "UIInterfaceOrientationPortraitUpsideDown",
            "UIInterfaceOrientationLandscapeLeft",
            "UIInterfaceOrientationLandscapeRight",
        ],
        "UISupportedInterfaceOrientations~ipad": [
            "UIInterfaceOrientationPortrait",
            "UIInterfaceOrientationPortraitUpsideDown",
            "UIInterfaceOrientationLandscapeLeft",
            "UIInterfaceOrientationLandscapeRight",
        ],
        "UIRequiresFullScreen": True,
        "MinimumOSVersion": "12.0",
        "DTSDKName": "iphoneos18.2",
        "DTPlatformName": "iphoneos",
        "DTPlatformVersion": "18.2",
        "DTXcode": "1600",
        "CFBundleSupportedPlatforms": ["iPhoneOS"],
        "UILaunchImageFile": "LaunchImage",
        "UILaunchImageFile~ipad": "LaunchImage-iPad",
        "UILaunchImageFile~iphone": "LaunchImage-iPhone",
        "UILaunchImages": [
            {
                "UILaunchImageName": "LaunchImage-700",
                "UILaunchImageMinimumOSVersion": "7.0",
                "UILaunchImageOrientation": "Portrait",
                "UILaunchImageSize": "{320, 480}",
            }
        ],
        "UILaunchImages~ipad": [
            {
                "UILaunchImageName": "LaunchImage-700-Portrait",
                "UILaunchImageMinimumOSVersion": "7.0",
                "UILaunchImageOrientation": "Portrait",
                "UILaunchImageSize": "{768, 1024}",
            }
        ],
        "XPCustomSentinel": {
            "nested": [1, True, "x"],
            "note": "must survive unchanged",
        },
    }


def write_fixture(path: Path, info: dict, fmt=plistlib.FMT_BINARY) -> bytes:
    data = plistlib.dumps(info, fmt=fmt, sort_keys=False)
    path.write_bytes(data)
    return data


def read_plist(path: Path) -> dict:
    return plistlib.loads(path.read_bytes())


def non_launch_keys(info: dict) -> dict:
    launch_keys = set(LEGACY_LAUNCH_IMAGE_KEYS) | {
        "UILaunchStoryboardName",
        "UILaunchScreen",
    }
    return {key: value for key, value in info.items() if key not in launch_keys}


class PrepareLaunchVariantTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(prefix="launch-variant-test-")
        self.root = Path(self.temp.name)

    def tearDown(self) -> None:
        self.temp.cleanup()

    def make_input(self, info: dict | None = None, fmt=plistlib.FMT_BINARY,
                   name: str = "Info.plist") -> tuple[Path, bytes, dict]:
        info = synthetic_info() if info is None else info
        path = self.root / name
        data = write_fixture(path, info, fmt)
        return path, data, info

    def test_legacy_preserve_binary_is_byte_identical(self) -> None:
        source, original_bytes, original_info = self.make_input()
        output = self.root / "Info-legacy.plist"
        report = prepare_launch_variant(source, output, "legacy-preserve")

        self.assertEqual(output.read_bytes(), original_bytes)
        self.assertTrue(output.read_bytes().startswith(b"bplist00"))
        self.assertTrue(report["unchanged_bytes"])
        self.assertEqual(report["removed_keys"], [])
        self.assertEqual(report["set_keys"], {})
        self.assertEqual(read_plist(output), original_info)
        self.assertEqual(source.read_bytes(), original_bytes)
        self.assertFalse(report["resources_copied"])
        self.assertFalse(report["runtime_validation_required"])

    def test_legacy_preserve_keeps_legacy_launch_keys(self) -> None:
        source, _, original_info = self.make_input(fmt=plistlib.FMT_XML)
        output = self.root / "Info-legacy.plist"
        prepare_launch_variant(source, output, "legacy-preserve")

        result = read_plist(output)
        for key in LEGACY_LAUNCH_IMAGE_KEYS:
            self.assertEqual(result[key], original_info[key])

    def test_storyboard_variant_changes_only_requested_launch_keys(self) -> None:
        source, _, original_info = self.make_input(fmt=plistlib.FMT_XML)
        output = self.root / "Info-storyboard.plist"
        report = prepare_launch_variant(source, output, "storyboard")

        result = read_plist(output)
        self.assertEqual(report["variant"], "storyboard")
        self.assertEqual(result["UILaunchStoryboardName"], "LaunchScreen")
        for key in LEGACY_LAUNCH_IMAGE_KEYS:
            self.assertNotIn(key, result)
        self.assertEqual(set(report["removed_keys"]), set(LEGACY_LAUNCH_IMAGE_KEYS))
        self.assertEqual(report["set_keys"], {"UILaunchStoryboardName": "LaunchScreen"})
        self.assertNotIn("UILaunchScreen", result)

        # Explicitly named layout/identity/platform keys and every other
        # non-launch key must be identical.
        self.assertEqual(result["UIDeviceFamily"], [1, 2])
        self.assertEqual(
            result["UISupportedInterfaceOrientations"],
            original_info["UISupportedInterfaceOrientations"],
        )
        self.assertEqual(
            result["UISupportedInterfaceOrientations~ipad"],
            original_info["UISupportedInterfaceOrientations~ipad"],
        )
        self.assertIs(result["UIRequiresFullScreen"], True)
        self.assertEqual(result["CFBundleIdentifier"], "tvp.XP3Player.Compat")
        self.assertEqual(result["DTSDKName"], "iphoneos18.2")
        self.assertEqual(result["DTPlatformName"], "iphoneos")
        self.assertEqual(non_launch_keys(result), non_launch_keys(original_info))

        # XML stays XML; no resources are copied.
        self.assertTrue(output.read_bytes().lstrip().startswith(b"<?xml"))
        self.assertFalse(report["resources_copied"])
        self.assertTrue(report["storyboard_resource_required"])
        self.assertEqual(
            {path.name for path in self.root.iterdir()},
            {"Info.plist", "Info-storyboard.plist"},
        )

    def test_plist_variant_sets_empty_native_dict_and_preserves_binary(self) -> None:
        info = synthetic_info()
        info["UILaunchStoryboardName"] = "OldLaunch"
        info["UILaunchScreen"] = {"UIColorName": "black"}
        source, _, _ = self.make_input(info, fmt=plistlib.FMT_BINARY)
        output = self.root / "Info-dictionary.plist"
        report = prepare_launch_variant(source, output, "plist")

        self.assertTrue(output.read_bytes().startswith(b"bplist00"))
        result = read_plist(output)
        self.assertIsInstance(result["UILaunchScreen"], dict)
        self.assertEqual(result["UILaunchScreen"], {})
        self.assertNotIn("UILaunchStoryboardName", result)
        for key in LEGACY_LAUNCH_IMAGE_KEYS:
            self.assertNotIn(key, result)
        self.assertIn("UILaunchStoryboardName", report["removed_keys"])
        self.assertIn("UILaunchScreen", report["replaced_keys"])
        self.assertEqual(report["set_keys"], {"UILaunchScreen": {}})
        self.assertEqual(result["CFBundleIdentifier"], "tvp.XP3Player.Compat")
        self.assertEqual(result["CFBundleExecutable"], "XP3Player")
        self.assertEqual(result["CFBundleShortVersionString"], "1.3.11")
        self.assertEqual(non_launch_keys(result), non_launch_keys(info))
        self.assertEqual(report["format"], "binary")

    def test_both_variants_accept_tvp_xp3player_identity(self) -> None:
        for bundle_id in ("tvp.XP3Player", "tvp.XP3Player.Compat"):
            for variant in ("storyboard", "plist"):
                with self.subTest(bundle_id=bundle_id, variant=variant):
                    with tempfile.TemporaryDirectory(
                        prefix="launch-variant-id-"
                    ) as directory:
                        root = Path(directory)
                        info = synthetic_info()
                        info["CFBundleIdentifier"] = bundle_id
                        source = root / "Info.plist"
                        write_fixture(source, info)
                        output = root / "Info-out.plist"
                        report = prepare_launch_variant(source, output, variant)
                        self.assertEqual(
                            report["identity"]["CFBundleIdentifier"], bundle_id
                        )
                        self.assertEqual(read_plist(output)["CFBundleIdentifier"], bundle_id)

    def test_refuses_existing_output_and_does_not_modify_it(self) -> None:
        source, _, _ = self.make_input()
        output = self.root / "Info-out.plist"
        sentinel = b"existing output sentinel"
        output.write_bytes(sentinel)

        with self.assertRaisesRegex(LaunchVariantError, "already exists"):
            prepare_launch_variant(source, output, "plist")
        self.assertEqual(output.read_bytes(), sentinel)

    def test_refuses_input_symlink(self) -> None:
        source, _, _ = self.make_input()
        alias = self.root / "Info-link.plist"
        alias.symlink_to(source)
        output = self.root / "Info-out.plist"

        with self.assertRaisesRegex(LaunchVariantError, "symlink"):
            prepare_launch_variant(alias, output, "storyboard")
        self.assertFalse(output.exists())

    def test_refuses_output_symlink_even_when_dangling(self) -> None:
        source, _, _ = self.make_input()
        for name, target_name in (
            ("Info-link.plist", "Info-target.plist"),
            ("Info-dangling.plist", "Info-missing.plist"),
        ):
            with self.subTest(name=name):
                output = self.root / name
                target = self.root / target_name
                if name == "Info-link.plist":
                    target.write_bytes(b"do not touch")
                output.symlink_to(target)
                with self.assertRaisesRegex(LaunchVariantError, "symlink"):
                    prepare_launch_variant(source, output, "plist")
                if name == "Info-link.plist":
                    self.assertEqual(target.read_bytes(), b"do not touch")
                output.unlink()

    def test_refuses_output_colliding_with_input(self) -> None:
        source, original_bytes, _ = self.make_input()
        with self.assertRaisesRegex(LaunchVariantError, "exists|collides"):
            prepare_launch_variant(source, source, "legacy-preserve")
        self.assertEqual(source.read_bytes(), original_bytes)

    def test_refuses_wrong_identity(self) -> None:
        cases = (
            ("CFBundleIdentifier", "com.example.Other"),
            ("CFBundleExecutable", "OtherPlayer"),
            ("CFBundleShortVersionString", "1.3.10"),
        )
        for key, value in cases:
            with self.subTest(key=key, value=value):
                info = synthetic_info()
                info[key] = value
                source = self.root / ("Info-%s.plist" % key)
                write_fixture(source, info)
                output = self.root / ("Out-%s.plist" % key)
                with self.assertRaisesRegex(LaunchVariantError, "identity"):
                    prepare_launch_variant(source, output, "storyboard")
                self.assertFalse(output.exists())

    def test_refuses_malformed_or_non_dictionary_plist(self) -> None:
        malformed = self.root / "Info-malformed.plist"
        malformed.write_bytes(b"not a plist")
        output = self.root / "Info-out.plist"
        with self.assertRaisesRegex(LaunchVariantError, "encoding|parse"):
            prepare_launch_variant(malformed, output, "plist")
        self.assertFalse(output.exists())

        array_root = self.root / "Info-array.plist"
        array_root.write_bytes(plistlib.dumps([1, 2, 3], fmt=plistlib.FMT_BINARY))
        with self.assertRaisesRegex(LaunchVariantError, "root"):
            prepare_launch_variant(array_root, output, "plist")
        self.assertFalse(output.exists())

    def test_refuses_missing_input_or_output_parent(self) -> None:
        source, _, _ = self.make_input()
        with self.assertRaisesRegex(LaunchVariantError, "does not exist"):
            prepare_launch_variant(self.root / "no-such.plist",
                                   self.root / "out.plist", "plist")
        missing_parent_output = self.root / "missing" / "Info.plist"
        with self.assertRaisesRegex(LaunchVariantError, "parent directory"):
            prepare_launch_variant(source, missing_parent_output, "plist")
        self.assertFalse(missing_parent_output.parent.exists())

    def test_cli_prints_report_and_refuses_second_run(self) -> None:
        source, _, _ = self.make_input()
        output = self.root / "Info-cli.plist"
        command = [
            sys.executable,
            str(SCRIPT),
            "--variant",
            "plist",
            str(source),
            str(output),
        ]
        first = subprocess.run(
            command, text=True, capture_output=True, check=False, cwd=self.root
        )
        self.assertEqual(first.returncode, 0, first.stderr)
        report = json.loads(first.stdout)
        self.assertEqual(report["variant"], "plist")
        self.assertFalse(report["resources_copied"])
        self.assertTrue(report["runtime_validation_required"])
        self.assertTrue(output.exists())

        second = subprocess.run(
            command, text=True, capture_output=True, check=False, cwd=self.root
        )
        self.assertNotEqual(second.returncode, 0)
        self.assertIn("already exists", second.stderr)
        self.assertEqual(read_plist(output)["UILaunchScreen"], {})


if __name__ == "__main__":
    unittest.main(verbosity=2)
