#!/bin/bash
# Rebuilds the building set: shared atlas, Blender meshes, export, bundle.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

BLENDER="${BLENDER:-/Applications/Blender.app/Contents/MacOS/Blender}"

if [[ ! -x "$BLENDER" ]]; then
  echo "Blender not found at $BLENDER" >&2
  echo "Set BLENDER=/path/to/Blender to override." >&2
  exit 1
fi

echo "▸ atlas"
python3 Scripts/make_buildings_atlas.py

echo "▸ buildings"
"$BLENDER" -b --python Scripts/build_buildings.py

echo "▸ roundhouse"
"$BLENDER" -b --python Scripts/build_roundhouse.py

echo "▸ bundling"
./Scripts/build.sh >/dev/null

echo "done: Assets/Buildings"
