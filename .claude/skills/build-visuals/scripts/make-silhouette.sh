#!/usr/bin/env bash
#
# make-silhouette.sh — recolor a transparent-background GIF into a solid white or black silhouette.
#
# Preset art is a shape on a transparent background. The "white"/"black" preset variants are the
# same shape flood-filled to a single color (alpha untouched) so it reads on either menu-bar theme.
# Run smooth-gif.sh AFTER this if the source is low-res.
#
# Usage:
#   make-silhouette.sh <input.gif> <output.gif> <white|black>
#
set -euo pipefail

IN=${1:?usage: make-silhouette.sh <input.gif> <output.gif> <white|black>}
OUT=${2:?usage: make-silhouette.sh <input.gif> <output.gif> <white|black>}
COLOR=${3:?usage: make-silhouette.sh <input.gif> <output.gif> <white|black>}

case "$COLOR" in
  white) FILL="white" ;;
  black) FILL="black" ;;
  *) echo "color must be 'white' or 'black'"; exit 1 ;;
esac

command -v magick >/dev/null || { echo "ImageMagick 'magick' not found (brew install imagemagick)"; exit 1; }

# -coalesce                     : full-canvas frames, preserve delays/loop
# -channel RGB -fill -colorize  : paint every pixel the fill color, leaving the alpha channel intact
magick "$IN" -coalesce -channel RGB -fill "$FILL" -colorize 100 +channel +repage "$OUT"

echo "wrote $OUT ($COLOR silhouette)"
