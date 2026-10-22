#!/usr/bin/env python3
"""Add a compiled launch storyboard to a patched XP3Player IPA; re-sign afterward.

This changes launch metadata and resources only. Engine rendering, game aspect
ratio, executable bytes, bundle identity, and device-family settings are retained.
"""
import argparse
import copy
import json
import os
from pathlib import Path
import plistlib
import stat
import tempfile
import zipfile

from inject_ipa import APP_ROOT, InjectionError, sha256, signature_residue, validate_zip

RESOURCE_NAME = "LaunchScreen.storyboardc"
LEGACY_KEYS = ("UILaunchImageFile", "UILaunchImages", "UILaunchImages~ipad",
               "UILaunchImageFile~ipad", "UILaunchImageFile~iphone")


def modernize_display(input_ipa, storyboard_dir, output_ipa):
    input_ipa, storyboard_dir, output_ipa = map(Path, (input_ipa, storyboard_dir, output_ipa))
    if output_ipa.resolve() == input_ipa.resolve():
        raise InjectionError("Output must differ from input IPA")
    if os.path.lexists(output_ipa):
        raise InjectionError("Output already exists; choose a new filename")
    if storyboard_dir.name != RESOURCE_NAME or not storyboard_dir.is_dir() or storyboard_dir.is_symlink():
        raise InjectionError("Expected a regular LaunchScreen.storyboardc directory")
    resources = {}
    for path in sorted(storyboard_dir.rglob("*")):
        if path.is_symlink() or not (path.is_dir() or path.is_file()):
            raise InjectionError("Launch storyboard contains a symlink or special file")
        if path.is_file():
            resources[APP_ROOT + RESOURCE_NAME + "/" + path.relative_to(storyboard_dir).as_posix()] = path.read_bytes()
    if not resources or sum(map(len, resources.values())) > 10 * 1024 * 1024:
        raise InjectionError("Missing or oversized compiled launch storyboard")
    storyboard_info = plistlib.loads(resources.get(APP_ROOT + RESOURCE_NAME + "/Info.plist", b""))
    if not isinstance(storyboard_info, dict) or not storyboard_info.get("UIStoryboardDesignatedEntryPointIdentifier"):
        raise InjectionError("Compiled launch storyboard has no entry point")
    entry = storyboard_info["UIStoryboardDesignatedEntryPointIdentifier"]
    nibs = storyboard_info.get("UIViewControllerIdentifiersToNibNames", {})
    nib = nibs.get(entry) if isinstance(nibs, dict) and isinstance(entry, str) else None
    if not isinstance(nib, str) or APP_ROOT + RESOURCE_NAME + "/" + nib + ".nib" not in resources:
        raise InjectionError("Compiled launch storyboard is missing its entry-point nib")

    info_name = APP_ROOT + "Info.plist"
    executable_name = APP_ROOT + "XP3Player"
    removed = []
    with zipfile.ZipFile(input_ipa) as source:
        infos = source.infolist()
        validate_zip(infos)
        app_infos = [i.filename for i in infos if i.filename.startswith("Payload/")
                     and i.filename.count("/") == 2 and i.filename.endswith(".app/Info.plist")]
        if app_infos != [info_name]:
            raise InjectionError("Expected exactly Payload/XP3Player.app/Info.plist")
        original_info = source.read(info_name)
        info = plistlib.loads(original_info)
        if (not isinstance(info, dict)
                or info.get("CFBundleIdentifier") not in ("tvp.XP3Player", "tvp.XP3Player.Compat")
                or info.get("CFBundleExecutable") != "XP3Player"
                or info.get("CFBundleShortVersionString") != "1.3.11"):
            raise InjectionError("Unsupported XP3Player identity or version")
        prefix = (APP_ROOT + RESOURCE_NAME).casefold()
        if any(i.filename.rstrip("/").casefold() == prefix
               or i.filename.casefold().startswith(prefix + "/") for i in infos):
            raise InjectionError("Archive already contains LaunchScreen.storyboardc")
        updated = dict(info)
        removed_keys = [key for key in LEGACY_KEYS if key in updated]
        for key in LEGACY_KEYS:
            updated.pop(key, None)
        updated["UILaunchStoryboardName"] = "LaunchScreen"
        fmt = plistlib.FMT_BINARY if original_info.startswith(b"bplist") else plistlib.FMT_XML
        updated_bytes = plistlib.dumps(updated, fmt=fmt, sort_keys=False)
        executable = source.read(executable_name)
        output_ipa.parent.mkdir(parents=True, exist_ok=True)
        fd, temporary = tempfile.mkstemp(prefix=".xp3display-", suffix=".ipa", dir=output_ipa.parent)
        os.close(fd)
        try:
            with zipfile.ZipFile(temporary, "w", allowZip64=True) as target:
                for member in infos:
                    if signature_residue(member.filename):
                        removed.append(member.filename)
                        continue
                    contents = updated_bytes if member.filename == info_name else source.read(member)
                    target.writestr(copy.copy(member), contents)
                for name, contents in resources.items():
                    member = zipfile.ZipInfo(name, date_time=(2021, 12, 1, 0, 0, 0))
                    member.create_system = 3
                    member.external_attr = (stat.S_IFREG | 0o644) << 16
                    member.compress_type = zipfile.ZIP_DEFLATED
                    target.writestr(member, contents)
            with zipfile.ZipFile(temporary) as target:
                validate_zip(target.infolist())
                if target.testzip() or target.read(info_name) != updated_bytes:
                    raise InjectionError("Output archive verification failed")
                if target.read(executable_name) != executable:
                    raise InjectionError("Executable preservation check failed")
                if any(target.read(name) != contents for name, contents in resources.items()):
                    raise InjectionError("Launch storyboard verification failed")
            os.link(temporary, output_ipa)
        finally:
            os.unlink(temporary)
    return {"output_ipa": str(output_ipa.resolve()),
            "output_ipa_sha256": sha256(output_ipa.read_bytes()),
            "bundle_id": info["CFBundleIdentifier"], "executable_unchanged": True,
            "removed_plist_keys": removed_keys, "launch_storyboard": "LaunchScreen",
            "resource_sha256": {name: sha256(data) for name, data in resources.items()},
            "removed_signature_members": removed, "requires_resigning": True}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("ipa", type=Path)
    parser.add_argument("storyboard", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    try:
        print(json.dumps(modernize_display(args.ipa, args.storyboard, args.output), indent=2, ensure_ascii=False))
    except (InjectionError, OSError, ValueError, zipfile.BadZipFile, KeyError) as exc:
        parser.exit(1, "Display update failed: %s\n" % exc)


if __name__ == "__main__":
    main()
