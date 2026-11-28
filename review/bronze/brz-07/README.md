# BRZ-07 Bronze Age clothing and work loops

The actors wear belted tunics in flax and umber tones, with sleeves and
leggings authored in Blender. The garment cuts are an interpretation. Must
Farm's surviving fibres, textiles and loom weights inform the workshop
details. [Must Farm excavation project](https://www.mustfarm.com/bronze-age-settlement/about/)

The weaver stands in front of the existing weighted loom and works a wooden
shuttle across the warp. A kneeling potter works both hands around the taller
clay jar's rim. The basket carrier walks across a submitted court, pauses, turns,
and carries the basket back. Stable seed and town IDs set the phases. Each
pose uses absolute animation time and the rendered terrain or court height.

## Matched views

All four comparisons use seed 8 at year 1450. BRZ-06 is on the left and
BRZ-07 is on the right.

- [Workshop overview](workshop-before-after.jpg)
- [Weaving](weaving-before-after.jpg)
- [Pottery shaping](shaping-before-after.jpg)
- [Basket carrying](carrying-before-after.jpg)

The new Blender parts are in **Clothing and Work** inside the
[editable Bronze library](../../../Assets/BronzeHouse/bronze.blend).
Two exports from the shared pipeline matched across all 42 assets, including
the 37 previously exported meshes.

## Try the workshop on your Mac

From the repository root, open the exact saved weaving pose in the installed
Timeline.

```sh
EVOLVING_DEV=1 EVOLVING_NEO01=0 \
  EVOLVING_NEO01_VIEW="$PWD/review/bronze/brz-07/views/weaving.json" \
  "$HOME/Applications/Evolving Timeline.app/Contents/MacOS/EvolvingTimeline"
```

Add `EVOLVING_PLAY_REVIEW=1` to let the animation clock run at normal speed
while the camera and historical year stay fixed. Use the corresponding saved
view for [pottery shaping](views/shaping.json) or [basket carrying](views/carrying.json).

## Repeat the checks

```sh
./Scripts/verify.sh
build/bin/civheadless bronzeworkcheck build/brz-07
build/bin/civheadless bronzecraftcheck build/brz-07-craft
./Scripts/install.sh
```

The work checker samples each complete cycle, checks work-pad and route
clearance, and measures movement of the hands, shuttle, and carried basket.
It reads the submitted Metal instances, advances the animation, and opens
the same saved view again to compare the poses and rendered stills.

The work checker passed 108 routines across seed 8 at years 810, 1450 and
1990, plus seeds 1 and 10 at year 1450. All three saved routines reproduced
identical Metal instances and byte-identical rendered PNGs. The BRZ-06
regression check passed 148 craft props. City, river and submitted terrain
hashes matched BRZ-06 at seed 8/year 1450 and seed 1/year 2336. The standard
build and verification script also passed, including bundle loading and the
world lifecycle checks.

The installed saver presented 105 frames in its three-second bundle smoke
test at year 1450. Timeline navigation passed, and the installed Timeline
and Player both rendered Metal frames at year 1450.
