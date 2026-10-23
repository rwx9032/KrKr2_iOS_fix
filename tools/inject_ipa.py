#!/usr/bin/env python3
"""Inject XP3Compat into the supplied XP3Player 1.3.11 IPA (still needs signing).

Standard library only. Does not extract archives or modify the input files.
The original executable hash is recorded in the report for traceability; it is not
used to reject a valid same-version input with different bytes.
"""
import argparse
import copy
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import stat
import struct
import tempfile
import zipfile

INSTALL_NAME = "@executable_path/Frameworks/XP3Compat.dylib"
APP_ROOT = "Payload/XP3Player.app/"
LIB_PATH = APP_ROOT + "Frameworks/XP3Compat.dylib"
CPU_ARM64 = 0x0100000C
MH_EXECUTE, MH_DYLIB = 2, 6
LC_SEGMENT_64, LC_LOAD_DYLIB = 0x19, 0xC
LC_CODE_SIGNATURE, LC_ENCRYPTION_INFO_64 = 0x1D, 0x2C
LC_VERSION_MIN_IPHONEOS, LC_BUILD_VERSION = 0x25, 0x32
IOS_PLATFORMS = (2, 7)  # iOS, iOS Simulator
PLATFORM_NAMES = {1: "macos", 2: "ios", 6: "mac-catalyst", 7: "ios-simulator"}
MINIMUM_SDK_VERSION = 26 << 16  # 26.0


class InjectionError(ValueError):
    pass


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def plist_bytes(plist, original_bytes):
    # Keep binary plists binary. For XML plists, plistlib's canonical output
    # is deterministic while preserving the rest of the archive at member level.
    fmt = plistlib.FMT_BINARY if original_bytes.startswith(b"bplist") else plistlib.FMT_XML
    return plistlib.dumps(plist, fmt=fmt, sort_keys=False)


def configure_ipad_launch(plist):
    """Avoid selecting a legacy 4:3 iPad launch image.

    A device-qualified UILaunchScreen dictionary lets iPadOS generate the
    launch surface at the current display size instead of resolving the
    legacy UILaunchImageFile/UILaunchImages entries.  iPhone launch metadata
    and all orientation/full-screen keys are left untouched.  This function
    does not rotate the interface or change the runtime window; the
    UIRequiresFullScreen compatibility mode still controls presentation.
    Existing modern launch configurations take precedence over the generated
    default.  XP3Player 1.3.11 requires iOS 15, which supports UILaunchScreen.
    """
    families = plist.get("UIDeviceFamily", [])
    if not isinstance(families, list) or 2 not in families:
        return False
    keys = ("UILaunchScreen", "UILaunchScreen~ipad",
            "UILaunchStoryboardName", "UILaunchStoryboardName~ipad")
    if any(key in plist for key in keys):
        return False
    plist["UILaunchScreen~ipad"] = {}
    return True


def _version_string(value):
    major, minor, patch = (value >> 16) & 0xFFFF, (value >> 8) & 0xFF, value & 0xFF
    return f"{major}.{minor}" if not patch else f"{major}.{minor}.{patch}"


def _sdk_record(command, platform, before, after, updated, reason=None):
    record = {"command": command, "platform": platform,
              "before": _version_string(before), "after": _version_string(after),
              "updated": updated}
    if reason:
        record["reason"] = reason
    return record


