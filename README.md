# Evolving

A macOS screen saver that renders one persistent 3D island valley whose civilisation grows and
modernises from the Neolithic to the near future. The **only input is real elapsed time**: close
the lid for a month, open it, and the world has moved on.

```
elapsed real time ──► sim year ──► deterministic replay ──► 3D scene
```

## Requirements

- macOS 13 or later, Apple Silicon (the build targets `arm64-apple-macos13.0`)
- Xcode command-line tools (`swiftc`, `clang`, `codesign`)
- No Xcode project and no Metal toolchain download required — shaders are compiled at runtime

## Build, install, verify

```sh
./Scripts/build.sh     # builds build/Evolving.saver and build/bin/civheadless
./Scripts/install.sh   # copies the .saver to ~/Library/Screen Savers
./Scripts/verify.sh    # checks the bundle presents frames and renders years 500/5000/10000
```

Then open **System Settings → Screen Saver**, pick **Evolving**, and press **Screen Saver Options**
to choose a pace or start a new world. If it does not appear, quit System Settings completely and
reopen it.

## How it works

- **Time.** A piecewise `Pace` maps real days onto simulated years. `Standard` reaches the
  near future in about 20 real months, with early eras passing quickly and modern eras slowing
  down. `Chronicle` is ~4× slower; `Time-lapse` finishes in about three months.
- **Nothing is saved but the seed.** The entire world — terrain, settlements, roads, buildings —
  is a deterministic function of `{seed, epoch, pace}`. On launch the sim is replayed from
  genesis to the present year, which takes a couple of milliseconds for 10,000 years. Closing the
  lid for a month is just a larger replay, not a special case.
- **Buildings are derived.** A settlement's building set is a pure function of its id,
  population, era and the local terrain, so no scene state needs to be persisted.
- **Towers gain detail with the era.** Flat roof caps, rooftop clutter, antennae and faint floor
  bands appear as the civilisation modernises, so a close-up reads as a city rather than a field
  of boxes.
- **Night life.** From the Industrial era, warm street lamps line the roads. At night the road
  network becomes a web of light between the lit towers; by day the posts nearly vanish.
- **Traffic and boats.** From the Bronze Age ox carts creak along the roads; from the modern era
  cars with headlights take over. From the classical era sailing boats circle the island. All are
  positioned from wall-clock time, so they stay in step with the world.
- **Town plan.** Every era has its own settlement planner, driven by a deterministic resource map
  (soil, water, timber, stone, ore, coast, buildability, route access). Neolithic hamlets cluster
  around yards with no streets; Bronze Age towns centre on a raised temple inside a wall with a
  canal to the gate; Classical towns use a grid with an acropolis and agora; Medieval towns pack
  narrow burgage plots along a market street; Renaissance towns lay radial boulevards and a piazza
  over the old fabric; Industrial towns follow water and rail with terraces and a villa quarter;
  Modern towns get a ring road and suburbs; Information and Future towns cluster towers at transit
  nodes with parks between them. Buildings always sit on street-fronting plots, aligned and clamped: each mesh is measured once and its footprint is fitted inside the plot, while density/landmark multipliers affect height only. and roads are
  rejected when they cross water or climb steeper than a 0.35 grade. Road surfaces are
era-specific and procedurally shaded: braided earth tracks with hollow-way banks,
  cambered Roman paving with kerbs, cobbles, setts, macadam and asphalt, with fords
  giving way to stone, iron and concrete bridges.
- **Blender building set.** Every house in a town is a Blender-authored mesh from a pool of
  **30 variants per era** across all nine eras (huts, roundhouses, villas, timber-framed
  houses, townhouses, brick terraces, modern houses and towers) — 270 buildings in total. Variants vary width, depth, storeys, roof type, frontage and
  detail (porticoes, timber frames, shopfronts, balconies, dormers, quoins, chimneys). Houses are
  picked with a neighbour rule that avoids repeats, carry a small per-instance colour palette,
  and some sit back behind low garden walls. A share of older housing survives into each era.
  Information/future towers come with podiums, twin shafts and skybridges, terraced or lantern
  crowns, four façade systems and brick, stone or metal cladding; dense eras keep some plots open as small parks. Imported
  buildings light a stable subset of their windows at night, a generated normal map adds surface
  relief to thatch, stone, timber, brick and roof tiles, and glass reflects the sky with a
  Fresnel response that warms at sunset.
  Models share one 2048² atlas and export to `.civmesh`; regenerate with
  `Scripts/build_variants.py` and rebuild with `Scripts/build_asset.sh`.
