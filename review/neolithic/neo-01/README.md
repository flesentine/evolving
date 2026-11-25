# NEO-01 Atlantic Neolithic reference hamlet

One timber-and-daub house, a kneeling worker at a saddle quern, and a pig stand-in
are staged beside the existing seed 1 hamlet at year 450. This is an opt-in art
review assembled on submitted terrain. The household objects and poses establish
scale for the later modeling and animation tickets.

[Historic England's Durrington Walls record](https://historicengland.org.uk/listing/heritage-gateway/results/record/5079bd59-b1b8-4237-b20f-3bc281dbc435/MWI11907)
describes approximately 5 m square houses, wattle and chalk daub, hearths, and pig
bones. [English Heritage's reconstruction](https://www.english-heritage.org.uk/visit/places/stonehenge/things-to-do/neolithic-houses/)
informed the straw roof and quern. The roof shape, clothing and staging are art
interpretations.

## Reproduce the renders

From the repository root, build with `./Scripts/build.sh`, then run
`build/bin/civheadless neolithicreference build/neo-01` on the Mac. This writes
matched before and after PNGs and all three fixed camera records. The records fix
seed, year, lighting, weather, animation time, camera and viewport.

With the branch installed using `./Scripts/install.sh`, open the same scene in
the native Timeline from the repository root.

```sh
EVOLVING_DEV=1 EVOLVING_NEO01=1 \
  EVOLVING_NEO01_VIEW="$PWD/review/neolithic/neo-01/hamlet.json" \
  "$HOME/Applications/Evolving Timeline.app/Contents/MacOS/EvolvingTimeline"
```

Use `overhead.json` or `island.json` for the other views. Use
`EVOLVING_NEO01=0` for the baseline. The opt-in launch uses a separate simulated
view and does not checkpoint visits to your saved world.

For Blender authoring, run
`/Applications/Blender.app/Contents/MacOS/Blender -b --python-exit-code 1 --python Scripts/build_neolithic_reference.py`.
This rebuilds the three reference meshes using the existing building atlas.
