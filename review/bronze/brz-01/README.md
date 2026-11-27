# BRZ-01 Norimton roof repair

The fixed views show Norimton, seed 8, year 810. Each pair compares the
merged Neolithic release on the left with the rebuilt Bronze Age assets on
the right. The camera, daylight, season, and animation time match.

- [Walk-up view of the prototype roundhouse](prototype-before-after.jpg)
- [Close settlement view](close-before-after.jpg)
- [Opposite approach](opposite-before-after.jpg)
- [Overhead](overhead-before-after.jpg)
- [Island](island-before-after.jpg)

The cone generator used a single direction to choose roof winding around
the whole house. Metal's back-face culling discarded sectors that faced
inward. The wall and footing rings also had reversed faces, and the
under-eave ring used the wrong coordinates. The rebuilt Bronze family has a
consistently oriented shell and a concentric soffit. The repair keeps the
roof profiles, doors, and existing settlement placement. The walk-up view
shows the existing lane crossing a house in both builds. BRZ-04 covers
court and path placement.

## Play the view on your Mac

From the repository root, launch the installed Timeline at Norimton.

```sh
EVOLVING_DEV=1 EVOLVING_NEO01=0 \
  EVOLVING_NEO01_VIEW="$PWD/review/bronze/brz-01/views/close.json" \
  "$HOME/Applications/Evolving Timeline.app/Contents/MacOS/EvolvingTimeline"
```

Replace `close.json` with `opposite.json`, `overhead.json`, or `island.json`
for the other matched views. Use `prototype.json` to walk up to the tested
roundhouse, `bronze-07`.

## Reproduce the repair and checks

```sh
/Applications/Blender.app/Contents/MacOS/Blender --background --factory-startup \
  --python-exit-code 1 --python Scripts/build_variants.py -- --bronze-only
./Scripts/verify.sh
build/bin/civheadless bronzeroofcheck build/brz-01
build/bin/civheadless neolithictransition build/brz-01-transition
```

The roof fixture casts horizontal and overhead rays against the indexed
thatch triangles in the renderer's Metal buffers. The nearest roof hit
must survive back-face culling. This catches the missing facing sector even
when the opposite half of a two-sided mesh would conceal the gap.

The baseline missed 2,304 of 7,200 probe rays. All 7,200 passed after the
repair across the 30 uploaded roof meshes. The seed-8, year-810 settlement,
river, and submitted terrain hashes match the baseline. The Neolithic-to-Bronze
continuity check still finds the same two recognizable Norimton houses.
