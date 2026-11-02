#!/usr/bin/env python3
"""Regenerate the Stillroom macOS app icon.

The artwork lives in this script: an original chunky "S" on a deep-navy
rounded square, filled with a soft mesh of violet, white, light blue, and
hot pink. It is not a trace of the reference mark. Running it rewrites the
vector source and every AppIcon size.

  npm install @resvg/resvg-js
  python3 Scripts/render_app_icon.py

Outputs
  Scripts/stillroom-icon.svg
  App/Stillroom/Assets.xcassets/AppIcon.appiconset/icon_{16,32,64,128,256,512,1024}.png
  App/Stillroom/Assets.xcassets/AppIcon.appiconset/Contents.json
  docs/app-icon-1024.png
  docs/app-icon-128.png
"""

from __future__ import annotations

import argparse
import math
import os
import shutil
import subprocess
import sys
import tempfile
import zlib

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
SVG_PATH = os.path.join(ROOT, "Scripts", "stillroom-icon.svg")
ICONSET = os.path.join(
    ROOT, "App", "Stillroom", "Assets.xcassets", "AppIcon.appiconset"
)
DOCS = os.path.join(ROOT, "docs")

# macOS Big Sur+ icon grid: ~824px rounded rect centered on a 1024 canvas.
CANVAS = 1024
PLATE = 824
PLATE_ORIGIN = (CANVAS - PLATE) / 2  # 100
PLATE_RADIUS = 185
PLATE_COLOR = "#00001F"
SAFE_INSET = 138.0

# Stroke in design units. The fitter scales it with the skeleton.
STROKE = 292.0
BODY_WAVE = 0.0

SIZES = (16, 32, 64, 128, 256, 512, 1024)

CONTENTS_JSON = """\
{
  "images" : [
    { "filename" : "icon_16.png", "idiom" : "mac", "scale" : "1x", "size" : "16x16" },
    { "filename" : "icon_32.png", "idiom" : "mac", "scale" : "2x", "size" : "16x16" },
    { "filename" : "icon_32.png", "idiom" : "mac", "scale" : "1x", "size" : "32x32" },
    { "filename" : "icon_64.png", "idiom" : "mac", "scale" : "2x", "size" : "32x32" },
    { "filename" : "icon_128.png", "idiom" : "mac", "scale" : "1x", "size" : "128x128" },
    { "filename" : "icon_256.png", "idiom" : "mac", "scale" : "2x", "size" : "128x128" },
    { "filename" : "icon_256.png", "idiom" : "mac", "scale" : "1x", "size" : "256x256" },
    { "filename" : "icon_512.png", "idiom" : "mac", "scale" : "2x", "size" : "256x256" },
    { "filename" : "icon_512.png", "idiom" : "mac", "scale" : "1x", "size" : "512x512" },
    { "filename" : "icon_1024.png", "idiom" : "mac", "scale" : "2x", "size" : "512x512" }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
"""

NODE_RENDERER = r"""
const { Resvg } = require(process.argv[2]);
const fs = require("fs");
const svg = fs.readFileSync(process.argv[3]);
const width = Number(process.argv[5]);
const resvg = new Resvg(svg, {
  fitTo: { mode: "width", value: width },
  shapeRendering: 2,
});
fs.writeFileSync(process.argv[4], resvg.render().asPng());
"""


def arc_points(cx, cy, rx, ry, a0_deg, a1_deg, n):
    """Elliptical arc. Angles are mathematical degrees; y grows downward."""
    a0 = math.radians(a0_deg)
    a1 = math.radians(a1_deg)
    points = []
    for i in range(n + 1):
        a = a0 + (a1 - a0) * (i / n)
        points.append((cx + rx * math.cos(a), cy - ry * math.sin(a)))
    return points


def arc_travel(a_deg, rx, ry, increasing):
    a = math.radians(a_deg)
    dx, dy = -rx * math.sin(a), -ry * math.cos(a)
    if not increasing:
        dx, dy = -dx, -dy
    length = math.hypot(dx, dy) or 1.0
    return dx / length, dy / length


def _lerp(p, q, t):
    return (p[0] + (q[0] - p[0]) * t, p[1] + (q[1] - p[1]) * t)