def _patch_sdk_command(cmd, raw):
    """Raise an existing iOS-family SDK field when eligible; keep other bytes."""
    if cmd == LC_BUILD_VERSION:
        platform = struct.unpack_from("<I", raw, 8)[0]
        command = "LC_BUILD_VERSION"
        platform_name = PLATFORM_NAMES.get(platform, "platform-%d" % platform)
        sdk_offset = 16
    else:
        platform = None
        command = "LC_VERSION_MIN_IPHONEOS"
        platform_name = "ios"
        sdk_offset = 12
    sdk = struct.unpack_from("<I", raw, sdk_offset)[0]
    if platform is not None and platform not in IOS_PLATFORMS:
        return raw, _sdk_record(command, platform_name, sdk, sdk, False,
                                "unsupported platform")
    if sdk >= MINIMUM_SDK_VERSION:
        return raw, _sdk_record(command, platform_name, sdk, sdk, False)
    changed = bytearray(raw)
    struct.pack_into("<I", changed, sdk_offset, MINIMUM_SDK_VERSION)
    return bytes(changed), _sdk_record(command, platform_name, sdk,
                                       MINIMUM_SDK_VERSION, True)


def _patch_sdk_commands(commands):
    kept, records = [], []
    for cmd, raw in commands:
        if cmd == LC_CODE_SIGNATURE:
            continue
        if cmd in (LC_BUILD_VERSION, LC_VERSION_MIN_IPHONEOS):
            raw, record = _patch_sdk_command(cmd, raw)
            records.append(record)
        kept.append(raw)
    return kept, records


def parse_macho(data, expected_type):
    if len(data) < 32:
        raise InjectionError("Truncated Mach-O header")
    header = struct.unpack_from("<8I", data)
    magic, cpu, subtype, filetype, ncmds, sizeofcmds, flags, reserved = header
    if magic != 0xFEEDFACF or cpu != CPU_ARM64 or (subtype & 0xFFFFFF) != 0:
        raise InjectionError("Only thin, little-endian arm64 Mach-O is supported")
    if filetype != expected_type:
        raise InjectionError("Unexpected Mach-O file type")
    end = 32 + sizeofcmds
    if end > len(data) or ncmds > sizeofcmds // 8:
        raise InjectionError("Invalid load-command bounds")
    commands, names, first_data = [], [], len(data)
    pos = 32
    for _ in range(ncmds):
        if pos + 8 > end:
            raise InjectionError("Truncated load command")
        cmd, size = struct.unpack_from("<2I", data, pos)
        if size < 8 or size % 8 or pos + size > end:
            raise InjectionError("Invalid load-command size")
        raw = data[pos:pos + size]
        if cmd == LC_SEGMENT_64:
            if size < 72:
                raise InjectionError("Truncated segment command")
            fileoff, filesize = struct.unpack_from("<2Q", raw, 40)
            nsects = struct.unpack_from("<I", raw, 64)[0]
            if 72 + 80 * nsects != size or fileoff + filesize > len(data):
                raise InjectionError("Invalid segment or section bounds")
            if fileoff and filesize:
                first_data = min(first_data, fileoff)
            for i in range(nsects):
                section = 72 + i * 80
                length = struct.unpack_from("<Q", raw, section + 40)[0]
                offset = struct.unpack_from("<I", raw, section + 48)[0]
                section_type = struct.unpack_from("<I", raw, section + 64)[0] & 0xFF
                # S_ZEROFILL, S_GB_ZEROFILL, S_THREAD_LOCAL_ZEROFILL have no bytes.
                if length and section_type not in (1, 0xC, 0x12):
                    if offset < end or offset + length > len(data):
                        raise InjectionError("Invalid file-backed section bounds")
                    first_data = min(first_data, offset)
        elif cmd == LC_BUILD_VERSION:
            if size < 24:
                raise InjectionError("Truncated build-version command")
            ntools = struct.unpack_from("<I", raw, 20)[0]
            if size != 24 + 8 * ntools:
                raise InjectionError("Invalid build-version tool table")
        elif cmd == LC_VERSION_MIN_IPHONEOS:
            if size != 16:
                raise InjectionError("Invalid version-min command")
        elif cmd == LC_ENCRYPTION_INFO_64:
            if size < 24:
                raise InjectionError("Truncated encryption command")
            if struct.unpack_from("<I", raw, 16)[0]:
                raise InjectionError("Encrypted executable: injection requires an unencrypted input")
        elif cmd == LC_CODE_SIGNATURE:
            if size != 16:
                raise InjectionError("Invalid code-signature command")
            offset, length = struct.unpack_from("<2I", raw, 8)
            if offset + length > len(data):
                raise InjectionError("Invalid code-signature bounds")
        elif cmd in (0xC, 0x18 | 0x80000000, 0x1F | 0x80000000,
                     0x20, 0x23 | 0x80000000, 0xD):
            if size < 24:
                raise InjectionError("Truncated dylib command")
            nameoff = struct.unpack_from("<I", raw, 8)[0]
            if nameoff < 24 or nameoff >= size or b"\0" not in raw[nameoff:]:
                raise InjectionError("Invalid dylib name")
            names.append(raw[nameoff:].split(b"\0", 1)[0].decode("utf-8", "strict"))
        commands.append((cmd, raw))
        pos += size
    if pos != end:
        raise InjectionError("Load-command count and size disagree")
    return header, commands, names, first_data


