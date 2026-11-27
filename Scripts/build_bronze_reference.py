"""Export the editable Bronze Age roundhouses through the shared .civmesh writer."""

import argparse
from pathlib import Path
import re
import sys

import bpy
from mathutils import Matrix

sys.path.insert(0, str(Path(__file__).resolve().parent))
from build_neolithic_reference import contact_sheet, export
from build_variants import OUT, ROOT

SOURCE = Path(ROOT) / "Assets" / "BronzeHouse" / "bronze.blend"
COLLECTION = "Evolving Bronze Exports"
ASSET_NAME = re.compile(r"bronze-[a-z0-9]+(?:-[a-z0-9]+)*")


def assets():
    collection = bpy.data.collections.get(COLLECTION)
    if collection is None or not collection.all_objects:
        raise ValueError(f"Source must contain a nonempty {COLLECTION!r} collection")
    objects = sorted(collection.all_objects, key=lambda obj: obj.name)
    for obj in objects:
        if obj.type != "MESH" or ASSET_NAME.fullmatch(obj.name) is None:
            raise ValueError(f"{obj.name!r}: expected a mesh with a lowercase bronze- name")
        if not obj.data.polygons or obj.data.uv_layers.active is None:
            raise ValueError(f"{obj.name}: add geometry and an active UV map before exporting")
        if obj.parent or obj.matrix_basis.to_3x3() != Matrix.Identity(3):
            raise ValueError(f"{obj.name}: apply rotation and scale and remove parenting before export")
    return objects


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=SOURCE)
    parser.add_argument("--output", type=Path, default=Path(OUT))
    parser.add_argument("--sheet", type=Path, help="Optional PNG contact sheet")
    args = parser.parse_args(sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else [])
    if args.sheet and args.sheet.suffix.lower() != ".png":
        parser.error("--sheet must end in .png")
    bpy.ops.wm.open_mainfile(filepath=str(args.source.resolve()), load_ui=False, use_scripts=False)
    objects = assets()
    export(objects, args.output.resolve())
    if args.sheet:
        contact_sheet(objects, args.sheet.resolve(), columns=6, panel_pixels=360,
                      scene_name="Bronze Age contact sheet")


if __name__ == "__main__":
    main()
