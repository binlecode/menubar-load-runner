# DESIGN-system.md

Ground truth for this document: `menubar-load-runner` (zsh launcher, 223 lines) and
`MenuBarLoadRunner.swift` (1077 lines). Every claim below cites the line(s) it is derived
from. This document contains no design rationale, no recommendations, and no speculation
beyond what the cited code does — it is a structural map of the code as it exists, for
resync whenever either source file changes.

---

## 1. Mission (as expressed by code, not prose)

Derived from `Config.printUsage()` (`MenuBarLoadRunner.swift:146-154`) and the CPU-driven
speed logic (`speedMultiplier(forUsage:)`, lines 789-795):

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
          ├── parses CLI args into: launch_detached, allow_extra, passthrough_args (lines 107-124)
          ├── maps a preset keyword (or none) to an absolute .gif path (lines 127-179)
          ├── decides swiftc vs swift execution (lines 181-193):
          │      - if MenuBarLoadRunner binary missing or older than MenuBarLoadRunner.swift:
          │            try `swiftc -O` to (re)build the binary
          │            on swiftc failure, fall back to `swift -module-cache-path ... <src>` (interpreted)
          │      - else: run the existing compiled binary directly
          ├── enforces a singleton via `pgrep -f "MenuBarLoadRunner.*\.gif"` unless --extra (lines 196-205)
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

---

## 3. Launcher module (`menubar-load-runner`)

### 3.1 `resolve_script_dir()` (lines 6-26)
Resolves the script's own real directory by following symlinks (`readlink` loop, lines
19-23), using zsh's `${(%):-%x}` expansion to get its own path (line 9), falling back to
`command -v` if invoked by bare name without a `/` in it (lines 11-17).

### 3.2 `print_help()` (lines 28-75)
Static text block. Lists 11 preset keywords (`dog-white`, `dog-black`, `horse-black`,
`horse`, `horse-white`, `totoro`, `totoro-group-white`, `totoro-group-black`, `totoro-white`,
`totoro-black`, `raining`) and 7 flags (`--width`, `--speed-multiplier`, `--overlay-text`,
`--foreground`/`--no-detach`, `--detach`, `--extra`, `-h`/`--help`).

### 3.3 `main()` (lines 77-222)

**Preflight** (lines 78-81): exits 127 if `swift` is not on `PATH`.

**Path table** (lines 92-105): builds 10 absolute GIF paths from `$script_dir/gifs/`, plus
`default_gif="$horse_white_gif"`.

**Flag scan** (lines 107-124): single pass over `$@`; `--foreground`/`--no-detach` set
`launch_detached=0`; `--detach` sets `launch_detached=1`; `--extra` sets `allow_extra=1`;
everything else is pushed into `passthrough_args` unchanged (including unrecognized flags —
the launcher does not validate them; that is left to `Config.parse()` in the Swift binary).

**Preset-keyword-to-path resolution** (lines 127-179):
- No positional args at all → `default_gif` (`horse-white`).
- First remaining arg matches `-h`/`--help` → print help, exit 0.
- First remaining arg matches one of the 10 preset keywords → replaced in-place with the
  corresponding absolute `.gif` path (e.g. `horse-black|horse` both map to
  `$horse_black_gif`, line 143-145 — `horse` is a bash/zsh-level alias for `horse-black`,
  not a concept known to the Swift binary).
- First remaining arg starts with `-` (any other flag) → `default_gif` is prepended, so the
  flag is passed straight through to the Swift binary as its first CLI arg after the GIF
  path (lines 175-177).
- Any other first arg (i.e. a raw path) is left untouched and passed straight through as the
  positional GIF-path argument to the Swift binary.

**Build-or-reuse decision** (lines 181-193): compares mtimes of
`MenuBarLoadRunner.swift` and `MenuBarLoadRunner` (the compiled binary); rebuilds with
`swiftc -O` only when missing or stale; falls back to interpreted `swift` on compile failure.

