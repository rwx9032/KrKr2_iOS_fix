"""Free 1.3.9 support in the existing command-line pipeline; no upstream IPA required."""
import importlib.util
from pathlib import Path
import plistlib
import struct
import tempfile
import unittest
import zipfile

from test_inject import fixture, inj

spec = importlib.util.spec_from_file_location("free_clone", Path(__file__).resolve().parents[1] / "tools/clone_ipa.py")
clone = importlib.util.module_from_spec(spec)
spec.loader.exec_module(clone)
ROOT = "Payload/Kirikiroid2.app/"


def fat(slice_data):
    data = bytearray(4096)
    struct.pack_into(">7I", data, 0, 0xcafebabe, 1, inj.CPU_ARM64, 0, 4096, len(slice_data), 12)
    return bytes(data) + slice_data


class FreeIPATests(unittest.TestCase):
    def test_extracts_arm64_and_rejects_bad_fat(self):
        self.assertEqual(inj.arm64_executable(fat(fixture())), fixture())
        self.assertEqual(inj.arm64_executable(fixture()), fixture())
        for at, value in [(4, 0), (8, 12), (16, 4097), (20, 0xffffffff)]:
            with self.subTest(at=at):
                data = bytearray(fat(fixture()))
                struct.pack_into(">I", data, at, value)
                with self.assertRaises(inj.InjectionError):
                    inj.arm64_executable(bytes(data))
        with self.assertRaises(inj.InjectionError):
            inj.arm64_executable(fat(fixture(cryptid=1)))
        # Duplicate arm64 slices and overlapping slices must fail independently.
        for second_offset in (4096, 8192):
            data = bytearray(8192 + len(fixture()))
            struct.pack_into(">2I", data, 0, 0xcafebabe, 2)
            struct.pack_into(">5I", data, 8, inj.CPU_ARM64, 0, 4096, len(fixture()), 12)
            struct.pack_into(">5I", data, 28, inj.CPU_ARM64, 0, second_offset, len(fixture()), 12)
            data[4096:4096 + len(fixture())] = fixture()
            data[second_offset:second_offset + len(fixture())] = fixture()
            with self.assertRaises(inj.InjectionError):
                inj.arm64_executable(bytes(data))

    def test_free_inject_clone_and_identity_rejection(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source, injected, output = (root / name for name in ("free.ipa", "injected.ipa", "coexist.ipa"))
            plugin = root / "XP3Compat.dylib"
            plugin.write_bytes(fixture(filetype=6) + b"XP3COMPAT_FREE_139_V1\0")
            info = {"CFBundleIdentifier": "tvp.XP3Player.free", "CFBundleExecutable": "Kirikiroid2",
                    "CFBundleShortVersionString": "1.3.9", "CFBundleVersion": "20", "MinimumOSVersion": "6.0"}

            def write(properties):
                with zipfile.ZipFile(source, "w") as z:
                    z.writestr(ROOT + "Info.plist", plistlib.dumps(properties))
                    z.writestr(ROOT + "Kirikiroid2", fat(fixture()))
                    z.writestr(ROOT + "resource.txt", b"preserve")
                    z.writestr(ROOT + "_CodeSignature/CodeResources", b"old")

            write(info)
            before = source.read_bytes()
            report = inj.inject_ipa(source, plugin, injected)
            self.assertTrue(report["arm64_extracted"])
            self.assertTrue(report["payload_bytes_unchanged"])
            self.assertEqual(before, source.read_bytes())
            for bundle_id in (None, "com.example.free-fix"):
                destination = output if bundle_id is None else root / "custom.ipa"
                result = clone.clone_ipa(injected, destination, bundle_id=bundle_id)
                self.assertEqual(result["bundle_id"], bundle_id or "tvp.XP3Player.free.Compat")
                with zipfile.ZipFile(destination) as z:
                    fixed = plistlib.loads(z.read(ROOT + "Info.plist"))
                    self.assertEqual(fixed["XP3CompatOriginalBundleIdentifier"], "tvp.XP3Player.free")
                    self.assertEqual(fixed["MinimumOSVersion"], "12.0")
                    binary = z.read(ROOT + "Kirikiroid2")
                    first_data = inj.parse_macho(fixture(), 2)[3]
                    self.assertEqual(binary[first_data:], fixture()[first_data:])
                    self.assertEqual(z.read(ROOT + "resource.txt"), b"preserve")
                    self.assertNotIn(ROOT + "_CodeSignature/CodeResources", z.namelist())
            with self.assertRaises(inj.InjectionError):
                inj.inject_ipa(injected, plugin, root / "twice.ipa")
            old_plugin = root / "old.dylib"
            old_plugin.write_bytes(fixture(filetype=6))
            with self.assertRaises(inj.InjectionError):
                inj.inject_ipa(source, old_plugin, root / "old.ipa")
            for key in ("CFBundleIdentifier", "CFBundleExecutable", "CFBundleShortVersionString", "CFBundleVersion"):
                wrong = dict(info, **{key: "wrong"})
                write(wrong)
                with self.assertRaises(inj.InjectionError):
                    inj.inject_ipa(source, plugin, root / "invalid.ipa")
                with self.assertRaises(clone.CloneError):
                    clone.clone_ipa(source, root / "invalid-clone.ipa")
