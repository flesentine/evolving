# NEO-03 inland timber-and-daub houses

Normal Neolithic settlements choose among the square hipped house, the
long gabled house, and the clipped-corner thatched house. All three use
roughly five-metre wall footprints, recessed yard-facing entrances, patches
of repaired daub, and bands of exposed wattle. The [Blender source and
contact sheet](../../../Assets/Neolithic/README.md) include the three new
models and the original prototype. Roof forms and above-ground details
interpret evidence from the Durrington Walls house plans.

The stone skirts extend below the floor origin. The house placement pass
samples the submitted terrain and rejects plots the skirts cannot support.
The existing river-footprint exclusion remains in force. Bronze continues to
use its existing house selection until the transition ticket.

## Inspect the production houses

After running the build and install scripts, launch the installed Timeline
from the repository root with the close camera. This opens a fixed seed-1
review view at year 450 with the normal Neolithic catalog.

```sh
EVOLVING_DEV=1 EVOLVING_NEO01=0 \
  EVOLVING_NEO01_VIEW="$PWD/review/neolithic/neo-03/close.json" \
  "$HOME/Applications/Evolving Timeline.app/Contents/MacOS/EvolvingTimeline"
```

Substitute `overhead.json` for the matched overhead view. The normal Timeline
launch also displays the new housing when browsing the Neolithic on another
seed.

Run `build/bin/civheadless neolithichouses build/neo-03` to check roof coverage,
the selected hamlet's placement, and regenerate the view records and stills.
