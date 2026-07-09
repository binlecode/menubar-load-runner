---
name: build-visuals
description: Build, smooth, or add preset GIF artwork for the menu-bar app. Use when asked to make menu-bar edges crisper/smoother, add a new preset GIF, generate white/black silhouette variants, fix jagged/blocky/pixelated preset art, or otherwise (re)build the visual assets in gifs/.
---

# Build visuals

Reusable pipeline for the preset GIF artwork in `gifs/`. Requires ImageMagick 7 (`brew install imagemagick`);
`gifsicle` is a handy extra. Scripts live in `scripts/` next to this file.

## The one thing to know: GIF has no soft edges

GIF supports only **1-bit (on/off) transparency** — no alpha gradient. So *every* preset stores HARD,
staircase edges in the file. A preset looks smooth in the menu bar only because the app **downsamples**
it: `NSImageInterpolation.high` anti-aliases a high-res source on the way down to the ~40px-tall render
size. A source that is *lower* resolution than the render size gets **upscaled**, which keeps the blocky
staircase (this is why the 72×34 dog looked jagged next to the 111×74 horse / 120×88 totoro).

**Rule of thumb:** a preset GIF's shorter dimension should be **≥ ~120px** (≈ 3× the menu-bar render
height) so the app always downsamples. Keep files roughly **≤ ~200KB** (the horse/totoro are 5–26KB;
color chihiro is ~474KB and is the outlier). If a scale pushes past ~200KB, lower the scale or run the
result through `gifsicle -O3 --lossy=30`.

## Tasks

### Make a preset's edges smoother (e.g. the dog)
Raise its source resolution so the app downsamples. Preserves shape, delays, and loop.
```bash
scripts/smooth-gif.sh gifs/running-dog-white.gif gifs/running-dog-white.gif 400%
scripts/smooth-gif.sh gifs/running-dog-black.gif gifs/running-dog-black.gif 400%
```
Do it in place (git tracks the diff). Pick a scale that gets the shorter side ≥ ~120px: 400% turns
72×34 → 288×136. Then verify (below).

### Generate white + black silhouette variants from one transparent source
```bash
scripts/make-silhouette.sh source.gif gifs/foo-white.gif white
scripts/make-silhouette.sh source.gif gifs/foo-black.gif black
# then smooth if the source is low-res:
scripts/smooth-gif.sh gifs/foo-white.gif gifs/foo-white.gif 400%
```

### Add a brand-new built-in preset
Do the asset work above, then follow the 4-step checklist in the project `CLAUDE.md`
("Adding a new built-in preset"): add the GIF to `gifs/`, add an entry to `gifs/presets.json`
(`{key, menuTitle, file, slotScale, speed}`), add a `print_help` line in `menubar-load-runner`, and
update `README.md` (file list, preset command list, speed-range table). The Swift code needs no edit —
presets are pure data.

## Verify

The app already trims transparent padding per frame (`trimTransparentPadding`) and computes per-frame
aspect, so full-canvas frames are fine. To confirm a change:

1. **Simulate the menu-bar downsample** and eyeball the edge (no app launch needed):
   ```bash
   magick "gifs/running-dog-white.gif[0]" -filter Lanczos -resize x40 -background '#333' -flatten tmp/edge.png
   magick tmp/edge.png -filter point -resize 600% tmp/edge-zoom.png   # magnify to see the stairs
   ```
   Read `tmp/edge-zoom.png` — smooth = grey anti-aliased transition pixels; jagged = hard blocky steps.
2. **Design page**: `docs/cover.html` embeds the preset GIFs directly (`../gifs/*.gif`), so regenerating
   a GIF in place updates the page. Screenshot it headless to confirm:
   ```bash
   "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
     --headless --disable-gpu --screenshot=tmp/cover.png --window-size=1400,2000 \
     "file://$PWD/docs/cover.html"
   ```
3. **In the app**: `MENUBAR_LOAD_RUNNER_EXIT_AFTER=5 ./menubar-load-runner dog-white --foreground`.

Sanity-check the rebuilt GIF kept its animation:
```bash
identify -format "%f  %n frames  %wx%h  delay=%T  " out.gif; identify -verbose out.gif | grep -i iterations | head -1
```
Delays and `Iterations: 0` (infinite loop) must match the original.

## Scratch files

Write all intermediates to `tmp/` (repo root), never the repo root or `gifs/` until final.