- **Model detail.** Early houses carry real geometry, not just paint: doors with stone steps and
  timber lintels, recessed window panes with glazing bars, sills and painted shutters, roof ridge
  tiles, eaves boards and chimney pots. The well has a kerb, posts and a tiled roof, and stalls
  come with produce crates.
- **Era detail.** Classical villas get quoins, pedimented windows, steps and a fountain; medieval
  houses get diagonal braces, jetty brackets, a door canopy, hanging sign and dormer; industrial
  terraces get shopfronts, string courses and chimney pots; modern houses get balcony railings,
  entrance canopies, mullions and rooftop plant. Plazas gain benches, bollards, planters or a
  market cross depending on the age.
- **Street life.** People are articulated: separate bodies, heads with caps, and legs and arms that
  swing through a walk cycle as they move along every street in the grid. Livestock have horns,
  ears and tails; ox carts have spoked wheels and a beast in the shafts; cars have cabins, wheels
  and headlights; boats have a pointed hull, mast and sail. **Street** and **Square** camera presets
  put you down among them, from a low 3/4 view to a close orbit just outside the town.
- **Land use.** Cultivated plots ring each settlement, coloured by the era's crops, and the forest
  thins as the city footprint grows. Crops rotate every 12 simulated years, so the patchwork
  changes as the world ages.
- **Road network.** Pathfinding is era-weighted: early roads avoid wet ground and climb
  ridges, classical roads pull toward straight surveyed alignments between hub towns,
  medieval roads converge on the largest market, industrial roads favour gentle turnpike
  grades and reuse existing corridors, and modern roads form a direct arterial hierarchy.
  Crossing rivers uses fords early and stone, iron or concrete bridges later.
  Road furniture follows the same logic: cairns on prehistoric ridges, milestones from
  the Roman era, signposts at town approaches, tollhouses on industrial turnpikes, and
  cat's eyes on modern roads, with per-segment widths for arterial, lane and track.
  Signposts and milestones carry atlas-rendered inscriptions, town gates carry the
  settlement's own name in that town's typeface, a unique crest and a settlement-specific era emblem, tollhouses show lit windows at night, traffic signals at a
  junction share a phase with cross-directions running half a cycle apart, longer
  green on busier roads, adapting to measured queue lengths, and a green wave whose spacing follows measured car speeds,
  and wet roads darken, reflect the sky, form camber-draining puddles and throw
  spray behind cars in proportion to local puddle-prone ground, pulsing with the puddle ripple phase.
