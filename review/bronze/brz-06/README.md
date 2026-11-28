# BRZ-06 Bronze Age household and craft props

Suitable Bronze Age courts now have a small household workshop beside the
walking lanes. A standing loom carries cloth, hanging warp threads, and nine
clay weights. The group also includes a wicker basket, a clay jar and bowl, and
a low workbench with a finished hafted bronze axe. The standing loom is a visual
interpretation. The finds that informed the furnishings include loom weights,
textiles, pots, and hafted axes. [Cambridge Archaeological Unit on the Must Farm objects](https://www.arch.cam.ac.uk/research/projects/current-projects/must-farm-project/objects-must-farm-site)

A court receives a complete group when all four asset footprints fit on dry,
usable ground. The placement checks buildings, paths, crops, paddocks, banks,
and water. Each asset uses metre-scale geometry from Blender and is seated
against the submitted terrain.

## Matched views

Every pair shows BRZ-05 on the left and BRZ-06 on the right. Both sides use the
same seed, year, camera, sun, weather, and animation time.

- [Loom, weights, and the court workshop](court-close-before-after.jpg)
- [Workbench, bronze axe, and pottery](tool-and-pottery-before-after.jpg)
- [Installed Timeline windows at year 1450](timeline-before-after.jpg)

## Open the installed Timeline

From the repository root, jump to the workshop.

```sh
EVOLVING_DEV=1 EVOLVING_NEO01=0 \
  EVOLVING_NEO01_VIEW="$PWD/review/bronze/brz-06/views/court-close.json" \
  "$HOME/Applications/Evolving Timeline.app/Contents/MacOS/EvolvingTimeline"
```

Use [tool-and-pottery.json](views/tool-and-pottery.json) for a closer look at
the tabletop and vessels.

## Edit and verify

The four meshes are in **Craft Props** under **Evolving Bronze Exports** in the
[editable Bronze Blender library](../../../Assets/BronzeHouse/bronze.blend).
Use the [shared Bronze export workflow](../brz-02/README.md) to refresh the
runtime meshes after editing them.

```sh
./Scripts/verify.sh
build/bin/civheadless bronzecraftcheck build/brz-06
build/bin/civheadless bronzecourtcheck build/brz-06-courts
build/bin/civheadless bronzeenclosurecheck build/brz-06-enclosures
./Scripts/install.sh
```

The craft checker reads uploaded meshes and instance transforms for scale,
clearance, and terrain support. It also checks complete groups, the workbench
tool's metal faces, replay determinism, and era bounds. Two Blender exports
matched byte for byte across all 37 meshes. The original 33 Bronze house meshes
matched the BRZ-05 files.

| Seed | Year | Complete workshops |
|---:|---:|---:|
| 8 | 810 | 4 |
| 8 | 1450 | 7 |
| 8 | 1990 | 8 |
| 1 | 1450 | 9 |
| 10 | 1450 | 9 |

Each workshop supplied a loom, workbench, basket and pottery group, for 148
checked instances across the five Bronze scenes. The seed-8 year-1450
transforms and materials matched bit for bit on replay. The same check
found zero Bronze craft props in the year-790 and year-2010 scenes.

The production build rendered both saved cameras at seed 8, year 1450. The
court and enclosure regressions passed, and city, river and submitted terrain
hashes matched BRZ-05 at seed 8/year 1450 and seed 1/year 2336. The installed
saver presented 94 frames during its three-second smoke check. The installed
Timeline and Player both rendered year 1450, and Timeline navigation passed.