def catmull_rom(points, samples=14):
    """Centripetal Catmull-Rom. Passes through every control point."""
    ext = [
        (2 * points[0][0] - points[1][0], 2 * points[0][1] - points[1][1]),
        *points,
        (2 * points[-1][0] - points[-2][0], 2 * points[-1][1] - points[-2][1]),
    ]

    def tj(ti, a, b):
        return ti + math.hypot(b[0] - a[0], b[1] - a[1]) ** 0.5

    out = []
    for i in range(1, len(ext) - 2):
        p0, p1, p2, p3 = ext[i - 1], ext[i], ext[i + 1], ext[i + 2]
        t0 = 0.0
        t1 = tj(t0, p0, p1)
        t2 = tj(t1, p1, p2)
        t3 = tj(t2, p2, p3)
        if t2 == t1:
            out.append(p1)
            continue
        for s in range(samples):
            t = t1 + (t2 - t1) * (s / samples)

            def seg(a, b, ta, tb):
                if tb == ta:
                    return a
                return _lerp(a, b, (t - ta) / (tb - ta))

            a1 = seg(p0, p1, t0, t1)
            a2 = seg(p1, p2, t1, t2)
            a3 = seg(p2, p3, t2, t3)
            b1 = seg(a1, a2, t0, t2)
            b2 = seg(a2, a3, t1, t3)
            out.append(seg(b1, b2, t1, t2))
    out.append(points[-1])
    return out


def build_spine():
    """A heavy roman S: long shelves, broad corners, open counters.

    The corner radius stays larger than half the stroke, so the inner edge
    doesn't cusp, and the shelves are what make it read as a letter.
    """
    radius = 208.0
    bar_y = 200.0
    corner_x = 460.0
    lead = catmull_rom(
        [
            (930, bar_y + 42),  # top tip, drooping
            (888, bar_y + 22),
            (830, bar_y + 2),
            (760, bar_y - 8),  # a small rise, so the end waves
            (corner_x, bar_y),
        ],
        samples=8,
    )
    top_arc = arc_points(corner_x, bar_y + radius, radius, radius, 90, 228, 40)
    leave = arc_travel(228, radius, radius, True)

    # Place the lower bowl so its entry tangent matches the upper bowl's exit.
    # The diagonal between them is straight, which keeps that join from cusping.
    end = top_arc[-1]
    join = 250.0
    start = (end[0] + leave[0] * join, end[1] + leave[1] * join)
    entry = math.degrees(math.atan2(leave[0], leave[1]))
    bottom_r = 236.0
    bcx = start[0] - bottom_r * math.cos(math.radians(entry))
    bcy = start[1] + bottom_r * math.sin(math.radians(entry))
    bottom_arc = arc_points(bcx, bcy, bottom_r, bottom_r, entry, -118, 46)
    depart = arc_travel(-118, bottom_r, bottom_r, False)
    bridge = [
        (
            end[0] + (start[0] - end[0]) * (i / 16),
            end[1] + (start[1] - end[1]) * (i / 16),
        )
        for i in range(1, 16)
    ]

    # Bottom shelf. Zero slope at both ends so it doesn't kink the bowl or the cap.
    tx, ty = depart
    nx, ny = -ty, tx
    origin = bottom_arc[-1]
    tail = []
    for i in range(1, 18):
        u = i / 17
        sway = 20.0 * (1.0 - math.cos(math.pi * u)) / 2.0
        tail.append(
            (
                origin[0] + tx * 200.0 * u + nx * sway,
                origin[1] + ty * 200.0 * u + ny * sway,
            )
        )

    spine = []
    for group in (lead, top_arc[1:], bridge[1:], bottom_arc[1:], tail):
        for point in group:
            if spine and math.hypot(point[0] - spine[-1][0], point[1] - spine[-1][1]) < 0.35:
                continue
            spine.append(point)
    return apply_body_wave(spine)


def min_turn_radius(points):
    worst = 1e9
    for i in range(1, len(points) - 1):
        ax, ay = points[i - 1]
        bx, by = points[i]
        cx, cy = points[i + 1]
        ab = math.hypot(bx - ax, by - ay)
        bc = math.hypot(cx - bx, cy - by)
        ac = math.hypot(cx - ax, cy - ay)
        cross = (bx - ax) * (cy - ay) - (by - ay) * (cx - ax)
        if ab < 1e-3 or bc < 1e-3 or abs(cross) < 1e-6:
            continue
        worst = min(worst, ab * bc * ac / (2 * abs(cross)))
    return worst


