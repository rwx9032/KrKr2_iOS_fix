#!/usr/bin/env python3
"""Make a separately installable XP3Player IPA from an existing IPA.

The source application must have the original ``tvp.XP3Player`` bundle
identifier.  This tool only changes the root application's plist and removes
stale signing material; it never signs the archive.  The resulting IPA still
needs the application and its embedded libraries to be signed together.

Only the Python standard library is used.  The ZIP safety checks and signing
residue rules are shared with ``inject_ipa.py`` rather than being duplicated.
"""

import argparse
import copy
import hashlib
import importlib.util
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import re
import tempfile
import zipfile


# ``clone_ipa.py`` is normally run from this directory, in which case the
# sibling module is importable directly.  Loading by path also keeps the
# module usable from the repository's unittest loader, which imports scripts
# by filename rather than putting ``tools`` on sys.path.
try:
    from inject_ipa import InjectionError, signature_residue, validate_zip
except ModuleNotFoundError as exc:
    if exc.name != "inject_ipa":
        raise
    _inject_path = Path(__file__).with_name("inject_ipa.py")
    _inject_spec = importlib.util.spec_from_file_location("_xp3_clone_inject_ipa", _inject_path)
    if _inject_spec is None or _inject_spec.loader is None:  # pragma: no cover - import failure
        raise ImportError("Unable to load sibling inject_ipa.py")
    _inject_module = importlib.util.module_from_spec(_inject_spec)
    _inject_spec.loader.exec_module(_inject_module)
    InjectionError = _inject_module.InjectionError
    signature_residue = _inject_module.signature_residue
    validate_zip = _inject_module.validate_zip


# Public alias makes errors from the shared validator and this tool consistent
# for callers that use the module as a library.
CloneError = InjectionError

ORIGINAL_BUNDLE_ID = "tvp.XP3Player"
DEFAULT_BUNDLE_ID = "tvp.XP3Player.Compat"
DEFAULT_DISPLAY_NAME = "XP3Player Fix"


def sha256(data):
    """Return the SHA-256 digest of bytes."""

    return hashlib.sha256(data).hexdigest()


def _sha256_file(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _validate_bundle_id(bundle_id):
    if not isinstance(bundle_id, str) or not bundle_id:
        raise CloneError("Bundle identifier must be a non-empty string")
    if ("\0" in bundle_id or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9.-]*", bundle_id)
            or bundle_id[-1] in ".-" or ".." in bundle_id):
        raise CloneError("Invalid bundle identifier: " + repr(bundle_id))
    if bundle_id == ORIGINAL_BUNDLE_ID:
        raise CloneError("Target bundle identifier must differ from the original")


def _validate_display_name(display_name):
    if not isinstance(display_name, str) or not display_name or "\0" in display_name:
        raise CloneError("Display name must be a non-empty string")


def _app_root_and_info(infos):
    """Find the sole top-level ``Payload/*.app`` and its root Info.plist."""

    roots = set()
    for member in infos:
        parts = PurePosixPath(member.filename.rstrip("/")).parts
        if len(parts) >= 2 and parts[0] == "Payload" and parts[1].endswith(".app"):
            roots.add("Payload/" + parts[1] + "/")
    if len(roots) != 1:
        raise CloneError("Expected exactly one top-level Payload .app")
    app_root = next(iter(roots))
    info_path = app_root + "Info.plist"
    info_members = [member for member in infos if member.filename == info_path]
    if len(info_members) != 1:
        raise CloneError("Expected exactly one root app Info.plist")
    return app_root, info_path


def _plist_bytes(plist, original_bytes):
    # Keep binary plists binary.  For XML plists, plistlib's canonical output
    # is deterministic while preserving the rest of the archive byte-for-byte
    # at the member-content level.
    fmt = plistlib.FMT_BINARY if original_bytes.startswith(b"bplist") else plistlib.FMT_XML
    return plistlib.dumps(plist, fmt=fmt, sort_keys=False)


