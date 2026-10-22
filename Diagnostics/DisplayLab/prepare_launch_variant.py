#!/usr/bin/env python3
"""Prepare a launch-metadata-only Info.plist variant for a copied XP3Player app.

This is a small A/B helper for Diagnostics/DisplayLab.  It reads one already
copied app Info.plist and writes one NEW Info.plist.  It never copies launch
resources; the storyboard variant expects the root workflow to provide
LaunchScreen.storyboardc separately.

Variants:
  legacy-preserve  byte-for-byte copy (baseline, no metadata change)
  storyboard       set UILaunchStoryboardName=LaunchScreen and remove the
                   legacy launch-image keys
  plist            remove the legacy launch-image keys and
                   UILaunchStoryboardName, then set UILaunchScreen to an empty
                   native dictionary ({})

The identity guard accepts only XP3Player 1.3.11 with bundle identifier
tvp.XP3Player or tvp.XP3Player.Compat.  Input/output symlinks, existing outputs,
path collisions, malformed plists, and unsupported identities are refused.

Both modern variants are EXPERIMENTAL.  Apple documents UILaunchScreen as a
dictionary alternative to a launch storyboard:
https://developer.apple.com/documentation/bundleresources/information-property-list/uilaunchscreen
That documentation does not claim a fix for this app's display/fullscreen
problem; runtime A/B validation is still required.
"""
from __future__ import annotations

import argparse
import copy
import hashlib
import json
import os
from pathlib import Path
import plistlib
import stat
import sys
from typing import Any

VARIANTS = ("legacy-preserve", "storyboard", "plist")
SUPPORTED_BUNDLE_IDS = ("tvp.XP3Player", "tvp.XP3Player.Compat")
EXPECTED_EXECUTABLE = "XP3Player"
EXPECTED_SHORT_VERSION = "1.3.11"

# Legacy launch-image metadata keys.  The tilde variants are device-specific
# spellings of the same legacy mechanism.
LEGACY_LAUNCH_IMAGE_KEYS = (
    "UILaunchImageFile",
    "UILaunchImageFile~ipad",
    "UILaunchImageFile~iphone",
    "UILaunchImages",
    "UILaunchImages~ipad",
)

STORYBOARD_NAME = "LaunchScreen"
UILAUNCHSCREEN_KEY = "UILaunchScreen"


class LaunchVariantError(Exception):
    """A refused input or a failed output-safety check."""


def _sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _refuse_symlink(path: Path, label: str) -> None:
    if path.is_symlink():
        raise LaunchVariantError(
            "%s must not be a symlink: %s" % (label, path)
        )


def _read_input_plist(path: Path) -> bytes:
    """Read a regular input file without following a final symlink."""
    _refuse_symlink(path, "Input Info.plist")
    flags = os.O_RDONLY
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        fd = os.open(os.fspath(path), flags)
    except FileNotFoundError as exc:
        raise LaunchVariantError("Input Info.plist does not exist: %s" % path) from exc
    except OSError as exc:
        raise LaunchVariantError(
            "Cannot open input Info.plist: %s (%s)" % (path, exc)
        ) from exc
    try:
        mode = os.fstat(fd).st_mode
        if not stat.S_ISREG(mode):
            raise LaunchVariantError(
                "Input Info.plist must be a regular file: %s" % path
            )
        chunks = []
        while True:
            chunk = os.read(fd, 1024 * 1024)
            if not chunk:
                break
            chunks.append(chunk)
        return b"".join(chunks)
    finally:
        os.close(fd)


def _output_target(input_real: Path, output_path: Path) -> Path:
    """Validate a brand-new output path and return its absolute target."""
    if os.path.lexists(os.fspath(output_path)):
        if output_path.is_symlink():
            raise LaunchVariantError(
                "Output must not be a symlink: %s" % output_path
            )
        raise LaunchVariantError(
            "Output already exists; refusing to overwrite: %s" % output_path
        )

    parent = output_path.parent
    try:
        parent_stat = parent.stat()
    except FileNotFoundError as exc:
        raise LaunchVariantError(
            "Output parent directory does not exist: %s" % parent
        ) from exc
    except OSError as exc:
        raise LaunchVariantError(
            "Cannot inspect output parent directory: %s (%s)" % (parent, exc)
        ) from exc
    if not stat.S_ISDIR(parent_stat.st_mode):
        raise LaunchVariantError(
            "Output parent is not a directory: %s" % parent
        )

    target = parent.resolve(strict=True) / output_path.name
    if target == input_real:
        raise LaunchVariantError(
            "Output collides with the input Info.plist; choose a new path"
        )
    if os.path.lexists(os.fspath(target)):
        raise LaunchVariantError(
            "Output already exists; refusing to overwrite: %s" % target
        )
    return target


