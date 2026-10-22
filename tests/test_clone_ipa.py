"""Tests for the XP3Player coexistence IPA cloner.

Run with::

    python3 -m unittest discover -s tests -p 'test_*.py' -v

Set ``XP3COMPAT_CLONE_INPUT_IPA`` to additionally exercise a real IPA (for
example, the output of the injector or the supplied candidate IPA).
"""

import importlib.util
import os
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest import mock
import zipfile


SCRIPT = Path(__file__).resolve().parents[1] / "tools" / "clone_ipa.py"
spec = importlib.util.spec_from_file_location("clone_ipa", SCRIPT)
clone = importlib.util.module_from_spec(spec)
spec.loader.exec_module(clone)


class CloneIPATests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.input_ipa = self.root / "input.ipa"
        self.output_ipa = self.root / "clone.ipa"
        self.dylib = b"already-injected-dylib-bytes"
        self.resource = b"resource bytes must survive cloning"

    def write_ipa(self, bundle_id=clone.ORIGINAL_BUNDLE_ID, extra_members=(),
                  second_app=False, plist_overrides=None):
        properties = {
            "CFBundleIdentifier": bundle_id,
            "CFBundleDisplayName": "XP3Player",
            "CFBundleName": "XP3Player",
            "CFBundleExecutable": "XP3Player",
            "CFBundleShortVersionString": "1.3.11",
        }
        properties.update(plist_overrides or {})
        info = plistlib.dumps(properties)
        with zipfile.ZipFile(self.input_ipa, "w") as archive:
            root = "Payload/XP3Player.app/"
            archive.writestr(root + "Info.plist", info)
            archive.writestr(root + "XP3Player", b"main executable")
            archive.writestr(root + "Frameworks/XP3Compat.dylib", self.dylib)
            archive.writestr(root + "resource.bin", self.resource)
            archive.writestr(root + "_CodeSignature/CodeResources", b"stale signature")
            archive.writestr(root + "embedded.mobileprovision", b"stale profile")
            archive.writestr("iTunesMetadata.plist", b"stale metadata")
            if second_app:
                archive.writestr("Payload/Other.app/Info.plist", info)
            for member in extra_members:
                archive.writestr(*member)

    def test_clone_changes_identity_preserves_payload_and_reports_hashes(self):
        self.write_ipa()
        before = self.input_ipa.read_bytes()

        with mock.patch.object(clone, "validate_zip", wraps=clone.validate_zip) as validator:
            report = clone.clone_ipa(self.input_ipa, self.output_ipa)
        validator.assert_called_once()
        self.assertEqual(self.input_ipa.read_bytes(), before)

        with zipfile.ZipFile(self.output_ipa) as archive:
            self.assertIsNone(archive.testzip())
            info = plistlib.loads(archive.read("Payload/XP3Player.app/Info.plist"))
            self.assertEqual(info["CFBundleIdentifier"], clone.DEFAULT_BUNDLE_ID)
            self.assertEqual(info["CFBundleDisplayName"], clone.DEFAULT_DISPLAY_NAME)
            self.assertEqual(info["CFBundleName"], clone.DEFAULT_DISPLAY_NAME)
            self.assertEqual(archive.read("Payload/XP3Player.app/Frameworks/XP3Compat.dylib"),
                             self.dylib)
            self.assertEqual(archive.read("Payload/XP3Player.app/resource.bin"), self.resource)
            self.assertFalse(any(clone.signature_residue(name) for name in archive.namelist()))

        self.assertEqual(report["bundle_id"], clone.DEFAULT_BUNDLE_ID)
        self.assertEqual(report["output_ipa_sha256"], clone._sha256_file(self.output_ipa))
        self.assertTrue(report["requires_resigning"])
        self.assertGreaterEqual(len(report["removed_signature_members"]), 3)

    def test_ipad_launch_keeps_legacy_iphone_settings_and_payload(self):
        legacy = {"UIDeviceFamily": [1, 2], "MinimumOSVersion": "15.0",
                  "UIRequiresFullScreen": True,
                  "UILaunchImageFile": "LaunchImage",
                  "UILaunchImages": [{"UILaunchImageName": "Legacy"}],
                  "UISupportedInterfaceOrientations": ["UIInterfaceOrientationLandscapeLeft"]}
        self.write_ipa(plist_overrides=legacy)
        report = clone.clone_ipa(self.input_ipa, self.output_ipa)
        with zipfile.ZipFile(self.input_ipa) as source, zipfile.ZipFile(self.output_ipa) as target:
            info = plistlib.loads(target.read(report["info_plist"]))
            self.assertEqual(info["UILaunchScreen~ipad"], {})
            self.assertNotIn("UILaunchScreen", info)
            # The generic orientation key is honored for iPad; the clone must
            # not synthesize an orientation override while fixing launch images.
            self.assertNotIn("UISupportedInterfaceOrientations~ipad", info)
            for key, value in legacy.items():
                self.assertEqual(info[key], value)
            for member in source.infolist():
                if member.filename != report["info_plist"] and not clone.signature_residue(member.filename):
                    self.assertEqual(source.read(member), target.read(member.filename))
        self.assertTrue(report["ipad_launch_screen_added"])

    def test_iphone_only_and_existing_modern_launch_are_preserved(self):
        for settings in ({"UIDeviceFamily": [1]},
                         {"UIDeviceFamily": [1, 2], "UILaunchScreen": {"UIColorName": "Brand"}},
                         {"UIDeviceFamily": [1, 2], "UILaunchScreen~ipad": {"UIImageName": "Logo"}},
                         {"UIDeviceFamily": [1, 2], "UILaunchStoryboardName": "Existing"},
                         {"UIDeviceFamily": [1, 2], "UILaunchStoryboardName~ipad": "ExistingPad"}):
            with self.subTest(settings=settings):
                self.write_ipa(plist_overrides=settings)
                output = self.root / ("preserved-" + str(len(list(self.root.glob("preserved-*")))) + ".ipa")
                report = clone.clone_ipa(self.input_ipa, output)
                with zipfile.ZipFile(output) as target:
                    info = plistlib.loads(target.read(report["info_plist"]))
                    for key, value in settings.items():
                        self.assertEqual(info[key], value)
                    if "UILaunchScreen~ipad" not in settings:
                        self.assertNotIn("UILaunchScreen~ipad", info)
                self.assertFalse(report["ipad_launch_screen_added"])

    def test_wrong_source_bundle_id_is_rejected_without_output(self):
        self.write_ipa(bundle_id="com.example.other")
        with self.assertRaisesRegex(clone.CloneError, "Unsupported source bundle identifier"):
            clone.clone_ipa(self.input_ipa, self.output_ipa)
        self.assertFalse(self.output_ipa.exists())

    def test_multiple_apps_are_rejected_without_output(self):
        self.write_ipa(second_app=True)
        with self.assertRaisesRegex(clone.CloneError, "exactly one top-level"):
            clone.clone_ipa(self.input_ipa, self.output_ipa)
        self.assertFalse(self.output_ipa.exists())

    def test_unsafe_and_duplicate_members_are_rejected(self):
        for member in (("Payload/../escape", b"unsafe"),
                       ("Payload/XP3Player.app/duplicate", b"first")):
            with self.subTest(member=member[0]):
                self.write_ipa(extra_members=(member,))
                if member[0].endswith("duplicate"):
                    with zipfile.ZipFile(self.input_ipa, "a") as archive:
                        archive.writestr(member[0], b"second")
                with self.assertRaises(clone.CloneError):
                    clone.clone_ipa(self.input_ipa, self.output_ipa)
                self.assertFalse(self.output_ipa.exists())

    def test_existing_output_and_input_output_alias_are_rejected(self):
        self.write_ipa()
        self.output_ipa.write_bytes(b"keep this artifact")
        with self.assertRaisesRegex(clone.CloneError, "already exists"):
            clone.clone_ipa(self.input_ipa, self.output_ipa)
        self.assertEqual(self.output_ipa.read_bytes(), b"keep this artifact")
        with self.assertRaisesRegex(clone.CloneError, "differ"):
            clone.clone_ipa(self.input_ipa, self.input_ipa)

    @unittest.skipUnless(os.environ.get("XP3COMPAT_CLONE_INPUT_IPA"),
                         "Set XP3COMPAT_CLONE_INPUT_IPA for real-IPA verification")
    def test_real_ipa_integration(self):
        real_input = Path(os.environ["XP3COMPAT_CLONE_INPUT_IPA"])
        report = clone.clone_ipa(real_input, self.output_ipa,
                                 "tvp.XP3Player.Compat", "XP3Player Fix")
        self.assertTrue(report["requires_resigning"])
        with zipfile.ZipFile(real_input) as source, zipfile.ZipFile(self.output_ipa) as target:
            info = plistlib.loads(target.read(report["info_plist"]))
            self.assertEqual(info["CFBundleIdentifier"], "tvp.XP3Player.Compat")
            self.assertEqual(info["CFBundleDisplayName"], "XP3Player Fix")
            self.assertEqual(info["CFBundleName"], "XP3Player Fix")
            for member in source.infolist():
                if member.filename == report["info_plist"] or clone.signature_residue(member.filename):
                    continue
                self.assertEqual(source.read(member), target.read(member.filename), member.filename)


if __name__ == "__main__":
    unittest.main()
