# BRZ-04 Bronze Age courts and paths

Bronze households now face small clearings with worn-earth approaches. Nearby
courts connect with direct or bent footpaths where the ground is walkable.
The layout leaves the simulation's settlement centres and island road and
crossing builders in place. The old processional streets, temple platforms,
wall rings, and ornamental canals are gone from Bronze town layouts.

The renderer replays year 799 and reserves eligible inherited footprints before
it fits Bronze courts, house foundations, or paths. An eligible court may retain
up to four homes at their original transforms. At Norimton this preserves both
homes from the NEO-12 review. Path triangles come from the submitted terrain
mesh and pedestrians follow covered lanes. Farm workers still use the existing
fieldwork system.

## Matched views

The left side uses BRZ-03 and the right side uses BRZ-04. Each pair uses the
same seed, camera, year, light, and animation time.

| View | Comparison |
|---|---|
| Norimton at year 810 | [Hamlet](hamlet-810-before-after.jpg) · [Overhead](overhead-810-before-after.jpg) |
| Occupied Bronze court at year 1450 | [Close](court-close-1450-before-after.jpg) · [Overhead](court-overhead-1450-before-after.jpg) |
| Previous lane-intersection case | [Overhead at year 1450](legacy-lane-1450-before-after.jpg) |

The [Norimton transition](norimton-790-810.jpg) pairs years 790 and 810 using
the archived NEO-12 camera. The year-790 image matched BRZ-03 pixel for pixel.

The [installed Timeline comparison](timeline-before-after.jpg) shows the
year-1450 court in both native windows, with the island crossing in view.

## Open the installed Timeline

From the repository root, open the new court view.

```sh
EVOLVING_DEV=1 EVOLVING_NEO01=0 \
  EVOLVING_NEO01_VIEW="$PWD/review/bronze/brz-04/views/court-close-1450.json" \
  "$HOME/Applications/Evolving Timeline.app/Contents/MacOS/EvolvingTimeline"
```

Use [hamlet-810.json](views/hamlet-810.json) for Norimton's transition scene.
The same assets and layout are installed in Evolving Player and the saver.

## Validation

```sh
./Scripts/verify.sh
build/bin/civheadless bronzecourtcheck build/brz-04
build/bin/civheadless neolithictransition build/brz-04-transition
build/bin/civheadless bronzeroofcheck
build/bin/civheadless bronzefamilycheck build/brz-04-roofs
build/bin/civheadless bridgefixtures
build/bin/civheadless determinism 1450 8
build/bin/civheadless determinism 2336 1
./Scripts/install.sh
```

The court checker reads submitted house instance buffers and indexed ground
triangles. It checks the 4 cm terrain lift, roof-footprint clearance, each
new home's approach, and covered walking lanes.

| Seed | Year | Domestic plots | Courts | Walks | Ground triangles |
|---:|---:|---:|---:|---:|---:|
| 8 | 810 | 19 | 8 | 23 | 502 |
| 8 | 1450 | 66 | 25 | 78 | 1,664 |
| 8 | 1990 | 92 | 33 | 103 | 2,060 |
| 1 | 1450 | 67 | 24 | 73 | 1,419 |
| 10 | 1450 | 70 | 25 | 80 | 1,677 |

The inheritance check found the same transforms on direct open and scrub for
seeds 1, 8, and 10. The Norimton-specific check located the two houses from the
archived camera and confirmed both transforms. The roof and crossing
regressions passed. The year-1450 layout hash changed as expected. The river
and submitted terrain hashes matched BRZ-03 at seed 8/year 1450 and
seed 1/year 2336.

The built renderer reproduced the year-1450 court screenshot pixel for pixel.
The installed saver presented 93 frames in the three-second smoke test.
Timeline navigation passed and both installed apps rendered year 1450.
