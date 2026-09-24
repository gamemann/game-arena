#!/usr/bin/env bash
# Renders a map to screenshots/<map>_{overview,eye,roof}.png so a person can look at it.
#
#   tools/screenshot.sh dm_atrium
#   tools/screenshot.sh dm_box --admin   # a beacon, a beacon behind a wall, a blind
#
# Uses xvfb-run because this needs a rendering context and the machines this runs on
# have no display. Nothing here is headless-safe: `--headless` gives a null renderer and
# every frame it saves is empty, which is worse than no screenshot because it looks like
# one.
set -euo pipefail
cd "$(dirname "$0")/.."
map="${1:-dm_box}"
shift || true
exec xvfb-run -a godot --path . --resolution 1600x900 \
  --script tools/screenshot.gd -- --map "$map" "$@"