def arm64_executable(data):
    """Extract the free release's unique arm64 slice after validating its FAT table."""
    if data[:4] != b"\xca\xfe\xba\xbe":
        parse_macho(data, MH_EXECUTE)
        return data
    if len(data) < 8:
        raise InjectionError("Invalid FAT header")
    count = struct.unpack_from(">I", data, 4)[0]
    if not count or count > (len(data) - 8) // 20:
        raise InjectionError("Invalid FAT architecture table")
    ranges, selected = [], None
    for index in range(count):
        cpu, subtype, offset, size, align = struct.unpack_from(">5I", data, 8 + index * 20)
        if (offset < 8 + count * 20 or not size or offset > len(data) or
                size > len(data) - offset or align > 30 or offset % (1 << align)):
            raise InjectionError("Invalid FAT slice bounds or alignment")
        end = offset + size
        if any(offset < b and a < end for a, b in ranges):
            raise InjectionError("Overlapping FAT slices")
        ranges.append((offset, end))
        if cpu == CPU_ARM64 and subtype & 0xffffff == 0:
            if selected is not None:
                raise InjectionError("Duplicate arm64 slices")
            selected = data[offset:end]
            parse_macho(selected, MH_EXECUTE)
            if struct.unpack_from("<I", selected, 8)[0] != subtype:
                raise InjectionError("FAT architecture metadata mismatch")
    if selected is None:
        raise InjectionError("Missing supported arm64 slice")
    return selected


def inject_macho(data):
    header, commands, names, first_data = parse_macho(data, MH_EXECUTE)
    if INSTALL_NAME in names or any(name.endswith("/XP3Compat.dylib") for name in names):
        raise InjectionError("XP3Compat is already loaded")
    old_end = 32 + header[5]
    if first_data == len(data):
        raise InjectionError("No file-backed sections found")
    if any(data[old_end:first_data]):
        raise InjectionError("Header padding contains nonzero bytes")
    name = INSTALL_NAME.encode() + b"\0"
    size = (24 + len(name) + 7) & ~7
    newcmd = struct.pack("<6I", LC_LOAD_DYLIB, size, 24, 0, 0x10000, 0x10000)
    newcmd += name + b"\0" * (size - 24 - len(name))
    # This raises the declared SDK only; it does not rebuild the executable.
    kept, sdk_versions = _patch_sdk_commands(commands)
    new_table = b"".join(kept) + newcmd
    new_end = 32 + len(new_table)
    if new_end > first_data:
        raise InjectionError("Insufficient zero header padding for injection")
    modified = bytearray(data)
    struct.pack_into("<2I", modified, 16, len(kept) + 1, len(new_table))
    modified[32:max(old_end, new_end)] = new_table + b"\0" * max(0, old_end - new_end)
    result = bytes(modified)
    parsed = parse_macho(result, MH_EXECUTE)
    if parsed[2].count(INSTALL_NAME) != 1 or any(c == LC_CODE_SIGNATURE for c, _ in parsed[1]):
        raise InjectionError("Internal post-injection validation failed")
    if result[first_data:] != data[first_data:]:
        raise InjectionError("Internal executable payload preservation check failed")
    return result, {
        "load_command": INSTALL_NAME,
        "commands_before": header[4], "commands_after": parsed[0][4],
        "header_padding_remaining": first_data - new_end,
        "code_signature_commands_removed": sum(c == LC_CODE_SIGNATURE for c, _ in commands),
        "sdk_versions": sdk_versions,
        "sdk_version_updated": any(record["updated"] for record in sdk_versions),
        "payload_bytes_unchanged": True,
    }


