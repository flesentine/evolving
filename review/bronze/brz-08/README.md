# BRZ-08 Bronze Age fields and hearths

An eligible court can have a pair of small wheat and barley beds, harvested
bundles, a stone-ring hearth, and a two-handled clay cooking pot. The beds
follow the terrain triangles and use the existing cereal meshes. The cooking
pot is an original stylized model in **Craft Props** in the
[editable Bronze library](../../../Assets/BronzeHouse/bronze.blend).

Placement reserves dry space away from foundations, walking lanes, household
work areas, paddocks, roads, existing fields, river banks and the wet footprint.
A court receives the group only when there is room for both beds and all three
fixtures. Each settlement receives at most one group. The hearth reuses the
existing local light and smoke, with a subtler glow and plume in rain.

## Matched views

The left side shows BRZ-07 and the right side shows BRZ-08. Each pair uses
seed 8, year 1450, and identical camera, clock, and weather settings.

- [Daylight](daylight-before-after.jpg)
- [Dusk](dusk-before-after.jpg)
- [Rain](rain-before-after.jpg)
- [Close view of the dusk hearth](hearth-detail-before-after.jpg)
- [All three weather views in the installed Timeline](timeline-weather.jpg)

## Explore in the installed Timeline

From the repository root, run this to open the dusk view with the hearth
flickering and the year held at 1450.

```sh
EVOLVING_DEV=1 EVOLVING_NEO01=0 EVOLVING_PLAY_REVIEW=1 \
  EVOLVING_NEO01_VIEW="$PWD/review/bronze/brz-08/views/dusk.json" \
  "$HOME/Applications/Evolving Timeline.app/Contents/MacOS/EvolvingTimeline"
```

Use `daylight.json` or `rain.json` to visit the same camera in different light.

## Repeat the checks

```sh
./Scripts/verify.sh
build/bin/civheadless bronzeharvestcheck build/brz-08
build/bin/civheadless neolithicharvest build/brz-08-neolithic
build/bin/civheadless bronzeworkcheck build/brz-08-work
./Scripts/install.sh
```

The harvest checker reads indexed soil triangles and submitted crop and
fixture instances. It checks support and clearance, compares exact rebuild
and dusk replay, and measures daylight cutoff, flicker, plume drift, and
rain damping.

| Seed | Year | Harvest stations | Crop tufts | Soil triangles |
|---:|---:|---:|---:|---:|
| 8 | 810 | 3 | 267 | 164 |
| 8 | 1450 | 6 | 534 | 320 |
| 8 | 1990 | 7 | 622 | 372 |
| 1 | 1450 | 8 | 721 | 416 |
| 10 | 1450 | 9 | 790 | 478 |

The five cases passed, and the Classical scene at year 2010 had no Bronze
harvest geometry. The Neolithic harvest regression and all 108 BRZ-07 work
routines passed. The city, river and submitted terrain hashes matched BRZ-07
at seed 8/year 1450 and seed 1/year 2336. Repeat Blender exports matched
across 43 files, including the 42 prior Bronze meshes.

The standard build, verify and install passed on the Mac. The installed
saver, Player and Timeline bundles matched the verified runtime and cooking
pot. The saver presented frames in the bundle smoke check, Player rendered
year 1450, and Timeline navigation and the three weather views passed.

The three-second bundle smoke count was lower than the earlier BRZ-07 run,
so both versions were measured sequentially in the same seed-1, year-1450
Metal scene at 2560 × 1600. Two uninstrumented 90-frame runs averaged
21.10–22.15 ms/frame on BRZ-07 and 20.57–21.14 ms/frame on BRZ-08. The first
two startup runs averaged about 13% slower on BRZ-08. A profiled repeat
reversed the ordering at 11.52 s on BRZ-07 and 10.01 s on BRZ-08. The samples
were dominated by terrain and river initialization shared by both versions.
The 60-second native presentation comparison remains part of BRZ-13.
