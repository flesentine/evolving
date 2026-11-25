# NEO-05 shared yards and footpaths

Neolithic house groups can share a small packed-earth work yard. Narrow
footpaths begin at the placed entrances. They follow the submitted terrain
and detour where needed, with small stone steps under higher thresholds.
Short wooden fences leave the mapped approaches open.

Each yard needs at least two dry, usable entrances. Placement checks the
full path width against the wet footprint, actual roads, roofs, and
standing props. A yard or path is skipped where the terrain cannot
support it. The same terrain triangles control fields, yards, and paths.
The yard footprint also keeps cultivated plots off the footpaths.

## Review on the Mac

After building and installing, open the installed Timeline from the repository
root with the inland view.

```sh
EVOLVING_DEV=1 EVOLVING_NEO01=0 \
  EVOLVING_NEO01_VIEW="$PWD/review/neolithic/neo-05/inland.json" \
  "$HOME/Applications/Evolving Timeline.app/Contents/MacOS/EvolvingTimeline"
```

The inland view uses seed 1, year 450. Use `coastal.json` for the
stone-house yard in seed 8, year 790. These records fix the seed, year,
daylight, animation time, and camera. Normal Neolithic exploration
also displays the paths, steps, and fences.

Run `build/bin/civheadless neolithicyards build/neo-05` to validate submitted
triangles, door-to-yard coverage, fence openings, and ground contact, and
to regenerate the review views.