- **River channels.** The rendered network is terrain-driven: true gradient (slope)
  routing on a stream-power-conditioned heightfield, one priority-flood spill per sink,
  topological contributing-area accumulation on the final receiver graph, and a channel
  mask derived from that final area. Reaches split at real confluences; first-order
  sources are thinned to one per 180 m. Corner-cutting subdivision prevents self-loops,
  and a four-harmonic meander with a slow envelope and a bend-radius clamp shapes the
  plan. Three stream-power routing passes merge adjacent parallel rills before the graph
  is built. The gate measures the canal artefact directly: the greatest number of
  separate channel runs in a 250 m span of one row is 5–9 across seeds.
  The water surface is one connected downstream-non-increasing profile: the local
  centreline bed plus 0.6 m, lowered at each junction to the lowest incident end. The
  gate reports a 0.000 m junction step, 0.000 m downstream water rise and a valid
  drainage-forest identity. Headwaters taper from a couple of metres to the full
  channel, and endorheic basin ends are rounded into tarns (5 on seed 1, capped at 30%
  of reaches). Widths scale with final contributing area (3–21.6 m on seed 1), with
  narrow headwaters and wider trunks. Closed-basin ends are drawn as small round tarns.
  The water
  carries depth in its vertex alpha and is shaded as a shore-to-deep ramp with
  flow-aligned ripples, grazing sky reflection, a faint sun glint and depth-driven
  shoreline foam. The rendered terrain is upsampled 2× and carved as a slope-limited
  valley: a 4 m wet shelf just below the water, then a 0.55 grade back to the hillside,
  with the bank profile heights sampled from that carved surface. Every junction is one
  Y-shaped water polygon built from the trimmed incident cross-sections (no disc, no
  deck lift, no overlapping ribbon ends). The scene uses one carved terrain for the terrain
  mesh and every placement, so buildings, roads and trees sit on the valley floor. The
  natural crest is 0.35 m, capped at 2 m on steep cuts, so an ordinary hillside gets a
  valley rather than a vertical trench or a levee.
  Streets, plots, houses and crop fields are clipped against the same rendered water
  field, road crossings are keyed to it so each deck spans the water it actually sees,
  and civic paving is skipped when a settlement centre lands on a distributary.
  On seed 1 the gate reports 69 reaches and 60 linked reaches, 24 graph sources
  (19 flagged pre-prune), 15 real junctions, 4 mouths and 5 tarns; a 0.33 m minimum
  bank lip (mean 0.38 m); 0.60 m water depth; 1.3–1.8 m wet margin; exact 3158/3158
  waterline welds; zero
  bed-exposure probes; zero submerged trees, buildings or road surface; zero
  self-intersections; 0.000 m junction step; 0.000 m water rise; and 5 maximum parallel
  runs (`civheadless river [seed] [year]`). The remaining close-range artefact is the
  2.6 m heightfield itself at extreme zoom; the routing valleys are still only in the
  routing surface, not carved into the visible terrain.
- **Infrastructure.** Roads cross rivers on raised decks. Medieval towns get curtain walls and towers that enclose whole rings of the historic core, leave the outer rings as suburbs, align gates with the actual roads, follow the core's irregular outline, and shrink or disappear where a neighbouring town leaves no room; a few coastal
  outposts have a hut, a pier and a moored boat. From the Industrial era a railway with sleepers
  and a moving train runs along the longest road, and chimneys trail soft smoke plumes.
- **History, not just growth.** Seeded events (plague, fire, war, drought, boom, quake) set a
  settlement back and let it rebuild, and are reported in the chronicle line on the HUD. Refugees
  flee to the nearest town, and towns that trade with neighbours grow faster. Recent disasters
  char the buildings and scatter rubble; a town that cannot recover is abandoned and leaves a
  scorched ruin that stays on the map.
- **Urban consolidation.** From the Industrial era onward the smallest towns are absorbed by
  larger neighbours, so late eras settle into fewer, larger cities with open land between them
  instead of a carpet of villages.
- **Preview any point in the arc.** Development builds honour `EVOLVING_DEV=1`,
  `EVOLVING_AGE_DAYS=<days>` and `EVOLVING_PACE=Standard` when launched directly, which lets the
  player open at, say, the Information Age without waiting months.
- **Resolution.** Frame-time-driven dynamic resolution keeps the scene near native on mid-size displays and steps
  down gracefully on 4K/6K ones, resolves through a light unsharp pass, and dithers the final
  image so wide sky gradients do not band. Shadows are 4K, tiles and timber get surface detail,
  and the ground carries mottling and crop rows instead of flat colour.
- **The real sky.** The sun's position comes from your local time of day, so the city lights up
  at night and the scene is daylight when you are.
- **The real season.** Foliage shifts from green to ochre to grey and the snowline drops as the
  actual month advances, so the valley in January is not the valley in July. The hemisphere is
  detected from your region (override with `EVOLVING_HEMISPHERE`).
- **Returning.** If you have been away for more than an hour, the saver replays to your last visit
  and then to now, and reports what actually changed: years passed, population before → after,
  towns founded or abandoned, a new age, or the worst disaster in between.