**Singleton enforcement** (lines 195-205): `pgrep -f "MenuBarLoadRunner.*\.gif"` — matches
any process whose command line contains `MenuBarLoadRunner` followed later by `.gif`
(matches both the compiled-binary and interpreted-`swift` invocation forms, since both carry
the GIF path as an argument). If any PID is found and `--extra` was not passed, the launcher
prints an error to stderr and exits 1 without ever invoking the Swift process.

**Launch** (lines 207-219):
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
| 1 | `Tuning` | 6-58 | `enum` (namespace of `static let` constants only) |
| 2 | `Config` | 60-155 | `struct` (CLI/env parsing + usage text) |
| 3 | `CPULoadMonitor` | 157-225 | `final class` (CPU sampling) |
| 4 | `MenuBarLoadRunnerApp` | 227-1065 | `final class`, `NSObject`, conforms to `NSApplicationDelegate`, `NSMenuDelegate` |
| — | entry point | 1067-1077 | top-level `switch` on `Config.parse()` |

### 4.1 Entry point (lines 1067-1077)
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

## 5. `Tuning` — constant inventory (lines 6-58)

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
- `cpuStateLowThreshold: Double = 0.30`
- `cpuStateMediumThreshold: Double = 0.70`
- `dogSpeedMin/Max: Double = 0.5 / 2.5`
- `horseSpeedMin/Max: Double = 0.45 / 2.3`
- `totoroSpeedMin/Max: Double = 0.5 / 2.6`
- `totoroGroupSpeedMin/Max: Double = 0.2 / 2.0`
- `rainingSpeedMin/Max: Double = 0.15 / 4.25`
- `linearSpeedCurveExponent: Double = 1.0`
- `rainingSpeedCurveExponent: Double = 2.6`
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
- `rainingSlotScale: CGFloat = 1.15`
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

## 6. `Config` — CLI/env interface (lines 60-155)

### 6.1 Fields (lines 66-69)
```swift
let gifPath: String                        // always non-empty, tilde-expanded
let widthSlots: Int?                        // nil = auto; else 1...4
let speedMultiplierOverride: Double?        // nil = auto (CPU-driven); else fixed, > 0
let overlayText: String?                    // nil = no overlay; else 1...12 trimmed chars
```

### 6.2 `ParseResult` (lines 61-64)
```swift
enum ParseResult { case config(Config); case help }
```
`Config.parse() -> ParseResult?` — `nil` return means a parse error already reported to
stderr (usage already printed at the failing call site).

