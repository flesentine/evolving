# NEO-04 exposed stone houses

The Neolithic catalog uses two low dry-stone homes on exposed plots.
One has a rounded turf cover and a short slab entrance. The other has a
longer footprint, a lower turf roof, and a more sheltered slab passage.

The slab walls and passages draw on [Skara Brae](https://www.historicenvironment.scot/visit/all/skara-brae/history-and-stories/).
Skara Brae itself stood beside a freshwater loch. The coastal siting and the
roof forms are interpretations for Evolving's Atlantic island.

A plot must lie on dry ground 4–34 m above sea level. Two adjacent directions
must see open ocean within 160 m, with water continuing farther offshore.
A ridge more than 10 m above the plot screens a direction. The builder then
applies the same submitted-terrain support, dry-footprint and neighboring
house checks as the timber homes. If neither stone footprint fits, it tries
the usual timber house.

## Reproduce the review

The installed Timeline opens these exact review views. Run this from the
repository root.

```sh
EVOLVING_DEV=1 EVOLVING_NEO01=0 \
  EVOLVING_NEO01_VIEW="$PWD/review/neolithic/neo-04/turf-daylight.json" \
  "$HOME/Applications/Evolving Timeline.app/Contents/MacOS/EvolvingTimeline"
```

Choose the matching `turf-rain.json`, `passage-daylight.json`, or
`passage-rain.json` for the other views. Normal Timeline exploration also
uses these houses. Both review plots are in seed 6 at year 790. Each
daylight and rain pair pins the same camera and animation time.

Run `build/bin/civheadless neolithicstone build/neo-04` to check the coastal
fixtures and survey production placement. To render a saved camera through
the CLI, use `build/bin/civheadless riverreview <view.json> <directory> --no-ids`.
The [editable Blender
source and contact sheet](../../../Assets/Neolithic/README.md) contain both homes.
