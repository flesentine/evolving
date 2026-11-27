"""Create the editable long barrow, with the chamber opening toward +Z."""
import math
from pathlib import Path
import sys

import bpy
from mathutils import Vector

sys.path.insert(0, str(Path(__file__).resolve().parent))
from author_neolithic_people import patch
from build_buildings import MB
from build_variants import atlas_material, build_object

ROOT = Path(__file__).resolve().parents[1]


def face(mesh, corners, normal, tile):
    tex = [patch(tile, u, v) for u, v in ((0, 0), (1, 0), (1, 1), (0, 1))]
    mesh.quad_out(*corners, normal, *tex)


def slab(mesh, centre, size, turn, style):
    """Chamfered, individually dressed slabs with irregular shoulders."""
    cx, cy, cz = centre
    hx, hy, hz = [value / 2 for value in size]
    outline = [(-.8, -1), (.69, -1), (1, -.70), (1, .59),
               (.72, 1), (-.63, 1), (-1, .56), (-1, -.67)]
    sn, co = math.sin(turn), math.cos(turn)
    rings = []
    for level, scale in ((-1, .89), (-.68, 1), (.65, .92), (1, .72)):
        row = []
        for i, (x, z) in enumerate(outline):
            jitter = .055 * math.sin(i * 2.4 + style * 1.83)
            px = x * hx * (scale + jitter) + level * hx * .09
            pz = z * hz * (scale - jitter)
            dy = .07 * math.sin(i * 1.81 + style) if level > .6 else 0
            row.append((cx + px * co + pz * sn, cy + hy * (level + dy),
                        cz - px * sn + pz * co))
        rings.append(row)
    tile = "plaster" if style % 4 == 0 else "concrete"
    for low, high in zip(rings, rings[1:]):
        for i, a in enumerate(low):
            j = (i + 1) % len(outline)
            b = low[j]
            normal = ((a[0] + b[0]) / 2 - cx, 0, (a[2] + b[2]) / 2 - cz)
            face(mesh, [a, b, high[j], high[i]], normal, tile)
    for row, sign in ((rings[0], -1), (rings[-1], 1)):
        for i in range(1, len(row) - 1):
            mesh.tri_out(row[0], row[i], row[i + 1], (0, sign, 0),
                         patch(tile, 0, 0), patch(tile, 1, 0), patch(tile, .5, 1))


def mound():
    mesh = MB()
    fractions = (-1, -.76, -.50, -.30, -.18, 0, .18, .30, .50, .76, 1)
    # (distance along the mound, half width, crown height).
    profiles = [(-15.1, .30, -.28), (-14.0, 1.56, .44), (-12.3, 2.48, 1.25),
                (-9.4, 3.28, 1.79), (-5.5, 3.81, 2.18), (-1.4, 4.25, 2.42),
                (2.9, 4.66, 2.62), (6.7, 4.94, 2.70), (9.1, 5.02, 2.68),
                (11.1, 5.04, 2.54)]
    rings = []
    for index, (z, width, crest) in enumerate(profiles):
        row = []
        for column, t in enumerate(fractions):
            curve = max(0, math.cos(t * math.pi / 2)) ** .92
            raised = -.65 + (crest + .65) * curve
            relief = math.sin(column * 2.1 + index * 1.5) * .09 * curve
            dx = math.sin(index * .68) * .22 if index < len(profiles)-1 else 0
            dz = math.sin(column * 1.29 + index * .84) * .23 if 0 < index < len(profiles)-1 else 0
            row.append((t * width + dx, raised + relief, z + dz))
        rings.append(row)
    for row, next_row in zip(rings, rings[1:]):
        for i in range(len(fractions) - 1):
            face(mesh, [row[i], next_row[i], next_row[i+1], row[i+1]], (0, 1, 0), "turf")
    for index, side in ((0, -1), (len(rings)-1, 1)):
        row = rings[index]
        for i, (a, b) in enumerate(zip(row, row[1:])):
            # Leave a real passage opening between the jambs.
            base = 1.62 if side == 1 and i in (4, 5) else -.66
            face(mesh, [(a[0], base, a[2]), (b[0], base, b[2]), b, a], (0, 0, side), "daub")

    # Recessed opening, including shaded returns and a back wall.
    face(mesh, [(-.96,-.62,8.85),(.96,-.62,8.85),(.96,1.63,8.85),(-.96,1.63,8.85)],
         (0,0,1), "dark")
    for sign in (-1, 1):
        x = sign * .96
        face(mesh, [(x,-.63,8.85),(x,-.63,11.13),(x,1.65,11.13),(x,1.65,8.85)],
             (-sign,0,0), "slate")
        slab(mesh, (sign * 1.08,.66,11.29), (.67,2.54,.87), sign * .13, 4 + sign)
    face(mesh, [(-.96,1.65,8.85),(.96,1.65,8.85),(.96,1.65,11.13),(-.96,1.65,11.13)],
         (0,-1,0), "slate")
    slab(mesh, (0,1.86,11.26), (2.96,.47,1.02), -.05, 8)

    # Low flanking walls step out towards the forecourt.
    for sign in (-1, 1):
        for i in range(6):
            x = sign * (1.55 + i * .58)
            z = 11.36 + i * .25
            slab(mesh, (x,-.11,z), (.77,1.08,.94), sign * -.32, i)
            if i < 5:
                slab(mesh, (x+sign*.055,.56-i*.045,z-.04), (.73,.50,.77), sign * -.31, i+5)
        slab(mesh, (sign*4.70,-.11,12.95), (.85,1.08,1.09), sign * -.41, 11)
    return mesh


def smooth_turf(obj):
    """Average normals across the unwelded turf triangles only."""
    mesh = obj.data
    uv = mesh.uv_layers.active.data
    turf = [face for face in mesh.polygons if all(
        uv[index].uv.x > .75 and uv[index].uv.y > .75 for index in face.loop_indices)]
    normals = {}
    for face in turf:
        face.use_smooth = True
        for vertex in face.vertices:
            key = tuple(mesh.vertices[vertex].co)
            if key not in normals:
                normals[key] = Vector()
            normals[key] += face.normal * face.area
    loops = [Vector() for _ in mesh.loops]
    for face in turf:
        for index in face.loop_indices:
            point = mesh.vertices[mesh.loops[index].vertex_index].co
            loops[index] = normals[tuple(point)].normalized()
    mesh.normals_split_custom_set(loops)


def main():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    scene = bpy.context.scene
    scene.unit_settings.system = "METRIC"
    scene.unit_settings.length_unit = "METERS"
    collection = bpy.data.collections.new("Evolving Neolithic Exports")
    scene.collection.children.link(collection)
    bpy.context.view_layer.active_layer_collection = bpy.context.view_layer.layer_collection.children[collection.name]
    atlas = atlas_material()
    barrow = build_object(mound(), "neolithic-long-barrow", (0, 0, 0), atlas)
    smooth_turf(barrow)
    bpy.data.images.get("atlas-flipped.png").filepath = "//../Buildings/variants/atlas-flipped.png"
    for screen in bpy.data.screens:
        for area in screen.areas:
            if area.type == "VIEW_3D":
                space = area.spaces.active
                space.shading.color_type = "TEXTURE"
                space.region_3d.view_distance = 36
                space.region_3d.view_location = (0, 0, .6)
    bpy.ops.wm.save_as_mainfile(filepath=str(ROOT / "Assets/Neolithic/long-barrow.blend"),
                               relative_remap=False, compress=True)


if __name__ == "__main__":
    main()
