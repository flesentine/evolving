#!/usr/bin/env python3
"""Builds the shared 2048x2048 building atlas.

Sixteen 512x512 islands, laid out 4x4:

    thatch   daub     stone    oak
    door     brick    slate    tile
    plaster  glass    concrete metal
    dark     marble   planks   turf

Everything is generated procedurally and deterministically so the asset
pipeline is reproducible without external textures.
"""

import math
import os
import random
import struct
import zlib

SIZE = 2048
CELL = SIZE // 4
PAD = 14

random.seed(0xB0A7D1)


def blank():
    return bytearray(SIZE * SIZE * 3)


def set_px(buf, x, y, r, g, b):
    if 0 <= x < SIZE and 0 <= y < SIZE:
        i = (y * SIZE + x) * 3
        buf[i] = max(0, min(255, int(r * 255)))
        buf[i + 1] = max(0, min(255, int(g * 255)))
        buf[i + 2] = max(0, min(255, int(b * 255)))


def get_px(buf, x, y):
    if not (0 <= x < SIZE and 0 <= y < SIZE):
        return 0.0, 0.0, 0.0
    i = (y * SIZE + x) * 3
    return buf[i] / 255.0, buf[i + 1] / 255.0, buf[i + 2] / 255.0


def fill(buf, x0, y0, x1, y1, rgb):
    for y in range(max(y0, 0), min(y1, SIZE)):
        for x in range(max(x0, 0), min(x1, SIZE)):
            set_px(buf, x, y, *rgb)


def vnoise(x, y, seed):
    x = int(x)
    y = int(y)
    n = x * 374761393 + y * 668265263 + seed * 2147483647
    n &= 0xFFFFFFFFFFFFFFFF
    n = (n ^ (n >> 13)) * 1274126177
    n &= 0xFFFFFFFFFFFFFFFF
    n = n ^ (n >> 16)
    return (n & 0xFFFF) / 65535.0


def fbm(x, y, seed, octaves=4):
    total = 0.0
    amp = 0.5
    freq = 1.0
    for _ in range(octaves):
        total += vnoise(x * freq, y * freq, seed) * amp
        amp *= 0.5
        freq *= 2.0
    return total


# ---------------------------------------------------------------------------
# Materials
# ---------------------------------------------------------------------------