def clone_ipa(input_ipa, output_ipa, bundle_id=DEFAULT_BUNDLE_ID,
              display_name=DEFAULT_DISPLAY_NAME):
    """Clone *input_ipa* to *output_ipa* with a new application identity.

    The output path is published atomically and is never overwritten.  The
    returned dictionary is suitable for JSON reporting and includes hashes,
    removed signing members, and the fact that a re-sign is still required.
    """

    input_ipa = Path(input_ipa)
    output_ipa = Path(output_ipa)
    input_resolved = input_ipa.resolve()
    output_resolved = output_ipa.resolve()
    if output_resolved == input_resolved:
        raise CloneError("Output must differ from input IPA")
    # lexists also rejects a dangling symlink, so publishing cannot replace an
    # existing directory entry by accident.
    if os.path.lexists(output_ipa):
        raise CloneError("Output already exists; choose a new filename")
    _validate_bundle_id(bundle_id)
    _validate_display_name(display_name)

    input_hash = _sha256_file(input_ipa)
    removed = []
    original_info_bytes = None
    updated_info_bytes = None
    app_root = None
    info_path = None

    with zipfile.ZipFile(input_ipa) as source:
        infos = source.infolist()
        # This must remain the single source of archive path validation.  It
        # rejects traversal, duplicate names, symlinks, and path conflicts.
        validate_zip(infos)
        app_root, info_path = _app_root_and_info(infos)
        original_info_bytes = source.read(info_path)
        try:
            plist = plistlib.loads(original_info_bytes)
        except (plistlib.InvalidFileException, UnicodeError, ValueError, TypeError) as exc:
            raise CloneError("Invalid root app Info.plist: " + str(exc)) from exc
        if not isinstance(plist, dict):
            raise CloneError("Root app Info.plist must contain a dictionary")
        source_bundle_id = plist.get("CFBundleIdentifier")
        if source_bundle_id != ORIGINAL_BUNDLE_ID:
            raise CloneError("Unsupported source bundle identifier: " + repr(source_bundle_id))

        updated = dict(plist)
        updated["CFBundleIdentifier"] = bundle_id
        updated["CFBundleDisplayName"] = display_name
        updated["CFBundleName"] = display_name
        updated_info_bytes = _plist_bytes(updated, original_info_bytes)

        # Do not create the output parent until all input validation above has
        # succeeded.  This keeps rejected inputs side-effect free.
        output_ipa.parent.mkdir(parents=True, exist_ok=True)
        fd, temporary = tempfile.mkstemp(prefix=".xp3clone-", suffix=".ipa",
                                          dir=output_ipa.parent)
        os.close(fd)
        try:
            with zipfile.ZipFile(temporary, "w", allowZip64=True) as target:
                for member in infos:
                    if signature_residue(member.filename):
                        removed.append(member.filename)
                        continue
                    contents = (updated_info_bytes if member.filename == info_path
                                else source.read(member))
                    # Copy the ZipInfo: writestr updates offsets on the object,
                    # and mutating the source instance can break later reads.
                    target.writestr(copy.copy(member), contents)

            with zipfile.ZipFile(temporary) as target:
                bad = target.testzip()
                if bad:
                    raise CloneError("Output ZIP integrity check failed: " + bad)
                if target.read(info_path) != updated_info_bytes:
                    raise CloneError("Output Info.plist integrity check failed")
                if any(signature_residue(name) for name in target.namelist()):
                    raise CloneError("Output still contains signing residue")

            # Hard-link publication fails if another process created the
            # destination after the preflight check, so it cannot overwrite.
            os.link(temporary, output_ipa)
        finally:
            try:
                os.unlink(temporary)
            except FileNotFoundError:
                pass

    return {
        "input_ipa": str(input_resolved),
        "output_ipa": str(output_resolved),
        "input_ipa_sha256": input_hash,
        "output_ipa_sha256": _sha256_file(output_ipa),
        "bundle_id": bundle_id,
        "display_name": display_name,
        "app_root": app_root,
        "info_plist": info_path,
        "removed_signature_members": removed,
        "requires_resigning": True,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("inputIPA", type=Path, metavar="inputIPA")
    parser.add_argument("outputIPA", type=Path, metavar="outputIPA")
    parser.add_argument("--bundle-id", default=DEFAULT_BUNDLE_ID,
                        help="new CFBundleIdentifier (default: %(default)s)")
    parser.add_argument("--display-name", default=DEFAULT_DISPLAY_NAME,
                        help="new CFBundleDisplayName and CFBundleName (default: %(default)s)")
    args = parser.parse_args()
    try:
        report = clone_ipa(args.inputIPA, args.outputIPA, args.bundle_id, args.display_name)
    except (CloneError, OSError, zipfile.BadZipFile, KeyError, UnicodeError,
            plistlib.InvalidFileException, TypeError, ValueError) as exc:
        parser.exit(1, "Clone failed: %s\n" % exc)
    print(json.dumps(report, indent=2, ensure_ascii=False))


if __name__ == "__main__":
    main()