def frames_for(points):
    frames = []
    last = len(points) - 1
    for i in range(len(points)):
        i0 = max(0, i - 3)
        i1 = min(last, i + 3)
        dx = points[i1][0] - points[i0][0]
        dy = points[i1][1] - points[i0][1]
        length = math.hypot(dx, dy) or 1.0
        tx, ty = dx / length, dy / length
        frames.append((tx, ty, -ty, tx))
    return frames


def apply_body_wave(spine):
    frames = frames_for(spine)
    waved = []
    last = len(spine) - 1
    for i, (x, y) in enumerate(spine):
        t = i / last
        envelope = math.sin(math.pi * t) ** 0.9
        disp = BODY_WAVE * math.sin(2.0 * math.pi * t * 1.35) * envelope
        nx, ny = frames[i][2], frames[i][3]
        waved.append((x + nx * disp, y + ny * disp))
    return waved


def bounds(points):
    xs = [p[0] for p in points]
    ys = [p[1] for p in points]
    return min(xs), min(ys), max(xs), max(ys)


def clearance(spine):
    """Closest approach of non-neighboring samples, in spine units."""
    step = 4
    sampled = spine[::step]
    worst = 1e9
    skip = 18
    for i, p in enumerate(sampled):
        for q in sampled[i + skip :]:
            worst = min(worst, math.hypot(p[0] - q[0], p[1] - q[1]))
    return worst


def fit_spine(spine, stroke):
    """Scale spine and stroke together so the ink sits inside the plate margin."""
    minx, miny, maxx, maxy = bounds(spine)
    bleed = stroke * 0.58
    ink_w = (maxx - minx) + 2 * bleed
    ink_h = (maxy - miny) + 2 * bleed
    safe = PLATE - 2 * SAFE_INSET
    scale = min(safe / ink_w, safe / ink_h)
    cx = (minx + maxx) / 2.0
    cy = (miny + maxy) / 2.0
    target_x = PLATE_ORIGIN + PLATE / 2.0
    target_y = PLATE_ORIGIN + PLATE / 2.0 - 4.0
    fitted = [((x - cx) * scale + target_x, (y - cy) * scale + target_y) for x, y in spine]
    return fitted, stroke * scale, scale


def path_d(points):
    parts = [f"M {points[0][0]:.2f} {points[0][1]:.2f}"]
    for x, y in points[1:]:
        parts.append(f"L {x:.2f} {y:.2f}")
    return " ".join(parts)


def terminal_blobs(spine, stroke):
    """Round caps already finish the stroke. No extra lobes."""
    return []


def ink_box(spine, stroke):
    minx, miny, maxx, maxy = bounds(spine)
    bleed = stroke * 0.55
    return (minx - bleed, miny - bleed, maxx + bleed, maxy + bleed)


def blob_xml(blobs):
    parts = []
    for cx, cy, rx, ry, tx, ty in blobs:
        deg = math.degrees(math.atan2(ty, tx))
        parts.append(
            f'<ellipse cx="{cx:.2f}" cy="{cy:.2f}" rx="{rx:.2f}" ry="{ry:.2f}" '
            f'transform="rotate({deg:.2f} {cx:.2f} {cy:.2f})" fill="white"/>'
        )
    return "\n    ".join(parts)


