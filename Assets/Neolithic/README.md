# Neolithic Blender source

Open [neolithic.blend](neolithic.blend) in Blender. It contains the editable
timber-and-daub house, the kneeling worker and quern, and the pig from the
[NEO-01 reference hamlet](../../review/neolithic/neo-01/README.md), along with
the three production inland house forms and two exposed stone homes. The .blend
uses the existing building atlas through a relative path within the checkout.

- Edit the meshes in the **Evolving Neolithic Exports** collection. Blender uses
  metres and Z-up. The house entrance faces Blender −Y. The exporter converts to
  the renderer's Y-up convention and reads mesh coordinates relative to each
  object's origin. Object position spaces models apart in the Blender workspace.
- Give export meshes an active UV map and a lowercase, hyphenated name beginning
  `neo01-` or `neolithic-`. The object name is the .civmesh filename. Apply
  rotation and scale and clear parenting before export. Keep ordinary scene
  helpers outside the export collection.
- Keep the house's stone skirt beneath its ground-level origin. It fills the
  downhill side of the foundation in Timeline. The production square hip, long
  gable and clipped-hip models each have a 1.55 m skirt below the floor origin.
  Their roof forms extrapolate from the excavated house plans.

From the repository root, update the runtime assets and regenerate the
[contact sheet](contact-sheet.png).

```sh
/Applications/Blender.app/Contents/MacOS/Blender --background --factory-startup \
  --python-exit-code 1 --python Scripts/build_neolithic_reference.py -- \
  --sheet Assets/Neolithic/contact-sheet.png
```

The exporter writes only named collection meshes under
`Assets/Buildings/variants/`. Send a trial export elsewhere with
`--output /tmp/evolving-neolithic-preview`. Use `--source` to try an alternate
.blend. The contact sheet frames each mesh independently and shows the buried
part of the foundation. Blender runs during asset authoring. Evolving's normal
build consumes the checked-in .civmesh files.

## References

- Roughly 5 m square dwellings, wattle-and-daub walls, and hearth evidence.
  [Historic England's Durrington Walls excavation record](https://historicengland.org.uk/listing/heritage-gateway/results/record/5079bd59-b1b8-4237-b20f-3bc281dbc435/MWI11907)
- Straw roof construction and a saddle quern in use. The roof silhouette and
  worker's clothing are artistic interpretations.
  [English Heritage's experimental houses](https://www.english-heritage.org.uk/visit/places/stonehenge/things-to-do/neolithic-houses/)
- Neolithic cereals, livestock, tools, and pottery.
  [Ashmolean Museum's Neolithic collection](https://britisharchaeology.ashmus.ox.ac.uk/collections/neolithic.html)
- Slab construction, sheltered passages, and low walls for the exposed stone
  homes. The turf roofs and coastal setting are interpretations.
  [Historic Environment Scotland's Skara Brae guide](https://www.historicenvironment.scot/visit/all/skara-brae/history-and-stories/)
