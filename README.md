# MenuBar Load Runner

Small macOS menu bar app that renders an animated GIF in the status bar.
Animation speed automatically adapts to a system load source (CPU by default; also memory, GPU, network, disk, or fan — see Load source below).

Current version: **1.6.1** (see [`CHANGELOG.md`](CHANGELOG.md)).

**Cover page:** [menubar-load-runner.pages.dev](https://menubar-load-runner.pages.dev)

## Install

macOS only. Requires the **Xcode Command Line Tools** (`git` + `swiftc`); the installer tells you
to run `xcode-select --install` if they're missing. It compiles from source on your machine — no
Apple signing, notarization, or Homebrew involved.

Recommended — download, inspect, then run:

```bash
curl -fsSL https://raw.githubusercontent.com/binlecode/menubar-load-runner/main/install.sh -o install.sh
less install.sh          # inspect before running
bash install.sh
```

Or the one-line convenience form:

```bash
curl -fsSL https://raw.githubusercontent.com/binlecode/menubar-load-runner/main/install.sh | bash
```

The installer clones the repo to `~/.local/share/menubar-load-runner`, compiles the binary, and
symlinks the launcher to `~/.local/bin/menubar-load-runner`. Run interactively, it also asks
whether to enable start-at-login (pass `--login` to enable it without prompting; a piped
`curl | bash` skips the prompt). Re-running updates an existing install in place (`git pull`).

- **Overrides:** `MENUBAR_LOAD_RUNNER_HOME` (install dir), `BIN_DIR` (launcher symlink dir).
- **Update:** re-run the installer.
- **Uninstall:** run `~/.local/share/menubar-load-runner/uninstall.sh` — it tears down
  start-at-login (if enabled), stops any running instance, and removes the launcher symlink and
  the install dir (`--yes` to skip the delete confirmation).

Already have the repo checked out? Skip the installer — see **Run Locally**.

## Files

- `MenuBarLoadRunner.swift`: app source.
- `install.sh`: one-line installer (clone + compile + symlink launcher onto `PATH`; see Install above).
- `uninstall.sh`: reverses `install.sh` (LaunchAgent, running instance, symlink, install dir).
- `LICENSE.md`: MIT license (covers the source code; the bundled GIFs are third-party — see Assets & attribution).
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
  menu title, GIF file, and auto speed range (and the default preset). Edit this to add or
  tweak presets; no Swift change needed. (Width is not configured here — it's derived from each GIF's
  aspect ratio at runtime.)

## Run Locally

From the repository directory:

```bash
./menubar-load-runner
```

This uses the built-in `horse-white` preset. The menu-bar item sizes itself to the GIF's aspect ratio
at menu-bar height (a wide preset like `totoro-group-*` gets a wide item; a tall/narrow one gets a
narrow one) — width is automatic and not configurable.
It launches detached by default, so it keeps running even if the host shell exits.

To run attached to the current shell session:

```bash
./menubar-load-runner --foreground
```

Notes:

- **Single instance.** Only one instance runs at a time. Running any command below a second time does nothing unless you pass `--extra` to allow an additional instance.
- **Detached logs.** A detached launch writes output to `/tmp/menubar-load-runner.log` (override with the `MENUBAR_LOAD_RUNNER_LOG_FILE` environment variable). Use `--foreground` to send output straight to your terminal instead.

## Global command

The installer symlinks the launcher onto your `PATH` (at `~/.local/bin/menubar-load-runner`), so you
can launch it as **`menubar-load-runner`** from any folder:

```bash
menubar-load-runner dog-black
```

Running from a cloned repo instead? Symlink it yourself:

```bash
ln -s "$PWD/menubar-load-runner" ~/.local/bin/menubar-load-runner
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

### Upgrading vs. reconfiguring the login item

These are **independent** — a new release does *not* require a reinstall, and a reinstall is *only*
for changing the baked-in args:

- **Pick up a new release** — the LaunchAgent runs the launcher script (not a fixed binary), which
  recompiles `MenuBarLoadRunner.swift` whenever it changes. So a new version is picked up the next
  time the agent starts — just restart it (args are preserved, nothing to reinstall):
  ```bash
  launchctl kickstart -k "gui/$(id -u)/ai.bera.menubarloadrunner"   # or simply log out and back in
  ```
- **Change the preset or load source** — this is the *only* reason to reinstall. Re-run the installer
  with the new args; it re-bakes the plist and restarts:
  ```bash
  ./scripts/install-login-item.sh dog-black --load-source fan
  ```

## Built-in presets

```bash
# Default
./menubar-load-runner horse-white

# Black horse preset (Pinterest silhouette)
./menubar-load-runner horse-black

# Chihiro walking preset (color, and white/black silhouettes)
./menubar-load-runner chihiro
./menubar-load-runner chihiro-white
./menubar-load-runner chihiro-black

# Totoro preset
./menubar-load-runner totoro

# White Totoro group preset (transparent, wide — renders at its GIF aspect ratio)
./menubar-load-runner totoro-group-white

# Black Totoro group preset (transparent, wide — renders at its GIF aspect ratio)
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

## Width

Width is automatic and not configurable: the menu-bar item sizes itself to the loaded GIF's aspect
ratio at menu-bar height (clamped to a sane maximum). A wide GIF gets a wide item; a tall/narrow one
gets a narrow item. The current width is shown read-only in the menu (see below).

## Fixed speed override

```bash
./menubar-load-runner --speed-multiplier 1.2
```

## Runtime text overlay

```bash
./menubar-load-runner dog-black --overlay-text CPU
```

`--overlay-text` draws text on each rendered frame at runtime without modifying the GIF file.
The character limit is adaptive to the item width — from 1 up to 12 characters, with narrower GIFs
allowing fewer (the interactive `Set Text...` prompt shows the current limit). The `--overlay-text`
flag validates against the absolute ceiling of 12, since the GIF's width isn't known at parse time.

## The menu (live dashboard)

Clicking the status-bar creature opens a menu that doubles as a live readout of the active load
source, refreshed while it's open:

- **Trace chart** at the top — a small bar chart of the last ~60s of the source's 0–1 driving
  fraction (the same value that maps to animation speed). Bars are colored by the same Low/Medium/High
  thresholds as the state line below, so the chart and text agree. Switching source resets it.
- **Numeric readouts** below — current usage, state, speed multiplier, and system load average.
- A read-only **Width** readout, plus selectors for **Load Source**, **Overlay Text**, and the **preset** list.

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
- `Speed Multiplier` (shows the active load source and mode; a separate `Slowing animation — <cause>` line appears only when a self-throttle condition is active, naming the cause: thermal throttling, Low Power Mode, or memory pressure)
- `Load Source` (`CPU` / `Memory` / `GPU` / `Network` / `Disk` / `Fan`; radio selection, takes effect immediately; sources with no readable hardware are disabled)
- `Width` (read-only: shows the GIF-derived item width in points and the GIF aspect ratio; not configurable)
- `Overlay Text` (`Set Text...` with a width-adaptive char limit + bold toggle, `Clear`)
- `Presets` -> `Dog (White)` / `Dog (Black)` / `Horse (Black)` / `Horse (White)` / `Chihiro (Walking)` / `Chihiro (Walking, White)` / `Chihiro (Walking, Black)` / `Totoro` / `Totoro (Group, White)` / `Totoro (Group, Black)` / `Totoro (White)` / `Totoro (Black)`
- `Update available: vX.Y.Z ->` (only shown when a newer release exists) and `Check for Updates...` — see [Updates](#updates)
- `About`
- `Exit`

Metrics are refreshed every 2 seconds from the app's periodic sampler.

## Updates

On launch, the app checks whether a newer release exists by reading your git checkout's origin remote
release tags (`git ls-remote --tags origin 'v*'`) and comparing the highest one to the running
version. **This is the only network access the app makes**, it runs once per launch off the main
thread, and it fails silently (offline, no `git`, or a non-git install → nothing happens). When a
newer tag is found, an **`Update available: vX.Y.Z ->`** item appears in the menu; **`Check for
Updates...`** re-checks on demand.

Applying an update is always a deliberate two-step user action — click the menu item, then confirm —
never automatic:

1. Click **`Update available`** (or **`Check for Updates...`** when it finds a newer version).
2. Confirm the dialog. The app runs `git pull --ff-only` in its install directory (never `--force` /
   `reset`, so a modified or diverged checkout aborts cleanly and offers the releases page instead).
3. On success it asks you to **restart** — quit from the menu and relaunch (or it starts fresh at next
   login). The launcher recompiles automatically because the source is now newer than the binary.

Disable the check entirely with `--no-update-check` or `MENUBAR_LOAD_RUNNER_UPDATE_CHECK=0`.

## Testing & CI

There's no unit-test framework — the checks are a single tiered QA harness, `tests/qa.sh`, the
executable form of [`docs/RUNBOOK-qa-release.md`](docs/RUNBOOK-qa-release.md) §1–6. Run it from the
repo root:

```bash
tests/qa.sh            # core + gui (local default)
tests/qa.sh --core     # core only — the headless / CI-safe subset
tests/qa.sh --gui      # build + the GUI sections only
tests/qa.sh --launcher # also run the disruptive §6 launcher/singleton check
tests/qa.sh --help
```

Coverage is split into explicit tiers around one question — **does the check boot the GUI?**

| Tier | Sections | Needs a GUI session? | Role |
|---|---|---|---|
| `core` | §1 build (warning-clean) · §2 CLI/version · §5 readers + adaptive scaler | No | Primary gate — must pass before a release; headless-safe |
| `gui` | §3 launch lifecycle · §4 error paths (boot `NSApplication` + a status item) | Yes (WindowServer) | Best-effort — needs a logged-in Mac; skipped on a headless host |
| `launcher` / §7 | §6 launcher + singleton (disruptive `pkill`) · §7 interactive menu spot-check | — | Manual — run locally before a release |

**All regression/QA currently runs locally** — `tests/qa.sh` is the source of truth. The §5
readers/scaler checks are standalone `.swift` files (`tests/readers.swift`, `tests/scaler.swift`) —
the closest thing to unit tests here.

A GitHub Actions workflow ([`.github/workflows/ci.yml`](.github/workflows/ci.yml)) mirrors these tiers
on `macos-14` (`core` job + best-effort `gui` job), but its automatic push/PR triggers are **disabled
to conserve the free-tier Actions quota** (macOS runners bill at a 10× minute multiplier). It's
manual-dispatch-only for now — run it on demand from the Actions tab, or re-enable auto-runs by
uncommenting the trigger block in the workflow.

## License

Source code: [MIT](LICENSE.md) © 2026 Bin Le. The bundled preset GIFs in `gifs/` are **not** covered
by the MIT license — see Assets & attribution below.

## Assets & attribution

The preset GIFs in `gifs/` are third-party content collected from publicly available internet sources
(e.g. Giphy, Pinterest) and are included only as reference/sample artwork to demonstrate the app. No
ownership is claimed over any of it; all rights remain with their respective owners:

- `totoro.gif`, `totoro-white.gif`, `totoro-black.gif`, `totoro-group-white.gif`,
  `totoro-group-black.gif` — "Totoro" and related characters © Studio Ghibli.
- `chihiro-walk.gif`, `chihiro-walk-white.gif`, `chihiro-walk-black.gif` — "Chihiro" (Spirited Away)
  © Studio Ghibli.
- `running-horse-black.gif`, `running-horse-white.gif`, `running-dog-white.gif`,
  `running-dog-black.gif` — animal silhouettes from public sources (original authorship unverified).

This project is **not affiliated with, endorsed by, or sponsored by** any of these rights holders. If
you are a rights holder and would like a file removed, please open an issue and it will be taken down
promptly.

You don't need the bundled GIFs — point the app at any GIF you have the rights to use:
`menubar-load-runner /absolute/path/to/your.gif` (or set `MENUBAR_LOAD_RUNNER_PATH`).
