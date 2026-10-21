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


def fixture(filetype=2, padding=128, cryptid=0, signature=True):
    """A synthetic executable with an actual file-backed __text section."""
    segment_size = 152
    encryption = struct.pack("<6I", 0x2C, 24, 0, 0, cryptid, 0)
    sig = struct.pack("<4I", 0x1D, 16, 0, 0) if signature else b""
    table_size = segment_size + len(encryption) + len(sig)
    offset = 32 + table_size + padding
    payload = b"PRESERVED-EXECUTABLE-TEXT" * 4
    segment = struct.pack("<2I16s4Q4I", 0x19, segment_size, b"__TEXT", 0x100000000,
                          offset + len(payload), 0, offset + len(payload), 5, 5, 1, 0)
    section = struct.pack("<16s16s2Q8I", b"__text", b"__TEXT", 0x100000000 + offset,
                          len(payload), offset, 2, 0, 0, 0x80000400, 0, 0, 0)
    table = segment + section + encryption + sig
    header = struct.pack("<8I", 0xFEEDFACF, inj.CPU_ARM64, 0, filetype,
                         3 if signature else 2, len(table), 0, 0)
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
        self.assertTrue(report["payload_bytes_unchanged"])

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
        self.info = plistlib.dumps({"CFBundleIdentifier": "tvp.XP3Player",
                                   "CFBundleExecutable": "XP3Player",
                                   "CFBundleShortVersionString": "1.3.11",
                                   "MinimumOSVersion": "15.0"})
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
        with mock.patch.object(inj, "EXPECTED_SHA256", inj.sha256(self.exe)):
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
        self.assertTrue(report["requires_resigning"])

    def test_hash_binding(self):
        with self.assertRaisesRegex(inj.InjectionError, "SHA-256"):
            inj.inject_ipa(self.ipa, self.lib, self.output)
        self.assertFalse(self.output.exists())

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
        self.assertEqual(report["original_executable_sha256"], inj.EXPECTED_SHA256)
        self.assertTrue(report["payload_bytes_unchanged"])
        with zipfile.ZipFile(os.environ["XP3COMPAT_ORIGINAL_IPA"]) as original, zipfile.ZipFile(self.output) as patched:
            for member in original.infolist():
                if member.filename == inj.APP_ROOT + "XP3Player" or inj.signature_residue(member.filename):
                    continue
                self.assertEqual(original.read(member), patched.read(member.filename), member.filename)


if __name__ == "__main__":
    unittest.main()
