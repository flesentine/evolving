# NEO-06 Household tools and storage

The shared yard gets a saddle quern and handstone, a plain clay pot, and a
banded woven basket. A hafted polished stone axe and a stack of split firewood
sit near a house. These props use metre-scale meshes in the shared Neolithic
Blender source. Pottery is undecorated so it can appear throughout the era.

The placement pass checks roads, banks, the wet footprint, doorway paths,
fences, buildings, crops, and other props. A prop is omitted when the available
space is occupied or the submitted terrain is too uneven to support it.

The stone blade and plain vessel draw on objects in the
[Ashmolean Neolithic collection](https://britisharchaeology.ashmus.ox.ac.uk/collections/neolithic.html).
The grinding setup follows the quern and rider demonstrated at the
[English Heritage Neolithic houses](https://www.english-heritage.org.uk/visit/places/stonehenge/things-to-do/neolithic-houses/).
The haft, basket, and firewood pile are stylized interpretations.

## Review in Timeline

After installing the build, run this from the feature checkout to open the
work corner at seed 1, year 450.

```sh
EVOLVING_DEV=1 EVOLVING_NEO01=0 \
  EVOLVING_NEO01_VIEW="$PWD/review/neolithic/neo-06/neolithic-prop-quern.json" \
  "$HOME/Applications/Evolving Timeline.app/Contents/MacOS/EvolvingTimeline"
```

The other saved cameras focus on the pottery, basket, axe, and wood stack.
`inland.json` opens the original NEO-05 overview of the same hamlet. The
[work corner comparison](before-after.jpg) and [hamlet comparison](overview-before-after.jpg)
use matched before-and-after cameras. The [placed prop gallery](props.jpg)
shows all five items at ground level.

Run `build/bin/civheadless neolithicprops build/neo-06` to reproduce the
captures and verify grounding, exclusion and replay from the renderer's
instance buffers. Edit the five objects in [the Neolithic Blender source](../../../Assets/Neolithic/neolithic.blend) and use
[the existing exporter](../../../Assets/Neolithic/README.md) to update the
runtime meshes.