def validate_zip(infos):
    seen = set()
    directories = set()
    total = 0
    for info in infos:
        name = info.filename
        path = PurePosixPath(name)
        if (not name or "\0" in info.orig_filename or "\\" in name or name.startswith("/")
                or any(part in ("", ".", "..") for part in name.rstrip("/").split("/"))
                or ":" in path.parts[0]):
            raise InjectionError("Unsafe ZIP member path: " + repr(name))
        normalized = name.rstrip("/").casefold()
        if normalized in seen:
            raise InjectionError("Duplicate ZIP member path: " + name)
        seen.add(normalized)
        if info.is_dir():
            directories.add(normalized)
        mode = (info.external_attr >> 16) & 0xFFFF
        kind = stat.S_IFMT(mode)
        if kind not in (0, stat.S_IFREG, stat.S_IFDIR):
            raise InjectionError("ZIP symlinks and special files are not supported: " + name)
        if info.flag_bits & 1:
            raise InjectionError("Encrypted ZIP members are not supported")
        total += info.file_size
        if total > 2 * 1024**3:
            raise InjectionError("Archive exceeds the 2 GiB unpacked safety limit")
    for info in infos:
        parts = info.filename.rstrip("/").split("/")
        for i in range(1, len(parts)):
            prefix = "/".join(parts[:i]).casefold()
            if prefix in seen and prefix not in directories:
                raise InjectionError("ZIP file/directory path conflict")


def signature_residue(name):
    parts = PurePosixPath(name).parts
    return ("_CodeSignature" in parts or "SC_Info" in parts
            or (parts and parts[-1] == "embedded.mobileprovision")
            or (parts and parts[0] in ("iTunesMetadata.plist", "iTunesArtwork", "iTunesArtwork@2x")))


