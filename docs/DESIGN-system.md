# DESIGN-system.md

Ground truth for this document: `menubar-load-runner` (zsh launcher, 181 lines) and
`MenuBarLoadRunner.swift` (2221 lines), plus the auxiliary login-item scripts under `scripts/`
(§19). Every claim below is derived from the source and was re-verified against it.

**Anchoring convention.** Each section/subsection names the exact Swift/shell **symbol** it maps to
(e.g. `speedMultiplier(forUsage:)`, `resolve_script_dir()`). That symbol name — unique and
greppable — is the authoritative anchor. Parenthetical **line numbers are approximate** and lag the
source as the file grows (they were once exact and have since drifted); when a line number and a
symbol name disagree, trust the symbol name and `grep` for it. This deliberately avoids duplicating
volatile line positions that rot on every edit.

This document is a structural map of the code as it exists, for resync whenever either source file
changes; the body carries only the minimal rationale needed to make a behavior legible. Review-style
observations (modularity / DRY / API boundaries) are **not** kept in the body — the one such review
pass to date has been closed out, with per-item outcomes and the rationale for what was declined
recorded in Appendix B.

It reflects the current implemented state including: the `@MainActor`/`-strict-concurrency=complete`
concurrency posture (§4); self-throttling of the app's own animation under power/thermal pressure
and full pause under occlusion (§12.2, §13.6); graceful startup-error quit instead of `fatalError`
(§9.2, §17); the live VoiceOver accessibility label (§9.2, §10.3); and the `CADisplayLink` game loop
(§13).

---

## 1. Mission (as expressed by code, not prose)

Derived from `Config.printUsage()` and the CPU-driven speed logic
(`speedMultiplier(forUsage:)`):

> Render a GIF, decoded from disk, as the image of one `NSStatusItem` in the macOS menu bar,
> and continuously vary the playback speed of that GIF as a function of smoothed system CPU
> usage, sampled every `Tuning.loadSampleInterval` seconds.

Fixed-speed mode (`--speed-multiplier`) is a supported deviation from the auto-speed mission:
when `config.speedMultiplierOverride != nil`, the load-to-speed mapping in
`sampleSystemLoad()` (line 1346: `if isAutoSpeed`, where `isAutoSpeed` is
`config.speedMultiplierOverride == nil`) is skipped entirely — `speedMultiplier` becomes a
constant, clamped once at startup to `Tuning.speedOverrideMin...Tuning.speedOverrideMax`
(lines 1125-1127).

---

## 2. Process architecture

Two processes, two languages, executed in sequence per invocation:

```
user shell
   └── menubar-load-runner (zsh script, this repo's entrypoint)
          ├── resolves its own script directory (resolve_script_dir, lines 6-26)
          ├── parses CLI args into: launch_detached, allow_extra, passthrough_args (lines 98-114)
          ├── forwards the positional arg (preset keyword or path) unchanged; only intercepts
          │      its own -h/--help (lines 120-127) — keyword→path resolution and the default
          │      preset moved to the Swift side (Config/init)
          ├── decides swiftc vs swift execution (lines 135-144):
          │      - if MenuBarLoadRunner binary missing or older than MenuBarLoadRunner.swift:
          │            try `swiftc -O` to (re)build the binary
          │            on swiftc failure, fall back to `swift -module-cache-path ... <src>` (interpreted)
          │      - else: run the existing compiled binary directly
          ├── enforces a singleton via `pgrep -f "/MenuBarLoadRunner( |$)"` unless --extra (lines 147-163)
          └── launches the resolved command, either:
                 - detached: nohup + disown, stdout/stderr -> log file, script exits 0 (lines 165-174)
                 - foreground: exec (replaces the shell process) (lines 176-177)
                     └── MenuBarLoadRunner (compiled Swift binary OR `swift` interpreter session)
                            = NSApplication process running MenuBarLoadRunnerApp as its delegate
                            (bottom of MenuBarLoadRunner.swift, lines 2210-2220)
```

Environment variables read by the launcher and passed to the Swift process:
- `SWIFT_MODULE_CACHE` (launcher-side only, default `/tmp/swift-module-cache`, line 95)
- `MENUBAR_LOAD_RUNNER_LOG_FILE` (launcher-side only, default `/tmp/menubar-load-runner.log`, line 166)
- `MENUBAR_LOAD_RUNNER_BIN_NAME` (set by launcher to `menubar-load-runner/menubar-load-runner`,
  lines 168, 176; read by the Swift process in `Config.printUsage()`, line 246, for its own
  `--help` text)
- `MENUBAR_LOAD_RUNNER_PATH` (read only by the Swift process, `Config.parse()` line 212, as a
  fallback GIF path when no positional argument was given)

### 2.1 Module dependency map (Swift binary)

Top-level declarations. Arrows = "depends on / calls". `Tuning` is a pure leaf; `CPULoadMonitor`
is joined by the sibling load-source readers `MemoryLoadMonitor`/`GPULoadMonitor`/
`NetworkLoadMonitor`/`DiskLoadMonitor` and the shared `ThroughputScaler` value type (§7.5–§7.9),
plus the `LoadHistoryView` trace chart; `MenuBarLoadRunnerApp` is the hub that owns everything
else (the size/shape consequence is tracked in the anti-patterns TODO; see Appendix B). The
diagram below shows only `CPULoadMonitor` for legibility; the other readers slot in beside it.

```
                         ┌───────────────────────────────┐
       entry point  ───► │ switch Config.parse()          │
   (end of file)         │   .config → build App, run()   │
                         └───────┬───────────────┬────────┘
                                 │               │
                                 ▼               ▼
                         ┌───────────────┐   ┌─────────────────────────────────────┐
                         │ Config        │   │ MenuBarLoadRunnerApp   @MainActor    │
                         │ (struct)      │   │ NSObject / NSApplicationDelegate /   │
                         │ CLI+env parse │   │ NSMenuDelegate  — the hub (~1000 ln) │
                         │ printUsage()  │   └───┬───────────────┬──────────────┬───┘
                         └───────┬───────┘       │ owns          │ calls        │ reads
                                 │               ▼               ▼              │
                                 │       ┌───────────────┐  ┌──────────────┐    │
                                 │       │ CPULoadMonitor │  │ AppKit /      │   │
                                 │       │ @MainActor     │  │ CoreGraphics/ │   │
                                 │       │ Mach CPU ticks │  │ Mach / POSIX  │   │
                                 │       └───────┬────────┘  └──────────────┘    │
                                 │               │                               │
                                 ▼               ▼                               ▼
                         ┌─────────────────────────────────────────────────────────┐
                         │ Tuning (enum) — all static-let constants; pure leaf,     │
                         │ no dependencies; referenced by every box above           │
                         └─────────────────────────────────────────────────────────┘
```

### 2.2 API layers within `MenuBarLoadRunnerApp`

The class has almost no *public* surface — its externally-visible API is just the framework
conformances (`applicationDidFinishLaunching`, `applicationWillTerminate`, `menuWillOpen`) plus the
`@objc` menu targets. Everything below is `private`. The layers below are a *call-direction* map
(top = inputs, bottom = leaves); control flows downward, and no layer calls back up.

```
 INPUT / EVENT SOURCES (framework-driven, all on the main actor)
 ┌──────────────┬───────────────┬───────────────────┬────────────────────────────┐
 │ App lifecycle│ NSMenuDelegate│ CADisplayLink /   │ NotificationCenter observers │
 │ didFinish…/  │ menuWillOpen  │ Timer ticks       │ screen / power / thermal /   │
 │ willTerminate│               │ displayLinkTick / │ occlusion                    │
 │              │               │ fallbackTimerTick │                              │
 └──────┬───────┴───────┬───────┴─────────┬─────────┴───────────────┬──────────────┘
        │        ┌───────┴───────┐         │                         │
        │        │ @objc actions │         │                         │
        │        │ selectPreset  │         │                         │
        │        │ selectWidth*  │         │                         │
        │        │ promptOverlay │         │                         │
        │        │ clearOverlay  │         │                         │
        │        │ showAbout/exit│         │                         │
        ▼        ▼               ▼         ▼                         ▼
 ┌───────────────────────────────────────────────────────────────────────────────┐
 │ COORDINATION / STATE MUTATION                                                   │
 │ switchToGif · applySizing · sampleSystemLoad · reevaluateSpeedForConditions ·   │
 │ updateAnimationForOcclusion · start/stop/resetGameLoop · startLoadMonitoring    │
 └───────┬───────────────────────┬───────────────────────────┬────────────────────┘
         ▼                        ▼                           ▼
 ┌────────────────┐   ┌──────────────────────────┐   ┌──────────────────────────────┐
 │ PRESENTATION   │   │ RENDER PIPELINE          │   │ DATA / DECODE PIPELINE        │
 │ refreshMenu-   │   │ updateRenderedFrames ──► │   │ loadFrames ──► trimTranspar-  │
 │ Metrics ·      │   │ renderCurrentFrame       │   │ entPadding · frameDuration    │
 │ refresh*Sel-   │   │ advanceFrames (game loop)│   │ (frames/aspects/baseDurations)│
 │ ectionState×3  │   │ (renderedFrames)         │   │                               │
 └───────┬────────┘   └────────────┬─────────────┘   └───────────────┬───────────────┘
         └─────────────────────────┴─── read-only derivation ────────┘
                                        ▼
 ┌───────────────────────────────────────────────────────────────────────────────┐
 │ PURE READ-ONLY HELPERS (no mutation): currentPresetScale · isAutoSpeed ·        │
 │ currentSpeedProfile · effectiveWidthSlots · minimumSlotsForCurrentPreset ·      │
 │ effectiveOverlayText · speedMultiplier(forUsage:) · isUnderPowerPressure ·      │
 │ cpuStateText · readSystemLoadAverages  + collaborators: cpu/memory/gpu/network/ │
 │ disk monitors, allPresets                                                       │
 └───────────────────────────────────────────────────────────────────────────────┘
```

Two independent clocks drive the hub: the 2 s `loadTimer` (`sampleSystemLoad` → speed) and the
per-refresh display link (`advanceFrames` → frame index). They share only `speedMultiplier` (writer:
sample tick / power-thermal observers; reader: the accumulator), which is why a speed change needs
no driver restart (§12, §13).

---

## 3. Launcher module (`menubar-load-runner`)

### 3.1 `resolve_script_dir()` (lines 6-26)
Resolves the script's own real directory by following symlinks (`readlink` loop, lines
19-23), using zsh's `${(%):-%x}` expansion to get its own path (line 9), falling back to
`command -v` if invoked by bare name without a `/` in it (lines 11-17).

### 3.2 `print_help()` (lines 28-80)
Static text block (docs only — the launcher no longer maps keywords to paths). Lists the 12
preset keywords (`dog-white`, `dog-black`, `horse-black`, `horse-white`, `chihiro`,
`chihiro-white`, `chihiro-black`, `totoro`, `totoro-group-white`, `totoro-group-black`,
`totoro-white`, `totoro-black`) and 8 flags (`--width`, `--speed-multiplier`, `--load-source`,
`--overlay-text`, `--foreground`/`--no-detach`, `--detach`, `--extra`, `-h`/`--help`). The former
`horse`→`horse-black` alias was removed; callers use canonical names. These keywords are
documentation of what the Swift side (`allPresets`, sourced from `gifs/presets.json`) accepts, not
a launcher-side mapping.

### 3.3 `main()` (lines 82-180)

**Preflight** (lines 83-86): exits 127 if `swift` is not on `PATH`.

**Flag scan** (lines 98-114): single pass over `$@`; `--foreground`/`--no-detach` set
`launch_detached=0`; `--detach` sets `launch_detached=1`; `--extra` sets `allow_extra=1`;
everything else is pushed into `passthrough_args` unchanged (including unrecognized flags and
the positional preset keyword / GIF path — the launcher validates none of them; that is left
to `Config.parse()` / `MenuBarLoadRunnerApp.init` in the Swift binary).

**Positional passthrough** (lines 120-127): the launcher no longer resolves preset keywords or
supplies a default. It forwards the positional arg (preset keyword *or* raw path *or* nothing)
to the Swift binary verbatim, only intercepting its own `-h`/`--help` (print help, exit 0).
Keyword→path resolution and the `horse-white` default now live Swift-side (see §8.1, §9;
`Config.defaultPreset` supplies the default when no positional arg / env override is present).
This removed the launcher's former 10-entry path table, the keyword `case` switch, and the
default injection — collapsing the preset mapping to a single language.

**Build-or-reuse decision** (lines 135-144): compares mtimes of
`MenuBarLoadRunner.swift` and `MenuBarLoadRunner` (the compiled binary); rebuilds with
`swiftc -O` only when missing or stale; falls back to interpreted `swift` on compile failure.

**Singleton enforcement** (lines 147-163): `pgrep -f "/MenuBarLoadRunner( |$)"` — matches a
process whose command line contains the compiled binary's path segment `/MenuBarLoadRunner`
followed by a space (it has args) or end-of-line (env-var mode, no positional). The pattern
had to change from the old `"MenuBarLoadRunner.*\.gif"`: now that Swift resolves preset
keywords, the args no longer carry a `.gif` path, so the old pattern would miss keyword
launches. The trailing `( |$)` also keeps it from matching an editor holding
`MenuBarLoadRunner.swift` open or a `swiftc`/`swift` build of the source — with the deliberate
trade-off that the interpreted-`swift` fallback (used only when `swiftc` fails) is **not**
singleton-guarded. `pgrep -f` excludes its own process, and the lowercase launcher path
`menubar-load-runner` never matches. If any PID is found and `--extra` was not passed, the
launcher prints an error to stderr and exits 1 without ever invoking the Swift process.

**Launch** (lines 165-177):
- Detached: `nohup ... >>"$log_file" 2>&1 </dev/null &`, `disown`, prints
  `pid=... log=...`, exits 0. The launcher process itself terminates; the Swift process is
  reparented and continues running.
