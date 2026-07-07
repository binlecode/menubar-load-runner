# DESIGN-system.md

Ground truth for this document: `menubar-load-runner` (zsh launcher, 223 lines) and
`MenuBarLoadRunner.swift` (1228 lines). Every claim below cites the line(s) it is derived
from. This document contains no design rationale, no recommendations, and no speculation
beyond what the cited code does — it is a structural map of the code as it exists, for
resync whenever either source file changes.

---

## 1. Mission (as expressed by code, not prose)

Derived from `Config.printUsage()` (`MenuBarLoadRunner.swift:146-154`) and the CPU-driven
speed logic (`speedMultiplier(forUsage:)`, lines 860-866):

> Render a GIF, decoded from disk, as the image of one `NSStatusItem` in the macOS menu bar,
> and continuously vary the playback speed of that GIF as a function of smoothed system CPU
> usage, sampled every `Tuning.loadSampleInterval` seconds.

Fixed-speed mode (`--speed-multiplier`) is a supported deviation from the auto-speed mission:
when `config.speedMultiplierOverride != nil`, the CPU-to-speed mapping in
`sampleSystemLoad()` (line 544: `if config.speedMultiplierOverride == nil`) is skipped
entirely — `speedMultiplier` becomes a constant, clamped once at startup to
`Tuning.speedOverrideMin...Tuning.speedOverrideMax` (lines 449-451).

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
                            (bottom of MenuBarLoadRunner.swift, lines 1218-1228)
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
| 4 | `MenuBarLoadRunnerApp` | 227-1216 | `final class`, `NSObject`, conforms to `NSApplicationDelegate`, `NSMenuDelegate` |
| — | entry point | 1218-1228 | top-level `switch` on `Config.parse()` |

### 4.1 Entry point (lines 1218-1228)
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

## 8. `MenuBarLoadRunnerApp` — state inventory (lines 244-295)

All properties are `private` unless noted; all are on the single `MenuBarLoadRunnerApp`
instance created once at the bottom of the file.

**Immutable, set in `init` (lines 297-314)**
```swift
let config: Config
let builtInDogWhitePath: String
let builtInDogBlackPath: String
let builtInHorseBlackPath: String
let builtInHorseWhitePath: String
let builtInTotoroPath: String
let builtInTotoroGroupWhitePath: String
let builtInTotoroGroupBlackPath: String
let builtInTotoroWhitePath: String
let builtInTotoroBlackPath: String
let builtInRainingPath: String
```
Each `builtIn*Path` is `#filePath`'s directory + `"gifs/<name>.gif"` (lines 304-313) — i.e.
these are resolved relative to the *source file's* location, independent of the launcher's
own (separately computed) `gifs_dir` path table. Both happen to point at the same
`gifs/` directory in practice because the launcher and the Swift source live in the same
repo directory, but the two path tables are computed independently in two different
languages.

**Mutable, mutated over the app's lifetime**
```swift
var activeGifPath: String                         // init: config.gifPath; changed by switchToGif(at:)
var statusItem: NSStatusItem!                     // set once, applicationDidFinishLaunching
var infoMenu: NSMenu!                             // set once
var cpuUsageItem, loadAverageItem, cpuStateItem,
    speedMultiplierItem, widthStatusItem,
    widthMenuItem, widthAutoItem: NSMenuItem!      // set once; .title mutated by refresh*() methods
var widthSlotItems: [NSMenuItem] = []             // populated once (4 items, tags 1...4)
var overlayStatusItem, overlayMenuItem,
    overlaySetItem, overlayClearItem: NSMenuItem! // set once; mutated by refreshOverlaySelectionState()
var dogWhitePresetItem ... rainingPresetItem: NSMenuItem!  // 10 properties, set once; .state/.isEnabled mutated
var frames: [NSImage] = []                        // raw decoded GIF frames; replaced by loadFrames(from:)
var frameAspects: [CGFloat] = []                  // per-frame width/height ratio; replaced by loadFrames(from:)
var baseDurations: [TimeInterval] = []            // per-frame GIF delay (unscaled by speed); replaced by loadFrames(from:)
var frameIndex = 0                                // current playback position into frames/renderedFrames
var displayLinkTimer: Timer?                      // 60Hz game loop driver
var lastTickTime: TimeInterval = 0                // systemUptime at last gameLoopTick
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

**Nested types**
```swift
private enum PresetKind { case dog, horse, totoro, totoroGroup, raining, custom }        // line 228-235
private struct SpeedProfile { let label: String; let min, max, responseExponent: Double } // line 237-242
```

---

## 9. `MenuBarLoadRunnerApp` — lifecycle sequence

### 9.1 `init(config:)` (lines 297-314)
Stores `config`, seeds `activeGifPath = config.gifPath`, `requestedWidthSlots =
config.widthSlots`, `requestedOverlayText = config.overlayText`, and computes the 10
`builtIn*Path` constants from `#filePath`. No AppKit objects are touched here.

