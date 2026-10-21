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


class InjectionError(ValueError):
    pass


def sha256(data):
    return hashlib.sha256(data).hexdigest()


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
    kept = [raw for cmd, raw in commands if cmd != LC_CODE_SIGNATURE]
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
        if any(info.filename == LIB_PATH for info in infos):
            raise InjectionError("Archive already contains XP3Compat.dylib")
        app_infos = [info.filename for info in infos if info.filename.startswith("Payload/")
                     and info.filename.count("/") == 2 and info.filename.endswith(".app/Info.plist")]
        if app_infos != [APP_ROOT + "Info.plist"]:
            raise InjectionError("Expected exactly Payload/XP3Player.app/Info.plist")
        info = plistlib.loads(source.read(APP_ROOT + "Info.plist"))
        if (info.get("CFBundleIdentifier") != "tvp.XP3Player"
                or info.get("CFBundleExecutable") != "XP3Player"
                or info.get("CFBundleShortVersionString") != "1.3.11"):
            raise InjectionError("Unsupported application identity or version")
        executable_path = APP_ROOT + "XP3Player"
        original = source.read(executable_path)
        patched, report = inject_macho(original)
        output_path.parent.mkdir(parents=True, exist_ok=True)
        fd, temporary = tempfile.mkstemp(prefix=".xp3compat-", suffix=".ipa", dir=output_path.parent)
        os.close(fd)
        try:
            with zipfile.ZipFile(temporary, "w", allowZip64=True) as target:
                for member in infos:
                    if signature_residue(member.filename):
                        removed.append(member.filename)
                        continue
                    contents = patched if member.filename == executable_path else source.read(member)
                    # writestr updates header_offset and other fields on ZipInfo.
                    # The source retains these same objects in its name lookup;
                    # preserve them so subsequent source.read() calls stay valid.
                    target.writestr(copy.copy(member), contents)
                member = zipfile.ZipInfo(LIB_PATH, date_time=(2021, 12, 1, 0, 0, 0))
                member.create_system = 3
                member.external_attr = (stat.S_IFREG | 0o755) << 16
                member.compress_type = zipfile.ZIP_DEFLATED
                target.writestr(member, library)
            with zipfile.ZipFile(temporary) as target:
                bad = target.testzip()
                if bad or target.read(APP_ROOT + "Info.plist") != source.read(APP_ROOT + "Info.plist"):
                    raise InjectionError("Output ZIP integrity or Info.plist preservation check failed")
                if target.read(LIB_PATH) != library:
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
        "removed_signature_members": removed, "info_plist_unchanged": True,
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
