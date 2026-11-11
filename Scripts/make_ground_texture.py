#!/usr/bin/env python3
"""Builds a seamless ground detail texture and its normal map.

Neutral luminance detail (0.85–1.15) multiplied into the terrain's vertex
colours, so grass, dirt and rock keep their palette but gain surface grain.
"""

import math
import os
import struct
import zlib

SIZE = 1024
FINE = 512
OUT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                   "Assets", "Terrain")


def pnoise(u, v, period, seed):
    """Periodic value noise on a `period` x `period` lattice."""
    x = u * period
    y = v * period
    x0 = math.floor(x)
    y0 = math.floor(y)
    fx = x - x0
    fy = y - y0
    fx = fx * fx * (3 - 2 * fx)
    fy = fy * fy * (3 - 2 * fy)

    def h(ix, iy):
        n = (ix % period) * 374761393 + (iy % period) * 668265263 + seed * 1442695041
        n &= 0xFFFFFFFFFFFFFFFF
        n = (n ^ (n >> 13)) * 1274126177
        n &= 0xFFFFFFFFFFFFFFFF
        n = n ^ (n >> 16)
        return (n & 0xFFFF) / 65535.0

    a = h(x0, y0)
    b = h(x0 + 1, y0)
    c = h(x0, y0 + 1)
    d = h(x0 + 1, y0 + 1)
    top = a + (b - a) * fx
    bottom = c + (d - c) * fx
    return top + (bottom - top) * fy


def height_at(u, v):
    # A few low-octave waves give soft clumps; noise adds fine grain.
    h = 0.5
    h += 0.13 * math.sin(2 * math.pi * (3 * u + 1 * v))
    h += 0.09 * math.sin(2 * math.pi * (7 * u - 4 * v))
    h += 0.05 * math.sin(2 * math.pi * (13 * u + 9 * v))
    h += 0.18 * (pnoise(u, v, 18, 5) - 0.5)
    h += 0.10 * (pnoise(u, v, 46, 11) - 0.5)
    h += 0.06 * (pnoise(u, v, 96, 23) - 0.5)
    return h


def rock_height_at(u, v):
    h = 0.5
    h += 0.22 * (pnoise(u, v, 9, 31) - 0.5)
    h += 0.14 * (pnoise(u, v, 27, 37) - 0.5)
    h += 0.08 * (pnoise(u, v, 61, 43) - 0.5)
    h += 0.10 * abs(math.sin(2 * math.pi * (6 * u + 2 * v)))
    h += 0.06 * abs(math.sin(2 * math.pi * (13 * u - 5 * v)))
    return h


def write_png(path, buf, size=None):
    size = size or SIZE
    raw = bytearray()
    for y in range(size):
        raw.append(0)
        raw.extend(buf[y * size * 3:(y + 1) * size * 3])

    def chunk(tag, data):
        return (struct.pack(">I", len(data)) + tag + data +
                struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF))

    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 2, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(bytes(raw), 9))
    png += chunk(b"IEND", b"")
    with open(path, "wb") as f:
        f.write(png)


