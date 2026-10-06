#!/usr/bin/env python3
import math
import os
import struct
import zlib

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "Resources", "Assets.xcassets", "AppIcon.appiconset")
os.makedirs(OUT, exist_ok=True)

def png_bytes(w, h, rgba):
    raw = bytearray()
    stride = w * 4
    for y in range(h):
        raw.append(0)
        raw.extend(rgba[y * stride:(y + 1) * stride])
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xffffffff)
    return (
        b"\x89PNG\r\n\x1a\n" +
        chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0)) +
        chunk(b"IDAT", zlib.compress(bytes(raw), 9)) +
        chunk(b"IEND", b"")
    )

def draw_icon(size):
    px = bytearray(size * size * 4)

    def put(x, y, color, alpha=1.0):
        if not (0 <= x < size and 0 <= y < size):
            return
        i = (y * size + x) * 4
        a = max(0.0, min(1.0, alpha))
        olda = px[i + 3] / 255.0
        outa = a + olda * (1.0 - a)
        if outa <= 0:
            return
        for k in range(3):
            old = px[i + k] / 255.0
            new = color[k] / 255.0
            px[i + k] = int(255 * ((new * a + old * olda * (1.0 - a)) / outa))
        px[i + 3] = int(255 * outa)

    # Dark AthleteOS background with subtle center lift.
    for y in range(size):
        for x in range(size):
            nx = (x - size * 0.5) / size
            ny = (y - size * 0.46) / size
            r = math.sqrt(nx * nx + ny * ny)
            lift = max(0.0, 1.0 - r * 1.8)
            base = (
                int(8 + 12 * lift),
                int(15 + 18 * lift),
                int(24 + 26 * lift)
            )
            i = (y * size + x) * 4
            px[i:i+4] = bytes((*base, 255))

    def line(x0, y0, x1, y1, width, color):
        minx = max(0, int(min(x0, x1) - width - 2))
        maxx = min(size - 1, int(max(x0, x1) + width + 2))
        miny = max(0, int(min(y0, y1) - width - 2))
        maxy = min(size - 1, int(max(y0, y1) + width + 2))
        vx, vy = x1 - x0, y1 - y0
        denom = vx * vx + vy * vy or 1.0
        for yy in range(miny, maxy + 1):
            for xx in range(minx, maxx + 1):
                t = ((xx - x0) * vx + (yy - y0) * vy) / denom
                t = max(0.0, min(1.0, t))
                qx, qy = x0 + t * vx, y0 + t * vy
                d = math.hypot(xx - qx, yy - qy)
                if d <= width:
                    put(xx, yy, color, min(1.0, width + 0.8 - d))

    # Angular A / mountain mark.
    steel = (205, 220, 245)
    blue = (80, 128, 255)
    mint = (79, 240, 174)
    w = size * 0.045
    line(size * 0.24, size * 0.67, size * 0.50, size * 0.24, w, steel)
    line(size * 0.50, size * 0.24, size * 0.75, size * 0.67, w, steel)
    line(size * 0.34, size * 0.54, size * 0.66, size * 0.54, w * 0.8, blue)

    # ECG waveform across lower third.
    pts = [
        (0.16, 0.72), (0.31, 0.72), (0.37, 0.66), (0.42, 0.80),
        (0.49, 0.52), (0.56, 0.78), (0.62, 0.69), (0.68, 0.72), (0.84, 0.72)
    ]
    for (a, b) in zip(pts, pts[1:]):
        line(size * a[0], size * a[1], size * b[0], size * b[1], w * 0.52, mint)

    return px

for name, size in [
    ("icon-40.png", 40),
    ("icon-60.png", 60),
    ("icon-58.png", 58),
    ("icon-87.png", 87),
    ("icon-80.png", 80),
    ("icon-120-spot.png", 120),
    ("icon-120.png", 120),
    ("icon-180.png", 180),
    ("icon-1024.png", 1024),
]:
    data = draw_icon(size)
    with open(os.path.join(OUT, name), "wb") as f:
        f.write(png_bytes(size, size, data))
