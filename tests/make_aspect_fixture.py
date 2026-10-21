#!/usr/bin/env python3
"""Build and statically verify a tiny, uncompressed Kirikiri XP3 visual fixture.

The archive contains only startup.tjs.  The script creates a 640x480 Window,
an opaque primary Layer, and one 160x160 child target at (240, 160).  All
visuals are drawn with Layer.fillRect, so the fixture has no external assets.
"""

from __future__ import annotations

import argparse
import json
import pathlib
import struct
import zlib


ROOT = pathlib.Path(__file__).resolve().parent
ARCHIVE = ROOT / "AspectRatioSmoke.xp3"
SOURCE = ROOT / "startup.tjs"
MAGIC = b"XP3\r\n \n\x1a\x8bg\x01"
HEADER_SIZE = len(MAGIC) + 8
DATA_OFFSET = HEADER_SIZE


# Keep this source deliberately small and synchronous.  The click callback is
# installed on the Window because Layer's native event action owner is the
# Window passed to its constructor.  The current Window handler reads the
# click position from the event's x,y fields (not Event.target).
SCRIPT = r"""/* XP3 aspect-ratio smoke fixture: 640x480, no external assets. */
var visualWindow = new Window();
visualWindow.caption = "XP3 Aspect Ratio Smoke (640x480)";
visualWindow.width = 640;
visualWindow.height = 480;
visualWindow.innerWidth = 640;
visualWindow.innerHeight = 480;

// The first Layer with a null parent becomes Window's primary layer.
var aspectRoot = new Layer(visualWindow, null);
aspectRoot.setSize(640, 480);
aspectRoot.visible = true;
aspectRoot.fillRect(0, 0, 640, 480, 0xff182033);

// Distinct edge markers make cropping, stretching, and rotation obvious.
aspectRoot.fillRect(0,   0,   32, 32, 0xffef4444);
aspectRoot.fillRect(608, 0,   32, 32, 0xff22c55e);
aspectRoot.fillRect(0,   448, 32, 32, 0xff3b82f6);
aspectRoot.fillRect(608, 448, 32, 32, 0xffd946ef);

// Global target bounds: left=240, top=160, width=160, height=160.
var centerTarget = new Layer(visualWindow, aspectRoot);
centerTarget.setPos(240, 160);
centerTarget.setSize(160, 160);
centerTarget.type = 1;
centerTarget.visible = true;
centerTarget.fillRect(0, 0, 160, 160, 0xfff7c948);
centerTarget.fillRect(0, 0, 160, 8, 0xff3b2f2f);
centerTarget.fillRect(0, 152, 160, 8, 0xff3b2f2f);
centerTarget.fillRect(0, 0, 8, 160, 0xff3b2f2f);
centerTarget.fillRect(152, 0, 8, 160, 0xff3b2f2f);
centerTarget.fillRect(72, 72, 16, 16, 0xff3b2f2f);

// Window native input callbacks receive x,y; Layer action events use a dictionary.
// Suppress Layer forwarding so this fixture shows only one result per tap.
aspectRoot.onClick = function(x, y) {};
centerTarget.onClick = function(x, y) {};
visualWindow.onClick = function(x, y) {
    var inside = x >= 240 && x < 400 && y >= 160 && y < 320;
    System.inform((inside ? "PASS: center target" : "Outside center target")
        + " at canvas (" + x + ", " + y + "). Expected center: (320,240).",
        "XP3 aspect-ratio smoke");
};

visualWindow.visible = true;
"""


def chunk(tag: bytes, data: bytes) -> bytes:
    if len(tag) != 4:
        raise ValueError(f"XP3 chunk tag must be four bytes: {tag!r}")
    return tag + struct.pack("<Q", len(data)) + data


