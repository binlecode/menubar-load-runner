# MenuBar Load Runner

Small macOS menu bar app that renders an animated GIF in the status bar.
Animation speed automatically adapts to a system load source (CPU by default; also memory, GPU, network, disk, or fan — see Load source below).

Current version: **1.3.0** (see [`CHANGELOG.md`](CHANGELOG.md)).

## Files

- `MenuBarLoadRunner.swift`: app source.
- `menubar-load-runner`: launcher script.
- `scripts/install-login-item.sh` / `scripts/uninstall-login-item.sh`: optional start-at-login setup (see below).
- `CHANGELOG.md`: release history (Keep a Changelog + semver).
- `gifs/running-dog-white.gif`: built-in white dog preset (transparent).
- `gifs/running-dog-black.gif`: built-in black dog preset (transparent).
- `gifs/running-horse-black.gif`: built-in black horse preset (Pinterest silhouette, transparent).
- `gifs/running-horse-white.gif`: built-in white horse preset (transparent).
- `gifs/chihiro-walk.gif`: built-in walking Chihiro preset (side-profile walk cycle, color, transparent).
- `gifs/chihiro-walk-white.gif`: built-in walking Chihiro preset (white silhouette, transparent).
- `gifs/chihiro-walk-black.gif`: built-in walking Chihiro preset (black silhouette, transparent).
- `gifs/totoro.gif`: built-in Totoro preset (from Giphy).
- `gifs/totoro-group-white.gif`: built-in white Totoro group preset (transparent).
- `gifs/totoro-group-black.gif`: built-in black Totoro group preset (transparent).
- `gifs/totoro-white.gif`: built-in white Totoro preset (transparent).
- `gifs/totoro-black.gif`: built-in black Totoro preset (transparent).
- `gifs/presets.json`: preset manifest — the single source of truth for each built-in preset's keyword,
  menu title, GIF file, slot width, and auto speed range (and the default preset). Edit this to add or
  tweak presets; no Swift change needed.

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

- **Single instance.** Only one instance runs at a time. Running any command below a second time does nothing unless you pass `--extra` to allow an additional instance.
- **Detached logs.** A detached launch writes output to `/tmp/menubar-load-runner.log` (override with the `MENUBAR_LOAD_RUNNER_LOG_FILE` environment variable). Use `--foreground` to send output straight to your terminal instead.

## Global Command Wrapper

If you are using the companion `env-config` control plane, the launcher wrapper is symlinked directly on your `$PATH` as **`menubar-load-runner`**. This allows you to launch the load runner globally from any folder:

```bash
menubar-load-runner dog-black
```

`menubar-load-runner` supports the same flags (`--foreground`, `--no-detach`, `--detach`, `--extra`).

## Start at login (personal, optional)

Auto-start via a **per-user LaunchAgent** — no root, no installer, no `.app` bundle, no signing.

```bash
./scripts/install-login-item.sh                              # start at login (defaults to horse-white)
./scripts/install-login-item.sh dog-black --load-source memory   # bake in launcher args
./scripts/uninstall-login-item.sh                            # remove it again
```

Install starts it immediately (no logout needed) and on every login; with no args it uses the
manifest's default preset (`horse-white`). Choosing **Exit** from the menu quits it until the next
login (there is no `KeepAlive`). It shows up in **System Settings → General → Login Items → "Allow in
the Background"** — not the top "Open at Login" list, which is only for `.app`-style login items.

Uninstall is the exact inverse and leaves no residue (deregisters the agent, deletes the plist + log).
The mechanics — `--no-detach` supervision, `RunAtLoad` timing, the `bootout` reload race, and the
Background Task Management behavior — are documented in `docs/DESIGN-system.md` §19.

## Built-in presets

```bash
# Default
./menubar-load-runner horse-white

# Black horse preset (Pinterest silhouette, slightly wider slot scaling)
./menubar-load-runner horse-black

# Chihiro walking preset (color, and white/black silhouettes)
./menubar-load-runner chihiro
./menubar-load-runner chihiro-white
./menubar-load-runner chihiro-black

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

## The menu (live dashboard)

Clicking the status-bar creature opens a menu that doubles as a live readout of the active load
source, refreshed while it's open:

- **Trace chart** at the top — a small bar chart of the last ~60s of the source's 0–1 driving
  fraction (the same value that maps to animation speed). Bars are colored by the same Low/Medium/High
  thresholds as the state line below, so the chart and text agree. Switching source resets it.
- **Numeric readouts** below — current usage, state, speed multiplier, and system load average.
- Selectors for **Load Source**, **Width**, **Overlay Text**, and the **preset** list.

## Load source (what drives the animation)

```bash
./menubar-load-runner --load-source gpu
MENUBAR_LOAD_RUNNER_LOAD_SOURCE=network ./menubar-load-runner
```

`--load-source` (or the `MENUBAR_LOAD_RUNNER_LOAD_SOURCE` env var) selects which system reader
drives the animation speed: `cpu` (default), `memory`, `gpu`, `network`, `disk`, or `fan`. Unknown values —
or a source with no readable hardware on this machine — fall back to `cpu` (unavailable sources are
disabled in the menu). It can also be switched live from the `Load Source` menu. All readers are
unprivileged (no `sudo`); the app only ever *reads* load.

- **cpu** (default): CPU usage across all cores.
- **memory**: memory in use, combined with swap activity.
- **gpu**: GPU utilization.
- **network**: total interface throughput (rx+tx, loopback excluded).
- **disk**: total block-device throughput (read+write across all drives).
- **fan**: fan speed as a thermal/cooling signal (RPM as a fraction of the fan's max; max across fans). A lagging signal that trails actual work and only ramps under sustained thermal load, but idle fans still spin — so it keeps some visible motion (a genuinely stopped fan still crawls at the preset's minimum speed). Unavailable on fanless Macs (e.g. MacBook Air, which have zero fans), which fall back to `cpu`.

Without `--speed-multiplier`, animation speed adapts to the selected load source. Per-preset speed
ranges are defined in `gifs/presets.json`; edit that file to change a range or add a preset (the app
loads it at startup). Switching source changes *which* load value is mapped, not the preset's range.

> How each source is measured and normalized — EMA smoothing, the memory + swap composite,
> btop-style adaptive auto-scaling for the throughput (bytes/sec) sources, and self-throttling under
> power/thermal/memory pressure — is documented in `docs/DESIGN-system.md` (§7, §12).

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

- The active source's metric + state line: `CPU Usage (smoothed)` / `CPU State`; or `Memory` (used-% + swap capacity + swap MB/s when paging) / `Memory Pressure`; or `GPU` / `GPU State`; or `Network` (MB/s) / `Network State`; or `Disk` (MB/s) / `Disk State`; or `Fan` (RPM + %) / `Fan State`
- `Load Avg (1/5/15m)`
- `Speed Multiplier` (shows the active load source, mode, and active range when auto)
- `Load Source` (`CPU` / `Memory` / `GPU` / `Network` / `Disk` / `Fan`; radio selection, takes effect immediately; sources with no readable hardware are disabled)
- `Width` status and `Width Options` (`auto`, `1`, `2`, `3`, `4` slots; preset minimum clamp applies)
- `Overlay Text` (`Set Text...` with max 12 chars + bold toggle, `Clear`)
- `Presets` -> `Dog (White)` / `Dog (Black)` / `Horse (Black)` / `Horse (White)` / `Totoro` / `Totoro (Group, White)` / `Totoro (Group, Black)` / `Totoro (White)` / `Totoro (Black)`
- `About`
- `Exit`

Metrics are refreshed every 2 seconds from the app's periodic sampler.
