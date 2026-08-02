# MenuBar Load Runner

<p align="center">
  <img src="docs/media/hero.svg?v=2" alt="MenuBar Load Runner — a running horse in the macOS menu bar whose animation speed tracks system load" width="880">
</p>

Small macOS menu bar app that renders an animated GIF in the status bar.
Animation speed automatically adapts to a system load source (CPU by default; also memory, GPU, network, disk, fan, battery, or die temperature — see Load source below).

Current version: **1.19.4** (see [`CHANGELOG.md`](CHANGELOG.md)).

**Cover page:** [menubar-load-runner.pages.dev](https://menubar-load-runner.pages.dev)

## Feedback wanted

This project grows by community feedback. Want a new preset, another load source, or
different behavior? Say so in
[Discussions](https://github.com/binlecode/menubar-load-runner/discussions) — a one-liner
is enough. Found a bug? [Open an issue](https://github.com/binlecode/menubar-load-runner/issues/new/choose).

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

You can also toggle it from the menu: **Settings ▸ "Start at Login"** — no terminal needed.

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

## Menu-bar label (adjacent value / text slot)

```bash
./menubar-load-runner --label value      # live reading of the active source, e.g. "CPU 15%"
./menubar-load-runner dog-black --label BUILD   # a fixed label in its own slot
```

`--label` adds an optional **second menu-bar slot** next to the animation:

- `--label value` shows the active source's live reading, refreshed on the 2s tick — `CPU 15%`,
  `MEM 63%`, `NET ↓3.4 ↑0.1`, `DSK R12 W4`, `GPU 30%`, `FAN 45%`, `BAT 88%` (MB/s implied for the rate
  sources). The full, fully-labeled figures still live in the dropdown; this is the at-a-glance number.
- `--label <text>` shows a fixed label (up to 24 chars) — handy for telling apart multiple instances
  (e.g. one on `--load-source cpu` labeled `CPU`, another on `net` labeled `NET`).
- `--label off` (the default) shows nothing and claims no extra menu-bar space.

Also settable via `MENUBAR_LOAD_RUNNER_LABEL`, and switchable at runtime from the menu's **Menu Bar
Label** submenu (Off / Live Value / Custom Text…). It renders in the native menu-bar font in its own
slot rather than being drawn onto the tiny animated icon, so it stays legible.

**The slot doesn't move.** Its width is fixed for the shape on show — sized once for the widest reading
that shape can produce (`CPU 100%`, `NET ↓999.9 ↑999.9`), with the number right-aligned in monospaced
digits. Nothing resizes as the value changes, so the animation next to it never shifts. (Before this,
the slot auto-sized: `CPU 9%` → `CPU 100%` widened it, and macOS shifts everything to the *left* of an
item that resizes, so the creature twitched sideways twice a second.) A rate past its ceiling — over
999.9 MB/s of network — widens the slot for that tick rather than truncating the number; the figures in
the dropdown are always exact.

**Position** is yours to choose, in the same submenu: `Left of Icon` (the default) or `Right of Icon`.
Left keeps the animation where it has always been and grows the label away from it; right puts the
reading nearer the clock, where the eye already looks for status. Either way it's jitter-free. The
choice is remembered across relaunches. One asymmetry worth knowing: when the menu bar runs out of room
macOS hides the leftmost items first, so on a crowded bar the left position risks the *number* being
clipped and the right position risks the *icon*.

Whenever the track line under the icon is tinted, the label takes the same tint, so the two read as one
indicator: solid when this app is holding the Mac awake, faded when something else is (a `caffeinate` you
started, another utility), and fainter still when this app is armed but a low battery or a hot machine has
released its hold for now. Brightness tracks how much of a hold there is — only this app's own hold is one
its `Off` row can release.

## The menu (live dashboard)

Clicking the status-bar creature opens a menu that doubles as a live readout of the active load
source, refreshed while it's open:

- **Trace chart** at the top — a small bar chart of the last ~60s of the source's 0–1 driving
  fraction (the same value that maps to animation speed). Bars are colored by the same Low/Medium/High
  thresholds as the state line below, so the chart and text agree. The **Battery** source is the
  exception: it's a charge-level fuel gauge with an inverted ramp — a low battery reads red (≤20%),
  amber near ~40%, green when healthy — since for battery *low* is the alert, not high. Switching
  source resets it.
- **Numeric readouts** below — current usage, state, speed multiplier, and system load average.
- A read-only **Width** readout, an **Other Sources** collapsible list (the load-source switcher), a **Settings** submenu (currently the **Menu Bar Label**: Off / Live Value / Custom Text), and a **Presets** submenu.

## Load source (what drives the animation)

```bash
./menubar-load-runner --load-source gpu
MENUBAR_LOAD_RUNNER_LOAD_SOURCE=network ./menubar-load-runner
```

`--load-source` (or the `MENUBAR_LOAD_RUNNER_LOAD_SOURCE` env var) selects which system reader
drives the animation speed: `cpu` (default), `memory`, `gpu`, `network`, `disk`, `fan`, `battery`, or `temperature`. Unknown values —
or a source with no readable hardware on this machine — fall back to `cpu` (unavailable sources are
disabled in the menu). It can also be switched live by expanding the **Other Sources** list in the menu
and clicking a reader (see below). All readers are
unprivileged (no `sudo`); the app only ever *reads* load.

- **cpu** (default): CPU usage across all cores.
- **memory**: memory in use, combined with swap activity.
- **gpu**: GPU utilization.
- **network**: total interface throughput (rx+tx, loopback excluded).
- **disk**: total block-device throughput (read+write across all drives).
- **fan**: fan speed as a thermal/cooling signal (RPM as a fraction of the fan's max, averaged across fans — one fan spinning up doesn't dominate while the rest of the system is quiet). A lagging signal that trails actual work and only ramps under sustained thermal load, but idle fans still spin — so it keeps some visible motion (a genuinely stopped fan still crawls at the preset's minimum speed). Unavailable on fanless Macs (e.g. MacBook Air, which have zero fans), which fall back to `cpu`.
- **battery**: discharge current (instantaneous draw, in mA) while on battery — a fast drain animates faster; on AC power the draw is zero, so the animation idles. Since every machine's draw ceiling differs, the current is normalized against the same adaptive ceiling the byte-rate sources use. The menu also shows the charge level. Unavailable on desktop Macs with no battery, which fall back to `cpu`.
- **temperature**: die temperature — the *leading* thermal signal, where fan speed is the lagging one (the die heats in milliseconds; the fans answering it ramp over seconds). Read straight off the performance-core temperature sensors and mapped on an absolute 30 °C → 100 °C scale, so a given animation speed means the same temperature on every Mac rather than being rescaled to your machine's recent range. The driver is the *hottest* sensor, not the average — throttling responds to the hottest die, and averaging a loaded core cluster against an idle one hides the event worth watching; the menu shows the full spread it came from. A Mac that cools well may never reach the top of the speed range, which is the honest reading. Unavailable where no sensor answers (typically VMs), which fall back to `cpu`.

Without `--speed-multiplier`, animation speed adapts to the selected load source. Per-preset speed
ranges are defined in `gifs/presets.json`; edit that file to change a range or add a preset (the app
loads it at startup). Switching source changes *which* load value is mapped, not the preset's range.

### Other sources (the switcher + multi-metric view)

The active source is shown on top with the sparkline. Every *other* source lives under the
**Other Sources** disclosure row in the menu: click the row (▸ / ▾) to expand or collapse an inline
list of the remaining available readers, each showing its live readout. Clicking a reader's row
switches the driving source to it — it moves up top and drops out of the list.

By default only the active source is sampled (so the indicator doesn't add to the load it visualizes),
and the list starts collapsed. Expanding it samples *every* available reader each tick, turning the
menu into a compact multi-metric monitor; collapsing restores active-only sampling. Launch with the
list already expanded via `--show-all-sources` (or `MENUBAR_LOAD_RUNNER_SHOW_ALL=1`). The active source
still drives the animation; the history sparkline still tracks the active source only.

> How each source is measured, in brief: the percentage-style sources (CPU, GPU, fan) are
> direct unprivileged reads (CPU smoothed by a short moving average); memory combines the used
> fraction with live swap throughput; the byte-rate sources (network, disk, swap) plus battery
> discharge current are normalized against an adaptive ceiling that tracks your machine's recent peaks (the same
> approach `btop` uses), so the animation stays meaningful whatever your hardware's actual maximum
> throughput is. Under Low Power Mode, thermal, or memory pressure the app caps its own animation
> speed at half the preset's range.

## Keep Awake at launch (`--keep-awake`)

```bash
./menubar-load-runner --keep-awake 4h        # arm a 4-hour window at startup
./menubar-load-runner --keep-awake on        # until turned off
MENUBAR_LOAD_RUNNER_KEEP_AWAKE=90m ./menubar-load-runner
```

`--keep-awake` (or `MENUBAR_LOAD_RUNNER_KEEP_AWAKE`) arms sleep prevention as the app starts, so a
long unattended run can be scripted instead of clicked. It takes `off` (the default), `on` /
`indefinite`, or a duration — **a unit is required**: `30m`, `2h`, `1h30m`, `90s`, up to 24 hours.
A bare number is rejected rather than guessed at, since minutes and hours are both plausible readings
and picking wrong is a 60× error in how long your Mac stays awake. An unrecognized value warns on
stderr and launches with Keep Awake off; it never fails the launch, because this value can be baked
into a login item:

```bash
./scripts/install-login-item.sh --keep-awake 4h
```

### The battery release point (`--battery-threshold`)

```bash
./menubar-load-runner --keep-awake 8h --battery-threshold 10   # release at 10% instead of 20%
./menubar-load-runner --keep-awake on --battery-threshold off  # never release on charge alone
MENUBAR_LOAD_RUNNER_BATTERY_THRESHOLD=10 ./menubar-load-runner
```

Also settable from the menu: `Settings ▸ Battery Threshold` offers 10 / 15 / 20 / 30%, `Never`, and a
`Custom…` percent prompt, with the current value in the parent row's title. A change there applies
immediately — a Keep Awake window that is already running picks up the new release point without
waiting for the next battery event.

Keep Awake releases at 20% on battery by default. `--battery-threshold` (or
`MENUBAR_LOAD_RUNNER_BATTERY_THRESHOLD`) moves that point: a **whole percent** — `20` or `20%`, from 6
to 100 — or `off`, which never releases on charge alone. A decimal like `0.20` is refused rather than
guessed at, for the reason a bare duration is: it reads as 0.2% under one convention and 20% under the
other. Out-of-range values are clamped and unrecognized ones fall back to the 20% default, both with a
warning on stderr and never a failed launch, since this too can be baked into a login item.

The threshold **persists across launches**: whatever it was last set to comes back, so a plain
`./menubar-load-runner` keeps your release point instead of reverting to 20%. That matters most for
`off` — a forgotten `off` would silently reinstate a policy you turned off. Passing the flag or the env
var still wins over the saved value, so a login item can pin one threshold without disturbing it.

**Below 5% on battery the Mac sleeps regardless.** That floor is not configurable and is checked
first, so it holds whatever the threshold is set to — including `off`. It's also why the minimum is
6% rather than 1%: a threshold beneath the floor would be a setting that does nothing.

This relocates the cliff; it doesn't remove it. Turning Keep Awake on from the menu while already
below the threshold still overrides that pause for the session (see the menu section above).

**This is launch-time arming, not remote control.** The launcher allows one instance, so running the
command again while the app is up won't re-arm it — the second invocation is refused. To change the
window on a running app, use the menu (or `pkill -f MenuBarLoadRunner` and relaunch).

**Persistence.** Keep Awake state is saved to
`~/Library/Application Support/menubar-load-runner/state.json` and restored on the next launch, so a
reboot in the middle of an overnight window doesn't silently drop it. What's restored:

| Saved | On the next launch |
|---|---|
| A window still running | Resumed with the **time remaining**, not a fresh window |
| A window that already elapsed | Not restored — the Mac is free to sleep |
| Keep Awake on with **no** window (indefinite) | **Not** restored — see below |
| The track-line color | Always restored (it's cosmetic) |

A saved *indefinite* window is deliberately not resumed. It has no stopping condition, so a stale
flag would keep the Mac awake after every reboot until someone noticed the menu bar; a bounded window
is self-limiting and is the case that actually hurts. Passing `--keep-awake` — **including
`--keep-awake off`** — overrides whatever was saved. If the state file is missing, unreadable, or
corrupt, the app launches normally with Keep Awake off; it is never a startup error.

## Resource cost

MenuBar Load Runner is built to stay out of the way of the load it visualizes. Measured on Apple
Silicon at 2× Retina — your numbers vary with Mac model, menu-bar height, display refresh rate, the
active preset, and the current load level:

- **CPU:** ~0.4–0.9% of one core while the icon is animating and visible; **0% when hidden** (the game
  loop stops when the item is occluded by the notch, a full-screen app, or an inactive Space). Usage
  scales with the animation rate — lower at light load — and is capped at half speed under Low Power
  Mode / thermal / memory pressure.
- **Memory:** ~10 MB at launch, ~20–24 MB once the menu (with its live load-history graph) has been
  opened — essentially the AppKit framework floor for a menu-bar app.

Frames are drawn by swapping a `CALayer`'s contents (a pre-rasterized `CGImage`), not by re-setting the
status button's image every frame — which avoids a per-frame Auto Layout pass and keeps steady-state
CPU low. Reproduce it:

```bash
./menubar-load-runner                                    # start (detached)
PID=$(pgrep -U "$(id -u)" -f '/MenuBarLoadRunner( |$)')   # -U: your instance, not another account's
top -pid "$PID" -l 6 -s 1 -stats pid,command,cpu,mem     # CPU + memory
footprint -p "$PID"                                      # phys_footprint (true memory)
```

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

- The active source's metric + state line: `CPU Usage (smoothed)` / `CPU State`; or `Memory` (used-% + swap capacity + swap MB/s when paging) / `Memory Pressure`; or `GPU` / `GPU State`; or `Network` (MB/s) / `Network State`; or `Disk` (MB/s) / `Disk State`; or `Fan` (RPM + %) / `Fan State`; or `Battery` (charge % + discharge A, or `AC`) / `Battery State`; or `Temperature` (hottest sensor °C + the spread across sensors) / `Temperature State`
- `Load Avg (1/5/15m)`
- `Speed Multiplier` (shows the active load source and mode; a separate `Slowing animation — <cause>` line appears only when a self-throttle condition is active, naming the cause: thermal throttling, Low Power Mode, or memory pressure)
- `▸ Other Sources` (disclosure row) — click to expand/collapse an inline list of every *other* available reader (`CPU` / `Memory` / `GPU` / `Network` / `Disk` / `Fan` / `Battery` / `Temperature`, minus the active one; sources with no readable hardware are omitted). Each row shows that reader's live readout; clicking it switches the driving source to it (takes effect immediately). Expanding samples every reader each tick; collapsed (the default) samples only the active source. The active source still drives the animation. Launch expanded with `--show-all-sources` / `MENUBAR_LOAD_RUNNER_SHOW_ALL=1`
- `Width` (read-only: shows the GIF-derived item width in points and the GIF aspect ratio; not configurable)
- `Settings` (submenu) — where preferences live, so they don't crowd the top level
  - `Menu Bar Label` -> `Off` / `Live Value` (the active source's compact live reading in its own slot) / `Custom Text…` (a fixed label, up to 24 chars). Off by default; the parent title shows the current state. **Your choice is remembered across relaunches.** Also settable at launch via `--label` / `MENUBAR_LOAD_RUNNER_LABEL`, which wins over the saved value for that run — including `--label off`, which starts with no label even if one was saved. Below those, a second group — `Position` -> `Left of Icon` (default) / `Right of Icon` — puts the slot on either side of the animation; it applies immediately, stays set while the label is off, and is remembered across relaunches. Menu-only (no flag), like the Keep Awake tint. The slot's width is fixed either way, so neither side jitters — see [Menu-bar label](#menu-bar-label-adjacent-value--text-slot)
  - `Battery Threshold` -> `10%` / `15%` / `20%` / `30%` / `Never` / `Custom…` (any whole percent from 6 to 100). The charge at which Keep Awake stops holding the Mac awake on battery; 20% by default, and the parent title shows the current setting. `Never` means it never releases on charge alone — **below 5% the Mac still sleeps regardless**, so that is not a way to run the battery flat. A change takes effect immediately, including on a window that is already armed. **Remembered across relaunches**, and settable at launch via [`--battery-threshold`](#the-battery-release-point---battery-threshold) / `MENUBAR_LOAD_RUNNER_BATTERY_THRESHOLD`, which wins over the saved value for that run
- `Keep Awake` (submenu) — keeps the Mac awake while the app runs by spawning `caffeinate -di -w <pid>` (prevents both display and idle system sleep — an idle-only assertion is unreliable on modern macOS, where the system follows the display into sleep). Bound to the app's PID, so it's reaped automatically on crash/quit. Auto-disengages on low battery (≤20% on battery by default — movable with [`--battery-threshold`](#the-battery-release-point---battery-threshold)) or serious/critical thermal state, and re-engages when the condition clears. A thin track line along the icon's bottom edge shows while it's actively keeping the Mac awake, and the adjacent [menu-bar label](#menu-bar-label-adjacent-value--text-slot), if you have one on, wears the same tint for as long as it runs. **When it's paused, it says so without you opening anything:** the line stays, dimmed further — armed but not currently holding — so a window that released itself overnight doesn't look like one you never switched on. In the menu the `Keep Awake` row reads `(paused)` and the submenu tells you why — `paused — battery low (15%)`, `paused — battery critical (4%)`, or `paused — Mac is too warm`. **Turning Keep Awake on from the menu while the battery is already low overrides the battery pause** — an explicit arm is honored rather than silently doing nothing — down to a hard 5% floor, where it releases regardless so an override can't drain the Mac to a power-off. The override lasts for that session only: it isn't saved, and `--keep-awake` doesn't set it, since that flag can be baked into the login item and fires with nobody present to weigh a low battery against the task. A thermal pause is never overridable. The submenu holds two radio groups. The first is **Off** plus five track-line colors (**Dusty Teal**, the default, **Sand**, **Graphite**, **Mauve**, **Sage**): picking a color turns Keep Awake on with that tint, **Off** turns it off. The second is **Duration** — the timed release: **Until turned off** (the default), **30 minutes**, **1 hour**, **2 hours**, **4 hours**, **8 hours**, or **Custom…** (hours + minutes, up to 24 hours). Picking any duration also turns Keep Awake on, so arming a window is one click. With a window armed it's a real countdown: the `Keep Awake` row reads `Keep Awake: 29:24` and the submenu shows `29:24 left (until 8:18 PM)` — time remaining at seconds resolution plus the wall-clock moment it ends, ticking every second while the menu is open. When it elapses `caffeinate` exits on its own, Keep Awake returns to **Off**, and the Mac is free to sleep — handy for a long unattended task you won't be awake to babysit. The window is a *time* promise, not a *task* promise: it releases whether or not your job finished. An armed window **survives a relaunch or a reboot** — it is saved as the moment it ends, so what comes back is the remainder, not a fresh window, and a window that elapsed while the app was down does not come back at all. Also armable at launch with `--keep-awake` (see below). **The submenu's first row answers "is my Mac being held awake right now?" — by anything, not just by this app.** That is the question the menu used to get wrong: start `caffeinate -di -t 30m` in a terminal, or leave another utility holding sleep, and every Keep Awake surface here read `Off` while your Mac stayed up. Now the row reads `Mac held awake — this app · 29:24` when it's ours, `Mac held awake — caffeinate · until 8:18 PM` when it's someone else's (naming the holder, and its release time when it has one), `Idle sleep held, display is not — the Mac may still sleep` when what's held won't actually keep the Mac up, or `Nothing holding sleep`. The track line and the label tint follow it, so a hold you didn't start is visible without opening the menu — **faded** rather than solid, because only *this app's* hold is one the `Off` row can release. Two things it deliberately does not do: it never ticks a color row on someone else's behalf (that would make `Off` a button that can't turn off what it appears to describe), and it never promises your Mac won't sleep — clamshell, your `pmset` settings and the 5% battery floor are all invisible to it, so it names what is *holding* sleep and stops there.

**The submenu's last section, `Other Assertions`, names what *else* is holding a sleep assertion** — one row per other process as `owner — AssertionType` (e.g. `caffeinate — PreventUserIdleDisplaySleep, PreventUserIdleSystemSleep ×2`, listing every type that process holds), read from IOKit's public power-management API, or `none`. It answers "the app says Off, so why isn't my Mac sleeping?" — the case that used to leave the menu truthful about itself and silent about the machine. It reports the **observation, not a conclusion**: an assertion is not proof the Mac can't sleep (`PreventUserIdleSystemSleep` alone doesn't hold the *display*, and the system follows the display down — which is why this app spawns `-di`), so the rows name the holder and the type and stop there. Cross-check any row with `pmset -g assertions`, which prints the same type strings. This app's own `caffeinate` is never listed — the countdown row above already reports it. Read-only: there is no button here to kill anything.
- `Presets` (submenu) -> `Dog (White)` / `Dog (Black)` / `Horse (Black)` / `Horse (White)` / `Chihiro (Walking)` / `Chihiro (Walking, White)` / `Chihiro (Walking, Black)` / `Totoro` / `Totoro (Group, White)` / `Totoro (Group, Black)` / `Totoro (White)` / `Totoro (Black)`
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
3. On success it offers a **Restart** button, which quits and relaunches you onto the new version. The
   launcher recompiles automatically because the source is now newer than the binary. Your Keep Awake
   window, label, battery threshold, and Keep Awake tint carry over (they're saved to disk), and a
   restart also carries the preset, load source, fixed speed, and Other Sources disclosure you picked
   from the menu, which are not saved between ordinary launches.
   - The button appears only when the app knows how to bring itself back: a normal (detached) launcher
     run, or a start-at-login LaunchAgent. A `--foreground` run belongs to the shell that started it,
     so there you get the manual instruction instead — quit from the menu and relaunch.
   - Under the LaunchAgent, the relaunch uses the arguments baked into the login item, so a preset or
     source you picked from the menu resets to those (everything saved to disk still carries over).

Disable the check entirely with `--no-update-check` or `MENUBAR_LOAD_RUNNER_UPDATE_CHECK=0`.

## Testing & CI

There's no unit-test framework — the release gate is a single tiered QA harness, `tests/qa.sh`.
[`docs/RUNBOOK-qa-release.md`](docs/RUNBOOK-qa-release.md) maps what it covers and what only a person
can. Run it from the repo root:

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
| `core` | §1 build (warning-clean) · §2 CLI/version | No | Primary gate — must pass before a release; headless-safe |
| `gui` | §3 launch lifecycle · §3a–§3e Keep Awake / persistence / label geometry / sleep assertions · §5 reader readouts · §4 error paths (all boot `NSApplication` + a status item) | Yes (WindowServer) | Best-effort — needs a logged-in Mac; skipped on a headless host |
| `launcher` / §7 | §6 launcher + singleton (disruptive `pkill`) · §7 interactive menu spot-check | — | Manual — run locally before a release |

**All regression/QA currently runs locally** — `tests/qa.sh` is the source of truth. There are **no unit
tests**, by policy: every check launches the real binary and asserts a real side effect (a `caffeinate`
child, a state file, the live status item's own geometry and readout). Five standalone `.swift` probes that
re-ported app logic and asserted against the copy were deleted in favor of that — the copy passes while the
app is broken. This is why the `core` tier is thin: the real binary needs a status item, so the behavioral
checks live in `gui`.

A GitHub Actions workflow ([`.github/workflows/ci.yml`](.github/workflows/ci.yml)) mirrors these tiers
on `macos-14` (`core` job + best-effort `gui` job), but its automatic push/PR triggers are **disabled
to conserve the free-tier Actions quota** (macOS runners bill at a 10× minute multiplier). It's
manual-dispatch-only for now — run it on demand from the Actions tab, or re-enable auto-runs by
uncommenting the trigger block in the workflow.

## How it compares

MenuBar Load Runner sits between two categories: animated load indicators (RunCat-style "the
creature runs faster when the machine works harder") and menu-bar system monitors (numeric
dashboards). It is the CLI-first, no-Xcode entry in the first category, with a lightweight slice of
the second built into its dropdown. Feature presence at a glance versus the closest open-source
neighbors — [menubar_runcat](https://github.com/Kyome22/menubar_runcat) (the open-source edition of
RunCat, by its original developer), [zoomies](https://github.com/KartikLabhshetwar/zoomies) (SwiftUI
pixel-pet indicator), and [stats](https://github.com/exelban/stats) (the full system-monitor
dashboard):

| | MenuBar Load Runner | menubar_runcat | zoomies | stats |
| :--- | :--- | :--- | :--- | :--- |
| **Category** | Animated load indicator | Animated load indicator | Animated load indicator | System monitor |
| **Packaging** | Single Swift file + shell launcher (no Xcode project) | Xcode `.app` | Xcode `.app` | Xcode `.app` |
| **Load sources** | CPU, memory+swap, GPU, network, disk, fan, battery, die temperature | CPU | CPU, GPU, RAM | Full hardware suite |
| **Unbounded rates (net/disk/swap) drive the animation** | Yes — adaptive auto-scaling | — | — | n/a (numeric display) |
| **In-menu readout** | 60s sparkline, numerics, load averages | Minimal | Numeric dropdown | Full graphs, temps, per-process |
| **Sensor temps / battery health / per-process** | No (out of scope by design) | No | No | Yes |
| **Pauses when hidden; self-throttles under power/thermal pressure** | Yes | — | — | — |
| **Built-in sleep inhibitor (Keep Awake)** | Yes (`caffeinate`, timed release, auto-disengage, survives relaunch) | — | — | — |
| **CLI flags / headless install / login automation** | Yes (launcher, LaunchAgent scripts) | GUI app | GUI app | GUI app |
| **Settings window** | No (menu + CLI flags) | — | Yes (SwiftUI) | Yes |
| **Updates** | In-app git tag check + one-click `git pull` | Manual rebuild (archived repo) | GitHub releases | Built-in updater |

> Snapshot: July 2026, feature *presence* only — no performance comparisons are made or implied
> (no rigorous same-method measurements of other menu-bar apps exist; the only figures measured
> here are this app's own, above). Verify each project's current state upstream.

If you want temperatures, battery health, or per-process breakdowns, use **stats** — this app
deliberately stays an unprivileged, aggregate-only indicator. If you want a graphical settings
window over CLI flags, **zoomies** offers one.

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
