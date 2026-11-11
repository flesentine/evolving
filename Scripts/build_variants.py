#!/usr/bin/env python3
"""Generates 30 building variants for the four visibility-critical eras and
renders a contact sheet for each.

Run:
    /Applications/Blender.app/Contents/MacOS/Blender -b --python Scripts/build_variants.py

Outputs:
    Assets/Buildings/variants/<era>-<nn>.civmesh
    Assets/Buildings/variants/<era>-variants.png   (contact sheet)
    Assets/Buildings/variants/manifest.json
"""

import bpy
import bmesh
import json
import math
import os
import random
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)

from build_buildings import (  # noqa: E402
    MB, uv, window, door, chimney, bar2d,
)

OUT = os.path.join(ROOT, "Assets", "Buildings", "variants")
COUNT = 30


# ---------------------------------------------------------------------------
# Shared details
# ---------------------------------------------------------------------------

def window_grid(mb, width, depth, base_y, floor_h, storeys, cols,
                glass="glass", frame="plaster", shutter=None, back=True,
                sides=True, sill=True):
    for s in range(storeys):
        y = base_y + floor_h * (s + 0.5)
        for c in range(cols):
            x = (c - (cols - 1) * 0.5) * width / (cols + 0.7)
            window(mb, "front", x, y, depth * 0.5, 1.15, floor_h * 0.52,
                   frame=frame, glass=glass, shutter=shutter, sill=sill)
            if back:
                window(mb, "back", x, y, -depth * 0.5, 1.15, floor_h * 0.52,
                       frame=frame, glass=glass, shutter=shutter, sill=sill)
    if sides:
        for face, x in (("right", width * 0.5), ("left", -width * 0.5)):
            for s in range(storeys):
                y = base_y + floor_h * (s + 0.5)
                window(mb, face, x, y, 0, 1.05, floor_h * 0.48,
                       frame=frame, glass=glass, shutter=shutter, sill=sill)


def quoins(mb, width, depth, base_y, top_y, stone="stone", block=0.6):
    count = max(int((top_y - base_y) / 1.1), 2)
    for sx in (-1, 1):
        for k in range(count):
            y = base_y + 0.55 + k * (top_y - base_y) / count
            q = block if k % 2 == 0 else block * 0.72
            for sz in (-1, 1):
                mb.box((sx * (width * 0.5 - q * 0.5 + 0.02), y,
                        sz * (depth * 0.5 - q * 0.5 + 0.02)),
                       (q, 0.42, q), stone)


def railing(mb, width, y, z, island="metal", bars=9, height=1.05):
    for i in range(bars):
        x = -width * 0.5 + i * width / (bars - 1)
        mb.box((x, y + height * 0.5, z), (0.06, height, 0.06), island)
    mb.box((0, y + height, z), (width * 1.01, 0.08, 0.10), island)


def ring(radius, y, n=20, phase=0.0):
    return [(math.cos(phase + 2 * math.pi * i / n) * radius, y,
             math.sin(phase + 2 * math.pi * i / n) * radius) for i in range(n)]


def pyramid(mb, cx, cz, base_y, w, d, h, island):
    apex = (cx, base_y + h, cz)
    a = (cx - w * 0.5, base_y, cz - d * 0.5)
    b = (cx + w * 0.5, base_y, cz - d * 0.5)
    c = (cx + w * 0.5, base_y, cz + d * 0.5)
    dpt = (cx - w * 0.5, base_y, cz + d * 0.5)
    mb.tri_out(a, b, apex, (0, 0.3, -1), uv(island, 0, 0), uv(island, 1, 0),
               uv(island, 0.5, 1), smooth=True)
    mb.tri_out(c, dpt, apex, (0, 0.3, 1), uv(island, 0, 0), uv(island, 1, 0),
               uv(island, 0.5, 1), smooth=True)
    mb.tri_out(b, c, apex, (1, 0.3, 0), uv(island, 0, 0), uv(island, 1, 0),
               uv(island, 0.5, 1), smooth=True)
    mb.tri_out(dpt, a, apex, (-1, 0.3, 0), uv(island, 0, 0), uv(island, 1, 0),
               uv(island, 0.5, 1), smooth=True)


# ---------------------------------------------------------------------------
# Classical
# ---------------------------------------------------------------------------