- Foreground: `exec` — the launcher process image is replaced by the Swift process (no
  child/parent relationship; same PID).

---

## 4. Swift binary — top-level structure

`MenuBarLoadRunner.swift` has twelve top-level declarations plus a script-level entry point:

| # | Declaration | Lines | Kind |
|---|---|---|---|
| 1 | `AppInfo` | 10-12 | `enum` (single `version` `static let`) |
| 2 | `Tuning` | 14-88 | `enum` (namespace of `static let` constants only) |
| 3 | `LoadSource` | 93-124 | `enum Int, CaseIterable` (load-source registry: key + menu title) |
| 4 | `Config` | 126-256 | `struct` (CLI/env parsing + usage text) |
| 5 | `ThroughputScaler` | 266-319 | `struct` (adaptive 0…1 normalizer for unbounded rates) |
| 6 | `CPULoadMonitor` | 321-390 | `@MainActor final class` (CPU sampling) |
| 7 | `MemoryLoadMonitor` | 399-502 | `@MainActor final class` (memory + swap) |
| 8 | `GPULoadMonitor` | 509-570 | `@MainActor final class` (GPU utilization) |
| 9 | `NetworkLoadMonitor` | 576-626 | `@MainActor final class` (network throughput) |
| 10 | `DiskLoadMonitor` | 631-694 | `@MainActor final class` (disk I/O throughput) |
| 11 | `LoadHistoryView` | 701-792 | `@MainActor final class`, `NSView` (menu trace chart) |
| 12 | `MenuBarLoadRunnerApp` | 794-2208 | `@MainActor final class`, `NSObject`, conforms to `NSApplicationDelegate`, `NSMenuDelegate` |
| — | entry point | 2210-2220 | top-level `switch` on `Config.parse()` |

**Concurrency posture.** All six classes (`CPULoadMonitor`, `MemoryLoadMonitor`, `GPULoadMonitor`,
`NetworkLoadMonitor`, `DiskLoadMonitor`, `LoadHistoryView`, `MenuBarLoadRunnerApp`) are annotated
`@MainActor`, and the launcher builds with
`swiftc -O -strict-concurrency=complete` (interpreted fallback: `swift -strict-concurrency=complete`)
in Swift 5 mode — so any future data-race violation surfaces as a *warning*, not a hard build break.
The build is warning-clean. The sites that needed help reaching the `@MainActor`-isolated
methods from `queue: .main` callbacks are the four `NotificationCenter` observer closures (the
screen-parameters, power-state, thermal-state, and occlusion observers), the memory-pressure
`DispatchSource` event handler, and the `MENUBAR_LOAD_RUNNER_EXIT_AFTER` `asyncAfter` closure: each
wraps its body in `MainActor.assumeIsolated { ... }`, safe precisely because each is registered to
fire on the main queue.

### 4.1 Entry point (end of file, 2210-2220)
```
switch Config.parse() {
case .config(let config): builds NSApplication.shared, sets its delegate to
                           MenuBarLoadRunnerApp(config:), calls app.run()  [blocks]
case .help:                exit(0)
case nil:                  exit(1)
}
```
`Config.parse()` itself already printed usage text (via `printUsage()`) for both the `.help`
and `nil` (error) outcomes before returning, at each of its early-return sites (the `--help`
return at lines 159-161, and the `printUsage()`+`return nil` guards at lines 168-171, 174-178,
181-191, 194-198, 204-207).

---

## 5. `Tuning` — constant inventory (lines 14-88)

All values are `private` to the file, `static let`, grouped by the enum's declaration order
(not by category — the groupings below are for lookup only; the source has no section
comments dividing them). **Per-preset speed ranges and slot scales are no longer here** —
they moved to `gifs/presets.json` (decoded via `PresetManifest`, §8); `Tuning` keeps only a
single neutral `fallbackSlotScale` for the no-active-preset case.

**Frame timing**
- `defaultGifFrameDelay: TimeInterval = 0.1`
- `minGifFrameDelay: TimeInterval = 0.02`
- `gameLoopFallbackInterval: TimeInterval = 1.0 / 60.0` — tick period for the 60 Hz `Timer`
  game-loop fallback used only on macOS < 14 (CADisplayLink is the primary driver; see §13.1a)
- `maxFrameAdvanceDelta: TimeInterval = 1.0` — inter-tick gaps larger than this (display sleep,
  app occlusion, clock jump) resync instead of replaying every skipped frame (see §13.2 step 3)

**Load sampling / speed mapping**
- `cpuSmoothingAlpha: Double = 0.2`
- `loadSampleInterval: TimeInterval = 2.0`
- `speedUpdateHysteresis: Double = 0.08`
- `constrainedSpeedCeilingFraction: Double = 0.5` — midpoint cap applied to auto speed under power/thermal pressure (§12.1, §12.2)
- `cpuStateLowThreshold: Double = 0.30`
- `cpuStateMediumThreshold: Double = 0.70`
- `loadHistoryCapacity: Int = 30` — samples retained by the menu trace chart (30 × 2s ≈ 60s of history)
- `speedOverrideMin/Max: Double = 0.1 / 5.0`
- `initialSpeedMultiplier: Double = 1.0`
- `percentScale: Double = 100.0`

**Adaptive throughput scaling (`ThroughputScaler`, §7.9)**
- `scalerWindow: Int = 5`
- `scalerRescaleCount: Int = 5`
- `scalerHeadroomUp: Double = 1.3`
- `scalerHeadroomDown: Double = 3.0`
- `networkFloorBytesPerSec: Double = 1 * 1_048_576` (1 MiB/s)
- `diskFloorBytesPerSec: Double = 4 * 1_048_576` (4 MiB/s)
- `swapFloorBytesPerSec: Double = 1 * 1_048_576` (1 MiB/s)

**Rendering geometry**
- `renderVerticalInset: CGFloat = 4`
- `minIconDimension: CGFloat = 12`
- `renderHorizontalInset: CGFloat = 2`
- `minAspect: CGFloat = 0.01`
- `minBaseSlotWidth: CGFloat = 18`
- `fallbackSlotScale: CGFloat = 1.0` — neutral slot-scale / aspect fallback when there is no
  active preset (custom GIF) or a frame's real aspect is unavailable

**System/format constants**
- `loadAverageSampleCount = 3`, `loadAverage1mIndex/5mIndex/15mIndex = 0/1/2`
- `minAlphaPixelComponents = 4`
- `alphaVisibleThreshold: UInt8 = 3`
- `minWidthSlots = 1`, `maxWidthSlots = 4`

**Overlay text rendering**
- `overlayMinFontSize/MaxFontSize: CGFloat = 8 / 14`
- `overlayHorizontalInset/VerticalInset: CGFloat = 2 / 1`
- `overlayFontScale: CGFloat = 0.5`
- `overlayStrokeWidth: CGFloat = -2`
- `overlayMaxChars = 12`

---

## 6. `Config` — CLI/env interface (lines 126-256)

### 6.1 Fields (lines 136-146)
```swift
let presetOrPath: String                    // preset keyword OR GIF path; tilde-expanded, "" = none
let widthSlots: Int?                        // nil = auto; else 1...4
let speedMultiplierOverride: Double?        // nil = auto (load-driven); else fixed, > 0
let overlayText: String?                    // nil = no overlay; else 1...12 trimmed chars
let loadSource: LoadSource                  // which reader drives speed; resolved here (unknown → .cpu)
let exitAfterSeconds: TimeInterval?         // MENUBAR_LOAD_RUNNER_EXIT_AFTER test hook; nil = run until quit
```
`presetOrPath` is stored verbatim — it may be a built-in preset **keyword** (e.g.
`horse-white`) or a GIF path, or `""` when no arg/env was given. Keyword→path resolution and the
default-preset fallback are deferred to `MenuBarLoadRunnerApp.init` (§9), so `Config` carries no
preset-table knowledge (there is no longer a `Config.defaultPreset` static). `loadSource` is
resolved from `--load-source`/`MENUBAR_LOAD_RUNNER_LOAD_SOURCE` here (unknown/absent → `.cpu`, with
a stderr warning, never a launch failure — §7.10). `exitAfterSeconds` is a debug/test hook that
self-terminates the app after N seconds so a smoke test can exit 0 without an external kill.

### 6.2 `ParseResult` (lines 127-130)
```swift
enum ParseResult { case config(Config); case help }
```
`Config.parse() -> ParseResult?` — `nil` return means a parse error already reported to
stderr (usage already printed at the failing call site).

