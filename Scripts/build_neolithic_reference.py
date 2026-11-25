"""Build the NEO-01 review assets with Blender and the building atlas."""
import os
import sys
import math

import bpy

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from build_buildings import MB, uv
from build_variants import OUT, atlas_material, build_object, export_object


def house():
    mesh = MB()
    # Five-metre square house, with the entrance facing +Z.
    mesh.box((0, -0.51, 0), (5.1, 1.30, 5.1), "stone")
    for side in (-1, 1):
        mesh.box((side * 2.35, 1.06, 0), (0.30, 2.02, 5), "daub")
        mesh.box((side * 1.55, 1.06, 2.35), (1.85, 2.02, 0.30), "daub")
        mesh.box((side * 0.64, 1.09, 2.56), (0.16, 2, 0.18), "oak")
        for z in (-2.4, 2.4):
            mesh.box((side * 2.38, 1.08, z), (0.19, 2.12, 0.19), "oak")
    mesh.box((0, 1.06, -2.35), (5, 2.02, 0.30), "daub")
    mesh.box((0, 1.88, 2.39), (1.35, 0.33, 0.25), "oak")
    mesh.box((0, 1.02, 1.45), (1.55, 1.90, 0.10), "dark")
    mesh.box((0, 0.08, 2.86), (1.18, 0.16, 0.55), "stone")
    mesh.hip_roof(5, 5, 2.04, 2.63, 0.49, "thatch")
    for sign in (-1, 1):
        for i in range(27):
            x = -2.78 + i * 0.213
            z = sign * (2.93 + 0.036 * math.sin(i * 2.3))
            mesh.box((x, 2.04 + 0.036 * math.cos(i * 3), z), (0.24, 0.17, 0.14), "thatch")
    # Exposed lattice where the daub has weathered away.
    for i in range(7):
        mesh.box((1.24 + i * 0.11, 0.87, 2.515), (0.04, 0.48, 0.065), "oak")
    for i in range(5):
        mesh.box((1.57, 0.67 + i * 0.09, 2.55), (0.70, 0.045, 0.055), "oak")
    return mesh


def ellipsoid(mesh, centre, radii, material):
    def point(latitude, longitude):
        direction = (math.cos(latitude) * math.cos(longitude), math.sin(latitude),
                     math.cos(latitude) * math.sin(longitude))
        return tuple(c + d * r for c, d, r in zip(centre, direction, radii))

    def outward(point):
        return tuple(p - c for p, c in zip(point, centre))

    coordinates = [uv(material, u, v) for u, v in ((0, 0), (1, 0), (1, 1), (0, 1))]
    for band in range(5):
        low = math.pi * (band / 5 - 0.5)
        high = math.pi * ((band + 1) / 5 - 0.5)
        for sector in range(10):
            start = math.tau * sector / 10
            end = math.tau * (sector + 1) / 10
            corners = [point(low, start), point(low, end), point(high, end), point(high, start)]
            if band == 0:
                mesh.tri_out(corners[0], corners[2], corners[3], outward(corners[2]), *coordinates[:3])
            elif band == 4:
                mesh.tri_out(corners[0], corners[1], corners[2], outward(corners[0]), *coordinates[:3])
            else:
                mesh.quad_out(*corners, outward(corners[0]), *coordinates)


def worker():
    mesh = MB()
    # Kneeling worker and handstone, staged at a low saddle quern.
    ellipsoid(mesh, (0, 0.45, -0.16), (0.24, 0.35, 0.21), "oak")
    ellipsoid(mesh, (0, 0.95, -0.02), (0.115, 0.145, 0.115), "daub")
    ellipsoid(mesh, (0, 1.01, -0.055), (0.12, 0.09, 0.106), "dark")
    for x in (-0.14, 0.14):
        ellipsoid(mesh, (x, 0.19, -0.14), (0.115, 0.16, 0.24), "oak")
        ellipsoid(mesh, (x, 0.57, 0.16), (0.075, 0.11, 0.24), "daub")
        ellipsoid(mesh, (x, 0.45, 0.33), (0.06, 0.12, 0.085), "daub")
    ellipsoid(mesh, (0, 0.16, 0.46), (0.37, 0.16, 0.27), "stone")
    ellipsoid(mesh, (0, 0.33, 0.42), (0.22, 0.08, 0.09), "stone")
    ellipsoid(mesh, (0.58, 0.15, 0.24), (0.20, 0.15, 0.18), "daub")
    return mesh


def livestock():
    mesh = MB()
    ellipsoid(mesh, (0, 0.47, 0), (0.27, 0.27, 0.56), "oak")
    ellipsoid(mesh, (0, 0.40, 0.50), (0.17, 0.16, 0.24), "oak")
    ellipsoid(mesh, (0, 0.29, 0.67), (0.12, 0.093, 0.15), "daub")
    for x in (-0.17, 0.17):
        for z in (-0.32, 0.29):
            mesh.box((x, 0.19, z), (0.095, 0.38, 0.10), "oak")
        ellipsoid(mesh, (x * 0.74, 0.55, 0.46), (0.057, 0.13, 0.07), "oak")
    return mesh


if __name__ == "__main__":
    bpy.ops.wm.read_factory_settings(use_empty=True)
    material = atlas_material()
    for name, geometry in (("house", house()), ("worker", worker()), ("livestock", livestock())):
        name = "neo01-" + name
        obj = build_object(geometry, name, (0, 0, 0), material)
        print(name, export_object(obj, os.path.join(OUT, name + ".civmesh")))
