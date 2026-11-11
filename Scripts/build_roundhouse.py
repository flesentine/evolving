#!/usr/bin/env python3
"""Builds the Bronze Age roundhouse in Blender and exports a .civmesh.

Reference: Butser Ancient Farm's Dunch Hill roundhouse (1300-1000 BCE) and the
Beeston Castle reconstruction — low daub wall on a rubble footing, a ring of
exposed oak posts, a big layered thatch cone with a swept eave, and a dark
porch opening.

Run headless:

    /Applications/Blender.app/Contents/MacOS/Blender -b \
        --python Scripts/build_roundhouse.py

Outputs:
    Assets/BronzeHouse/roundhouse.civmesh
    Assets/BronzeHouse/roundhouse.blend
"""

import bpy
import bmesh
import math
import os
import struct

TAU = math.pi * 2
SEG = 24

ATLAS = 2048.0
ISLANDS = {
    # 4x4 grid of 512 px islands, top-left origin.
    "thatch": 0, "daub": 1, "stone": 2, "oak": 3,
    "door": 4, "brick": 5, "slate": 6, "tile": 7,
    "plaster": 8, "glass": 9, "concrete": 10, "metal": 11,
    "dark": 12, "marble": 13, "planks": 14, "turf": 15,
}
CELL = 512
MARGIN = 0.020

# House dimensions, in decimetres (export scale 0.001 -> world units).
WALL_R = 4.55
WALL_H = 3.45
EAVE_R = 5.95
EAVE_H = 4.05
APEX_H = 11.4
FOOT_R = 4.85
FOOT_H = 0.55
DOOR_HALF = math.radians(14.0)
DOOR_H = 2.75
DOOR_W = 1.55
PORCH_R = 5.35

verts = []
faces = []   # (indices, uvs, smooth)


def uv_of(island, s, t):
    idx = ISLANDS[island]
    col = idx % 4
    row = idx // 4
    m = MARGIN
    s = m + s * (1 - 2 * m)
    t = m + t * (1 - 2 * m)
    return ((col * CELL + s * CELL) / ATLAS,
            (row * CELL + t * CELL) / ATLAS)


def add_face(indices, uvs, smooth=False):
    assert len(indices) == len(uvs) and len(indices) >= 3
    faces.append((indices, uvs, smooth))


def quad(a, b, c, d, uv_a, uv_b, uv_c, uv_d, smooth=False):
    base = len(verts)
    verts.extend([a, b, c, d])
    add_face([base, base + 1, base + 2, base + 3],
             [uv_a, uv_b, uv_c, uv_d], smooth)


def tri(a, b, c, uv_a, uv_b, uv_c, smooth=False):
    base = len(verts)
    verts.extend([a, b, c])
    add_face([base, base + 1, base + 2], [uv_a, uv_b, uv_c], smooth)


def ring(radius, y, segments=SEG, phase=0.0):
    return [(math.cos(phase + TAU * i / segments) * radius,
             math.sin(phase + TAU * i / segments) * radius,
             y) for i in range(segments)]


def cylinder(radius, y0, y1, segments, island, u_scale=1.0, v_scale=1.0,
             smooth=True, invert=False):
    lo = ring(radius, y0, segments)
    hi = ring(radius, y1, segments)
    for i in range(segments):
        j = (i + 1) % segments
        u0 = (i / segments) * u_scale
        u1 = ((i + 1) / segments) * u_scale
        a, b, c, d = lo[i], lo[j], hi[j], hi[i]
        uv_a = uv_of(island, u0, v_scale)
        uv_b = uv_of(island, u1, v_scale)
        uv_c = uv_of(island, u1, 0)
        uv_d = uv_of(island, u0, 0)
        if invert:
            quad(d, c, b, a, uv_d, uv_c, uv_b, uv_a, smooth)
        else:
            quad(a, b, c, d, uv_a, uv_b, uv_c, uv_d, smooth)


