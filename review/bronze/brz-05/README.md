# BRZ-05 Bronze Age upland enclosures

Some upland courts now have a small paddock with a low earth bank and individual
stones set into it. A short companion field boundary appears if there is room
beside the paddock. Dartmoor's stone-and-earth reaves and the pens at Grimspound
informed the shapes. [English Heritage on Dartmoor](https://www.english-heritage.org.uk/dartmoor/) · [English Heritage on Grimspound](https://www.english-heritage.org.uk/visit/places/grimspound/history/)

The paddock measures about 9.3 by 7.4 metres, with a 2.6-metre opening. A dirt
approach runs from an occupied court through that opening. The siting code checks
the submitted crop, road, walking-lane, building, river and bank footprints.
If the terrain, clearance, or rendered approach cannot support the enclosure,
the renderer skips the site. Each settlement gets at most one paddock.

## Matched renders

Each pair uses the same seed, year, camera, lighting and animation time.
BRZ-04 is on the left and BRZ-05 is on the right.

- [Gate and stonework close-up](gate-close-before-after.jpg)
- [Overhead view of the court-to-gate approach](court-access-overhead-before-after.jpg)
- [Installed Timeline windows at year 1450](timeline-before-after.jpg)

## Open the installed Timeline

From the repository root, open the exact gate view.

```sh
EVOLVING_DEV=1 EVOLVING_NEO01=0 \
  EVOLVING_NEO01_VIEW="$PWD/review/bronze/brz-05/views/gate-close.json" \
  "$HOME/Applications/Evolving Timeline.app/Contents/MacOS/EvolvingTimeline"
```

Use [court-access-overhead.json](views/court-access-overhead.json) to replay
the overhead view. Open **Evolving Player** from Applications or select
**Evolving** in System Settings under **Screen Saver** to use the same build.

## Validation

```sh
./Scripts/verify.sh
build/bin/civheadless bronzeenclosurecheck build/brz-05
build/bin/civheadless bronzecourtcheck build/brz-05-courts
build/bin/civheadless determinism 1450 8
build/bin/civheadless determinism 2336 1
./Scripts/install.sh
```

The enclosure checker reads submitted bank vertices and indexed approach
triangles. It checks bank relief and buried toes, measures the opening against
the bank footprint, and follows the actual path coverage from the court into
the paddock. A controlled flat site admits a paddock. The inundated, steep,
and occupied-crop fixtures suppress it.

| Seed | Year | Paddocks | Companion reaves |
|---:|---:|---:|---:|
| 8 | 810 | 1 | 1 |
| 8 | 1450 | 4 | 3 |
| 8 | 1990 | 4 | 3 |
| 1 | 1450 | 2 | 2 |
| 10 | 1450 | 1 | 1 |

The enclosure and approach vertices and indices matched bit for bit on replay
at seed 8, year 1450. The Classical scene at year 2010 submitted no Bronze
enclosure meshes.

The built renderer reproduced both comparison stills pixel for pixel. The court
regression passed, and city, river and submitted terrain hashes matched BRZ-04
at seed 8/year 1450 and seed 1/year 2336. The installed saver presented 87 frames
in its three-second smoke check. Timeline navigation passed, and both installed
apps rendered year 1450.
