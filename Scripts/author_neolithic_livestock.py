"""Build editable livestock meshes in metres with the muzzle facing +Z."""
import math
import sys
from pathlib import Path

import bpy

sys.path.insert(0, str(Path(__file__).resolve().parent))
from build_buildings import MB, uv as atlas_uv
from build_variants import atlas_material, build_object

ROOT = Path(__file__).resolve().parents[1]
COLLECTION = "Evolving Neolithic Exports"


def uv(tile, u, v):
    # Sample a small patch of each shared tile so the coats retain subtle
    # variation without visible board seams, joints, or overscale grain.
    x, y = (0.39, 0.54) if tile == "planks" else (0.52, 0.52)
    return atlas_uv(tile, x + (u - 0.5) * 0.07, y + (v - 0.5) * 0.15)


def ellipsoid(mesh, centre, radii, tile, rings=7, sides=12):
    def point(row, column):
        latitude = math.pi * (row / rings - 0.5)
        longitude = math.tau * (column % sides) / sides
        unit = (math.cos(latitude) * math.cos(longitude), math.sin(latitude),
                math.cos(latitude) * math.sin(longitude))
        return tuple(c + r * value for c, r, value in zip(centre, radii, unit))

    def outward(p):
        return tuple((value - c) / (radius * radius) for value, c, radius in zip(p, centre, radii))

    for row in range(rings):
        for column in range(sides):
            a, b = point(row, column), point(row, column + 1)
            c, d = point(row + 1, column + 1), point(row + 1, column)
            u0, u1 = column / sides, (column + 1) / sides
            v0, v1 = row / rings, (row + 1) / rings
            if row == 0:
                mesh.tri_out(a, c, d, outward(c), uv(tile, u0, v0), uv(tile, u1, v1), uv(tile, u0, v1))
            elif row == rings - 1:
                mesh.tri_out(a, b, c, outward(a), uv(tile, u0, v0), uv(tile, u1, v0), uv(tile, u1, v1))
            else:
                mesh.quad_out(a, b, c, d, outward(a), uv(tile, u0, v0), uv(tile, u1, v0),
                              uv(tile, u1, v1), uv(tile, u0, v1))


def tube(mesh, points, radii, tile, sides=8):
    from mathutils import Vector
    rings = []
    for i, (position, radius) in enumerate(zip(points, radii)):
        tangent = (Vector(points[min(i + 1, len(points) - 1)]) - Vector(points[max(i - 1, 0)])).normalized()
        axis = Vector((1, 0, 0)) if abs(tangent.x) < 0.85 else Vector((0, 1, 0))
        side = tangent.cross(axis).normalized()
        up = side.cross(tangent)
        rings.append([tuple(Vector(position) + radius * (side * math.cos(math.tau * k / sides)
                     + up * math.sin(math.tau * k / sides))) for k in range(sides)])
    for i, (ring, next_ring) in enumerate(zip(rings, rings[1:])):
        for k, a in enumerate(ring):
            j = (k + 1) % sides
            b, c, d = ring[j], next_ring[j], next_ring[k]
            outward = tuple(x - y for x, y in zip(a, points[i]))
            mesh.quad_out(a, b, c, d, outward, uv(tile, 0.06, 0.06), uv(tile, 0.94, 0.06),
                          uv(tile, 0.94, 0.94), uv(tile, 0.06, 0.94))
    for index, other in [(0, 1), (len(points) - 1, len(points) - 2)]:
        normal = tuple(x - y for x, y in zip(points[index], points[other]))
        for a, b in zip(rings[index], rings[index][1:] + rings[index][:1]):
            mesh.tri_out(a, b, points[index], normal, uv(tile, 0.08, 0.1),
                         uv(tile, 0.92, 0.1), uv(tile, 0.5, 0.88))