def _decode_plist(raw: bytes) -> tuple[dict[str, Any], plistlib.PlistFormat, str]:
    """Load a dict and record whether the source was XML or binary."""
    if raw.startswith(b"bplist00"):
        fmt = plistlib.FMT_BINARY
        format_name = "binary"
    else:
        head = raw
        if head.startswith(b"\xef\xbb\xbf"):
            head = head[3:]
        head = head.lstrip()
        if head.startswith((b"<?xml", b"<plist", b"<!DOCTYPE plist")):
            fmt = plistlib.FMT_XML
            format_name = "xml"
        else:
            raise LaunchVariantError(
                "Unsupported Info.plist encoding; expected an XML or binary plist"
            )

    try:
        info = plistlib.loads(raw)
    except Exception as exc:  # plistlib raises several parser-specific errors.
        raise LaunchVariantError("Cannot parse input Info.plist: %s" % exc) from exc
    if not isinstance(info, dict):
        raise LaunchVariantError("Input Info.plist root must be a dictionary")
    return info, fmt, format_name


def _validate_identity(info: dict[str, Any]) -> None:
    bundle_id = info.get("CFBundleIdentifier")
    if bundle_id not in SUPPORTED_BUNDLE_IDS:
        raise LaunchVariantError(
            "Wrong bundle identity: expected CFBundleIdentifier in %r, got %r"
            % (SUPPORTED_BUNDLE_IDS, bundle_id)
        )
    executable = info.get("CFBundleExecutable")
    if executable != EXPECTED_EXECUTABLE:
        raise LaunchVariantError(
            "Wrong bundle identity: expected CFBundleExecutable=%r, got %r"
            % (EXPECTED_EXECUTABLE, executable)
        )
    short_version = info.get("CFBundleShortVersionString")
    if short_version != EXPECTED_SHORT_VERSION:
        raise LaunchVariantError(
            "Wrong bundle identity: expected CFBundleShortVersionString=%r, got %r"
            % (EXPECTED_SHORT_VERSION, short_version)
        )


def _verify_preservation(
    original: dict[str, Any],
    updated: dict[str, Any],
    intentionally_changed: set[str],
) -> None:
    """Fail closed if any key outside the requested launch edits changed."""
    for key, value in original.items():
        if key in intentionally_changed:
            continue
        if key not in updated:
            raise LaunchVariantError(
                "Internal preservation check failed: non-launch key %r disappeared" % key
            )
        if updated[key] != value:
            raise LaunchVariantError(
                "Internal preservation check failed: non-launch key %r changed" % key
            )
    extra = set(updated) - set(original) - intentionally_changed
    if extra:
        raise LaunchVariantError(
            "Internal preservation check failed: unexpected new key(s) %r"
            % sorted(extra)
        )


def _build_updated_plist(
    info: dict[str, Any], variant: str
) -> tuple[dict[str, Any], list[str], list[str], dict[str, Any], list[str]]:
    """Apply only the keys named by the selected variant."""
    updated = copy.deepcopy(info)
    removed: list[str] = []
    replaced: list[str] = []
    set_keys: dict[str, Any] = {}
    warnings: list[str] = []

    for key in LEGACY_LAUNCH_IMAGE_KEYS:
        if key in updated:
            del updated[key]
            removed.append(key)

    if variant == "storyboard":
        if "UILaunchStoryboardName" in updated and updated["UILaunchStoryboardName"] != STORYBOARD_NAME:
            replaced.append("UILaunchStoryboardName")
        updated["UILaunchStoryboardName"] = STORYBOARD_NAME
        set_keys["UILaunchStoryboardName"] = STORYBOARD_NAME
        if UILAUNCHSCREEN_KEY in updated:
            warnings.append(
                "Input also defines %s; this storyboard variant leaves that "
                "dictionary key unchanged. Use a source without modern launch "
                "keys for a clean dictionary-vs-storyboard A/B." % UILAUNCHSCREEN_KEY
            )
    elif variant == "plist":
        if "UILaunchStoryboardName" in updated:
            del updated["UILaunchStoryboardName"]
            removed.append("UILaunchStoryboardName")
        if UILAUNCHSCREEN_KEY in updated and updated[UILAUNCHSCREEN_KEY] != {}:
            replaced.append(UILAUNCHSCREEN_KEY)
        updated[UILAUNCHSCREEN_KEY] = {}
        set_keys[UILAUNCHSCREEN_KEY] = {}
        if any(key.startswith("UILaunchStoryboardName~") for key in updated):
            warnings.append(
                "A device-specific UILaunchStoryboardName variant remains; "
                "the utility intentionally edits only the documented base key."
            )
    elif variant != "legacy-preserve":
        raise LaunchVariantError("Unknown variant: %s" % variant)

    intentionally_changed = set(removed) | set(replaced) | set(set_keys)
    _verify_preservation(info, updated, intentionally_changed)
    return updated, removed, replaced, set_keys, warnings


