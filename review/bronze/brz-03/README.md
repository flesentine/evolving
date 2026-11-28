# BRZ-03 Bronze Age roundhouse family

Bronze Age residential and farm plots now select three editable Blender homes.
The timber-and-daub home has exposed posts and a compact conical roof. The
porched home has a deeper supported eave over its recessed entrance. The
upland home has a lower roof and slab-footed walls. The stone footing and
covered entrance are stylized interpretations of evidence from Dartmoor.
[English Heritage's Grimspound history](https://www.english-heritage.org.uk/visit/places/grimspound/history/)

Placement checks the rotated bounds against standing water and the submitted
river footprint. It seats each doorstep on the submitted ground and uses a
buried skirt and posts to remain grounded on modest grades. Stone-footed homes
are eligible on plots at 28 m or higher. BRZ-04 covers the settlement plan,
including roads and canals.

## Matched production renders

The left image uses BRZ-02 and the right uses BRZ-03. All six pairs use
seed 8, year 1450, and the same camera, lighting and animation time on both
sides. The views retain the visible lane and barrier intersections in both
builds so BRZ-04 can use them as placement references.

| Form | Close | Overhead |
|---|---|---|
| Timber and daub | [Close](timber-daub-close-before-after.jpg) | [Overhead](timber-daub-overhead-before-after.jpg) |
| Deeper porch | [Close](porched-close-before-after.jpg) | [Overhead](porched-overhead-before-after.jpg) |
| Upland stone-footed | [Close](upland-stone-close-before-after.jpg) | [Overhead](upland-stone-overhead-before-after.jpg) |

[Installed Timeline comparison](timeline-before-after.jpg) shows the same porch
view with the app controls visible. The final build reproduced the offscreen
porch still pixel for pixel.

## Explore the installed build

From the repository root, open the matched porch view in Timeline.

```sh
EVOLVING_DEV=1 EVOLVING_NEO01=0 \
  EVOLVING_NEO01_VIEW="$PWD/review/bronze/brz-03/views/porched-close.json" \
  "$HOME/Applications/Evolving Timeline.app/Contents/MacOS/EvolvingTimeline"
```

Use the other [saved views](views/) to visit the rest of the family. Open
Evolving Player from `~/Applications` or select Evolving in System Settings
under Screen Saver for the same installed assets.

## Export and verify

Edit the new models in [the Bronze Blender collection](../../../Assets/BronzeHouse/bronze.blend).
The shared export workflow is documented in [BRZ-02](../brz-02/README.md).
Two fresh exports agreed byte for byte across all 33 meshes. The original 30
meshes still match the BRZ-02 files.

```sh
./Scripts/verify.sh
build/bin/civheadless bronzefamilycheck build/brz-03
build/bin/civheadless bronzeroofcheck
build/bin/civheadless neolithictransition build/brz-03-transition
build/bin/civheadless determinism 1450 8
build/bin/civheadless determinism 2336 1
./Scripts/install.sh
```

The family check reads the uploaded triangles and tests 1,935 rooftop rays
under back-face culling. It checks the skirt vertices and the dry footprint
of every submitted new home in the three seed-8 Bronze review years.

| Year | Timber and daub | Deeper porch | Upland stone |
|---|---:|---:|---:|
| 810 | 29 | 13 | 0 |
| 1450 | 45 | 33 | 4 |
| 1990 | 68 | 49 | 5 |

The 30 legacy roofs passed 7,200 coverage probes. Norimton retained its two
reviewed Neolithic home footprints into year 810. The two determinism runs
matched each other and the BRZ-02 river and submitted-terrain hashes. In the
year-1450 city geometry diagnostic, building count fell from 209 to 170
with the more conservative foundation and water fit for domestic plots.

The checker rejected a fixture with the porch tips raised through the roof
and passed all three production forms. The installed saver presented frames
at year 1450, the Timeline navigation check passed, and the installed Timeline
and Player both completed Metal frames in the Bronze scene.
