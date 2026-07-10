# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.
It is also the **canonical agent-instruction file for every tool**: `AGENTS.md` is a symlink to it
(the cross-tool standard read by Codex, Copilot, Cursor, etc.), so edit *this* file only — never
duplicate rules into `AGENTS.md`. Keep it lean and high-SNR; specialized or verbose rules live in
`docs/` or `.claude/` with a one-line pointer here.

## What this is

A single-file native macOS menu bar app (Swift + AppKit, no Xcode project/SwiftPM package) that renders an
animated GIF in the status bar. Animation speed adapts automatically to system CPU load. There is no test suite
and no build system beyond `swiftc`/`swift` invoked directly.

## Documentation

`docs/` holds SDLC documents — design specs, architecture write-ups, and TODO/issue-tracking
files. This `CLAUDE.md` stays focused on build/run commands and architecture guidance for
Claude Code; longer-form design and task tracking documents belong in `docs/` instead of the
repo root.

TODO files are named `TODO-<YYYYMMDD-HHMM>-<slug>.md` (e.g.
`docs/TODO-20260706-2010-swift-impl-review-findings.md`) — the timestamp is when the file was
created, so filenames sort chronologically and make ordering/timing explicit without needing
a separate changelog. Other `docs/` files (design specs, etc.) don't need the timestamp
prefix, e.g. `docs/DESIGN-system.md`.

## Commands

Run from the repository root:

```bash
./menubar-load-runner                       # default preset (horse-white), detached
./menubar-load-runner --foreground           # run attached to the current shell (see stderr/output directly)
./menubar-load-runner dog-black --overlay-text CPU
./menubar-load-runner --help
```

- The launcher (`menubar-load-runner`, a zsh script) compiles `MenuBarLoadRunner.swift` with
  `swiftc -O -strict-concurrency=complete` into the `MenuBarLoadRunner` binary next to it, and only
  recompiles when the source is newer than the binary. If `swiftc` fails, it falls back to
  `swift <file>` (interpreted, no cached binary). The `-strict-concurrency=complete` flag opts into
  full data-race checking; the two classes are annotated `@MainActor`, so the build is warning-clean.
  It runs in Swift 5 mode, so any future concurrency violation surfaces as a warning, not a hard build
  break.
- There's no separate "build" step — editing `MenuBarLoadRunner.swift` and re-running `./menubar-load-runner`
  is the whole loop. To force a rebuild without relying on the mtime check:
  ```bash
  swiftc -O -strict-concurrency=complete MenuBarLoadRunner.swift -o MenuBarLoadRunner
  ```
- To check compile errors quickly without launching the app:
  ```bash
  swiftc -O -strict-concurrency=complete MenuBarLoadRunner.swift -o tmp/mblr-check
  ```
- To smoke-test at runtime, set `MENUBAR_LOAD_RUNNER_EXIT_AFTER=<seconds>` so the app self-terminates
  (exit 0) instead of blocking the AppKit run loop forever — no background/kill dance needed:
  ```bash
  MENUBAR_LOAD_RUNNER_EXIT_AFTER=5 ./tmp/mblr-check --load-source memory   # runs 5s, exits 0
  ```
  Prefer this (or `timeout 5 …`) over launch-then-`kill`. Note the raw binary bypasses the launcher's
  singleton, so stacked instances / a run wedged in a modal alert are what otherwise force a manual `pkill`.
- The launcher enforces a singleton via `pgrep -f "/MenuBarLoadRunner( |$)"` — only one instance runs unless
  `--extra` is passed. (The pattern matches the compiled binary path, not the process args, since args no
  longer carry a `.gif` path now that Swift resolves preset keywords.) When iterating locally, stop any
  running instance first:
  ```bash
  pkill -f 'MenuBarLoadRunner'
  ```
- Detached runs log to `/tmp/menubar-load-runner.log` (override with `MENUBAR_LOAD_RUNNER_LOG_FILE`); use
  `--foreground` while developing so output goes straight to the terminal.