def classical(spec):
    mb = MB()
    w, d = spec["width"], spec["depth"]
    floors, fh = spec["storeys"], spec["floor_h"]
    h = floors * fh
    y0 = 1.1

    mb.box((0, 0.55, 0), (w * 1.06, 1.10, d * 1.06), "stone")
    mb.box((0, y0 + h * 0.5, 0), (w, h, d), spec["wall"])
    for s in range(1, floors):
        mb.box((0, y0 + s * fh, 0), (w * 1.01, 0.20, d * 1.01), "stone")
    mb.box((0, y0 + h - 0.18, 0), (w * 1.07, 0.36, d * 1.07), "stone")

    if spec["roof"] == "hip":
        mb.hip_roof(w, d, y0 + h, spec["roof_h"], 0.6, spec["roof_mat"])
    elif spec["roof"] == "mansard":
        mb.hip_roof(w, d, y0 + h, spec["roof_h"] * 0.8, 0.45, spec["roof_mat"])
        mb.box((0, y0 + h + spec["roof_h"] * 0.8 + 0.55, 0),
               (w * 0.70, 1.1, d * 0.70), spec["roof_mat"])
    else:
        mb.gable_roof(w, d, y0 + h, spec["roof_h"], 0.6,
                      spec["roof_mat"], spec["wall"])

    if spec.get("dormers"):
        z_off = d * 0.30
        overhang = 0.45 if spec["roof"] == "mansard" else 0.6
        hd = d * 0.5 + overhang
        roof_h = spec["roof_h"] * (0.8 if spec["roof"] == "mansard" else 1.0)
        surface = roof_h * max(0.0, 1.0 - z_off / hd)
        base = y0 + h + surface - 0.55
        for i in range(3):
            dx = (i - 1) * w * 0.27
            mb.box((dx, base + 0.75, z_off), (1.9, 1.5, 1.3), spec["wall"])
            mb.gable_roof(1.9, 1.3, base + 1.50, 0.85, 0.08,
                          spec["roof_mat"], spec["wall"], cx=dx, cz=z_off)
            window(mb, "front", dx, base + 0.80, z_off + 0.66, 0.95, 1.0)

    window_grid(mb, w, d, y0, fh, floors, spec["cols"],
                shutter="oak" if spec["shutters"] else None,
                frame=spec["trim"])

    if spec["quoins"]:
        quoins(mb, w, d, y0, y0 + h)

    if spec["pediments"]:
        for s in range(floors):
            for c in range(spec["cols"]):
                x = (c - (spec["cols"] - 1) * 0.5) * w / (spec["cols"] + 0.7)
                mb.gable_roof(1.55, 0.34, y0 + fh * (s + 0.5) + 0.75, 0.38, 0.04,
                              "stone", "stone", cx=x, cz=d * 0.5 + 0.06)

    if spec["frontage"] == "portico":
        for c in range(spec["cols"] + 1):
            cx = (c - spec["cols"] * 0.5) * w * 0.15
            mb.box((cx, y0 + 1.65, d * 0.5 + 0.85), (0.42, 3.30, 0.42), "marble")
        mb.box((0, y0 + 3.35, d * 0.5 + 0.85), (w * 0.55, 0.34, 1.20), "marble")
        mb.gable_roof(w * 0.60, 1.2, y0 + 3.52, 1.5, 0.05,
                      spec["roof_mat"], "marble", cz=d * 0.5 + 0.85)
        mb.box((0, 0.35, d * 0.5 + 1.25), (w * 0.55, 0.70, 1.10), "stone")

    door(mb, spec["door_x"] * w, y0, d * 0.5, 1.55, 2.65)

    if spec["balcony"]:
        mb.box((0, y0 + fh + 0.15, d * 0.5 + 0.55), (w * 0.55, 0.20, 1.10), "stone")
        railing(mb, w * 0.52, y0 + fh + 0.25, d * 0.5 + 1.05, "marble", 11)

    chimney(mb, w * 0.28, y0 + h + spec["roof_h"] * 0.8, -d * 0.18,
            1.4, 0.7, spec["chimney_mat"])
    return mb


# ---------------------------------------------------------------------------
# Neolithic / Bronze roundhouse
# ---------------------------------------------------------------------------

def hut(spec):
    mb = MB()
    R, WH = spec["radius"], spec["wall_h"]
    eave_r = R + spec["eave"]
    eave_h = 0.5 + WH + spec["eave_lift"]
    apex = spec["apex"]
    seg = 20
    door_half = math.radians(spec["door_deg"])
    door_ang = math.pi * 0.5
    gap0 = door_ang - door_half
    gap1 = door_ang + door_half

    def in_gap(a):
        d = abs(((a - door_ang + math.pi) % (2 * math.pi)) - math.pi)
        return d < door_half

    # Footing ring.
    ob = ring(R + 0.32, 0.0)
    ot = ring(R + 0.32, 0.5)
    ib = ring(R - 0.05, 0.0)
    it = ring(R - 0.05, 0.5)
    for i in range(seg):
        j = (i + 1) % seg
        mb.quad(ob[i], ob[j], ot[j], ot[i],
                uv("stone", i / seg, 1), uv("stone", (i + 1) / seg, 1),
                uv("stone", (i + 1) / seg, 0.6), uv("stone", i / seg, 0.6))
        mb.quad(ot[i], ot[j], it[j], it[i],
                uv("stone", i / seg, 0.6), uv("stone", (i + 1) / seg, 0.6),
                uv("stone", (i + 1) / seg, 0.4), uv("stone", i / seg, 0.4))
        mb.quad(it[i], it[j], ib[j], ib[i],
                uv("stone", i / seg, 0.4), uv("stone", (i + 1) / seg, 0.4),
                uv("stone", (i + 1) / seg, 0), uv("stone", i / seg, 0))

    # Daub wall with a door gap.
    lo = ring(R, 0.5)
    hi = ring(R, 0.5 + WH)
    for i in range(seg):
        j = (i + 1) % seg
        a = 2 * math.pi * (i + 0.5) / seg
        if in_gap(a):
            continue
        mb.quad(lo[i], lo[j], hi[j], hi[i],
                uv("daub", i / seg * 2, 1), uv("daub", (i + 1) / seg * 2, 1),
                uv("daub", (i + 1) / seg * 2, 0), uv("daub", i / seg * 2, 0),
                smooth=True)

    # Interior shell and floor.
    il = ring(R - 0.16, 0.5)
    ih = ring(R - 0.16, 0.5 + WH)
    for i in range(seg):
        j = (i + 1) % seg
        mb.quad(ih[i], ih[j], il[j], il[i],
                uv("dark", 0, 0), uv("dark", 1, 0),
                uv("dark", 1, 1), uv("dark", 0, 1))
    floor = ring(R - 0.12, 0.52)
    for i in range(seg):
        j = (i + 1) % seg
        mb.tri((0, 0.52, 0), floor[i], floor[j],
               uv("dark", 0.5, 0.5), uv("dark", 0.2, 0.8), uv("dark", 0.8, 0.8))

    # Posts.
    posts = spec["posts"]
    for i in range(posts):
        a = 2 * math.pi * i / posts
        if in_gap(a):
            continue
        px, pz = math.cos(a) * (R + 0.04), math.sin(a) * (R + 0.04)
        ph = 0.5 + WH + spec["post_lift"]
        mb.box((px, ph * 0.5, pz), (0.34, ph, 0.34), "oak")

    # Layered thatch.
    courses = spec["courses"]
    profile = [(eave_h - 0.10, eave_r + 0.28), (eave_h + 0.08, eave_r + 0.08)]
    for i in range(1, courses + 1):
        t = i / courses
        h = eave_h + (apex - eave_h) * t
        r = max(0.22, eave_r * (1.0 - 0.90 * t))
        profile.append((h - 0.04, r))
        profile.append((h + 0.02, r + 0.14))
    profile.append((apex, 0.15))
    rings = [(h, ring(r, h, seg, door_ang + math.pi / seg)) for (h, r) in profile]
    for i in range(len(profile) - 1):
        v0 = i / (len(profile) - 1)
        v1 = (i + 1) / (len(profile) - 1)
        for s2 in range(seg):
            t2 = (s2 + 1) % seg
            mb.quad_out(rings[i][1][s2], rings[i][1][t2],
                        rings[i + 1][1][t2], rings[i + 1][1][s2],
                        (0, 0.4, 1),
                        uv("thatch", s2 / seg, v0), uv("thatch", (s2 + 1) / seg, v0),
                        uv("thatch", (s2 + 1) / seg, v1), uv("thatch", s2 / seg, v1),
                        smooth=True)

    # Peak bundle.
    mb.box((0, apex + 0.20, 0), (0.30, 0.55, 0.30), "thatch")
    # Under-eave soffit.
    for s2 in range(seg):
        t2 = (s2 + 1) % seg
        p0 = rings[0][1][s2]
        p1 = rings[0][1][t2]
        q0 = (p0[0] * 0.86, p0[1] * 0.86, eave_h + 0.20)
        q1 = (p1[0] * 0.86, p1[1] * 0.86, eave_h + 0.20)
        mb.quad_out(p1, p0, q0, q1, (0, -1, 0),
                    uv("dark", s2 / seg, 0), uv("dark", (s2 + 1) / seg, 0),
                    uv("dark", (s2 + 1) / seg, 1), uv("dark", s2 / seg, 1))

    # Porch posts and a lintel.
    if spec["porch"]:
        for side in (-1, 1):
            a = door_ang + side * (door_half + 0.16)
            px, pz = math.cos(a) * (R + 0.9), math.sin(a) * (R + 0.9)
            mb.box((px, eave_h * 0.5, pz), (0.42, eave_h, 0.42), "oak")
        mb.box((0, eave_h - 0.55, R + 0.9), (2.2, 0.35, 0.35), "oak")

    # Door panel and threshold.
    d0 = (math.cos(gap0) * R, 0.5, math.sin(gap0) * R)
    d1 = (math.cos(gap1) * R, 0.5, math.sin(gap1) * R)
    mid = ((d0[0] + d1[0]) * 0.5, (d0[2] + d1[2]) * 0.5)
    door_h = min(2.6, WH * 0.9)
    mb.box((mid[0] * 0.985, 0.5 + door_h * 0.5, mid[1] * 0.985),
           (2.0, door_h, 0.22), "door")
    mb.box((mid[0], 0.35, mid[1]), (2.6, 0.7, 1.3), "stone")

    # Lean-to on one side.
    if spec["lean_to"]:
        lx = R + 1.8
        mb.box((lx, 0.5, 0), (2.4, 0.5, 4.2), "stone")
        for zz in (-1.6, 1.6):
            mb.box((lx + 0.8, 1.7, zz), (0.28, 2.4, 0.28), "oak")
        mb.gable_roof(3.0, 5.0, 2.8, 1.0, 0.1, "thatch", "daub",
                      cx=lx, cz=0)

    return mb


