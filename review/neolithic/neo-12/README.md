# NEO-12 Transition into the Bronze Age

A surviving hamlet can keep a group of houses at their year-799 foundations.
The renderer replays that boundary from the same seed, so opening straight
into the Bronze Age produces the same buildings as scrubbing across it.
New houses yield to retained foundations. Civic structures, roads, fields,
water, banks, and existing terrain still constrain which houses can stay.

## Compare years 790 and 810

The images show Norimton in seed 8. The settlement centre and two familiar
houses remain recognizable with the same camera, weather, solar hour, and
animation time. Year 790 is on the left and year 810 is on the right.

- [Hamlet view](hamlet-790-810.jpg)
- [Overhead view](overhead-790-810.jpg)
- [Year 810 before and after NEO-12](hamlet-810-before-after.jpg)

From the checkout, open the installed Timeline at year 790.

```sh
EVOLVING_DEV=1 EVOLVING_NEO01=0 \
  EVOLVING_NEO01_VIEW="$PWD/review/neolithic/neo-12/hamlet-790.json" \
  "$HOME/Applications/Evolving Timeline.app/Contents/MacOS/EvolvingTimeline"
```

Use [hamlet-810.json](hamlet-810.json) for the matched Bronze Age camera.
The [year-790 overhead](overhead-790.json) and [year-810 overhead](overhead-810.json)
records frame the surviving group in relation to the settlement centre.

## Reproduce the checks

```sh
build/bin/civheadless neolithictransition build/neo-12
```

The fixture reads the Metal building instance buffers, compares each surviving
model with the year-799 original, and checks foundation support and clearance
against the submitted geometry. It also checks the pedestrian instance buffers
in the review frames for anyone crossing a retained house footprint. The
fixture opens directly at year 810, then scrubs
across the boundary and compares the result. The review hamlet must keep its
identity and centre, and at least two recognizable year-790 footprints.
