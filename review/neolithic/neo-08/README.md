# NEO-08 Fields and hearths

Small wheat and barley beds grow near eligible Neolithic work yards. The beds
follow the submitted terrain triangles. Planted rows stand on the resulting
soil mesh, and a tied sheaf pair and woven winnowing tray sit nearby where
the ground leaves room. Plot placement respects water, banks, roads, work paths,
buildings, crops, and the activities already in the yard.

Wheat and barley are stylized. Grain finds inform the crop choices and the
precise bed layout, sheaves, and tray are artistic interpretations.
[Historic England's record of wheat and barley at Hembury](https://historicengland.org.uk/listing/heritage-gateway/results/record/c39bc47e-3b72-4a06-9863-681629e456a2/MDV5327)

The existing work hearths emit a small animated plume. At dusk, the nearest
hearths also give a warm local light within about 2.8 m of the fixture. Rain
dampens the glow and smoke. The ember tint, light, and plume use the recorded
animation time.

## Review in Timeline

From the feature checkout, launch the installed Timeline with the dusk view.

```sh
EVOLVING_DEV=1 EVOLVING_NEO01=0 \
  EVOLVING_NEO01_VIEW="$PWD/review/neolithic/neo-08/hearth-dusk.json" \
  "$HOME/Applications/Evolving Timeline.app/Contents/MacOS/EvolvingTimeline"
```

The saved cameras also include daylight and dusk fields, the harvest corner,
the daytime hearth, and the hearth in rain. Open Timeline normally to see the
smoke rise and coals flicker as the world runs.

[Compare the field beds](fields-day-before-after.jpg) and [the hearth at dusk](hearth-dusk-before-after.jpg)
with their NEO-07 baselines. The [gallery](gallery.jpg) shows the plots at
daylight and dusk, the harvest corner, and the hearth in rain.

## Edit and verify

The editable models are in [harvest.blend](../../../Assets/Neolithic/harvest.blend).
The Blender authoring script can regenerate the original shapes. Export through
the existing Neolithic exporter.

```sh
blender -b --factory-startup --python-exit-code 1 --python Scripts/author_neolithic_harvest.py
blender -b --factory-startup --python-exit-code 1 --python Scripts/build_neolithic_reference.py -- \
  --source Assets/Neolithic/harvest.blend --sheet Assets/Neolithic/harvest-sheet.png
build/bin/civheadless neolithicharvest build/neo-08
```