def mesh_layers(box):
    minx, miny, maxx, maxy = box
    w = maxx - minx
    h = maxy - miny

    def at(px, py):
        return minx + w * px, miny + h * py

    blobs = [
        ("pink", *at(0.48, 0.90), max(w, h) * 0.58, "#FF66B3",
         [(0.0, 1.0), (0.32, 0.78), (0.68, 0.22), (1.0, 0.0)]),
        ("pinkRight", *at(0.82, 0.70), w * 0.42, "#FF66B3",
         [(0.0, 0.85), (0.45, 0.35), (1.0, 0.0)]),
        ("blue", *at(0.52, 0.48), max(w, h) * 0.36, "#C5DEFF",
         [(0.0, 0.95), (0.4, 0.5), (0.75, 0.12), (1.0, 0.0)]),
        ("blueLeft", *at(0.26, 0.42), w * 0.34, "#A9C8FF",
         [(0.0, 0.7), (0.55, 0.22), (1.0, 0.0)]),
        ("lavender", *at(0.50, 0.16), w * 0.48, "#E6D8FF",
         [(0.0, 0.8), (0.5, 0.28), (1.0, 0.0)]),
        ("violet", *at(0.20, 0.24), w * 0.50, "#6A2BF5",
         [(0.0, 1.0), (0.18, 0.9), (0.5, 0.4), (1.0, 0.0)]),
        ("white", *at(0.73, 0.18), w * 0.38, "#FFFFFF",
         [(0.0, 0.78), (0.28, 0.42), (0.62, 0.12), (1.0, 0.0)]),
        ("spec", *at(0.68, 0.16), w * 0.20, "#FFFFFF",
         [(0.0, 0.7), (0.35, 0.28), (1.0, 0.0)]),
    ]
    defs = []
    fills = []
    for name, cx, cy, radius, color, stops in blobs:
        stop_xml = "\n".join(
            f'      <stop offset="{offset * 100:.1f}%" stop-color="{color}" stop-opacity="{opacity:.3f}"/>'
            for offset, opacity in stops
        )
        defs.append(
            f"""    <radialGradient id="{name}" gradientUnits="userSpaceOnUse" cx="{cx:.1f}" cy="{cy:.1f}" r="{radius:.1f}">
{stop_xml}
    </radialGradient>"""
        )
        fills.append(f'    <rect x="0" y="0" width="{CANVAS}" height="{CANVAS}" fill="url(#{name})"/>')
    return "\n".join(defs), "\n".join(fills)


def build_svg(spine, stroke, guides=False, flat=False):
    box = ink_box(spine, stroke)
    gradient_defs, gradient_fills = mesh_layers(box)
    blobs = blob_xml(terminal_blobs(spine, stroke))
    if flat:
        paint = f'    <rect x="0" y="0" width="{CANVAS}" height="{CANVAS}" fill="#FF66B3"/>'
    else:
        paint = (
            f'    <rect x="0" y="0" width="{CANVAS}" height="{CANVAS}" fill="url(#base)"/>\n'
            + gradient_fills
        )
    guide = ""
    if guides:
        guide = (
            f'  <path d="{path_d(spine)}" fill="none" stroke="#00FFC8" '
            f'stroke-width="4" stroke-linecap="round"/>\n'
        )
    return f"""<?xml version="1.0" encoding="UTF-8"?>
<!-- Generated by Scripts/render_app_icon.py. Regenerate that script; do not hand-edit. -->
<svg xmlns="http://www.w3.org/2000/svg" width="{CANVAS}" height="{CANVAS}" viewBox="0 0 {CANVAS} {CANVAS}">
  <defs>
    <linearGradient id="base" gradientUnits="userSpaceOnUse" x1="{box[0]:.1f}" y1="{box[1]:.1f}" x2="{box[0]:.1f}" y2="{box[3]:.1f}">
      <stop offset="0%" stop-color="#7A62FF"/>
      <stop offset="26%" stop-color="#A9BFFF"/>
      <stop offset="50%" stop-color="#C5DEFF"/>
      <stop offset="72%" stop-color="#FF9DCE"/>
      <stop offset="100%" stop-color="#FF66B3"/>
    </linearGradient>
{gradient_defs}
    <filter id="plateShadow" x="-40%" y="-40%" width="180%" height="190%" color-interpolation-filters="sRGB">
      <feGaussianBlur in="SourceAlpha" stdDeviation="18" result="dropBlur"/>
      <feOffset in="dropBlur" dx="0" dy="16" result="dropOff"/>
      <feFlood flood-color="#000000" flood-opacity="0.30" result="dropFlood"/>
      <feComposite in="dropFlood" in2="dropOff" operator="in" result="drop"/>
      <feGaussianBlur in="SourceAlpha" stdDeviation="2.4" result="contactBlur"/>
      <feOffset in="contactBlur" dx="0" dy="1.6" result="contactOff"/>
      <feFlood flood-color="#000000" flood-opacity="0.36" result="contactFlood"/>
      <feComposite in="contactFlood" in2="contactOff" operator="in" result="contact"/>
      <feMerge>
        <feMergeNode in="drop"/>
        <feMergeNode in="contact"/>
        <feMergeNode in="SourceGraphic"/>
      </feMerge>
    </filter>
    <mask id="letter" maskUnits="userSpaceOnUse" x="0" y="0" width="{CANVAS}" height="{CANVAS}">
      <rect x="0" y="0" width="{CANVAS}" height="{CANVAS}" fill="black"/>
      <path d="{path_d(spine)}" fill="none" stroke="white" stroke-width="{stroke:.2f}" stroke-linecap="round" stroke-linejoin="round"/>
      {blobs}
    </mask>
  </defs>
  <rect x="{PLATE_ORIGIN:.1f}" y="{PLATE_ORIGIN:.1f}" width="{PLATE}" height="{PLATE}" rx="{PLATE_RADIUS}" ry="{PLATE_RADIUS}" fill="{PLATE_COLOR}" filter="url(#plateShadow)"/>
  <g mask="url(#letter)">
{paint}
  </g>
{guide}</svg>
"""