def stone_footing():
    outer = ring(FOOT_R, 0.0, SEG)
    outer_top = ring(FOOT_R, FOOT_H, SEG)
    inner = ring(WALL_R - 0.05, 0.0, SEG)
    inner_top = ring(WALL_R - 0.05, FOOT_H, SEG)
    for i in range(SEG):
        j = (i + 1) % SEG
        u0 = i / SEG
        u1 = (i + 1) / SEG
        # Outer face.
        quad(outer[i], outer[j], outer_top[j], outer_top[i],
             uv_of("stone", u0, 1), uv_of("stone", u1, 1),
             uv_of("stone", u1, 0.55), uv_of("stone", u0, 0.55))
        # Top.
        quad(outer_top[i], outer_top[j], inner_top[j], inner_top[i],
             uv_of("stone", u0, 0.55), uv_of("stone", u1, 0.55),
             uv_of("stone", u1, 0.35), uv_of("stone", u0, 0.35))
        # Inner face (visible as the footing behind the wall).
        quad(inner[i], inner_top[i], inner_top[j], inner[j],
             uv_of("stone", u0, 1), uv_of("stone", u0, 0.55),
             uv_of("stone", u1, 0.55), uv_of("stone", u1, 1))


def daub_wall():
    # Front gap for the door, centred on -Y.
    gap_centre = -math.pi / 2
    start = gap_centre + DOOR_HALF
    end = gap_centre - DOOR_HALF + TAU
    steps = SEG
    for i in range(steps):
        a0 = start + (end - start) * i / steps
        a1 = start + (end - start) * (i + 1) / steps
        x0, y0 = math.cos(a0) * WALL_R, math.sin(a0) * WALL_R
        x1, y1 = math.cos(a1) * WALL_R, math.sin(a1) * WALL_R
        u0 = i / steps
        u1 = (i + 1) / steps
        quad((x0, y0, FOOT_H), (x1, y1, FOOT_H),
             (x1, y1, WALL_H + FOOT_H), (x0, y0, WALL_H + FOOT_H),
             uv_of("daub", u0, 1), uv_of("daub", u1, 1),
             uv_of("daub", u1, 0), uv_of("daub", u0, 0), smooth=True)

    # Door jambs, both faces.
    for sign in (-1.0, 1.0):
        a = gap_centre + sign * DOOR_HALF
        p0 = (math.cos(a) * (WALL_R - 0.12), math.sin(a) * (WALL_R - 0.12), FOOT_H)
        p1 = (math.cos(a) * (WALL_R + 0.10), math.sin(a) * (WALL_R + 0.10), FOOT_H)
        p2 = (p1[0], p1[1], FOOT_H + DOOR_H)
        p3 = (p0[0], p0[1], FOOT_H + DOOR_H)
        quad(p0, p1, p2, p3,
             uv_of("oak", 0.0, 1), uv_of("oak", 0.12, 1),
             uv_of("oak", 0.12, 0), uv_of("oak", 0.0, 0), smooth=False)

    # Interior shell, dark, facing inward.
    interior = cylinder(WALL_R - 0.16, FOOT_H, WALL_H + FOOT_H, SEG,
                        "dark", u_scale=1.0, v_scale=1.0,
                        smooth=True, invert=True)
    del interior

    # Floor.
    floor = ring(WALL_R - 0.10, FOOT_H + 0.01, SEG)
    for i in range(SEG):
        j = (i + 1) % SEG
        tri((0, 0, FOOT_H + 0.01), floor[i], floor[j],
            uv_of("dark", 0.5, 0.5), uv_of("dark", 0.2, 0.8),
            uv_of("dark", 0.8, 0.8))


def timber_posts():
    # Ring of wall posts, skipping the doorway.
    count = 10
    gap_centre = -math.pi / 2
    for i in range(count):
        a = TAU * i / count
        delta = abs(((a - gap_centre + math.pi) % TAU) - math.pi)
        if delta < DOOR_HALF + 0.12:
            continue
        x, y = math.cos(a) * (WALL_R + 0.06), math.sin(a) * (WALL_R + 0.06)
        post(x, y, WALL_H + FOOT_H + 0.55, 0.20, lean=0.05)

    # Porch posts, thicker, standing proud of the eave.
    for sign in (-1.0, 1.0):
        a = gap_centre + sign * math.radians(34.0)
        x, y = math.cos(a) * PORCH_R, math.sin(a) * PORCH_R
        post(x, y, EAVE_H - 0.10, 0.30, lean=0.0)

    # Lintel across the porch, sitting under the eave.
    a0 = gap_centre - math.radians(34.0)
    a1 = gap_centre + math.radians(34.0)
    p0 = (math.cos(a0) * PORCH_R, math.sin(a0) * PORCH_R, EAVE_H - 1.35)
    p1 = (math.cos(a1) * PORCH_R, math.sin(a1) * PORCH_R, EAVE_H - 1.35)
    beam(p0, p1, 0.22, 0.26)