# ---------------------------------------------------------------------------
# Medieval
# ---------------------------------------------------------------------------

def medieval(spec):
    mb = MB()
    w, d = spec["width"], spec["depth"]
    lower_h = spec["floor_h"]
    upper_h = spec["floor_h"] * 0.92
    floors = spec["storeys"]
    jetty = spec["jetty"]

    mb.box((0, 0.45, 0), (w * 1.05, 0.9, d * 1.05), "stone")
    mb.box((0, 0.9 + lower_h * 0.5, 0), (w, lower_h, d), "daub")

    upper_y = 0.9 + lower_h
    for f in range(1, floors):
        grow = 1.10 if (jetty and f == 1) else 1.03
        mb.box((0, upper_y + upper_h * 0.5, 0), (w * grow, upper_h, d * grow),
               spec["wall"])
        upper_y += upper_h

    top_y = upper_y

    # Timber frame: posts, rails and braces.
    for x in [(-w * 0.48) + i * w * 0.24 for i in range(5)]:
        mb.box((x, 0.9 + lower_h * 0.5, d * 0.5 + 0.08), (0.26, lower_h, 0.12), "oak")
        if floors > 1:
            mb.box((x, 0.9 + lower_h + upper_h * 0.5, d * 0.54 + 0.08),
                   (0.26, upper_h, 0.12), "oak")
    for yy in (1.05, 0.9 + lower_h - 0.15, 0.9 + lower_h + 0.18,
               0.9 + lower_h + upper_h - 0.15):
        mb.box((0, yy, d * 0.5 + 0.10), (w * 1.02, 0.24, 0.12), "oak")
    if spec["braces"]:
        for i in range(4):
            x0 = (-w * 0.48) + i * w * 0.24
            x1 = x0 + w * 0.24
            bar2d(mb, (x0, 0.9 + 0.35), (x1, 0.9 + lower_h - 0.35),
                  d * 0.5 + 0.10, 0.16, 0.10, "oak")
            bar2d(mb, (x1, 0.9 + lower_h + 0.35),
                  (x0, 0.9 + lower_h + upper_h - 0.35), d * 0.54 + 0.10,
                  0.16, 0.10, "oak")

    mb.gable_roof(w * 1.06, d * 1.06, top_y, spec["roof_h"], 0.5,
                  spec["roof_mat"], spec["wall"])
    mb.box((0, top_y + 0.15, 0), (w * 1.10, 0.25, d * 1.10), "oak")

    window_grid(mb, w * 1.06, d * 1.06, 0.9, lower_h, floors, spec["cols"],
                frame="oak", shutter="oak", sill=False)

    if spec["shopfront"]:
        mb.box((0, 1.95, d * 0.5 + 0.12), (w * 0.52, 1.9, 0.16), "oak")
        mb.box((0, 1.95, d * 0.5 + 0.22), (w * 0.44, 1.6, 0.10), "glass")
        mb.box((0, 3.30, d * 0.5 + 0.24), (w * 0.56, 0.50, 0.10), "planks")

    if spec["canopy"]:
        mb.gable_roof(2.5, 1.0, 0.9 + 2.55, 0.52, 0.10, spec["roof_mat"], "oak",
                      cx=spec["door_x"] * w, cz=d * 0.5 + 0.55)

    if spec["sign"]:
        sx = w * 0.36
        mb.box((sx, 0.9 + 2.85, d * 0.5 + 0.50), (0.10, 0.10, 1.00), "oak")
        mb.box((sx, 0.9 + 2.45, d * 0.5 + 0.95), (0.10, 0.80, 0.06), "oak")
        mb.box((sx, 0.9 + 2.15, d * 0.5 + 0.95), (0.10, 0.42, 0.55), "planks")

    if spec["dormer"]:
        dx = w * 0.18
        mb.box((dx, top_y + 1.35, d * 0.24), (1.9, 1.5, 1.3), spec["wall"])
        mb.gable_roof(1.9, 1.3, top_y + 2.1, 0.9, 0.08,
                      spec["roof_mat"], spec["wall"], cx=dx, cz=d * 0.24)
        window(mb, "front", dx, top_y + 1.35, d * 0.24 + 0.65, 0.95, 1.0)

    door(mb, spec["door_x"] * w, 0.9, d * 0.5, 1.45, 2.55)
    chimney(mb, spec["door_x"] * w * 0.8, top_y + spec["roof_h"] * 0.8,
            -d * 0.2, 2.2, 0.8, "brick")
    return mb


