"""Run: python3 -m unittest discover -s tests -p 'test_*.py' -v.

Optional real-IPA test: XP3COMPAT_ORIGINAL_IPA=/path/original.ipa
XP3COMPAT_DYLIB=/path/XP3Compat.dylib python3 -m unittest discover -s tests -v
"""
import importlib.util
import os
from pathlib import Path
import plistlib
import stat
import struct
import tempfile
import unittest
from unittest import mock
import zipfile

SCRIPT = Path(__file__).resolve().parents[1] / "tools" / "inject_ipa.py"
spec = importlib.util.spec_from_file_location("inject_ipa", SCRIPT)
inj = importlib.util.module_from_spec(spec)
spec.loader.exec_module(inj)


SDK_14_5 = (14 << 16) | (5 << 8)
SDK_27_0 = 27 << 16


def build_version(platform=2, minos=SDK_14_5, sdk=SDK_14_5, tools=()):
    size = 24 + 8 * len(tools)
    command = struct.pack("<6I", inj.LC_BUILD_VERSION, size, platform,
                          minos, sdk, len(tools))
    for tool, version in tools:
        command += struct.pack("<2I", tool, version)
    return command


def version_min_iphoneos(version=SDK_14_5, sdk=SDK_14_5):
    return struct.pack("<4I", inj.LC_VERSION_MIN_IPHONEOS, 16, version, sdk)


def info_plist(extra=None, fmt=plistlib.FMT_XML):
    data = {"CFBundleIdentifier": "tvp.XP3Player",
            "CFBundleExecutable": "XP3Player",
            "CFBundleShortVersionString": "1.3.11",
            "MinimumOSVersion": "15.0"}
    data.update(extra or {})
    return plistlib.dumps(data, fmt=fmt)


def fixture(filetype=2, padding=128, cryptid=0, signature=True,
            version_commands=()):
    """A synthetic executable with an actual file-backed __text section."""
    segment_size = 152
    encryption = struct.pack("<6I", 0x2C, 24, 0, 0, cryptid, 0)
    sig = struct.pack("<4I", 0x1D, 16, 0, 0) if signature else b""
    versions = b"".join(version_commands)
    table_size = segment_size + len(versions) + len(encryption) + len(sig)
    offset = 32 + table_size + padding
    payload = b"PRESERVED-EXECUTABLE-TEXT" * 4
    segment = struct.pack("<2I16s4Q4I", 0x19, segment_size, b"__TEXT", 0x100000000,
                          offset + len(payload), 0, offset + len(payload), 5, 5, 1, 0)
    section = struct.pack("<16s16s2Q8I", b"__text", b"__TEXT", 0x100000000 + offset,
                          len(payload), offset, 2, 0, 0, 0x80000400, 0, 0, 0)
    table = segment + section + versions + encryption + sig
    ncmds = 2 + len(version_commands) + (1 if signature else 0)
    header = struct.pack("<8I", 0xFEEDFACF, inj.CPU_ARM64, 0, filetype,
                         ncmds, len(table), 0, 0)
    return header + table + b"\0" * padding + payload


