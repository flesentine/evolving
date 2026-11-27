# NEO-11 Late Neolithic long barrow

A low trapezoidal earthwork with a recessed slab entrance and short forecourt
walls can appear from year 600 until the Bronze Age begins at year 800. The
island gets at most one. Its location uses the submitted terrain and a ridge
with ground falling away on both sides. The entrance faces the nearest living
hamlet. Buildings, crops, paths, waterways, banks, and herd ranges can rule out
a site. An island without a suitable site gets no mound. The grassy surface
uses the same ground material as the surrounding terrain. The portal keeps
its authored stone and earth surfaces.

The long profile, slab portal, and flanking walls draw on British long barrow
examples. The turf, proportions, and simplified stonework are stylized.
[Stoney Littleton](https://www.english-heritage.org.uk/visit/places/stoney-littleton-long-barrow/history/) ·
[Belas Knap](https://www.english-heritage.org.uk/visit/places/belas-knap-long-barrow/history/)

## Explore in Timeline

Run this from the repository root to open the installed Timeline on the fixed
year-600 entrance view for seed 1.

```sh
EVOLVING_DEV=1 EVOLVING_NEO01=0 \
  EVOLVING_NEO01_VIEW="$PWD/review/neolithic/neo-11/entrance.json" \
  "$HOME/Applications/Evolving Timeline.app/Contents/MacOS/EvolvingTimeline"
```

The [mound](mound.json) and [overhead](overhead.json) records show the full
profile and its relationship to the hamlet. The
[editable Blender source](../../../Assets/Neolithic/long-barrow.blend) and
[contact sheet](../../../Assets/Neolithic/long-barrow-sheet.png) are also in
the checkout.

## Matched renders

Each pair shows the NEO-10 build on the left and NEO-11 on the right. Both
use seed 1 at year 600 with identical camera, weather, solar hour, and
animation time.

- [Slab entrance](entrance-before-after.jpg)
- [Full mound beside the river](mound-before-after.jpg)
- [Overhead relationship to Bramufell](overhead-before-after.jpg)

## Reproduce the checks

```sh
build/bin/civheadless neolithicbarrow build/neo-11
```

The check reads the submitted Metal instance and vertex buffers. It checks
ground contact, spacing, ridge exposure, exact placement on rebuild, and the
600 and 800 year boundaries. A separate dry plateau island with a live hamlet
checks that unsuitable terrain suppresses the landmark.

Export the checked-in mesh through the same Blender pipeline as the other
Neolithic assets.

```sh
/Applications/Blender.app/Contents/MacOS/Blender --background --factory-startup \
  --python-exit-code 1 --python Scripts/build_neolithic_reference.py -- \
  --source Assets/Neolithic/long-barrow.blend --sheet Assets/Neolithic/long-barrow-sheet.png
```