def find_resvg():
    candidates = [
        os.environ.get("RESVG_MODULE"),
        "/tmp/icon-tools/node_modules/@resvg/resvg-js",
        os.path.join(ROOT, "node_modules", "@resvg", "resvg-js"),
        os.path.join(os.path.dirname(__file__), "node_modules", "@resvg", "resvg-js"),
    ]
    for candidate in candidates:
        if candidate and os.path.isdir(candidate):
            return candidate
    sys.exit(
        "Cannot find @resvg/resvg-js. Install it with `npm install @resvg/resvg-js` "
        "or set RESVG_MODULE to the package directory."
    )


def render_png(svg_text, png_path, size, resvg_module):
    with tempfile.TemporaryDirectory() as tmp:
        svg_file = os.path.join(tmp, "icon.svg")
        js_file = os.path.join(tmp, "render.js")
        with open(svg_file, "w", encoding="utf-8") as fh:
            fh.write(svg_text)
        with open(js_file, "w", encoding="utf-8") as fh:
            fh.write(NODE_RENDERER)
        subprocess.run(
            ["node", js_file, resvg_module, svg_file, png_path, str(size)],
            check=True,
        )


def paeth(a, b, c):
    p = a + b - c
    pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
    if pa <= pb and pa <= pc:
        return a
    if pb <= pc:
        return b
    return c