def mat_thatch(buf, x, y, w, h):
    fill(buf, x, y, x + w, y + h, (0.520, 0.485, 0.400))
    for _ in range(w * 7):
        sx = x + random.randrange(w)
        sy = y + random.randrange(h)
        length = random.randint(6, 30)
        tint = 0.76 + random.random() * 0.52
        wobble = random.uniform(-0.35, 0.35)
        for t in range(length):
            xx = int(sx + wobble * t)
            yy = sy + t
            if yy >= y + h:
                break
            r, g, b = get_px(buf, xx, yy)
            set_px(buf, xx, yy, r * tint, g * tint * 0.99, b * tint * 0.96)
    for course in range(y + 40, y + h, 70):
        for xx in range(x, x + w):
            n = 0.86 + 0.10 * vnoise(xx // 3, course, 7)
            for d in range(3):
                r, g, b = get_px(buf, xx, course + d)
                set_px(buf, xx, course + d, r * n, g * n, b * n)
            if course + 4 < y + h:
                r, g, b = get_px(buf, xx, course + 4)
                set_px(buf, xx, course + 4, r * 1.10, g * 1.08, b * 1.02)
    for _ in range(80):
        cx = x + random.randrange(w)
        cy = y + random.randrange(h)
        rad = random.randint(8, 32)
        tint = 0.88 + random.random() * 0.18
        for yy in range(cy - rad, cy + rad):
            for xx in range(cx - rad, cx + rad):
                if (xx - cx) ** 2 + (yy - cy) ** 2 < rad * rad:
                    r, g, b = get_px(buf, xx, yy)
                    set_px(buf, xx, yy, r * tint, g * tint, b * tint)


def mat_daub(buf, x, y, w, h):
    fill(buf, x, y, x + w, y + h, (0.700, 0.650, 0.525))
    for yy in range(y, y + h, 2):
        for xx in range(x, x + w, 2):
            n = fbm(xx, yy, 11, 4)
            f = 0.88 + n * 0.18
            r, g, b = get_px(buf, xx, yy)
            for dy in range(2):
                for dx in range(2):
                    if xx + dx < x + w and yy + dy < y + h:
                        set_px(buf, xx + dx, yy + dy, r * f, g * f, b * f)
    for _ in range(1600):
        xx = x + random.randrange(w)
        yy = y + random.randrange(h)
        if random.random() < 0.62:
            c = random.choice([(0.86, 0.80, 0.62), (0.64, 0.58, 0.44)])
            set_px(buf, xx, yy, *[v * (0.95 + random.random() * 0.10) for v in c])
        else:
            set_px(buf, xx, yy, 0.46, 0.42, 0.36)
    for _ in range(22):
        xx = x + random.randrange(w)
        yy = y + random.randrange(h)
        for _ in range(random.randint(10, 40)):
            set_px(buf, xx, yy, 0.50, 0.46, 0.39)
            xx += random.choice([-1, 0, 1])
            yy += 1


def mat_plaster(buf, x, y, w, h):
    fill(buf, x, y, x + w, y + h, (0.815, 0.780, 0.690))
    for yy in range(y, y + h, 3):
        for xx in range(x, x + w, 3):
            n = fbm(xx, yy, 23, 3)
            f = 0.94 + n * 0.09
            for dy in range(3):
                for dx in range(3):
                    if xx + dx < x + w and yy + dy < y + h:
                        r, g, b = get_px(buf, xx + dx, yy + dy)
                        set_px(buf, xx + dx, yy + dy, r * f, g * f, b * f)
    for _ in range(260):
        xx = x + random.randrange(w)
        yy = y + random.randrange(h)
        c = random.choice([(0.70, 0.66, 0.56), (0.88, 0.86, 0.78)])
        set_px(buf, xx, yy, *c)


def mat_stone(buf, x, y, w, h):
    fill(buf, x, y, x + w, y + h, (0.320, 0.312, 0.295))
    yy = y
    while yy < y + h:
        rh = random.randint(28, 50)
        xx = x - random.randint(0, 30)
        while xx < x + w:
            rw = random.randint(32, 70)
            inset = 3
            tint = 0.78 + random.random() * 0.38
            for b in range(yy + inset, min(yy + rh - inset, y + h)):
                for a in range(max(xx + inset, x), min(xx + rw - inset, x + w)):
                    n = 0.94 + 0.10 * vnoise(a // 2, b // 2, 3)
                    f = tint * n
                    set_px(buf, a, b, 0.47 * f, 0.452 * f, 0.415 * f)
            for a in range(max(xx + inset, x), min(xx + rw - inset, x + w)):
                if yy + inset < y + h:
                    r, g, b = get_px(buf, a, yy + inset)
                    set_px(buf, a, yy + inset, r * 1.16, g * 1.14, b * 1.10)
                if yy + rh - inset - 1 < y + h:
                    r, g, b = get_px(buf, a, yy + rh - inset - 1)
                    set_px(buf, a, yy + rh - inset - 1, r * 0.78, g * 0.78, b * 0.78)
            xx += rw
        yy += rh


def mat_brick(buf, x, y, w, h):
    fill(buf, x, y, x + w, y + h, (0.330, 0.300, 0.270))
    course_h = 26
    brick_w = 54
    row = 0
    for yy in range(y, y + h, course_h):
        offset = (brick_w // 2) if row % 2 else 0
        for xx in range(x - brick_w + offset, x + w, brick_w):
            tint = 0.78 + random.random() * 0.40
            for b in range(yy + 2, min(yy + course_h - 2, y + h)):
                for a in range(max(xx + 2, x), min(xx + brick_w - 2, x + w)):
                    n = 0.93 + 0.12 * vnoise(a // 2, b // 3, 5)
                    f = tint * n
                    set_px(buf, a, b, 0.565 * f, 0.390 * f, 0.330 * f)
            for b in range(yy + 2, min(yy + course_h - 2, y + h)):
                if xx + 2 >= x and xx + 2 < x + w:
                    r, g, bl = get_px(buf, xx + 2, b)
                    set_px(buf, xx + 2, b, r * 1.14, g * 1.10, bl * 1.06)
                if xx + brick_w - 3 >= x and xx + brick_w - 3 < x + w:
                    r, g, bl = get_px(buf, xx + brick_w - 3, b)
                    set_px(buf, xx + brick_w - 3, b, r * 0.82, g * 0.82, bl * 0.82)
        row += 1


def mat_slate(buf, x, y, w, h):
    fill(buf, x, y, x + w, y + h, (0.190, 0.200, 0.215))
    tile_w = 52
    tile_h = 34
    row = 0
    for yy in range(y, y + h, tile_h):
        offset = (tile_w // 2) if row % 2 else 0
        for xx in range(x - tile_w + offset, x + w, tile_w):
            tint = 0.78 + random.random() * 0.45
            for b in range(yy, min(yy + tile_h, y + h)):
                for a in range(max(xx, x), min(xx + tile_w - 1, x + w)):
                    n = 0.92 + 0.12 * vnoise(a, b, 9)
                    f = tint * n
                    set_px(buf, a, b, 0.310 * f, 0.325 * f, 0.350 * f)
            for b in range(yy + tile_h - 5, min(yy + tile_h, y + h)):
                for a in range(max(xx, x), min(xx + tile_w - 1, x + w)):
                    r, g, bl = get_px(buf, a, b)
                    set_px(buf, a, b, r * 0.72, g * 0.72, bl * 0.75)
        row += 1


def mat_tile(buf, x, y, w, h):
    fill(buf, x, y, x + w, y + h, (0.440, 0.255, 0.185))
    tile_w = 48
    tile_h = 36
    row = 0
    for yy in range(y, y + h, tile_h):
        offset = (tile_w // 2) if row % 2 else 0
        for xx in range(x - tile_w + offset, x + w, tile_w):
            tint = 0.82 + random.random() * 0.38
            for b in range(yy, min(yy + tile_h, y + h)):
                for a in range(max(xx, x), min(xx + tile_w - 1, x + w)):
                    n = 0.93 + 0.10 * vnoise(a // 2, b // 2, 13)
                    f = tint * n
                    curve = 1.0 - 0.10 * abs(math.sin((a - xx) / tile_w * math.pi))
                    set_px(buf, a, b, 0.500 * f * curve, 0.300 * f * curve, 0.220 * f * curve)
            for b in range(yy + tile_h - 5, min(yy + tile_h, y + h)):
                for a in range(max(xx, x), min(xx + tile_w - 1, x + w)):
                    r, g, bl = get_px(buf, a, b)
                    set_px(buf, a, b, r * 0.74, g * 0.72, bl * 0.70)
        row += 1


def mat_oak(buf, x, y, w, h):
    fill(buf, x, y, x + w, y + h, (0.300, 0.215, 0.135))
    for _ in range(w * 3):
        xx = x + random.randrange(w)
        yy = y + random.randrange(h)
        length = random.randint(20, 90)
        tint = 0.80 + random.random() * 0.38
        for t in range(length):
            a = xx + int(math.sin(t * 0.08) * 2)
            b = yy + t
            if b >= y + h:
                break
            r, g, bl = get_px(buf, a, b)
            set_px(buf, a, b, r * tint, g * tint, bl * tint)
    for _ in range(6):
        cx = x + random.randrange(w)
        cy = y + random.randrange(h)
        for rad in range(4, 12):
            for ang in range(0, 360, 12):
                a = int(cx + math.cos(math.radians(ang)) * rad)
                b = int(cy + math.sin(math.radians(ang)) * rad * 0.7)
                r, g, bl = get_px(buf, a, b)
                set_px(buf, a, b, r * 0.82, g * 0.80, bl * 0.78)


def mat_door(buf, x, y, w, h):
    fill(buf, x, y, x + w, y + h, (0.255, 0.170, 0.110))
    plank = 58
    for px in range(x, x + w, plank):
        for a in range(px, min(px + plank, x + w)):
            n = 0.92 + 0.10 * vnoise(a // 2, 0, 5)
            edge = 0.80 if a in (px, px + plank - 1) else 1.0
            for b in range(y, y + h):
                r, g, bl = get_px(buf, a, b)
                set_px(buf, a, b, r * n * edge, g * n * edge, bl * n * edge)
    for sy in (y + h // 3, y + 2 * h // 3):
        for a in range(x, x + w):
            r, g, bl = get_px(buf, a, sy)
            set_px(buf, a, sy, r * 0.55, g * 0.55, bl * 0.58)
        for a in range(x + 20, x + w, 70):
            for bb in range(sy - 3, sy + 4):
                for aa in range(a - 3, a + 4):
                    set_px(buf, aa, bb, 0.20, 0.20, 0.22)


def mat_glass(buf, x, y, w, h):
    for b in range(y, y + h):
        t = (b - y) / max(h - 1, 1)
        for a in range(x, x + w):
            n = fbm(a, b, 41, 3)
            base = (0.205, 0.255, 0.315)
            sky = (0.530, 0.630, 0.730)
            f = 0.55 + 0.45 * t + 0.10 * (n - 0.5)
            set_px(buf, a, b,
                   base[0] * (1 - f) + sky[0] * f,
                   base[1] * (1 - f) + sky[1] * f,
                   base[2] * (1 - f) + sky[2] * f)
    # Mullions.
    for a in range(x, x + w, 96):
        for b in range(y, y + h):
            r, g, bl = get_px(buf, a, b)
            set_px(buf, a, b, r * 0.45, g * 0.45, bl * 0.45)
    for b in range(y, y + h, 128):
        for a in range(x, x + w):
            r, g, bl = get_px(buf, a, b)
            set_px(buf, a, b, r * 0.45, g * 0.45, bl * 0.45)


def mat_concrete(buf, x, y, w, h):
    fill(buf, x, y, x + w, y + h, (0.560, 0.545, 0.520))
    for b in range(y, y + h, 2):
        for a in range(x, x + w, 2):
            n = fbm(a, b, 53, 4)
            f = 0.88 + n * 0.20
            r, g, bl = get_px(buf, a, b)
            for dy in range(2):
                for dx in range(2):
                    if a + dx < x + w and b + dy < y + h:
                        set_px(buf, a + dx, b + dy, r * f, g * f, bl * f)
    for _ in range(120):
        a = x + random.randrange(w)
        b = y + random.randrange(h)
        set_px(buf, a, b, 0.40, 0.39, 0.37)


def mat_metal(buf, x, y, w, h):
    fill(buf, x, y, x + w, y + h, (0.460, 0.475, 0.490))
    for b in range(y, y + h):
        f = 0.92 + 0.14 * vnoise(0, b // 2, 61)
        for a in range(x, x + w):
            r, g, bl = get_px(buf, a, b)
            set_px(buf, a, b, r * f, g * f, bl * f)
    for a in range(x, x + w, 64):
        for b in range(y, y + h):
            r, g, bl = get_px(buf, a, b)
            set_px(buf, a, b, r * 0.80, g * 0.80, bl * 0.82)


def mat_dark(buf, x, y, w, h):
    for b in range(y, y + h):
        t = (b - y) / max(h - 1, 1)
        f = 0.015 + 0.035 * t
        for a in range(x, x + w):
            set_px(buf, a, b, f * 0.9, f * 0.85, f * 0.8)


def mat_marble(buf, x, y, w, h):
    fill(buf, x, y, x + w, y + h, (0.820, 0.800, 0.760))
    for _ in range(40):
        a = x + random.randrange(w)
        b = y + random.randrange(h)
        length = random.randint(40, 220)
        ang = random.uniform(-0.9, 0.9)
        tint = 0.70 + random.random() * 0.18
        for t in range(length):
            aa = int(a + math.cos(ang) * t)
            bb = int(b + math.sin(ang) * t)
            r, g, bl = get_px(buf, aa, bb)
            set_px(buf, aa, bb, r * tint, g * tint, bl * tint * 1.02)
    for b in range(y, y + h, 2):
        for a in range(x, x + w, 2):
            n = fbm(a, b, 71, 3)
            f = 0.94 + n * 0.08
            r, g, bl = get_px(buf, a, b)
            set_px(buf, a, b, r * f, g * f, bl * f)


def mat_planks(buf, x, y, w, h):
    fill(buf, x, y, x + w, y + h, (0.380, 0.300, 0.210))
    plank = 64
    for px in range(x, x + w, plank):
        tint = 0.85 + random.random() * 0.30
        for a in range(px, min(px + plank, x + w)):
            edge = 0.78 if a in (px, px + plank - 1) else 1.0
            for b in range(y, y + h):
                n = 0.92 + 0.10 * vnoise(a // 3, b // 3, 83)
                r, g, bl = get_px(buf, a, b)
                set_px(buf, a, b, r * tint * edge * n, g * tint * edge * n, bl * tint * edge * n)


def mat_turf(buf, x, y, w, h):
    fill(buf, x, y, x + w, y + h, (0.260, 0.360, 0.180))
    for _ in range(w * 8):
        a = x + random.randrange(w)
        b = y + random.randrange(h)
        tint = 0.75 + random.random() * 0.50
        set_px(buf, a, b, 0.30 * tint, 0.40 * tint, 0.20 * tint)


MATERIALS = [
    ("thatch", mat_thatch),
    ("daub", mat_daub),
    ("stone", mat_stone),
    ("oak", mat_oak),
    ("door", mat_door),
    ("brick", mat_brick),
    ("slate", mat_slate),
    ("tile", mat_tile),
    ("plaster", mat_plaster),
    ("glass", mat_glass),
    ("concrete", mat_concrete),
    ("metal", mat_metal),
    ("dark", mat_dark),
    ("marble", mat_marble),
    ("planks", mat_planks),
    ("turf", mat_turf),
]


def write_png(path, buf, size=SIZE):
    raw = bytearray()
    for y in range(size):
        raw.append(0)
        start = y * size * 3
        raw.extend(buf[start:start + size * 3])

    def chunk(tag, data):
        return (struct.pack(">I", len(data)) + tag + data +
                struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF))

    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 2, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(bytes(raw), 9))
    png += chunk(b"IEND", b"")
    with open(path, "wb") as f:
        f.write(png)


ROUGHNESS = [0.90, 0.92, 0.86, 0.80, 0.78, 0.90, 0.70, 0.80,
             0.95, 0.15, 0.90, 0.35, 0.90, 0.40, 0.85, 1.00]


def roughness_map(size=1024):
    step = SIZE // size
    out = bytearray(size * size * 3)
    for y in range(size):
        cell_row = (y * step) // CELL
        for x in range(size):
            cell_col = (x * step) // CELL
            v = ROUGHNESS[cell_row * 4 + cell_col]
            n = (vnoise(x // 3, y // 3, 17) - 0.5) * 0.05
            g = int(max(0, min(1, v + n)) * 255)
            i = (y * size + x) * 3
            out[i] = g
            out[i + 1] = g
            out[i + 2] = g
    return out


# Per-island bump gain: masonry and shingles want strong relief, paint and
# glass none at all.
ISLAND_BUMP = [1.5, 0.9, 2.6, 1.2, 0.7, 3.0, 3.0, 3.0,
               0.0, 0.0, 0.0, 0.0, 0.0, 0.4, 1.2, 0.6]


def normal_map(src, size=1024):
    """Blurred luminance -> per-material Sobel normal pass."""
    step = SIZE // size
    lum = [[0.0] * size for _ in range(size)]
    for y in range(size):
        sy = y * step
        for x in range(size):
            sx = x * step
            r, g, b = get_px(src, sx, sy)
            lum[y][x] = 0.299 * r + 0.587 * g + 0.114 * b

    # 3x3 box blur removes per-pixel noise before differentiating.
    blur = [[0.0] * size for _ in range(size)]
    for y in range(size):
        up = lum[(y - 1) % size]
        row = lum[y]
        dn = lum[(y + 1) % size]
        for x in range(size):
            xl = (x - 1) % size
            xr = (x + 1) % size
            blur[y][x] = (up[xl] + up[x] + up[xr] +
                          row[xl] + row[x] + row[xr] +
                          dn[xl] + dn[x] + dn[xr]) / 9.0

    out = bytearray(size * size * 3)
    cells = SIZE // CELL
    for y in range(size):
        cell_row = min((y * step) // CELL, 3)
        row = blur[y]
        up = blur[(y - 1) % size]
        dn = blur[(y + 1) % size]
        for x in range(size):
            cell_col = min((x * step) // CELL, 3)
            gain = ISLAND_BUMP[cell_row * 4 + cell_col]
            if gain <= 0.001:
                i = (y * size + x) * 3
                out[i] = 128
                out[i + 1] = 128
                out[i + 2] = 255
                continue
            xl = (x - 1) % size
            xr = (x + 1) % size
            dx = (row[xr] - row[xl]) * gain
            dy = (dn[x] - up[x]) * gain
            nx, ny, nz = -dx, -dy, 1.0
            inv = 1.0 / math.sqrt(nx * nx + ny * ny + nz * nz)
            i = (y * size + x) * 3
            out[i] = int((nx * inv * 0.5 + 0.5) * 255)
            out[i + 1] = int((ny * inv * 0.5 + 0.5) * 255)
            out[i + 2] = int((nz * inv * 0.5 + 0.5) * 255)
    return out


def main():
    here = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    out = os.path.join(here, "Assets", "Buildings", "buildings-atlas.png")
    os.makedirs(os.path.dirname(out), exist_ok=True)

    buf = blank()
    for index, (name, fn) in enumerate(MATERIALS):
        col = index % 4
        row = index // 4
        fn(buf, col * CELL, row * CELL, CELL, CELL)

    write_png(out, buf)
    normal = normal_map(buf)
    write_png(os.path.join(os.path.dirname(out), "buildings-normal.png"), normal, 1024)
    rough = roughness_map()
    write_png(os.path.join(os.path.dirname(out), "buildings-roughness.png"), rough, 1024)
    print("wrote", out, "and normals, with", len(MATERIALS), "islands")


if __name__ == "__main__":
    main()