### 9.2 `applicationDidFinishLaunching(_:)` (lines 316-464) — exact order of operations
1. `NSApp.setActivationPolicy(.accessory)` (line 317) — no Dock icon, no app switcher entry.
2. Create `statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)`
   (line 319); `fatalError` if `.button` is `nil` (lines 320-322).
3. `button.imagePosition = .imageOnly`; `button.imageScaling` set based on whether
   `requestedWidthSlots` is `nil` (`.scaleProportionallyUpOrDown`) or set
   (`.scaleAxesIndependently`) (lines 324-325); `button.toolTip = activeGifPath` (line 326).
4. Build `infoMenu` (`NSMenu`), set `self` as its delegate (lines 328-329).
5. Append, in this exact order, to `infoMenu` (lines 331-436):
   `CPU Usage: --` → `Load Avg (1/5/15m): -- / -- / --` → `CPU State: --` →
   `Speed Multiplier: --` → `Width: --` → `Width Options` (submenu: `Auto (preset)`,
   separator, `1 slot`..`4 slots`) → `Overlay Text: --` → `Overlay Text` (submenu:
   `Set Text... (max 12)`, `Clear`) → separator → disabled `Presets` header → 10 preset
   items (`Dog (White)`, `Dog (Black)`, `Horse (Black)`, `Horse (White)`, `Totoro`,
   `Totoro (Group, White)`, `Totoro (Group, Black)`, `Totoro (White)`, `Totoro (Black)`,
   `Raining`) → separator → `About` → `Exit` (key equivalent `q`).
6. `infoMenu.items.forEach { $0.target = self }` (line 435) — sets every item's target to
   `self`, including the ones that already had `target = self` set individually and the
   disabled/no-action ones (this is a blanket overwrite, applied after individual
   `.target = self` assignments earlier in the block).
7. `infoMenu.item(withTitle: "Presets")?.isEnabled = false` (line 436) — disables the section
   header by title lookup (not by stored reference).
8. `statusItem.menu = infoMenu` (line 437).
9. `refreshPresetSelectionState()`, `refreshWidthSelectionState()`,
   `refreshOverlaySelectionState()` (lines 438-440) — populate initial `.state`/`.title`
   text before first display.
10. `loadFrames(from: activeGifPath)` — if it returns `false`, call
    `showStartupErrorAndQuit(...)` and `return` immediately (lines 442-445), skipping every
    step below.
11. `applySizing()` then `renderCurrentFrame()` (lines 447-448).
12. If `config.speedMultiplierOverride` is set, clamp it into
    `Tuning.speedOverrideMin...Max` and assign to `speedMultiplier` (lines 449-451).
13. `startLoadMonitoring()`, `startGameLoop()`, `refreshMenuMetrics()` (lines 452-454).
14. Register `screenObserver` for
    `NSApplication.didChangeScreenParametersNotification` → `applySizing()` +
    `renderCurrentFrame()` on `.main` queue (lines 456-463).

### 9.3 `applicationWillTerminate(_:)` (lines 466-472)
Invalidates `displayLinkTimer` and `loadTimer`; removes `screenObserver` from
`NotificationCenter.default` if set.

---

## 10. Menu system — structure and refresh model

### 10.1 Static structure
Built once in step 9.2.5 above; never rebuilt. Every visible menu title after that point is
mutated in place by four `refresh*` methods (never by rebuilding items).