# ---------------------------------------------------------------------------
# Industrial
# ---------------------------------------------------------------------------

def industrial(spec):
    mb = MB()
    w, d = spec["width"], spec["depth"]
    floors, fh = spec["storeys"], spec["floor_h"]
    h = floors * fh
    y0 = 0.8

    mb.box((0, 0.4, 0), (w * 1.04, 0.8, d * 1.04), "stone")
    mb.box((0, y0 + h * 0.5, 0), (w, h, d), spec["wall"])
    for s in range(1, floors):
        mb.box((0, y0 + s * fh, 0), (w * 1.005, 0.16, d * 1.005), "stone")
    mb.box((0, y0 + h - 0.15, 0), (w * 1.02, 0.30, d * 1.02), "stone")

    if spec["roof"] == "mansard":
        # Two-stage roof.
        mb.gable_roof(w, d, y0 + h, spec["roof_h"] * 0.9, 0.35,
                      "slate", spec["wall"])
        mb.box((0, y0 + h + spec["roof_h"] * 0.9 + 0.6, 0),
               (w * 0.62, 1.2, d * 0.62), "slate")
    else:
        mb.gable_roof(w, d, y0 + h, spec["roof_h"], 0.35,
                      "slate", spec["wall"])

    window_grid(mb, w, d, y0, fh, floors, spec["cols"], frame="stone", sill=True)

    if spec["shopfront"]:
        mb.box((0, 1.95, d * 0.5 + 0.10), (w * 0.62, 1.9, 0.16), "oak")
        mb.box((0, 1.95, d * 0.5 + 0.20), (w * 0.54, 1.6, 0.10), "glass")
        mb.box((0, 3.35, d * 0.5 + 0.22), (w * 0.66, 0.55, 0.10), "planks")
        for i in range(3):
            mb.box(((i - 1) * w * 0.18, 1.95, d * 0.5 + 0.26),
                   (0.10, 1.6, 0.06), "metal")

    if spec["bay"]:
        bx = spec["door_x"] * w * 0.6
        mb.box((bx, y0 + fh * 1.5, d * 0.5 + 0.55), (2.6, fh * 1.3, 1.0),
               spec["wall"])
        window(mb, "front", bx, y0 + fh * 1.5, d * 0.5 + 1.06, 1.9, fh * 0.9,
               frame="stone")

    if spec["arcade"]:
        for c in range(3):
            cx = (c - 1) * w * 0.24
            mb.box((cx, y0 + 1.6, d * 0.5 + 0.7), (0.5, 3.2, 0.5), "stone")
        mb.box((0, y0 + 3.3, d * 0.5 + 0.7), (w * 0.72, 0.4, 1.2), "stone")

    door(mb, spec["door_x"] * w, y0, d * 0.5, 1.4, 2.5)

    for cx in (-w * 0.30, w * 0.30):
        chimney(mb, cx, y0 + h + spec["roof_h"] * 0.7, -d * 0.24, 2.0, 0.7, "brick")
    for i in range(spec["vents"]):
        mb.box(((i - 1) * w * 0.25, y0 + h + 0.85, -d * 0.08),
               (0.8, 0.9, 0.8), "metal")
    return mb


# ---------------------------------------------------------------------------
# Modern
# ---------------------------------------------------------------------------

def modern(spec):
    mb = MB()
    w, d = spec["width"], spec["depth"]
    floors, fh = spec["storeys"], spec["floor_h"]
    h = floors * fh
    y0 = 0.7

    mb.box((0, 0.35, 0), (w * 1.03, 0.7, d * 1.03), "concrete")
    mb.box((0, y0 + h * 0.5, 0), (w, h, d), spec["wall"])

    if spec["setback"]:
        mb.box((0, y0 + h + 1.4, 0), (w * 0.68, 2.8, d * 0.68), spec["wall"])
        top_y = y0 + h + 2.8
    else:
        top_y = y0 + h

    # Glazing bands.
    for s in range(floors):
        yy = y0 + fh * s + fh * 0.5
        for c in range(spec["cols"]):
            x = (c - (spec["cols"] - 1) * 0.5) * w / (spec["cols"] + 0.5)
            window(mb, "front", x, yy, d * 0.5, fh * 0.72, fh * 0.62,
                   frame="metal", glass="glass", sill=False)
            window(mb, "back", x, yy, -d * 0.5, fh * 0.72, fh * 0.62,
                   frame="metal", glass="glass", sill=False)

    if spec["balcony"]:
        for s in range(1, floors):
            by = y0 + fh * s
            mb.box((0, by + 0.1, d * 0.5 + 1.05), (w * 0.78, 0.20, 2.0),
                   "concrete")
            railing(mb, w * 0.75, by + 0.2, d * 0.5 + 2.0, "metal", 11)

    if spec["mullions"]:
        for i in range(spec["cols"] * 2 + 1):
            bx = -w * 0.45 + i * (w * 0.9 / (spec["cols"] * 2))
            mb.box((bx, y0 + h * 0.5, d * 0.5 + 0.12), (0.07, h * 0.9, 0.08),
                   "metal")

    mb.flat_roof(w, d, top_y, 0.6, "concrete")

    if spec["plant"]:
        mb.box((w * 0.22, top_y + 1.0, -d * 0.15), (2.4, 1.3, 2.0), "metal")
    if spec["penthouse"]:
        mb.box((-w * 0.22, top_y + 0.9, 0), (2.8, 1.6, 3.0), "concrete")

    door(mb, spec["door_x"] * w, y0, d * 0.5, 1.6, 2.8, frame="metal")
    mb.box((spec["door_x"] * w, y0 + 2.95, d * 0.5 + 0.85),
           (3.0, 0.22, 1.6), "concrete")
    return mb


