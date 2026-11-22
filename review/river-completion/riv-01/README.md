# RIV-01 · Seed-1 junction repair

At year 2336, the squared tongue at junction 8 came from two approaches touching, separating around an old bend and joining again. The bend on reach 6 was a former degree-two node removed by source thinning. Concatenating independently smoothed samples left a short edge of about 0.18 m and pinched the channel to about 0.8 m.

Refit the bend inside its original drainage corridor and resample the transition at 2 m nominal spacing. Both matched renders show the tongue removed and retain the dry wedge upstream. The repair changes where the water and carved ground meet at this bend and does not globally fill enclosed footprints.

[Before](../startup-query-cache/views/seed1-junction-10/before/normal.png) · [After, day](after-day.png) · [After, night](after-night.png)

The seed-1 minimum curvature radius increased from 1.4 m to 4.9 m. Maximum turn between adjoining routing tangents fell from 23.9° to 11.0°. Minimum exact rendered terrain clearance remained 0.449998 m. The existing geometry checks passed for seeds 1–17 plus the saved world, as did seed-1 determinism and the existing fixtures. Build and native verification passed.

Resampling changes geometry diagnostics on seeds 1, 3, 9, 11 and 15–17. Changes cover curvature, section and face counts, bank/profile extrema, water-grade maxima, footprint and terrain probes, and placement clearances. Seeds 11 and 15 report steeper individual edges about 1 cm long, each rising about 1 cm. Both locations were inspected in native close-up and showed continuous water surfaces. The complete local diagnostic comparison and diagnostic renders are in `../work/riv-01/`. [Check results](checks.txt) · [Steep edge measurements](edge-audit.txt)

RIV-02 still tracks regression coverage and inspection of additional junctions. Release and current-commit review remain RIV-03.
