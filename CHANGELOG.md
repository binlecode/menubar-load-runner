# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## Public API (what semver governs)

MenuBar Load Runner is a CLI-launched app; the surface that MAJOR / MINOR / PATCH bumps apply to is:

- **Launcher CLI** — the positional preset keyword or GIF path, and the flags `--width`,
  `--speed-multiplier`, `--overlay-text`, `--load-source`, `--foreground` / `--no-detach`,
  `--detach`, `--extra`, `-h` / `--help`.
- **Environment variables** — `MENUBAR_LOAD_RUNNER_PATH`, `MENUBAR_LOAD_RUNNER_LOAD_SOURCE`,
  `MENUBAR_LOAD_RUNNER_LOG_FILE`, `MENUBAR_LOAD_RUNNER_BIN_NAME`, and the debug/QA hooks
  `MENUBAR_LOAD_RUNNER_EXIT_AFTER` and `MENUBAR_LOAD_RUNNER_FORCE_UNAVAILABLE`.
- **Built-in preset keywords** and the `gifs/presets.json` manifest schema.
- **Observable behavior** — the status menu structure, the default preset, and the load-adaptive
  speed contract.

Internal implementation details (Swift types, `Tuning` constants, file structure) are **not** part
of the public API and may change in any release.

## [Unreleased]

### Added

- **Asset attribution** section in the README for the bundled third-party preset GIFs — clarifies the
  MIT license covers the source code only, and provides a takedown path.
- **Executable QA harness** in `tests/` (`qa.sh`, `install-smoke.sh`, `readers.swift`, `scaler.swift`)
  — the runnable form of `docs/RUNBOOK-qa-release.md` §1–6 (previously copy-paste blocks).

## [1.6.0] - 2026-07-10

### Added

- **Open-sourced under the MIT License** (`LICENSE.md`) — covers the source code only.
- **One-line installer** (`install.sh`) and matching **`uninstall.sh`**. `install.sh` is a
  gitlogue-style `curl | bash` installer adapted for this source-based app: it preflights macOS +
  the Xcode Command Line Tools (`git`/`swiftc`), clones the repo to
  `~/.local/share/menubar-load-runner` (updating in place on re-run), compiles the binary, symlinks
  the launcher onto `PATH` at `~/.local/bin/menubar-load-runner`, and optionally sets up
  start-at-login (interactive `[y/N]` prompt, or `--login`). `uninstall.sh` reverses it — removes the
  LaunchAgent, the PATH symlink, and the install dir — touching only what the installer created. No
  Apple signing, notarization, or Homebrew required. See the README "Install" section.

### Removed

- **Width customization** — the `--width` / `-w` CLI flag and the `Width Options` menu submenu
  (`auto` / `1` / `2` / `3` / `4` slots) are gone, along with the per-preset `slotScale` field in
  `gifs/presets.json`. The menu-bar item width is no longer user-configurable. **Breaking:** an
  invocation or baked login-item arg that passes `--width <n>` now fails to launch (unknown
  argument); remove it. A read-only `Width` line remains in the menu (see below).

### Changed

- **Width is now GIF-based.** The menu-bar item sizes itself directly to the loaded GIF's aspect
  ratio at menu-bar height (width = height × aspect, clamped to `Tuning.maxIconAspect` and floored
  at `Tuning.minBaseSlotWidth`), instead of a hand-tuned per-preset slot count. A wide GIF gets a
  wide item; a tall/narrow one gets a narrow item. The `Width` menu line is read-only and reports
  the resulting width in points plus the GIF aspect ratio.
- **Overlay char limit is adaptive to the item width.** The interactive `Set Text...` prompt (and
  its menu title) now cap input at roughly how many monospaced glyphs fit across the current
  GIF-derived width — from `Tuning.overlayMinChars` (1) up to the `Tuning.overlayMaxChars` (12)
  ceiling — so a narrow GIF allows fewer characters than a wide one. The `--overlay-text` CLI flag
  still validates against the absolute 12-char ceiling, since the GIF width isn't known at parse
  time; rendering truncates as a backstop either way.
- Overlay menu tidy-up: dropped the separate read-only `Overlay Text: …` status line; the current
  overlay state (text + style, or `off`) is now shown directly on the `Overlay Text` submenu
  parent item, so one line does the job of two.