### 10.2 `menuWillOpen(_:)` (lines 558-563, `NSMenuDelegate`)
Fired by AppKit immediately before the menu is displayed. Calls, in order:
`refreshMenuMetrics()`, `refreshPresetSelectionState()`, `refreshWidthSelectionState()`,
`refreshOverlaySelectionState()`. This is the *only* trigger for
`refreshPresetSelectionState`/`refreshWidthSelectionState`/`refreshOverlaySelectionState`
other than the direct calls made inline by the action methods that change the underlying
state (e.g. `selectWidthAuto()` calls `refreshWidthSelectionState()` itself, line 706).

### 10.3 `refreshMenuMetrics()` (lines 565-592)
- `cpuUsageItem.title` / `cpuStateItem.title`: `"warming up..."` if
  `!loadMonitor.hasSample`, else formatted from `loadMonitor.smoothedUsage` (via
  `cpuStateText(for:)`, lines 850-858, thresholds `Tuning.cpuStateLowThreshold` /
  `cpuStateMediumThreshold`).
- `speedMultiplierItem.title`: two formats depending on
  `config.speedMultiplierOverride == nil` — auto mode shows `currentSpeedProfile()`'s label
  and min/max; fixed mode shows `(fixed)`.
- `loadAverageItem.title`: `"unavailable"` if `cachedLoadAverages == nil`, else the 3 values
  formatted `%.2f`.

### 10.4 `refreshPresetSelectionState()` (lines 594-617)
For each of the 10 built-in paths: `item.isEnabled = FileManager.default.fileExists(atPath:
builtIn*Path)`; `item.state = (activeGifPath == builtIn*Path) ? .on : .off`. Both checks are
fully independent per item — no shared loop, no data table (10 explicit lines each).

### 10.5 `refreshWidthSelectionState()` (lines 619-638)
Reads `minimumSlotsForCurrentPreset()`, `requestedWidthSlots`, `effectiveWidthSlots()`.
- `widthStatusItem.title`: if `requestedWidthSlots` is set and below the preset's minimum,
  shows `"... (requested X, min Y for preset)"`; if set and at/above minimum, shows just the
  effective count; if unset, shows `"auto (preset scale %.2fx)"`.
- `widthAutoItem.state = .on` iff `requestedWidthSlots == nil`.
- Each of `widthSlotItems` (tags 1-4): `.state = .on` iff `requestedWidthSlots != nil &&
  item.tag == effectiveWidthSlots()`.

### 10.6 `refreshOverlaySelectionState()` (lines 640-649)
If `requestedOverlayText` is set: `overlayStatusItem.title = "Overlay Text: <text> (bold|regular)"`,
`overlayClearItem.isEnabled = true`. Else: `"Overlay Text: off"`,
`overlayClearItem.isEnabled = false`.

---

## 11. Action handlers (`@objc`, menu-item targets)

| Method | Lines | Effect |
|---|---|---|
| `selectDogWhitePreset` ... `selectRainingPreset` (10 methods) | 651-699 | each calls `switchToGif(at: builtIn<X>Path)` with a hardcoded constant |
| `selectWidthAuto` | 701-707 | `requestedWidthSlots = nil`; `applySizing()`; `renderCurrentFrame()`; `refreshWidthSelectionState()` |
| `selectWidthSlot(_:)` | 709-715 | `requestedWidthSlots = clamp(sender.tag, 1, 4)`; same 3 follow-up calls |
| `promptOverlayText` | 717-781 | see §11.1 |
| `clearOverlayText` | 783-789 | `requestedOverlayText = nil`; `updateRenderedFrames()`; `renderCurrentFrame()`; `refreshOverlaySelectionState()` |
| `showAbout` | 474-487 | modal `NSAlert` with static text + live speed-mode line |
| `exitApp` | 489-492 | `NSApp.terminate(nil)` |
| `sampleSystemLoad` | 539-556 | see §12 |
| `gameLoopTick` | 878-902 | see §13 |

### 11.1 `promptOverlayText()` (lines 717-781)
1. Builds an `NSAlert` with a custom `accessoryView` containing: a label (`"Overlay text"`),
   an `NSTextField` pre-filled with `requestedOverlayText ?? ""`, and an `NSButton`
   checkbox (`"Bold"`) pre-set to `requestedOverlayBold`.
2. Schedules the same focus/select-text closure three times: immediately, and after 0.03s
   and 0.12s (`DispatchQueue.main.async` / `asyncAfter`, lines 747-758).
3. `alert.runModal()` — if the result isn't `.alertFirstButtonReturn` (i.e. "Cancel" or the
   window was closed), returns with no state change (line 760).
