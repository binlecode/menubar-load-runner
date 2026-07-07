# DESIGN-system.md

Ground truth for this document: `menubar-load-runner` (zsh launcher, 173 lines) and
`MenuBarLoadRunner.swift` (1256 lines). Every claim below is derived from the source and was
re-verified against it.

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
when `config.speedMultiplierOverride != nil`, the CPU-to-speed mapping in
`sampleSystemLoad()` (line 530: `if config.speedMultiplierOverride == nil`) is skipped
entirely — `speedMultiplier` becomes a constant, clamped once at startup to
`Tuning.speedOverrideMin...Tuning.speedOverrideMax` (lines 432-434).

---

## 2. Process architecture

Two processes, two languages, executed in sequence per invocation:

```
user shell
   └── menubar-load-runner (zsh script, this repo's entrypoint)
          ├── resolves its own script directory (resolve_script_dir, lines 6-26)
          ├── parses CLI args into: launch_detached, allow_extra, passthrough_args (lines 90-108)
          ├── forwards the positional arg (preset keyword or path) unchanged; only intercepts
          │      its own -h/--help (lines 110-120) — keyword→path resolution and the default
          │      preset moved to the Swift side (Config/init)
          ├── decides swiftc vs swift execution (lines 123-137):
          │      - if MenuBarLoadRunner binary missing or older than MenuBarLoadRunner.swift:
          │            try `swiftc -O` to (re)build the binary
          │            on swiftc failure, fall back to `swift -module-cache-path ... <src>` (interpreted)
          │      - else: run the existing compiled binary directly
          ├── enforces a singleton via `pgrep -f "/MenuBarLoadRunner( |$)"` unless --extra (lines 139-155)
          └── launches the resolved command, either:
                 - detached: nohup + disown, stdout/stderr -> log file, script exits 0 (lines 207-216)
                 - foreground: exec (replaces the shell process) (lines 218-219)
                     └── MenuBarLoadRunner (compiled Swift binary OR `swift` interpreter session)
                            = NSApplication process running MenuBarLoadRunnerApp as its delegate
                            (bottom of MenuBarLoadRunner.swift, lines 1067-1077)
```

Environment variables read by the launcher and passed to the Swift process:
- `SWIFT_MODULE_CACHE` (launcher-side only, default `/tmp/swift-module-cache`, line 93)
- `MENUBAR_LOAD_RUNNER_LOG_FILE` (launcher-side only, default `/tmp/menubar-load-runner.log`, line 208)
- `MENUBAR_LOAD_RUNNER_BIN_NAME` (set by launcher to `menubar-load-runner/menubar-load-runner`,
  lines 210, 218; read by the Swift process in `Config.printUsage()`, line 147, for its own
  `--help` text)
- `MENUBAR_LOAD_RUNNER_PATH` (read only by the Swift process, `Config.parse()` line 127, as a
  fallback GIF path when no positional argument was given)

### 2.1 Module dependency map (Swift binary)

Four top-level declarations. Arrows = "depends on / calls". `Tuning` is a pure leaf; `CPULoadMonitor`
is the one cleanly-extracted collaborator; `MenuBarLoadRunnerApp` is the hub that owns everything
else (the size/shape consequence is tracked in the anti-patterns TODO; see Appendix B).

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
 │ PURE READ-ONLY HELPERS (no mutation): currentPresetScale/Kind ·                 │
 │ currentSpeedProfile · effectiveWidthSlots · minimumSlotsForCurrentPreset ·      │
 │ effectiveOverlayText · speedMultiplier(forUsage:) · isUnderPowerPressure ·      │
 │ cpuStateText · readSystemLoadAverages   +  collaborators: loadMonitor, allPresets│
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

### 3.2 `print_help()` (lines 28-73)
Static text block (docs only — the launcher no longer maps keywords to paths). Lists the 9
preset keywords (`dog-white`, `dog-black`, `horse-black`, `horse-white`, `totoro`,
`totoro-group-white`, `totoro-group-black`, `totoro-white`, `totoro-black`) and 7
flags (`--width`, `--speed-multiplier`, `--overlay-text`, `--foreground`/`--no-detach`,
`--detach`, `--extra`, `-h`/`--help`). The former `horse`→`horse-black` alias was removed;
callers use canonical names. These keywords are documentation of what the Swift side
(`allPresets`) accepts, not a launcher-side mapping.

### 3.3 `main()` (lines 75-171)

**Preflight** (lines 76-81): exits 127 if `swift` is not on `PATH`.

**Flag scan** (lines 90-108): single pass over `$@`; `--foreground`/`--no-detach` set
`launch_detached=0`; `--detach` sets `launch_detached=1`; `--extra` sets `allow_extra=1`;
everything else is pushed into `passthrough_args` unchanged (including unrecognized flags and
the positional preset keyword / GIF path — the launcher validates none of them; that is left
to `Config.parse()` / `MenuBarLoadRunnerApp.init` in the Swift binary).

**Positional passthrough** (lines 110-120): the launcher no longer resolves preset keywords or
supplies a default. It forwards the positional arg (preset keyword *or* raw path *or* nothing)
to the Swift binary verbatim, only intercepting its own `-h`/`--help` (print help, exit 0).
Keyword→path resolution and the `horse-white` default now live Swift-side (see §8.1, §9;
`Config.defaultPreset` supplies the default when no positional arg / env override is present).
This removed the launcher's former 10-entry path table, the keyword `case` switch, and the
default injection — collapsing the preset mapping to a single language.

**Build-or-reuse decision** (lines 122-137): compares mtimes of
`MenuBarLoadRunner.swift` and `MenuBarLoadRunner` (the compiled binary); rebuilds with
`swiftc -O` only when missing or stale; falls back to interpreted `swift` on compile failure.

**Singleton enforcement** (lines 139-155): `pgrep -f "/MenuBarLoadRunner( |$)"` — matches a
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

**Launch** (lines 158-170):
- Detached: `nohup ... >>"$log_file" 2>&1 </dev/null &`, `disown`, prints
  `pid=... log=...`, exits 0. The launcher process itself terminates; the Swift process is
  reparented and continues running.
- Foreground: `exec` — the launcher process image is replaced by the Swift process (no
  child/parent relationship; same PID).

---

## 4. Swift binary — top-level structure

`MenuBarLoadRunner.swift` has four top-level declarations plus a script-level entry point:

| # | Declaration | Lines | Kind |
|---|---|---|---|
| 1 | `Tuning` | ~7-73 | `enum` (namespace of `static let` constants only) |
| 2 | `Config` | ~75-173 | `struct` (CLI/env parsing + usage text) |
| 3 | `CPULoadMonitor` | ~177 | `@MainActor final class` (CPU sampling) |
| 4 | `MenuBarLoadRunnerApp` | ~248 | `@MainActor final class`, `NSObject`, conforms to `NSApplicationDelegate`, `NSMenuDelegate` |
| — | entry point | (end of file) | top-level `switch` on `Config.parse()` |

**Concurrency posture.** Both classes are annotated `@MainActor`, and the launcher builds with
`swiftc -O -strict-concurrency=complete` (interpreted fallback: `swift -strict-concurrency=complete`)
in Swift 5 mode — so any future data-race violation surfaces as a *warning*, not a hard build break.
The build is warning-clean. The only sites that needed help reaching the `@MainActor`-isolated
methods from `NotificationCenter` callbacks are the four observer closures registered on `queue:
.main` (the screen-parameters, power-state, thermal-state, and occlusion observers): each of the four
wraps its call in `MainActor.assumeIsolated { ... }`, safe precisely because those observers are
registered to fire on the main queue.

### 4.1 Entry point (end of file, ~1231-1241)
```
switch Config.parse() {
case .config(let config): builds NSApplication.shared, sets its delegate to
                           MenuBarLoadRunnerApp(config:), calls app.run()  [blocks]
case .help:                exit(0)
case nil:                  exit(1)
}
```
`Config.parse()` itself already printed usage text (via `printUsage()`) for both the `.help`
and `nil` (error) outcomes before returning, at each of its early-return sites (lines 82-83,
90-93, 97-100, 104-107, 111-113, 119-122, 131-134).

---

## 5. `Tuning` — constant inventory (~lines 7-73)

All values are `private` to the file, `static let`, grouped by the enum's declaration order
(not by category — the groupings below are for lookup only; the source has no section
comments dividing them):

