# MenuBar Load Runner

Small macOS menu bar app that renders an animated GIF in the status bar.
Animation speed automatically adapts to current system CPU load.

## Files

- `MenuBarLoadRunner.swift`: app source.
- `run`: launcher script.
- `gifs/running-dog-white.gif`: built-in white dog preset (transparent).
- `gifs/running-dog-black.gif`: built-in black dog preset (transparent).
- `gifs/running-horse-black.gif`: built-in black horse preset (Pinterest silhouette, transparent).
- `gifs/running-horse-white.gif`: built-in white horse preset (transparent).
- `gifs/totoro.gif`: built-in Totoro preset (from Giphy).
- `gifs/totoro-group-white.gif`: built-in white Totoro group preset (transparent).
- `gifs/totoro-group-black.gif`: built-in black Totoro group preset (transparent).
- `gifs/totoro-white.gif`: built-in white Totoro preset (transparent).
- `gifs/totoro-black.gif`: built-in black Totoro preset (transparent).
- `gifs/raining.gif`: built-in raining sticker preset (transparent, from Giphy).

## Run

From the `macos` directory:

```bash
menubar-load-runner/run
```

This uses the built-in `horse-white` preset and one-slot width by default (`NSStatusItem.squareLength`).
It launches detached by default, so it keeps running even if the host shell exits.

To run attached to the current shell session:

```bash
menubar-load-runner/run --foreground
```

`loadrunner` is a thin wrapper and supports the same flags (`--foreground`, `--no-detach`, `--detach`).

## Built-in presets

```bash
# Default
menubar-load-runner/run horse-white

# Black horse preset (Pinterest silhouette, slightly wider slot scaling)
menubar-load-runner/run horse-black

# Alias for horse-black
menubar-load-runner/run horse

# Totoro preset
menubar-load-runner/run totoro

# White Totoro group preset (transparent, defaults to 4 width units)
menubar-load-runner/run totoro-group-white

# Black Totoro group preset (transparent, defaults to 4 width units)
menubar-load-runner/run totoro-group-black

# White Totoro preset
menubar-load-runner/run totoro-white

# Black Totoro preset
menubar-load-runner/run totoro-black

# White dog preset
menubar-load-runner/run dog-white

# Black dog preset
menubar-load-runner/run dog-black

# Raining sticker preset
menubar-load-runner/run raining

```

## Use a custom GIF

```bash
menubar-load-runner/run /absolute/path/to/your.gif
```

Or:

```bash
MENUBAR_GIF_PATH=/absolute/path/to/your.gif menubar-load-runner/run
```

## Fixed width override

```bash
menubar-load-runner/run --width 2
```

`--width` sets requested menu bar width in slots (`1..4`) and scales the GIF to fill that width.
The effective width is clamped to each preset's minimum. For example, `totoro-group-*` requires 4 slots even if a smaller value is requested.

## Fixed speed override

```bash
menubar-load-runner/run --speed-multiplier 1.2
```

## Runtime text overlay

```bash
menubar-load-runner/run dog-black --overlay-text CPU
```

`--overlay-text` draws text on each rendered frame at runtime without modifying the GIF file.
Overlay text is limited to 12 characters.

Without `--speed-multiplier`, animation speed adapts to system CPU load.
Auto speed ranges are preset-dependent:
- `dog-white` / `dog-black` / custom GIF: `0.50x..2.50x`
- `horse` / `horse-black` / `horse-white`: `0.45x..2.30x`
- `totoro` / `totoro-white` / `totoro-black`: `0.50x..2.60x` (linear, proportional to CPU load)
- `totoro-group-white` / `totoro-group-black`: `0.20x..2.00x` (linear, proportional to CPU load)
- `raining`: `0.15x..4.25x` with eased ramp (much calmer at low CPU, stormier at high CPU)

## Help

```bash
menubar-load-runner/run --help
```

## Stop

```bash
pkill -f 'MenuBarLoadRunner.swift'
```

## Menu actions

Click the menu bar item to open:

- `CPU Usage (smoothed)`
- `Load Avg (1/5/15m)`
- `CPU State`
- `Speed Multiplier` (shows mode and active range when auto)
- `Width` status and `Width Options` (`auto`, `1`, `2`, `3`, `4` slots; preset minimum clamp applies)
- `Overlay Text` (`Set Text...` with max 12 chars + bold toggle, `Clear`)
- `Presets` -> `Dog (White)` / `Dog (Black)` / `Horse (Black)` / `Horse (White)` / `Totoro` / `Totoro (Group, White)` / `Totoro (Group, Black)` / `Totoro (White)` / `Totoro (Black)` / `Raining`
- `About`
- `Exit`

Metrics are refreshed every 2 seconds from the app's periodic sampler.