def read_png_rgba(path):
    with open(path, "rb") as fh:
        data = fh.read()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise SystemExit(f"{path} is not a PNG")
    pos = 8
    width = height = color_type = None
    idat = []
    while pos + 8 <= len(data):
        length = int.from_bytes(data[pos : pos + 4], "big")
        ctype = data[pos + 4 : pos + 8]
        chunk = data[pos + 8 : pos + 8 + length]
        pos += 12 + length
        if ctype == b"IHDR":
            width = int.from_bytes(chunk[0:4], "big")
            height = int.from_bytes(chunk[4:8], "big")
            color_type = chunk[9]
        elif ctype == b"IDAT":
            idat.append(chunk)
        elif ctype == b"IEND":
            break
    if color_type != 6:
        raise SystemExit(f"{path} color type is {color_type}, expected RGBA (6)")
    raw = zlib.decompress(b"".join(idat))
    stride = width * 4
    rows = []
    i = 0
    prev = bytearray(stride)
    for _y in range(height):
        filt = raw[i]
        i += 1
        row = bytearray(raw[i : i + stride])
        i += stride
        if filt == 1:
            for x in range(stride):
                left = row[x - 4] if x >= 4 else 0
                row[x] = (row[x] + left) & 255
        elif filt == 2:
            for x in range(stride):
                row[x] = (row[x] + prev[x]) & 255
        elif filt == 3:
            for x in range(stride):
                left = row[x - 4] if x >= 4 else 0
                row[x] = (row[x] + ((left + prev[x]) // 2)) & 255
        elif filt == 4:
            for x in range(stride):
                a = row[x - 4] if x >= 4 else 0
                b = prev[x]
                c = prev[x - 4] if x >= 4 else 0
                row[x] = (row[x] + paeth(a, b, c)) & 255
        elif filt != 0:
            raise SystemExit(f"unsupported PNG filter {filt} in {path}")
        prev = row
        rows.append(row)
    return width, height, rows


def pixel(rows, x, y):
    i = x * 4
    row = rows[y]
    return row[i], row[i + 1], row[i + 2], row[i + 3]


def validate_png(path, size, letter_xy):
    width, height, rows = read_png_rgba(path)
    if (width, height) != (size, size):
        raise SystemExit(f"{path} is {width}x{height}, expected {size}x{size}")
    for corner in ((0, 0), (size - 1, 0), (0, size - 1), (size - 1, size - 1)):
        if pixel(rows, *corner)[3] != 0:
            raise SystemExit(f"{path} corner {corner} is not transparent")
    nx = int(round(size * (PLATE_ORIGIN + 58) / CANVAS))
    ny = int(round(size * (PLATE_ORIGIN + 64) / CANVAS))
    r, g, b, a = pixel(rows, nx, ny)
    if a < 250 or max(r, g, b) > 45 or b < r + 6:
        raise SystemExit(f"{path} plate sample {(nx, ny)} is {(r, g, b, a)}, expected navy")
    sx = min(size - 1, max(0, int(round(letter_xy[0] / CANVAS * size))))
    sy = min(size - 1, max(0, int(round(letter_xy[1] / CANVAS * size))))
    r, g, b, a = pixel(rows, sx, sy)
    if a < 250 or max(r, g, b) < 140:
        raise SystemExit(f"{path} letter sample {(sx, sy)} is {(r, g, b, a)}")
    return rows


def compose_artwork(flat=False, guides=False):
    raw = build_spine()
    gap = clearance(raw)
    turn = min_turn_radius(raw)
    print(
        f"design clearance {gap:.1f}px  turn radius {turn:.1f}px  "
        f"stroke {STROKE:.1f}px (half {STROKE / 2:.1f})"
    )
    if gap < STROKE * 1.04:
        print("warning: stroke may close the counters")
    if turn < STROKE * 0.55:
        print("warning: a bend is tighter than the stroke; the inner edge may cusp")
    spine, stroke, scale = fit_spine(raw, STROKE)
    box = ink_box(spine, stroke)
    print(
        f"ink box {box[0]:.0f},{box[1]:.0f} {box[2] - box[0]:.0f}x{box[3] - box[1]:.0f}  "
        f"plate padding L{box[0] - PLATE_ORIGIN:.0f} T{box[1] - PLATE_ORIGIN:.0f} "
        f"R{PLATE_ORIGIN + PLATE - box[2]:.0f} B{PLATE_ORIGIN + PLATE - box[3]:.0f}  "
        f"scale {scale:.3f}  stroke {stroke:.1f}px"
    )
    # A point on the upper bowl, which is inside the stroke.
    letter_xy = min(spine, key=lambda p: p[1])
    svg = build_svg(spine, stroke, guides=guides, flat=flat)
    return svg, letter_xy


def main():
    parser = argparse.ArgumentParser(description="Render the Stillroom app icon set.")
    parser.add_argument("--preview", action="store_true", help="Write /tmp previews only")
    parser.add_argument("--flat", action="store_true", help="Flat pink S, for judging the outline")
    parser.add_argument("--guides", action="store_true", help="Draw the centerline")
    args = parser.parse_args()

    svg, letter_xy = compose_artwork(flat=args.flat, guides=args.guides)
    resvg_module = find_resvg()

    if args.preview or args.flat or args.guides:
        for size, name in ((1024, "preview"), (128, "128"), (32, "32")):
            out = f"/tmp/stillroom-icon-{name}.png"
            render_png(svg, out, size, resvg_module)
            validate_png(out, size, letter_xy)
            print(f"preview {out}")
        return

    os.makedirs(ICONSET, exist_ok=True)
    os.makedirs(DOCS, exist_ok=True)
    with open(SVG_PATH, "w", encoding="utf-8") as fh:
        fh.write(svg)
    with open(os.path.join(ICONSET, "Contents.json"), "w", encoding="utf-8") as fh:
        fh.write(CONTENTS_JSON)

    for size in SIZES:
        destination = os.path.join(ICONSET, f"icon_{size}.png")
        render_png(svg, destination, size, resvg_module)
        validate_png(destination, size, letter_xy)
        print(f"wrote {destination}")

    shutil.copyfile(os.path.join(ICONSET, "icon_1024.png"), os.path.join(DOCS, "app-icon-1024.png"))
    shutil.copyfile(os.path.join(ICONSET, "icon_128.png"), os.path.join(DOCS, "app-icon-128.png"))
    print("wrote docs/app-icon-1024.png and docs/app-icon-128.png")


if __name__ == "__main__":
    main()
