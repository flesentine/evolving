#!/usr/bin/env python3
"""Builds the era housing set in Blender and exports .civmesh assets.

Run headless:
    /Applications/Blender.app/Contents/MacOS/Blender -b --python Scripts/build_buildings.py

Outputs (Assets/Buildings):
    classical-house.civmesh
    medieval-house.civmesh
    renaissance-house.civmesh
    industrial-house.civmesh
    modern-house.civmesh
    modern-tower.civmesh
    buildings-atlas.png (generated separately)
"""

import bpy
import bmesh
import json
import math
import os
import struct

CELL = 512
ATLAS = 2048.0
MARGIN = 0.020

ISLANDS = {
    "thatch": 0, "daub": 1, "stone": 2, "oak": 3,
    "door": 4, "brick": 5, "slate": 6, "tile": 7,
    "plaster": 8, "glass": 9, "concrete": 10, "metal": 11,
    "dark": 12, "marble": 13, "planks": 14, "turf": 15,
}


def uv(island, u, v):
    idx = ISLANDS[island]
    col = idx % 4
    row = idx // 4
    x = col * CELL + MARGIN * CELL + u * CELL * (1 - 2 * MARGIN)
    y = row * CELL + MARGIN * CELL + v * CELL * (1 - 2 * MARGIN)
    return (x / ATLAS, y / ATLAS)


