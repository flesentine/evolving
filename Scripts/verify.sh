#!/bin/bash
# Build, then prove the two things that matter:
#   1. the .saver bundle loads and presents frames the way the system does
#   2. the simulated world renders across the whole arc
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

Scripts/build.sh

echo
echo "▸ checking bundle"
build/bin/civheadless checkbundle build/Evolving.saver 1.5

echo
echo "▸ rendering the arc"
for year in 500 5000 10000; do
  build/bin/civheadless sim "build/verify-$year.png" "$year" 10 1
  echo
done

echo "verified: build/Evolving.saver"
