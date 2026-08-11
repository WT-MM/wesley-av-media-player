#!/usr/bin/env python3
"""Build a modern PNG-backed ICNS file from a conventional .iconset folder.

This tiny writer is used because iconutil on the current development macOS
rejects otherwise valid iconsets. ICNS elements are just a four-byte type, a
big-endian element length, and PNG data for modern icon sizes.
"""

from __future__ import annotations

import argparse
import struct
from pathlib import Path


ELEMENTS = (
    (b"icp4", "icon_16x16.png"),
    (b"ic11", "icon_16x16@2x.png"),
    (b"icp5", "icon_32x32.png"),
    (b"ic12", "icon_32x32@2x.png"),
    (b"ic07", "icon_128x128.png"),
    (b"ic13", "icon_128x128@2x.png"),
    (b"ic08", "icon_256x256.png"),
    (b"ic14", "icon_256x256@2x.png"),
    (b"ic09", "icon_512x512.png"),
    (b"ic10", "icon_512x512@2x.png"),
)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("iconset", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()

    elements: list[bytes] = []
    for element_type, filename in ELEMENTS:
        path = args.iconset / filename
        payload = path.read_bytes()
        if not payload.startswith(b"\x89PNG\r\n\x1a\n"):
            raise SystemExit(f"not a PNG: {path}")
        elements.append(
            element_type + struct.pack(">I", len(payload) + 8) + payload
        )

    body = b"".join(elements)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(b"icns" + struct.pack(">I", len(body) + 8) + body)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