class MB:
    def __init__(self):
        self.v = []
        self.f = []

    def quad(self, a, b, c, d, uva, uvb, uvc, uvd, smooth=False):
        base = len(self.v)
        self.v.extend([a, b, c, d])
        self.f.append(([base, base + 1, base + 2, base + 3],
                       [uva, uvb, uvc, uvd], smooth))

    def quad_out(self, a, b, c, d, out, uva, uvb, uvc, uvd, smooth=False):
        """Quads whose winding is chosen so the face points along `out`."""
        ab = (b[0] - a[0], b[1] - a[1], b[2] - a[2])
        ac = (c[0] - a[0], c[1] - a[1], c[2] - a[2])
        n = (ab[1] * ac[2] - ab[2] * ac[1],
             ab[2] * ac[0] - ab[0] * ac[2],
             ab[0] * ac[1] - ab[1] * ac[0])
        if n[0] * out[0] + n[1] * out[1] + n[2] * out[2] < 0:
            self.quad(a, d, c, b, uva, uvd, uvc, uvb, smooth)
        else:
            self.quad(a, b, c, d, uva, uvb, uvc, uvd, smooth)

    def tri_out(self, a, b, c, out, uva, uvb, uvc, smooth=False):
        ab = (b[0] - a[0], b[1] - a[1], b[2] - a[2])
        ac = (c[0] - a[0], c[1] - a[1], c[2] - a[2])
        n = (ab[1] * ac[2] - ab[2] * ac[1],
             ab[2] * ac[0] - ab[0] * ac[2],
             ab[0] * ac[1] - ab[1] * ac[0])
        if n[0] * out[0] + n[1] * out[1] + n[2] * out[2] < 0:
            self.tri(a, c, b, uva, uvc, uvb, smooth)
        else:
            self.tri(a, b, c, uva, uvb, uvc, smooth)

    def tri(self, a, b, c, uva, uvb, uvc, smooth=False):
        base = len(self.v)
        self.v.extend([a, b, c])
        self.f.append(([base, base + 1, base + 2], [uva, uvb, uvc], smooth))

    def box(self, centre, size, island, u_scale=1.0, v_scale=1.0,
            smooth=False, skip_bottom=False):
        cx, cy, cz = centre
        hx, hy, hz = size[0] * 0.5, size[1] * 0.5, size[2] * 0.5
        x0, x1 = cx - hx, cx + hx
        y0, y1 = cy - hy, cy + hy
        z0, z1 = cz - hz, cz + hz

        def U(u, v):
            return uv(island, u * u_scale, v * v_scale)

        # Front (+Z), back (-Z), right (+X), left (-X), top, bottom.
        self.quad((x0, y0, z1), (x1, y0, z1), (x1, y1, z1), (x0, y1, z1),
                  U(0, 0), U(1, 0), U(1, 1), U(0, 1), smooth)
        self.quad((x1, y0, z0), (x0, y0, z0), (x0, y1, z0), (x1, y1, z0),
                  U(0, 0), U(1, 0), U(1, 1), U(0, 1), smooth)
        self.quad((x1, y0, z1), (x1, y0, z0), (x1, y1, z0), (x1, y1, z1),
                  U(0, 0), U(1, 0), U(1, 1), U(0, 1), smooth)
        self.quad((x0, y0, z0), (x0, y0, z1), (x0, y1, z1), (x0, y1, z0),
                  U(0, 0), U(1, 0), U(1, 1), U(0, 1), smooth)
        self.quad((x0, y1, z1), (x1, y1, z1), (x1, y1, z0), (x0, y1, z0),
                  U(0, 0), U(1, 0), U(1, 1), U(0, 1), smooth)
        if not skip_bottom:
            self.quad((x0, y0, z0), (x1, y0, z0), (x1, y0, z1), (x0, y0, z1),
                      U(0, 0), U(1, 0), U(1, 1), U(0, 1), smooth)

    def gable_roof(self, width, depth, base_y, height, overhang,
                   roof_island, wall_island, cx=0.0, cz=0.0):
        hw, hd = width * 0.5 + overhang, depth * 0.5 + overhang
        a = (cx - hw, base_y, cz - hd)
        b = (cx + hw, base_y, cz - hd)
        c = (cx + hw, base_y, cz + hd)
        d = (cx - hw, base_y, cz + hd)
        r0 = (cx - hw, base_y + height, cz)
        r1 = (cx + hw, base_y + height, cz)
        # Slopes.
        self.quad_out(a, b, r1, r0, (0, 0.4, -1),
                      uv(roof_island, 0, 1), uv(roof_island, 1, 1),
                      uv(roof_island, 1, 0), uv(roof_island, 0, 0), smooth=True)
        self.quad_out(d, c, r1, r0, (0, 0.4, 1),
                      uv(roof_island, 0, 1), uv(roof_island, 1, 1),
                      uv(roof_island, 1, 0), uv(roof_island, 0, 0), smooth=True)
        # Gable ends (wall material).
        self.tri_out(a, r0, d, (-1, 0, 0), uv(wall_island, 0, 1),
                     uv(wall_island, 0.5, 0), uv(wall_island, 1, 1))
        self.tri_out(b, c, r1, (1, 0, 0), uv(wall_island, 0, 1),
                     uv(wall_island, 1, 1), uv(wall_island, 0.5, 0))
        # Underside.
        self.quad_out(a, d, c, b, (0, -1, 0), uv("dark", 0, 0), uv("dark", 1, 0),
                      uv("dark", 1, 1), uv("dark", 0, 1))
        # Ridge cap.
        self.box((cx, base_y + height, cz), (hw * 2, 0.22, 0.34), roof_island)

    def hip_roof(self, width, depth, base_y, height, overhang, roof_island):
        hw, hd = width * 0.5 + overhang, depth * 0.5 + overhang
        ridge = max(hw - hd * 0.85, 0.6)
        a = (-hw, base_y, -hd)
        b = (hw, base_y, -hd)
        c = (hw, base_y, hd)
        d = (-hw, base_y, hd)
        r0 = (-ridge, base_y + height, 0)
        r1 = (ridge, base_y + height, 0)
        self.quad_out(a, b, r1, r0, (0, 0.4, -1),
                      uv(roof_island, 0, 1), uv(roof_island, 1, 1),
                      uv(roof_island, 1, 0), uv(roof_island, 0, 0), smooth=True)
        self.quad_out(d, c, r1, r0, (0, 0.4, 1),
                      uv(roof_island, 0, 1), uv(roof_island, 1, 1),
                      uv(roof_island, 1, 0), uv(roof_island, 0, 0), smooth=True)
        self.tri_out(a, r0, d, (-1, 0.3, 0), uv(roof_island, 0, 0),
                     uv(roof_island, 1, 0), uv(roof_island, 0, 1), smooth=True)
        self.tri_out(b, c, r1, (1, 0.3, 0), uv(roof_island, 0, 0),
                     uv(roof_island, 1, 0), uv(roof_island, 0, 1), smooth=True)
        self.quad_out(a, d, c, b, (0, -1, 0), uv("dark", 0, 0), uv("dark", 1, 0),
                      uv("dark", 1, 1), uv("dark", 0, 1))
        self.box((0, base_y + height, 0), (ridge * 2, 0.22, 0.30), roof_island)

    def flat_roof(self, width, depth, base_y, parapet, island):
        hw, hd = width * 0.5 + 0.25, depth * 0.5 + 0.25
        self.box((0, base_y + 0.18, 0), (hw * 2, 0.36, hd * 2), island)
        t = 0.28
        self.box((0, base_y + 0.18 + parapet * 0.5, hd), (hw * 2, parapet, t), island)
        self.box((0, base_y + 0.18 + parapet * 0.5, -hd), (hw * 2, parapet, t), island)
        self.box((hw, base_y + 0.18 + parapet * 0.5, 0), (t, parapet, hd * 2), island)
        self.box((-hw, base_y + 0.18 + parapet * 0.5, 0), (t, parapet, hd * 2), island)