- `MenuBarLoadRunner` (the compiled binary) is gitignored; `MenuBarLoadRunner.swift` is the only source of truth.

## Installer (`install.sh` — end-user install, already exists — do not rebuild)

`install.sh` at the repo root is the user-facing one-line installer (gitlogue-style curl|bash,
adapted for a *source-based* app — Homebrew/notarization are deferred, see Out of scope below). It
is intentionally MVP:

- Flow: preflight (macOS + `git`/`swiftc`, else `xcode-select --install`) → `git clone` into
  `~/.local/share/menubar-load-runner` (existing checkout → `git pull --ff-only`) → precompile
  (fail-fast; falls back to on-demand compile) → symlink launcher into `~/.local/bin` → optional
  `[y/N]` start-at-login prompt (via `/dev/tty`, so a piped `curl | bash` safely skips) → PATH hint.
- Env overrides: `MENUBAR_LOAD_RUNNER_HOME`, `BIN_DIR`, and `MENUBAR_LOAD_RUNNER_REPO_URL` (the last
  is test scaffolding — point it at a local clone to smoke-test into `./tmp/`). Flags: `--login`, `--help`.
- **Deliberately out of scope** (don't add without a reason — they were reviewed and cut as
  non-MVP): tag-pinning / `--ref` / `VERSION`, a Homebrew tap/formula, and a signed+notarized `.app`.
  It installs the latest default branch; power users `git checkout` a tag themselves.
- The installer *reuses* `scripts/install-login-item.sh` for start-at-login — it does not re-implement
  the LaunchAgent (see next section).
- `uninstall.sh` (repo root) reverses it: tears down the LaunchAgent (if enabled), stops any running
  instance, removes the `BIN_DIR` symlink (only if it points into the install dir), and removes the
  install dir (`[y/N]` confirm, `--yes` to skip; refuses/warns instead of deleting if the dir isn't
  its own git checkout).

## Start-at-login / LaunchAgent (already exists — do not rebuild)

Auto-start is **already implemented** as a per-user LaunchAgent; don't hand-roll a plist, `launchctl`
sequence, or `.app` bundle. Use the scripts:

```bash
./scripts/install-login-item.sh [preset] [flags]   # bake args, load + start now and at login
./scripts/uninstall-login-item.sh                  # deregister + delete plist and log
```

- Label `ai.bera.menubarloadrunner`; plist at `~/Library/LaunchAgents/`. No root, no signing.
- `ProgramArguments` = the **launcher script** + `--no-detach` (so `launchd` supervises the real
  process) + baked args. Because it runs the launcher (not a fixed binary), a source edit is picked up
  on the next agent start — restart with `launchctl kickstart -k "gui/$(id -u)/ai.bera.menubarloadrunner"`,
  no reinstall. Reinstall is **only** for changing baked args.
- `RunAtLoad`, no `KeepAlive` (menu **Exit** quits until next login). Shows under System Settings →
  Login Items → "Allow in the Background". Full mechanics (bootout reload race, etc.) in
  `docs/DESIGN-system.md` §19.

## Architecture

Everything lives in `MenuBarLoadRunner.swift` (~1200 lines), organized top to bottom as:

- **`Tuning`** — every magic number (icon-aspect clamp, overlay font sizing, alpha trim threshold,
  hysteresis, etc.) lives here. When adjusting behavior, change constants here rather than inlining new
  literals. **Exception:** per-preset speed ranges live in `gifs/presets.json` (see the
  preset-registry note below), not `Tuning`. Width is not tuned per-preset — it derives from each GIF's
  aspect ratio at runtime (`currentGifAspect`/`slotLength`).
- **`Config`** — CLI arg / env var parsing (`--speed-multiplier`, `--overlay-text`, positional
  preset keyword or GIF path, `MENUBAR_LOAD_RUNNER_PATH` fallback). The positional arg is captured verbatim as
  `presetOrPath`; when absent it is left empty and the app resolves the manifest's `defaultPreset`
  (`horse-white`). Keyword→path resolution
  happens in `MenuBarLoadRunnerApp.init` (matching `allPresets` by `key`, then by `path`), *not* in the shell
  launcher, which now forwards the arg unchanged.