### 6.3 Argument grammar (lines 71-144)
Single forward pass over `CommandLine.arguments.dropFirst()` via a manual iterator
(`iterator.next()` consumes the flag's value token, so `--width 2` is two consumed tokens):

| Token(s) | Effect | Validation | Lines |
|---|---|---|---|
| `--help`, `-h` | prints usage, returns `.help` | none | 81-83 |
| `--width`, `-w` | sets `widthSlots` | next token must parse as `Int` in `1...4` | 84-94 |
| `--speed-multiplier` | sets `speedMultiplierOverride` | next token must parse as `Double > 0` | 95-101 |
| `--overlay-text` | sets `overlayText` | next token, trimmed, must be `1...12` chars after trim | 102-114 |
| anything else, first occurrence | sets `gifPath` | — | 115-118 |
| anything else, second+ occurrence | fatal parse error ("Unexpected argument") | — | 119-122 |

**GIF path resolution** (lines 126-138): if no positional arg was consumed, falls back to
`ProcessInfo.processInfo.environment["MENUBAR_LOAD_RUNNER_PATH"]`; if still `nil`/empty,
parse fails ("Missing GIF path"). The resolved path is passed through
`NSString(string:).expandingTildeInPath` before being stored (line 138) — this is the only
normalization applied; no symlink resolution, no `standardizingPath`.

### 6.4 `printUsage()` (lines 146-154)
Reads `MENUBAR_LOAD_RUNNER_BIN_NAME` env var for the binary name shown in usage text,
falling back to `CommandLine.arguments[0]`'s last path component (lines 147-148). All
speed-range numbers shown are read live from `Tuning` (line 153), so this text cannot drift
from the actual `Tuning` values.

---

## 7. `CPULoadMonitor` — CPU sampling module (lines 157-225)

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

---

## 8. `MenuBarLoadRunnerApp` — state inventory (lines 228-294)

All properties are `private` unless noted; all are on the single `MenuBarLoadRunnerApp`
instance created once at the bottom of the file.

**Nested types**
```swift
private enum PresetKind { case dog, horse, totoro, totoroGroup, raining, custom }          // lines 228-235
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
`resolvedPath(_:)` helper (lines 301-304) — i.e. still relative to the *source file's*
location, independent of the launcher's own (separately computed) `gifs_dir` path table. Both
happen to point at the same `gifs/` directory in practice because the launcher and the Swift
source live in the same repo directory, but the two path tables are computed independently in
two different languages.

**Mutable, mutated over the app's lifetime**
```swift
var activePreset: PresetDescriptor?               // init: allPresets.first { $0.path == config.gifPath }; changed by switchToGif(to:descriptor:)
var activeGifPath: String                         // init: config.gifPath; changed by switchToGif(to:descriptor:)
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
```

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
| 9 | `raining` | Raining | `.raining` | 1.15 | raining, 0.15, 4.25, 2.6 (only non-linear curve) |

A custom/user-supplied GIF whose path matches none of these leaves `activePreset == nil`;
every accessor (§15, §16) falls back to `.custom`/`Tuning.dogSlotScale`/`Self.customSpeedProfile`
in that case. `PresetDescriptor.key` is an internal Swift identifier only (used for
`refreshPresetSelectionState`'s equality check and `makeMenuAlertIcon`'s lookup) — it is not
threaded through the CLI; the launcher still resolves preset keywords to absolute paths on its
own before the Swift binary starts (§18).

---

## 9. `MenuBarLoadRunnerApp` — lifecycle sequence

### 9.1 `init(config:)` (lines 296-328)
Stores `config`, `requestedWidthSlots = config.widthSlots`, `requestedOverlayText =
config.overlayText`. Builds `allPresets` (10 `PresetDescriptor` literals, §8.1) via a local
`resolvedPath(_:)` helper closing over `scriptDirURL` (lines 301-323), then resolves
`activeGifPath = config.gifPath` and `activePreset = allPresets.first { $0.path ==
config.gifPath }` (lines 326-327) — `activePreset` is `nil` here if `config.gifPath` doesn't
match any built-in preset (custom GIF case). No AppKit objects are touched here.

### 9.2 `applicationDidFinishLaunching(_:)` (lines 330-447) — exact order of operations
1. `NSApp.setActivationPolicy(.accessory)` (line 331) — no Dock icon, no app switcher entry.
2. Create `statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)`
   (line 333); `fatalError` if `.button` is `nil` (lines 334-336).
3. `button.imagePosition = .imageOnly`; `button.imageScaling` set based on whether
   `requestedWidthSlots` is `nil` (`.scaleProportionallyUpOrDown`) or set
   (`.scaleAxesIndependently`) (lines 338-339); `button.toolTip = activeGifPath` (line 340).
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
14. Register `screenObserver` for
    `NSApplication.didChangeScreenParametersNotification` → `applySizing()` +
    `renderCurrentFrame()` on `.main` queue (lines 439-446).

### 9.3 `applicationWillTerminate(_:)` (lines 449-455)
Calls `stopGameLoop()` (tears down whichever of `displayLink`/`fallbackTimer` is live) and
invalidates `loadTimer`; removes `screenObserver` from `NotificationCenter.default` if set.

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
  `cpuStateText(for:)`, lines 779-787, thresholds `Tuning.cpuStateLowThreshold` /
  `cpuStateMediumThreshold`).
- `speedMultiplierItem.title`: two formats depending on
  `config.speedMultiplierOverride == nil` — auto mode shows `currentSpeedProfile()`'s label
  and min/max; fixed mode shows `(fixed)`.
- `loadAverageItem.title`: `"unavailable"` if `cachedLoadAverages == nil`, else the 3 values
  formatted `%.2f`.

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
2. Schedules the same focus/select-text closure three times: immediately, and after 0.03s
   and 0.12s (`DispatchQueue.main.async` / `asyncAfter`, lines 673-684).
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

## 12. Load-sampling sequence — `sampleSystemLoad()` (lines 525-542)

Invoked every `Tuning.loadSampleInterval` (2.0s) by `loadTimer` (started in
`startLoadMonitoring()`, lines 512-523, registered on `RunLoop.main` in `.common` mode).

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
let value = profile.min + ((profile.max - profile.min) * curvedUsage)
return min(max(value, profile.min), profile.max)   // redundant clamp given the formula above, but present in source
```
`profile.responseExponent` is `1.0` (linear) for every preset except `raining`, which uses
`2.6` (`Tuning.rainingSpeedCurveExponent`) — i.e. `raining`'s speed stays near `min` for most
of the CPU range and only accelerates sharply near `usage = 1.0`.