# ---------------------------------------------------------------------------
# Facade details
# ---------------------------------------------------------------------------

def bar2d(mb, p0, p1, z, thickness, depth, island, out_sign=1.0):
    """A rectangular bar between two points in the XY plane at depth z."""
    x0, y0 = p0
    x1, y1 = p1
    dx, dy = x1 - x0, y1 - y0
    length = math.hypot(dx, dy)
    if length < 1e-5:
        return
    nx, ny = -dy / length * thickness * 0.5, dx / length * thickness * 0.5
    a = (x0 - nx, y0 - ny, z + depth * 0.5 * out_sign)
    b = (x1 - nx, y1 - ny, z + depth * 0.5 * out_sign)
    c = (x1 + nx, y1 + ny, z + depth * 0.5 * out_sign)
    d = (x0 + nx, y0 + ny, z + depth * 0.5 * out_sign)
    a2 = (a[0], a[1], z - depth * 0.5 * out_sign)
    b2 = (b[0], b[1], z - depth * 0.5 * out_sign)
    c2 = (c[0], c[1], z - depth * 0.5 * out_sign)
    d2 = (d[0], d[1], z - depth * 0.5 * out_sign)
    u0, u1 = (0.0, 1.0) if length > 0 else (0.0, 0.0)
    mb.quad(a, b, c, d, uv(island, 0, 0), uv(island, u1, 0),
            uv(island, u1, 1), uv(island, 0, 1))
    mb.quad(a2, a, d, d2, uv(island, 0, 0), uv(island, 0, 1),
            uv(island, 1, 1), uv(island, 1, 0))
    mb.quad(b, b2, c2, c, uv(island, 0, 0), uv(island, 0, 1),
            uv(island, 1, 1), uv(island, 1, 0))


def window(mb, face, x, y, z, w, h, frame="plaster", glass="glass",
           shutter=None, sill=True):
    """face: 'front' (+Z), 'back' (-Z), 'left' (-X), 'right' (+X)."""
    t = 0.10
    if face in ("front", "back"):
        sign = 1.0 if face == "front" else -1.0
        zz = z + sign * t * 0.5
        mb.box((x, y + sign * 0.02, zz), (w * 1.16, h * 1.12, t), frame)
        mb.box((x, y, zz + sign * 0.03), (w, h, t * 0.6), glass)
        if sill:
            mb.box((x, y - h * 0.5 - 0.08, zz), (w * 1.26, 0.16, 0.22), frame)
        if shutter:
            for side in (-1, 1):
                mb.box((x + side * w * 0.62, y, zz), (w * 0.34, h * 1.04, t * 0.5), shutter)
    else:
        sign = 1.0 if face == "right" else -1.0
        xx = x + sign * t * 0.5
        mb.box((xx, y + sign * 0.02, z), (t, w * 1.16, h * 1.12), frame)
        mb.box((xx + sign * 0.03, y, z), (t * 0.6, w, h), glass)
        if sill:
            mb.box((xx, y - h * 0.5 - 0.08, z), (0.22, w * 1.26, 0.16), frame)
        if shutter:
            for side in (-1, 1):
                mb.box((xx, y, z + side * w * 0.62), (t * 0.5, w * 0.34, h * 1.04), shutter)