- **`CPULoadMonitor`** — reads `host_processor_info`/`PROCESSOR_CPU_LOAD_INFO` via Mach APIs and exposes an
  EMA-smoothed CPU usage fraction (`Tuning.cpuSmoothingAlpha`). Requires two samples to produce a delta, so
  usage is nil until the second `sampleSystemLoad` tick.
- **`MemoryLoadMonitor`** — sibling reader, a *mixed domain*: an *instantaneous* memory used-fraction
  via `host_statistics64(HOST_VM_INFO64)` (a point read, no EMA, valid on the first sample) plus a
  *counter-delta* swap rate — `swapins`/`swapouts` from the same `vm_statistics64` read, differenced
  over the real elapsed wall time passed into `sampleUsage(elapsed:)` (so the rate warms up one tick,
  like the CPU reader). The driver value is `currentMemoryLoad = max(usedFraction, scaled(swapRate))`
  where the unbounded swap *rate* normalizes through a shared `ThroughputScaler` (see below), not a
  fixed reference; the menu still shows the raw used-fraction (+ swap capacity via
  `sysctlbyname("vm.swapusage")` and, when paging, the live MB/s rate). Same unprivileged Mach/sysctl
  tier as `CPULoadMonitor`. `nil` (never `0`) on failure. Used-fraction + composite formulas are
  documented in the class comment / `Tuning` (a deliberate approximation, not Activity Monitor's exact
  algorithm).
- **`GPULoadMonitor` / `NetworkLoadMonitor` / `DiskLoadMonitor`** — the other three load-source
  readers, same unprivileged tier (IORegistry + `getifaddrs`, `import IOKit`). GPU is an instantaneous
  0…1 point read (`IOAccelerator → PerformanceStatistics → "Device Utilization %"`); network
  (`getifaddrs → if_data`, AF_LINK, skip `lo0`) and disk (`IOBlockStorageDriver → Statistics → Bytes
  (Read)/(Write)`) are counter-deltas over `elapsed:`. Each has an `isAvailable` probe (`nil` reader →
  disabled menu item + launch fallback to `.cpu`).
- **`ThroughputScaler`** — shared value type (ported from btop `Net::collect`) that normalizes any
  *unbounded rate* signal (network/disk/swap bytes-per-sec) to 0…1 against an adaptive ceiling:
  `max(avg(last Tuning.scalerWindow) × headroom, floor)`, rescaled only after
  `Tuning.scalerRescaleCount` consecutive out-of-band samples (hysteresis), asymmetric headroom
  (`scalerHeadroomUp`/`scalerHeadroomDown`), per-source floor. **Bounded** percentage signals (CPU %,
  memory-used %, GPU %) are NOT scaled — they map through directly.