- Self-throttle status line now names the specific active cause instead of the generic
  `Throttled: low power/thermal` tag, and reserves the word "throttling" for the one condition
  where macOS actually throttles the hardware. The line reads `Slowing animation — <cause(s)>`
  where each cause is one of **thermal throttling** (macOS is clocking the CPU/GPU down —
  `thermalState` `.serious`/`.critical`), **Low Power Mode** (a user-chosen power policy), or
  **memory pressure** (memory reclamation — compression/swap/jetsam, not compute throttling).
  Multiple simultaneous causes are joined into the one line. All three still slow the app's own
  animation (the intent is unchanged — reduce this app's footprint when the machine is strained);
  only the wording is corrected so low power and memory pressure are no longer mislabeled as
  throttling. Detection and the menu wording now share one source of truth (`loadReductionReasons`).

## [1.5.1] - 2026-07-10

### Fixed

- `Speed Multiplier` menu line: dropped the preset's speed-profile label and min/max range from
  the auto-mode title — the label just restated the preset name (already visible from the checked
  item in the `Presets` submenu) and the range was tuning-internal detail, not something a user
  acts on. The line now reads `Speed Multiplier (auto: <source>): <value>x`. The
  low-power/thermal/memory-pressure throttle notice, previously appended inline (making the item
  even wider exactly when it was already busiest), is now its own `Throttled: low power/thermal`
  menu line that's hidden unless the cap is active.

## [1.5.0] - 2026-07-09

### Changed

- **Memory** load source: the used-fraction term now has an idle floor (`Tuning.memoryIdleFloor`,
  0.55) subtracted and the remainder rescaled to 0…1 before it drives the animation. macOS keeps
  most physical RAM resident as cache/wired, so a healthy Mac idles high (often 0.8–0.9 used); the
  previous linear map from the raw fraction drove the animation well up its speed range at rest.
  With the floor, an idle machine reads ~0 and the preset's full min..max range maps onto the
  fraction's real operating band. The swap-rate term is unchanged (already 0-based via the adaptive
  scaler) and is still max'd in un-floored, so active paging drives full speed regardless. The
  Memory menu line still shows the **raw** used-fraction — only the speed driver is floored. Affects
  `--load-source memory` only; CPU (the default) and the other 0-idle sources are unchanged.

## [1.4.0] - 2026-07-09

### Changed

- **Network**, **Disk**, and **Fan** load sources now report each axis separately and drive the
  animation from the *average* of those axes rather than a single combined figure. A one-directional
  transfer or a single spun-up fan no longer counts the same as balanced activity, and the status
  menu surfaces the breakdown:
  - **Network** tracks inbound and outbound throughput independently — the readout shows
    `↓X MB/s ↑Y MB/s` and speed follows the average of the two (previously a single summed rx+tx
    total).
  - **Disk** tracks read and write throughput independently — the readout shows
    `read X MB/s write Y MB/s` and speed follows their average (previously a summed total).
  - **Fan** reports every fan's RPM and utilization as one `Fan N: NNNN RPM (NN%)` segment per fan,
    and speed follows the average utilization across fans (previously the max across fans, so one
    ramped fan dominated).

### Fixed

- Frame registration: `loadFrames` previously cropped each GIF frame to its **own** independent
  alpha bounding box, so a preset whose limb extent varies frame to frame (a running or walking
  gait) rendered at a different size on different frames — visible as the whole menu-bar icon
  resizing/wobbling as it animated. Measured up to a 55% frame-to-frame aspect-ratio swing on the
  `chihiro` preset and 40% on `dog-white`/`dog-black`. Frames are now cropped to one shared
  bounding box — the union of every frame's own alpha extent — so the icon's rendered size is
  constant across a preset's whole animation; only the artwork inside it moves.

## [1.3.0] - 2026-07-09

### Added

- New **`fan`** load source — drives the animation from fan speed as a thermal/cooling signal.
  Reads per-fan tachometers from the SMC (`AppleSMCKeysEndpoint`) unprivileged and read-only
  (never touches fan-control keys), normalizing current RPM as a fraction of the fan's max (max
  across fans). It's a lagging signal that trails actual work and only ramps under sustained
  thermal load; idle fans keep some visible motion, and a genuinely stopped fan still crawls at
  the preset's minimum speed rather than freezing. Fanless Macs (e.g. MacBook Air, which report
  `FNum == 0`) have the source unavailable — it's disabled in the `Load Source` menu and a launch
  request falls back to `cpu`, matching the gpu/disk availability contract. Selectable via
  `--load-source fan`, `MENUBAR_LOAD_RUNNER_LOAD_SOURCE=fan`, or the `Load Source` menu, and
  honors `MENUBAR_LOAD_RUNNER_FORCE_UNAVAILABLE=fan` for QA.

