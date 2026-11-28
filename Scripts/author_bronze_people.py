"""Author Bronze clothing and a wooden weaving shuttle in the Bronze library."""
from pathlib import Path
import sys

import bpy

sys.path.insert(0, str(Path(__file__).resolve().parent))
from author_neolithic_people import limb, profile
from build_bronze_reference import COLLECTION, SOURCE
from build_buildings import MB
from build_variants import build_object


def tunic(tile, trim):
    mesh = MB()
    profile(mesh, [(-.24,0,0),(-.24,.232,.151),(-.12,.220,.143),
                   (.055,.178,.121),(.25,.189,.121),(.412,.218,.128),
                   (.466,.115,.083),(.476,.073,.067),(.476,0,0)], tile, 10)
    profile(mesh, [(-.237,.233,.152),(-.209,.231,.151)], trim, 10)
    profile(mesh, [(.021,.188,.130),(.058,.182,.127)], "oak", 10)
    mesh.box((.044,.044,.129), (.073,.041,.021), "stone")
    mesh.box((0,.413,.123), (.057,.081,.018), trim)
    return mesh


def shuttle():
    mesh = MB()
    profile(mesh, [(-.118,0,0),(-.092,.025,.014),(-.067,.037,.020),
                   (.067,.037,.020),(.092,.025,.014),(.118,0,0)], "planks", 6)
    profile(mesh, [(-.047,.040,.023),(.042,.040,.023)], "thatch", 6)
    return mesh


def main():
    bpy.ops.wm.open_mainfile(filepath=str(SOURCE), load_ui=True, use_scripts=False)
    exports = bpy.data.collections[COLLECTION]
    group = exports.children.get("Clothing and Work")
    if group is None:
        group = bpy.data.collections.new("Clothing and Work")
        exports.children.link(group)
    atlas = exports.all_objects["bronze-01"].data.materials[0]
    parts = [
        ("tunic-flax", tunic("thatch", "planks")),
        ("tunic-umber", tunic("planks", "thatch")),
        ("sleeve", limb([(-1,0,0),(-1,.057,.051),(-.22,.075,.062),(0,.072,.062),(0,0,0)], "thatch")),
        ("legging", limb([(-1,0,0),(-1,.047,.042),(-.52,.061,.053),(-.11,.081,.075),(0,.084,.076),(0,0,0)], "oak")),
        ("shuttle", shuttle()),
    ]
    for index, (suffix, mesh) in enumerate(parts):
        name = "bronze-person-" + suffix
        old = group.objects.get(name)
        if old is not None:
            bpy.data.objects.remove(old, do_unlink=True)
        obj = build_object(mesh, name, ((index - 2) * 2.0, -78, 0), atlas)
        for parent in tuple(obj.users_collection):
            parent.objects.unlink(obj)
        group.objects.link(obj)
    bpy.context.preferences.filepaths.save_version = 0
    bpy.ops.wm.save_as_mainfile(filepath=str(SOURCE), compress=True)


if __name__ == "__main__":
    main()