def door(mb, x, y, z, w, h, frame="oak", leaf="door", step="stone"):
    mb.box((x, y, z + 0.05), (w * 1.22, h * 1.10, 0.14), frame)
    mb.box((x, y, z + 0.10), (w, h, 0.12), leaf)
    mb.box((x, y - h * 0.5 - 0.10, z + 0.16), (w * 1.30, 0.18, 0.42), step)
    mb.box((x, y + h * 0.5 + 0.10, z + 0.10), (w * 1.16, 0.14, 0.18), frame)


def chimney(mb, x, base_y, z, h, width=0.66, island="brick"):
    mb.box((x, base_y + h * 0.5, z), (width, h, width), island)
    mb.box((x, base_y + h + 0.08, z), (width * 1.25, 0.22, width * 1.25), "stone")
    for side in (-1, 0, 1):
        mb.box((x + side * width * 0.30, base_y + h + 0.34, z),
               (width * 0.20, 0.34, width * 0.20), "metal")


# ---------------------------------------------------------------------------
# House styles (dimensions in BU; base at y = 0, front toward +Z)
# ---------------------------------------------------------------------------

def classical_house():
    mb = MB()
    w, d = 11.5, 9.0
    h = 7.6
    mb.box((0, 0.55, 0), (w * 1.06, 1.10, d * 1.06), "stone")
    mb.box((0, 1.10 + h * 0.5, 0), (w, h, d), "plaster")
    # String course.
    mb.box((0, 1.10 + h * 0.52, 0), (w * 1.01, 0.20, d * 1.01), "stone")
    # Portico: four columns and a pediment.
    for cx in (-w * 0.28, -w * 0.09, w * 0.09, w * 0.28):
        mb.box((cx, 1.10 + 1.65, d * 0.5 + 0.65), (0.42, 3.30, 0.42), "marble")
    mb.box((0, 1.10 + 3.35, d * 0.5 + 0.65), (w * 0.62, 0.34, 1.10), "marble")
    mb.gable_roof(w * 0.66, 1.0, 1.10 + 3.52, 1.6, 0.05, "tile", "marble",
                  cz=d * 0.5 + 0.65)
    # Main roof.
    mb.gable_roof(w, d, 1.10 + h, 3.2, 0.55, "tile", "plaster")
    for row, yy in enumerate((4.0, 6.7)):
        for i in range(3):
            window(mb, "front", (i - 1) * w * 0.26, yy, d * 0.5, 1.15, 1.75)
            window(mb, "back", (i - 1) * w * 0.26, yy, -d * 0.5, 1.15, 1.75)
    for face, x in (("right", w * 0.5), ("left", -w * 0.5)):
        for i in range(2):
            window(mb, face, x, 4.0 + i * 2.7, 0, 1.05, 1.65)
    door(mb, 0, 1.10, d * 0.5, 1.55, 2.65)
    chimney(mb, w * 0.28, 1.10 + h + 2.9, -d * 0.18, 1.5, 0.7, "brick")

    # Corner quoins.
    for sx in (-1, 1):
        for k in range(8):
            qy = 1.55 + k * 1.28
            q = 0.62 if k % 2 == 0 else 0.46
            mb.box((sx * (w * 0.5 - q * 0.5 + 0.02), qy, d * 0.5 - q * 0.5 + 0.02),
                   (q, 0.46, q), "stone")
            mb.box((sx * (w * 0.5 - q * 0.5 + 0.02), qy, -d * 0.5 + q * 0.5 - 0.02),
                   (q, 0.46, q), "stone")

    # Pediments over the front windows and a flight of steps.
    for row, yy in enumerate((4.0, 6.7)):
        for i in range(3):
            mb.gable_roof(1.65, 0.38, yy + 1.0, 0.42, 0.04, "stone", "stone",
                          cx=(i - 1) * w * 0.26, cz=d * 0.5 + 0.06)
    mb.box((0, 0.35, d * 0.5 + 1.30), (w * 0.60, 0.70, 1.20), "stone")
    mb.box((0, 0.18, d * 0.5 + 1.95), (w * 0.64, 0.36, 1.05), "stone")
    return mb