def post(x, y, height, radius, lean):
    segments = 8
    lo = []
    hi = []
    for i in range(segments):
        a = TAU * i / segments
        lo.append((x + math.cos(a) * radius, y + math.sin(a) * radius, 0.0))
        hi.append((x + math.cos(a) * radius * 0.86 + lean,
                   y + math.sin(a) * radius * 0.86, height))
    for i in range(segments):
        j = (i + 1) % segments
        u0 = i / segments
        u1 = (i + 1) / segments
        quad(lo[i], lo[j], hi[j], hi[i],
             uv_of("oak", u0, 1), uv_of("oak", u1, 1),
             uv_of("oak", u1, 0), uv_of("oak", u0, 0), smooth=True)
    # Cap.
    top = (x + lean, y, height)
    for i in range(segments):
        j = (i + 1) % segments
        tri(top, hi[i], hi[j],
            uv_of("oak", 0.5, 0.05), uv_of("oak", i / segments, 0.2),
            uv_of("oak", (i + 1) / segments, 0.2))


def beam(p0, p1, width, height):
    dx, dy = p1[0] - p0[0], p1[1] - p0[1]
    length = math.hypot(dx, dy)
    nx, ny = -dy / length * width * 0.5, dx / length * width * 0.5
    z0, z1 = p0[2], p0[2] + height
    a = (p0[0] - nx, p0[1] - ny, z0)
    b = (p1[0] - nx, p1[1] - ny, z0)
    c = (p1[0] + nx, p1[1] + ny, z0)
    d = (p0[0] + nx, p0[1] + ny, z0)
    a2 = (a[0], a[1], z1)
    b2 = (b[0], b[1], z1)
    c2 = (c[0], c[1], z1)
    d2 = (d[0], d[1], z1)
    quad(a2, b2, c2, d2, uv_of("oak", 0, 0.2), uv_of("oak", 1, 0.2),
         uv_of("oak", 1, 0.8), uv_of("oak", 0, 0.8))
    quad(a, d, d2, a2, uv_of("oak", 0, 1), uv_of("oak", 1, 1),
         uv_of("oak", 1, 0.8), uv_of("oak", 0, 0.8))
    quad(b, c, c2, b2, uv_of("oak", 0, 1), uv_of("oak", 1, 1),
         uv_of("oak", 1, 0.8), uv_of("oak", 0, 0.8))


def thatch_roof():
    # Profile of the layered cone. Each course ends in an overhanging lip,
    # which is what gives thatch its stepped silhouette.
    courses = 7
    profile = [(EAVE_H - 0.12, EAVE_R + 0.32),
               (EAVE_H + 0.10, EAVE_R + 0.10)]
    for i in range(1, courses + 1):
        t = i / courses
        h = EAVE_H + (APEX_H - EAVE_H) * t
        r = max(0.24, EAVE_R * (1.0 - 0.90 * t))
        profile.append((h - 0.04, r))
        profile.append((h + 0.02, r + 0.15))
    profile.append((APEX_H, 0.16))

    rings = []
    for (h, r) in profile:
        rings.append((h, ring(r, h, SEG)))

    for i in range(len(profile) - 1):
        h0, r0ring = rings[i]
        h1, r1ring = rings[i + 1]
        v0 = i / (len(profile) - 1)
        v1 = (i + 1) / (len(profile) - 1)
        for s in range(SEG):
            t = (s + 1) % SEG
            u0 = s / SEG
            u1 = (s + 1) / SEG
            quad(r0ring[s], r0ring[t], r1ring[t], r1ring[s],
                 uv_of("thatch", u0, v0), uv_of("thatch", u1, v0),
                 uv_of("thatch", u1, v1), uv_of("thatch", u0, v1),
                 smooth=True)

    # Rachis / thatch bundle at the peak.
    peak_base = ring(0.22, APEX_H - 0.35, 8)
    for i in range(8):
        j = (i + 1) % 8
        tri((0, 0, APEX_H + 0.55), peak_base[i], peak_base[j],
            uv_of("thatch", 0.5, 0.02),
            uv_of("thatch", i / 8, 0.12),
            uv_of("thatch", (i + 1) / 8, 0.12))

    # Inner ceiling: a dark cone just inside the thatch, so looking under the
    # eave shows a roof interior rather than the sky beyond.
    inner = []
    for (h, r) in profile[2:]:
        inner.append((h, ring(max(r * 0.93, 0.1), h - 0.12, SEG)))
    for i in range(len(inner) - 1):
        for s in range(SEG):
            t = (s + 1) % SEG
            u0 = s / SEG
            u1 = (s + 1) / SEG
            quad(inner[i][1][t], inner[i][1][s],
                 inner[i + 1][1][s], inner[i + 1][1][t],
                 uv_of("dark", u0, 0.2), uv_of("dark", u1, 0.2),
                 uv_of("dark", u1, 0.8), uv_of("dark", u0, 0.8))

    # Under-eave: a ring of thatch underside so the roof has thickness.
    for s in range(SEG):
        t = (s + 1) % SEG
        u0 = s / SEG
        u1 = (s + 1) / SEG
        p0 = rings[0][1][s]
        p1 = rings[0][1][t]
        q0 = (p0[0] * 0.86, p0[1] * 0.86, EAVE_H + 0.18)
        q1 = (p1[0] * 0.86, p1[1] * 0.86, EAVE_H + 0.18)
        quad(p1, p0, q0, q1,
             uv_of("dark", u0, 1), uv_of("dark", u1, 1),
             uv_of("dark", u1, 0), uv_of("dark", u0, 0))


