#!/usr/bin/env bash
#
# smooth-gif.sh — raise a preset GIF's source resolution so the menu bar renders crisp edges.
#
# Why: GIF only supports 1-bit (on/off) transparency, so every preset stores HARD edges.
# A preset looks smooth only when its source resolution is HIGHER than the ~40px-tall menu-bar
# render size, so the app downsamples it (NSImageInterpolation.high anti-aliases on the way down).
# A low-res source (e.g. the 72x34 dog) gets UPSCALED instead, which keeps the blocky staircase.
# This script re-scales a GIF up with a smoothing filter and re-binarizes alpha at the new,
# finer resolution — the shape is preserved, the app now downsamples, edges come out smooth.
#
# Usage:
#   smooth-gif.sh <input.gif> <output.gif> [scale-percent] [alpha-threshold-percent]
#
# Defaults: scale=400%  alpha-threshold=45%
# Guideline: pick a scale that makes the shorter dimension >= ~120px (>= ~3x the menu-bar render
# height) so the app always downsamples. 400% turns 72x34 -> 288x136. Over ~200KB, drop the scale.
#
set -euo pipefail

IN=${1:?usage: smooth-gif.sh <input.gif> <output.gif> [scale%] [alpha-threshold%]}
OUT=${2:?usage: smooth-gif.sh <input.gif> <output.gif> [scale%] [alpha-threshold%]}
SCALE=${3:-400%}
THRESH=${4:-45%}

command -v magick >/dev/null || { echo "ImageMagick 'magick' not found (brew install imagemagick)"; exit 1; }

# -coalesce            : expand every frame to full canvas (delays + loop preserved)
# -filter Lanczos      : high-quality smoothing during upscale -> anti-aliased edge pixels
# -resize <scale>      : raise source resolution
# -channel A -threshold: re-binarize alpha for GIF (RGB keeps its anti-aliased grays -> soft edge)
# +repage              : keep full-canvas frames (no optimize-crop, which would desync geometry)
magick "$IN" -coalesce -filter Lanczos -resize "$SCALE" \
  -channel A -threshold "$THRESH" +channel +repage "$OUT"

echo "wrote $OUT"
identify -format "  %f  %n frames  %wx%h  delay=%T\n" "$OUT" | head -1