def medieval_house():
    mb = MB()
    w, d = 10.5, 8.5
    lower_h, upper_h = 4.0, 3.6
    mb.box((0, 0.45, 0), (w * 1.05, 0.9, d * 1.05), "stone")
    mb.box((0, 0.9 + lower_h * 0.5, 0), (w, lower_h, d), "daub")
    # Jettied upper floor.
    mb.box((0, 0.9 + lower_h + upper_h * 0.5, 0), (w * 1.10, upper_h, d * 1.10), "plaster")
    # Timber frame: posts and rails on the front.
    for x in (-w * 0.48, -w * 0.24, 0.0, w * 0.24, w * 0.48):
        mb.box((x, 0.9 + lower_h * 0.5, d * 0.5 + 0.08), (0.26, lower_h, 0.12), "oak")
        mb.box((x, 0.9 + lower_h + upper_h * 0.5, d * 0.55 + 0.08), (0.26, upper_h, 0.12), "oak")
    for yy in (0.9 + 0.15, 0.9 + lower_h - 0.15, 0.9 + lower_h + 0.18, 0.9 + lower_h + upper_h - 0.15):
        mb.box((0, yy, d * 0.5 + 0.10), (w, 0.24, 0.12), "oak")
    # Steep gable roof.
    mb.gable_roof(w * 1.10, d * 1.10, 0.9 + lower_h + upper_h, 5.2, 0.5, "tile", "plaster")
    mb.box((0, 0.9 + lower_h + upper_h + 0.15, 0), (w * 1.15, 0.25, d * 1.15), "oak")
    for yy in (0.9 + 2.0, 0.9 + lower_h + 1.9):
        for i in range(2):
            window(mb, "front", (i - 0.5) * w * 0.34, yy, d * 0.55, 1.25, 1.55,
                   shutter="oak")
            window(mb, "back", (i - 0.5) * w * 0.34, yy, -d * 0.55, 1.25, 1.55,
                   shutter="oak")
    for face, x in (("right", w * 0.55), ("left", -w * 0.55)):
        for i in range(2):
            window(mb, face, x, 2.0 + i * 3.2, 0, 1.05, 1.45, shutter="oak")
    door(mb, -w * 0.18, 0.9, d * 0.5, 1.45, 2.55)
    chimney(mb, w * 0.30, 0.9 + lower_h + upper_h + 4.2, -d * 0.22, 2.4, 0.8, "brick")

    # Diagonal braces between the front posts.
    for i in range(4):
        x0 = (-w * 0.48) + i * w * 0.24
        x1 = x0 + w * 0.24
        bar2d(mb, (x0, 0.9 + 0.35), (x1, 0.9 + lower_h - 0.35), d * 0.5 + 0.10,
              0.16, 0.10, "oak")
        bar2d(mb, (x1, 0.9 + lower_h + 0.35), (x0, 0.9 + lower_h + upper_h - 0.35),
              d * 0.55 + 0.10, 0.16, 0.10, "oak")

    # Jetty brackets under the overhang.
    for i in range(3):
        bx = (i - 1) * w * 0.30
        bar2d(mb, (bx, 0.9 + lower_h - 0.55), (bx + 0.45, 0.9 + lower_h - 0.05),
              d * 0.54, 0.18, 0.12, "oak")

    # Door canopy.
    mb.gable_roof(2.5, 1.0, 0.9 + 2.55, 0.52, 0.10, "tile", "oak",
                  cx=-w * 0.18, cz=d * 0.5 + 0.55)
    mb.box((-w * 0.18 - 1.05, 0.9 + 2.25, d * 0.5 + 0.95), (0.16, 0.7, 0.16), "oak")
    mb.box((-w * 0.18 + 1.05, 0.9 + 2.25, d * 0.5 + 0.95), (0.16, 0.7, 0.16), "oak")

    # Hanging shop sign.
    mb.box((w * 0.34, 0.9 + 2.85, d * 0.5 + 0.50), (0.10, 0.10, 1.00), "oak")
    mb.box((w * 0.34, 0.9 + 2.45, d * 0.5 + 0.95), (0.10, 0.80, 0.06), "oak")
    mb.box((w * 0.34, 0.9 + 2.15, d * 0.5 + 0.95), (0.10, 0.42, 0.55), "planks")

    # Dormer on the front roof slope.
    mb.box((w * 0.20, 0.9 + lower_h + upper_h + 2.0, d * 0.22),
           (2.0, 1.6, 1.4), "plaster")
    mb.gable_roof(2.0, 1.4, 0.9 + lower_h + upper_h + 2.8, 0.95, 0.10,
                  "tile", "plaster", cx=w * 0.20, cz=d * 0.22)
    window(mb, "front", w * 0.20, 0.9 + lower_h + upper_h + 2.1, d * 0.22 + 0.70,
           1.0, 1.1)
    return mb