def door_and_threshold():
    # Stone threshold.
    a0 = -math.pi / 2 - DOOR_HALF
    a1 = -math.pi / 2 + DOOR_HALF
    p0 = (math.cos(a0) * (WALL_R + 0.35), math.sin(a0) * (WALL_R + 0.35), 0.0)
    p1 = (math.cos(a1) * (WALL_R + 0.35), math.sin(a1) * (WALL_R + 0.35), 0.0)
    p2 = (p1[0], p1[1], 0.30)
    p3 = (p0[0], p0[1], 0.30)
    quad(p0, p1, p2, p3,
         uv_of("stone", 0.0, 0.5), uv_of("stone", 0.4, 0.5),
         uv_of("stone", 0.4, 0.35), uv_of("stone", 0.0, 0.35))

    # Closed plank door, set a little inside the opening.
    ang = -math.pi / 2
    cx, cy = math.cos(ang) * WALL_R, math.sin(ang) * WALL_R
    tx, ty = -math.sin(ang), math.cos(ang)
    nx, ny = math.cos(ang), math.sin(ang)
    w = 2.0 * (WALL_R - 0.18) * math.sin(DOOR_HALF) - 0.06
    t = 0.10

    def P(u, v, out):
        return (cx + tx * u - nx * (0.10 + out),
                cy + ty * u - ny * (0.10 + out),
                FOOT_H + v)

    # Front (facing out of the house).
    quad(P(-w / 2, 0, 0), P(w / 2, 0, 0), P(w / 2, DOOR_H, 0), P(-w / 2, DOOR_H, 0),
         uv_of("door", 0, 1), uv_of("door", 1, 1),
         uv_of("door", 1, 0), uv_of("door", 0, 0))
    # Back.
    quad(P(w / 2, 0, t), P(-w / 2, 0, t), P(-w / 2, DOOR_H, t), P(w / 2, DOOR_H, t),
         uv_of("door", 0, 1), uv_of("door", 1, 1),
         uv_of("door", 1, 0), uv_of("door", 0, 0))
    # Edges.
    quad(P(-w / 2, 0, 0), P(-w / 2, 0, t), P(-w / 2, DOOR_H, t), P(-w / 2, DOOR_H, 0),
         uv_of("door", 0, 1), uv_of("door", 1, 1),
         uv_of("door", 1, 0), uv_of("door", 0, 0))
    quad(P(w / 2, 0, t), P(w / 2, 0, 0), P(w / 2, DOOR_H, 0), P(w / 2, DOOR_H, t),
         uv_of("door", 0, 1), uv_of("door", 1, 1),
         uv_of("door", 1, 0), uv_of("door", 0, 0))
    quad(P(-w / 2, DOOR_H, 0), P(w / 2, DOOR_H, 0), P(w / 2, DOOR_H, t), P(-w / 2, DOOR_H, t),
         uv_of("door", 0, 0), uv_of("door", 1, 0),
         uv_of("door", 1, 1), uv_of("door", 0, 1))
    quad(P(-w / 2, 0, t), P(w / 2, 0, t), P(w / 2, 0, 0), P(-w / 2, 0, 0),
         uv_of("door", 0, 0), uv_of("door", 1, 0),
         uv_of("door", 1, 1), uv_of("door", 0, 1))