4. On "Apply": `requestedOverlayBold = boldToggle.state == .on` (line 762) always happens
   first, regardless of the text field's content.
5. If the trimmed field text is empty: `requestedOverlayText = nil`, then
   `updateRenderedFrames()` + `renderCurrentFrame()` + `refreshOverlaySelectionState()`,
   return (lines 764-770).
6. If the trimmed text exceeds `Tuning.overlayMaxChars` (12): `showRuntimeError(...)` and
   return *without* changing `requestedOverlayText` (lines 772-775) — the bold-toggle change
   from step 4 is still committed even though the text change is rejected.
7. Otherwise: `requestedOverlayText = input`, then the same three follow-up calls
   (lines 777-780).

### 11.2 `switchToGif(at:)` (lines 791-823)
1. Expands `~` in the given path; no-ops if it equals `activeGifPath` already (line 793).
2. Saves `previousPath`, `previousFrames`, `previousDurations`, `previousFrameIndex`
   (lines 795-798) — `frameAspects` is **not** saved/restored here.
3. Calls `loadFrames(from: expanded)`. On failure: restores `activeGifPath`, `frames`,
   `baseDurations`, `frameIndex` from the saved values, shows a runtime error alert, calls
   `refreshPresetSelectionState()`, and returns (lines 800-808) — `frameAspects` is left as
   whatever `loadFrames` mutated it to before failing (see §14 — `loadFrames` only assigns
   `frameAspects` on full success, so in practice it is unchanged on failure, but this is a
   property of `loadFrames`'s internal ordering, not of anything `switchToGif` does).
4. On success: `activeGifPath = expanded`, `frameIndex = 0`,
   `statusItem.button?.toolTip = activeGifPath` (lines 810-812).
5. `applySizing()`, `renderCurrentFrame()`, `refreshWidthSelectionState()`,
   `refreshOverlaySelectionState()` (lines 814-817).
6. Invalidates and discards `displayLinkTimer`, then `startGameLoop()` (lines 819-821) — the
   game loop is fully restarted (resetting `lastTickTime`/`accumulatedFrameTime`) on every
   preset/GIF switch.
7. `refreshPresetSelectionState()` (line 822).

---

## 12. Load-sampling sequence — `sampleSystemLoad()` (lines 539-556)

Invoked every `Tuning.loadSampleInterval` (2.0s) by `loadTimer` (started in
`startLoadMonitoring()`, lines 526-537, registered on `RunLoop.main` in `.common` mode).

1. `cachedLoadAverages = readSystemLoadAverages()` (line 541) — always attempted,
   independent of anything below.
2. `loadMonitor.sampleUsage()` — if it returns a non-`nil` `usage`:
   - Only if `config.speedMultiplierOverride == nil` (line 544):
     - `candidate = speedMultiplier(forUsage: usage)` (line 545, see §12.1).
     - If `abs(candidate - speedMultiplier) >= Tuning.speedUpdateHysteresis` (0.08, line
       546): `speedMultiplier = candidate`; invalidate `displayLinkTimer` and set it to
       `nil`; call `startGameLoop()` (lines 547-551) — i.e. every hysteresis-crossing speed
       change fully restarts the 60Hz timer (resets `lastTickTime`,
       `accumulatedFrameTime = 0`), it does not just update a live-read variable in place
       (even though `gameLoopTick` already reads `speedMultiplier` live and would not
       strictly need a timer restart to pick up the new value).
   - If `speedMultiplierOverride` is set, `speedMultiplier` is never touched here.
   - If `usage` is `nil` (not enough samples yet), nothing in this block runs.
3. `refreshMenuMetrics()` (line 555) — always called, regardless of whether step 2 changed
   anything.

### 12.1 `speedMultiplier(forUsage:)` (lines 860-866)
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

### 12.2 `readSystemLoadAverages()` (lines 837-848)
Calls `getloadavg(&samples, 3)` (POSIX API) into a 3-element buffer. Returns `nil` if the
call returns fewer than 3 samples; otherwise returns the tuple indexed by
`Tuning.loadAverage1mIndex/5mIndex/15mIndex` (`0/1/2`).

---

## 13. Rendering / game-loop sequence

### 13.1 `startGameLoop()` (lines 868-876)
Invalidates any existing `displayLinkTimer`; resets `lastTickTime =
ProcessInfo.processInfo.systemUptime`, `accumulatedFrameTime = 0`; creates a new
`Timer(timeInterval: 1.0/60.0, target: self, selector: #selector(gameLoopTick), repeats:
true)`, added to `RunLoop.main` in `.common` mode.

### 13.2 `gameLoopTick()` (lines 878-902)
1. No-ops if `baseDurations` or `renderedFrames` is empty (line 879).
2. `delta = now - lastTickTime`; `lastTickTime = now`; `accumulatedFrameTime += delta`
   (lines 880-884).
3. Loop: while `accumulatedFrameTime >= requiredDelay` (where `requiredDelay =
   max(baseDurations[frameIndex] / speedMultiplier, Tuning.minGifFrameDelay)`):
   subtract `requiredDelay` from `accumulatedFrameTime`, advance
   `frameIndex = (frameIndex + 1) % baseDurations.count`, set `advanced = true`
   (lines 887-897) — this loop can advance multiple frames in a single 1/60s tick if the
   speed multiplier is high enough that several frame durations fit inside one accumulated
   delta.
4. If any advance happened, call `renderCurrentFrame()` (lines 899-901) — a tick with no
   advance does not touch the displayed image at all.

### 13.3 `renderCurrentFrame()` (lines 904-909)
No-ops if `statusItem.button` is `nil`, `renderedFrames` is empty, or `frameIndex` is out of
bounds (line 905 guard). Sets `button.imageScaling` based on `requestedWidthSlots != nil`
(`.scaleAxesIndependently`) vs `nil` (`.scaleProportionallyUpOrDown`) — this is evaluated on
*every* frame render, not just on sizing changes (redundant with the same assignment already
made in step 9.2.3 and in `updateRenderedFrames`'s sizing branch, but not otherwise cached).
Sets `button.image = renderedFrames[frameIndex]`.

### 13.4 `applySizing()` (lines 982-991)
No-ops if `frames` is empty. `baseSlotWidth = max(NSStatusBar.system.thickness,
Tuning.minBaseSlotWidth)`. Sets `statusItem.length` to `baseSlotWidth *
effectiveWidthSlots()` if `requestedWidthSlots != nil`, else `baseSlotWidth *
currentPresetScale()`. Always calls `updateRenderedFrames()` at the end.

### 13.5 `updateRenderedFrames()` (lines 917-980)
No-ops (sets `renderedFrames = []`) if `frames` is empty.
1. `availableHeight = max(NSStatusBar.system.thickness - Tuning.renderVerticalInset, 1)`;
   `availableWidth = max(statusItem.length - Tuning.renderHorizontalInset, 1)`.
2. `overlayText = effectiveOverlayText()` — `requestedOverlayText` trimmed, or `nil` if
   empty after trim (lines 911-915).
3. For each raw frame `i`:
   - `aspect = frameAspects[i]` if in range, else `Tuning.dogSlotScale` (used as a fallback
     numeric value here, not as a "slot scale" concept — this is a literal fallback constant
     reuse, line 931).
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

## 14. GIF decode pipeline — `loadFrames(from:)` (lines 1096-1154)

1. `FileManager.default.fileExists(atPath:)` check; fails (returns `false`, logs to stderr)
   if absent (lines 1098-1101).
2. `CGImageSourceCreateWithURL` — fails if the file isn't a decodable image source
   (lines 1103-1106).
3. `CGImageSourceGetCount(src)` — fails if `0` (lines 1108-1112).
4. For each frame index `0..<count`:
   - `CGImageSourceCreateImageAtIndex` — on failure, `continue` (skip this frame silently,
     line 1122-1124; does not abort the whole load).
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
   met (lines 1141-1148).
6. On success, assigns `frames = nextFrames`, `frameAspects = nextAspects`, `baseDurations =
   nextDurations`, returns `true` (lines 1150-1153).

Note: this method never touches `renderedFrames` — callers (`applicationDidFinishLaunching`,
`switchToGif`) always follow a successful `loadFrames` call with `applySizing()` (which
internally calls `updateRenderedFrames()`).

### 14.1 `trimTransparentPadding(from:)` (lines 1156-1201)
1. Wraps the `CGImage` in an `NSBitmapImageRep`; returns the image unchanged if it has no
   alpha channel or `bitmapData` is `nil` (line 1158).
2. Returns unchanged if `width/height <= 0` or `samplesPerPixel < 4`
   (`Tuning.minAlphaPixelComponents`) (line 1164).
3. Determines the alpha byte's offset within a pixel from `image.alphaInfo`:
   `.alphaOnly/.first/.premultipliedFirst/.noneSkipFirst` → offset `0`;
   `.last/.premultipliedLast/.noneSkipLast` → offset `bytesPerPixel - 1`; any other case
   (e.g. `.none`) → returns the image unchanged (lines 1166-1174).
4. Scans every pixel; tracks the bounding box (`minX/maxX/minY/maxY`) of pixels whose alpha
   byte is `> Tuning.alphaVisibleThreshold` (3) (lines 1176-1192).
5. Returns unchanged if no pixel exceeded the threshold (`maxX < minX`, line 1194) or if the
   bounding box already covers the full image (line 1195-1197).
6. Otherwise crops to the bounding box via `CGImage.cropping(to:)`, falling back to the
   original image if cropping itself fails (line 1200).

### 14.2 `frameDuration(from:frameIndex:)` (lines 1203-1215)
Reads `CGImageSourceCopyPropertiesAtIndex` → `kCGImagePropertyGIFDictionary` →
`kCGImagePropertyGIFUnclampedDelayTime`, falling back to `kCGImagePropertyGIFDelayTime`,
falling back to `Tuning.defaultGifFrameDelay` (0.1) if neither property/dictionary is
present. Final value is floored at `Tuning.minGifFrameDelay` (0.02) via `max(value, ...)`.

---

## 15. Sizing model

### 15.1 `currentPresetScale() -> CGFloat` (lines 1004-1021)
String-equality chain against the 10 `builtIn*Path` constants, returning one of
`Tuning.horseSlotScale` (1.2), `totoroGroupSlotScale` (4.0), `totoroSlotScale` (1.25),
`rainingSlotScale` (1.15), or the fallthrough `dogSlotScale` (1.0) for
dog/custom/anything-unmatched.

### 15.2 `minimumSlotsForCurrentPreset() -> Int` (lines 999-1002)
`clamp(Int(ceil(currentPresetScale())), Tuning.minWidthSlots, Tuning.maxWidthSlots)` — e.g.
`totoroGroupSlotScale = 4.0` → minimum `4` slots; `horseSlotScale = 1.2` → `ceil = 2` →
minimum `2` slots; `dogSlotScale = 1.0` → minimum `1` slot.

### 15.3 `effectiveWidthSlots() -> Int` (lines 993-997)
`clamp(requestedWidthSlots ?? minimumSlotsForCurrentPreset(), minimumSlotsForCurrentPreset(),
Tuning.maxWidthSlots)`.

---

## 16. Speed-profile model

### 16.1 `currentPresetKind() -> PresetKind` (lines 1027-1047)
String-equality chain, same style as §15.1, distinguishing `.horse`, `.totoroGroup`,
`.totoro`, `.raining`, `.dog` (dog-white/dog-black only), else `.custom`.

### 16.2 `speedProfile(for:) -> SpeedProfile` (lines 1049-1094)
Exhaustive `switch` over `PresetKind`, returning the `(label, min, max, responseExponent)`
tuples enumerated in §5's "CPU sampling / speed mapping" group. `.custom` reuses
`dogSpeedMin`/`dogSpeedMax`/`linearSpeedCurveExponent` under the label `"custom"` — i.e. any
non-built-in GIF path gets the dog preset's numeric speed range, only differing in the label
shown in the menu.

---

## 17. Alerts / error surfaces

| Method | Lines | `alertStyle` | Triggers app exit? |
|---|---|---|---|
| `showAbout()` | 474-487 | `.informational` | no |
| `showStartupErrorAndQuit(_:)` | 511-522 | `.critical` | yes — `NSApp.terminate(nil)` after modal dismissed |
| `showRuntimeError(_:)` | 825-835 | `.warning` | no — also calls `NSSound.beep()` first |

`makeMenuAlertIcon()` (lines 494-509): loads `builtInHorseBlackPath` as an `NSImage`,
redraws it into a fresh 48x48 `NSImage` via `lockFocus()`/`unlockFocus()`, returns `nil` if
the source image can't be loaded. Used as the `.icon` on all three alert types above
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
