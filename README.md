# MenuBar Load Runner

Small macOS menu bar app that renders an animated GIF in the status bar.
Animation speed automatically adapts to current system CPU load.

## Files

- `MenuBarLoadRunner.swift`: app source.
- `menubar-load-runner`: launcher script.
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

## Run Locally

From the repository directory:

```bash
./menubar-load-runner
```

This uses the built-in `horse-white` preset and one-slot width by default (`NSStatusItem.squareLength`).
It launches detached by default, so it keeps running even if the host shell exits.

To run attached to the current shell session:

```bash
./menubar-load-runner --foreground
```

Notes:

- **Single instance.** Only one instance runs at a time (enforced by a `pgrep -f "MenuBarLoadRunner.*\.gif"` check). Running any command below a second time does nothing unless you pass `--extra` to allow an additional instance.
- **Detached logs.** A detached launch writes output to `/tmp/menubar-load-runner.log` (override with the `MENUBAR_LOAD_RUNNER_LOG_FILE` environment variable). Use `--foreground` to send output straight to your terminal instead.

## Global Command Wrapper

If you are using the companion `env-config` control plane, the launcher wrapper is symlinked directly on your `$PATH` as **`menubar-load-runner`**. This allows you to launch the load runner globally from any folder:

```bash
menubar-load-runner dog-black
```

`menubar-load-runner` supports the same flags (`--foreground`, `--no-detach`, `--detach`, `--extra`).

## Built-in presets

```bash
# Default
./menubar-load-runner horse-white

# Black horse preset (Pinterest silhouette, slightly wider slot scaling)
./menubar-load-runner horse-black

# Totoro preset
./menubar-load-runner totoro

# White Totoro group preset (transparent, defaults to 4 width units)
./menubar-load-runner totoro-group-white

# Black Totoro group preset (transparent, defaults to 4 width units)
./menubar-load-runner totoro-group-black

# White Totoro preset
./menubar-load-runner totoro-white

# Black Totoro preset
./menubar-load-runner totoro-black

# White dog preset
./menubar-load-runner dog-white

# Black dog preset
./menubar-load-runner dog-black

# Raining sticker preset
./menubar-load-runner raining
```

## Use a custom GIF

```bash
./menubar-load-runner /absolute/path/to/your.gif
```

Or:

```bash
MENUBAR_LOAD_RUNNER_PATH=/absolute/path/to/your.gif ./menubar-load-runner
```

## Fixed width override

```bash
./menubar-load-runner --width 2
```

`--width` sets requested menu bar width in slots (`1..4`) and scales the GIF to fill that width.
The effective width is clamped to each preset's minimum. For example, `totoro-group-*` requires 4 slots even if a smaller value is requested.

## Fixed speed override

```bash
./menubar-load-runner --speed-multiplier 1.2
```

## Runtime text overlay

```bash
./menubar-load-runner dog-black --overlay-text CPU
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
./menubar-load-runner --help
```

## Stop

```bash
pkill -f 'MenuBarLoadRunner'
```

If a detached instance won't stop or a launch silently fails, check `/tmp/menubar-load-runner.log` (or `$MENUBAR_LOAD_RUNNER_LOG_FILE` if set) first.

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
