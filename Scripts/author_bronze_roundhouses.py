"""Seed the editable Bronze library with the BRZ-03 roundhouse family.

Run once in background Blender against the original BRZ-02 library.
Afterward, edit the library directly and use build_bronze_reference.py.
"""

from math import cos, pi, sin
from pathlib import Path
import sys

import bpy

sys.path.insert(0, str(Path(__file__).resolve().parent))
from build_bronze_reference import COLLECTION, SOURCE
from build_buildings import MB, uv
from build_variants import build_object

SECTORS = 32
SKIRT_DEPTH = 1.85


def ring_point(i, radius, height, advance=0):
    angle = 2 * pi * i / SECTORS
    return (radius * sin(angle), height, radius * cos(angle) + advance)


def course(mesh, lower, upper, material, i, row=0, *, roof=False):
    angle = 2 * pi * (i + 0.5) / SECTORS
    out = (sin(angle), 1 if roof else 0, cos(angle))
    u = ((i + row * 3) % 8) / 8
    mesh.quad_out(lower[i], lower[(i + 1) % SECTORS], upper[(i + 1) % SECTORS], upper[i],
                  out, uv(material, u, 0.04), uv(material, u + 0.125, 0.04),
                  uv(material, u + 0.125, 0.92), uv(material, u, 0.92), smooth=False)


def roundhouse(radius, wall, eave, peak, *, porch=False, upland=False):
    mesh = MB()
    door_sectors = (0, SECTORS - 1)
    footing = 0.77 if upland else 0.17
    lintel = wall - 0.24
    for row, (y0, y1, material) in enumerate([
        (-SKIRT_DEPTH, 0.04, "stone"),
        (0.04, footing, "stone"),
        (footing, lintel, "daub"),
        (lintel, wall, "daub"),
    ]):
        bottom = [ring_point(i, radius + (0.09 if material == "stone" else 0), y0)
                  for i in range(SECTORS)]
        top = [ring_point(i, radius + (0.09 if material == "stone" else 0), y1)
               for i in range(SECTORS)]
        for i in range(SECTORS):
            if i in door_sectors and row in (1, 2):
                continue
            course(mesh, bottom, top, material, i, row)
            if row == 1:
                j = (i + 1) % SECTORS
                mesh.quad_out(top[i], top[j], ring_point(j, radius, footing),
                              ring_point(i, radius, footing), (0, 1, 0),
                              uv("stone", 0, 0.3), uv("stone", 0.23, 0.3),
                              uv("stone", 0.23, 0.38), uv("stone", 0, 0.38))
    if upland:
        # Broad, offset slabs interrupt the otherwise continuous footing.
        for i in range(0, SECTORS, 2):
            if i < 2:
                continue
            p = ring_point(i, radius + 0.07, 0.26)
            angle = 2 * pi * i / SECTORS
            first = len(mesh.v)
            mesh.box((0, 0, 0), (0.68, 0.32 + 0.04 * sin(i), 0.21), "stone")
            mesh.v[first:] = [(p[0] + x * cos(angle) + z * sin(angle), p[1] + y,
                               p[2] - x * sin(angle) + z * cos(angle))
                              for x, y, z in mesh.v[first:]]
    else:
        for i in range(2, SECTORS, 3):
            post = ring_point(i, radius - 0.015, (wall + footing) / 2)
            mesh.box(post, (0.14, wall - footing + 0.05, 0.14), "oak")

    half_door = radius * sin(2 * pi / SECTORS)
    front = radius * cos(2 * pi / SECTORS)
    mesh.box((0, lintel * 0.5, front - 0.30), (half_door * 2.13, lintel, 0.075), "dark")
    for side in (-1, 1):
        mesh.box((side * half_door, (lintel + 0.04) * 0.5, front - 0.07),
                 (0.14, lintel, 0.37), "oak")
    mesh.box((0, lintel, front), (half_door * 2 + 0.22, 0.16, 0.31), "oak")
    mesh.box((0, -SKIRT_DEPTH / 2 + 0.04, front + 0.16),
             (half_door * 2 + 0.22, SKIRT_DEPTH, 0.67), "stone")

    # Extend the eave at the doorway. It is part of the same roof surface,
    # with no intersection line or second layer that can open under culling.
    lower = []
    for row, height_fraction in enumerate((0, 0.19, 0.43, 0.69, 0.88)):
        points = []
        for i in range(SECTORS):
            angle = i * 2 * pi / SECTORS
            projection = max(0, 1 - min(i, SECTORS - i) / 4) if porch else 0
            radius_at_course = (radius + eave) * (1 - height_fraction)
            radius_at_course += 0.06 * sin(angle * 7) * (1 - height_fraction)
            extension = 1.32 * projection * (1 - height_fraction) ** 3
            height = wall + (peak - wall) * height_fraction
            height += (0.055 * cos(9 * angle) - 0.14 * projection) * (1 - height_fraction)
            points.append(ring_point(i, radius_at_course, height, extension))
        if row == 0:
            rim = [(x * 0.98, y - 0.12, z * 0.98) for x, y, z in points]
            for i in range(SECTORS):
                course(mesh, rim, points, "thatch", i)
                j = (i + 1) % SECTORS
                mesh.quad_out(rim[i], rim[j], ring_point(j, radius - 0.04, wall - 0.065),
                              ring_point(i, radius - 0.04, wall - 0.065), (0, -1, 0),
                              uv("thatch", 0.08, 0.05), uv("thatch", 0.21, 0.05),
                              uv("thatch", 0.21, 0.44), uv("thatch", 0.08, 0.44))
        else:
            for i in range(SECTORS):
                course(mesh, lower, points, "thatch", i, row, roof=True)
        lower = points
    for i in range(SECTORS):
        mesh.tri_out(lower[i], lower[(i + 1) % SECTORS], (0.025, peak, 0.03),
                     (0, 1, 0), uv("thatch", 0.05, 0.05),
                     uv("thatch", 0.18, 0.05), uv("thatch", 0.12, 0.94))

    if porch:
        top = wall - 0.055
        for side in (-1, 1):
            mesh.box((side * 0.69, (top - SKIRT_DEPTH) / 2, radius + eave + 0.35),
                     (0.17, top + SKIRT_DEPTH, 0.18), "oak")
        mesh.box((0, top - 0.075, radius + eave + 0.35), (1.62, 0.15, 0.20), "oak")
    return mesh


def main():
    bpy.ops.wm.open_mainfile(filepath=str(SOURCE), load_ui=True, use_scripts=False)
    collection = bpy.data.collections[COLLECTION]
    material = next(iter(collection.objects)).data.materials[0]
    models = (
        ("timber-daub", roundhouse(2.46, 2.05, 0.45, 4.85)),
        ("porched", roundhouse(2.57, 2.09, 0.66, 5.28, porch=True)),
        ("upland-stone", roundhouse(2.73, 1.78, 0.36, 3.79, upland=True)),
    )
    for index, (suffix, mesh) in enumerate(models):
        name = "bronze-" + suffix
        existing = collection.objects.get(name)
        if existing:
            bpy.data.objects.remove(existing, do_unlink=True)
        obj = build_object(mesh, name, ((index - 1) * 16, -65, 0), material)
        if collection not in obj.users_collection:
            for previous in tuple(obj.users_collection):
                previous.objects.unlink(obj)
            collection.objects.link(obj)
    bpy.context.preferences.filepaths.save_version = 0
    bpy.ops.wm.save_as_mainfile(filepath=str(SOURCE), compress=True)


if __name__ == "__main__":
    main()