class MachOTests(unittest.TestCase):
    def test_injection_preserves_payload_and_removes_signature(self):
        original = fixture()
        patched, report = inj.inject_macho(original)
        parsed = inj.parse_macho(patched, 2)
        self.assertEqual(parsed[2], [inj.INSTALL_NAME])
        self.assertNotIn(inj.LC_CODE_SIGNATURE, [c for c, _ in parsed[1]])
        self.assertEqual(original[parsed[3]:], patched[parsed[3]:])
        self.assertEqual(len(original), len(patched))
        self.assertEqual(report["sdk_versions"], [])
        self.assertFalse(report["sdk_version_updated"])
        self.assertTrue(report["payload_bytes_unchanged"])

    def test_build_version_sdk_is_raised_to_26_without_other_changes(self):
        tools = ((1, 0x00010000), (2, 0x00020000))
        unknown = struct.pack("<4I", 0x9999, 16, 0x12345678, 0x9ABCDEF0)
        for platform in (2, 7):
            with self.subTest(platform=platform):
                original = fixture(version_commands=(build_version(
                    platform=platform, tools=tools), unknown))
                before = next(raw for cmd, raw in inj.parse_macho(original, 2)[1]
                              if cmd == inj.LC_BUILD_VERSION)
                before_unknown = next(raw for cmd, raw in inj.parse_macho(original, 2)[1]
                                      if cmd == 0x9999)
                patched, report = inj.inject_macho(original)
                after = next(raw for cmd, raw in inj.parse_macho(patched, 2)[1]
                             if cmd == inj.LC_BUILD_VERSION)
                after_unknown = next(raw for cmd, raw in inj.parse_macho(patched, 2)[1]
                                     if cmd == 0x9999)
                self.assertEqual(before_unknown, after_unknown)
                self.assertEqual(struct.unpack_from("<I", after, 16)[0],
                                 inj.MINIMUM_SDK_VERSION)
                self.assertEqual(before[:16] + before[20:],
                                 after[:16] + after[20:])
                self.assertEqual(len(original), len(patched))
                parsed = inj.parse_macho(patched, 2)
                self.assertEqual(parsed[2], [inj.INSTALL_NAME])
                self.assertEqual(original[parsed[3]:], patched[parsed[3]:])
                record = report["sdk_versions"][0]
                self.assertEqual(record["command"], "LC_BUILD_VERSION")
                self.assertEqual(record["platform"],
                                 "ios" if platform == 2 else "ios-simulator")
                self.assertEqual(record["before"], "14.5")
                self.assertEqual(record["after"], "26.0")
                self.assertTrue(record["updated"])
                self.assertTrue(report["sdk_version_updated"])
                self.assertTrue(report["payload_bytes_unchanged"])

    def test_newer_build_version_sdk_is_not_downgraded(self):
        for sdk in (inj.MINIMUM_SDK_VERSION, SDK_27_0):
            with self.subTest(sdk=sdk):
                original = fixture(version_commands=(build_version(sdk=sdk),))
                before = next(raw for cmd, raw in inj.parse_macho(original, 2)[1]
                              if cmd == inj.LC_BUILD_VERSION)
                patched, report = inj.inject_macho(original)
                after = next(raw for cmd, raw in inj.parse_macho(patched, 2)[1]
                             if cmd == inj.LC_BUILD_VERSION)
                self.assertEqual(before, after)
                self.assertEqual(struct.unpack_from("<I", after, 16)[0], sdk)
                self.assertFalse(report["sdk_version_updated"])
                record = report["sdk_versions"][0]
                self.assertEqual(record["before"], record["after"])
                self.assertFalse(record["updated"])

    def test_non_ios_build_version_is_untouched(self):
        for platform in (1, 6):
            with self.subTest(platform=platform):
                original = fixture(version_commands=(build_version(
                    platform=platform, sdk=SDK_14_5),))
                before = next(raw for cmd, raw in inj.parse_macho(original, 2)[1]
                              if cmd == inj.LC_BUILD_VERSION)
                patched, report = inj.inject_macho(original)
                after = next(raw for cmd, raw in inj.parse_macho(patched, 2)[1]
                             if cmd == inj.LC_BUILD_VERSION)
                self.assertEqual(before, after)
                self.assertEqual(struct.unpack_from("<I", after, 16)[0], SDK_14_5)
                self.assertFalse(report["sdk_version_updated"])
                self.assertEqual(report["sdk_versions"][0]["platform"],
                                 {1: "macos", 6: "mac-catalyst"}[platform])
                self.assertEqual(report["sdk_versions"][0]["reason"],
                                 "unsupported platform")

    def test_version_min_iphoneos_sdk_is_raised_to_26(self):
        original = fixture(version_commands=(version_min_iphoneos(),))
        before = next(raw for cmd, raw in inj.parse_macho(original, 2)[1]
                      if cmd == inj.LC_VERSION_MIN_IPHONEOS)
        patched, report = inj.inject_macho(original)
        after = next(raw for cmd, raw in inj.parse_macho(patched, 2)[1]
                     if cmd == inj.LC_VERSION_MIN_IPHONEOS)
        self.assertEqual(struct.unpack_from("<I", after, 8)[0], SDK_14_5)
        self.assertEqual(struct.unpack_from("<I", after, 12)[0],
                         inj.MINIMUM_SDK_VERSION)
        self.assertEqual(before[:12] + before[16:], after[:12] + after[16:])
        parsed = inj.parse_macho(patched, 2)
        self.assertEqual(original[parsed[3]:], patched[parsed[3]:])
        self.assertEqual(len(original), len(patched))
        record = report["sdk_versions"][0]
        self.assertEqual(record["command"], "LC_VERSION_MIN_IPHONEOS")
        self.assertEqual(record["platform"], "ios")
        self.assertEqual(record["before"], "14.5")
        self.assertEqual(record["after"], "26.0")
        self.assertTrue(record["updated"])
        self.assertTrue(report["sdk_version_updated"])

    def test_malformed_known_sdk_commands_are_rejected(self):
        malformed = (
            ("truncated build-version",
             struct.pack("<4I", inj.LC_BUILD_VERSION, 16, 2, SDK_14_5)),
            ("bad tool table",
             struct.pack("<6I", inj.LC_BUILD_VERSION, 24, 2, SDK_14_5,
                         SDK_14_5, 1)),
            ("truncated version-min",
             struct.pack("<2I", inj.LC_VERSION_MIN_IPHONEOS, 8)),
        )
        for label, command in malformed:
            with self.subTest(label), self.assertRaisesRegex(
                    inj.InjectionError, "(build-version|version-min)"):
                inj.inject_macho(fixture(version_commands=(command,)))

    def test_duplicate_injection_rejected(self):
        patched, _ = inj.inject_macho(fixture())
        with self.assertRaisesRegex(inj.InjectionError, "already loaded"):
            inj.inject_macho(patched)

    def test_encrypted_rejected(self):
        with self.assertRaisesRegex(inj.InjectionError, "Encrypted"):
            inj.inject_macho(fixture(cryptid=1))

    def test_not_enough_padding(self):
        with self.assertRaisesRegex(inj.InjectionError, "Insufficient"):
            inj.inject_macho(fixture(padding=0))

    def test_nonzero_padding_rejected(self):
        original = bytearray(fixture())
        header = struct.unpack_from("<8I", original)
        original[32 + header[5]] = 1
        with self.assertRaisesRegex(inj.InjectionError, "nonzero"):
            inj.inject_macho(bytes(original))

    def test_malformed_command_size(self):
        original = bytearray(fixture())
        struct.pack_into("<I", original, 36, 0)
        with self.assertRaisesRegex(inj.InjectionError, "command size"):
            inj.inject_macho(bytes(original))

    def test_malformed_command_count(self):
        original = bytearray(fixture())
        struct.pack_into("<I", original, 16, 1)
        with self.assertRaisesRegex(inj.InjectionError, "count and size"):
            inj.inject_macho(bytes(original))

    def test_truncated_binary(self):
        with self.assertRaises(inj.InjectionError):
            inj.inject_macho(fixture()[:-20])

    def test_wrong_architecture_and_type(self):
        for field, value in ((4, 0x01000007), (8, 2), (12, 6), (0, 0xCAFEBABE)):
            original = bytearray(fixture())
            struct.pack_into("<I", original, field, value)
            with self.assertRaises(inj.InjectionError):
                inj.inject_macho(bytes(original))

    def test_no_signature_supported(self):
        patched, report = inj.inject_macho(fixture(signature=False))
        self.assertEqual(report["code_signature_commands_removed"], 0)
        self.assertIn(inj.INSTALL_NAME, inj.parse_macho(patched, 2)[2])