**Frame timing**
- `defaultGifFrameDelay: TimeInterval = 0.1`
- `minGifFrameDelay: TimeInterval = 0.02`
- `gameLoopFallbackInterval: TimeInterval = 1.0 / 60.0` — tick period for the 60 Hz `Timer`
  game-loop fallback used only on macOS < 14 (CADisplayLink is the primary driver; see §13.1a)
- `maxFrameAdvanceDelta: TimeInterval = 1.0` — inter-tick gaps larger than this (display sleep,
  app occlusion, clock jump) resync instead of replaying every skipped frame (see §13.2 step 3)

**CPU sampling / speed mapping**
- `cpuSmoothingAlpha: Double = 0.2`
- `loadSampleInterval: TimeInterval = 2.0`
- `speedUpdateHysteresis: Double = 0.08`
- `constrainedSpeedCeilingFraction: Double = 0.5` — midpoint cap applied to auto speed under power/thermal pressure (§12.1, §12.2)
- `cpuStateLowThreshold: Double = 0.30`
- `cpuStateMediumThreshold: Double = 0.70`
- `dogSpeedMin/Max: Double = 0.5 / 2.5`
- `horseSpeedMin/Max: Double = 0.45 / 2.3`
- `totoroSpeedMin/Max: Double = 0.5 / 2.6`
- `totoroGroupSpeedMin/Max: Double = 0.2 / 2.0`
- `linearSpeedCurveExponent: Double = 1.0`
- `speedOverrideMin/Max: Double = 0.1 / 5.0`
- `initialSpeedMultiplier: Double = 1.0`
- `percentScale: Double = 100.0`

**Rendering geometry**
- `renderVerticalInset: CGFloat = 4`
- `minIconDimension: CGFloat = 12`
- `renderHorizontalInset: CGFloat = 2`
- `minAspect: CGFloat = 0.01`
- `minBaseSlotWidth: CGFloat = 18`
- `horseSlotScale: CGFloat = 1.2`
- `totoroSlotScale: CGFloat = 1.25`
- `totoroGroupSlotScale: CGFloat = 4.0`
- `dogSlotScale: CGFloat = 1.0`

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

## 6. `Config` — CLI/env interface (~lines 75-173)

### 6.1 Fields (lines 83-91)
```swift
static let defaultPreset = "horse-white"   // used when no positional arg / env override
let presetOrPath: String                    // preset keyword OR GIF path; tilde-expanded, non-empty
let widthSlots: Int?                        // nil = auto; else 1...4
let speedMultiplierOverride: Double?        // nil = auto (CPU-driven); else fixed, > 0
let overlayText: String?                    // nil = no overlay; else 1...12 trimmed chars
```
`presetOrPath` is stored verbatim — it may be a built-in preset **keyword** (e.g.
`horse-white`) or a GIF path. Keyword→path resolution is deferred to
`MenuBarLoadRunnerApp.init` (§9), so `Config` carries no preset-table knowledge.

### 6.2 `ParseResult` (lines 76-79)
```swift
enum ParseResult { case config(Config); case help }
```
`Config.parse() -> ParseResult?` — `nil` return means a parse error already reported to
stderr (usage already printed at the failing call site).