def build_xp3(script: str = SCRIPT) -> bytes:
    """Return one raw XP3 entry with the standard Kirikiri UTF-16 script."""

    payload = b"\xff\xfe" + script.encode("utf-16le")
    name = "startup.tjs".encode("utf-16le")
    info = struct.pack("<IQQH", 0, len(payload), len(payload), len(name) // 2) + name
    segm = struct.pack("<IQQQ", 0, DATA_OFFSET, len(payload), len(payload))
    adlr = struct.pack("<I", zlib.adler32(payload) & 0xFFFFFFFF)
    index = chunk(b"File", chunk(b"info", info) + chunk(b"segm", segm) + chunk(b"adlr", adlr))
    return (
        MAGIC
        + struct.pack("<Q", DATA_OFFSET + len(payload))
        + payload
        + b"\x00"
        + struct.pack("<Q", len(index))
        + index
    )


def read_chunks(data: bytes, start: int = 0, end: int | None = None):
    if end is None:
        end = len(data)
    while start < end:
        if start + 12 > end:
            raise ValueError("truncated XP3 chunk header")
        tag = data[start : start + 4]
        size = struct.unpack_from("<Q", data, start + 4)[0]
        start += 12
        finish = start + size
        if finish > end:
            raise ValueError("XP3 chunk extends beyond its parent")
        yield tag, data[start:finish]
        start = finish
    if start != end:
        raise ValueError("XP3 chunk stream did not end on a boundary")


def verify_archive(path: pathlib.Path = ARCHIVE) -> dict[str, object]:
    data = path.read_bytes()
    if data[: len(MAGIC)] != MAGIC:
        raise ValueError("invalid XP3 magic")
    if len(data) < HEADER_SIZE:
        raise ValueError("truncated XP3 header")

    index_offset = struct.unpack_from("<Q", data, len(MAGIC))[0]
    if index_offset < DATA_OFFSET or index_offset >= len(data):
        raise ValueError(f"index offset out of range: {index_offset}")
    payload = data[DATA_OFFSET:index_offset]
    if not payload.startswith(b"\xff\xfe"):
        raise ValueError("startup.tjs is missing its UTF-16LE BOM")
    decoded = payload[2:].decode("utf-16le")
    if decoded != SCRIPT:
        raise ValueError("startup.tjs payload differs from the checked-in source")

    if index_offset + 9 > len(data):
        raise ValueError("truncated XP3 raw index header")
    if data[index_offset] != 0:
        raise ValueError(f"expected raw XP3 index flag 0, got {data[index_offset]}")
    index_size = struct.unpack_from("<Q", data, index_offset + 1)[0]
    index_start = index_offset + 9
    index_end = index_start + index_size
    if index_end != len(data):
        raise ValueError("XP3 index size does not reach archive EOF")

    files = list(read_chunks(data[index_start:index_end]))
    if len(files) != 1 or files[0][0] != b"File":
        raise ValueError("expected exactly one File entry")
    file_chunks = list(read_chunks(files[0][1]))
    by_tag = {tag: body for tag, body in file_chunks}
    if set(by_tag) != {b"info", b"segm", b"adlr"}:
        raise ValueError(f"unexpected File chunks: {[tag for tag, _ in file_chunks]!r}")

    info = by_tag[b"info"]
    if len(info) < 22:
        raise ValueError("truncated XP3 info chunk")
    flags, original_size, archived_size, name_units = struct.unpack_from("<IQQH", info)
    name_end = 22 + name_units * 2
    name = info[22:name_end].decode("utf-16le")
    if flags != 0 or name != "startup.tjs":
        raise ValueError(f"unexpected entry metadata: flags={flags}, name={name!r}")
    if original_size != len(payload) or archived_size != len(payload):
        raise ValueError("XP3 info sizes do not match raw payload")

    segm = by_tag[b"segm"]
    if len(segm) != 28:
        raise ValueError(f"expected one 28-byte segment, got {len(segm)} bytes")
    seg_flags, seg_start, seg_original_size, seg_archived_size = struct.unpack("<IQQQ", segm)
    if (seg_flags, seg_start, seg_original_size, seg_archived_size) != (0, DATA_OFFSET, len(payload), len(payload)):
        raise ValueError("XP3 segment metadata does not match payload")

    adler = struct.unpack("<I", by_tag[b"adlr"])[0]
    if adler != zlib.adler32(payload) & 0xFFFFFFFF:
        raise ValueError("XP3 adler32 does not match payload")

    return {
        "archive": str(path),
        "bytes": len(data),
        "entry": name,
        "payload_bytes": len(payload),
        "index_offset": index_offset,
        "index_bytes": index_size,
        "geometry": {"window": [640, 480], "target": [240, 160, 160, 160]},
    }


def write_fixture() -> None:
    SOURCE.write_bytes(SCRIPT.encode("utf-8"))
    ARCHIVE.write_bytes(build_xp3())


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--verify-only", action="store_true", help="verify the existing archive without rebuilding it")
    args = parser.parse_args()
    if not args.verify_only:
        write_fixture()
    print(json.dumps(verify_archive(), indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
