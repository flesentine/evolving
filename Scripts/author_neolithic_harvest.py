"""Create editable wheat, barley, and harvest props in metres."""
import math
from pathlib import Path
import sys

import bpy
from mathutils import Vector

sys.path.insert(0, str(Path(__file__).resolve().parent))
from author_neolithic_people import patch, profile
from build_buildings import MB
from build_variants import atlas_material, build_object

ROOT = Path(__file__).resolve().parents[1]


def stem(mesh, a, b, width, tile):
    """A slender three-sided stem with an open base under the root."""
    start, finish = Vector(a), Vector(b)
    direction = (finish - start).normalized()
    right = direction.cross(Vector((0, 0, 1))).normalized()
    front = direction.cross(right)
    ring = [right * math.cos(i * math.tau / 3) + front * math.sin(i * math.tau / 3)
            for i in range(3)]
    for i, outward in enumerate(ring):
        other = ring[(i + 1) % 3]
        mesh.quad_out(tuple(start + outward * width), tuple(start + other * width),
                      tuple(finish + other * width * .7), tuple(finish + outward * width * .7),
                      tuple(outward + other), patch(tile,0,0), patch(tile,1,0),
                      patch(tile,1,1), patch(tile,0,1))


def leaf(mesh, base, tip, width, tile):
    a, b = Vector(base), Vector(tip)
    side = (b - a).cross(Vector((0, 1, 0))).normalized() * width
    mid = a.lerp(b, 0.4)
    vertices = [tuple(a), tuple(mid + side), tuple(b), tuple(mid - side)]
    uv = [patch(tile,0,0), patch(tile,1,0), patch(tile,1,1), patch(tile,0,1)]
    mesh.quad(*vertices, *uv)
    mesh.quad(*reversed(vertices), *reversed(uv))


def clump(barley):
    mesh = MB()
    for i, (x, z) in enumerate([(-.096,-.025),(.003,-.106),(.075,.052),(-.023,.087),(.11,-.028)]):
        height = (.50 if barley else .63) + .042 * ((i * 7) % 4)
        dx, dz = x * .36, z * .31
        tx, tz = x + dx, z + dz
        straw = "turf" if barley else "thatch"
        stem(mesh, (x,0,z), (tx,height,tz), .010, straw)
        leaf(mesh, (x+dx*.60,height*.60,z+dz*.60),
             (tx+(.16 if i%2 else -.125),height*.77,tz+.065), .028, straw)
        ear_height = .126 if barley else .162
        ear_width = .021 if barley else .034
        profile(mesh, [(height-.016,0,0),(height+.025,ear_width,ear_width*.72),
                       (height+ear_height*.67,ear_width*.83,ear_width*.62),
                       (height+ear_height,0,0)], "daub" if barley else "plaster",
                sides=5, centre=(tx,tz))
        if barley:
            for sign in (-1,1):
                stem(mesh, (tx+sign*.012,height+.065,tz),
                     (tx+sign*.064,height+.243,tz+.015), .005, "plaster")
    return mesh


def sheaves():
    mesh = MB()
    for j, (x, z) in enumerate([(-.17,-.04),(.117,.04)]):
        for i in range(7):
            angle = i * math.tau / 7
            sx, sz = math.cos(angle), math.sin(angle)
            stem(mesh, (x+sx*.102,0,z+sz*.097),
                 (x+sx*.133+.048,.59+.032*(i%3),z+sz*.125+.072), .024, "thatch")
            stem(mesh, (x+sx*.123+.043,.48,z+sz*.119+.065),
                 (x+sx*.133+.048,.62+.032*(i%3),z+sz*.125+.072), .029, "plaster")
        # Short interior stalks fill the tied centre of the bundle.
        for i in range(6):
            angle = i * math.tau / 6
            sx, sz = math.cos(angle), math.sin(angle)
            stem(mesh, (x+sx*.057,0,z+sz*.051),
                 (x+sx*.065+.041,.57+.034*(i%3),z+sz*.057+.061), .023, "thatch")
        profile(mesh, [(.267,.113,.112),(.298,.11,.108)], "oak", 9, centre=(x+.021,z+.034))
    return mesh


def winnowing_tray():
    mesh = MB()
    profile(mesh, [(0,0,0),(0,.172,.126),(.052,.328,.244),(.092,.338,.250),
                   (.100,.312,.231),(.073,.298,.226),(.027,.149,.11),(.027,0,0)],
            "thatch", 14)
    profile(mesh, [(.060,.334,.247),(.080,.337,.249)], "oak", 14)
    for i in range(10):
        angle = i * 2.39996
        radius = .077 + .017 * (i%4)
        point = (radius*math.cos(angle), radius*.7*math.sin(angle))
        profile(mesh, [(.030,0,0),(.038,.041,.027),(.054,.025,.022),(.065,0,0)],
                "plaster", 5, centre=point)
    return mesh


def main():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    scene = bpy.context.scene
    scene.unit_settings.system = "METRIC"
    scene.unit_settings.length_unit = "METERS"
    collection = bpy.data.collections.new("Evolving Neolithic Exports")
    scene.collection.children.link(collection)
    bpy.context.view_layer.active_layer_collection = bpy.context.view_layer.layer_collection.children[collection.name]
    atlas = atlas_material()
    parts = [("wheat", clump(False)), ("barley", clump(True)),
             ("sheaves", sheaves()), ("tray", winnowing_tray())]
    for index, (name, mesh) in enumerate(parts):
        build_object(mesh, "neolithic-harvest-" + name, (index * 1.4, 0, 0), atlas)
    bpy.data.images.get("atlas-flipped.png").filepath = "//../Buildings/variants/atlas-flipped.png"
    for screen in bpy.data.screens:
        for area in screen.areas:
            if area.type == "VIEW_3D":
                area.spaces.active.shading.color_type = "TEXTURE"
                area.spaces.active.region_3d.view_distance = 8
                area.spaces.active.region_3d.view_location = (2.1, 0, .5)
    bpy.ops.wm.save_as_mainfile(filepath=str(ROOT / "Assets/Neolithic/harvest.blend"),
                               relative_remap=False, compress=True)


if __name__ == "__main__":
    main()