def main():
    os.makedirs(OUT, exist_ok=True)
    heights = [0.0] * (SIZE * SIZE)
    for y in range(SIZE):
        v = y / SIZE
        row = y * SIZE
        for x in range(SIZE):
            heights[row + x] = height_at(x / SIZE, v)

    albedo = bytearray(SIZE * SIZE * 3)
    normal = bytearray(SIZE * SIZE * 3)
    strength = 3.0

    for y in range(SIZE):
        row = y * SIZE
        up = (y - 1) % SIZE
        dn = (y + 1) % SIZE
        for x in range(SIZE):
            xl = (x - 1) % SIZE
            xr = (x + 1) % SIZE
            h = heights[row + x]

            # Neutral detail around 1.0.
            g = max(0.0, min(1.0, 0.82 + h * 0.36))
            # Tiny pebbles: sparse bright specks.
            n = pnoise(x / SIZE, y / SIZE, 160, 7)
            if n > 0.82:
                g = min(1.0, g + 0.06)
            i = (row + x) * 3
            albedo[i] = albedo[i + 1] = albedo[i + 2] = int(g * 255)

            dx = (heights[row + xr] - heights[row + xl]) * strength
            dy = (heights[dn * SIZE + x] - heights[up * SIZE + x]) * strength
            nx, ny, nz = -dx, -dy, 1.0
            inv = 1.0 / math.sqrt(nx * nx + ny * ny + nz * nz)
            normal[i] = int((nx * inv * 0.5 + 0.5) * 255)
            normal[i + 1] = int((ny * inv * 0.5 + 0.5) * 255)
            normal[i + 2] = int((nz * inv * 0.5 + 0.5) * 255)

    write_png(os.path.join(OUT, "ground-albedo.png"), albedo)
    write_png(os.path.join(OUT, "ground-normal.png"), normal)

    # Fine detail: high-frequency grass/soil grain and small pebbles.
    fh = [0.0] * (FINE * FINE)
    for y in range(FINE):
        v = y / FINE
        row = y * FINE
        for x in range(FINE):
            u = x / FINE
            fh[row + x] = (0.55 * (pnoise(u, v, 48, 71) - 0.5)
                           + 0.30 * (pnoise(u, v, 128, 83) - 0.5)
                           + 0.15 * (pnoise(u, v, 256, 97) - 0.5))

    falbedo = bytearray(FINE * FINE * 3)
    fnormal = bytearray(FINE * FINE * 3)
    for y in range(FINE):
        row = y * FINE
        up = (y - 1) % FINE
        dn = (y + 1) % FINE
        for x in range(FINE):
            xl = (x - 1) % FINE
            xr = (x + 1) % FINE
            h = fh[row + x]
            g = max(0.0, min(1.0, 0.86 + h * 0.55))
            i = (row + x) * 3
            falbedo[i] = falbedo[i + 1] = falbedo[i + 2] = int(g * 255)

            dx = (fh[row + xr] - fh[row + xl]) * 2.6
            dy = (fh[dn * FINE + x] - fh[up * FINE + x]) * 2.6
            nx, ny, nz = -dx, -dy, 1.0
            inv = 1.0 / math.sqrt(nx * nx + ny * ny + nz * nz)
            fnormal[i] = int((nx * inv * 0.5 + 0.5) * 255)
            fnormal[i + 1] = int((ny * inv * 0.5 + 0.5) * 255)
            fnormal[i + 2] = int((nz * inv * 0.5 + 0.5) * 255)

    write_png(os.path.join(OUT, "ground-fine.png"), falbedo, FINE)
    write_png(os.path.join(OUT, "ground-fine-normal.png"), fnormal, FINE)

    # Rock/cliff set: sharper strata, stronger relief.
    rh = [0.0] * (SIZE * SIZE)
    for y in range(SIZE):
        v = y / SIZE
        row = y * SIZE
        for x in range(SIZE):
            rh[row + x] = rock_height_at(x / SIZE, v)

    ralb = bytearray(SIZE * SIZE * 3)
    rnorm = bytearray(SIZE * SIZE * 3)
    for y in range(SIZE):
        row = y * SIZE
        up = (y - 1) % SIZE
        dn = (y + 1) % SIZE
        for x in range(SIZE):
            xl = (x - 1) % SIZE
            xr = (x + 1) % SIZE
            h = rh[row + x]
            g = max(0.0, min(1.0, 0.66 + h * 0.34))
            i = (row + x) * 3
            ralb[i] = int(min(1.0, g * 1.02) * 255)
            ralb[i + 1] = int(g * 255)
            ralb[i + 2] = int(g * 0.94 * 255)

            dx = (rh[row + xr] - rh[row + xl]) * 4.0
            dy = (rh[dn * SIZE + x] - rh[up * SIZE + x]) * 4.0
            nx, ny, nz = -dx, -dy, 1.0
            inv = 1.0 / math.sqrt(nx * nx + ny * ny + nz * nz)
            rnorm[i] = int((nx * inv * 0.5 + 0.5) * 255)
            rnorm[i + 1] = int((ny * inv * 0.5 + 0.5) * 255)
            rnorm[i + 2] = int((nz * inv * 0.5 + 0.5) * 255)

    write_png(os.path.join(OUT, "rock-albedo.png"), ralb)
    write_png(os.path.join(OUT, "rock-normal.png"), rnorm)
    print("wrote ground and rock textures to", OUT)


if __name__ == "__main__":
    main()