### 12.2 `readSystemLoadAverages()` (lines 766-777)
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
teardown is unconditional). Called by `startGameLoop()` and `applicationWillTerminate` (§11.2).

### 13.1c `resetGameLoopTiming()` (lines 851-855)
Sets `lastTickTime = 0` (resync sentinel — see §13.2 step 2) and `accumulatedFrameTime = 0`.
Called by `startGameLoop()` and by `switchToGif` on a frame-source change (§12.1) — the latter
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

### 13.3 `renderCurrentFrame()` (lines 833-838)
No-ops if `statusItem.button` is `nil`, `renderedFrames` is empty, or `frameIndex` is out of
bounds (line 834 guard). Sets `button.imageScaling` based on `requestedWidthSlots != nil`
(`.scaleAxesIndependently`) vs `nil` (`.scaleProportionallyUpOrDown`) — this is evaluated on
*every* frame render, not just on sizing changes (redundant with the same assignment already
made in step 9.2.3 and in `updateRenderedFrames`'s sizing branch, but not otherwise cached).
Sets `button.image = renderedFrames[frameIndex]`.

### 13.4 `applySizing()` (lines 911-920)
No-ops if `frames` is empty. `baseSlotWidth = max(NSStatusBar.system.thickness,
Tuning.minBaseSlotWidth)`. Sets `statusItem.length` to `baseSlotWidth *
effectiveWidthSlots()` if `requestedWidthSlots != nil`, else `baseSlotWidth *
currentPresetScale()`. Always calls `updateRenderedFrames()` at the end.

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

---

## 14. GIF decode pipeline — `loadFrames(from:)` (lines 945-1003)

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
5. Returns unchanged if no pixel exceeded the threshold (`maxX < minX`, line 1043) or if the
   bounding box already covers the full image (lines 1044-1046).
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
`totoroGroupSlotScale` (4.0), `totoroSlotScale` (1.25), `rainingSlotScale` (1.15), or
`dogSlotScale` (1.0) for dog/custom (`activePreset == nil`).

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
| Resolved absolute `.gif` path (from preset keyword or passthrough) as first positional arg, OR nothing (falls back to `MENUBAR_LOAD_RUNNER_PATH`) | `gifPath` (positional or env fallback) |
| `--width`/`-w`, `--speed-multiplier`, `--overlay-text`, `-h`/`--help` passed through verbatim as `passthrough_args` | same flags, parsed as documented in §6.3 |
| `--foreground`/`--no-detach`/`--detach`/`--extra` — consumed by the launcher itself, never forwarded | not present in `Config` — the Swift binary has no knowledge of detach/singleton behavior; those are exclusively launcher-level concerns |

The launcher does not validate `--width`'s value, `--speed-multiplier`'s value, or
`--overlay-text`'s length — all of that validation happens only inside `Config.parse()`
after the Swift process starts (§6.3 table).