# ---------------------------------------------------------------------------
# Information / future towers
# ---------------------------------------------------------------------------

def tower(spec):
    mb = MB()
    w, d = spec["width"], spec["depth"]
    floors, fh = spec["floors"], 3.0
    setback_floor = spec["setback_floor"]
    clad = spec.get("cladding", "concrete")

    base_y = 0.5
    if spec.get("podium"):
        ph = 4.2
        mb.box((0, base_y + ph * 0.5, 0), (w * 1.30, ph, d * 1.30), clad)
        mb.box((0, base_y + ph * 0.55, 0), (w * 1.31, ph * 0.55, d * 1.31), "glass")
        mb.box((0, base_y + ph * 0.97, 0), (w * 1.32, 0.30, d * 1.32), "metal")
        mb.box((0, base_y + ph * 0.72, 0), (w * 1.40, 0.24, d * 1.40), "metal")
        mb.box((0, base_y + ph * 0.86, d * 0.68), (w * 0.85, 0.65, 0.10), "planks")
        for i in range(3):
            mb.box((w * 0.30 * (i - 1), base_y + ph * 0.70, d * 0.69 + 0.35),
                   (w * 0.24, 0.08, 0.70),
                   ["brick", "tile", "planks"][i % 3])
            # Glazed shop bays with mullions and a sign above each.
            bx = w * 0.28 * (i - 1)
            mb.box((bx, base_y + 1.55, d * 0.66 - 0.10), (w * 0.18, 2.0, 0.12), "dark")
            for shelf in range(2):
                mb.box((bx, base_y + 1.10 + shelf * 0.72, d * 0.66 - 0.02),
                       (w * 0.16, 0.08, 0.26), "planks")
            mb.box((bx, base_y + 1.55, d * 0.66 + 0.14), (w * 0.19, 2.1, 0.12), "glass")
            for m in range(3):
                mb.box((bx + (m - 1) * w * 0.065, base_y + 1.55, d * 0.66 + 0.22),
                       (0.10, 2.1, 0.08), "metal")
            mb.box((bx, base_y + 2.95, d * 0.66 + 0.16), (w * 0.20, 0.45, 0.08),
                   ["brick", "planks", "tile"][i % 3])
            # Projecting sign on a bracket.
            mb.box((bx + w * 0.11, base_y + 2.95, d * 0.66 + 0.45),
                   (0.08, 0.08, 0.55), "metal")
            mb.box((bx + w * 0.11, base_y + 2.60, d * 0.66 + 0.70),
                   (0.06, 0.50, 0.60), ["planks", "brick", "metal"][i % 3])
        for side in (-1, 1):
            mb.box((side * w * 0.62, base_y + 0.40, d * 0.74), (0.9, 0.8, 0.9), "stone")
            mb.box((side * w * 0.62, base_y + 0.84, d * 0.74), (0.65, 0.22, 0.65), "turf")
        door(mb, 0, base_y, d * 0.65, 2.4, 3.4, frame="metal")
        base_y += ph
    else:
        mb.box((0, 0.5, 0), (w * 1.05, 1.0, d * 1.05), "concrete")

    y = base_y
    for f in range(floors):
        sw, sd = (w * 0.74, d * 0.74) if (setback_floor and f >= setback_floor) else (w, d)

        facade = spec.get("facade", "glass")

        if facade == "punched":
            mb.box((0, y + fh * 0.5, 0), (sw, fh, sd), clad)
            mb.box((0, y + fh * 0.97, 0), (sw * 1.02, 0.20, sd * 1.02), "concrete")
            cols = spec.get("window_cols", 3)
            for c in range(cols):
                ox = (c - (cols - 1) * 0.5) * sw / (cols + 0.4)
                window(mb, "front", ox, y + fh * 0.55, sd * 0.5, 1.7, fh * 0.52,
                       frame="metal", glass="glass", sill=False)
                window(mb, "back", ox, y + fh * 0.55, -sd * 0.5, 1.7, fh * 0.52,
                       frame="metal", glass="glass", sill=False)
            for c in range(max(cols - 1, 2)):
                oz = (c - (cols - 2) * 0.5) * sd / (cols + 0.4)
                window(mb, "right", sw * 0.5, y + fh * 0.55, oz, 1.7, fh * 0.52,
                       frame="metal", glass="glass", sill=False)
                window(mb, "left", -sw * 0.5, y + fh * 0.55, oz, 1.7, fh * 0.52,
                       frame="metal", glass="glass", sill=False)
        else:
            mb.box((0, y + fh * 0.5, 0), (sw * 0.96, fh, sd * 0.96), clad)
            band = 0.60 if facade == "glass" else 0.46
            mb.box((0, y + fh * 0.55, 0), (sw * 1.012, fh * band, sd * 1.012), "glass")
            mb.box((0, y + fh * 0.08, 0), (sw * 1.02, 0.24, sd * 1.02), "metal")
            mb.box((0, y + fh * 0.965, 0), (sw * 1.02, 0.20, sd * 1.02), "metal")

            for sx in (-1, 1):
                for sz in (-1, 1):
                    mb.box((sx * sw * 0.5, y + fh * 0.5, sz * sd * 0.5),
                           (0.24, fh, 0.24), "metal")

            if facade == "fins":
                for i in range(4):
                    fx = -sw * 0.5 + i * sw / 3
                    fz = -sd * 0.5 + i * sd / 3
                    mb.box((fx, y + fh * 0.5, sd * 0.5 + 0.14),
                           (0.14, fh * 0.96, 0.30), "metal")
                    mb.box((fx, y + fh * 0.5, -sd * 0.5 - 0.14),
                           (0.14, fh * 0.96, 0.30), "metal")
                    mb.box((sw * 0.5 + 0.14, y + fh * 0.5, fz),
                           (0.30, fh * 0.96, 0.14), "metal")
                    mb.box((-sw * 0.5 - 0.14, y + fh * 0.5, fz),
                           (0.30, fh * 0.96, 0.14), "metal")
            elif facade == "ribbon":
                for i in range(3):
                    px = (i - 1) * sw * 0.32
                    pz = (i - 1) * sd * 0.32
                    mb.box((px, y + fh * 0.5, sd * 0.5 + 0.10),
                           (0.42, fh * 0.92, 0.22), "concrete")
                    mb.box((px, y + fh * 0.5, -sd * 0.5 - 0.10),
                           (0.42, fh * 0.92, 0.22), "concrete")
                    mb.box((sw * 0.5 + 0.10, y + fh * 0.5, pz),
                           (0.22, fh * 0.92, 0.42), "concrete")
                    mb.box((-sw * 0.5 - 0.10, y + fh * 0.5, pz),
                           (0.22, fh * 0.92, 0.42), "concrete")

        if spec["balconies"] and f > 0 and f % spec["balcony_every"] == 0:
            mb.box((0, y + 0.16, sd * 0.5 + 0.95), (sw * 0.78, 0.18, 1.8), "concrete")
            railing(mb, sw * 0.74, y + 0.25, sd * 0.5 + 1.85, "metal", 13)

        y += fh

    top = y
    mb.flat_roof(w, d, top, 0.7, "concrete")
    mb.box((w * 0.18, top + 1.0, -d * 0.16), (3.0, 1.6, 2.6), "metal")

    if spec["crown"] == "spire":
        pyramid(mb, 0, 0, top, w * 0.68, d * 0.68, spec["crown_h"], "metal")
    elif spec["crown"] == "antenna":
        mb.box((0, top + spec["crown_h"] * 0.5, 0),
               (0.20, spec["crown_h"], 0.20), "metal")
        mb.box((0, top + 0.4, 0), (w * 0.40, 0.5, d * 0.40), "metal")
    elif spec["crown"] == "terrace":
        mb.box((0, top + 1.2, 0), (w * 0.88, 2.4, d * 0.88), "concrete")
        mb.box((0, top + 2.4, 0), (w * 0.58, 1.2, d * 0.58), "glass")
        mb.box((0, top + 3.0, 0), (w * 0.30, 0.8, d * 0.30), "metal")
    elif spec["crown"] == "lantern":
        mb.box((0, top + 2.0, 0), (w * 0.46, 4.0, d * 0.46), "glass")
        pyramid(mb, 0, 0, top + 4.0, w * 0.30, d * 0.30,
                max(spec["crown_h"] * 0.5, 3.0), "metal")

    if spec["terrace"]:
        mb.box((0, top + 0.9, d * 0.30), (w * 0.70, 1.5, 3.0), "glass")

    if spec.get("twin"):
        tw, td = w * 0.60, d * 0.60
        tfloors = max(3, int(floors * 0.62))
        tx = w * 0.92
        th = tfloors * fh
        mb.box((tx, base_y + th * 0.5, 0), (tw * 0.96, th, td * 0.96), clad)
        for f in range(tfloors):
            yy = base_y + f * fh
            mb.box((tx, yy + fh * 0.55, 0), (tw * 1.012, fh * 0.6, td * 1.012), "glass")
            mb.box((tx, yy + fh * 0.08, 0), (tw * 1.02, 0.22, td * 1.02), "metal")
            mb.box((tx, yy + fh * 0.965, 0), (tw * 1.02, 0.18, td * 1.02), "metal")
        mb.box((tx, base_y + th + 0.2, 0), (tw * 1.06, 0.4, td * 1.06), "concrete")
        # Skybridge between the shafts.
        by = base_y + max(3, int(floors * 0.55)) * fh
        mb.box((w * 0.46, by + 1.6, 0), (w * 0.55, 3.2, 2.4), "glass")
        mb.box((w * 0.46, by + 3.35, 0), (w * 0.56, 0.4, 2.6), "metal")

    if not spec.get("podium"):
        door(mb, 0, 0.5, d * 0.5, 2.2, 3.2, frame="metal")
    return mb