### 6.3 Argument grammar (lines 93-163)
Single forward pass over `CommandLine.arguments.dropFirst()` via a manual iterator
(`iterator.next()` consumes the flag's value token, so `--width 2` is two consumed tokens):

| Token(s) | Effect | Validation | Lines |
|---|---|---|---|
| `--help`, `-h` | prints usage, returns `.help` | none | 103-105 |
| `--width`, `-w` | sets `widthSlots` | next token must parse as `Int` in `1...4` | 106-116 |
| `--speed-multiplier` | sets `speedMultiplierOverride` | next token must parse as `Double > 0` | 117-123 |
| `--overlay-text` | sets `overlayText` | next token, trimmed, must be `1...12` chars after trim | 124-136 |
| anything else, first occurrence | sets `presetOrPath` | — | 137-139 |
| anything else, second+ occurrence | fatal parse error ("Unexpected argument") | — | 140-143 |

**Positional resolution + default** (lines 148-153): if no positional arg was consumed, falls
back to `ProcessInfo.processInfo.environment["MENUBAR_LOAD_RUNNER_PATH"]`; if *that* is also
absent/empty, falls back to `Config.defaultPreset` (`horse-white`) — so parsing no longer fails
on a missing arg (the old "Missing GIF path" error path is gone). The resolved value is passed
through `NSString(string:).expandingTildeInPath` before being stored (a no-op for a bare
keyword) — this is the only normalization applied; no symlink resolution, no
`standardizingPath`.

### 6.4 `printUsage()` (lines 165-173)
Reads `MENUBAR_LOAD_RUNNER_BIN_NAME` env var for the binary name shown in usage text,
falling back to `CommandLine.arguments[0]`'s last path component (lines 147-148). All
speed-range numbers shown are read live from `Tuning` (line 153), so this text cannot drift
from the actual `Tuning` values.

---

## 7. `CPULoadMonitor` — CPU sampling module (~lines 172-241)

### 7.1 State (lines 158-163)
```swift
private var lastTotalTicks: UInt64?
private var lastIdleTicks: UInt64?
private var hasSmoothedUsage = false
private(set) var smoothedUsage: Double = 0
private let smoothingAlpha: Double = Tuning.cpuSmoothingAlpha   // 0.2
var hasSample: Bool { hasSmoothedUsage }
```

### 7.2 `sampleUsage() -> Double?` (lines 165-175)
Calls `currentUsage()`. First successful sample seeds `smoothedUsage` directly (no
smoothing applied to the first value, lines 167-170). Every subsequent sample applies an
exponential moving average:
```
smoothedUsage = (0.2 * usage) + (0.8 * smoothedUsage)
```
Returns `nil` if `currentUsage()` returns `nil` (i.e. no update to `smoothedUsage` happens on
a failed sample).

### 7.3 `currentUsage() -> Double?` (lines 177-224)
1. Calls `host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &cpuInfo,
   &cpuInfoCount)` (Mach API). Returns `nil` if the call doesn't return `KERN_SUCCESS` or
   `cpuInfo` is `nil` (line 189).
2. `defer`s a `vm_deallocate` of the returned `cpuInfo` buffer (lines 191-194).
3. Sums `user + system + nice + idle` ticks across all CPUs into `totalTicks`, and `idle`
   ticks into `idleTicks` (loop, lines 200-209), using `CPU_STATE_MAX` as the per-CPU stride
   and `CPU_STATE_USER`/`SYSTEM`/`NICE`/`IDLE` as offsets within each CPU's slice.
4. `defer`s storing the current `totalTicks`/`idleTicks` into `lastTotalTicks`/`lastIdleTicks`
   for the next call, unconditionally (lines 211-214) — this runs even if the function is
   about to return `nil` at line 217 (first-ever call has no previous sample) or line 222
   (degenerate delta).
5. Requires a previous sample to exist (`lastTotalTicks`/`lastIdleTicks` both non-nil) to
   compute anything; otherwise returns `nil` (line 216-218) — this is why `CPULoadMonitor`
   needs two `sampleUsage()` calls before it produces its first real value (first call stores
   ticks and returns `nil` from `currentUsage()`, but note `sampleUsage()` itself only calls
   `currentUsage()` once and returns whatever it gets — so `sampleUsage()`'s first call
   returns `nil` too, per line 166's guard).
6. Delta computation uses wrapping subtraction (`&-`, lines 220-221) and requires
   `deltaTotal > 0 && deltaIdle <= deltaTotal` (line 222) before returning
   `(deltaTotal - deltaIdle) / deltaTotal` — i.e. the fraction of ticks since the last sample
   that were *not* idle.

### 7.4 Call sites
Only called from `MenuBarLoadRunnerApp.sampleSystemLoad()` (line 543:
`loadMonitor.sampleUsage()`), which runs on `Tuning.loadSampleInterval` (2s) via
`loadTimer`.

The remaining subsections below (7.5-7.14) cover the memory/GPU/network/disk readers, the
shared adaptive-scaling and load-source-selector machinery, and the durable design principles
those readers were built against — all of which landed after §7.1-7.4 above were written and are
documented here for the first time. Every line number below was re-verified against the current
1256+-line source with `grep -n`/`Read`, independent of the "approximate, may have drifted"
caveat in the doc header that applies to the older §1-§18 numbers.

### 7.5 `MemoryLoadMonitor` — memory + swap module (lines 402-504)

A *mixed-domain* sibling of `CPULoadMonitor`: one reader exposing both an **instantaneous**
percentage and a **counter-delta** rate, composited into a single driver value.

- **State** (lines 403-420): `currentUsedFraction`/`hasSample` (instantaneous), `swapUsedBytes`/
  `swapTotalBytes`/`hasSwapSample` (instantaneous, display-only), `currentSwapRateBytesPerSec`/
  `hasSwapRateSample` (counter-delta), `currentMemoryLoad` (the composite driver value),
  `lastSwapEvents: UInt64?` (previous-tick baseline for the delta), and its own
  `swapScaler = ThroughputScaler(floor: Tuning.swapFloorBytesPerSec)` (§7.9).
- **`sampleUsage(elapsed:) -> Double?`** (lines 427-436): calls `readVMSample()`; returns `nil`
  only if that instantaneous read fails (a failed swap read degrades just the swap
  display/rate, never the fraction — see §7.12 principle 4). On success: sets
  `currentUsedFraction`/`hasSample`, calls `readSwapUsage()` (swap capacity, display-only),
  calls `updateSwapRate(swapEvents:elapsed:)`, then computes
  `currentMemoryLoad = max(sample.usedFraction, swapLoad)` where `swapLoad` is
  `swapScaler.normalize(speed: currentSwapRateBytesPerSec)` gated on `hasSwapRateSample` (else
  `0`) — the composite formula named in the class comment (lines 394-400).
- **`updateSwapRate(swapEvents:elapsed:)`** (lines 441-452): a textbook counter-delta — `defer`s
  storing `lastSwapEvents = swapEvents` unconditionally; if `elapsed` is `nil` (first tick, or a
  source-switch re-sample per §7.10) or there is no `lastSwapEvents` baseline yet, reports no
  rate (`hasSwapRateSample = false`) rather than dividing by a stale/nominal interval. Otherwise
  `currentSwapRateBytesPerSec = deltaBytes / elapsed` (real wall-clock seconds, §7.11).
- **`readVMSample()`** (lines 463-490): one `host_statistics64(HOST_VM_INFO64)` call yields both
  values used here — `used = 1 - (free + purgeable + external) * pageSize / physicalMemory` (a
  documented approximation, not Activity Monitor's exact algorithm, per the comment at lines
  454-462) and the cumulative `swapins + swapouts` page count (in bytes) returned as
  `swapEvents` — i.e. the swap-rate counter costs zero extra syscalls, it's a second field off
  the same read. Page size comes from `host_page_size`, not the mutable `vm_kernel_page_size`
  global, to stay `-strict-concurrency=complete`-clean. Returns `nil` on non-`KERN_SUCCESS` or a
  zero `physicalMemory`/page-size read.
- **`readSwapUsage()`** (lines 493-503): `sysctlbyname("vm.swapusage")`, unprivileged,
  instantaneous, no lifecycle; sets `swapUsedBytes`/`swapTotalBytes`/`hasSwapSample`, or leaves
  `hasSwapSample = false` on failure without touching the other fields.

**Memory-pressure tri-state** (a separate mechanism, owned by `MenuBarLoadRunnerApp`, not
`MemoryLoadMonitor`, but feeding the same self-throttle path as memory load):
- `memoryPressureLevel: DispatchSource.MemoryPressureEvent = .normal` (line 781) and
  `memoryPressureSource: DispatchSourceMemoryPressure?` (line 782) — cached because, unlike
  `thermalState`/`isLowPowerModeEnabled`, memory pressure has **no synchronous getter**; it is
  event-only.
- Constructed in `applicationDidFinishLaunching` (lines 1003-1016):
  `DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue:
  .main)` — the mask **must** include `.normal`, or the cached level can never fall back out of
  `.warning`/`.critical` once raised. Its event handler updates `memoryPressureLevel`, then calls
  `reevaluateSpeedForCurrentConditions()` and `refreshMenuMetrics()` immediately (bypassing the
  2s tick, same as the power/thermal observers, §12.2). `pressureSource.resume()` (line 1016)
  starts delivery — dispatch sources start suspended. It is torn down in
  `applicationWillTerminate` via `memoryPressureSource?.cancel()` (lines 1049-1051), **not**
  `NotificationCenter.removeObserver` — a distinct lifecycle from the four notification observers
  torn down just above it.
- Read by `isUnderPowerPressure` (lines 1629-1642): `true` if Low Power Mode is on, or
  `thermalState` is `.serious`/`.critical`, **or** `memoryPressureLevel.contains(.warning)` /
  `.contains(.critical)` — memory pressure is the third input into the same self-throttle
  computed property documented in §12.2, joining low-power/thermal rather than replacing them.
  `memoryPressureText()` (lines 1305-1309) renders it as `"Normal"`/`"Warning"`/`"Critical"` for
  the menu's `Memory Pressure:` state line (§7.10).

### 7.6 `GPULoadMonitor` — GPU utilization module (lines 512-572)

Unprivileged-tier, instantaneous, point-read — the simplest of the four new readers.

- `isAvailable` (lines 519-525): probes once (`readUtilization() != nil`) and caches the result
  (`availabilityChecked`/`available`) — this is the "cache expensive setup" principle (§7.12 #6)
  applied to a probe rather than a subscription, since there's nothing else here to cache.
- `sampleUsage() -> Double?` (lines 527-535): no `elapsed:` parameter — this is a pure point
  read, unlike the counter-delta readers below. Sets `hasSample = false` and returns `nil` on
  failure (never a fabricated `0`).
- `readUtilization()` (lines 540-545) tries `IOServiceMatching("IOAccelerator")` first, then
  falls back to `"AGXAccelerator"` (the Apple Silicon-specific IOClass) since the accelerator's
  concrete class is hardware-specific. `readUtilization(matching:)` (lines 547-571) iterates every
  matched `io_service_t`, reads its `"PerformanceStatistics"` registry property, and takes the
  max `"Device Utilization %"` (0…100) across matches, scaled by `Tuning.percentScale` (÷100) and
  clamped to `0...1`. Because the value is natively bounded 0…1 after that division, it is
  **not** run through `ThroughputScaler` (§7.9) — bounded percentage signals map straight
  through, per §7.12 principle 3. GPU *power/energy* is a different, unimplemented tier — see
  §7.14.

### 7.7 `NetworkLoadMonitor` — network throughput module (lines 579-628)

- `isAvailable` (line 588): hardcoded `true` — `getifaddrs` is always present on macOS, unlike
  the IORegistry-probed GPU/disk sources.
- `sampleUsage(elapsed:) -> Double?` (lines 590-608): counter-delta over cumulative interface
  byte counters. `defer`s storing `lastBytes = total` unconditionally (mirroring
  `MemoryLoadMonitor.updateSwapRate`'s pattern); if `elapsed` is `nil` or there's no `lastBytes`
  baseline, reports no sample (first tick / source-switch re-sample warm-up, §7.10/§7.11).
  Otherwise `currentThroughputBytesPerSec = deltaBytes / elapsed`, then normalizes through its
  own `scaler = ThroughputScaler(floor: Tuning.networkFloorBytesPerSec)` (§7.9) into `currentLoad`
  — the value actually returned and used to drive speed.
- `readTotalBytes()` (lines 610-627): `getifaddrs` → walks the linked list, keeping only entries
  where `ifa_addr.sa_family == AF_LINK` (only those carry a populated `if_data`) and skipping
  `"lo0"` (loopback) so local traffic doesn't inflate the reading; sums `ifi_ibytes + ifi_obytes`
  across the remaining interfaces.

### 7.8 `DiskLoadMonitor` — disk I/O throughput module (lines 634-696)

Structurally a twin of `NetworkLoadMonitor` (§7.7) over a different IORegistry class.

- `isAvailable` (lines 643-649): probed once and cached (`readTotalBytes() != nil`), like
  `GPULoadMonitor.isAvailable` — a machine with no readable `IOBlockStorageDriver` disables the
  source.
- `sampleUsage(elapsed:) -> Double?` (lines 651-667): same counter-delta shape as
  `NetworkLoadMonitor.sampleUsage(elapsed:)` — `defer`-stores `lastBytes`, requires `elapsed` and
  a prior baseline, divides the byte delta by `elapsed`, normalizes through
  `scaler = ThroughputScaler(floor: Tuning.diskFloorBytesPerSec)` into `currentLoad`.
- `readTotalBytes()` (lines 669-695): `IOServiceMatching("IOBlockStorageDriver")` → for every
  matched entry, reads its `"Statistics"` registry dictionary's `"Bytes (Read)"` and
  `"Bytes (Write)"` keys (defaulting a missing key to `0`, not failing the whole read) and sums
  across all drivers found; returns `nil` (via `found` staying `false`) only if zero drivers
  matched at all.

### 7.9 `ThroughputScaler` — shared adaptive-scaling value type (lines 268-321)

A `private struct` (a pure value type, not `@MainActor` — it has no shared mutable global state,
just per-owner instance state), ported from btop's `Net::collect` auto-scale (`Tuning` comment,
lines 45-51). Three unbounded rate signals share this same normalization: `MemoryLoadMonitor`'s
swap rate (§7.5), `NetworkLoadMonitor`'s throughput (§7.7), and `DiskLoadMonitor`'s throughput
(§7.8) — each owns its own scaler instance seeded with a different `floor` (`Tuning.
swapFloorBytesPerSec`/`networkFloorBytesPerSec`/`diskFloorBytesPerSec`, 1/1/4 MiB/s, lines 58-60).

- **State** (lines 269-274): `floor` (fixed at init), `ceiling` (the adaptive normalization
  denominator, seeded to `floor`), `seeded`, a `recent: [Double]` ring of the last
  `Tuning.scalerWindow` (5) samples, and `overCount`/`underCount` hysteresis counters.
- **`normalize(speed:) -> Double`** (lines 282-315):
  1. First call only: seeds `ceiling = max(speed * Tuning.scalerHeadroomUp, floor)` so the very
     first sample doesn't peg at `1.0` against a bare `floor` (comment, lines 283-284).
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
- **CLI/env wiring in `Config`**: `let loadSource: LoadSource` field (line 145); `--load-source`
  parsed at lines 196-202 (stores the raw string, deferring resolution); falls back to
  `MENUBAR_LOAD_RUNNER_LOAD_SOURCE` (line 222) when no flag was given; resolves via
  `LoadSource.from(key:) ?? .cpu` (line 225) — unknown/absent values fall back to `.cpu` with a
  logged warning (lines 226-228), never a launch failure (§7.12 principle 2/4). `printUsage()`
  documents the flag and lists all known keys (lines 251-253).
- **`activeLoadSource: LoadSource`** (line 777, mutable): initialized from `config.loadSource`
  in `init` (line 797); mutated only by `selectLoadSource(_:)` (below).
- **The three speed-path helpers — the only read sites for "what drives the animation"**:
  - `sampleActiveSource(elapsed:) -> Double?` (lines 1161-1169): a `switch` dispatching to
    exactly one reader's `sampleUsage()`/`sampleUsage(elapsed:)`, called once per tick from
    `sampleSystemLoad()` (line 1145) — this is what makes sampling **active-only**: the four
    inactive monitors are never polled while another source drives.
  - `activeSourceHasSample: Bool` (lines 1172-1180): mirrors the switch, reading each monitor's
    `hasSample`.
  - `activeSourceCurrentUsage: Double` (lines 1185-1193): mirrors the switch again, reading each
    monitor's last driving value without re-sampling (`loadMonitor.smoothedUsage`,
    `memoryMonitor.currentMemoryLoad`, `gpuMonitor.currentUtilization`,
    `networkMonitor.currentLoad`, `diskMonitor.currentLoad`) — used by
    `reevaluateSpeedForCurrentConditions()` (§12.2) to recompute speed immediately without
    waiting for the next tick's sample.
- **Source-conditional `refreshMenuMetrics()`** (lines 1203-1279, superseding the single-source
  description in §10.3): a `switch activeLoadSource` with one case per source, each setting
  `usageItem.title`/`stateItem.title`/the accessibility label from *only* that source's monitor
  (e.g. `.memory` shows `"Memory Pressure: ..."` from `memoryPressureText()` plus
  `memoryUsageLineText()`/swap rate, lines 1222-1236; `.network`/`.disk` show a human MB/s figure
  via `networkUsageLineText()`/`diskUsageLineText()`, lines 1334-1340, rather than the
  scaler-normalized 0…1 value that actually drives speed). The inactive sources' lines are never
  shown, matching active-only sampling. `speedMultiplierItem.title` additionally names
  `activeLoadSource.menuTitle` (lines 1284-1293) so the dashboard always states *what* is
  driving the animation.
- **`Load Source` radio submenu**: built in `applicationDidFinishLaunching` (lines 869-879) — one
  `NSMenuItem` per `LoadSource.allCases`, `tag = source.rawValue`, action
  `selectLoadSource(_:)`, appended to `loadSourceMenuItems`. Selection state is refreshed by
  `refreshLoadSourceSelectionState()` (lines 1353-1360): `.state = .on` iff
  `item.tag == activeLoadSource.rawValue`; `.isEnabled = isSourceAvailable(source)` — the same
  radio-group + enablement shape as the width/preset menus (§10.4/§10.5).
- **`selectLoadSource(_:)`** (lines 1427-1441, `@objc`): no-ops if the tapped source is already
  active; otherwise sets `activeLoadSource`, immediately calls `sampleActiveSource(elapsed: nil)`
  to seed the new monitor (an on-demand resample has no meaningful interval, so counter-delta
  readers just store a baseline here), resets `lastSampleUptime = nil` (§7.11) so the next tick
  doesn't divide by a stale gap, calls `reevaluateSpeedForCurrentConditions()` to re-derive speed
  immediately (bypassing the 2s hysteresis, mirroring preset switches), then refreshes both the
  load-source selection state and the menu metrics.
- **`isSourceAvailable(_:)`** (lines 1367-1377): `.cpu`/`.memory` are always `true` (core
  Mach/sysctl, never absent); `.gpu`/`.network`/`.disk` defer to each monitor's own `isAvailable`
  probe. Also checks a debug-only `forcedUnavailableSources` env override
  (`MENUBAR_LOAD_RUNNER_FORCE_UNAVAILABLE`, lines 1379-1385) so QA can exercise the
  disabled-menu-item and fallback path on hardware where every reader actually works.
  **Launch-time fallback** (lines 881-887, right after the submenu is built): if the
  configured `activeLoadSource` isn't available, logs a warning to stderr and forces `.cpu` —
  the one enforcement point where an unavailable *requested* source is corrected, versus the
  per-tick case where a reader going dark just yields `nil` for that tick and the animation holds
  its last speed (§7.12 principle 4).

### 7.11 Shared elapsed-time plumbing — `lastSampleUptime` / `elapsed:`

The mechanism that makes every counter-delta *rate* reader (as opposed to CPU's counter-delta
*ratio*, which needs no wall-clock division at all — see the distinction below) divide by real
time rather than the nominal 2s tick interval.

- `lastSampleUptime: Double?` (lines 770-771, comment explicitly calls out
  `ProcessInfo.systemUptime` over `Date` for immunity to wall-clock changes).
- Captured once per tick in `sampleSystemLoad()` (lines 1136-1141): `now =
  ProcessInfo.processInfo.systemUptime`; `elapsed = lastSampleUptime.map { now - $0 }` (`nil` on
  the very first tick); `lastSampleUptime = now`. This single `elapsed` value is threaded into
  `sampleActiveSource(elapsed:)` (line 1145, §7.10), which forwards it to whichever reader's
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
- **Reset on source switch**: `selectLoadSource(_:)` (§7.10, line 1437) sets
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
   `activeSourceHasSample`, `activeSourceCurrentUsage` (lines 1161-1193, §7.10). These are the
   *only* speed-path read sites.
4. **Menu line** — add a source-conditional branch to `refreshMenuMetrics()` (lines 1203-1279).
5. **Availability** — expose `isAvailable` on the reader (probed once and cached, like
   `GPULoadMonitor`/`DiskLoadMonitor`) and add a case to `isSourceAvailable(_:)`
   (lines 1367-1377); the disabled-menu-item and launch-fallback behavior follow automatically.
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

## 8. `MenuBarLoadRunnerApp` — state inventory (~lines 244-319)

All properties are `private` unless noted; all are on the single `MenuBarLoadRunnerApp`
instance created once at the bottom of the file.

**Nested types**
```swift
private enum PresetKind { case dog, horse, totoro, totoroGroup, custom }                  // lines 228-234
private struct SpeedProfile { let label: String; let min, max, responseExponent: Double }  // lines 237-242
private struct PresetDescriptor {                                                          // lines 244-251
    let key: String            // internal id, e.g. "dog-white" — not CLI-facing
    let menuTitle: String
    let path: String           // absolute path, resolved once in init() from scriptDirURL
    let kind: PresetKind
    let slotScale: CGFloat
    let speedProfile: SpeedProfile
}
static let customSpeedProfile = SpeedProfile(       // lines 253-258
    label: "custom", min: Tuning.dogSpeedMin, max: Tuning.dogSpeedMax,
    responseExponent: Tuning.linearSpeedCurveExponent
)                                                    // i.e. dog's numeric range, under the label "custom"
```

**Immutable, set in `init` (lines 296-328)**
```swift
let config: Config
let allPresets: [PresetDescriptor]   // the 10 built-in presets; single source of truth (see §8.1)
```
Each preset's `path` is `#filePath`'s directory + `"gifs/<name>.gif"`, resolved via a local
`resolvedPath(_:)` helper (lines 301-304) — i.e. relative to the *source file's* location.
`allPresets` is now the **sole** owner of the key→path mapping: the launcher no longer keeps a
parallel `gifs_dir` path table (it was deleted with anti-pattern #6), so the cross-language
duplication that this note previously described is gone.

**Mutable, mutated over the app's lifetime**
```swift
var activePreset: PresetDescriptor?               // init: keyword match (allPresets.first { $0.key == config.presetOrPath }) else path match; changed by switchToGif(to:descriptor:)
var activeGifPath: String                         // init: matched preset's path, else config.presetOrPath verbatim; changed by switchToGif(to:descriptor:)
var statusItem: NSStatusItem!                     // set once, applicationDidFinishLaunching
var infoMenu: NSMenu!                             // set once
var cpuUsageItem, loadAverageItem, cpuStateItem,
    speedMultiplierItem, widthStatusItem,
    widthMenuItem, widthAutoItem: NSMenuItem!      // set once; .title mutated by refresh*() methods
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
var loadTimer: Timer?                             // 2s CPU-sampling driver
var loadMonitor = CPULoadMonitor()                // owns EMA CPU state
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

### 8.1 Preset registry — `allPresets` (built in `init`, lines 312-323)

Single source of truth for every built-in preset, replacing what used to be 10 independent
path constants plus parallel if-chains in multiple functions. Order = menu order = array index
= `NSMenuItem.tag`:

| # | `key` | `menuTitle` | `kind` | `slotScale` | speed profile (label, min, max, exponent) |
|---|---|---|---|---|---|
| 0 | `dog-white` | Dog (White) | `.dog` | 1.0 | dog, 0.5, 2.5, 1.0 |
| 1 | `dog-black` | Dog (Black) | `.dog` | 1.0 | dog, 0.5, 2.5, 1.0 |
| 2 | `horse-black` | Horse (Black) | `.horse` | 1.2 | horse, 0.45, 2.3, 1.0 |
| 3 | `horse-white` | Horse (White) | `.horse` | 1.2 | horse, 0.45, 2.3, 1.0 |
| 4 | `totoro` | Totoro | `.totoro` | 1.25 | totoro, 0.5, 2.6, 1.0 |
| 5 | `totoro-group-white` | Totoro (Group, White) | `.totoroGroup` | 4.0 | totoro-group, 0.2, 2.0, 1.0 |
| 6 | `totoro-group-black` | Totoro (Group, Black) | `.totoroGroup` | 4.0 | totoro-group, 0.2, 2.0, 1.0 |
| 7 | `totoro-white` | Totoro (White) | `.totoro` | 1.25 | totoro, 0.5, 2.6, 1.0 |
| 8 | `totoro-black` | Totoro (Black) | `.totoro` | 1.25 | totoro, 0.5, 2.6, 1.0 |

A custom/user-supplied GIF whose path matches none of these leaves `activePreset == nil`;
every accessor (§15, §16) falls back to `.custom`/`Tuning.dogSlotScale`/`Self.customSpeedProfile`
in that case. `PresetDescriptor.key` is now the CLI-facing preset keyword as well as an
internal identifier: `init` matches `config.presetOrPath` against `key` first (§9.1), and the
same `key` drives `refreshPresetSelectionState`'s equality check and `makeMenuAlertIcon`'s
lookup. The launcher no longer resolves keywords (anti-pattern #6) — it forwards the keyword and
`allPresets` is the single place it becomes a path (§18).

---

## 9. `MenuBarLoadRunnerApp` — lifecycle sequence

### 9.1 `init(config:)` (lines 325-366)
Stores `config`, `requestedWidthSlots = config.widthSlots`, `requestedOverlayText =
config.overlayText`. Builds `allPresets` (10 `PresetDescriptor` literals, §8.1) via a local
`resolvedPath(_:)` helper closing over `scriptDirURL` (lines 330-347), then resolves the
positional arg (lines 354-365) — **this is the single place a preset keyword becomes a path**,
having moved here from the launcher (anti-pattern #6):
- If `config.presetOrPath` matches a preset's `key` (`allPresets.first { $0.key == ... }`) →
  `activeGifPath = matched.path`, `activePreset = matched`.
- Otherwise treat it as a GIF path: `activeGifPath = config.presetOrPath`, and still
  `activePreset = allPresets.first { $0.path == config.presetOrPath }` so a raw path pointing
  at a built-in GIF adopts that preset's profile; `activePreset` is `nil` for a genuine custom
  GIF.

No AppKit objects are touched here.

### 9.2 `applicationDidFinishLaunching(_:)` (lines 368-465) — exact order of operations
1. `NSApp.setActivationPolicy(.accessory)` (line 331) — no Dock icon, no app switcher entry.
2. Create `statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)`;
   if `.button` is `nil`, call `showStartupErrorAndQuit("Unable to create NSStatusItem button.")`
   and `return` — a graceful quit consistent with the GIF-decode-failure path (step 10), **not**
   a `fatalError`/crash.
3. `button.imagePosition = .imageOnly`; `button.imageScaling` set based on whether
   `requestedWidthSlots` is `nil` (`.scaleProportionallyUpOrDown`) or set
   (`.scaleAxesIndependently`); `button.toolTip = activeGifPath`;
   `button.setAccessibilityLabel("MenuBar Load Runner")` — a static VoiceOver base label, later
   enriched with live CPU load by `refreshMenuMetrics()` (§10.3).
4. Build `infoMenu` (`NSMenu`), set `self` as its delegate (lines 342-343).
5. Append, in this exact order, to `infoMenu` (lines 345-417):
   `CPU Usage: --` → `Load Avg (1/5/15m): -- / -- / --` → `CPU State: --` →
   `Speed Multiplier: --` → `Width: --` → `Width Options` (submenu: `Auto (preset)`,
   separator, `1 slot`..`4 slots`) → `Overlay Text: --` → `Overlay Text` (submenu:
   `Set Text... (max 12)`, `Clear`) → separator → disabled `Presets` header → one menu item
   per `allPresets` entry, built by a `for (index, preset) in allPresets.enumerated()` loop
   (lines 407-413) that sets `item.tag = index` and appends each item to `presetMenuItems` (so
   the 10 preset titles are generated from the registry, not listed as 10 separate literal
   `NSMenuItem` constructions) → separator → `About` → `Exit` (key equivalent `q`).
6. `infoMenu.items.forEach { $0.target = self }` (line 418) — sets every item's target to
   `self`, including the ones that already had `target = self` set individually and the
   disabled/no-action ones (this is a blanket overwrite, applied after individual
   `.target = self` assignments earlier in the block).
7. `presetsHeaderItem.isEnabled = false` (line 419) — disables the section header via the
   local variable captured when it was created (line 404), not a title-string lookup.
8. `statusItem.menu = infoMenu` (line 420).
9. `refreshPresetSelectionState()`, `refreshWidthSelectionState()`,
   `refreshOverlaySelectionState()` (lines 421-423) — populate initial `.state`/`.title`
   text before first display.
10. `loadFrames(from: activeGifPath)` — if it returns `false`, call
    `showStartupErrorAndQuit(...)` and `return` immediately (lines 425-428), skipping every
    step below.
11. `applySizing()` then `renderCurrentFrame()` (lines 430-431).
12. If `config.speedMultiplierOverride` is set, clamp it into
    `Tuning.speedOverrideMin...Max` and assign to `speedMultiplier` (lines 432-434).
13. `startLoadMonitoring()`, `startGameLoop()`, `refreshMenuMetrics()` (lines 435-437).
14. Register four `NotificationCenter` observers, all on `queue: .main` (each callback wraps its
    body in `MainActor.assumeIsolated`, §4):
    - `screenObserver` — `NSApplication.didChangeScreenParametersNotification` → `applySizing()` +
      `renderCurrentFrame()`.
    - `powerStateObserver` — `.NSProcessInfoPowerStateDidChange` (Low Power Mode toggled) →
      `reevaluateSpeedForCurrentConditions()` (§12.2).
    - `thermalStateObserver` — `ProcessInfo.thermalStateDidChangeNotification` →
      `reevaluateSpeedForCurrentConditions()` (§12.2).
    - `occlusionObserver` — `NSWindow.didChangeOcclusionStateNotification` on the status button's
      window (registered only if that window exists) → `updateAnimationForOcclusion()` (§13.6).

### 9.3 `applicationWillTerminate(_:)`
Calls `stopGameLoop()` (tears down whichever of `displayLink`/`fallbackTimer` is live) and
invalidates `loadTimer`; removes every registered observer
(`screenObserver`/`powerStateObserver`/`thermalStateObserver`/`occlusionObserver`) from
`NotificationCenter.default`.

---

## 10. Menu system — structure and refresh model

### 10.1 Static structure
Built once in step 9.2.5 above; never rebuilt. Every visible menu title after that point is
mutated in place by four `refresh*` methods (never by rebuilding items).

### 10.2 `menuWillOpen(_:)` (lines 544-549, `NSMenuDelegate`)
Fired by AppKit immediately before the menu is displayed. Calls, in order:
`refreshMenuMetrics()`, `refreshPresetSelectionState()`, `refreshWidthSelectionState()`,
`refreshOverlaySelectionState()`. This is the *only* trigger for
`refreshPresetSelectionState`/`refreshWidthSelectionState`/`refreshOverlaySelectionState`
other than the direct calls made inline by the action methods that change the underlying
state (e.g. `selectWidthAuto()` calls `refreshWidthSelectionState()` itself, line 632).

### 10.3 `refreshMenuMetrics()` (lines 551-578)
- `cpuUsageItem.title` / `cpuStateItem.title`: `"warming up..."` if
  `!loadMonitor.hasSample`, else formatted from `loadMonitor.smoothedUsage` (via
  `cpuStateText(for:)`, thresholds `Tuning.cpuStateLowThreshold` /
  `cpuStateMediumThreshold`).
- `speedMultiplierItem.title`: two formats depending on
  `config.speedMultiplierOverride == nil` — auto mode shows `currentSpeedProfile()`'s label
  and min/max; fixed mode shows `(fixed)`.
- `loadAverageItem.title`: `"unavailable"` if `cachedLoadAverages == nil`, else the 3 values
  formatted `%.2f`.
- `statusItem.button?.setAccessibilityLabel(...)`: enriches the static launch-time label with live
  state — `"MenuBar Load Runner — CPU NN%, <state>"` once `loadMonitor.hasSample`, else
  `"MenuBar Load Runner — measuring CPU load"`. Because `refreshMenuMetrics()` runs on every 2s
  `sampleSystemLoad()` tick (§12) and not only on `menuWillOpen`, the VoiceOver description tracks
  current load without the menu being opened.

### 10.4 `refreshPresetSelectionState()` (lines 580-586)
A single loop over `zip(presetMenuItems, allPresets)` (relies on both arrays being built
together, same order, same length, in the `applicationDidFinishLaunching` loop, §9.2 step 5):
`item.isEnabled = FileManager.default.fileExists(atPath: preset.path)`; `item.state =
(activePreset?.key == preset.key) ? .on : .off`. Replaces what used to be 10 explicit
`isEnabled` lines + 10 explicit `state` lines, one pair per built-in path constant.

### 10.5 `refreshWidthSelectionState()` (lines 588-607)
Reads `minimumSlotsForCurrentPreset()`, `requestedWidthSlots`, `effectiveWidthSlots()`.
- `widthStatusItem.title`: if `requestedWidthSlots` is set and below the preset's minimum,
  shows `"... (requested X, min Y for preset)"`; if set and at/above minimum, shows just the
  effective count; if unset, shows `"auto (preset scale %.2fx)"`.
- `widthAutoItem.state = .on` iff `requestedWidthSlots == nil`.
- Each of `widthSlotItems` (tags 1-4): `.state = .on` iff `requestedWidthSlots != nil &&
  item.tag == effectiveWidthSlots()`.

### 10.6 `refreshOverlaySelectionState()` (lines 609-618)
If `requestedOverlayText` is set: `overlayStatusItem.title = "Overlay Text: <text> (bold|regular)"`,
`overlayClearItem.isEnabled = true`. Else: `"Overlay Text: off"`,
`overlayClearItem.isEnabled = false`.

---

## 11. Action handlers (`@objc`, menu-item targets)

| Method | Lines | Effect |
|---|---|---|
| `selectPreset(_:)` | 620-625 | tag-indexes into `allPresets`, calls `switchToGif(to: preset.path, descriptor: preset)` — single method for all 10 built-in presets, replacing 10 near-identical `selectXPreset()` methods |
| `selectWidthAuto` | 627-633 | `requestedWidthSlots = nil`; `applySizing()`; `renderCurrentFrame()`; `refreshWidthSelectionState()` |
| `selectWidthSlot(_:)` | 635-641 | `requestedWidthSlots = clamp(sender.tag, 1, 4)`; same 3 follow-up calls |
| `promptOverlayText` | 643-707 | see §11.1 |
| `clearOverlayText` | 709-715 | `requestedOverlayText = nil`; `updateRenderedFrames()`; `renderCurrentFrame()`; `refreshOverlaySelectionState()` |
| `showAbout` | 457-470 | modal `NSAlert` with static text + live speed-mode line |
| `exitApp` | 472-475 | `NSApp.terminate(nil)` |
| `sampleSystemLoad` | 525-542 | see §12 |
| `displayLinkTick(_:)` / `fallbackTimerTick` → `advanceFrames(now:)` | 857-898 | see §13 |

### 11.1 `promptOverlayText()` (lines 643-707)
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
   window was closed), returns with no state change (line 686).
4. On "Apply": `requestedOverlayBold = boldToggle.state == .on` (line 688) always happens
   first, regardless of the text field's content.
5. If the trimmed field text is empty: `requestedOverlayText = nil`, then
   `updateRenderedFrames()` + `renderCurrentFrame()` + `refreshOverlaySelectionState()`,
   return (lines 690-696).
6. If the trimmed text exceeds `Tuning.overlayMaxChars` (12): `showRuntimeError(...)` and
   return *without* changing `requestedOverlayText` (lines 698-701) — the bold-toggle change
   from step 4 is still committed even though the text change is rejected.
7. Otherwise: `requestedOverlayText = input`, then the same three follow-up calls
   (lines 703-706).

### 11.2 `switchToGif(to:descriptor:)` (lines 717-752)
Signature: `switchToGif(to path: String, descriptor: PresetDescriptor?)` — takes both an
explicit path and the resolved `PresetDescriptor` (or `nil`) for that path, called only from
`selectPreset(_:)` (line 624, always passing a non-nil descriptor for one of the 10 built-in
presets today; the `nil` case exists for a hypothetical future custom-path menu action, not
currently exercised by any call site).
1. Expands `~` in the given path; no-ops if it equals `activeGifPath` already (line 719).
2. Saves `previousPath`, `previousPreset`, `previousFrames`, `previousDurations`,
   `previousFrameIndex` (lines 721-725) — `frameAspects` is **not** saved/restored here.
3. Calls `loadFrames(from: expanded)`. On failure: restores `activeGifPath`, `activePreset`,
   `frames`, `baseDurations`, `frameIndex` from the saved values, shows a runtime error alert,
   calls `refreshPresetSelectionState()`, and returns (lines 727-736) — `frameAspects` is left
   as whatever `loadFrames` mutated it to before failing (see §14 — `loadFrames` only assigns
   `frameAspects` on full success, so in practice it is unchanged on failure, but this is a
   property of `loadFrames`'s internal ordering, not of anything `switchToGif` does).
4. On success: `activeGifPath = expanded`, `activePreset = descriptor`, `frameIndex = 0`,
   `statusItem.button?.toolTip = activeGifPath` (lines 738-741).
5. `applySizing()`, `renderCurrentFrame()`, `refreshWidthSelectionState()`,
   `refreshOverlaySelectionState()` (lines 743-746).
6. Calls `resetGameLoopTiming()` (§13.1c) — re-syncs the **running** driver's clock rather than
   tearing it down and recreating it, since the frame source changed but the display link's
   button/screen has not. (Previously this invalidated and recreated the driver on every switch.)
7. `refreshPresetSelectionState()` (line 751).

---

## 12. Load-sampling sequence — `sampleSystemLoad()` (~lines 590-605)

Invoked every `Tuning.loadSampleInterval` (2.0s) by `loadTimer` (started in
`startLoadMonitoring()`, lines 512-523, registered on `RunLoop.main` in `.common` mode).

`loadTimer` uses the classic `Timer(target: self, selector:)` form, which strongly retains `self`
while `self` retains the timer — a retain cycle. This is intentionally accepted, not a leak in
practice: the `MenuBarLoadRunnerApp` delegate lives for the entire process and only deallocates at
`NSApp.terminate`, so nothing is ever waiting to be freed. (The game-loop driver does not have this
concern — `displayLink`/`fallbackTimer` are held directly and torn down in `stopGameLoop()`, §13.1b.)

1. `cachedLoadAverages = readSystemLoadAverages()` (line 527) — always attempted,
   independent of anything below.
2. `loadMonitor.sampleUsage()` — if it returns a non-`nil` `usage`:
   - Only if `config.speedMultiplierOverride == nil` (line 530):
     - `candidate = speedMultiplier(forUsage: usage)` (line 531, see §12.1).
     - If `abs(candidate - speedMultiplier) >= Tuning.speedUpdateHysteresis` (0.08): assigns
       `speedMultiplier = candidate` and nothing else. The game-loop driver reads
       `speedMultiplier` live through the accumulator (§13.2 step 5), so the new speed takes
       effect on the next tick with no driver restart. (Previously this invalidated and
       recreated the driver on every hysteresis-crossing change — an unnecessary teardown that
       also reset `lastTickTime`/`accumulatedFrameTime`; removed with the CADisplayLink migration.)
   - If `speedMultiplierOverride` is set, `speedMultiplier` is never touched here.
   - If `usage` is `nil` (not enough samples yet), nothing in this block runs.
3. `refreshMenuMetrics()` (line 541) — always called, regardless of whether step 2 changed
   anything.

### 12.1 `speedMultiplier(forUsage:)` (lines 789-795)
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

- `isUnderPowerPressure` (a computed `Bool`): `true` when `ProcessInfo.isLowPowerModeEnabled` is on
  **or** `thermalState` is `.serious`/`.critical`. Read-only, getters only.
- When true, `speedMultiplier(forUsage:)` (§12.1) caps this app's auto speed at the midpoint of the
  active preset's range (`Tuning.constrainedSpeedCeilingFraction`). The menu's Speed Multiplier line
  appends `" [throttled: low power/thermal]"` whenever `isUnderPowerPressure` is true — i.e. it is
  keyed on the pressure state, not on whether the value actually hit the ceiling, so at low CPU
  usage (where the computed value is already below the midpoint) the suffix still shows even though
  no clamping occurred (§10.3 shows the base format).
- `reevaluateSpeedForCurrentConditions()`: recomputes `speedMultiplier` from the latest smoothed
  usage **immediately, bypassing the 2s-tick hysteresis** (guarded by `speedMultiplierOverride == nil`
  && `loadMonitor.hasSample`), then calls `refreshMenuMetrics()`. Invoked from the `powerStateObserver`
  and `thermalStateObserver` (§9.2 step 14) so the cap engages/lifts without waiting up to 2s.
- Disabled entirely in fixed-speed mode (`--speed-multiplier`), like all auto-speed logic.

### 12.3 `readSystemLoadAverages()` (lines 766-777)
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

### 13.1a `startGameLoop()` (lines 821-840)
Calls `stopGameLoop()` then `resetGameLoopTiming()`, then installs the driver:
- **macOS 14+ and `statusItem.button` non-nil**: `button.displayLink(target: self, selector:
  #selector(displayLinkTick(_:)))` → stored in `displayLink`, added to `RunLoop.main` in `.common`
  mode. The button is view-backed and lives in the status-bar window, so the link attaches and
  follows the button's screen automatically.
- **otherwise (fallback)**: `Timer(timeInterval: Tuning.gameLoopFallbackInterval /* 1/60s */,
  target: self, selector: #selector(fallbackTimerTick), repeats: true)` → stored in
  `fallbackTimer`, added to `RunLoop.main` in `.common`.

### 13.1b `stopGameLoop()` (lines 842-847)
Invalidates and nils **both** `displayLink` and `fallbackTimer` (only one is ever live, but
teardown is unconditional). Called by `startGameLoop()`, `applicationWillTerminate` (§9.3), and
`updateAnimationForOcclusion()` when the item becomes occluded (§13.6).

### 13.1c `resetGameLoopTiming()` (lines 851-855)
Sets `lastTickTime = 0` (resync sentinel — see §13.2 step 2) and `accumulatedFrameTime = 0`.
Called by `startGameLoop()` and by `switchToGif` on a frame-source change (§11.2) — the latter
re-syncs the *running* driver instead of tearing it down, since the link's button/screen is
unchanged and only the frames/durations differ (§11.2 step 6).

### 13.2 `displayLinkTick(_:)` / `fallbackTimerTick()` → `advanceFrames(now:)` (lines 857-898)
Two thin `@objc` shims select the clock source and call the shared core:
- `displayLinkTick(_ link:)` (macOS 14+) passes `link.timestamp`.
- `fallbackTimerTick()` passes `ProcessInfo.processInfo.systemUptime`.

`advanceFrames(now:)`:
1. No-ops if `baseDurations` or `renderedFrames` is empty (line 866).
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

### 13.3 `renderCurrentFrame()`
No-ops if `statusItem.button` is `nil`, `renderedFrames` is empty, or `frameIndex` is out of
bounds (guard). Sets `button.imageScaling` based on `requestedWidthSlots != nil`
(`.scaleAxesIndependently`) vs `nil` (`.scaleProportionallyUpOrDown`) — this is evaluated on
*every* frame render, not just on sizing changes (redundant with the same assignment already
made in step 9.2.3; `updateRenderedFrames()` does **not** set `imageScaling`, so this per-frame
re-assignment and the launch-time one are the only two sites). Sets
`button.image = renderedFrames[frameIndex]`.

### 13.4 `applySizing()` (lines 911-920)
No-ops if `frames` is empty. `baseSlotWidth = max(NSStatusBar.system.thickness,
Tuning.minBaseSlotWidth)`. Sets `statusItem.length` to `ceil(baseSlotWidth *
effectiveWidthSlots())` if `requestedWidthSlots != nil`, else `ceil(baseSlotWidth *
currentPresetScale())` — the product is rounded **up** to a whole point in both branches.
Always calls `updateRenderedFrames()` at the end.

### 13.5 `updateRenderedFrames()` (lines 846-909)
No-ops (sets `renderedFrames = []`) if `frames` is empty.
1. `availableHeight = max(NSStatusBar.system.thickness - Tuning.renderVerticalInset, 1)`;
   `availableWidth = max(statusItem.length - Tuning.renderHorizontalInset, 1)`.
2. `overlayText = effectiveOverlayText()` — `requestedOverlayText` trimmed, or `nil` if
   empty after trim (lines 840-844).
3. For each raw frame `i`:
   - `aspect = frameAspects[i]` if in range, else `Tuning.dogSlotScale` (used as a fallback
     numeric value here, not as a "slot scale" concept — this is a literal fallback constant
     reuse, line 860).
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
4. Assigns the full array to `renderedFrames` (line 979) — every frame is regenerated on
   every call; there is no per-frame caching/memoization across calls.

### 13.6 Occlusion pause — `updateAnimationForOcclusion()`
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

## 14. GIF decode pipeline — `loadFrames(from:)` (~lines 1109-1167)

1. `FileManager.default.fileExists(atPath:)` check; fails (returns `false`, logs to stderr)
   if absent (lines 947-950).
2. `CGImageSourceCreateWithURL` — fails if the file isn't a decodable image source
   (lines 952-955).
3. `CGImageSourceGetCount(src)` — fails if `0` (lines 957-961).
4. For each frame index `0..<count`:
   - `CGImageSourceCreateImageAtIndex` — on failure, `continue` (skip this frame silently,
     lines 971-973; does not abort the whole load).
   - `trimTransparentPadding(from:)` (§14.1) applied to the decoded `CGImage`.
   - `frameDuration(from:frameIndex:)` (§14.2) — appended to `nextDurations`.
   - Wraps the trimmed `CGImage` in an `NSImage` sized to the trimmed pixel dimensions,
     appended to `nextFrames`.
   - Aspect ratio `= width/height` (or `Tuning.dogSlotScale` if height is `0`), clamped to
     `>= Tuning.minAspect`, appended to `nextAspects`.
5. Final guard: `!nextFrames.isEmpty && nextFrames.count == nextDurations.count &&
   nextFrames.count == nextAspects.count` — since every append happens together per
   iteration (no `continue` between the three appends once past the decode-failure check),
   this guard can only fail via the `nextFrames.isEmpty` branch in practice (all three arrays
   are always appended to in lockstep after that point). Fails with a stderr message if not
   met (lines 990-997).
6. On success, assigns `frames = nextFrames`, `frameAspects = nextAspects`, `baseDurations =
   nextDurations`, returns `true` (lines 999-1002).

Note: this method never touches `renderedFrames` — callers (`applicationDidFinishLaunching`,
`switchToGif`) always follow a successful `loadFrames` call with `applySizing()` (which
internally calls `updateRenderedFrames()`).

### 14.1 `trimTransparentPadding(from:)` (lines 1005-1050)
1. Wraps the `CGImage` in an `NSBitmapImageRep`; returns the image unchanged if it has no
   alpha channel or `bitmapData` is `nil` (line 1007).
2. Returns unchanged if `width/height <= 0` or `samplesPerPixel < 4`
   (`Tuning.minAlphaPixelComponents`) (line 1013).
3. Determines the alpha byte's offset within a pixel from `image.alphaInfo`:
   `.alphaOnly/.first/.premultipliedFirst/.noneSkipFirst` → offset `0`;
   `.last/.premultipliedLast/.noneSkipLast` → offset `bytesPerPixel - 1`; any other case
   (e.g. `.none`) → returns the image unchanged (lines 1015-1023).
4. Scans every pixel; tracks the bounding box (`minX/maxX/minY/maxY`) of pixels whose alpha
   byte is `> Tuning.alphaVisibleThreshold` (3) (lines 1025-1041).
5. Returns unchanged if no pixel exceeded the threshold — the guard is `maxX >= minX && maxY >=
   minY` (both axes checked) — or if the bounding box already covers the full image.
6. Otherwise crops to the bounding box via `CGImage.cropping(to:)`, falling back to the
   original image if cropping itself fails (line 1049).

### 14.2 `frameDuration(from:frameIndex:)` (lines 1052-1064)
Reads `CGImageSourceCopyPropertiesAtIndex` → `kCGImagePropertyGIFDictionary` →
`kCGImagePropertyGIFUnclampedDelayTime`, falling back to `kCGImagePropertyGIFDelayTime`,
falling back to `Tuning.defaultGifFrameDelay` (0.1) if neither property/dictionary is
present. Final value is floored at `Tuning.minGifFrameDelay` (0.02) via `max(value, ...)`.

---

## 15. Sizing model

### 15.1 `currentPresetScale() -> CGFloat` (lines 933-935)
`activePreset?.slotScale ?? Tuning.dogSlotScale` — a direct read of the descriptor resolved
once by `switchToGif`/`init` (§8.1), rather than re-deriving identity from a path comparison
on every call. Values are the same as before: `Tuning.horseSlotScale` (1.2),
`totoroGroupSlotScale` (4.0), `totoroSlotScale` (1.25), or `dogSlotScale` (1.0) for dog/custom
(`activePreset == nil`).

### 15.2 `minimumSlotsForCurrentPreset() -> Int` (lines 928-931)
`clamp(Int(ceil(currentPresetScale())), Tuning.minWidthSlots, Tuning.maxWidthSlots)` — e.g.
`totoroGroupSlotScale = 4.0` → minimum `4` slots; `horseSlotScale = 1.2` → `ceil = 2` →
minimum `2` slots; `dogSlotScale = 1.0` → minimum `1` slot.

### 15.3 `effectiveWidthSlots() -> Int` (lines 922-926)
`clamp(requestedWidthSlots ?? minimumSlotsForCurrentPreset(), minimumSlotsForCurrentPreset(),
Tuning.maxWidthSlots)`.

---

## 16. Speed-profile model

### 16.1 `currentPresetKind() -> PresetKind` (lines 941-943)
`activePreset?.kind ?? .custom` — direct descriptor read, same pattern as §15.1. As of this
refactor, `currentPresetKind()` has no remaining internal callers (`currentSpeedProfile()`
below reads `activePreset?.speedProfile` directly instead of round-tripping through
`PresetKind`); it's kept as a small public-shaped accessor since `PresetKind` remains a
meaningful domain concept.

### 16.2 `currentSpeedProfile() -> SpeedProfile` (lines 937-939)
`activePreset?.speedProfile ?? Self.customSpeedProfile`. Each built-in preset's
`SpeedProfile` is constructed once in `init` (lines 306-310) from the same `Tuning`
`(label, min, max, responseExponent)` tuples enumerated in §5's "CPU sampling / speed
mapping" group, and stored on its `PresetDescriptor` (§8.1) — there is no longer a `switch`
over `PresetKind` computing this per call. `Self.customSpeedProfile` (lines 253-258) reuses
`dogSpeedMin`/`dogSpeedMax`/`linearSpeedCurveExponent` under the label `"custom"` — i.e. any
non-built-in GIF path (`activePreset == nil`) still gets the dog preset's numeric speed range,
only differing in the label shown in the menu.

---

## 17. Alerts / error surfaces

| Method | Lines | `alertStyle` | Triggers app exit? |
|---|---|---|---|
| `showAbout()` | 457-470 | `.informational` | no |
| `showStartupErrorAndQuit(_:)` | 497-508 | `.critical` | yes — `NSApp.terminate(nil)` after modal dismissed |
| `showRuntimeError(_:)` | 754-764 | `.warning` | no — also calls `NSSound.beep()` first |

`makeMenuAlertIcon()` (lines 477-495): looks up the `"horse-black"` entry in `allPresets` by
key (`allPresets.first(where: { $0.key == "horse-black" })?.path`, replacing the old direct
`builtInHorseBlackPath` constant reference) and loads that path as an `NSImage`, redraws it
into a fresh 48x48 `NSImage` via `lockFocus()`/`unlockFocus()`, returns `nil` if either the
lookup or the image load fails. Used as the `.icon` on all three alert types above
(conditionally, `if let icon = ...`) — i.e. every alert in the app uses the black-horse GIF
as its icon regardless of the currently active preset.

---

## 18. Cross-reference: what the launcher passes vs. what `Config` expects

| Launcher passes | `Config.parse()` consumes |
|---|---|
| The positional arg **unchanged** — a preset keyword (e.g. `horse-white`), a raw GIF path, or nothing at all | `presetOrPath` (positional, or `MENUBAR_LOAD_RUNNER_PATH` env fallback, or `Config.defaultPreset`); keyword→path resolution deferred to `init` (§9.1) |
| `--width`/`-w`, `--speed-multiplier`, `--overlay-text`, `-h`/`--help` passed through verbatim as `passthrough_args` | same flags, parsed as documented in §6.3 |
| `--foreground`/`--no-detach`/`--detach`/`--extra` — consumed by the launcher itself, never forwarded | not present in `Config` — the Swift binary has no knowledge of detach/singleton behavior; those are exclusively launcher-level concerns |

Since anti-pattern #6, the launcher no longer resolves preset keywords or supplies a default —
it forwards the positional arg verbatim, and the Swift side owns the keyword→path mapping and
the `horse-white` default. The launcher still validates none of `--width`'s value,
`--speed-multiplier`'s value, or `--overlay-text`'s length — all of that validation happens
only inside `Config.parse()` after the Swift process starts (§6.3 table).

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
- **Internal collaborator boundary**: `CPULoadMonitor` is the only sub-responsibility factored into
  its own type; it exposes a 2-method + 2-property surface (`sampleUsage()`, `smoothedUsage`,
  `hasSample`) and hides all Mach detail. `Tuning` is a pure constant namespace with no behavior.
- **Two decoupled data pipelines** meet only at `frameIndex`/`renderedFrames`: the raw-decode
  pipeline (`loadFrames` → `frames`/`frameAspects`/`baseDurations`) and the render pipeline
  (`updateRenderedFrames` → `renderedFrames`), as documented in §13–§14.

## Appendix B — Structural observations (resolved)

The duplication / dead-code / modularity observations surfaced while verifying this document
were tracked in a since-deleted TODO (`TODO-20260706-2303-antipatterns-from-design-review.md`)
and closed out on 2026-07-07. Outcomes, recorded here so the rationale survives:

**Applied** (the sections above already reflect these):
- **#1 — dead `currentPresetKind()`**: deleted (zero callers); `enum PresetKind` retained.
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