def legs(mesh, side, spread, shoulder, stroke, phase, radius, hide):
    for xsign in (-1, 1):
        for zsign in (-1, 1):
            x = xsign * side
            z = zsign * spread
            cycle = phase + (math.pi if xsign != zsign else 0)
            reach = math.sin(cycle) * stroke
            lift = max(0.0, math.cos(cycle)) * stroke * 0.32 if stroke else 0
            tube(mesh, [(x, shoulder, z), (x, shoulder * 0.47 + lift, z + reach * 0.45),
                        (x, lift + 0.038, z + reach)],
                 [radius, radius * 0.72, radius * 0.56], hide, 7)
            ellipsoid(mesh, (x, lift + 0.035, z + reach + 0.020),
                      (radius * 0.70, 0.035, radius * 1.15), "dark", 4, 8)


def eyes(mesh, x, y, z, radius):
    for sign in (-1, 1):
        ellipsoid(mesh, (sign * x, y, z), (radius * 0.65, radius, radius),
                  "dark", 4, 8)


def sheep(phase, feed):
    mesh = MB()
    legs(mesh, 0.16, 0.34, 0.53, 0 if feed else 0.13, phase, 0.044, "planks")
    ellipsoid(mesh, (0, 0.62, -0.04), (0.29, 0.27, 0.55), "plaster")
    # A coarse, naturally uneven fleece rather than a featureless white box.
    for i in range(8):
        z = -0.42 + i * 0.107
        for sign in (-1, 1):
            x = sign * (0.16 + 0.04 * math.sin(i * 2.7))
            ellipsoid(mesh, (x, 0.72 + 0.038 * math.cos(i * 3.1), z),
                      (0.14, 0.14, 0.145), "plaster", 5, 8)
    ellipsoid(mesh, (0, 0.57, -0.58), (0.078, 0.085, 0.15), "plaster", 5, 8)
    y, z = (0.22, 0.73) if feed else (0.78, 0.55)
    tube(mesh, [(0, 0.68, 0.30), (0, (y + 0.64) * 0.5, z - 0.10), (0, y, z)],
         [0.16, 0.13, 0.10], "plaster")
    ellipsoid(mesh, (0, y, z), (0.14, 0.125, 0.155), "planks")
    dy = -0.09 if feed else -0.04
    ellipsoid(mesh, (0, y + dy, z + 0.11), (0.096, 0.079, 0.13), "daub")
    eyes(mesh, 0.126, y + 0.034, z + 0.052, 0.022)
    for sign in (-1, 1):
        tube(mesh, [(sign * 0.095, y + 0.054, z - 0.06), (sign * 0.20, y + 0.07, z - 0.09),
                    (sign * 0.245, y + 0.045, z - 0.10)], [0.040, 0.039, 0.008], "planks", 6)
    return mesh


def cattle(phase, feed):
    mesh = MB()
    legs(mesh, 0.23, 0.54, 0.86, 0 if feed else 0.21, phase, 0.073, "planks")
    ellipsoid(mesh, (0, 0.92, -0.06), (0.37, 0.37, 0.79), "planks")
    ellipsoid(mesh, (0, 0.99, 0.42), (0.31, 0.37, 0.32), "planks")
    ellipsoid(mesh, (0.012, 0.82, -0.34), (0.33, 0.22, 0.44), "planks")
    tube(mesh, [(0, 1.04, -0.77), (0.02, 0.75, -0.92), (0.04, 0.44, -0.94)],
         [0.044, 0.025, 0.020], "planks")
    ellipsoid(mesh, (0.04, 0.38, -0.94), (0.043, 0.12, 0.043), "dark", 5, 8)
    y, z = (0.29, 1.11) if feed else (1.08, 0.80)
    tube(mesh, [(0, 1.02, 0.45), (0, (y + 1.0) * 0.5, z - 0.20), (0, y, z)],
         [0.28, 0.22, 0.17], "planks")
    ellipsoid(mesh, (0, y, z), (0.19, 0.205, 0.23), "planks")
    muzzle_y = y - (0.18 if feed else 0.08)
    ellipsoid(mesh, (0, muzzle_y, z + 0.17), (0.154, 0.10, 0.125), "daub")
    eyes(mesh, 0.17, y + 0.072, z + 0.065, 0.028)
    for sign in (-1, 1):
        ellipsoid(mesh, (sign * 0.23, y + 0.06, z - 0.06), (0.14, 0.054, 0.077), "planks", 5, 8)
        tube(mesh, [(sign * 0.115, y + 0.145, z - 0.109), (sign * 0.223, y + 0.211, z - 0.15),
                    (sign * 0.31, y + 0.31, z - 0.13), (sign * 0.33, y + 0.38, z - 0.06)],
             [0.061, 0.046, 0.025, 0.007], "plaster", 7)
    return mesh