### 6.3 Argument grammar (lines 148-243)
Single forward pass over `CommandLine.arguments.dropFirst()` via a manual iterator
(`iterator.next()` consumes the flag's value token, so `--width 2` is two consumed tokens):

| Token(s) | Effect | Validation | Lines |
|---|---|---|---|
| `--help`, `-h` | prints usage, returns `.help` | none | 159-161 |
| `--width`, `-w` | sets `widthSlots` | next token must parse as `Int` in `1...4` | 162-172 |
| `--speed-multiplier` | sets `speedMultiplierOverride` | next token must parse as `Double > 0` | 173-179 |
| `--overlay-text` | sets `overlayText` | next token, trimmed, must be `1...12` chars after trim | 180-192 |
| `--load-source` | captures the raw source string (resolved below) | next token must exist (value validated later) | 193-199 |
| anything else, first occurrence | sets `presetOrPath` | — | 200-202 |
| anything else, second+ occurrence | fatal parse error ("Unexpected argument") | — | 203-207 |

**Positional resolution + default** (lines 211-216): if no positional arg was consumed, falls
back to `ProcessInfo.processInfo.environment["MENUBAR_LOAD_RUNNER_PATH"]`; if *that* is also
absent/empty, the stored value becomes the empty string `""` — the manifest's `defaultPreset` is
then resolved in `init` (§9.1), so parsing no longer fails on a missing arg (the old "Missing GIF
path" error path is gone). The resolved value is passed through
`NSString(string:).expandingTildeInPath` before being stored (a no-op for a bare keyword or `""`)
— this is the only normalization applied; no symlink resolution, no `standardizingPath`.
**Load-source resolution** (lines 218-225): falls back to `MENUBAR_LOAD_RUNNER_LOAD_SOURCE`, then
`LoadSource.from(key:) ?? .cpu`, logging a warning for an unknown non-empty value.

### 6.4 `printUsage()` (lines 245-255)
Reads `MENUBAR_LOAD_RUNNER_BIN_NAME` env var for the binary name shown in usage text,
falling back to `CommandLine.arguments[0]`'s last path component (lines 246-247). It prints
`AppInfo.version`, the two usage lines (including `--load-source` with `LoadSource.allCases`
keys), and states that per-preset speed ranges are defined in `gifs/presets.json` (line 254) —
so unlike the earlier version it no longer inlines `Tuning` speed numbers.

---

## 7. `CPULoadMonitor` — CPU sampling module (lines 321-390)

### 7.1 State (lines 323-328)
```swift
private var lastTotalTicks: UInt64?
private var lastIdleTicks: UInt64?
private var hasSmoothedUsage = false
private(set) var smoothedUsage: Double = 0
private let smoothingAlpha: Double = Tuning.cpuSmoothingAlpha   // 0.2
var hasSample: Bool { hasSmoothedUsage }
```

### 7.2 `sampleUsage() -> Double?` (lines 330-340)
Calls `currentUsage()`. First successful sample seeds `smoothedUsage` directly (no
smoothing applied to the first value, lines 332-336). Every subsequent sample applies an
exponential moving average:
```
smoothedUsage = (0.2 * usage) + (0.8 * smoothedUsage)
```
Returns `nil` if `currentUsage()` returns `nil` (i.e. no update to `smoothedUsage` happens on
a failed sample).

### 7.3 `currentUsage() -> Double?` (lines 342-389)
1. Calls `host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &cpuInfo,
   &cpuInfoCount)` (Mach API). Returns `nil` if the call doesn't return `KERN_SUCCESS` or
   `cpuInfo` is `nil` (line 354).
2. `defer`s a `vm_deallocate` of the returned `cpuInfo` buffer (lines 356-359).
3. Sums `user + system + nice + idle` ticks across all CPUs into `totalTicks`, and `idle`
   ticks into `idleTicks` (loop, lines 365-374), using `CPU_STATE_MAX` as the per-CPU stride
   and `CPU_STATE_USER`/`SYSTEM`/`NICE`/`IDLE` as offsets within each CPU's slice.
4. `defer`s storing the current `totalTicks`/`idleTicks` into `lastTotalTicks`/`lastIdleTicks`
   for the next call, unconditionally (lines 376-379) — this runs even if the function is
   about to return `nil` at lines 381-383 (first-ever call has no previous sample) or line 387
   (degenerate delta).
5. Requires a previous sample to exist (`lastTotalTicks`/`lastIdleTicks` both non-nil) to
   compute anything; otherwise returns `nil` (lines 381-383) — this is why `CPULoadMonitor`
   needs two `sampleUsage()` calls before it produces its first real value (first call stores
   ticks and returns `nil` from `currentUsage()`, but note `sampleUsage()` itself only calls
   `currentUsage()` once and returns whatever it gets — so `sampleUsage()`'s first call
   returns `nil` too, per line 331's guard).
6. Delta computation uses wrapping subtraction (`&-`, lines 385-386) and requires
   `deltaTotal > 0 && deltaIdle <= deltaTotal` (line 387) before returning
   `(deltaTotal - deltaIdle) / deltaTotal` — i.e. the fraction of ticks since the last sample
   that were *not* idle.

### 7.4 Call sites
Only called from `MenuBarLoadRunnerApp.sampleActiveSource(elapsed:)` (line 1363:
`case .cpu: return loadMonitor.sampleUsage()`), reached once per tick from `sampleSystemLoad()`
(§12) when `.cpu` is the active source, which runs on `Tuning.loadSampleInterval` (2s) via
`loadTimer`.

The remaining subsections below (7.5-7.14) cover the memory/GPU/network/disk readers, the
shared adaptive-scaling and load-source-selector machinery, and the durable design principles
those readers were built against — all of which landed after §7.1-7.4 above were written and are
documented here for the first time. Every line number below was re-verified against the current
2221-line source with `grep -n`/`Read`, independent of the "approximate, may have drifted"
caveat in the doc header that applies to the older §1-§18 numbers.

### 7.5 `MemoryLoadMonitor` — memory + swap module (lines 399-502)

A *mixed-domain* sibling of `CPULoadMonitor`: one reader exposing both an **instantaneous**
percentage and a **counter-delta** rate, composited into a single driver value.

- **State** (lines 401-418): `currentUsedFraction`/`hasSample` (instantaneous), `swapUsedBytes`/
  `swapTotalBytes`/`hasSwapSample` (instantaneous, display-only), `currentSwapRateBytesPerSec`/
  `hasSwapRateSample` (counter-delta), `currentMemoryLoad` (the composite driver value),
  `lastSwapEvents: UInt64?` (previous-tick baseline for the delta), and its own
  `swapScaler = ThroughputScaler(floor: Tuning.swapFloorBytesPerSec)` (§7.9).
- **`sampleUsage(elapsed:) -> Double?`** (lines 425-434): calls `readVMSample()`; returns `nil`
  only if that instantaneous read fails (a failed swap read degrades just the swap
  display/rate, never the fraction — see §7.12 principle 4). On success: sets
  `currentUsedFraction`/`hasSample`, calls `readSwapUsage()` (swap capacity, display-only),
  calls `updateSwapRate(swapEvents:elapsed:)`, then computes
  `currentMemoryLoad = max(sample.usedFraction, swapLoad)` where `swapLoad` is
  `swapScaler.normalize(speed: currentSwapRateBytesPerSec)` gated on `hasSwapRateSample` (else
  `0`) — the composite formula named in the class comment (lines 392-398).
- **`updateSwapRate(swapEvents:elapsed:)`** (lines 439-450): a textbook counter-delta — `defer`s
  storing `lastSwapEvents = swapEvents` unconditionally; if `elapsed` is `nil` (first tick, or a
  source-switch re-sample per §7.10) or there is no `lastSwapEvents` baseline yet, reports no
  rate (`hasSwapRateSample = false`) rather than dividing by a stale/nominal interval. Otherwise
  `currentSwapRateBytesPerSec = deltaBytes / elapsed` (real wall-clock seconds, §7.11).
- **`readVMSample()`** (lines 461-488): one `host_statistics64(HOST_VM_INFO64)` call yields both
  values used here — `used = 1 - (free + purgeable + external) * pageSize / physicalMemory` (a
  documented approximation, not Activity Monitor's exact algorithm, per the comment at lines
  452-460) and the cumulative `swapins + swapouts` page count (in bytes) returned as
  `swapEvents` — i.e. the swap-rate counter costs zero extra syscalls, it's a second field off
  the same read. Page size comes from `host_page_size`, not the mutable `vm_kernel_page_size`
  global, to stay `-strict-concurrency=complete`-clean. Returns `nil` on non-`KERN_SUCCESS` or a
  zero `physicalMemory`/page-size read.
- **`readSwapUsage()`** (lines 491-501): `sysctlbyname("vm.swapusage")`, unprivileged,
  instantaneous, no lifecycle; sets `swapUsedBytes`/`swapTotalBytes`/`hasSwapSample`, or leaves
  `hasSwapSample = false` on failure without touching the other fields.

**Memory-pressure tri-state** (a separate mechanism, owned by `MenuBarLoadRunnerApp`, not
`MemoryLoadMonitor`, but feeding the same self-throttle path as memory load):
- `memoryPressureLevel: DispatchSource.MemoryPressureEvent = .normal` (line 907) and
  `memoryPressureSource: DispatchSourceMemoryPressure?` (line 908) — cached because, unlike
  `thermalState`/`isLowPowerModeEnabled`, memory pressure has **no synchronous getter**; it is
  event-only.
- Constructed in `applicationDidFinishLaunching` (lines 1167-1180):
  `DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue:
  .main)` — the mask **must** include `.normal`, or the cached level can never fall back out of
  `.warning`/`.critical` once raised. Its event handler updates `memoryPressureLevel`, then calls
  `reevaluateSpeedForCurrentConditions()` and `refreshMenuMetrics()` immediately (bypassing the
  2s tick, same as the power/thermal observers, §12.2). `pressureSource.resume()` (line 1180)
  starts delivery — dispatch sources start suspended. It is torn down in
  `applicationWillTerminate` via `memoryPressureSource?.cancel()` (lines 1214-1215), **not**
  `NotificationCenter.removeObserver` — a distinct lifecycle from the four notification observers
  torn down just above it.
- Read by `isUnderPowerPressure` (lines 1849-1862): `true` if Low Power Mode is on, or
  `thermalState` is `.serious`/`.critical`, **or** `memoryPressureLevel.contains(.warning)` /
  `.contains(.critical)` — memory pressure is the third input into the same self-throttle
  computed property documented in §12.2, joining low-power/thermal rather than replacing them.
  `memoryPressureText()` (lines 1520-1524) renders it as `"Normal"`/`"Warning"`/`"Critical"` for
  the menu's `Memory Pressure:` state line (§7.10).

### 7.6 `GPULoadMonitor` — GPU utilization module (lines 509-570)

Unprivileged-tier, instantaneous, point-read — the simplest of the four new readers.

- `isAvailable` (lines 517-523): probes once (`readUtilization() != nil`) and caches the result
  (`availabilityChecked`/`available`) — this is the "cache expensive setup" principle (§7.12 #6)
  applied to a probe rather than a subscription, since there's nothing else here to cache.
- `sampleUsage() -> Double?` (lines 525-533): no `elapsed:` parameter — this is a pure point
  read, unlike the counter-delta readers below. Sets `hasSample = false` and returns `nil` on
  failure (never a fabricated `0`).
- `readUtilization()` (lines 538-543) tries `IOServiceMatching("IOAccelerator")` first, then
  falls back to `"AGXAccelerator"` (the Apple Silicon-specific IOClass) since the accelerator's
  concrete class is hardware-specific. `readUtilization(matching:)` (lines 545-569) iterates every
  matched `io_service_t`, reads its `"PerformanceStatistics"` registry property, and takes the
  max `"Device Utilization %"` (0…100) across matches, scaled by `Tuning.percentScale` (÷100) and
  clamped to `0...1`. Because the value is natively bounded 0…1 after that division, it is
  **not** run through `ThroughputScaler` (§7.9) — bounded percentage signals map straight
  through, per §7.12 principle 3. GPU *power/energy* is a different, unimplemented tier — see
  §7.14.

### 7.7 `NetworkLoadMonitor` — network throughput module (lines 576-626)

- `isAvailable` (line 586): hardcoded `true` — `getifaddrs` is always present on macOS, unlike
  the IORegistry-probed GPU/disk sources.
- `sampleUsage(elapsed:) -> Double?` (lines 588-606): counter-delta over cumulative interface
  byte counters. `defer`s storing `lastBytes = total` unconditionally (mirroring
  `MemoryLoadMonitor.updateSwapRate`'s pattern); if `elapsed` is `nil` or there's no `lastBytes`
  baseline, reports no sample (first tick / source-switch re-sample warm-up, §7.10/§7.11).
  Otherwise `currentThroughputBytesPerSec = deltaBytes / elapsed`, then normalizes through its
  own `scaler = ThroughputScaler(floor: Tuning.networkFloorBytesPerSec)` (§7.9) into `currentLoad`
  — the value actually returned and used to drive speed.
- `readTotalBytes()` (lines 608-625): `getifaddrs` → walks the linked list, keeping only entries
  where `ifa_addr.sa_family == AF_LINK` (only those carry a populated `if_data`) and skipping
  `"lo0"` (loopback) so local traffic doesn't inflate the reading; sums `ifi_ibytes + ifi_obytes`
  across the remaining interfaces.

### 7.8 `DiskLoadMonitor` — disk I/O throughput module (lines 631-694)

Structurally a twin of `NetworkLoadMonitor` (§7.7) over a different IORegistry class.

- `isAvailable` (lines 641-647): probed once and cached (`readTotalBytes() != nil`), like
  `GPULoadMonitor.isAvailable` — a machine with no readable `IOBlockStorageDriver` disables the
  source.
- `sampleUsage(elapsed:) -> Double?` (lines 649-665): same counter-delta shape as
  `NetworkLoadMonitor.sampleUsage(elapsed:)` — `defer`-stores `lastBytes`, requires `elapsed` and
  a prior baseline, divides the byte delta by `elapsed`, normalizes through
  `scaler = ThroughputScaler(floor: Tuning.diskFloorBytesPerSec)` into `currentLoad`.
- `readTotalBytes()` (lines 667-693): `IOServiceMatching("IOBlockStorageDriver")` → for every
  matched entry, reads its `"Statistics"` registry dictionary's `"Bytes (Read)"` and
  `"Bytes (Write)"` keys (defaulting a missing key to `0`, not failing the whole read) and sums
  across all drivers found; returns `nil` (via `found` staying `false`) only if zero drivers
  matched at all.

### 7.9 `ThroughputScaler` — shared adaptive-scaling value type (lines 266-319)

A `private struct` (a pure value type, not `@MainActor` — it has no shared mutable global state,
just per-owner instance state), ported from btop's `Net::collect` auto-scale (`Tuning` comment,
lines 47-53). Three unbounded rate signals share this same normalization: `MemoryLoadMonitor`'s
swap rate (§7.5), `NetworkLoadMonitor`'s throughput (§7.7), and `DiskLoadMonitor`'s throughput
(§7.8) — each owns its own scaler instance seeded with a different `floor` (`Tuning.
swapFloorBytesPerSec`/`networkFloorBytesPerSec`/`diskFloorBytesPerSec`, 1/1/4 MiB/s, lines 60-62).

- **State** (lines 267-272): `floor` (fixed at init), `ceiling` (the adaptive normalization
  denominator, seeded to `floor`), `seeded`, a `recent: [Double]` ring of the last
  `Tuning.scalerWindow` (5) samples, and `overCount`/`underCount` hysteresis counters.
- **`normalize(speed:) -> Double`** (lines 280-313):
  1. First call only: seeds `ceiling = max(speed * Tuning.scalerHeadroomUp, floor)` so the very
     first sample doesn't peg at `1.0` against a bare `floor` (comment, lines 281-282).
  2. Appends `speed` to `recent`, trimming to `Tuning.scalerWindow` (5) entries.
  3. Hysteresis: increments `overCount` (and decays `underCount`) when `speed > ceiling`;
     increments `underCount` (and decays `overCount`) when `speed < ceiling / 10` — a single
     spike or dip can't move the scale; only `Tuning.scalerRescaleCount` (5) *consecutive*
     out-of-band samples on one side triggers a rescale.
  4. On an over-rescale: `ceiling = max(average(recent) * Tuning.scalerHeadroomUp, floor)`
     (headroom `1.3`×, tight — scaling up commits fast). On an under-rescale:
     `ceiling = max(average(recent) * Tuning.scalerHeadroomDown, floor)` (headroom `3.0`×, loose
     — scaling back down is deliberately slow so it doesn't immediately re-trigger an
     over-rescale). Both branches reset both counters.
  5. Returns `min(speed / ceiling, 1)`.
- **Never applied to a bounded signal.** CPU%, memory-used%, and GPU% map straight through
  (§7.5, §7.6) — running a bounded 0…1 signal through an adaptive ceiling would let its
  historical average distort its absolute meaning (e.g. "50% CPU" would stop meaning the same
  thing over time), which is exactly what this type exists to avoid for *unbounded* signals. See
  §7.12 principle 3.

### 7.10 `LoadSource` — selector registry and speed-path wiring

The mechanism that decides *which* reader drives the animation, orthogonal to which preset (i.e.
which `SpeedProfile`, §16) is active: selecting a source changes which 0…1 value is mapped
through the active preset's min/max/exponent, never the range itself. There is no per-source
`SpeedProfile`.

- **`LoadSource` enum** (lines 93-124): `Int, CaseIterable`, cases `.cpu`/`.memory`/`.gpu`/
  `.network`/`.disk` (raw values `0...4`, doubling as menu-item `tag`s), each with a `key`
  (CLI/env string) and `menuTitle`. `LoadSource.from(key:)` (lines 120-123) is a
  case-insensitive lookup used by both the CLI parser and the env fallback. A single registry —
  same pattern as `PresetDescriptor` (§8.1) — so the CLI keyword, env var, menu item, and
  selection-state check all derive from one source of truth.
- **CLI/env wiring in `Config`**: `let loadSource: LoadSource` field (line 142); `--load-source`
  parsed at lines 193-199 (stores the raw string, deferring resolution); falls back to
  `MENUBAR_LOAD_RUNNER_LOAD_SOURCE` (line 219) when no flag was given; resolves via
  `LoadSource.from(key:) ?? .cpu` (line 222) — unknown/absent values fall back to `.cpu` with a
  logged warning (lines 223-225), never a launch failure (§7.12 principle 2/4). `printUsage()`
  documents the flag and lists all known keys (lines 249-251).
- **`activeLoadSource: LoadSource`** (line 903, mutable): initialized from `config.loadSource`
  in `init` (line 923); mutated only by `selectLoadSource(_:)` (below).
- **The three speed-path helpers — the only read sites for "what drives the animation"**:
  - `sampleActiveSource(elapsed:) -> Double?` (lines 1361-1369): a `switch` dispatching to
    exactly one reader's `sampleUsage()`/`sampleUsage(elapsed:)`, called once per tick from
    `sampleSystemLoad()` (line 1344) — this is what makes sampling **active-only**: the four
    inactive monitors are never polled while another source drives.
  - `activeSourceHasSample: Bool` (lines 1380-1388): mirrors the switch, reading each monitor's
    `hasSample`.
  - `activeSourceCurrentUsage: Double` (lines 1393-1401): mirrors the switch again, reading each
    monitor's last driving value without re-sampling (`loadMonitor.smoothedUsage`,
    `memoryMonitor.currentMemoryLoad`, `gpuMonitor.currentUtilization`,
    `networkMonitor.currentLoad`, `diskMonitor.currentLoad`) — used by
    `reevaluateSpeedForCurrentConditions()` (§12.2) to recompute speed immediately without
    waiting for the next tick's sample.
- **Source-conditional `refreshMenuMetrics()`** (lines 1411-1518, superseding the single-source
  description in §10.3): a `switch activeLoadSource` with one case per source, each setting
  `usageItem.title`/`stateItem.title`/the accessibility label from *only* that source's monitor
  (e.g. `.memory` shows `"Memory Pressure: ..."` from `memoryPressureText()` plus
  `memoryUsageLineText()`/swap rate, lines 1437-1451; `.network`/`.disk` show a human MB/s figure
  via `networkUsageLineText()`/`diskUsageLineText()`, lines 1549-1555, rather than the
  scaler-normalized 0…1 value that actually drives speed). The inactive sources' lines are never
  shown, matching active-only sampling. `speedMultiplierItem.title` additionally names
  `activeLoadSource.menuTitle` (lines 1496-1511) so the dashboard always states *what* is
  driving the animation.
- **`Load Source` radio submenu**: built in `applicationDidFinishLaunching` (lines 1033-1043) — one
  `NSMenuItem` per `LoadSource.allCases`, `tag = source.rawValue`, action
  `selectLoadSource(_:)`, appended to `loadSourceMenuItems`. Selection state is refreshed by
  `refreshLoadSourceSelectionState()` (lines 1568-1575): `.state = .on` iff
  `item.tag == activeLoadSource.rawValue`; `.isEnabled = isSourceAvailable(source)` — the same
  radio-group + enablement shape as the width/preset menus (§10.4/§10.5).
- **`selectLoadSource(_:)`** (lines 1641-1661, `@objc`): no-ops if the tapped source is already
  active; otherwise sets `activeLoadSource`, clears the trace-chart history buffer (a mixed-source
  history would be meaningless), immediately calls `sampleActiveSource(elapsed: nil)` to seed the
  new monitor (an on-demand resample has no meaningful interval, so counter-delta readers just
  store a baseline here) and records that seed if usable, resets `lastSampleUptime = nil` (§7.11)
  so the next tick doesn't divide by a stale gap, calls `reevaluateSpeedForCurrentConditions()` to
  re-derive speed immediately (bypassing the 2s hysteresis, mirroring preset switches), then
  refreshes both the load-source selection state and the menu metrics.
- **`isSourceAvailable(_:)`** (lines 1582-1592): `.cpu`/`.memory` are always `true` (core
  Mach/sysctl, never absent); `.gpu`/`.network`/`.disk` defer to each monitor's own `isAvailable`
  probe. Also checks a debug-only `forcedUnavailableSources` env override
  (`MENUBAR_LOAD_RUNNER_FORCE_UNAVAILABLE`, lines 1594-1600) so QA can exercise the
  disabled-menu-item and fallback path on hardware where every reader actually works.
  **Launch-time fallback** (lines 1045-1051, right after the submenu is built): if the
  configured `activeLoadSource` isn't available, logs a warning to stderr and forces `.cpu` —
  the one enforcement point where an unavailable *requested* source is corrected, versus the
  per-tick case where a reader going dark just yields `nil` for that tick and the animation holds
  its last speed (§7.12 principle 4).

### 7.11 Shared elapsed-time plumbing — `lastSampleUptime` / `elapsed:`

The mechanism that makes every counter-delta *rate* reader (as opposed to CPU's counter-delta
*ratio*, which needs no wall-clock division at all — see the distinction below) divide by real
time rather than the nominal 2s tick interval.

- `lastSampleUptime: Double?` (lines 894-897, comment explicitly calls out
  `ProcessInfo.systemUptime` over `Date` for immunity to wall-clock changes).
- Captured once per tick in `sampleSystemLoad()` (lines 1338-1340): `now =
  ProcessInfo.processInfo.systemUptime`; `elapsed = lastSampleUptime.map { now - $0 }` (`nil` on
  the very first tick); `lastSampleUptime = now`. This single `elapsed` value is threaded into
  `sampleActiveSource(elapsed:)` (line 1344, §7.10), which forwards it to whichever reader's
  `sampleUsage(elapsed:)` needs it that tick.
- **Consumers**: `MemoryLoadMonitor.updateSwapRate` (§7.5), `NetworkLoadMonitor.sampleUsage`
  (§7.7), `DiskLoadMonitor.sampleUsage` (§7.8) — each divides its byte delta by `elapsed`
  directly, and each treats `elapsed == nil` (or `<= 0`) the same way: store the new baseline,
  report no rate this tick.
- **Not a consumer: `CPULoadMonitor.sampleUsage()`** (§7.2) takes no `elapsed:` parameter at all
  — its delta is `(deltaTotal - deltaIdle) / deltaTotal`, a ratio of *tick counts* over the same
  window, not a bytes-per-second rate, so there is nothing to normalize against wall-clock time.
  This is the "instantaneous vs. counter-delta, bounded vs. unbounded" distinction (§7.12
  principle 3) in concrete form: CPU is counter-delta but bounded (a ratio); memory swap/network/
  disk are counter-delta *and* unbounded (a rate), which is what actually requires `elapsed:`.
- **Reset on source switch**: `selectLoadSource(_:)` (§7.10, line 1657) sets
  `lastSampleUptime = nil` so the newly-active reader's first real sample after a switch is
  correctly treated as a warm-up tick (`elapsed = nil`) instead of dividing by however long the
  *previous* source had been active.

### 7.12 Design principles for OS readers

Six principles distilled from cross-reviewing this repo's readers against a sibling
sudoless-monitor project; they bind every reader above (§7.5-§7.11) *and* the pre-existing
`CPULoadMonitor` (§7.1-§7.4) equally — they are forward-looking guidance for reader #N, not
retroactive fixes.

1. **Unprivileged sibling API only.** Every implemented reader is a plain Mach
   (`host_processor_info`, `host_statistics64`) / sysctl (`sysctlbyname("vm.swapusage")`) /
   IORegistry (`IOServiceMatching`, `getifaddrs`) read — no `sudo`, no shelling to
   `powermetrics`. The one deferred tier (§7.14) is deferred precisely because it needs a
   private, unheadered API and would break this rule.
2. **`nil`, never a fabricated `0`.** Every `sampleUsage()`/`sampleUsage(elapsed:)` above returns
   `Double?`; a non-`KERN_SUCCESS` result, a missing registry key, or no prior baseline yet all
   return `nil`, and the menu shows "warming up…"/the item disables — "0%" is reserved for an
   actually-idle reading.
3. **Instantaneous vs. counter-delta, and bounded vs. unbounded, are orthogonal axes.**
   Instantaneous = a point read valid on the first tick (memory used-fraction, swap capacity,
   GPU utilization). Counter-delta = needs two samples (CPU ticks; memory swap events; network/
   disk bytes). Separately: bounded 0…1 signals (CPU%, memory-used%, GPU%) map straight through;
   unbounded rate signals (network/disk/swap bytes-per-sec) have no natural ceiling and go
   through `ThroughputScaler` (§7.9). Never adaptive-scale a bounded signal.
4. **Asymmetric error handling.** One reader going dark degrades only its own menu line
   (`hasSample = false` for that tick) and, if it's the *requested* source at launch, falls back
   to `.cpu` (§7.10) — it never takes down the animation or the app. No reader here is
   fatal-at-startup.
5. **No EMA in a reader unless it's a deliberate, documented choice.** `CPULoadMonitor` is the
   one exception (`Tuning.cpuSmoothingAlpha`, §7.2) and says so in its own comment; every other
   reader above reports the raw instantaneous/counter-delta value with no smoothing.
   `ThroughputScaler`'s window-averaging is a *scaling* choice on an already-unbounded rate, not
   an EMA on the reported value.
6. **Cache expensive setup once.** Only relevant to the private-API tier today (§7.14) — a
   subscription/connection would need to be created once and torn down explicitly. Every
   Mach/sysctl/IORegistry reader above has nothing expensive to cache except an availability
   probe, which `GPULoadMonitor`/`DiskLoadMonitor` already memoize (`isAvailable`, §7.6/§7.8).

### 7.13 Checklist: adding a new load source

Adding reader #6 (or beyond) is a fixed checklist against real call sites, not a design
exercise — the selector plumbing (§7.10) already exists:

1. **`LoadSource`** — add a `case` with its `key`/`menuTitle` (lines 93-124). CLI, env, menu
   item, and `@objc selectLoadSource`/`refreshLoadSourceSelectionState` pick it up automatically.
2. **Reader** — a `sampleUsage()`/`sampleUsage(elapsed:) -> Double?` returning a normalized
   0…1 value (`nil` = unavailable/warming up), on a peer `@MainActor` monitor class (§7.5-§7.8).
3. **Wire into the three helpers** — add a branch each to `sampleActiveSource(elapsed:)`,
   `activeSourceHasSample`, `activeSourceCurrentUsage` (lines 1361-1401, §7.10). These are the
   *only* speed-path read sites.
4. **Menu line** — add a source-conditional branch to `refreshMenuMetrics()` (lines 1411-1518).
5. **Availability** — expose `isAvailable` on the reader (probed once and cached, like
   `GPULoadMonitor`/`DiskLoadMonitor`) and add a case to `isSourceAvailable(_:)`
   (lines 1582-1592); the disabled-menu-item and launch-fallback behavior follow automatically.
6. **`elapsed:` threading** — if the reader is a counter-delta *rate* (not CPU's tick-ratio
   shape, §7.11), accept `elapsed: Double?` and divide the byte/event delta by it, never by the
   nominal `Tuning.loadSampleInterval`.
7. **Docs** — `--help` (`Config.printUsage()`), the README load-source list, and a
   `RUNBOOK-qa-release.md` launch row + reader check.

### 7.14 Deferred: GPU power/ANE and die-temp/fan sensors (not implemented)

**Not present in the source at all** — flagged here so it isn't mistaken for an oversight in
§7.6's GPU coverage. GPU power/ANE/package power would need the private, unheadered
`libIOReport.dylib` (`IOReportCopyChannelsInGroup` → `IOReportCreateSubscription` →
`IOReportCreateSamples`); die temperature and fan speed would need SMC access via
`IOServiceOpen`/`IOConnectCallStructMethod` with sensor keys discovered ad hoc. Both break
§7.12 principle 1 (unprivileged sibling API only) — the private-API tier is the sole reason this
is deferred, not any technical blocker in the existing readers. It would also be the first
reader here to need principle 6's cache-once/explicit-teardown lifecycle for real (a
subscription/connection, not just a probe) and a decision on fatal-at-startup vs.
degrade-one-feature if that subscription can't be created. No timeline; own design pass if ever
picked up.

---

## 8. `MenuBarLoadRunnerApp` — state inventory (~lines 794-917)

All properties are `private` unless noted; all are on the single `MenuBarLoadRunnerApp`
instance created once at the bottom of the file. The `PresetKind` enum was removed when preset
profiles were externalized to `gifs/presets.json` — preset identity is now data, decoded via the
`PresetManifest` Codable structs, not a hardcoded enum.

**Nested types**
```swift
private struct SpeedProfile { let label: String; let min, max, responseExponent: Double }  // lines 796-801
private struct PresetDescriptor {                                                          // lines 803-809
    let key: String            // preset keyword, e.g. "dog-white" — matches gifs/presets.json
    let menuTitle: String
    let path: String           // absolute path, resolved once in init() from scriptDirURL + gifs/<file>
    let slotScale: CGFloat
    let speedProfile: SpeedProfile
}
private struct PresetManifest: Decodable {          // lines 814-832 — Codable mirror of gifs/presets.json
    let defaultPreset: String
    let presets: [Entry]                            // Entry: {key, menuTitle, file, slotScale, speed}
    // struct Speed: {label, min, max, responseExponent}
}
private static let customSpeedProfile = SpeedProfile(   // lines 837-842 — literal, self-contained
    label: "custom", min: 0.5, max: 2.5, responseExponent: 1.0
)   // last-resort profile only when there is neither an active preset nor a manifest default to borrow
```

**Immutable, set in `init` (lines 844-851, populated by `init` lines 919-986)**
```swift
let config: Config
let allPresets: [PresetDescriptor]   // the 12 built-in presets, decoded from gifs/presets.json (see §8.1)
let defaultDescriptor: PresetDescriptor?  // the manifest's declared default (horse-white); profile fallback for a custom GIF
let startupError: String?            // set if presets.json couldn't be loaded/decoded → applicationDidFinishLaunching shows it and quits
```
Each preset's `path` is `scriptDirURL + "gifs/<file>"`, where `scriptDirURL` is chosen (init lines
934-940) as the first of `[Bundle.main.executableURL?.deletingLastPathComponent(), #filePath's
directory]` that actually contains `gifs/presets.json` — the running executable's directory is
preferred so a login-item launch with `CWD=/` still resolves resources (the `#filePath` directory
is the interpreted-`swift <file>` dev fallback). `allPresets` is decoded from the manifest and is
the **sole** owner of the key→path mapping: the launcher no longer keeps a parallel `gifs_dir` path
table (deleted with anti-pattern #6), so the former cross-language duplication is gone.

**Mutable, mutated over the app's lifetime** (lines 852-917)
```swift
var activePreset: PresetDescriptor?               // init: keyword match (allPresets.first { $0.key == requested }) else path match; changed by switchToGif(to:descriptor:)
var activeGifPath: String                         // init: matched preset's path, else the requested path verbatim; changed by switchToGif(to:descriptor:)
var statusItem: NSStatusItem!                     // set once, applicationDidFinishLaunching
var infoMenu: NSMenu!                             // set once
var historyMenuItem: NSMenuItem!                  // disabled item hosting the trace chart view (set once)
var loadHistoryView: LoadHistoryView!             // the trace-chart NSView (set once)
var loadHistory: [Double] = []                    // ring buffer of the active source's recent 0…1 fractions (cap Tuning.loadHistoryCapacity); cleared on source switch
var usageItem, loadAverageItem, stateItem,
    speedMultiplierItem, loadSourceMenuItem,
    widthStatusItem, widthMenuItem,
    widthAutoItem: NSMenuItem!                     // set once; .title/.state mutated by refresh*() methods (usageItem/stateItem are source-conditional, §7.10)
var loadSourceMenuItems: [NSMenuItem] = []        // populated once, one per LoadSource.allCases (tag == rawValue)
var widthSlotItems: [NSMenuItem] = []             // populated once (4 items, tags 1...4)
var overlayStatusItem, overlayMenuItem,
    overlaySetItem, overlayClearItem: NSMenuItem! // set once; mutated by refreshOverlaySelectionState()
var presetMenuItems: [NSMenuItem] = []            // populated once, one per allPresets entry (same order, index == tag); .state/.isEnabled mutated
var frames: [NSImage] = []                        // raw decoded GIF frames; replaced by loadFrames(from:)
var frameAspects: [CGFloat] = []                  // per-frame width/height ratio; replaced by loadFrames(from:)
var baseDurations: [TimeInterval] = []            // per-frame GIF delay (unscaled by speed); replaced by loadFrames(from:)
var frameIndex = 0                                // current playback position into frames/renderedFrames
var displayLink: CADisplayLink?                   // vsync-aligned game loop driver (macOS 14+, via NSView.displayLink on the status button)
var fallbackTimer: Timer?                          // 60Hz Timer game loop driver, used only on macOS < 14
var lastTickTime: TimeInterval = 0                // clock at last advanceFrames tick (link.timestamp, or systemUptime on fallback); 0 = resync sentinel
var accumulatedFrameTime: TimeInterval = 0        // carry-over time not yet consumed by a frame advance
var renderedFrames: [NSImage] = []                // frames pre-composited to current size + overlay; replaced by updateRenderedFrames()
var loadTimer: Timer?                             // 2s load-sampling driver
var lastSampleUptime: Double?                     // systemUptime at previous tick, for counter-delta rate sources (§7.11)
var loadMonitor = CPULoadMonitor()                // owns EMA CPU state
var memoryMonitor = MemoryLoadMonitor()           // memory + swap (§7.5)
var gpuMonitor = GPULoadMonitor()                 // GPU utilization (§7.6)
var networkMonitor = NetworkLoadMonitor()         // network throughput (§7.7)
var diskMonitor = DiskLoadMonitor()               // disk I/O throughput (§7.8)
var activeLoadSource: LoadSource                  // which reader drives speed; init from config.loadSource (§7.10)
var memoryPressureLevel: DispatchSource.MemoryPressureEvent = .normal  // cached; event-only, no synchronous getter (§7.5)
var memoryPressureSource: DispatchSourceMemoryPressure?  // dispatch source; cancel() on terminate, not removeObserver
var speedMultiplier: Double = Tuning.initialSpeedMultiplier  // current playback speed factor
var requestedWidthSlots: Int?                     // nil = auto; else 1...4, set via CLI or menu
var requestedOverlayText: String?                 // nil = no overlay; set via CLI or menu prompt
var requestedOverlayBold = true                   // overlay font weight toggle
var cachedLoadAverages: (Double, Double, Double)? // last getloadavg() result; nil until first sample
var screenObserver: NSObjectProtocol?              // NotificationCenter token for screen-parameter changes
var powerStateObserver: NSObjectProtocol?          // .NSProcessInfoPowerStateDidChange (Low Power Mode); see §12.2
var thermalStateObserver: NSObjectProtocol?        // ProcessInfo.thermalStateDidChangeNotification; see §12.2
var occlusionObserver: NSObjectProtocol?           // NSWindow.didChangeOcclusionStateNotification on the status button's window; see §13.6
```

**IUO lifecycle invariant.** The `statusItem`/`infoMenu` and all the `NSMenuItem!` properties above
are implicitly-unwrapped optionals assigned exactly once inside `applicationDidFinishLaunching`
(`init` never touches them) and read only afterwards (menu-delegate callbacks, `refresh*()` methods,
`@objc` actions). The `!` encodes this single-init lifecycle: guaranteed non-nil for the app's
lifetime, never accessed before launch. A source comment above the property block records the same
invariant.

### 8.1 Preset registry — `allPresets` (decoded from `gifs/presets.json` in `init`, lines 948-968)

Single source of truth for every built-in preset. As of the manifest refactor these profiles are
**data** (`gifs/presets.json`), decoded into `PresetDescriptor`s at startup — the Swift code holds
no hardcoded preset list. Order = manifest order = menu order = array index = `NSMenuItem.tag`:

| # | `key` | `menuTitle` | `slotScale` | speed profile (label, min, max, exponent) |
|---|---|---|---|---|
| 0 | `dog-white` | Dog (White) | 1.0 | dog, 0.5, 2.5, 1.0 |
| 1 | `dog-black` | Dog (Black) | 1.0 | dog, 0.5, 2.5, 1.0 |
| 2 | `horse-black` | Horse (Black) | 1.2 | horse, 0.45, 2.3, 1.0 |
| 3 | `horse-white` | Horse (White) | 1.2 | horse, 0.45, 2.3, 1.0 |
| 4 | `chihiro` | Chihiro (Walking) | 1.0 | chihiro, 0.5, 2.5, 1.0 |
| 5 | `chihiro-white` | Chihiro (Walking, White) | 1.0 | chihiro, 0.5, 2.5, 1.0 |
| 6 | `chihiro-black` | Chihiro (Walking, Black) | 1.0 | chihiro, 0.5, 2.5, 1.0 |
| 7 | `totoro` | Totoro | 1.25 | totoro, 0.5, 2.6, 1.0 |
| 8 | `totoro-group-white` | Totoro (Group, White) | 4.0 | totoro-group, 0.2, 2.0, 1.0 |
| 9 | `totoro-group-black` | Totoro (Group, Black) | 4.0 | totoro-group, 0.2, 2.0, 1.0 |
| 10 | `totoro-white` | Totoro (White) | 1.25 | totoro, 0.5, 2.6, 1.0 |
| 11 | `totoro-black` | Totoro (Black) | 1.25 | totoro, 0.5, 2.6, 1.0 |

The manifest's `defaultPreset` is `horse-white`. A custom/user-supplied GIF whose path matches
none of these leaves `activePreset == nil`; every accessor (§15, §16) then borrows
`defaultDescriptor`'s `slotScale`/`speedProfile` (or `Self.customSpeedProfile`/
`Tuning.fallbackSlotScale` if the manifest itself failed to load). `PresetDescriptor.key` is the
CLI-facing preset keyword as well as an internal identifier: `init` matches the requested arg
against `key` first (§9.1), and the same `key` drives `refreshPresetSelectionState`'s equality
check and `makeMenuAlertIcon`'s lookup. The launcher no longer resolves keywords (anti-pattern #6)
— it forwards the keyword and `allPresets` is the single place it becomes a path (§18).

---

## 9. `MenuBarLoadRunnerApp` — lifecycle sequence

### 9.1 `init(config:)` (lines 919-986)
Stores `config`, `requestedWidthSlots = config.widthSlots`, `requestedOverlayText =
config.overlayText`, `activeLoadSource = config.loadSource` (lines 920-923). Resolves the resource
base directory `scriptDirURL` (lines 934-940, preferring the running executable's directory over
`#filePath`'s), then loads and JSON-decodes `gifs/presets.json` into `PresetManifest` and maps its
entries into `allPresets` (`PresetDescriptor`s, lines 948-968); on any failure it leaves the
registry empty and records `startupError` (line 967). Sets `defaultDescriptor` (the entry whose
`key == manifest.defaultPreset`) and `startupError` (lines 970-972). Then resolves the requested
arg (lines 976-985) — **this is the single place a preset keyword becomes a path**, having moved
here from the launcher (anti-pattern #6):
- `requested = config.presetOrPath.isEmpty ? (manifestDefaultKey ?? "") : config.presetOrPath` —
  an empty arg falls back to the manifest's default preset.
- If `requested` matches a preset's `key` (`presets.first { $0.key == requested }`) →
  `activeGifPath = matched.path`, `activePreset = matched`.
- Otherwise treat it as a GIF path: `activeGifPath = requested`, and still
  `activePreset = presets.first { $0.path == requested }` so a raw path pointing
  at a built-in GIF adopts that preset's profile; `activePreset` is `nil` for a genuine custom
  GIF.

No AppKit objects are touched here.

### 9.2 `applicationDidFinishLaunching(_:)` (lines 988-1203) — exact order of operations
1. `NSApp.setActivationPolicy(.accessory)` (line 989) — no Dock icon, no app switcher entry.
2. If `startupError` is set (manifest load failure, §9.1), `showStartupErrorAndQuit(startupError)`
   and `return` (lines 991-994).
3. Create `statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)`;
   if `.button` is `nil`, call `showStartupErrorAndQuit("Unable to create NSStatusItem button.")`
   and `return` (lines 996-1000) — a graceful quit consistent with the GIF-decode-failure path
   (step 11), **not** a `fatalError`/crash.
4. `button.imagePosition = .imageOnly` (line 1002); `button.imageScaling` is **not** set here —
   it is set by `applySizing()` (step 12; §13.4); `button.toolTip = activeGifPath` (line 1004);
   `button.setAccessibilityLabel("MenuBar Load Runner")` (line 1006) — a static VoiceOver base
   label, later enriched with live load by `refreshMenuMetrics()` (§10.3).
5. Build `infoMenu` (`NSMenu`), set `self` as its delegate (lines 1008-1009).
6. Append, in this exact order, to `infoMenu` (lines 1011-1109):
   `Load History` (disabled item hosting `loadHistoryView`, the trace chart — lines 1011-1015) →
   `CPU Usage: --` (`usageItem`) → `Load Avg (1/5/15m): -- / -- / --` → `CPU State: --`
   (`stateItem`) → `Speed Multiplier: --` → `Load Source` (submenu: one item per
   `LoadSource.allCases`, `tag = rawValue`, appended to `loadSourceMenuItems` — lines 1033-1043) →
   `Width: --` → `Width Options` (submenu: `Auto (preset)`, separator, `1 slot`..`4 slots`) →
   `Overlay Text: --` → `Overlay Text` (submenu: `Set Text... (max 12)`, `Clear`) → separator →
   disabled `Presets` header → one menu item per `allPresets` entry, built by a
   `for (index, preset) in allPresets.enumerated()` loop (lines 1099-1105) that sets
   `item.tag = index` and appends each item to `presetMenuItems` (so the 12 preset titles are
   generated from the registry) → separator → `About` → `Exit` (key equivalent `q`).
7. **Load-source availability fallback** (lines 1045-1051, right after the Load Source submenu is
   built): if the configured `activeLoadSource` isn't available on this hardware, log a warning and
   force `activeLoadSource = .cpu` (§7.10).
8. `infoMenu.items.forEach { $0.target = self }` (line 1110) — a blanket target overwrite applied
   after the individual `.target = self` assignments earlier in the block.
9. `presetsHeaderItem.isEnabled = false` (line 1111) — disables the section header via the
   local variable captured when it was created (line 1096), not a title-string lookup.
   `statusItem.menu = infoMenu` (line 1112).
10. `refreshPresetSelectionState()`, `refreshWidthSelectionState()`,
    `refreshOverlaySelectionState()`, `refreshLoadSourceSelectionState()` (lines 1113-1116) —
    populate initial `.state`/`.title` text before first display.
11. `loadFrames(from: activeGifPath)` — if it returns `false`, call
    `showStartupErrorAndQuit(...)` and `return` immediately (lines 1118-1121).
12. `applySizing()` then `renderCurrentFrame()` (lines 1123-1124).
13. If `config.speedMultiplierOverride` is set, clamp it into
    `Tuning.speedOverrideMin...Max` and assign to `speedMultiplier` (lines 1125-1127).
14. `startLoadMonitoring()`, `startGameLoop()`, `refreshMenuMetrics()` (lines 1128-1130).
15. Register four `NotificationCenter` observers, all on `queue: .main` (each callback wraps its
    body in `MainActor.assumeIsolated`, §4):
    - `screenObserver` (lines 1132-1143) — `NSApplication.didChangeScreenParametersNotification` →
      `applySizing()` + `renderCurrentFrame()`.
    - `powerStateObserver` (lines 1147-1153) — `.NSProcessInfoPowerStateDidChange` (Low Power Mode
      toggled) → `reevaluateSpeedForCurrentConditions()` (§12.2).
    - `thermalStateObserver` (lines 1154-1160) — `ProcessInfo.thermalStateDidChangeNotification` →
      `reevaluateSpeedForCurrentConditions()` (§12.2).
    - `occlusionObserver` (lines 1185-1193) — `NSWindow.didChangeOcclusionStateNotification` on the
      status button's window (registered only if that window exists) →
      `updateAnimationForOcclusion()` (§13.6).
16. Construct and `resume()` the memory-pressure `DispatchSource` (lines 1167-1180, §7.5) — a
    sibling lifecycle to the notification observers.
17. If `config.exitAfterSeconds` is set, schedule an `asyncAfter` `NSApp.terminate` (lines
    1197-1202) — the `MENUBAR_LOAD_RUNNER_EXIT_AFTER` smoke-test hook.

### 9.3 `applicationWillTerminate(_:)` (lines 1205-1216)
Calls `stopGameLoop()` (tears down whichever of `displayLink`/`fallbackTimer` is live) and
invalidates `loadTimer`; removes every registered notification observer
(`screenObserver`/`powerStateObserver`/`thermalStateObserver`/`occlusionObserver`) from
`NotificationCenter.default`, then `memoryPressureSource?.cancel()` (its own dispatch-source
lifecycle, not `removeObserver`).

---

## 10. Menu system — structure and refresh model

### 10.1 Static structure
Built once in step 9.2.5 above; never rebuilt. Every visible menu title after that point is
mutated in place by four `refresh*` methods (never by rebuilding items).

### 10.2 `menuWillOpen(_:)` (lines 1403-1409, `NSMenuDelegate`)
Fired by AppKit immediately before the menu is displayed. Calls, in order:
`refreshMenuMetrics()`, `refreshPresetSelectionState()`, `refreshWidthSelectionState()`,
`refreshOverlaySelectionState()`, `refreshLoadSourceSelectionState()`. This is the *only* trigger
for those `refresh*SelectionState` methods other than the direct calls made inline by the action
methods that change the underlying state (e.g. `selectWidthAuto()` calls
`refreshWidthSelectionState()` itself, line 1668).

### 10.3 `refreshMenuMetrics()` (lines 1411-1518)
As of the load-source work this method is **source-conditional** — a `switch activeLoadSource`
sets `usageItem`/`stateItem`/the accessibility label from *only* the active source's monitor;
the fuller description lives in §7.10. In summary:
- Pushes the active source's recent 0…1 fractions into `loadHistoryView` (label, warming-up flag,
  samples) so the trace chart refreshes here (lines 1415-1417).
- `usageItem.title` / `stateItem.title`: per-source metric + state (e.g. CPU% + CPU State from
  `loadMonitor.smoothedUsage` via `cpuStateText(for:)`; Memory% + `Memory Pressure` from
  `memoryPressureText()`; etc.), or `"warming up..."` until the active source has a sample.
- `speedMultiplierItem.title` (lines 1496-1511): auto mode shows the active source's `menuTitle`,
  `currentSpeedProfile()`'s label and min/max, and a `" [throttled: low power/thermal]"` suffix
  when `isUnderPowerPressure`; fixed mode shows `(fixed)`.
- `loadAverageItem.title`: `"unavailable"` if `cachedLoadAverages == nil`, else the 3 values
  formatted `%.2f`.
- `statusItem.button?.setAccessibilityLabel(...)`: enriches the static launch-time label with live
  per-source state. Because `refreshMenuMetrics()` runs on every 2s `sampleSystemLoad()` tick (§12)
  and not only on `menuWillOpen`, the VoiceOver description tracks current load without the menu
  being opened.

### 10.4 `refreshPresetSelectionState()` (lines 1557-1563)
A single loop over `zip(presetMenuItems, allPresets)` (relies on both arrays being built
together, same order, same length, in the `applicationDidFinishLaunching` loop, §9.2 step 6):
`item.isEnabled = FileManager.default.fileExists(atPath: preset.path)`; `item.state =
(activePreset?.key == preset.key) ? .on : .off`. Replaces what used to be 10 explicit
`isEnabled` lines + 10 explicit `state` lines, one pair per built-in path constant.

### 10.5 `refreshWidthSelectionState()` (lines 1602-1621)
Reads `minimumSlotsForCurrentPreset()`, `requestedWidthSlots`, `effectiveWidthSlots()`.
- `widthStatusItem.title`: if `requestedWidthSlots` is set and below the preset's minimum,
  shows `"... (requested X, min Y for preset)"`; if set and at/above minimum, shows just the
  effective count; if unset, shows `"auto (preset scale %.2fx)"`.
- `widthAutoItem.state = .on` iff `requestedWidthSlots == nil`.
- Each of `widthSlotItems` (tags 1-4): `.state = .on` iff `requestedWidthSlots != nil &&
  item.tag == effectiveWidthSlots()`.

### 10.6 `refreshOverlaySelectionState()` (lines 1623-1632)
If `requestedOverlayText` is set: `overlayStatusItem.title = "Overlay Text: <text> (bold|regular)"`,
`overlayClearItem.isEnabled = true`. Else: `"Overlay Text: off"`,
`overlayClearItem.isEnabled = false`.

---

## 11. Action handlers (`@objc`, menu-item targets)

| Method | Lines | Effect |
|---|---|---|
| `selectPreset(_:)` | 1634-1639 | tag-indexes into `allPresets`, calls `switchToGif(to: preset.path, descriptor: preset)` — single method for all built-in presets, replacing the former per-preset `selectXPreset()` methods |
| `selectLoadSource(_:)` | 1641-1661 | switches the active load source; see §7.10 |
| `selectWidthAuto` | 1663-1669 | `requestedWidthSlots = nil`; `applySizing()`; `renderCurrentFrame()`; `refreshWidthSelectionState()` |
| `selectWidthSlot(_:)` | 1671-1677 | `requestedWidthSlots = clamp(sender.tag, 1, 4)`; same 3 follow-up calls |
| `promptOverlayText` | 1679-1744 | see §11.1 |
| `clearOverlayText` | 1746-1749 | delegates to `applyOverlayCleared()` (lines 1751-1756): `requestedOverlayText = nil`; `updateRenderedFrames()`; `renderCurrentFrame()`; `refreshOverlaySelectionState()` |
| `showAbout` | 1218-1231 | modal `NSAlert` with static text + live speed-mode line |
| `exitApp` | 1233-1236 | `NSApp.terminate(nil)` |
| `sampleSystemLoad` | 1331-1357 | see §12 |
| `displayLinkTick(_:)` / `fallbackTimerTick` → `advanceFrames(now:)` | 1931-1973 | see §13 |

### 11.1 `promptOverlayText()` (lines 1679-1744)
1. Builds an `NSAlert` with a custom `accessoryView` containing: a label (`"Overlay text"`),
   an `NSTextField` pre-filled with `requestedOverlayText ?? ""`, and an `NSButton`
   checkbox (`"Bold"`) pre-set to `requestedOverlayBold`.
2. Hands first-responder focus to the text field deterministically via
   `alert.window.initialFirstResponder = field` *before* `runModal()`, plus a single
   `DispatchQueue.main.async` belt-and-suspenders hop that re-asserts `makeFirstResponder(field)`
   (in case an AppKit version ignores `initialFirstResponder` on an NSAlert accessory view) and
   moves the caret to the end of any pre-filled text (which needs the field editor that exists only
   once focused). Closures capture `field`/`alertWindow` weakly. (This replaced an earlier
   timing-dependent hack that fired the same closure three times at staggered 0/0.03/0.12s delays.)
3. `alert.runModal()` — if the result isn't `.alertFirstButtonReturn` (i.e. "Cancel" or the
   window was closed), returns with no state change (line 1726).
4. On "Apply": `requestedOverlayBold = boldToggle.state == .on` (line 1728) always happens
   first, regardless of the text field's content.
5. If the trimmed field text is empty: calls `applyOverlayCleared()` (which nils
   `requestedOverlayText` then `updateRenderedFrames()` + `renderCurrentFrame()` +
   `refreshOverlaySelectionState()`) and returns (lines 1730-1733).
6. If the trimmed text exceeds `Tuning.overlayMaxChars` (12): `showRuntimeError(...)` and
   return *without* changing `requestedOverlayText` (lines 1735-1738) — the bold-toggle change
   from step 4 is still committed even though the text change is rejected.
7. Otherwise: `requestedOverlayText = input`, then `updateRenderedFrames()` +
   `renderCurrentFrame()` + `refreshOverlaySelectionState()` (lines 1740-1743).

### 11.2 `switchToGif(to:descriptor:)` (lines 1758-1793)
Signature: `switchToGif(to path: String, descriptor: PresetDescriptor?)` — takes both an
explicit path and the resolved `PresetDescriptor` (or `nil`) for that path, called only from
`selectPreset(_:)` (line 1638, always passing a non-nil descriptor for one of the built-in
presets today; the `nil` case exists for a hypothetical future custom-path menu action, not
currently exercised by any call site).
1. Expands `~` in the given path; no-ops if it equals `activeGifPath` already (line 1760).
2. Saves `previousPath`, `previousPreset`, `previousFrames`, `previousDurations`,
   `previousFrameIndex` (lines 1762-1766) — `frameAspects` is **not** saved/restored here.
3. Calls `loadFrames(from: expanded)`. On failure: restores `activeGifPath`, `activePreset`,
   `frames`, `baseDurations`, `frameIndex` from the saved values, shows a runtime error alert,
   calls `refreshPresetSelectionState()`, and returns (lines 1768-1777) — `frameAspects` is left
   as whatever `loadFrames` mutated it to before failing (see §14 — `loadFrames` only assigns
   `frameAspects` on full success, so in practice it is unchanged on failure, but this is a
   property of `loadFrames`'s internal ordering, not of anything `switchToGif` does).
4. On success: `activeGifPath = expanded`, `activePreset = descriptor`, `frameIndex = 0`,
   `statusItem.button?.toolTip = activeGifPath` (lines 1779-1782).
5. `applySizing()`, `renderCurrentFrame()`, `refreshWidthSelectionState()`,
   `refreshOverlaySelectionState()` (lines 1784-1787).
6. Calls `resetGameLoopTiming()` (§13.1c, line 1791) — re-syncs the **running** driver's clock
   rather than tearing it down and recreating it, since the frame source changed but the display
   link's button/screen has not. (Previously this invalidated and recreated the driver on every
   switch.)
7. `refreshPresetSelectionState()` (line 1792).

---

## 12. Load-sampling sequence — `sampleSystemLoad()` (lines 1331-1357)

Invoked every `Tuning.loadSampleInterval` (2.0s) by `loadTimer` (started in
`startLoadMonitoring()`, lines 1318-1329, registered on `RunLoop.main` in `.common` mode).

`loadTimer` uses the classic `Timer(target: self, selector:)` form, which strongly retains `self`
while `self` retains the timer — a retain cycle. This is intentionally accepted, not a leak in
practice: the `MenuBarLoadRunnerApp` delegate lives for the entire process and only deallocates at
`NSApp.terminate`, so nothing is ever waiting to be freed. (The game-loop driver does not have this
concern — `displayLink`/`fallbackTimer` are held directly and torn down in `stopGameLoop()`, §13.1b.)

1. `cachedLoadAverages = readSystemLoadAverages()` (line 1333) — always attempted,
   independent of anything below.
2. Captures the real elapsed wall-clock since the last tick (`lastSampleUptime`/`elapsed`, lines
   1338-1340, §7.11), then `sampleActiveSource(elapsed:)` (line 1344, §7.10) — samples **only** the
   active source. If it returns a non-`nil` `usage`:
   - `recordLoadSample(usage)` (line 1345) appends it to the trace-chart ring buffer.
   - Only if `isAutoSpeed` (line 1346, i.e. `config.speedMultiplierOverride == nil`):
     - `candidate = speedMultiplier(forUsage: usage)` (line 1347, see §12.1).
     - If `abs(candidate - speedMultiplier) >= Tuning.speedUpdateHysteresis` (0.08): assigns
       `speedMultiplier = candidate` and nothing else. The game-loop driver reads
       `speedMultiplier` live through the accumulator (§13.2 step 5), so the new speed takes
       effect on the next tick with no driver restart. (Previously this invalidated and
       recreated the driver on every hysteresis-crossing change — an unnecessary teardown that
       also reset `lastTickTime`/`accumulatedFrameTime`; removed with the CADisplayLink migration.)
   - If `speedMultiplierOverride` is set, `speedMultiplier` is never touched here.
   - If `usage` is `nil` (not enough samples yet / source unavailable), nothing in this block runs.
3. `refreshMenuMetrics()` (line 1356) — always called, regardless of whether step 2 changed
   anything.

### 12.1 `speedMultiplier(forUsage:)` (lines 1834-1844)
```swift
let profile = currentSpeedProfile()
let clampedUsage = min(max(usage, 0), 1)
let curvedUsage = pow(clampedUsage, profile.responseExponent)
var value = profile.min + ((profile.max - profile.min) * curvedUsage)
if isUnderPowerPressure {                                            // see §12.2
    let ceiling = profile.min + (profile.max - profile.min) * Tuning.constrainedSpeedCeilingFraction
    value = min(value, ceiling)
}
return min(max(value, profile.min), profile.max)   // final clamp; redundant given the formula above, but present in source
```
`value` is declared `var` (not `let`) precisely because the `isUnderPowerPressure` branch may
reassign it. `profile.responseExponent` is `1.0` (linear) for every preset — speed scales
proportionally with load across the whole range. The `isUnderPowerPressure` cap
holds `value` at `profile.min + (profile.max - profile.min) * Tuning.constrainedSpeedCeilingFraction`
(0.5, the midpoint of the preset's range) — see §12.2.

### 12.2 Self-throttling under power/thermal pressure
The app only ever *reads* system power/thermal state; it never mutates it and cannot throttle the
system or any other process. "Self-throttling" means it reduces **its own** animation work (fewer
frame advances/redraws) so the load indicator doesn't add to the load it visualizes.

- `isUnderPowerPressure` (a computed `Bool`, lines 1849-1862): `true` when
  `ProcessInfo.isLowPowerModeEnabled` is on, `thermalState` is `.serious`/`.critical`, **or** the
  cached `memoryPressureLevel` contains `.warning`/`.critical` (§7.5). Read-only, getters only.
- When true, `speedMultiplier(forUsage:)` (§12.1) caps this app's auto speed at the midpoint of the
  active preset's range (`Tuning.constrainedSpeedCeilingFraction`). The menu's Speed Multiplier line
  appends `" [throttled: low power/thermal]"` whenever `isUnderPowerPressure` is true — i.e. it is
  keyed on the pressure state, not on whether the value actually hit the ceiling, so at low load
  (where the computed value is already below the midpoint) the suffix still shows even though
  no clamping occurred (§10.3 shows the base format).
- `reevaluateSpeedForCurrentConditions()` (lines 1870-1874): recomputes `speedMultiplier` from the
  **active source's** latest sample (`activeSourceCurrentUsage`) **immediately, bypassing the
  2s-tick hysteresis** (guarded by `isAutoSpeed && activeSourceHasSample`), then calls
  `refreshMenuMetrics()`. Invoked from the `powerStateObserver`/`thermalStateObserver` (§9.2 step
  15), the memory-pressure dispatch source (§7.5), and `selectLoadSource` (§7.10) so the cap
  engages/lifts — or a new source takes over — without waiting up to 2s.
- Disabled entirely in fixed-speed mode (`--speed-multiplier`), like all auto-speed logic.

### 12.3 `readSystemLoadAverages()` (lines 1811-1822)
Calls `getloadavg(&samples, 3)` (POSIX API) into a 3-element buffer. Returns `nil` if the
call returns fewer than 3 samples; otherwise returns the tuple indexed by
`Tuning.loadAverage1mIndex/5mIndex/15mIndex` (`0/1/2`).

---

## 13. Rendering / game-loop sequence

The engine is a **display-synchronized game loop**: a `CADisplayLink` (macOS 14+) fires a
callback aligned to the refresh of whichever screen the status item is on (including ProMotion's
variable rate), and the callback advances GIF frames by accumulating real elapsed wall time —
decoupling animation *timing* (fixed by each frame's GIF delay ÷ `speedMultiplier`) from the
*driver's* callback cadence (the display's refresh). This is the layer to touch when changing how
playback is clocked; leave frame *content* to §14 (`updateRenderedFrames`).

The driver is created once per (re)start and read live: `speedMultiplier` is consulted inside the
accumulator on every tick, so a speed change takes effect on the next callback with **no driver
restart** (see §12 — the old invalidate/recreate dance was removed). A single driver instance
persists across preset switches; only its timing is re-synced (§13.1c).

### 13.1a `startGameLoop()` (lines 1896-1915)
Calls `stopGameLoop()` then `resetGameLoopTiming()`, then installs the driver:
- **macOS 14+ and `statusItem.button` non-nil**: `button.displayLink(target: self, selector:
  #selector(displayLinkTick(_:)))` → stored in `displayLink`, added to `RunLoop.main` in `.common`
  mode. The button is view-backed and lives in the status-bar window, so the link attaches and
  follows the button's screen automatically.
- **otherwise (fallback)**: `Timer(timeInterval: Tuning.gameLoopFallbackInterval /* 1/60s */,
  target: self, selector: #selector(fallbackTimerTick), repeats: true)` → stored in
  `fallbackTimer`, added to `RunLoop.main` in `.common`.

### 13.1b `stopGameLoop()` (lines 1917-1922)
Invalidates and nils **both** `displayLink` and `fallbackTimer` (only one is ever live, but
teardown is unconditional). Called by `startGameLoop()`, `applicationWillTerminate` (§9.3), and
`updateAnimationForOcclusion()` when the item becomes occluded (§13.6).

### 13.1c `resetGameLoopTiming()` (lines 1926-1929)
Sets `lastTickTime = 0` (resync sentinel — see §13.2 step 2) and `accumulatedFrameTime = 0`.
Called by `startGameLoop()` and by `switchToGif` on a frame-source change (§11.2) — the latter
re-syncs the *running* driver instead of tearing it down, since the link's button/screen is
unchanged and only the frames/durations differ (§11.2 step 6).

### 13.2 `displayLinkTick(_:)` / `fallbackTimerTick()` → `advanceFrames(now:)` (lines 1931-1973)
Two thin `@objc` shims select the clock source and call the shared core:
- `displayLinkTick(_ link:)` (macOS 14+) passes `link.timestamp`.
- `fallbackTimerTick()` passes `ProcessInfo.processInfo.systemUptime`.

`advanceFrames(now:)`:
1. No-ops if `baseDurations` or `renderedFrames` is empty (line 1941).
2. **Resync sentinel**: if `lastTickTime == 0`, latch `lastTickTime = now` and return without
   advancing (first tick after any (re)start or `resetGameLoopTiming()`).
3. `delta = now - lastTickTime`; `lastTickTime = now`. Guard: if `delta <= 0` (backwards clock) or
   `delta > Tuning.maxFrameAdvanceDelta` (1.0s — display sleep, app occlusion, clock jump), return
   without advancing. This prevents replaying thousands of catch-up frames on resume; the next tick
   resumes cleanly from the current frame.
4. `accumulatedFrameTime += delta`.
5. Loop: while `accumulatedFrameTime >= requiredDelay` (where `requiredDelay =
   max(baseDurations[frameIndex] / speedMultiplier, Tuning.minGifFrameDelay)`):
   subtract `requiredDelay` from `accumulatedFrameTime`, advance
   `frameIndex = (frameIndex + 1) % baseDurations.count`, set `advanced = true` — this loop can
   advance multiple frames in a single tick if the speed multiplier is high enough that several
   frame durations fit inside one accumulated delta.
6. If any advance happened, call `renderCurrentFrame()` — a tick with no advance does not touch the
   displayed image at all.

### 13.3 `renderCurrentFrame()` (lines 1975-1978)
No-ops if `statusItem.button` is `nil`, `renderedFrames` is empty, or `frameIndex` is out of
bounds (guard). Sets `button.image = renderedFrames[frameIndex]` and nothing else. `imageScaling`
is **not** set here — it was moved off the per-frame hot path into `applySizing()` (§13.4; the
resolved anti-pattern #4, Appendix B).

### 13.4 `applySizing()` (lines 2051-2064)
No-ops if `frames` is empty. Sets `button.imageScaling` based on `requestedWidthSlots != nil`
(`.scaleAxesIndependently`) vs `nil` (`.scaleProportionallyUpOrDown`) — here rather than per frame,
since it depends only on auto-vs-fixed width (line 2056). `baseSlotWidth =
max(NSStatusBar.system.thickness, Tuning.minBaseSlotWidth)`. Sets `statusItem.length` to
`ceil(baseSlotWidth * effectiveWidthSlots())` if `requestedWidthSlots != nil`, else
`ceil(baseSlotWidth * currentPresetScale())` — the product is rounded **up** to a whole point in
both branches. Always calls `updateRenderedFrames()` at the end.

### 13.5 `updateRenderedFrames()` (lines 1986-2049)
No-ops (sets `renderedFrames = []`) if `frames` is empty.
1. `availableHeight = max(NSStatusBar.system.thickness - Tuning.renderVerticalInset, 1)`;
   `availableWidth = max(statusItem.length - Tuning.renderHorizontalInset, 1)` (lines 1992-1993).
2. `overlayText = effectiveOverlayText()` — `requestedOverlayText` trimmed, or `nil` if
   empty after trim (`effectiveOverlayText()` at lines 1980-1984).
3. For each raw frame `i`:
   - `aspect = frameAspects[i]` if in range, else `Tuning.fallbackSlotScale` (a neutral 1.0
     fallback numeric value, line 2000).
   - If `requestedWidthSlots != nil`: `targetSize = (availableWidth, availableHeight)`
     (stretch to fill the slot exactly, no aspect preservation).
   - Else: `targetHeight = min(max(availableHeight, 12), max(availableWidth, 12) /
     max(aspect, 0.01))`; `targetWidth = targetHeight * aspect` (aspect-preserving fit).
   - Builds an `NSImage(size: targetSize, flipped: false) { ... }` closure-rendered image:
     draws `rawImage` scaled into the full target rect; if `overlayText != nil`, computes a
     font size = `clamp(targetSize.height * 0.5, 8, 14)`, weight = bold/regular per
     `requestedOverlayBold`, font = `NSFont.monospacedSystemFont`, white fill / black stroke
     (`strokeWidth = -2`, i.e. fill-and-stroke per `NSAttributedString` convention for
     negative stroke width), centered/truncating-tail paragraph style, drawn into a rect
     inset by `overlayHorizontalInset`/`overlayVerticalInset` and vertically centered.
   - `rendered.isTemplate = false` (explicit — not left to the `NSImage` default).
4. Assigns the full array to `renderedFrames` (line 2048) — every frame is regenerated on
   every call; there is no per-frame caching/memoization across calls.

### 13.6 Occlusion pause — `updateAnimationForOcclusion()` (lines 1879-1888)
Driven by the `occlusionObserver` (`NSWindow.didChangeOcclusionStateNotification` on the status
button's window, §9.2 step 14). When the button's window is **not** `.visible` (behind the notch /
menu-bar overflow, on another Space, or the display is off), calls `stopGameLoop()` — no point
re-rasterizing frames no one can see. When it becomes visible again (and no driver is currently
live), calls `startGameLoop()`, which re-syncs timing so playback resumes from the current frame
rather than replaying skipped ones (§13.2 step 2).

By design it only ever pauses in *response to a positive occlusion-changed event*: if the
notification never fires, the game loop just keeps running (always-animating fallback) — so a
missing/never-firing notification can never freeze a visible icon. This is complementary to §12.2:
occlusion pause stops work entirely when invisible; power/thermal capping reduces work when visible
but the machine is under pressure.

---

## 14. GIF decode pipeline — `loadFrames(from:)` (lines 2088-2146)

1. `FileManager.default.fileExists(atPath:)` check; fails (returns `false`, logs to stderr)
   if absent (lines 2090-2093).
2. `CGImageSourceCreateWithURL` — fails if the file isn't a decodable image source
   (lines 2095-2098).
3. `CGImageSourceGetCount(src)` — fails if `0` (lines 2100-2104).
4. For each frame index `0..<count`:
   - `CGImageSourceCreateImageAtIndex` — on failure, `continue` (skip this frame silently,
     lines 2114-2116; does not abort the whole load).
   - `trimTransparentPadding(from:)` (§14.1) applied to the decoded `CGImage`.
   - `frameDuration(from:frameIndex:)` (§14.2) — appended to `nextDurations`.
   - Wraps the trimmed `CGImage` in an `NSImage` sized to the trimmed pixel dimensions,
     appended to `nextFrames`.
   - Aspect ratio `= width/height` (or `Tuning.fallbackSlotScale` if height is `0`), clamped to
     `>= Tuning.minAspect`, appended to `nextAspects` (line 2129).
5. Final guard: `!nextFrames.isEmpty && nextFrames.count == nextDurations.count &&
   nextFrames.count == nextAspects.count` — since every append happens together per
   iteration (no `continue` between the three appends once past the decode-failure check),
   this guard can only fail via the `nextFrames.isEmpty` branch in practice (all three arrays
   are always appended to in lockstep after that point). Fails with a stderr message if not
   met (lines 2133-2140).
6. On success, assigns `frames = nextFrames`, `frameAspects = nextAspects`, `baseDurations =
   nextDurations`, returns `true` (lines 2142-2145).

Note: this method never touches `renderedFrames` — callers (`applicationDidFinishLaunching`,
`switchToGif`) always follow a successful `loadFrames` call with `applySizing()` (which
internally calls `updateRenderedFrames()`).

### 14.1 `trimTransparentPadding(from:)` (lines 2148-2193)
1. Wraps the `CGImage` in an `NSBitmapImageRep`; returns the image unchanged if it has no
   alpha channel or `bitmapData` is `nil` (line 2150).
2. Returns unchanged if `width/height <= 0` or `samplesPerPixel < 4`
   (`Tuning.minAlphaPixelComponents`) (line 2156).
3. Determines the alpha byte's offset within a pixel from `image.alphaInfo`:
   `.alphaOnly/.first/.premultipliedFirst/.noneSkipFirst` → offset `0`;
   `.last/.premultipliedLast/.noneSkipLast` → offset `bytesPerPixel - 1`; any other case
   (e.g. `.none`) → returns the image unchanged (lines 2158-2166).
4. Scans every pixel; tracks the bounding box (`minX/maxX/minY/maxY`) of pixels whose alpha
   byte is `> Tuning.alphaVisibleThreshold` (3) (lines 2168-2184).
5. Returns unchanged if no pixel exceeded the threshold — the guard is `maxX >= minX && maxY >=
   minY` (both axes checked) — or if the bounding box already covers the full image.
6. Otherwise crops to the bounding box via `CGImage.cropping(to:)`, falling back to the
   original image if cropping itself fails (line 2192).

### 14.2 `frameDuration(from:frameIndex:)` (lines 2195-2207)
Reads `CGImageSourceCopyPropertiesAtIndex` → `kCGImagePropertyGIFDictionary` →
`kCGImagePropertyGIFUnclampedDelayTime`, falling back to `kCGImagePropertyGIFDelayTime`,
falling back to `Tuning.defaultGifFrameDelay` (0.1) if neither property/dictionary is
present. Final value is floored at `Tuning.minGifFrameDelay` (0.02) via `max(value, ...)`.

---

## 15. Sizing model

### 15.1 `currentPresetScale() -> CGFloat` (lines 2077-2079)
`activePreset?.slotScale ?? defaultDescriptor?.slotScale ?? Tuning.fallbackSlotScale` — a direct
read of the descriptor resolved once by `switchToGif`/`init` (§8.1), rather than re-deriving
identity from a path comparison on every call. `slotScale` values come from `gifs/presets.json`
(§8.1): e.g. horse `1.2`, totoro `1.25`, totoro-group `4.0`, dog/chihiro `1.0`; a custom GIF
(`activePreset == nil`) borrows `defaultDescriptor`'s scale, or the neutral `1.0`
`Tuning.fallbackSlotScale` if the manifest failed to load.

### 15.2 `minimumSlotsForCurrentPreset() -> Int` (lines 2072-2075)
`clamp(Int(ceil(currentPresetScale())), Tuning.minWidthSlots, Tuning.maxWidthSlots)` — e.g. a
`4.0` slot scale (totoro-group) → minimum `4` slots; `1.2` (horse) → `ceil = 2` →
minimum `2` slots; `1.0` (dog/chihiro) → minimum `1` slot.

### 15.3 `effectiveWidthSlots() -> Int` (lines 2066-2070)
`clamp(requestedWidthSlots ?? minimumSlotsForCurrentPreset(), minimumSlotsForCurrentPreset(),
Tuning.maxWidthSlots)`.

---

## 16. Speed-profile model

### 16.1 `currentPresetKind()` / `PresetKind` — removed
Both the `PresetKind` enum and the `currentPresetKind()` accessor were removed when preset
profiles moved into `gifs/presets.json` (§8): preset identity is now the `key`/`speedProfile`
data on `PresetDescriptor`, not a Swift enum, so there is no per-kind `switch` and nothing left to
map through `PresetKind`. `currentSpeedProfile()` (§16.2) reads `activePreset?.speedProfile`
directly. (Appendix B #1 noted the `currentPresetKind()` deletion; the `PresetKind` enum itself
was subsequently removed as well.)

### 16.2 `currentSpeedProfile() -> SpeedProfile` (lines 2081-2083)
`activePreset?.speedProfile ?? defaultDescriptor?.speedProfile ?? Self.customSpeedProfile`. Each
built-in preset's `SpeedProfile` is decoded from `gifs/presets.json` in `init` (lines 948-968) and
stored on its `PresetDescriptor` (§8.1) — there is no longer a `switch` over any preset enum
computing this per call. `Self.customSpeedProfile` (lines 837-842) is a self-contained literal
(`label "custom"`, `min 0.5`, `max 2.5`, `responseExponent 1.0`) used only as a last resort when
there is neither an active preset nor a manifest default to borrow from (i.e. a custom GIF loaded
while the manifest itself failed); in the normal path a custom GIF inherits `defaultDescriptor`'s
profile.

---

## 17. Alerts / error surfaces

| Method | Lines | `alertStyle` | Triggers app exit? |
|---|---|---|---|
| `showAbout()` | 1218-1231 | `.informational` | no |
| `showStartupErrorAndQuit(_:)` | 1299-1314 | `.critical` | yes — `NSApp.terminate(nil)` after modal dismissed |
| `showRuntimeError(_:)` | 1795-1809 | `.warning` | no — also calls `NSSound.beep()` first |

All three (and `promptOverlayText`'s alert) route through `suppressModalAlerts` (line 1297,
`config.exitAfterSeconds != nil`): under the `MENUBAR_LOAD_RUNNER_EXIT_AFTER` test hook they
report to stderr (and, for the startup path, terminate) instead of blocking on a modal.

`makeMenuAlertIcon()` (lines 1238-1291): looks up the `"horse-black"` entry in `allPresets` by
key (`allPresets.first(where: { $0.key == "horse-black" })?.path`) and loads that path as an
`NSImage`, then aspect-fits it (the art is ~3:2) into a 48x48 box backed by an
`NSBitmapImageRep` at the display's `backingScaleFactor` with high-quality interpolation (drawn
via an `NSGraphicsContext`, not `lockFocus`/`unlockFocus`); returns `nil` if either the lookup or
the image load fails. Used as the `.icon` on all three alert types above (conditionally,
`if let icon = ...`) — i.e. every alert in the app uses the black-horse GIF as its icon regardless
of the currently active preset.

---

## 18. Cross-reference: what the launcher passes vs. what `Config` expects

| Launcher passes | `Config.parse()` consumes |
|---|---|
| The positional arg **unchanged** — a preset keyword (e.g. `horse-white`), a raw GIF path, or nothing at all | `presetOrPath` (positional, or `MENUBAR_LOAD_RUNNER_PATH` env fallback, else `""`); keyword→path resolution and the manifest `defaultPreset` fallback deferred to `init` (§9.1) |
| `--width`/`-w`, `--speed-multiplier`, `--load-source`, `--overlay-text`, `-h`/`--help` passed through verbatim as `passthrough_args` | same flags, parsed as documented in §6.3 |
| `--foreground`/`--no-detach`/`--detach`/`--extra` — consumed by the launcher itself, never forwarded | not present in `Config` — the Swift binary has no knowledge of detach/singleton behavior; those are exclusively launcher-level concerns |

Since anti-pattern #6, the launcher no longer resolves preset keywords or supplies a default —
it forwards the positional arg verbatim, and the Swift side owns the keyword→path mapping and
the `horse-white` default. The launcher still validates none of `--width`'s value,
`--speed-multiplier`'s value, or `--overlay-text`'s length — all of that validation happens
only inside `Config.parse()` after the Swift process starts (§6.3 table).

---

## 19. Login-item scripts (`scripts/install-login-item.sh` / `uninstall-login-item.sh`)

A third artifact beyond the two core source files: optional, personal-use start-at-login tooling.
These are plain `bash` scripts that only invoke the `menubar-load-runner` launcher and macOS
`launchctl`; they do **not** touch `MenuBarLoadRunner.swift` logic. Shared identifiers: `LABEL =
ai.bera.menubarloadrunner`, `PLIST = ~/Library/LaunchAgents/$LABEL.plist`, `LOG = /tmp/$LABEL.log`,
`DOMAIN = gui/$(id -u)` (the per-user GUI launchd domain).

### 19.1 `install-login-item.sh`

1. **Path resolution** — resolves its own real directory (a `readlink` loop over `BASH_SOURCE`,
   mirroring the launcher's `resolve_script_dir`), then `REPO_DIR` (parent) and `LAUNCHER =
   $REPO_DIR/menubar-load-runner`; aborts if the launcher isn't executable. So the plist gets an
   absolute launcher path regardless of the caller's CWD.
2. **Best-effort pre-build** — if `swiftc` is on `PATH`, compiles the binary once
   (`-O -strict-concurrency=complete`). This removes the swift-toolchain dependency from *login* for
   the common (unchanged-source) case; if the source later changes, the launcher's mtime check
   recompiles at next login (needs `swiftc` on launchd's `PATH` then — see the `EnvironmentVariables`
   key below). A failed pre-build only warns; on-demand compile still covers it.
3. **`ProgramArguments`** — `[LAUNCHER, "--no-detach", "$@"]`, minimally XML-escaped. `--no-detach`
   is load-bearing: the launcher's default path is `nohup … & disown` then `exit 0` (§3.3), which
   `launchd` would read as "the job finished." `--no-detach` makes the launcher `exec` into the Swift
   process (same PID), so `launchd` supervises the *real* long-lived process.
4. **Plist keys written**: `Label`; `ProgramArguments`; `EnvironmentVariables.PATH =
   /usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin` (launchd's per-user default `PATH` is minimal; the
   launcher needs `swift`/`swiftc` and `pgrep` for its on-demand compile and singleton check);
   `RunAtLoad = true`; `StandardOutPath`/`StandardErrorPath = $LOG`. **No `KeepAlive`** — on purpose,
   so a menu **Exit** (or a crash) leaves it stopped until the next login rather than respawning.
5. **When it runs.** `RunAtLoad` means launchd starts it *immediately when it loads the agent*, which
   happens as the `gui/$uid` domain comes up at **login** (reboot → login, log-out → log-in, or
   fast-user-switch into the account). It is a *user* agent, so it requires login; it never runs at
   boot pre-login (that would be a system LaunchDaemon).
6. **Idempotent (re)load** — `launchctl bootout "$DOMAIN/$LABEL"` (`|| true`), then **poll**
   `launchctl print` until the service is gone (≤ 30 × 0.1 s), then `bootstrap`, then `kickstart -k`
   (start now, no logout). The poll is the v1.1.1 fix: `bootout` is asynchronous, so an immediate
   `bootstrap` races the still-terminating service and fails with launchctl error 5 ("Input/output
   error"). Because of the poll, re-running install (e.g. to change the baked-in preset/args) is safe.
7. **Default preset.** The scripts pass args through verbatim and hardcode no preset; a no-arg install
   yields `ProgramArguments = [LAUNCHER, "--no-detach"]`, and the app then resolves the manifest's
   `defaultPreset` (`horse-white`, §6/§9.1). Passing a keyword pins it explicitly.

### 19.2 `uninstall-login-item.sh`

The exact inverse: `launchctl bootout "$DOMAIN/$LABEL"` (`|| true`, stops the process and deregisters
the agent), then `rm -f` the plist and the `/tmp` log. It deliberately does **not** use `launchctl
disable`, which writes a *persistent* override into the launchd/BTM store that would survive file
removal. Safe to re-run (a no-op when nothing is installed). It does not kill an instance the user
launched manually (that process isn't in `$DOMAIN/$LABEL`); it prints the `pkill` hint instead.

### 19.3 Background Task Management (BTM) and where it surfaces

A loaded LaunchAgent is tracked by macOS's Background Task Management, so it appears in **System
Settings → General → Login Items → "Allow in the Background"** — *not* the top "Open at Login" list,
which is reserved for `.app`-style login items (`SMAppService.mainApp` / drag-added apps). Because the
launcher is an unsigned script (no Developer ID, no bundle), BTM may label the entry generically.
Toggling it **off** in Settings applies a persistent BTM override, separate from `launchctl` state and
from these scripts; `uninstall-login-item.sh` is the clean removal path (deregister + delete), which
also clears the "Allow in the Background" entry. The `.app` + `SMAppService.mainApp` route (which would
instead land in "Open at Login", with a friendly name and an in-app toggle) is intentionally not taken
— it needs a bundle + `Bundle.main.resourceURL` resource resolution and buys only cosmetics over the
LaunchAgent's identical start-at-login behavior.

---

## Appendix A — API surface & boundary summary

Grounded characterization of the code's *shape*, derived from the diagrams in §2.1/§2.2.

- **External API of the Swift binary** = the CLI/env contract (`Config`, §6) + the four framework
  entry points on `MenuBarLoadRunnerApp` (`applicationDidFinishLaunching`, `applicationWillTerminate`,
  `menuWillOpen`, and the `@objc` menu-action selectors). Everything else is `private` — encapsulation
  at the type boundary is tight; there are no leaked internals.
- **Cross-process boundary** (launcher ↔ binary) is narrow and explicit: the positional arg
  (preset keyword or GIF path) as `argv[1]`, the passthrough flags (§18), and four env vars (§2).
  Since anti-pattern #6 the launcher forwards the positional arg unchanged — preset identity lives
  entirely Swift-side. Detach/singleton concerns live entirely launcher-side and are invisible to
  the binary — a clean split.
- **Internal collaborator boundary**: the load-source readers (`CPULoadMonitor`,
  `MemoryLoadMonitor`, `GPULoadMonitor`, `NetworkLoadMonitor`, `DiskLoadMonitor`) are the
  sub-responsibilities factored into their own types, each exposing a small
  `sampleUsage(...)` + `hasSample` + last-value surface and hiding all Mach/IORegistry/sysctl
  detail; they share the `ThroughputScaler` value type for unbounded rates (§7.9), and
  `LoadHistoryView` is a self-contained drawing view. `Tuning` is a pure constant namespace with no
  behavior. (The single-type extraction note that once said "`CPULoadMonitor` is the only
  collaborator" predates the additional readers.)
- **Two decoupled data pipelines** meet only at `frameIndex`/`renderedFrames`: the raw-decode
  pipeline (`loadFrames` → `frames`/`frameAspects`/`baseDurations`) and the render pipeline
  (`updateRenderedFrames` → `renderedFrames`), as documented in §13–§14.

## Appendix B — Structural observations (resolved)

The duplication / dead-code / modularity observations surfaced while verifying this document
were tracked in a since-deleted TODO (`TODO-20260706-2303-antipatterns-from-design-review.md`)
and closed out on 2026-07-07. Outcomes, recorded here so the rationale survives:

**Applied** (the sections above already reflect these):
- **#1 — dead `currentPresetKind()`**: deleted (zero callers). `enum PresetKind` was retained at
  the time, but has since been removed entirely along with the move of preset profiles to
  `gifs/presets.json` (§8, §16.1).
- **#2 — `isAutoSpeed`**: extracted the 4× `config.speedMultiplierOverride == nil` predicate
  into one computed property.
- **#3 — overlay-clear dedup**: `clearOverlayText` and `promptOverlayText`'s empty-input branch
  now share `applyOverlayCleared()`.
- **#4 — per-frame `imageScaling`**: moved off the `renderCurrentFrame` hot path into
  `applySizing()` (§14); it depends only on auto-vs-fixed width, which changes on selection, not
  per frame.
- **#6 — cross-language preset duplication**: Swift now owns keyword→path resolution
  (`allPresets` + `Config.defaultPreset`); the launcher's parallel path table and keyword switch
  were deleted (§3.3, §6, §8.1, §9.1, §18). This is the largest structural win here.

**Evaluated and deliberately declined** (leaving them documented so they aren't re-proposed):
- **#5 — memoize `updateRenderedFrames()`**: declined. It is *not* on the animation hot path
  (the game loop reads precomputed `renderedFrames`, §14), so the only waste it removes is
  re-rasterizing all frames on an occasional `didChangeScreenParametersNotification` that doesn't
  actually change menu-bar thickness. A frame-count-based cache key risks showing stale art when
  switching between two GIFs of equal frame count, which outweighs the rare-event gain. If ever
  worth it, the safer form is to guard the screen-parameters observer to re-render only when
  `NSStatusBar.system.thickness` actually changed — no per-frame cache key, no stale-art risk.
- **#7 — extract cohesive clusters (`GifDecoder`/`FrameRenderer`/`SpeedController`) out of the
  `MenuBarLoadRunnerApp` hub**: declined. The single-file shape is an intentional choice for an
  app this size (per `CLAUDE.md`); extraction is tidiness with no behavior or ROI win. `GifDecoder`
  (pure, no `@MainActor` state) is the cleanest starting point should this ever be revisited.

**Noted but not scheduled** (inherent to the design, not defects): help/preset text partly
duplicated across the launcher's `print_help` and Swift `Config.printUsage()` (launcher-only flags
must be documented launcher-side); and the three `refresh*SelectionState()` methods sharing a shape
(they mutate different menu items with genuinely different logic — a forced abstraction would
obscure more than it saves).
