#!/usr/bin/env bash
# Plays the offline client and saves the weapons in use to screenshots/weapons_*.png:
# the hands, a bot holding its gun, a tracer and a flash, a grenade in hand, in flight,
# bouncing, and going off. See tools/screenshot_weapons.gd for the sequence.
#
# Needs xvfb-run, because it needs a rendering context: under --headless every frame it
# saves is empty, which is worse than no screenshot because it looks like one.
set -euo pipefail
cd "$(dirname "$0")/.."
exec timeout 400 xvfb-run -a godot --path . --resolution 1280x720 \
  --script res://tools/screenshot_weapons.gd
