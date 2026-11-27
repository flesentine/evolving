# BRZ-02 Editable Bronze roundhouses

Open the [Bronze Blender library](../../../Assets/BronzeHouse/bronze.blend)
and edit a mesh in **Evolving Bronze Exports**. The collection holds the
30 repaired roundhouses from BRZ-01. The [contact sheet](../../../Assets/BronzeHouse/bronze-contact-sheet.png)
labels each model by its export name. Keep the library inside this checkout
so Blender can find the shared atlas by its relative path.

The meshes use metres and Blender Z-up. The shared writer converts them to
the runtime Y-up convention and exports coordinates relative to each object's
origin. Edit the geometry, retain an active UV map, and apply rotation and
scale before exporting. Object translation arranges the library on screen.
Only meshes named with the lowercase `bronze-` prefix belong in the export
collection. Cameras, lights, and other authoring helpers can use a separate
collection.

## Export from the checkout

```sh
/Applications/Blender.app/Contents/MacOS/Blender --background --factory-startup \
  --python-exit-code 1 --python Scripts/build_bronze_reference.py -- \
  --output /tmp/evolving-bronze-preview \
  --sheet /tmp/evolving-bronze-preview/bronze-contact-sheet.png
```

Use `--source` to open another Bronze library, or omit `--output` to refresh
the runtime variants in `Assets/Buildings/variants/`. The exporter validates
the whole collection and stages the meshes before replacing any destination
files. Optional sheet rendering uses a separate Blender scene.
The normal Evolving build uses the exported `.civmesh` files. Use the
editable library for Bronze changes so they carry forward into the game.
The procedural BRZ-01 generator remains the replay source for the
original roof-repair evidence.

Two fresh Blender processes exported all 30 files byte for byte, and the
results matched the checked-in runtime meshes. A test edit to a copy of
`bronze-07` changed only its own export. A non-Bronze object in the collection
failed validation before writing files. The default export left the runtime
asset directory byte-identical.

## Review the export in Timeline

Open the saved Norimton view at year 810 from the repository root.

```sh
EVOLVING_DEV=1 EVOLVING_NEO01=0 \
  EVOLVING_NEO01_VIEW="$PWD/review/bronze/brz-02/roundhouse.json" \
  "$HOME/Applications/Evolving Timeline.app/Contents/MacOS/EvolvingTimeline"
```

The [matched render](roundhouse-before-after.jpg) shows the BRZ-01 runtime
on the left and the Blender collection export on the right.
The production-renderer images were byte-identical at the saved camera.