def renaissance_house():
    mb = MB()
    w, d = 12.0, 10.0
    h = 11.0
    mb.box((0, 0.65, 0), (w * 1.05, 1.3, d * 1.05), "stone")
    mb.box((0, 1.3 + h * 0.5, 0), (w, h, d), "plaster")
    mb.box((0, 1.3 + 3.9, 0), (w * 1.02, 0.26, d * 1.02), "stone")
    mb.box((0, 1.3 + 7.6, 0), (w * 1.02, 0.26, d * 1.02), "stone")
    # Cornice.
    mb.box((0, 1.3 + h - 0.18, 0), (w * 1.06, 0.36, d * 1.06), "stone")
    mb.hip_roof(w, d, 1.3 + h, 3.6, 0.65, "slate")
    # Dormers.
    for i in range(3):
        x = (i - 1) * w * 0.27
        mb.box((x, 1.3 + h + 1.0, d * 0.30), (2.0, 1.7, 1.6), "plaster")
        mb.gable_roof(2.0, 1.6, 1.3 + h + 1.85, 1.0, 0.12, "slate", "plaster")
        window(mb, "front", x, 1.3 + h + 1.05, d * 0.30 + 0.8, 1.0, 1.2)
    for row, yy in enumerate((3.0, 6.7, 10.2)):
        for i in range(3):
            window(mb, "front", (i - 1) * w * 0.27, yy, d * 0.5, 1.25, 1.9)
            window(mb, "back", (i - 1) * w * 0.27, yy, -d * 0.5, 1.25, 1.9)
    for face, x in (("right", w * 0.5), ("left", -w * 0.5)):
        for i in range(3):
            window(mb, face, x, 3.0 + i * 3.6, 0, 1.15, 1.8)
    door(mb, 0, 1.3, d * 0.5, 1.7, 3.0)
    chimney(mb, -w * 0.32, 1.3 + h + 3.2, -d * 0.2, 2.2, 0.9, "brick")
    return mb


def industrial_house():
    mb = MB()
    w, d = 9.5, 8.5
    h = 11.5
    mb.box((0, 0.4, 0), (w * 1.04, 0.8, d * 1.04), "stone")
    mb.box((0, 0.8 + h * 0.5, 0), (w, h, d), "brick")
    # Stone lintels and a string course.
    mb.box((0, 0.8 + 4.0, 0), (w * 1.01, 0.18, d * 1.01), "stone")
    mb.box((0, 0.8 + 8.0, 0), (w * 1.01, 0.18, d * 1.01), "stone")
    mb.gable_roof(w, d, 0.8 + h, 3.0, 0.35, "slate", "brick")
    for row, yy in enumerate((2.6, 5.6, 8.8, 11.6)):
        for i in range(2):
            window(mb, "front", (i - 0.5) * w * 0.34, yy, d * 0.5, 1.2, 1.9)
            window(mb, "back", (i - 0.5) * w * 0.34, yy, -d * 0.5, 1.2, 1.9)
    for face, x in (("right", w * 0.5), ("left", -w * 0.5)):
        for i in range(3):
            window(mb, face, x, 2.6 + i * 3.2, 0, 1.1, 1.8)
    door(mb, w * 0.22, 0.8, d * 0.5, 1.4, 2.5)
    for cx in (-w * 0.30, w * 0.30):
        chimney(mb, cx, 0.8 + h + 2.6, -d * 0.24, 2.0, 0.7, "brick")

    # Ground-floor shopfront and sign board.
    mb.box((0, 2.1, d * 0.5 + 0.10), (w * 0.62, 2.0, 0.16), "oak")
    mb.box((0, 2.1, d * 0.5 + 0.20), (w * 0.54, 1.7, 0.10), "glass")
    mb.box((0, 3.55, d * 0.5 + 0.22), (w * 0.66, 0.55, 0.10), "planks")
    for i in range(3):
        mb.box(((i - 1) * w * 0.18, 2.1, d * 0.5 + 0.26), (0.10, 1.7, 0.06), "metal")

    # Brick string courses and roof vents.
    for yy in (1.1, 4.4, 7.7, 10.9):
        mb.box((0, yy, 0), (w * 1.005, 0.14, d * 1.005), "stone")
    for i in range(3):
        mb.box(((i - 1) * w * 0.26, 0.8 + h + 0.9, -d * 0.10),
               (0.8, 0.9, 0.8), "metal")
    return mb


