# MenuBar Load Runner

Small macOS menu bar app that renders an animated GIF in the status bar.
Animation speed automatically adapts to a system load source (CPU by default; also memory, GPU, network, or disk — see Load source below).

Current version: **1.0.0** (see [`CHANGELOG.md`](CHANGELOG.md)).

## Files

- `MenuBarLoadRunner.swift`: app source.
- `menubar-load-runner`: launcher script.
- `scripts/install-login-item.sh` / `scripts/uninstall-login-item.sh`: optional start-at-login setup (see below).
- `CHANGELOG.md`: release history (Keep a Changelog + semver).
- `gifs/running-dog-white.gif`: built-in white dog preset (transparent).
- `gifs/running-dog-black.gif`: built-in black dog preset (transparent).
- `gifs/running-horse-black.gif`: built-in black horse preset (Pinterest silhouette, transparent).
- `gifs/running-horse-white.gif`: built-in white horse preset (transparent).
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

Auto-start via a per-user LaunchAgent — no root, no installer, no `.app` bundle. It registers the
launcher with `launchd` using `--no-detach`, so `launchd` supervises the process directly.

```bash
./scripts/install-login-item.sh                              # default preset
./scripts/install-login-item.sh dog-black --load-source memory   # bake in launcher args
```

It starts immediately (no logout needed) and on every login. There is no `KeepAlive`, so choosing
**Exit** from the menu quits it until the next login — the expected behavior for a login item.

Fully reversible — the entire footprint is one plist in `~/Library/LaunchAgents/`:

```bash
./scripts/uninstall-login-item.sh                            # deregister + delete plist/log
```

This is deliberately low-footprint: user-scoped only, nothing written under `/Library` or
`/System`, and no receipts database or Background Task Management entry (unlike a `.pkg` or
`SMAppService`). Uninstall is the exact inverse of install, leaving no residue.

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

## Load source (what drives the animation)

```bash
./menubar-load-runner --load-source gpu
MENUBAR_LOAD_RUNNER_LOAD_SOURCE=network ./menubar-load-runner
```

`--load-source` (or the `MENUBAR_LOAD_RUNNER_LOAD_SOURCE` env var) selects which system reader
drives the animation speed: `cpu` (default), `memory`, `gpu`, `network`, or `disk`. Unknown values —
or a source with no readable hardware on this machine — fall back to `cpu` (unavailable sources are
disabled in the menu). It can also be switched live from the `Load Source` menu. All readers are
unprivileged (no `sudo`); the app only ever *reads* load.

- **cpu** (default): CPU usage across all cores.
- **memory**: memory in use, combined with swap activity.
- **gpu**: GPU utilization.
- **network**: total interface throughput (rx+tx, loopback excluded).
- **disk**: total block-device throughput (read+write across all drives).

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

- The active source's metric + state line: `CPU Usage (smoothed)` / `CPU State`; or `Memory` (used-% + swap capacity + swap MB/s when paging) / `Memory Pressure`; or `GPU` / `GPU State`; or `Network` (MB/s) / `Network State`; or `Disk` (MB/s) / `Disk State`
- `Load Avg (1/5/15m)`
- `Speed Multiplier` (shows the active load source, mode, and active range when auto)
- `Load Source` (`CPU` / `Memory` / `GPU` / `Network` / `Disk`; radio selection, takes effect immediately; sources with no readable hardware are disabled)
- `Width` status and `Width Options` (`auto`, `1`, `2`, `3`, `4` slots; preset minimum clamp applies)
- `Overlay Text` (`Set Text...` with max 12 chars + bold toggle, `Clear`)
- `Presets` -> `Dog (White)` / `Dog (Black)` / `Horse (Black)` / `Horse (White)` / `Totoro` / `Totoro (Group, White)` / `Totoro (Group, Black)` / `Totoro (White)` / `Totoro (Black)`
- `About`
- `Exit`

Metrics are refreshed every 2 seconds from the app's periodic sampler.