# ---------------------------------------------------------------------------
# Spec generation
# ---------------------------------------------------------------------------

def specs(era, rng):
    out = []
    if era == "classical":
        widths = [9.5, 11.0, 12.5, 14.0]
        depths = [8.0, 9.0, 10.0]
        for w in widths:
            for d in depths:
                for st in (1, 2, 3):
                    for roof in ("gable", "hip"):
                        for front in ("plain", "portico"):
                            out.append(dict(
                                width=w, depth=d, storeys=st,
                                floor_h=3.3 if st == 1 else 3.0,
                                roof=roof, frontage=front,
                                wall=rng.choice(["plaster", "plaster", "stone"]),
                                trim=rng.choice(["plaster", "marble"]),
                                roof_mat=rng.choice(["tile", "tile", "slate"]),
                                roof_h=3.0 + st * 0.2,
                                cols=rng.choice([2, 2, 3]),
                                shutters=rng.random() < 0.4,
                                quoins=rng.random() < 0.55,
                                pediments=rng.random() < 0.45,
                                balcony=rng.random() < 0.25,
                                door_x=rng.choice([-0.18, 0.0, 0.18]),
                                chimney_mat="brick"))
    elif era == "medieval":
        for w in (8.5, 10.0, 11.5, 13.0):
            for d in (8.0, 9.0):
                for st in (2, 3):
                    for roof in ("gable", "gable", "hip"):
                        for jetty in (True, False):
                            out.append(dict(
                                width=w, depth=d, storeys=st,
                                floor_h=3.8 if st == 2 else 3.1,
                                jetty=jetty,
                                wall=rng.choice(["plaster", "daub", "plaster"]),
                                roof_mat=rng.choice(["tile", "tile", "slate"]),
                                roof_h=4.6 + st * 0.3,
                                cols=2,
                                shopfront=rng.random() < 0.35,
                                canopy=rng.random() < 0.5,
                                sign=rng.random() < 0.35,
                                braces=rng.random() < 0.7,
                                dormer=rng.random() < 0.5,
                                door_x=rng.choice([-0.2, 0.0, 0.2])))
    elif era == "industrial":
        for w in (8.0, 9.5, 11.0):
            for d in (8.0, 9.0):
                for st in (2, 3, 4):
                    for roof in ("gable", "mansard"):
                        for front in ("plain", "shopfront"):
                            out.append(dict(
                                width=w, depth=d, storeys=st,
                                floor_h=2.9 if st >= 3 else 3.3,
                                roof=roof, roof_h=3.0 + st * 0.2,
                                wall="brick",
                                cols=2,
                                shopfront=(front == "shopfront"),
                                bay=rng.random() < 0.25,
                                arcade=rng.random() < 0.18,
                                vents=rng.choice([1, 1, 2]),
                                door_x=rng.choice([-0.2, 0.2])))
    elif era == "neolithic":
        for r in (3.2, 3.5, 3.8, 4.1):
            for wh in (2.2, 2.5, 2.8):
                for ap in (8.0, 9.0, 10.0):
                    for porch in (False, True):
                        out.append(dict(
                            radius=r, wall_h=wh, apex=ap,
                            eave=1.0 + (ap - 8.0) * 0.12,
                            eave_lift=-0.15,
                            posts=rng.choice([6, 7, 8]),
                            post_lift=0.4,
                            courses=rng.choice([5, 6, 6]),
                            door_deg=rng.choice([16, 18, 20]),
                            porch=porch and rng.random() < 0.4,
                            lean_to=rng.random() < 0.35))
    elif era == "bronze":
        for r in (4.0, 4.4, 4.8, 5.2):
            for wh in (2.8, 3.1, 3.4):
                for ap in (10.0, 11.2, 12.4):
                    for porch in (True, False):
                        out.append(dict(
                            radius=r, wall_h=wh, apex=ap,
                            eave=1.25, eave_lift=-0.1,
                            posts=rng.choice([8, 9, 10, 11]),
                            post_lift=0.55,
                            courses=rng.choice([6, 7, 8]),
                            door_deg=rng.choice([15, 17, 19]),
                            porch=porch,
                            lean_to=rng.random() < 0.45))
    elif era == "renaissance":
        for w in (10.0, 12.0, 14.0):
            for d in (9.0, 10.5):
                for st in (2, 3, 4):
                    for roof in ("hip", "mansard"):
                        out.append(dict(
                            width=w, depth=d, storeys=st, floor_h=3.1,
                            roof=roof, frontage=rng.choice(["plain", "portico"]),
                            wall=rng.choice(["plaster", "plaster", "stone"]),
                            trim="stone",
                            roof_mat=rng.choice(["slate", "tile"]),
                            roof_h=3.2 + st * 0.3,
                            cols=rng.choice([3, 3, 4]),
                            shutters=rng.random() < 0.3,
                            quoins=rng.random() < 0.75,
                            pediments=rng.random() < 0.5,
                            dormers=rng.random() < 0.65,
                            balcony=rng.random() < 0.45,
                            door_x=rng.choice([-0.15, 0.0, 0.15]),
                            chimney_mat="brick"))
    elif era == "information":
        for w in (8.0, 9.5, 11.0):
            for d in (8.0, 9.5):
                for floors in (4, 6, 8):
                    for setback in (0, rng.choice([3, 4, 5])):
                        out.append(dict(
                            width=w, depth=d, floors=floors,
                            setback_floor=setback,
                            balconies=rng.random() < 0.35,
                            balcony_every=rng.choice([2, 3]),
                            crown=rng.choice(["flat", "antenna", "terrace", "lantern"]),
                            crown_h=rng.choice([6.0, 8.0]),
                            terrace=rng.random() < 0.2,
                            podium=rng.random() < 0.55,
                            twin=(w <= 9.5 and rng.random() < 0.30),
                            cladding=rng.choice(["concrete", "concrete", "brick", "stone"]),
                            facade=rng.choice(["glass", "punched", "fins", "ribbon"]),
                            window_cols=rng.choice([3, 4])))
    elif era == "future":
        for w in (9.0, 10.5, 12.0):
            for d in (9.0, 10.5):
                for floors in (6, 9, 12):
                    for setback in (0, rng.choice([4, 6])):
                        out.append(dict(
                            width=w, depth=d, floors=floors,
                            setback_floor=setback,
                            balconies=rng.random() < 0.55,
                            balcony_every=rng.choice([2, 3]),
                            crown=rng.choice(["spire", "lantern", "terrace", "antenna"]),
                            crown_h=rng.choice([8.0, 11.0]),
                            terrace=rng.random() < 0.35,
                            podium=rng.random() < 0.5,
                            twin=(w <= 10.5 and rng.random() < 0.35),
                            cladding=rng.choice(["concrete", "stone", "metal", "brick"]),
                            facade=rng.choice(["fins", "ribbon", "glass", "punched"]),
                            window_cols=rng.choice([3, 4])))
    elif era == "modern":
        for w in (10.0, 12.0, 14.0):
            for d in (9.0, 10.5):
                for st in (2, 3, 4):
                    for roof in ("flat",):
                        for balc in (True, False):
                            out.append(dict(
                                width=w, depth=d, storeys=st,
                                floor_h=2.9,
                                wall=rng.choice(["concrete", "concrete", "plaster"]),
                                cols=rng.choice([2, 3]),
                                balcony=balc,
                                setback=rng.random() < 0.3,
                                mullions=rng.random() < 0.6,
                                plant=rng.random() < 0.6,
                                penthouse=rng.random() < 0.3,
                                door_x=rng.choice([-0.25, 0.0, 0.25])))
    rng.shuffle(out)
    return out[:COUNT]