- **`MenuBarLoadRunnerApp`** (`NSApplicationDelegate`/`NSMenuDelegate`) — the entire app. Key internal
  concepts to know before changing behavior:
  - **Preset identity is externalized to `gifs/presets.json`.** That manifest (`defaultPreset` + a
    `presets` array of `{key, menuTitle, file, speed:{label,min,max,responseExponent}}`) is the
    single source of truth for every built-in preset's profile. `init(config:)` decodes it via `JSONDecoder`
    into the `PresetManifest` Codable structs and maps each entry into `allPresets: [PresetDescriptor]`
    (`file` is resolved to an absolute path relative to `#filePath`'s directory). The Swift code holds **no**
    hardcoded preset list, and there are no per-preset speed constants in `Tuning` anymore. Selecting a
    preset resolves `activePreset` once (in `switchToGif(to:descriptor:)`); `currentSpeedProfile()`
    is a trivial read of `activePreset` (falling back to `defaultDescriptor`, the
    manifest's declared default). A custom/user-supplied GIF that matches no entry leaves `activePreset` `nil`
    and borrows `defaultDescriptor`'s profile (or `Self.customSpeedProfile` if the
    manifest itself failed to load). If the manifest can't be loaded/decoded, `init` records `startupError` and
    `applicationDidFinishLaunching` shows it and quits. The default preset is the manifest's `defaultPreset`
    field, resolved when `config.presetOrPath` is empty (no arg / env override).
  - **Two decoupled pipelines**: `frames`/`frameAspects`/`baseDurations` hold the raw decoded GIF (from
    `loadFrames`, which also trims transparent padding via `trimTransparentPadding` so preset art isn't
    padded to a square). `renderedFrames` holds the actual per-frame `NSImage`s sized for the current status
    item length and with the overlay text (if any) baked in, produced by `updateRenderedFrames()`. Any change
    to width, overlay text, or overlay bold state must call `updateRenderedFrames()` (usually via
    `applySizing()`) before `renderCurrentFrame()` picks up the new images.
  - **Game loop**: a `CADisplayLink` (macOS 14+, via `NSView.displayLink` on the status item button; a 60 Hz
    `Timer` fallback on older systems) drives `advanceFrames(now:)`, which accumulates real elapsed time
    (`link.timestamp`) and advances `frameIndex` based on each frame's GIF delay divided by the current
    `speedMultiplier`, looping (possibly multiple frames per tick) until under budget. Ticks are vsync-aligned
    and follow the screen's refresh rate. Speed changes take effect immediately since the driver reads
    `speedMultiplier` live — `sampleSystemLoad` no longer restarts the driver on a speed change. `startGameLoop`
    (re)creates the driver; `resetGameLoopTiming` re-syncs the clock (used on frame-source switch). Gaps larger
    than `Tuning.maxFrameAdvanceDelta` (sleep/occlusion/clock jump) resync instead of replaying every frame.
  - **Auto speed**: on each `loadSampleInterval` (2s) tick, `speedMultiplier(forUsage:)` maps the active
    load source's 0..1 fraction through the current preset's `SpeedProfile` (min/max/response exponent —
    linear for every preset), and only applies the new value if the change exceeds
    `Tuning.speedUpdateHysteresis`, to avoid visible jitter. Disabled entirely when
    `--speed-multiplier` is passed.
  - **Load source selector**: `activeLoadSource: LoadSource` (`.cpu` default, `.memory` available;
    `--load-source`/`MENUBAR_LOAD_RUNNER_LOAD_SOURCE`, unknown → `.cpu`) picks *which* reader drives the
    animation, independent of the preset's speed range. `LoadSource` is a single registry (key + menu title)
    like `PresetDescriptor`. The speed path reads the active source, never `loadMonitor` directly, through
    three helpers: `sampleActiveSource(elapsed:)` (in `sampleSystemLoad`), `activeSourceHasSample` /
    `activeSourceCurrentUsage` (in `reevaluateSpeedForCurrentConditions`). Sampling is **active-only** (the
    inactive monitor isn't polled), so `refreshMenuMetrics` is **source-conditional**: it shows the active
    source's metric + state (CPU%/CPU State, or Memory%+swap/Memory Pressure) — not both. The `Load Source`
    submenu is a radio group wired exactly like width/preset (`selectLoadSource`,
    `refreshLoadSourceSelectionState`). Adding gpu/network/disk = add a `LoadSource` case + its reader +
    branches in the three helpers. Counter-delta sources divide by the real elapsed wall time captured
    each tick in `sampleSystemLoad` (`ProcessInfo.systemUptime` → `lastSampleUptime`, threaded as the
    `elapsed:` arg); the memory source's swap rate already uses it, and network/disk reuse it (a source
    switch resets `lastSampleUptime` so rates re-warm cleanly).
  - **Self-throttling under pressure** (the app throttles *its own* animation, never the system —
    it only ever *reads* system state): the indicator reduces its own CPU use so it doesn't add to
    the load it visualizes. `speedMultiplier(forUsage:)` caps *this app's* auto animation speed at the
    midpoint of the preset's range (`Tuning.constrainedSpeedCeilingFraction`) when `isUnderPowerPressure`
    (Low Power Mode on, `thermalState` `.serious`/`.critical`, or memory pressure `.warning`/`.critical`).
    Fewer frame advances/redraws = less CPU spent by the app; nothing about the system or other processes
    is changed. It subscribes to `.NSProcessInfoPowerStateDidChange` /
    `ProcessInfo.thermalStateDidChangeNotification` and a `DispatchSource.makeMemoryPressureSource` (mask
    **must** include `.normal` to lift the cap — memory pressure is event-only with no synchronous getter,
    so `memoryPressureLevel` is cached; its lifecycle is `resume()`/`cancel()`, NOT `removeObserver`), each
    calling `reevaluateSpeedForCurrentConditions()` (recomputes immediately, bypassing hysteresis) so the
    cap engages/lifts without waiting for the next 2s tick. Separately, `updateAnimationForOcclusion()` (driven by
    `NSWindow.didChangeOcclusionStateNotification` on the status button's window) stops the game loop
    entirely when the item is fully occluded (notch/overflow, another Space, display off) and restarts
    it when visible — no re-rasterizing frames no one can see. It only ever pauses in response to a
    positive occlusion event, so a never-firing notification leaves animation running (no freeze risk).
  - **Menu bar state is menu-driven**: the status item menu doubles as a live dashboard — metrics and
    selection state are refreshed on `menuWillOpen` (`refreshMenuMetrics`, `refreshPresetSelectionState`,
    `refreshWidthInfo`, `refreshOverlaySelectionState`, `refreshLoadSourceSelectionState`) rather
    than pushed reactively. When adding
    a new piece of runtime state, wire it into these refresh functions and into the initial
    `applicationDidFinishLaunching` setup.
  - **Width model**: width is **GIF-derived, not configurable**. `currentGifAspect()` reads the loaded
    GIF's aspect (frames share one union bbox from `trimTransparentPadding`, so any frame represents the
    whole animation), clamped to `[Tuning.minAspect, Tuning.maxIconAspect]`. `slotLength()` maps that to
    the status-item length (menu-bar height × aspect, floored at `Tuning.minBaseSlotWidth`) — the sole
    driver of item width, used by both `applySizing()` and the read-only `refreshWidthInfo()` menu line.
    There is no user width control (`--width` / slot submenu removed) and no per-preset slot constant.
  - **Overlay char limit is width-adaptive**: `maxOverlayChars()` estimates how many monospaced glyphs
    fit across `slotLength()` at the overlay font size, clamped to `[Tuning.overlayMinChars,
    Tuning.overlayMaxChars]`. The interactive `Set Text...` prompt and its menu title use it; the
    `--overlay-text` CLI path validates against the absolute `overlayMaxChars` ceiling since the GIF
    width isn't known at parse time. Rendering still truncates (`byTruncatingTail`) as a backstop.

## Adding a new built-in preset

No Swift edit is needed — preset profiles are data in `gifs/presets.json`. Touch these together, or the
preset will be inconsistent across the CLI, menu, and README:
1. Add the GIF to `gifs/`.
2. `gifs/presets.json` — add one object to the `presets` array: `{key, menuTitle, file,
   speed:{label, min, max, responseExponent}}`. `file` is the GIF filename relative to `gifs/`. This is the
   single source of the preset's keyword, menu title, path, and speed profile — the CLI keyword,
   menu item, `@objc` action, and every selection-state check all derive from it at startup. (Optionally set
   `defaultPreset` to a `key` in the array to change the no-arg default.) There is no width field — the
   menu-bar item sizes itself to the GIF's aspect ratio, so just make sure the GIF is trimmed/proportioned
   the way you want it to appear.
3. `menubar-load-runner` — add a line to `print_help`'s preset list and usage string (docs only; the launcher
   forwards the keyword to Swift unchanged).
4. `README.md` — add it to the file list, the built-in presets command list, and the auto speed ranges table.
