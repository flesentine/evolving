# Low shot orbit takeover

The first horizontal orbit keeps the captured pitch. Starting outside the manual pitch range still lets a vertical drag move inward gradually. A drag farther outside the range stops at the current pitch.

The native renderer check exercises 24 bearing and pitch combinations, including the reported 0.083 rad coastal shot. It checks pitch, target and field of view through takeover, inward and outward movement at the manual limits, pan, zoom and Auto. [Before first orbit](before.png) · [After first orbit](after.png) · [Camera check](camera-check.txt)

The native build, verify, install, and installed saver, Timeline and Player checks passed. All 19 river diagnostic reports matched the earlier validation byte for byte. Both accepted seed-1 junction images also replayed byte for byte. [River checks](river-checks.txt)

The previous placement review described unequal carving at a grid vertex. Commit `44f2b1a` introduced supported placement heights. The current WorldScene uses the supported heightfield for placements and their texture, and copies the same values into matching vertices of the submitted terrain. The older review thread refers to the earlier rendering path.
