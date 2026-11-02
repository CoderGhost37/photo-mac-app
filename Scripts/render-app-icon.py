#!/usr/bin/env python3
"""Rasterize Scripts/app-icon.svg into the macOS AppIcon set.

Requires rsvg-convert (librsvg). From the repository root:

    python3 Scripts/render-app-icon.py

Writes the 16, 32, 64, 128, 256, 512, and 1024 PNGs used by
AppIcon.appiconset, plus the 1024 and 128 previews under docs/.
The SVG is the artwork. This script only rasterizes it.
"""

from __future__ import annotations

import shutil
import struct
import subprocess
import sys
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SVG = ROOT / "Scripts" / "app-icon.svg"
ICONSET = ROOT / "App" / "Stillroom" / "Assets.xcassets" / "AppIcon.appiconset"

# Pixel sizes for the macOS idiom. Contents.json maps these onto
# 16, 32, 128, 256, and 512 points at 1x and 2x.
SIZES = (16, 32, 64, 128, 256, 512, 1024)


def load_rgba(path: Path) -> tuple[int, int, list[bytearray]]:
    """Decode an 8-bit non-interlaced RGBA PNG. Returns width, height, rows."""
    data = path.read_bytes()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise SystemExit(f"{path} is not a PNG")
    pos = 8
    width = height = bit_depth = color_type = None
    idat: list[bytes] = []
    while pos + 8 <= len(data):
        length = struct.unpack(">I", data[pos : pos + 4])[0]
        kind = data[pos + 4 : pos + 8]
        chunk = data[pos + 8 : pos + 8 + length]
        pos += 12 + length
        if kind == b"IHDR":
            width, height, bit_depth, color_type = struct.unpack(">IIBB", chunk[:10])
        elif kind == b"IDAT":
            idat.append(chunk)
        elif kind == b"IEND":
            break
    if width is None or bit_depth != 8 or color_type != 6:
        raise SystemExit(f"{path} must be 8-bit RGBA (got depth {bit_depth}, type {color_type})")
    raw = zlib.decompress(b"".join(idat))
    stride = width * 4
    rows: list[bytearray] = []
    index = 0
    prev = bytearray(stride)
    for _ in range(height):
        filt = raw[index]
        index += 1
        row = bytearray(raw[index : index + stride])
        index += stride
        if filt == 1 or filt == 3 or filt == 4:
            for x in range(stride):
                left = row[x - 4] if x >= 4 else 0
                up = prev[x]
                if filt == 1:
                    pred = left
                elif filt == 3:
                    pred = (left + up) // 2
                else:
                    up_left = prev[x - 4] if x >= 4 else 0
                    p = left + up - up_left
                    pa, pb, pc = abs(p - left), abs(p - up), abs(p - up_left)
                    pred = left if pa <= pb and pa <= pc else up if pb <= pc else up_left
                row[x] = (row[x] + pred) & 255
        elif filt == 2:
            for x in range(stride):
                row[x] = (row[x] + prev[x]) & 255
        elif filt != 0:
            raise SystemExit(f"{path} uses unsupported PNG filter {filt}")
        prev = row
        rows.append(row)
    return width, height, rows


def pixel(rows: list[bytearray], x: int, y: int) -> tuple[int, int, int, int]:
    i = x * 4
    row = rows[y]
    return row[i], row[i + 1], row[i + 2], row[i + 3]


def render(size: int, dest: Path, rsvg: str) -> None:
    dest.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(
        [rsvg, "--width", str(size), "--height", str(size), str(SVG), "--output", str(dest)],
        check=True,
    )
    width, height, _rows = load_rgba(dest)
    if (width, height) != (size, size):
        raise SystemExit(f"{dest} is {width}x{height}, expected {size}x{size}")


def check_grid(rows: list[bytearray]) -> None:
    """The 1024 plate is an 824px squircle: transparent margin, navy at the edge."""
    if pixel(rows, 0, 0)[3] != 0 or pixel(rows, 40, 512)[3] != 0:
        raise SystemExit("icon margin is not transparent")
    edge = pixel(rows, 100, 512)
    if edge[3] != 255 or edge[:3] != (0, 0, 31):
        raise SystemExit(f"plate edge at (100, 512) is {edge}, expected #00001F")
    if pixel(rows, 512, 100)[:3] != (0, 0, 31):
        raise SystemExit("plate edge at (512, 100) is not #00001F")
    if pixel(rows, 512, 512)[3] != 255:
        raise SystemExit("icon center is transparent")


def main() -> None:
    rsvg = shutil.which("rsvg-convert")
    if rsvg is None:
        raise SystemExit("rsvg-convert is not on PATH (install librsvg)")
    if not SVG.is_file():
        raise SystemExit(f"missing {SVG}")

    for size in SIZES:
        render(size, ICONSET / f"icon_{size}.png", rsvg)
    render(1024, ROOT / "docs" / "app-icon-1024.png", rsvg)
    render(128, ROOT / "docs" / "app-icon-128.png", rsvg)

    _w, _h, rows = load_rgba(ICONSET / "icon_1024.png")
    check_grid(rows)
    print(f"wrote {len(SIZES)} icon sizes and docs/app-icon-{{1024,128}}.png")


if __name__ == "__main__":
    try:
        main()
    except subprocess.CalledProcessError as exc:
        sys.exit(exc.returncode)
