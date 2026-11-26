# NEO-10 Herds around Neolithic hamlets

Sheep graze in small flocks on dry pasture. Cattle use a larger range on
flatter land. Pigs root near the edges of work yards and early camps. Each
herd has a seed-derived route, spacing, and phase. Individuals lower their
heads at slightly different times during stops, and pigs shift their snouts
while rooting.

Before a group is placed, its entire swept footprint must clear buildings,
trees, paths, crops, waterways, banks, and other herds. The initial search
checks terrain and hoof support at points along each walk. Groups stay on
their accepted routes through walking and feeding. A hamlet can have fewer
herds when the ground is unsuitable.

This build brings the NEO-09 Blender livestock into the same Timeline as the
NEO-08 fields and hearths. The route choices model visual activity at the
hamlet scale.

## Review in Timeline

From the feature checkout, open the installed Timeline with a fixed view of
the hamlet and pigs.

```sh
EVOLVING_DEV=1 EVOLVING_NEO01=0 \
  EVOLVING_NEO01_VIEW="$PWD/review/neolithic/neo-10/hamlet-edge.json" \
  "$HOME/Applications/Evolving Timeline.app/Contents/MacOS/EvolvingTimeline"
```

Use the sheep, cattle, and pig records to see the same camera in the walking
and feeding phases. Open Timeline normally and select Neolithic to watch the
routes loop live.

The [walking and feeding gallery](herds.jpg) shows sheep, cattle, and pigs
from top to bottom. The [hamlet view](hamlet-edge-before-after.jpg) and
[cattle pasture](cattle-feed-before-after.jpg) use matched cameras against
the NEO-08 build. There is also a [matched installed Timeline view](native-hamlet-before-after.jpg)
and an [installed herd gallery](native-herds.jpg).

## Reproduce the checks

```sh
build/bin/civheadless neolithicherds build/neo-10
build/bin/civheadless neolithicanimals build/neo-09-regression
```

The herd check exercises each accepted route over at least one traversal,
verifies the submitted pose buffers, and renders the saved views. The earlier
asset check verifies the 15 authored models against the integrated renderer.