## [1.2.2] - 2026-07-09

### Changed

- Dog preset (`dog-white` / `dog-black`) re-rendered by **vector-tracing** the silhouette with
  `potrace` instead of raster upscaling. Each frame's alpha mask is preprocessed (`mkbitmap`) and
  traced to resolution-independent Bézier curves, then rasterized at 466×220, so the menu bar
  downsamples clean curves rather than a fixed 72×34 pixel staircase — edges now read as smooth as
  the horse preset. The stylistic ground/motion streak under the paws was removed (banded
  morphological opening) so the dog floats like the other silhouettes. 12 frames, delay 3, infinite
  loop, transparent background unchanged; no keyword, timing, or manifest change.

### Added

- CLI forgiveness for common argument mix-ups — neither now triggers the fatal startup error box:
  - A load-source keyword (`cpu` / `memory` / `gpu` / `network` / `disk`) given in the **positional**
    (preset) slot is interpreted as `--load-source` and the default preset is used, with a stderr
    note. An explicit `--load-source` always wins (the positional is then ignored).
  - An unknown positional **bareword** (not a known preset keyword and not an existing file) falls
    back to the default preset with a stderr warning. An explicit GIF **path** (contains `/` or ends
    `.gif`) that doesn't exist still fails fast with the fatal "GIF file not found" — the QA §4a
    contract is preserved, since naming a specific missing file is worth surfacing.
- README "The menu (live dashboard)" section documenting the status-item menu's trace chart and
  numeric readouts.

## [1.2.1] - 2026-07-09

### Changed

- Dog preset (`dog-white` / `dog-black`) art re-rendered from a higher-resolution source so the menu
  bar downsamples it instead of upscaling — edges are smoother rather than blocky. GIF stores only
  1-bit transparency, so a preset looks crisp only when its source out-resolves the ~40 px render
  height; the dog was 72×34 (below it) and is now 288×136. No keyword, timing, or manifest change.

### Added

- `docs/cover.html` — design/marketing cover page for the project.
- `docs/RUNBOOK-pages-publish.md` — runbook to build the cover bundle and deploy it to Cloudflare
  Pages via `wrangler` direct upload.
- `.claude/skills/build-visuals/` — reusable skill + scripts for smoothing preset GIFs and generating
  white/black silhouette variants.

## [1.2.0] - 2026-07-07

### Added

- Chihiro walking presets: `chihiro` (full-color walk cycle), `chihiro-white`, and `chihiro-black`
  silhouettes (293×621, 21 frames, shared "chihiro" speed profile). Wired through `gifs/presets.json`,
  the launcher help, and README.

## [1.1.3] - 2026-07-07

### Fixed

- About dialog: the auto-speed line was hardcoded to "CPU load"; it now names the active load source
  (e.g. "Speed adapts to GPU load …"), matching the Speed Multiplier menu line.
- About/alert icon: the horse art (~3:2) was squished into a 48×48 square and rasterized at 1× with
  default interpolation. It is now aspect-fit and centered, backed at the display (Retina) scale, and
  drawn with high interpolation — smooth, with correct proportions.
- Resource resolution hardened: `gifs/` and `presets.json` are now located relative to the running
  executable (falling back to `#filePath` for the interpreted `swift <file>` dev path) rather than
  `#filePath` alone. A binary compiled with a relative source path and run under `launchd` (working
  directory `/`) previously resolved the manifest to `/gifs/presets.json` and failed at startup; the
  new anchor is independent of both the working directory and the compile-time path.

## [1.1.2] - 2026-07-07

### Changed