def pig(phase, feed):
    mesh = MB()
    legs(mesh, 0.155, 0.34, 0.34, 0 if feed else 0.12, phase, 0.052, "planks")
    ellipsoid(mesh, (0, 0.46, -0.06), (0.275, 0.275, 0.55), "planks")
    ellipsoid(mesh, (0, 0.52, 0.15), (0.245, 0.244, 0.36), "planks")
    y, z = (0.27, 0.48) if feed else (0.46, 0.50)
    ellipsoid(mesh, (0, y, z), (0.19, 0.17, 0.21), "planks")
    tip_y = y - (0.17 if feed else 0.055)
    tube(mesh, [(0, y - 0.028, z + 0.08), (0, tip_y, z + 0.31)], [0.133, 0.084], "daub")
    ellipsoid(mesh, (0, tip_y, z + 0.32), (0.10, 0.079, 0.048), "daub", 5, 10)
    eyes(mesh, 0.158, y + 0.062, z + 0.092, 0.018)
    for sign in (-1, 1):
        tube(mesh, [(sign * 0.125, y + 0.08, z - 0.035), (sign * 0.164, y + 0.205, z + 0.01),
                    (sign * 0.176, y + 0.28, z + 0.03)], [0.062, 0.046, 0.006], "planks", 6)
        ellipsoid(mesh, (sign * 0.043, tip_y + 0.023, z + 0.362),
                  (0.018, 0.013, 0.009), "dark", 4, 6)
    curls = [(0.0, 0.55, -0.58)]
    curls += [(0.09 * (1 - math.cos(t)), 0.61 + 0.054 * math.sin(t), -0.68 - 0.008 * i)
              for i, t in enumerate([i * math.pi / 5 for i in range(8)])]
    tube(mesh, curls, [0.027, 0.022, 0.020, 0.018, 0.017, 0.015, 0.013, 0.010, 0.008], "planks", 6)
    return mesh


def main():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    scene = bpy.context.scene
    scene.unit_settings.system = "METRIC"
    scene.unit_settings.length_unit = "METERS"
    collection = bpy.data.collections.new(COLLECTION)
    scene.collection.children.link(collection)
    bpy.context.view_layer.active_layer_collection = bpy.context.view_layer.layer_collection.children[COLLECTION]
    atlas = atlas_material()
    for row, (name, factory) in enumerate([("sheep", sheep), ("cattle", cattle), ("pig", pig)]):
        for frame in range(5):
            feed = frame == 4
            pose = "feed" if feed else f"walk-{frame}"
            build_object(factory(frame * math.pi / 2, feed), f"neolithic-livestock-{name}-{pose}",
                         ((frame - 2) * 2.7, row * 3.0, 0), atlas)
    bpy.data.images.get("atlas-flipped.png").filepath = "//../Buildings/variants/atlas-flipped.png"
    for screen in bpy.data.screens:
        for area in screen.areas:
            if area.type == "VIEW_3D":
                area.spaces.active.shading.color_type = "TEXTURE"
                area.spaces.active.region_3d.view_distance = 22
                area.spaces.active.region_3d.view_location = (0, 3, 0.6)
    bpy.ops.wm.save_as_mainfile(filepath=str(ROOT / "Assets/Neolithic/livestock.blend"),
                               relative_remap=False, compress=True)


if __name__ == "__main__":
    main()