# ---------------------------------------------------------------------------
# Blender plumbing
# ---------------------------------------------------------------------------

def atlas_material():
    mat = bpy.data.materials.new("Atlas")
    mat.use_nodes = True
    nodes = mat.node_tree.nodes
    nodes.clear()
    out = nodes.new("ShaderNodeOutputMaterial")
    bsdf = nodes.new("ShaderNodeBsdfPrincipled")
    tex = nodes.new("ShaderNodeTexImage")
    tex.image = bpy.data.images.load(
        os.path.join(ROOT, "Assets", "Buildings", "variants", "atlas-flipped.png"))
    mat.node_tree.links.new(bsdf.inputs["Base Color"], tex.outputs["Color"])
    mat.node_tree.links.new(out.inputs["Surface"], bsdf.outputs["BSDF"])
    return mat


def build_object(mb, name, location, material=None):
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
    obj.location = location
    if material is not None:
        mesh.materials.append(material)

    bm = bmesh.new()
    bm.from_mesh(mesh)
    bmesh.ops.triangulate(bm, faces=bm.faces)
    bm.to_mesh(mesh)
    bm.free()
    mesh.update()
    return obj


def export_object(obj, path):
    depsgraph = bpy.context.evaluated_depsgraph_get()
    eval_obj = obj.evaluated_get(depsgraph)
    eval_mesh = eval_obj.to_mesh()
    uv_layer = eval_mesh.uv_layers.active
    eval_mesh.calc_loop_triangles()

    vbuf = bytearray()
    ibuf = bytearray()
    vc = 0
    ic = 0
    mins = [1e9, 1e9, 1e9]
    maxs = [-1e9, -1e9, -1e9]

    try:
        normals = eval_mesh.corner_normals
        use_corner = True
    except AttributeError:
        use_corner = False

    for tri in eval_mesh.loop_triangles:
        for li in tri.loops:
            p = eval_mesh.vertices[eval_mesh.loops[li].vertex_index].co
            x, y, z = p.x, p.z, -p.y
            n = normals[li].vector if use_corner else tri.normal
            nx, ny, nz = n.x, n.z, -n.y
            u, v = uv_layer.data[li].uv
            vbuf += struct.pack("<8f", x, y, z, nx, ny, nz, u, v)
            vc += 1
            mins[0] = min(mins[0], x); mins[1] = min(mins[1], y); mins[2] = min(mins[2], z)
            maxs[0] = max(maxs[0], x); maxs[1] = max(maxs[1], y); maxs[2] = max(maxs[2], z)
        for _ in tri.loops:
            ibuf += struct.pack("<I", ic)
            ic += 1

    data = bytearray()
    data += struct.pack("<4sII", b"CIVM", 1, vc)
    data += struct.pack("<I", ic)
    data += struct.pack("<6f", mins[0], mins[1], mins[2], maxs[0], maxs[1], maxs[2])
    data += vbuf
    data += ibuf
    with open(path, "wb") as f:
        f.write(data)

    eval_obj.to_mesh_clear()
    return {"triangles": ic // 3, "min": mins, "max": maxs}


def contact_sheet(objects, path, era, max_h=14.0, spacing=20.0):
    from mathutils import Vector

    scene = bpy.context.scene
    scene.render.engine = "BLENDER_WORKBENCH"
    scene.render.resolution_x = 2400
    scene.render.resolution_y = 1800
    scene.render.film_transparent = False
    scene.display.shading.light = "FLAT"
    scene.display.shading.show_cavity = True
    scene.display.shading.cavity_type = "WORLD"
    scene.display.shading.color_type = "TEXTURE"
    scene.display.shading.show_shadows = False
    scene.display.shading.background_type = "VIEWPORT"
    scene.display.shading.background_color = (0.86, 0.86, 0.84)

    cam_data = bpy.data.cameras.new("Cam")
    cam = bpy.data.objects.new("Cam", cam_data)
    bpy.context.collection.objects.link(cam)
    cam_data.type = "ORTHO"
    # Fit the whole 6x5 grid, not just the tallest model.
    ortho = max(150.0, spacing * 6 * 1.12, spacing * 5 * 1.04)
    cam_data.ortho_scale = ortho
    cam.location = (ortho * 0.95, -ortho * 1.35, ortho * 0.85)
    target = Vector((0, 0, max_h * 0.45))
    direction = target - cam.location
    cam.rotation_euler = direction.to_track_quat("-Z", "Y").to_euler()
    scene.camera = cam
    scene.render.filepath = path
    bpy.ops.render.render(write_still=True)
    bpy.data.objects.remove(cam, do_unlink=True)


def main():
    os.makedirs(OUT, exist_ok=True)
    bpy.ops.wm.read_factory_settings(use_empty=True)

    manifest = []
    material = atlas_material()
    builders = {
        "classical": classical,
        "medieval": medieval,
        "industrial": industrial,
        "modern": modern,
        "neolithic": hut,
        "bronze": hut,
        "renaissance": classical,
        "information": tower,
        "future": tower,
    }

    for era, build in builders.items():
        rng = random.Random(0xC0FFEE ^ sum(ord(c) for c in era))
        spec_list = specs(era, rng)
        built = [(build(spec), spec) for spec in spec_list]
        max_h = max(max(v[1] for v in mb.v) for mb, _ in built)

        cols = 6
        spacing = max(18.0, max_h * 1.30)
        spacing_x, spacing_z = spacing, spacing * 1.05
        objects = []

        for i, (mb, spec) in enumerate(built):
            col = i % cols
            row = i // cols
            x = (col - (cols - 1) * 0.5) * spacing_x
            z = (2 - row) * spacing_z
            name = f"{era}-{i + 1:02d}"
            obj = build_object(mb, name, (x, z, 0), material)
            objects.append(obj)

            path = os.path.join(OUT, name + ".civmesh")
            info = export_object(obj, path)
            manifest.append({"era": era, "name": name, "spec": spec, **info})

        sheet = os.path.join(OUT, f"{era}-variants.png")
        contact_sheet(objects, sheet, era, max_h, spacing)
        print("sheet", sheet)

        for obj in objects:
            mesh = obj.data
            bpy.data.objects.remove(obj, do_unlink=True)
            bpy.data.meshes.remove(mesh)

    with open(os.path.join(OUT, "manifest.json"), "w") as f:
        json.dump(manifest, f, indent=2)

    print("variants:", len(manifest))


if __name__ == "__main__":
    main()