- Documentation only: split the login-item docs to match the repo convention (README = usage,
  `docs/DESIGN-system.md` = source-anchored mechanism). The README "Start at login" section is
  trimmed to install/uninstall usage; the full LaunchAgent mechanics — `--no-detach` supervision,
  `RunAtLoad` timing, the `bootout` reload race, and Background Task Management ("Allow in the
  Background") behavior — now live in `docs/DESIGN-system.md` §19.

## [1.1.1] - 2026-07-07

### Fixed

- `scripts/install-login-item.sh` re-install (running install while already installed, e.g. to
  change the baked-in preset / `--load-source` args) failed with launchctl error 5 ("Input/output
  error"). `launchctl bootout` is asynchronous, so the follow-up `bootstrap` raced the still-tearing-
  down service. Install now polls until the old service is fully gone before re-`bootstrap`. First
  install and uninstall were unaffected.

## [1.1.0] - 2026-07-07

### Added

- Optional start-at-login support for personal use, via two scripts:
  `scripts/install-login-item.sh` and `scripts/uninstall-login-item.sh`. Install registers a
  per-user LaunchAgent (`~/Library/LaunchAgents/ai.bera.menubarloadrunner.plist`) that runs the
  launcher with `--no-detach` so `launchd` supervises the process; it starts immediately and on
  every login, and passes through any launcher args (preset keyword, `--load-source`, etc.).
- Fully reversible uninstall: the LaunchAgent is deregistered (`launchctl bootout`) and its plist +
  log deleted, leaving no residue (no root writes, no receipts database, no Background Task
  Management entry). Documented under "Start at login" in the README.

### Notes

- No `.app` bundle, `.dmg`, `.pkg`, or code signing is involved — this is the minimal, low-footprint
  auto-start path for a personal single-machine setup. Distribution to other Macs would still call
  for a signed/notarized bundle (out of scope for this release).

## [1.0.0] - 2026-07-07

Initial stable release.

### Added

- Native macOS menu bar app (Swift + AppKit, single source file, no Xcode project) that renders an
  animated GIF as the image of one `NSStatusItem`.
- Automatic animation-speed adaptation to a selectable system load source, sampled every 2 s. All
  readers are unprivileged (no `sudo`), and the app only ever *reads* system state:
  - `cpu` (default) — EMA-smoothed CPU usage across all cores.
  - `memory` — memory-in-use composited with the swap-paging rate.
  - `gpu` — GPU device utilization.
  - `network` — total interface throughput (rx + tx, loopback excluded).
  - `disk` — total block-device throughput (read + write across all drives).
  Selectable via `--load-source`, `MENUBAR_LOAD_RUNNER_LOAD_SOURCE`, or the live `Load Source` menu;
  sources with no readable hardware are disabled and fall back to `cpu`.
- btop-style adaptive auto-scaling for the unbounded throughput sources (network / disk / swap
  rate): bytes-per-second are normalized to 0..1 against an adaptive, hysteresis-guarded ceiling
  that calibrates to recent activity on the machine.
- Nine built-in presets (dog, horse, and Totoro variants) whose profiles — keyword, menu title, GIF
  file, slot width, speed range, and the default preset — are externalized to `gifs/presets.json`.
  Presets can be added or tweaked by editing the manifest, with no Swift change.
- Custom GIF playback via a positional path argument or `MENUBAR_LOAD_RUNNER_PATH`.
- Fixed-speed override (`--speed-multiplier`) that disables load adaptation.
- Menu-bar width control in slots (`--width 1..4`), clamped to each preset's minimum width.
- Runtime text overlay baked onto each rendered frame (`--overlay-text`, up to 12 characters, with a
  bold toggle) without modifying the GIF file.
- Live status menu: the active source's metric and state line, load averages (1 / 5 / 15 m), speed
  multiplier, and radio selectors for load source, width, overlay text, and preset — plus About and
  Exit.
- Self-throttling: the app caps its *own* animation speed under Low Power Mode, thermal state
  `serious` / `critical`, or memory pressure `warning` / `critical`, so the indicator adds as little
  as possible to the load it visualizes.
- Full animation pause when the status item is occluded (notch/overflow, another Space, display
  off), driven by occlusion notifications.
- `CADisplayLink`-driven, vsync-aligned game loop on macOS 14+, with a 60 Hz `Timer` fallback on
  older systems; large inter-tick gaps (sleep, clock jump) resync instead of replaying every frame.
- zsh launcher with compile-on-change (`swiftc -O -strict-concurrency=complete`, interpreted `swift`
  fallback), singleton enforcement (`--extra` to allow an extra instance), and detached-by-default
  launch with logging (`--foreground` / `--no-detach` / `--detach`, `MENUBAR_LOAD_RUNNER_LOG_FILE`).
- Debug / QA hooks: `MENUBAR_LOAD_RUNNER_EXIT_AFTER` (self-terminate after N seconds) and
  `MENUBAR_LOAD_RUNNER_FORCE_UNAVAILABLE` (force a load source unavailable).
- In-app version string, shown in the About dialog and `--help`.
- Documentation: `README.md`, `docs/DESIGN-system.md` (source-anchored architecture map),
  `docs/RUNBOOK-qa-release.md` (release QA gate), and `CLAUDE.md`.

### Engineering notes

- Built warning-clean under `-strict-concurrency=complete`; both classes are `@MainActor`-isolated.
- Startup errors (including a missing or invalid `gifs/presets.json`) surface as an alert and quit
  cleanly, rather than calling `fatalError`.