class ZipSafetyTests(unittest.TestCase):
    def test_unsafe_paths(self):
        for name in ("../escape", "/escape", "Payload/../escape", "Payload//file",
                     "Payload/./file", "C:/escape", "Payload\\escape"):
            with self.subTest(name=name), self.assertRaises(inj.InjectionError):
                inj.validate_zip([zipfile.ZipInfo(name)])

    def test_symlink_rejected(self):
        entry = zipfile.ZipInfo("Payload/link")
        entry.create_system = 3
        entry.external_attr = (stat.S_IFLNK | 0o777) << 16
        with self.assertRaisesRegex(inj.InjectionError, "symlinks"):
            inj.validate_zip([entry])

    def test_duplicate_casefold_paths(self):
        with self.assertRaisesRegex(inj.InjectionError, "Duplicate"):
            inj.validate_zip([zipfile.ZipInfo("Payload/File"), zipfile.ZipInfo("Payload/file")])

    def test_parent_file_conflict(self):
        with self.assertRaisesRegex(inj.InjectionError, "conflict"):
            inj.validate_zip([zipfile.ZipInfo("Payload/file"), zipfile.ZipInfo("Payload/file/child")])

    def test_signature_residue_filter(self):
        self.assertTrue(inj.signature_residue("Payload/App.app/_CodeSignature/CodeResources"))
        self.assertTrue(inj.signature_residue("Payload/App.app/embedded.mobileprovision"))
        self.assertTrue(inj.signature_residue("iTunesMetadata.plist"))
        self.assertFalse(inj.signature_residue("Payload/App.app/Info.plist"))


