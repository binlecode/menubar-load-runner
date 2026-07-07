# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

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
- The launcher enforces a singleton via `pgrep -f "MenuBarLoadRunner.*\.gif"` — only one instance runs unless
  `--extra` is passed. When iterating locally, stop any running instance first:
  ```bash
  pkill -f 'MenuBarLoadRunner'
  ```
- Detached runs log to `/tmp/menubar-load-runner.log` (override with `MENUBAR_LOAD_RUNNER_LOG_FILE`); use
  `--foreground` while developing so output goes straight to the terminal.
- `MenuBarLoadRunner` (the compiled binary) is gitignored; `MenuBarLoadRunner.swift` is the only source of truth.

## Architecture

Everything lives in `MenuBarLoadRunner.swift` (~1200 lines), organized top to bottom as:

- **`Tuning`** — every magic number (speed ranges per preset, slot-width scaling, overlay font sizing, alpha
  trim threshold, hysteresis, etc.) lives here. When adjusting behavior, change constants here rather than
  inlining new literals.
- **`Config`** — CLI arg / env var parsing (`--width`, `--speed-multiplier`, `--overlay-text`, positional GIF
  path or preset name, `MENUBAR_LOAD_RUNNER_PATH` fallback). Preset-name-to-path resolution happens in the
  `menubar-load-runner` shell launcher, *not* here — by the time Swift sees `arg`, it's already an absolute
  GIF path.
- **`CPULoadMonitor`** — reads `host_processor_info`/`PROCESSOR_CPU_LOAD_INFO` via Mach APIs and exposes an
  EMA-smoothed CPU usage fraction (`Tuning.cpuSmoothingAlpha`). Requires two samples to produce a delta, so
  usage is nil until the second `sampleSystemLoad` tick.
- **`MenuBarLoadRunnerApp`** (`NSApplicationDelegate`/`NSMenuDelegate`) — the entire app. Key internal
  concepts to know before changing behavior:
  - **Preset identity is a single registry.** `allPresets: [PresetDescriptor]` (built once in `init(config:)`,
    paths resolved relative to `#filePath`'s directory) is the source of truth for every built-in preset's
    menu title, path, `PresetKind`, slot scale, and `SpeedProfile`. Selecting a preset resolves `activePreset`
    once (in `switchToGif(to:descriptor:)`); `currentPresetKind()`/`currentPresetScale()`/
    `currentSpeedProfile()` are trivial reads of `activePreset`. A custom/user-supplied GIF that doesn't match
    any entry in `allPresets` leaves `activePreset` `nil`, falling through to `.custom` (dog's speed range,
    `dogSlotScale` width, via `Self.customSpeedProfile`).
  - **Two decoupled pipelines**: `frames`/`frameAspects`/`baseDurations` hold the raw decoded GIF (from
    `loadFrames`, which also trims transparent padding via `trimTransparentPadding` so preset art isn't
    padded to a square). `renderedFrames` holds the actual per-frame `NSImage`s sized for the current status
    item length and with the overlay text (if any) baked in, produced by `updateRenderedFrames()`. Any change
    to width, overlay text, or overlay bold state must call `updateRenderedFrames()` (usually via
    `applySizing()`) before `renderCurrentFrame()` picks up the new images.
  - **Game loop**: a 60 Hz `Timer` (`gameLoopTick`) accumulates real elapsed time and advances `frameIndex`
    based on each frame's GIF delay divided by the current `speedMultiplier`, looping (possibly multiple
    frames per tick) until under budget. Speed changes take effect immediately since the timer reads
    `speedMultiplier` live; a new `startGameLoop()` call is only used to reset `lastTickTime`/accumulated time.
  - **Auto speed**: on each `loadSampleInterval` (2s) tick, `speedMultiplier(forUsage:)` maps smoothed CPU
    usage through the current preset's `SpeedProfile` (min/max/response exponent — linear for most presets,
    an eased curve for `raining`), and only applies the new value if the change exceeds
    `Tuning.speedUpdateHysteresis`, to avoid visible jitter. Disabled entirely when `--speed-multiplier` is
    passed.
  - **Menu bar state is menu-driven**: the status item menu doubles as a live dashboard — metrics and
    selection state are refreshed on `menuWillOpen` (`refreshMenuMetrics`, `refreshPresetSelectionState`,
    `refreshWidthSelectionState`, `refreshOverlaySelectionState`) rather than pushed reactively. When adding
    a new piece of runtime state, wire it into these refresh functions and into the initial
    `applicationDidFinishLaunching` setup.
  - **Width model**: `requestedWidthSlots` (nil = auto) combines with `minimumSlotsForCurrentPreset()`
    (derived from `currentPresetScale()`, e.g. `totoro-group` forces 4 slots) via `effectiveWidthSlots()` to
    clamp the user's request. Switching presets re-derives the effective width from the new preset's minimum.

## Adding a new built-in preset

Touch all of these together, or the preset will be inconsistent across the CLI, menu, and README:
1. Add the GIF to `gifs/`.
2. `menubar-load-runner` — add a `*_gif` path var, a `case` in the preset-name switch, and a line in
   `print_help`'s preset list.
3. `MenuBarLoadRunner.swift` — add one `PresetDescriptor` entry to the `allPresets` array literal in
   `init(config:)` (reuse an existing `PresetKind` case, or add a new one, plus a `Tuning` min/max pair and a
   `SpeedProfile` if it needs its own speed range). The menu item, `@objc` action, and every selection-state
   check derive automatically from `allPresets` — no other call site needs touching.
4. `README.md` — add it to the file list, the built-in presets command list, and the auto speed ranges table.
