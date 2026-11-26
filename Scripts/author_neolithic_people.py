"""Recreate the editable Neolithic character parts and activity props."""
import math
from pathlib import Path
import sys

import bpy

sys.path.insert(0, str(Path(__file__).resolve().parent))
from build_buildings import MB, uv
from build_variants import atlas_material, build_object

ROOT = Path(__file__).resolve().parents[1]
COLLECTION = "Evolving Neolithic Exports"


def patch(tile, u, v):
    # Sample within a tile to keep architectural joints off clothing and skin.
    cx, cy = (0.36, 0.53) if tile == "planks" else (0.53, 0.49)
    return uv(tile, cx + 0.08 * (u - 0.5), cy + 0.12 * (v - 0.5))


def profile(mesh, rings, tile, sides=8, centre=(0, 0)):
    """Join horizontal rings. Rings are (height, width radius, depth radius)."""
    def point(ring, i):
        y, rx, rz = ring
        a = math.tau * (i % sides) / sides
        return (centre[0] + rx * math.cos(a), y, centre[1] + rz * math.sin(a))

    for j, (lo, hi) in enumerate(zip(rings, rings[1:])):
        for i in range(sides):
            a, b, c, d = point(lo, i), point(lo, i+1), point(hi, i+1), point(hi, i)
            u0, u1 = i / sides, (i+1) / sides
            v0, v1 = j / (len(rings)-1), (j+1) / (len(rings)-1)
            ta, tb, tc, td = [patch(tile, u, v) for u, v in
                              [(u0,v0),(u1,v0),(u1,v1),(u0,v1)]]
            if lo[1] == 0:
                mesh.tri(a, d, c, ta, td, tc)
            elif hi[1] == 0:
                mesh.tri(a, d, b, ta, td, tb)
            else:
                mesh.quad(a, d, c, b, ta, td, tc, tb)


def tunic(tile):
    m = MB()
    profile(m, [(-.15,0,0),(-.15,.21,.135),(.06,.177,.113),
                (.35,.207,.116),(.44,.190,.109),(.47,.08,.068),(.47,0,0)], tile)
    profile(m, [(.027,.186,.123),(.066,.183,.121)], "oak")
    m.box((.026,.05,.122), (.055,.037,.017), "planks")
    return m


def head():
    m = MB()
    profile(m, [(-.032,0,0),(-.012,.053,.053),(.018,.060,.061),
                (.038,.075,.072),(.10,.099,.086),(.185,.091,.084),
                (.222,.065,.064),(.232,0,0)], "daub")
    profile(m, [(.153,.098,.09),(.207,.092,.083),(.238,.057,.059),(.24,0,0)],
            "oak", centre=(0,-.012))
    m.box((0,.105,.086), (.027,.037,.035), "daub")
    for sign in (-1,1):
        m.box((sign*.041,.134,.079), (.015,.012,.012), "dark")
        m.box((sign*.097,.112,-.004), (.025,.046,.030), "daub")
    return m


def limb(rings, tile):
    m = MB()
    profile(m, rings, tile, 7)
    return m


def shoe():
    m = MB()
    profile(m, [(0,0,0),(0,.062,.111),(.049,.059,.105),(.11,.044,.065),(.12,0,0)],
            "planks", 8, centre=(0,.037))
    return m


def copy_quern_bed():
    obj = bpy.data.objects["neolithic-prop-quern"]
    tex = obj.data.uv_layers.active.data
    m = MB()
    for face in obj.data.polygons:
        indices = list(face.loop_indices)
        uvs = [tuple(tex[i].uv) for i in indices]
        # The existing bed maps to the mineral tile. Its lighter rider maps to plaster.
        if not all(.5 < u < .75 for u, _ in uvs):
            continue
        xyz = [obj.data.vertices[obj.data.loops[i].vertex_index].co for i in indices]
        m.tri(*[(p.x,p.z,-p.y) for p in xyz], *uvs)
    if not m.f:
        raise ValueError("Missing original quern bed")
    return m


def hearth():
    m = MB()
    profile(m, [(0,0,0),(0,.292,.281),(.014,.291,.283),(.026,0,0)], "dark", 12)
    for i in range(8):
        a = i * math.tau / 8
        p = (.32 * math.cos(a), .31 * math.sin(a))
        profile(m, [(-.018,0,0),(0,.117,.108),(.091 + .011 * (i%3),.10,.083),
                    (.129,.057,.065),(.137,0,0)], "concrete", 6, centre=p)
    for j in range(5):
        a = j * 2.39
        p = (.16 * math.cos(a),.14 * math.sin(a))
        profile(m, [(.018,0,0),(.024,.054,.04),(.060,.043,.032),(.079,0,0)],
                "tile", 5, centre=p)
    return m


def main():
    bpy.ops.wm.open_mainfile(filepath=str(ROOT / "Assets/Neolithic/neolithic.blend"),
                            load_ui=False, use_scripts=False)
    bed = copy_quern_bed()
    bpy.ops.wm.read_factory_settings(use_empty=True)
    scene = bpy.context.scene
    scene.unit_settings.system = "METRIC"
    scene.unit_settings.length_unit = "METERS"
    collection = bpy.data.collections.new(COLLECTION)
    scene.collection.children.link(collection)
    bpy.context.view_layer.active_layer_collection = bpy.context.view_layer.layer_collection.children[COLLECTION]
    atlas = atlas_material()
    handstone = MB()
    profile(handstone, [(0,0,0),(0,.065,.106),(.035,.075,.127),(.078,.057,.101),
                        (.105,.038,.060),(.107,0,0)], "plaster", 10)
    poker = MB()
    poker.box((0,-.35,0), (.023,.70,.024), "planks")
    parts = {
        "tunic-oat": tunic("thatch"), "tunic-brown": tunic("planks"), "head": head(),
        "sleeve": limb([(-1,0,0),(-1,.050,.049),(-.18,.065,.056),(0,.058,.053),(0,0,0)], "thatch"),
        "forearm": limb([(-1,0,0),(-1,.036,.032),(-.77,.040,.035),(-.12,.045,.043),(0,0,0)], "daub"),
        "legging": limb([(-1,0,0),(-1,.045,.044),(-.2,.083,.076),(0,.083,.078),(0,0,0)], "oak"),
        "shoe": shoe(), "handstone": handstone, "quern-bed": bed,
        "hearth": hearth(), "poker": poker,
    }
    for i, (name, mesh) in enumerate(parts.items()):
        build_object(mesh, "neolithic-person-" + name, (i % 4 * 2.1, i // 4 * 2.0, 0), atlas)
    bpy.data.images.get("atlas-flipped.png").filepath = "//../Buildings/variants/atlas-flipped.png"
    for screen in bpy.data.screens:
        for area in screen.areas:
            if area.type == "VIEW_3D":
                area.spaces.active.shading.color_type = "TEXTURE"
                area.spaces.active.region_3d.view_distance = 13
                area.spaces.active.region_3d.view_location = (3, 2, .5)
    bpy.ops.wm.save_as_mainfile(filepath=str(ROOT / "Assets/Neolithic/people.blend"),
                               relative_remap=False, compress=True)


if __name__ == "__main__":
    main()