def _write_new_file(path: Path, data: bytes) -> None:
    """Atomically claim a new path and write data without overwriting."""
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        fd = os.open(os.fspath(path), flags, 0o644)
    except FileExistsError as exc:
        raise LaunchVariantError(
            "Output already exists; refusing to overwrite: %s" % path
        ) from exc
    except OSError as exc:
        raise LaunchVariantError("Cannot create output Info.plist: %s" % exc) from exc

    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
    except BaseException:
        try:
            os.unlink(os.fspath(path))
        except OSError:
            pass
        raise


def prepare_launch_variant(
    input_plist: os.PathLike[str] | str,
    output_plist: os.PathLike[str] | str,
    variant: str,
) -> dict[str, Any]:
    """Create one launch-metadata variant and return a JSON-ready report."""
    if variant not in VARIANTS:
        raise LaunchVariantError(
            "Unknown variant %r; expected one of %r" % (variant, VARIANTS)
        )

    input_path = Path(input_plist)
    output_path = Path(output_plist)
    _refuse_symlink(output_path, "Output Info.plist")
    _refuse_symlink(input_path, "Input Info.plist")

    raw = _read_input_plist(input_path)
    input_real = input_path.resolve(strict=True)
    output_target = _output_target(input_real, output_path)

    info, fmt, format_name = _decode_plist(raw)
    _validate_identity(info)

    if variant == "legacy-preserve":
        output_bytes = raw
        removed: list[str] = []
        replaced: list[str] = []
        set_keys: dict[str, Any] = {}
        warnings: list[str] = []
    else:
        updated, removed, replaced, set_keys, warnings = _build_updated_plist(
            info, variant
        )
        try:
            output_bytes = plistlib.dumps(updated, fmt=fmt, sort_keys=False)
        except Exception as exc:
            raise LaunchVariantError(
                "Cannot serialize updated Info.plist: %s" % exc
            ) from exc
        try:
            round_trip = plistlib.loads(output_bytes)
        except Exception as exc:
            raise LaunchVariantError(
                "Serialized Info.plist failed verification: %s" % exc
            ) from exc
        if round_trip != updated:
            raise LaunchVariantError(
                "Serialized Info.plist does not round-trip to the intended dictionary"
            )

    _write_new_file(output_target, output_bytes)
    try:
        written = output_target.read_bytes()
        if written != output_bytes:
            raise LaunchVariantError("Output verification failed: bytes differ")
    except BaseException:
        try:
            os.unlink(os.fspath(output_target))
        except OSError:
            pass
        raise

    identity = {
        "CFBundleIdentifier": info["CFBundleIdentifier"],
        "CFBundleExecutable": info["CFBundleExecutable"],
        "CFBundleShortVersionString": info["CFBundleShortVersionString"],
    }
    return {
        "variant": variant,
        "experimental": variant != "legacy-preserve",
        "input_plist": str(input_real),
        "output_plist": str(output_target),
        "input_sha256": _sha256(raw),
        "output_sha256": _sha256(output_bytes),
        "format": format_name,
        "format_preserved": True,
        "identity": identity,
        "removed_keys": removed,
        "replaced_keys": replaced,
        "set_keys": set_keys,
        "unchanged_bytes": output_bytes == raw,
        "all_non_launch_keys_preserved": True,
        "resources_copied": False,
        "storyboard_resource_required": variant == "storyboard",
        "bundle_resigning_required_after_install": variant != "legacy-preserve",
        "runtime_validation_required": variant != "legacy-preserve",
        "warnings": warnings,
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Create a launch-metadata-only XP3Player Info.plist variant."
    )
    parser.add_argument(
        "--variant",
        required=True,
        choices=VARIANTS,
        help="legacy-preserve (baseline), storyboard, or plist (empty UILaunchScreen dict)",
    )
    parser.add_argument("input", type=Path, help="copied app Info.plist to read")
    parser.add_argument("output", type=Path, help="new Info.plist path (must not exist)")
    args = parser.parse_args(argv)

    try:
        report = prepare_launch_variant(args.input, args.output, args.variant)
    except LaunchVariantError as exc:
        parser.exit(2, "Launch variant refused: %s\n" % exc)
    print(json.dumps(report, indent=2, ensure_ascii=False, sort_keys=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