def build():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    stone_footing()
    daub_wall()
    timber_posts()
    thatch_roof()
    door_and_threshold()

    mesh = bpy.data.meshes.new("RoundhouseMesh")
    mesh.from_pydata(verts, [], [f[0] for f in faces])
    mesh.update()

    uv_layer = mesh.uv_layers.new(name="UVMap")
    loop = 0
    for indices, uvs, smooth in faces:
        for (u, v) in uvs:
            uv_layer.data[loop].uv = (u, v)
            loop += 1
    for poly, (indices, uvs, smooth) in zip(mesh.polygons, faces):
        poly.use_smooth = smooth
    mesh.update()
    mesh.validate()

    obj = bpy.data.objects.new("Roundhouse", mesh)
    bpy.context.collection.objects.link(obj)

    # Recalculate outward normals and triangulate.
    bm = bmesh.new()
    bm.from_mesh(mesh)
    # Winding is authored outward; recalculating here flips the open cone and
    # the wall inward, which makes the roof disappear.
    bmesh.ops.triangulate(bm, faces=bm.faces)
    bm.to_mesh(mesh)
    bm.free()
    mesh.update()

    # A material pointing at the atlas, for editing in Blender.
    mat = bpy.data.materials.new("RoundhouseAtlas")
    mat.use_nodes = True
    nodes = mat.node_tree.nodes
    nodes.clear()
    output = nodes.new("ShaderNodeOutputMaterial")
    bsdf = nodes.new("ShaderNodeBsdfPrincipled")
    tex = nodes.new("ShaderNodeTexImage")
    here = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    tex.image = bpy.data.images.load(os.path.join(here, "Assets", "Buildings",
                                                  "buildings-atlas.png"))
    mat.node_tree.links.new(bsdf.inputs["Base Color"], tex.outputs["Color"])
    mat.node_tree.links.new(output.inputs["Surface"], bsdf.outputs["BSDF"])
    mesh.materials.append(mat)

    return obj


def export(obj):
    here = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    out = os.path.join(here, "Assets", "Buildings", "roundhouse.civmesh")

    depsgraph = bpy.context.evaluated_depsgraph_get()
    mesh = obj.evaluated_get(depsgraph).to_mesh()

    uv_layer = mesh.uv_layers.active
    mesh.calc_loop_triangles()

    data = bytearray()
    vertex_count = 0
    index_count = 0
    vbuf = bytearray()
    ibuf = bytearray()
    mins = [1e9, 1e9, 1e9]
    maxs = [-1e9, -1e9, -1e9]

    try:
        corner_normals = mesh.corner_normals
        use_corner = True
    except AttributeError:
        use_corner = False

    for tri in mesh.loop_triangles:
        for li in tri.loops:
            v = mesh.vertices[mesh.loops[li].vertex_index]
            p = v.co
            # Blender Z-up -> renderer Y-up. Blender -Y becomes +Z.
            x, y, z = p.x, p.z, -p.y
            if use_corner:
                n = corner_normals[li].vector
            else:
                n = tri.normal
            nx, ny, nz = n.x, n.z, -n.y
            uv = uv_layer.data[li].uv
            vbuf += struct.pack("<8f", x, y, z, nx, ny, nz, uv.x, uv.y)
            vertex_count += 1
            mins[0] = min(mins[0], x); mins[1] = min(mins[1], y); mins[2] = min(mins[2], z)
            maxs[0] = max(maxs[0], x); maxs[1] = max(maxs[1], y); maxs[2] = max(maxs[2], z)
        for li in tri.loops:
            ibuf += struct.pack("<I", index_count)
            index_count += 1

    data += struct.pack("<4sII", b"CIVM", 1, vertex_count)
    data += struct.pack("<I", index_count)
    data += struct.pack("<6f", mins[0], mins[1], mins[2], maxs[0], maxs[1], maxs[2])
    data += vbuf
    data += ibuf

    with open(out, "wb") as f:
        f.write(data)

    print("wrote", out)
    print("  vertices", vertex_count, "triangles", index_count // 3)
    print("  bounds", mins, maxs)


if __name__ == "__main__":
    obj = build()
    export(obj)
    here = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    bpy.ops.wm.save_as_mainfile(filepath=os.path.join(here, "Assets", "BronzeHouse",
                                                      "roundhouse.blend"))
