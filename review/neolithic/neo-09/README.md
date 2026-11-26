# NEO-09 Neolithic livestock

These photographs and saved cameras document NEO-09's standalone build.
The integrated build uses the [NEO-10 herd cameras](../neo-10/README.md)
for the current routes.

Sheep, cattle, and pigs have separate silhouettes and scale. Sheep have
a coarse fleece, cattle have swept horns and taller shoulders, and pigs
have short legs, a long snout, and a curled tail. Each species has four
walk frames and a feeding pose. The animation phases and grazing anchors
are seeded by world and settlement. The animation pauses movement during
feeding. Grazing still uses the existing radius around each settlement. Planted
hooves follow the submitted terrain. Animals are excluded from water,
banks, roads, yards, and crops.
Species-specific pasture, pen and route selection belongs to NEO-10.

## Open the review in Timeline

Run from the feature checkout after building and installing.

```sh
EVOLVING_DEV=1 EVOLVING_NEO01=0 \
  EVOLVING_NEO01_VIEW="$PWD/review/neolithic/neo-09/sheep-walk.json" \
  "$HOME/Applications/Evolving Timeline.app/Contents/MacOS/EvolvingTimeline"
```

The supplied records use seed 1, year 450, and a fixed daytime view.
Replace the filename with `sheep-feed.json`, `cattle-walk.json`,
`cattle-feed.json`, `pig-walk.json` or `pig-feed.json` to view the
other poses. `grazing-range.json` covers the settlement at a wider
scale. Open Timeline normally to see the poses cycle as the world runs.

## Rendered comparison

[Before and after](before-after.jpg) shows the generic animal on the left and
NEO-09 cattle on the right, rendered from [the same camera](matched-cattle.json)
with the same seed, year, weather, and animation time. The anchors and scale
changed. [Close views](poses.jpg) show sheep, cattle, and pigs from top to bottom,
with walking on the left and feeding on the right.

## Edit and export

Edit `Assets/Neolithic/livestock.blend` independently of the house source.
Its objects already use the existing building atlas. The authoring script
can recreate the original models. Runtime assets can be exported from the
editable source with the existing exporter.

```sh
blender -b --python Scripts/build_neolithic_reference.py -- \
  --source Assets/Neolithic/livestock.blend \
  --sheet Assets/Neolithic/livestock-sheet.png
```

`build/bin/civheadless neolithicanimals build/neo-09` checks and renders
the poses. `build/bin/civheadless riverreview <record.json> <output-directory> --no-ids` replays one saved view.