- **Weather and camera.** Soft cloud shadows drift across the island, dimming the sun and the
  water glints. Rain or snow falls when the real weather turns, with an overcast sky, dimmed sun
  and occasional lightning; birds circle the island. The camera cycles through a wide orbit, a low drift along the
  coast, and a slow push into the largest city.
- **Sun shadows.** A 2048² shadow map is rendered from the real sun direction each frame, with
  normal-offset biasing and 3×3 PCF, so buildings, trees and mountains ground themselves in the
  landscape and the light changes through the day.
- **Ambient occlusion.** Terrain concavity is baked into the height field (valleys and mountain
  bases sit darker), and building walls darken toward their base, so structures feel planted
  rather than floating.
- **Sky and clouds.** A world-locked procedural cloud deck drifts over the island, lit by the same
  sun as the ground; it thickens with the weather and goes dark at night.
- **Reflective water.** The sea reflects the actual sky and cloud deck through a Schlick fresnel
  term, so it shifts from deep blue when you look down to a pale mirrored horizon; foam runs up
  the shoreline in moving bands.
- **Building detail.** Towers carry a procedural window grid by day as well as lit windows by
  night, with floor bands, mullions, setbacks and rooftop clutter. Pre-industrial houses get
  pitched gable roofs with eaves, stone plinths and the odd chimney. Their walls carry procedural
  plaster-and-timber framing and small windows, plinths use running-bond stone, and roofs show
  shingle rows. Trees are two-tier conifers with trunks, and modern roads get dashed centre lines.
- **Grade and lens.** A final grade adds gentle contrast and split toning (cool shadows, warm
  highlights) with extra warmth at golden hour, plus a soft vignette, fine grain and a subtle
  chromatic fringe at the frame edges.
- **The miniature look.** The scene renders with 4× MSAA into an offscreen target and is
  composited with a tilt-shift depth-of-field band, a light bloom on bright windows, a vignette
  and a whisper of grain. Blur radius is resolution-independent, so the diorama reads the same on
  any display. On very large displays the scene pass is capped at ~6 MP and upscaled by the post
  pass.

State lives in `ScreenSaverDefaults`:
`~/Library/Preferences/ByHost/com.mccullough.evolving.<uuid>.plist`.

The System Settings preview is read-only: it never updates `lastSeen` and never shows the
"while you were away" recap, so previewing cannot erase a real absence.

## Options

- **Pace** — Chronicle / Standard / Time-lapse
- **Seed** — type one or press *Randomise*
- **Start a new world now** — resets the epoch to this moment
- **Southern hemisphere** — flips the seasonal calendar; otherwise detected from your region

Changing the seed or starting over resets the world to year 0.

## Companion app

`Scripts/build.sh` also builds **Evolving Companion.app**, and `Scripts/install.sh` copies it to
`~/Applications`. It reads the same `ScreenSaverDefaults` domain as the saver and shows the
current year, era, population, settlement count and latest chronicle entry, with:

- a scrollable history of the chronicle (last 150 entries)
- a pace selector and **Apply**
- **Screen Saver Settings…** and **Preview** shortcuts
- **New World** (resets the epoch to now)

## Timeline app

**Evolving Timeline.app** is a standalone viewer for scrubbing the whole arc without touching
Screen Saver settings. Launch it from `~/Applications` or with:

```sh
open "$HOME/Applications/Evolving Timeline.app"
```

- drag the year slider from 0 to 12,000,
- **Play/Pause** advances the world continuously, with a **0.5×–25× speed menu**,
- the era menu jumps to any age,
- **Live** returns to wall-clock time,
- left/right arrows step 10 years (Shift = 100), Space toggles play, Esc quits,
- **drag** to orbit the camera, **scroll** or pinch to zoom, **right-drag** to pan,
- double-click the view or press **Auto** to return to the automatic camera.

Moving forward is incremental; moving backward replays the deterministic world from the seed,
which takes about one frame at normal speed.

