# NEO-07 People at work

Neolithic characters wear belted tunics, leggings, and shoes in flax and earth
tones. The tunic cuts and color choices are interpretations informed by
evidence for plant fibres and hides. The grinding motion follows a quern and
rider demonstration. [English Heritage on Neolithic clothing](https://www.english-heritage.org.uk/visit/places-to-visit/stonehenge/history-and-stories/stonehenge-reconstructed/) ·
[English Heritage's reconstructed houses](https://www.english-heritage.org.uk/visit/places/stonehenge/things-to-do/neolithic-houses/)

- Grinding workers kneel at a placed NEO-06 quern and move the handstone with
  both hands. The static quern bed keeps its original position.
- Carriers hold the actual woven basket at both sides and turn at each end of a
  checked path. Young camps can use a short dry route near their buildings.
- Hearth tenders kneel at an exterior work hearth and rake the coals with a
  stick. The exterior siting is a visual interpretation. NEO-08 covers hearth
  light, smoke, and crops.

All three routines use seed-derived phases and the renderer's animation time.
The same saved camera and time replay the pose, hand-held props, weather, and
lighting.

## Review in Timeline

From the feature checkout, launch the installed app at the grinding station.

```sh
EVOLVING_DEV=1 EVOLVING_NEO01=0 \
  EVOLVING_NEO01_VIEW="$PWD/review/neolithic/neo-07/grinding-a.json" \
  "$HOME/Applications/Evolving Timeline.app/Contents/MacOS/EvolvingTimeline"
```

Use `grinding-b.json`, `carrying-a.json`, `carrying-b.json`,
`tending-a.json`, or `tending-b.json` for the other saved poses. Open Timeline
normally and select Neolithic to see the routines loop live.

The [matched before-and-after view](before-after.jpg) shows the quern at the
same camera before and after adding the grinder. The [six-frame gallery](activities.jpg)
shows two animation times each, with grinding, carrying, and tending from top
to bottom. The installed app was also captured at [the matched grinding camera](native-before-after.jpg)
and at [all three routines](native-activities.jpg). The new routines use checked routes in place of the old ambient
street-grid walkers during the Neolithic. Existing fieldwork still runs with
figures scaled to the buildings.

## Author and verify

Edit [people.blend](../../../Assets/Neolithic/people.blend) to revise the
metric character parts and tools. The arm and leg sections use a normalized
length along local −Y in runtime coordinates, so the pose can position each
section between joints. The clothing and footwear are authored at metre scale.
The source reuses the building atlas and can be regenerated from the authored
profiles.

```sh
blender -b --factory-startup --python-exit-code 1 --python Scripts/author_neolithic_people.py
blender -b --factory-startup --python-exit-code 1 --python Scripts/build_neolithic_reference.py -- \
  --source Assets/Neolithic/people.blend --sheet Assets/Neolithic/people-sheet.png
build/bin/civheadless neolithicpeople build/neo-07
```