def inject_ipa(ipa_path, dylib_path, output_path):
    ipa_path, dylib_path, output_path = map(Path, (ipa_path, dylib_path, output_path))
    if output_path.resolve() in (ipa_path.resolve(), dylib_path.resolve()):
        raise InjectionError("Output must differ from both input paths")
    if output_path.exists():
        raise InjectionError("Output already exists; choose a new filename")
    library = dylib_path.read_bytes()
    parse_macho(library, MH_DYLIB)
    removed = []
    with zipfile.ZipFile(ipa_path) as source:
        infos = source.infolist()
        validate_zip(infos)
        app_infos = [member.filename for member in infos if member.filename.startswith("Payload/")
                     and member.filename.count("/") == 2 and member.filename.endswith(".app/Info.plist")]
        if len(app_infos) != 1 or app_infos[0] not in (
                APP_ROOT + "Info.plist", "Payload/Kirikiroid2.app/Info.plist"):
            raise InjectionError("Expected exactly one supported Payload app Info.plist")
        info_path = app_infos[0]
        app_root = info_path.rsplit("/", 1)[0] + "/"
        lib_path = app_root + "Frameworks/XP3Compat.dylib"
        if any(member.filename == lib_path for member in infos):
            raise InjectionError("Archive already contains XP3Compat.dylib")
        info_bytes = source.read(info_path)
        info = plistlib.loads(info_bytes)
        is_free = app_root == "Payload/Kirikiroid2.app/"
        executable = "Kirikiroid2" if is_free else "XP3Player"
        if (not isinstance(info, dict) or
                info.get("CFBundleIdentifier") != ("tvp.XP3Player.free" if is_free else "tvp.XP3Player") or
                info.get("CFBundleExecutable") != executable or
                info.get("CFBundleShortVersionString") != ("1.3.9" if is_free else "1.3.11") or
                (is_free and info.get("CFBundleVersion") != "20")):
            raise InjectionError("Unsupported application identity or version")
        if is_free:
            if b"XP3COMPAT_FREE_139_V1" not in library:
                raise InjectionError("Plugin does not support Kirikiroid2 free 1.3.9")
            info["MinimumOSVersion"] = "12.0"
        ipad_launch_added = configure_ipad_launch(info)
        updated_info_bytes = plist_bytes(info, info_bytes) if is_free or ipad_launch_added else info_bytes
        info_plist_unchanged = updated_info_bytes == info_bytes
        executable_path = app_root + executable
        original = source.read(executable_path)
        executable_data = arm64_executable(original) if is_free else original
        patched, report = inject_macho(executable_data)
        report["arm64_extracted"] = executable_data != original
        output_path.parent.mkdir(parents=True, exist_ok=True)
        fd, temporary = tempfile.mkstemp(prefix=".xp3compat-", suffix=".ipa", dir=output_path.parent)
        os.close(fd)
        try:
            with zipfile.ZipFile(temporary, "w", allowZip64=True) as target:
                for member in infos:
                    if signature_residue(member.filename):
                        removed.append(member.filename)
                        continue
                    if member.filename == executable_path:
                        contents = patched
                    elif member.filename == info_path:
                        contents = updated_info_bytes
                    else:
                        contents = source.read(member)
                    # writestr updates header_offset and other fields on ZipInfo.
                    # The source retains these same objects in its name lookup;
                    # preserve them so subsequent source.read() calls stay valid.
                    target.writestr(copy.copy(member), contents)
                member = zipfile.ZipInfo(lib_path, date_time=(2021, 12, 1, 0, 0, 0))
                member.create_system = 3
                member.external_attr = (stat.S_IFREG | 0o755) << 16
                member.compress_type = zipfile.ZIP_DEFLATED
                target.writestr(member, library)
            with zipfile.ZipFile(temporary) as target:
                bad = target.testzip()
                if bad or target.read(info_path) != updated_info_bytes:
                    raise InjectionError("Output ZIP integrity or Info.plist check failed")
                if target.read(executable_path) != patched:
                    raise InjectionError("Output executable integrity check failed")
                if target.read(lib_path) != library:
                    raise InjectionError("Output dylib integrity check failed")
            # A hard link atomically publishes without replacing a file created by a concurrent process.
            os.link(temporary, output_path)
        finally:
            os.unlink(temporary)
    report.update({
        "input_ipa": str(ipa_path.resolve()), "output_ipa": str(output_path.resolve()),
        "original_executable_sha256": sha256(original),
        "patched_executable_sha256": sha256(patched), "dylib_sha256": sha256(library),
        "output_ipa_sha256": sha256(output_path.read_bytes()),
        "removed_signature_members": removed,
        "ipad_launch_screen_added": ipad_launch_added,
        "info_plist_unchanged": info_plist_unchanged,
        "requires_resigning": True,
    })
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("ipa", type=Path)
    parser.add_argument("dylib", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    try:
        print(json.dumps(inject_ipa(args.ipa, args.dylib, args.output), indent=2, ensure_ascii=False))
    except (InjectionError, OSError, zipfile.BadZipFile, KeyError, UnicodeError,
            plistlib.InvalidFileException) as exc:
        parser.exit(1, "Injection failed: %s\n" % exc)


if __name__ == "__main__":
    main()