class IPATests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.exe = fixture()
        self.ipa = self.root / "original.ipa"
        self.lib = self.root / "XP3Compat.dylib"
        self.lib.write_bytes(fixture(filetype=6))
        self.output = self.root / "patched.ipa"
        self.info = info_plist()
        self.write_ipa()

    def write_ipa(self, extra=None):
        with zipfile.ZipFile(self.ipa, "w") as archive:
            archive.writestr(inj.APP_ROOT + "Info.plist", self.info)
            entry = zipfile.ZipInfo(inj.APP_ROOT + "XP3Player")
            entry.create_system = 3
            entry.external_attr = (stat.S_IFREG | 0o755) << 16
            archive.writestr(entry, self.exe)
            archive.writestr(inj.APP_ROOT + "_CodeSignature/CodeResources", b"old signature")
            archive.writestr(inj.APP_ROOT + "embedded.mobileprovision", b"old profile")
            archive.writestr("iTunesMetadata.plist", b"old metadata")
            archive.writestr(inj.APP_ROOT + "resource.txt", b"unaltered resource")
            if extra:
                archive.writestr(*extra)

    def patch(self):
        return inj.inject_ipa(self.ipa, self.lib, self.output)

    def test_archive_roundtrip_preserves_info_resources_permissions(self):
        before = self.ipa.read_bytes()
        report = self.patch()
        self.assertEqual(self.ipa.read_bytes(), before)
        with zipfile.ZipFile(self.output) as archive:
            self.assertEqual(archive.read(inj.APP_ROOT + "Info.plist"), self.info)
            self.assertEqual(archive.read(inj.APP_ROOT + "resource.txt"), b"unaltered resource")
            self.assertEqual(archive.read(inj.LIB_PATH), self.lib.read_bytes())
            self.assertEqual((archive.getinfo(inj.APP_ROOT + "XP3Player").external_attr >> 16) & 0o777, 0o755)
            self.assertFalse(any(inj.signature_residue(n) for n in archive.namelist()))
        self.assertEqual(report["sdk_versions"], [])
        self.assertFalse(report["sdk_version_updated"])
        self.assertFalse(report["ipad_launch_screen_added"])
        self.assertTrue(report["info_plist_unchanged"])
        self.assertTrue(report["requires_resigning"])

    def test_ipad_legacy_info_adds_launch_and_bumps_sdk(self):
        legacy = {
            "UIDeviceFamily": [1, 2],
            "UIRequiresFullScreen": True,
            "UISupportedInterfaceOrientations": [
                "UIInterfaceOrientationLandscapeLeft",
                "UIInterfaceOrientationLandscapeRight",
            ],
            "UILaunchImageFile": "LaunchImage",
            "UILaunchImages": [{"UILaunchImageName": "Legacy"}],
            "DTSDKName": "iphonesimulator14.5",
            "DTPlatformVersion": "14.5",
            "UIApplicationSceneManifest": {"UIApplicationSupportsMultipleScenes": False},
            "CustomKeep": "value",
        }
        for fmt, suffix in ((plistlib.FMT_XML, "xml"),
                            (plistlib.FMT_BINARY, "binary")):
            with self.subTest(fmt=suffix):
                self.info = info_plist(legacy, fmt)
                self.exe = fixture(version_commands=(build_version(),))
                self.write_ipa()
                output = self.root / ("ipad-legacy-%s.ipa" % suffix)
                report = inj.inject_ipa(self.ipa, self.lib, output)
                self.assertTrue(report["ipad_launch_screen_added"])
                self.assertFalse(report["info_plist_unchanged"])
                self.assertTrue(report["sdk_version_updated"])
                self.assertEqual(report["sdk_versions"][0]["after"], "26.0")
                with zipfile.ZipFile(output) as archive:
                    patched_info_bytes = archive.read(inj.APP_ROOT + "Info.plist")
                    patched_exe = archive.read(inj.APP_ROOT + "XP3Player")
                    self.assertEqual(archive.read(inj.APP_ROOT + "resource.txt"),
                                     b"unaltered resource")
                expected = plistlib.loads(self.info)
                expected["UILaunchScreen~ipad"] = {}
                self.assertEqual(plistlib.loads(patched_info_bytes), expected)
                if fmt == plistlib.FMT_BINARY:
                    self.assertTrue(patched_info_bytes.startswith(b"bplist"))
                else:
                    self.assertTrue(patched_info_bytes.lstrip().startswith(b"<?xml"))
                parsed = inj.parse_macho(patched_exe, 2)
                self.assertEqual(self.exe[parsed[3]:], patched_exe[parsed[3]:])
                self.assertEqual(len(self.exe), len(patched_exe))

    def test_modern_or_phone_only_info_is_byte_identical(self):
        cases = (
            ("modern-global", {"UIDeviceFamily": [1, 2], "UILaunchScreen": {}}),
            ("modern-ipad", {"UIDeviceFamily": [1, 2],
                             "UILaunchScreen~ipad": {"UIImageName": "Logo"}}),
            ("storyboard", {"UIDeviceFamily": [1, 2],
                            "UILaunchStoryboardName": "Launch"}),
            ("storyboard-ipad", {"UIDeviceFamily": [1, 2],
                                 "UILaunchStoryboardName~ipad": "LaunchPad"}),
            ("phone-only", {"UIDeviceFamily": [1], "UILaunchImageFile": "LaunchImage",
                            "UILaunchImages": [{"UILaunchImageName": "Legacy"}]}),
        )
        for name, props in cases:
            with self.subTest(name):
                self.info = info_plist(props)
                self.exe = fixture(version_commands=(build_version(),))
                self.write_ipa()
                output = self.root / ("preserved-info-%s.ipa" % name)
                report = inj.inject_ipa(self.ipa, self.lib, output)
                self.assertFalse(report["ipad_launch_screen_added"])
                self.assertTrue(report["info_plist_unchanged"])
                self.assertTrue(report["sdk_version_updated"])
                with zipfile.ZipFile(output) as archive:
                    self.assertEqual(archive.read(inj.APP_ROOT + "Info.plist"),
                                     self.info)

    def test_distinct_valid_macho_inputs_both_inject_with_recorded_hashes(self):
        # Same supported app/version, but two valid executables whose bytes (and
        # therefore SHA-256) differ, as independently decrypted/signed copies do.
        originals = [fixture(padding=128, version_commands=(build_version(),)),
                     fixture(padding=136, version_commands=(version_min_iphoneos(),))]
        self.assertEqual(len({inj.sha256(data) for data in originals}), 2)
        for index, original in enumerate(originals):
            with self.subTest(index=index, original_sha256=inj.sha256(original)):
                self.exe = original
                self.write_ipa()
                output = self.root / ("distinct-%d.ipa" % index)
                report = inj.inject_ipa(self.ipa, self.lib, output)
                self.assertEqual(report["original_executable_sha256"], inj.sha256(original))
                self.assertTrue(report["payload_bytes_unchanged"])
                self.assertTrue(report["sdk_version_updated"])
                self.assertEqual(report["sdk_versions"][0]["after"], "26.0")
                self.assertTrue(report["info_plist_unchanged"])
                with zipfile.ZipFile(output) as archive:
                    self.assertEqual(archive.read(inj.APP_ROOT + "Info.plist"), self.info)
                    patched = archive.read(inj.APP_ROOT + "XP3Player")
                self.assertEqual(len(patched), len(original))
                parsed = inj.parse_macho(patched, 2)
                self.assertEqual(parsed[2], [inj.INSTALL_NAME])
                self.assertEqual(original[parsed[3]:], patched[parsed[3]:])

    def test_source_zipinfo_offsets_not_mutated_by_output(self):
        # Dropping an early signature entry moves later members in the output.
        # Reusing the source ZipInfo while writing would corrupt source.read()
        # during the final Info.plist validation ("Bad magic number").
        with zipfile.ZipFile(self.ipa, "w") as archive:
            archive.writestr(inj.APP_ROOT + "_CodeSignature/CodeResources", b"removed first")
            archive.writestr(inj.APP_ROOT + "XP3Player", self.exe)
            archive.writestr(inj.APP_ROOT + "Info.plist", self.info)
        self.patch()
        with zipfile.ZipFile(self.output) as archive:
            self.assertEqual(archive.read(inj.APP_ROOT + "Info.plist"), self.info)

    def test_never_overwrite_input_or_existing_output(self):
        with self.assertRaisesRegex(inj.InjectionError, "differ"):
            inj.inject_ipa(self.ipa, self.lib, self.ipa)
        self.output.write_bytes(b"previous artifact")
        with self.assertRaisesRegex(inj.InjectionError, "already exists"):
            self.patch()
        self.assertEqual(self.output.read_bytes(), b"previous artifact")

    def test_zip_traversal_fails_without_output(self):
        self.write_ipa(("../escape", b"malicious"))
        with self.assertRaisesRegex(inj.InjectionError, "Unsafe"):
            self.patch()
        self.assertFalse(self.output.exists())
        self.assertFalse((self.root.parent / "escape").exists())

    def test_deterministic_output(self):
        self.patch()
        first = self.output.read_bytes()
        self.output.unlink()
        self.patch()
        self.assertEqual(self.output.read_bytes(), first)

    def test_failed_publish_cleans_temporary(self):
        with mock.patch.object(inj.os, "link", side_effect=OSError("publish failed")):
            with self.assertRaisesRegex(OSError, "publish failed"):
                self.patch()
        self.assertFalse(self.output.exists())
        self.assertFalse(list(self.root.glob(".xp3compat-*")))

    @unittest.skipUnless(os.environ.get("XP3COMPAT_ORIGINAL_IPA") and os.environ.get("XP3COMPAT_DYLIB"),
                         "Set XP3COMPAT_ORIGINAL_IPA and XP3COMPAT_DYLIB for real-IPA verification")
    def test_real_supplied_ipa(self):
        report = inj.inject_ipa(os.environ["XP3COMPAT_ORIGINAL_IPA"],
                                os.environ["XP3COMPAT_DYLIB"], self.output)
        info_path = inj.APP_ROOT + "Info.plist"
        with zipfile.ZipFile(os.environ["XP3COMPAT_ORIGINAL_IPA"]) as original, zipfile.ZipFile(self.output) as patched:
            original_exe = original.read(inj.APP_ROOT + "XP3Player")
            patched_exe = patched.read(inj.APP_ROOT + "XP3Player")
            self.assertEqual(report["original_executable_sha256"], inj.sha256(original_exe))
            self.assertTrue(report["payload_bytes_unchanged"])
            self.assertEqual(len(original_exe), len(patched_exe))
            parsed = inj.parse_macho(patched_exe, 2)
            self.assertEqual(original_exe[parsed[3]:], patched_exe[parsed[3]:])
            for member in original.infolist():
                if member.filename in (inj.APP_ROOT + "XP3Player", info_path) or inj.signature_residue(member.filename):
                    continue
                self.assertEqual(original.read(member), patched.read(member.filename), member.filename)
            original_info_bytes = original.read(info_path)
            patched_info_bytes = patched.read(info_path)
            if report["ipad_launch_screen_added"]:
                original_info = plistlib.loads(original_info_bytes)
                patched_info = plistlib.loads(patched_info_bytes)
                self.assertNotIn("UILaunchScreen~ipad", original_info)
                self.assertEqual(patched_info["UILaunchScreen~ipad"], {})
                original_info.pop("UILaunchScreen~ipad", None)
                patched_info.pop("UILaunchScreen~ipad", None)
                self.assertEqual(patched_info, original_info)
                self.assertFalse(report["info_plist_unchanged"])
            else:
                self.assertFalse(report["ipad_launch_screen_added"])
                self.assertEqual(patched_info_bytes, original_info_bytes)
                self.assertTrue(report["info_plist_unchanged"])


if __name__ == "__main__":
    unittest.main()
