"""Export the editable Neolithic collection through the shared .civmesh exporter."""
import argparse
from pathlib import Path
import re
import sys
from tempfile import TemporaryDirectory

import bpy
from mathutils import Matrix, Vector

sys.path.insert(0, str(Path(__file__).resolve().parent))
from build_variants import export_object, OUT, ROOT

SOURCE = Path(ROOT) / "Assets" / "Neolithic" / "neolithic.blend"
COLLECTION = "Evolving Neolithic Exports"
ASSET_NAME = re.compile(r"(?:neo01|neolithic)-[a-z0-9]+(?:-[a-z0-9]+)*")


def assets():
    collection = bpy.data.collections.get(COLLECTION)
    if collection is None or not collection.all_objects:
        raise ValueError(f"Source must contain a nonempty {COLLECTION!r} collection")
    objects = sorted(collection.all_objects, key=lambda obj: obj.name)
    for obj in objects:
        if obj.type != "MESH" or ASSET_NAME.fullmatch(obj.name) is None:
            raise ValueError(f"{obj.name!r}: expected a Neolithic mesh asset name")
        if not obj.data.polygons or obj.data.uv_layers.active is None:
            raise ValueError(f"{obj.name}: add geometry and an active UV map")
        if obj.parent or obj.matrix_basis.to_3x3() != Matrix.Identity(3):
            raise ValueError(f"{obj.name}: apply rotation and scale and remove parenting before export")
    return objects


def export(objects, directory):
    directory.mkdir(parents=True, exist_ok=True)
    with TemporaryDirectory(prefix=".civmesh-export-", dir=directory) as staging:
        written = []
        for obj in objects:
            path = Path(staging) / (obj.name + ".civmesh")
            info = export_object(obj, str(path))
            if info["triangles"] == 0:
                raise ValueError(f"{obj.name}: the evaluated mesh has no triangles")
            written.append(path)
            print(f"{obj.name}: {info['triangles']} triangles")
        for path in written:
            path.replace(directory / path.name)


def contact_sheet(objects, path, *, columns=3, panel_pixels=600, scene_name="Neolithic contact sheet"):
    scene = bpy.data.scenes.new(scene_name)
    bpy.context.window.scene = scene
    scene.render.engine = "BLENDER_WORKBENCH"
    scene.display.shading.light = "STUDIO"
    scene.display.shading.color_type = "TEXTURE"
    scene.display.shading.show_cavity = True
    scene.display.shading.cavity_type = "BOTH"
    scene.display.shading.show_shadows = False
    scene.display.shading.background_type = "WORLD"
    scene.world = bpy.data.worlds.new("Warm grey")
    scene.world.color = (0.16, 0.17, 0.18)

    view = Vector((0.42, -1, 0.68)).normalized()
    rotation = (-view).to_track_quat("-Z", "Y")
    right = rotation @ Vector((1, 0, 0))
    up = rotation @ Vector((0, 1, 0))
    columns = min(columns, len(objects))
    rows = (len(objects) + columns - 1) // columns
    panel = 3.7
    for index, obj in enumerate(objects):
        row, column = divmod(index, columns)
        centre = right * ((column - (columns - 1) / 2) * panel) \
            + up * (((rows - 1) / 2 - row) * panel)
        preview = obj.copy()
        preview.name = f"{obj.name} (sheet)"
        scene.collection.objects.link(preview)
        bounds = [Vector(corner) for corner in obj.bound_box]
        midpoint = sum(bounds, Vector()) / len(bounds)
        scale = 2.35 / max(obj.dimensions)
        preview.scale = (scale,) * 3
        preview.location = centre + up * 0.26 - midpoint * scale

        label = bpy.data.curves.new("Asset caption", "FONT")
        label.body = obj.name.removeprefix("neo01-").replace("-", " ").title()
        label.align_x = "CENTER"
        label.size = 0.20
        caption = bpy.data.objects.new(label.body, label)
        scene.collection.objects.link(caption)
        caption.location = centre - up * 1.56 + view * 2
        caption.rotation_euler = rotation.to_euler()

    lens = bpy.data.cameras.new("Contact sheet")
    lens.type = "ORTHO"
    lens.ortho_scale = panel * max(columns, rows)
    camera = bpy.data.objects.new(lens.name, lens)
    scene.collection.objects.link(camera)
    camera.location = view * 14
    camera.rotation_euler = rotation.to_euler()
    scene.camera = camera
    scene.render.resolution_x = columns * panel_pixels
    scene.render.resolution_y = rows * panel_pixels
    scene.render.image_settings.file_format = "PNG"
    path.parent.mkdir(parents=True, exist_ok=True)
    scene.render.filepath = str(path)
    bpy.ops.render.render(write_still=True)


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
        contact_sheet(objects, args.sheet.resolve())


if __name__ == "__main__":
    main()