## Signing and notarization

`Scripts/build.sh` signs with a **Developer ID Application** identity from your keychain when one
is present (hardened runtime + secure timestamp), and falls back to an ad-hoc signature otherwise.
Override with `EVOLVING_SIGN_IDENTITY="Developer ID Application: …"`.

To notarize, store notary credentials once:

```sh
xcrun notarytool store-credentials evolving-notary \
  --apple-id <your-apple-id> --team-id <TEAMID> \
  --password <app-specific-password>
```

then run:

```sh
NOTARY_PROFILE=evolving-notary Scripts/notarize.sh
```

The script zips, submits and staples both the `.saver` and the companion app. Without credentials
it exits with those instructions.

## Development tool

`build/bin/civheadless` runs the same core without the screen saver host:

```sh
# Render a still at a simulated year (hour is local time of day, 0–24)
build/bin/civheadless sim build/year-7400.png 7400 10 1

# Add a camera time in seconds to sample the two-shot camera cycle
build/bin/civheadless sim build/close.png 7400 10 1 70

# Print the river network and channel gate
build/bin/civheadless river 1 2336
build/bin/civheadless info
build/bin/civheadless map

# Prove the bundle loads and presents frames
build/bin/civheadless checkbundle build/Evolving.saver 2.0

# Capture the live view (including the HUD) into a PNG
EVOLVING_DEV=1 EVOLVING_AGE_DAYS=330 EVOLVING_HOUR=9 \
  build/bin/civheadless hostshot build/host.png 2.0

# Capture the options sheet
build/bin/civheadless sheet build/sheet.png
```

Development overrides are only honoured when `EVOLVING_DEV=1`; they never persist to the stored
world:

| Variable | Meaning |
|---|---|
| `EVOLVING_DEV=1` | enable the overrides below |
| `EVOLVING_AGE_DAYS` | pretend the world began this many days ago |
| `EVOLVING_HOUR` | override the local hour used for the sun |
| `EVOLVING_SEASON` | override the season, 0 (summer) … 1 (winter) |
| `EVOLVING_HEMISPHERE` | force `north` or `south` seasons |
| `EVOLVING_WEATHER` | force precipitation, 0…1 |
| `EVOLVING_SNOW` | force snow (`1`) or rain (`0`) when precipitating |
| `EVOLVING_SEED` | override the world seed |
| `EVOLVING_PACE` | override the pace name |
| `EVOLVING_AWAY_HOURS` | pretend the last visit was this many hours ago |
| `EVOLVING_CAMERA` | pin the still camera: `ex,ey,ez,tx,ty,tz,fov` |

## Layout

```
Sources/
  CivCore/      terrain generation, era/pace model, deterministic simulation, roads, persistence
  CivRender/    Metal context, renderer, meshes, city builder, shaders, snapshots
  Saver/        EvolvingSaver — ScreenSaverView + MTKView + HUD + options sheet
  Headless/     civheadless CLI and window capture
Scripts/        build.sh · install.sh · verify.sh
```

`build.sh` compiles the sources with `swiftc -emit-object`, links the saver as an `MH_BUNDLE`
with `clang -bundle`, and ad-hoc signs it.

## Known limitations

- Close-up cities read as overlapping blocks; detail is limited to roof caps, rooftop clutter and
  window glow.
- The sun glow is screen-space, so it does not move relative to the camera.
- Very large displays render the scene below native resolution and upscale it.
- Rivers are terrain-driven, meander, and no longer show the parallel irrigation-canal
  fan, but 5–9 separate channel runs can still share a 250 m span, endorheic basins
  render as tarns, and a steep cross-slope can still show a cut wall beside the water. At extreme close range the terrain mesh still steps at the carved
  channel edge on steep ground; that is a heightfield-resolution limit, not the water
  or bank mesh.
- Multi-display is safe because replay is deterministic, but each screen simulates independently.
- Seasons auto-detect by country; the options sheet can override.
- Notarization needs your Apple ID/app-specific password; the tooling is ready but the ticket has
  not been submitted from this machine.