def modern_house():
    mb = MB()
    w, d = 12.0, 10.0
    h = 7.5
    mb.box((0, 0.35, 0), (w * 1.03, 0.7, d * 1.03), "concrete")
    mb.box((0, 0.7 + h * 0.5, 0), (w, h, d), "concrete")
    # Cantilevered upper floor and balcony.
    mb.box((0, 0.7 + h + 0.2, 0), (w * 1.08, 0.4, d * 1.08), "concrete")
    mb.box((0, 0.7 + h * 0.55, d * 0.5 + 1.1), (w * 0.9, 0.24, 2.2), "concrete")
    # Full-height glazing.
    for i in range(3):
        window(mb, "front", (i - 1) * w * 0.29, 3.3, d * 0.5, 2.5, 4.2,
               frame="metal", glass="glass", sill=False)
        window(mb, "back", (i - 1) * w * 0.29, 3.3, -d * 0.5, 2.5, 4.2,
               frame="metal", glass="glass", sill=False)
    for face, x in (("right", w * 0.5), ("left", -w * 0.5)):
        for i in range(2):
            window(mb, face, x, 2.4 + i * 2.6, 0, 2.2, 1.9,
                   frame="metal", glass="glass", sill=False)
    door(mb, -w * 0.30, 0.7, d * 0.5, 1.6, 2.8, frame="metal")
    # Flat roof with a plant room.
    mb.flat_roof(w, d, 0.7 + h + 0.4, 0.6, "concrete")
    mb.box((w * 0.16, 0.7 + h + 1.3, 0), (3.4, 1.5, 2.6), "metal")

    # Balcony railing.
    for i in range(11):
        bx = -w * 0.42 + i * (w * 0.84 / 10)
        mb.box((bx, 0.7 + h * 0.55 + 0.9, d * 0.5 + 2.05), (0.06, 1.1, 0.06), "metal")
    mb.box((0, 0.7 + h * 0.55 + 1.45, d * 0.5 + 2.05), (w * 0.86, 0.08, 0.10), "metal")

    # Entrance canopy and posts.
    mb.box((-w * 0.30, 0.7 + 2.95, d * 0.5 + 0.85), (3.0, 0.22, 1.7), "concrete")
    for side in (-1, 1):
        mb.box((-w * 0.30 + side * 1.25, 0.7 + 1.45, d * 0.5 + 1.55),
               (0.16, 2.9, 0.16), "metal")

    # Vertical mullions over the front glazing.
    for i in range(7):
        bx = -w * 0.42 + i * (w * 0.84 / 6)
        mb.box((bx, 3.3, d * 0.5 + 0.12), (0.07, 4.3, 0.08), "metal")

    # Rooftop plant and a small penthouse.
    mb.box((w * 0.30, 0.7 + h + 1.0, -d * 0.20), (2.2, 1.2, 2.0), "metal")
    mb.box((-w * 0.26, 0.7 + h + 0.85, 0), (2.6, 1.7, 3.0), "concrete")
    return mb


def modern_tower():
    mb = MB()
    w, d = 10.0, 10.0
    floors = 8
    fh = 2.9
    h = floors * fh
    mb.box((0, 0.5, 0), (w * 1.05, 1.0, d * 1.05), "concrete")
    mb.box((0, 0.5 + h * 0.5, 0), (w, h, d), "concrete")
    # Curtain wall bands.
    for f in range(floors):
        y = 0.5 + f * fh
        mb.box((0, y + fh * 0.55, 0), (w * 1.015, fh * 0.72, d * 1.015), "glass")
        mb.box((0, y + fh * 0.97, 0), (w * 1.03, 0.16, d * 1.03), "metal")
        for side in (-1, 1):
            mb.box((side * w * 0.5, y + fh * 0.5, 0), (0.16, fh, d * 1.01), "metal")
            mb.box((0, y + fh * 0.5, side * d * 0.5), (w * 1.01, fh, 0.16), "metal")
    mb.flat_roof(w, d, 0.5 + h, 0.7, "concrete")
    mb.box((0, 0.5 + h + 1.4, 0), (3.6, 1.2, 3.6), "metal")
    door(mb, 0, 0.5, d * 0.5, 2.2, 3.0, frame="metal")
    return mb


STYLES = {
    "classical-house": classical_house,
    "medieval-house": medieval_house,
    "renaissance-house": renaissance_house,
    "industrial-house": industrial_house,
    "modern-house": modern_house,
    "modern-tower": modern_tower,
}


def export(mb, name):
    here = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    out = os.path.join(here, "Assets", "Buildings", name + ".civmesh")

    # The builder authors in renderer coordinates (Y up). Blender is Z up, so
    # rotate -90 degrees about X for the mesh; the exporter rotates back.
    verts = [(p[0], -p[2], p[1]) for p in mb.v]

    mesh = bpy.data.meshes.new(name)
    mesh.from_pydata(verts, [], [f[0] for f in mb.f])
    mesh.update()

    uv_layer = mesh.uv_layers.new(name="UVMap")
    loop = 0
    for indices, uvs, smooth in mb.f:
        for (u, v) in uvs:
            uv_layer.data[loop].uv = (u, v)
            loop += 1
    for poly, (indices, uvs, smooth) in zip(mesh.polygons, mb.f):
        poly.use_smooth = smooth
    mesh.update()
    mesh.validate()

    obj = bpy.data.objects.new(name, mesh)
    bpy.context.collection.objects.link(obj)

    bm = bmesh.new()
    bm.from_mesh(mesh)
    bmesh.ops.triangulate(bm, faces=bm.faces)
    bm.to_mesh(mesh)
    bm.free()
    mesh.update()

    depsgraph = bpy.context.evaluated_depsgraph_get()
    eval_obj = obj.evaluated_get(depsgraph)
    eval_mesh = eval_obj.to_mesh()
    uv_layer = eval_mesh.uv_layers.active
    eval_mesh.calc_loop_triangles()

    vertex_count = 0
    index_count = 0
    vbuf = bytearray()
    ibuf = bytearray()
    mins = [1e9, 1e9, 1e9]
    maxs = [-1e9, -1e9, -1e9]

    try:
        corner_normals = eval_mesh.corner_normals
        use_corner = True
    except AttributeError:
        use_corner = False

    for tri in eval_mesh.loop_triangles:
        for li in tri.loops:
            v = eval_mesh.vertices[eval_mesh.loops[li].vertex_index]
            p = v.co
            x, y, z = p.x, p.z, -p.y
            n = corner_normals[li].vector if use_corner else tri.normal
            nx, ny, nz = n.x, n.z, -n.y
            u, vv = uv_layer.data[li].uv
            vbuf += struct.pack("<8f", x, y, z, nx, ny, nz, u, vv)
            vertex_count += 1
            mins[0] = min(mins[0], x); mins[1] = min(mins[1], y); mins[2] = min(mins[2], z)
            maxs[0] = max(maxs[0], x); maxs[1] = max(maxs[1], y); maxs[2] = max(maxs[2], z)
        for _ in tri.loops:
            ibuf += struct.pack("<I", index_count)
            index_count += 1

    data = bytearray()
    data += struct.pack("<4sII", b"CIVM", 1, vertex_count)
    data += struct.pack("<I", index_count)
    data += struct.pack("<6f", mins[0], mins[1], mins[2], maxs[0], maxs[1], maxs[2])
    data += vbuf
    data += ibuf

    with open(out, "wb") as f:
        f.write(data)

    eval_obj.to_mesh_clear()
    bpy.data.objects.remove(obj, do_unlink=True)
    bpy.data.meshes.remove(mesh)

    return {
        "name": name,
        "triangles": index_count // 3,
        "min": mins,
        "max": maxs,
    }


def main():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    manifest = []
    for name, builder in STYLES.items():
        mb = builder()
        info = export(mb, name)
        manifest.append(info)
        print("built", name, info["triangles"], "tris")

    here = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    with open(os.path.join(here, "Assets", "Buildings", "manifest.json"), "w") as f:
        json.dump(manifest, f, indent=2)

    print("wrote manifest")


if __name__ == "__main__":
    main()
