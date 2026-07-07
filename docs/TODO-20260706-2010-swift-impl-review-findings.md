# TODO-001: Swift impl + README review findings

Source: manual review of `MenuBarLoadRunner.swift` (1228 lines) against 2026 Swift/AppKit
frontier practice, and `README.md` against the design/impl documented in `CLAUDE.md`.
Date: 2026-07-06.

Ranked by relevance to the app's core mission: accurately and *cheaply* reflecting system
load via a menu bar animation.

---

## 1. Preset identity is stringly-typed and duplicated across 6+ call sites

**Status: RESOLVED (2026-07-06).** Implemented substantially as proposed below: a single
`PresetDescriptor` struct + `allPresets: [PresetDescriptor]` array (built once in `init`) is
now the source of truth for preset key/menu title/path/kind/slot scale/speed profile. The 10
`builtIn*Path` constants, 10 `NSMenuItem!` properties, 10 `@objc selectXPreset()` methods, and
the `speedProfile(for:)` switch are gone; `currentPresetScale()`/`currentPresetKind()`/
`currentSpeedProfile()` are now one-line reads of `activePreset`, resolved once per selection
in `switchToGif(to:descriptor:)` rather than re-derived from a path string on every call.
`refreshPresetSelectionState()` and the menu-construction block in
`applicationDidFinishLaunching` are now loops over `allPresets`/`presetMenuItems`. See
`docs/DESIGN-system.md` §8.1, §9, §10.4, §11.2, §15, §16 for the current ground-truth
structure. `CLAUDE.md`'s "Adding a new built-in preset" checklist was updated to match (step 3
collapses to "add one `PresetDescriptor` entry"). Out of scope (unchanged): the shell
launcher's own independent preset-name-to-path map.

**Where**: `MenuBarLoadRunner.swift`
- Path constants: `builtInDogWhitePath` ... `builtInRainingPath` (lines 245-254)
- Menu item properties + wiring: lines 270-279, 392-430
- `refreshPresetSelectionState()`: lines 594-617
- `currentPresetScale()`: lines 1004-1021
- `currentPresetKind()`: lines 1027-1047
- `speedProfile(for:)`: lines 1049-1094

**Issue**: There is no single source of truth for "what is a preset." Each of the functions
above independently re-derives preset identity by comparing `activeGifPath` (a `String`)
against ten `builtIn*Path` constants. Adding a preset requires touching all of these in
lockstep — which is exactly why `CLAUDE.md`'s "Adding a new built-in preset" section is a
4-step manual checklist instead of "add one entry." This is a data-modeling smell, not just
verbosity:
- It's easy to update one switch/if-chain and forget another (compiles fine, wrong behavior
  at runtime — e.g. forgetting to add a case to `currentPresetScale()` silently falls
  through to `dogSlotScale`).
- Preset identity is inferred *after the fact* from a path string every time
  `refreshPresetSelectionState()`/`currentPresetKind()` runs, rather than being known
  directly at the moment the user picked it (`switchToGif(at:)` already knows exactly which
  preset was requested but throws that information away and re-derives it from the path).
- String-based identity is fragile: a custom GIF path that happens to normalize to the same
  string as a built-in path (e.g. via a symlink, or a relative path that resolves to the same
  file) would be misclassified as that built-in preset.

**Fix proposal**:
1. Define one struct as the single source of truth:
   ```swift
   private struct PresetDescriptor {
       let key: String            // e.g. "dog-white", used by CLI/launcher matching
       let menuTitle: String      // e.g. "Dog (White)"
       let gifRelativePath: String // e.g. "gifs/running-dog-white.gif"
       let kind: PresetKind
       let slotScale: CGFloat
       let speedProfile: SpeedProfile
   }
   ```
2. Build a single `static let allPresets: [PresetDescriptor]` array (order = menu order).
3. Resolve each descriptor's absolute path once in `init` from `scriptDirURL`, same as today,
   but store `[PresetDescriptor: String]` (or just keep `path` on the descriptor).
4. Replace `dogWhitePresetItem`/`dogBlackPresetItem`/... (10 stored `NSMenuItem!` properties)
   with a single `[NSMenuItem]` built in a loop over `allPresets`, using `item.tag` (index
   into `allPresets`) or an associated-object/dictionary to map menu item -> descriptor.
5. Replace the 10 `@objc selectXPreset()` methods with **one** `@objc selectPreset(_ sender:
   NSMenuItem)` that looks up `allPresets[sender.tag]` and calls
   `switchToGif(descriptor:)`.
6. Change `switchToGif` to take the `PresetDescriptor` (or `nil` for a fully custom path) and
   store the resolved descriptor directly on `self` (e.g. `private var activePreset:
   PresetDescriptor?`) instead of re-deriving kind/scale/speed from `activeGifPath` string
   comparisons every refresh. `currentPresetKind()`, `currentPresetScale()`,
   `currentSpeedProfile()` all become trivial reads of `activePreset?.kind ?? .custom`, etc.
7. `refreshPresetSelectionState()` becomes a loop: `for (item, descriptor) in
   zip(presetMenuItems, allPresets) { item.isEnabled = fileExists; item.state = descriptor.key
   == activePreset?.key ? .on : .off }`.

**Net effect**: adding a preset becomes "add one entry to `allPresets` + drop the GIF in
`gifs/`" — no more 4-step checklist, and CLAUDE.md's "touch all of these together" warning
becomes unnecessary because there's only one place to touch.

**Risk/cost**: Medium-sized refactor (~150-200 lines touched), no behavior change intended.
Should be done as its own commit with manual smoke-testing of every preset + custom GIF path
before/after.

---

## 2. No Swift 6 concurrency posture

**Status: RESOLVED (2026-07-06).** Both `CPULoadMonitor` and `MenuBarLoadRunnerApp` are now
annotated `@MainActor`, and the launcher (`menubar-load-runner`) builds with
`swiftc -O -strict-concurrency=complete` (interpreted fallback: `swift -strict-concurrency=complete`),
verified to be accepted by the interpreter. Chose Swift 5 mode + `-strict-concurrency=complete`
(not `-swift-version 6`) so future violations surface as warnings, not hard build breaks. Adding
`@MainActor` took strict-concurrency diagnostics from 120 → 0: the only two residual sites were the
screen-parameters observer closure (now wrapped in `MainActor.assumeIsolated`, safe because it's
registered with `queue: .main`) and the overlay focus hack — the latter fixed together with item #7.
The `@objc`/`Timer(target:selector:)` callbacks produced zero diagnostics, so this did NOT require
the item #8 closure-based-timer refactor. `CLAUDE.md`'s build commands were updated to include the
flag.

**Where**: Whole file, especially `MenuBarLoadRunnerApp` (line 227) and `CPULoadMonitor`
(line 157).

**Issue**: Every mutable stored property is implicitly main-thread-only (driven by
`Timer`/`RunLoop.main`/`NotificationCenter` on `.main` queue), but nothing is annotated
`@MainActor`, and the build command (`swiftc -O MenuBarLoadRunner.swift -o
MenuBarLoadRunner`, per the launcher script / CLAUDE.md) doesn't opt into Swift 6 language
mode or strict concurrency checking. This works today only because every call path happens to
originate on the main thread — there's no compiler-enforced guarantee of that as the code
evolves.

**Fix proposal**:
1. Add `@MainActor` to `final class MenuBarLoadRunnerApp` (line 227) and `final class
   CPULoadMonitor` (line 157).
2. Update the build invocation (in the `menubar-load-runner` launcher script, wherever
   `swiftc -O` is called) to add `-swift-version 6` (or `-strict-concurrency=complete` if
   staying on Swift 5 mode for now) and fix any diagnostics that surface.
3. Re-verify the `swift <file>` interpreted fallback path still works under the same flags,
   or explicitly document that the fallback runs in relaxed concurrency mode.

**Risk/cost**: Low — this is expected to be a no-op behaviorally; the value is compiler-
enforced protection against future data races as the file grows. Should surface zero or very
few diagnostics given current code is already single-threaded in practice.

---

## 3. Animation driven by a polling `Timer`, not `CADisplayLink`

**Status: RESOLVED (2026-07-06).** Migrated the game loop to `CADisplayLink` via
`NSView.displayLink(target:selector:)` on the status item button (macOS 14+), with a 60 Hz
`Timer` fallback under `#available` for older systems. `displayLinkTimer: Timer?` →
`displayLink: CADisplayLink?` + `fallbackTimer: Timer?`; the old `gameLoopTick()` split into
`displayLinkTick(_:)`/`fallbackTimerTick()` thin shims over a shared `advanceFrames(now:)` core
that uses `link.timestamp` for elapsed-time accumulation. Verified: the button is view-backed and
lives in the status-bar window, so the display link attaches cleanly (app launched from the real
menu bar, ran stably, empty log). Ticks are now vsync-aligned and follow the screen's refresh rate
(ProMotion). Bonus cleanups folded in: (a) the `invalidate()`/recreate dance in `sampleSystemLoad()`
on every hysteresis-triggered speed change is gone — the driver reads `speedMultiplier` live, so a
speed change needs no driver restart; (b) `switchToGif` now calls `resetGameLoopTiming()` instead of
tearing down/recreating the driver (the link's button/screen is unchanged); (c) inter-tick gaps
larger than `Tuning.maxFrameAdvanceDelta` (sleep/occlusion/clock jump) resync instead of replaying
every skipped frame. `stopGameLoop()` centralizes teardown. Builds warning-clean under
`-strict-concurrency=complete`. `CLAUDE.md`'s game-loop architecture bullet was updated.

**Where**: `startGameLoop()` (lines 868-876), `gameLoopTick()` (lines 878-902).

**Issue**: The "game loop" is a manually-ticked 60 Hz `Timer` that accumulates elapsed wall
time (`ProcessInfo.processInfo.systemUptime`) and advances `frameIndex` by dividing each
frame's base GIF delay by `speedMultiplier`. This is a reasonable classic approach, but since
macOS 14, `CADisplayLink` is available outside `CAAnimation`/UIKit contexts and provides
vsync-aligned callbacks instead of a fixed-rate poll. At high speed multipliers (the
`raining` preset auto-ranges up to 4.25x, `Tuning.rainingSpeedMax`, line 24) a 60 Hz poll can
visibly stutter relative to true display refresh, and `CADisplayLink` can be paused/resumed
directly instead of `invalidate()`/re-`Timer(...)` on every speed change (see
`sampleSystemLoad()`, lines 548-551, which invalidates and restarts the timer on every
hysteresis-triggered speed update).

**Fix proposal**:
1. Replace `displayLinkTimer: Timer?` with a `CADisplayLink`-based driver (requires wiring it
   to a view/layer per API requirements — the status item's button view can host it, or use
   `NSScreen`-associated display link if button-hosting isn't supported for `NSStatusItem`).
2. Keep the same accumulator math (`accumulatedFrameTime`, `baseDurations[frameIndex] /
   speedMultiplier`) inside the new callback — the frame-advance logic in `gameLoopTick()`
   doesn't need to change, only the driver.
3. On speed change, just let the next callback read the live `speedMultiplier` (already true
   today) — remove the `invalidate()`/recreate dance in `sampleSystemLoad()` entirely if
   `CADisplayLink` doesn't need to be recreated on rate change (only `startGameLoop()`'s
   initial call and `switchToGif`'s frame-source change would still need a fresh link/reset
   of `lastTickTime`).

**Risk/cost**: Medium — needs verification that `CADisplayLink` attaches cleanly to a
non-window-backed `NSStatusItem` button on target macOS versions; if it doesn't attach
cleanly outside a window's view hierarchy, this may not be feasible and the current `Timer`
approach should stay (document why, and skip this item).

---

## 4. The load-indicator doesn't economize its own resource usage

**Status: RESOLVED (2026-07-06).** Implemented the two high-value paths from the fix proposal;
left point 3 (the 2s synchronous Mach call) as-is since it's cheap and moving it off-main would
be over-engineering.
Scope note: "back off"/"self-throttle" here means the app reduces **its own** animation work
(frame advances + redraws). The app only ever *reads* `isLowPowerModeEnabled`/`thermalState` — it
never mutates system state and cannot throttle the system or any other process. It is strictly
read-only w.r.t. the machine.
- **Power/thermal back-off**: `speedMultiplier(forUsage:)` now caps *the app's own* auto animation
  speed at `profile.min + (profile.max - profile.min) * Tuning.constrainedSpeedCeilingFraction` (0.5,
  i.e. the midpoint of the range) whenever `isUnderPowerPressure` is true — Low Power Mode on, or
  `thermalState` at `.serious`/`.critical`. The app subscribes to
  `.NSProcessInfoPowerStateDidChange` and `ProcessInfo.thermalStateDidChangeNotification` and calls
  `reevaluateSpeedForCurrentConditions()` on either, which recomputes speed from the latest smoothed
  usage immediately (bypassing the sample-tick hysteresis) so the cap engages/lifts without waiting
  up to 2s. The menu's Speed Multiplier line appends `[throttled: low power/thermal]` while capped.
- **Occlusion pause**: subscribes to `NSWindow.didChangeOcclusionStateNotification` on the status
  item button's window; `updateAnimationForOcclusion()` calls `stopGameLoop()` when the window is
  not `.visible` (behind the notch / menu-bar overflow, another Space, display off) and
  `startGameLoop()` when it becomes visible again — no re-rasterizing frames no one can see. Chosen
  to only ever pause in response to a positive occlusion-changed event, so if the notification never
  fires the behavior is unchanged (always animating) — no risk of freezing a visible icon.
- All three new observers (`powerStateObserver`/`thermalStateObserver`/`occlusionObserver`) are torn
  down in `applicationWillTerminate`. Builds warning-clean under `-strict-concurrency=complete`;
  launched from the real menu bar and ran stably for ~14s (empty log, no freeze in the visible case).

**Where**: `startGameLoop()`/`gameLoopTick()` (lines 868-902), `updateRenderedFrames()`
(lines 917-980), `sampleSystemLoad()` (lines 539-556).

**Issue**: This is the sharpest miss against the app's actual purpose. An app whose entire
job is to reflect system pressure never asks whether *it* should back off under pressure:
- The 60 Hz timer and full-frame re-rasterization (`updateRenderedFrames`, which redraws every
  frame via `NSImage(size:flipped:drawingHandler:)` plus `NSAttributedString` layout when an
  overlay is set) run unconditionally, regardless of thermal state or Low Power Mode.
- There's no check of whether the status item button is actually visible (e.g. hidden behind
  the notch/overflow chevron when the menu bar is crowded) — the game loop keeps ticking and
  re-rendering frames no one can see.
- `sampleSystemLoad()` (every `Tuning.loadSampleInterval` = 2s) does a synchronous Mach call
  (`host_processor_info`) on the main thread; cheap in isolation, but combine with the above
  and this is a utility that adds to the very load it's built to visualize.

**Fix proposal**:
1. Read `ProcessInfo.processInfo.isLowPowerModeEnabled` and `ProcessInfo.processInfo.thermalState`
   in `sampleSystemLoad()` (or a dedicated lower-frequency timer) and:
   - When Low Power Mode is on or `thermalState >= .serious`, cap `speedMultiplier` at a lower
     ceiling (e.g. clamp to `profile.min...(profile.min + (profile.max-profile.min)*0.5)`) and/or
     drop the game loop tick rate (e.g. 30 Hz instead of 60 Hz) via a second `Tuning` constant.
   - Optionally subscribe to `NSProcessInfoPowerStateDidChange` notification instead of
     polling, to react immediately rather than waiting for the next 2s sample.
2. Add a visibility check — `NSStatusBar` doesn't directly expose "is my item currently
   shown," but `statusItem.button?.window?.isVisible` or observing
   `NSApplication.didChangeScreenParametersNotification`/window occlusion state can be used as
   a proxy; if not visible, pause `displayLinkTimer` and resume when it becomes visible again.
3. Document the tradeoff in `CLAUDE.md`'s Tuning section once implemented (new constants for
   throttled tick rate / speed cap).

**Risk/cost**: Medium — mostly additive (new checks, new low-power path), low risk of
regressing the default (Low Power Mode off, thermalState nominal) case. Visibility detection
for `NSStatusItem` is the fiddliest part and may need experimentation.

---

## 5. Force-unwrapped IUOs and a `fatalError` on the startup hot path

**Status: PARTIALLY RESOLVED (2026-07-06).** Did the high-value half — the startup
`fatalError`. The `statusItem.button == nil` guard now calls
`showStartupErrorAndQuit("Unable to create NSStatusItem button.")` + `return`, matching the
existing graceful path used for GIF-decode failure (no new helper). Verified: builds
warning-clean under `-strict-concurrency=complete`; launched detached from the real menu bar,
ran stably with an empty log (success path unchanged). Deliberately left the ~20 IUO menu-item
properties as-is — the proposed struct-grouping is medium-risk, vaguely specified, and was
meant to fold into the #1 preset-registry refactor (now complete); it's not worth a standalone
pass. The IUOs remain guaranteed non-nil after `applicationDidFinishLaunching` and are never
accessed before then.

**Where**:
- IUO properties: `statusItem: NSStatusItem!` (line 256), `infoMenu: NSMenu!` (line 257), and
  ~20 more `NSMenuItem!` properties (lines 258-279).
- `fatalError`: `guard let button = statusItem.button else { fatalError("Unable to create
  NSStatusItem button") }` (lines 320-322).

**Issue**: All menu/status-item properties are force-unwrapped optionals initialized only in
`applicationDidFinishLaunching`, and if `statusItem.button` is ever `nil` (e.g. some future
macOS behavior change, or running under an unusual session type with no menu bar), the app
`fatalError`s — a hard crash — rather than degrading. This is inconsistent with the rest of
the file's error-handling philosophy: GIF-load failures already correctly show an alert and
quit gracefully via `showStartupErrorAndQuit()` (lines 511-522) instead of crashing.

**Fix proposal**:
1. Replace the `fatalError` with the same pattern used for GIF failures:
   ```swift
   guard let button = statusItem.button else {
       showStartupErrorAndQuit("Unable to create NSStatusItem button.")
       return
   }
   ```
2. For the ~20 IUO menu item properties, either:
   - (Minimal change) Leave them as IUOs but add a comment noting they're guaranteed
     non-nil after `applicationDidFinishLaunching` completes and are never accessed before
     then — acceptable given this is a single-init, single-purpose delegate.
   - (More thorough) Group related items into small structs (e.g. `WidthMenuUI { statusItem,
     menuItem, autoItem, slotItems }`, `OverlayMenuUI { statusItem, menuItem, setItem,
     clearItem }`) built once and returned from a `makeWidthMenu() -> WidthMenuUI` factory —
     this also shrinks the preset-registry refactor in item #1 by giving preset menu items the
     same treatment.

**Risk/cost**: Low for the `fatalError` fix (pure win, no behavior change in the success
path). Medium for the full IUO cleanup — recommend doing only the `fatalError` fix now and
folding the menu-item struct grouping into the item #1 refactor rather than as a separate pass.

---

## 6. No accessibility label on the status item

**Where**: `applicationDidFinishLaunching`, around line 326 (`button.toolTip =
activeGifPath`).

**Issue**: `button.toolTip` is set, but there's no `button.setAccessibilityLabel(...)` /
`setAccessibilityHelp(...)`. VoiceOver users get no meaningful description of the control —
just whatever generic role AppKit infers for an image-only status item button.

**Fix proposal**:
```swift
button.setAccessibilityLabel("MenuBar Load Runner")
```
and update it inside `refreshMenuMetrics()` (lines 565-592) to include live state, e.g.:
```swift
button.setAccessibilityLabel("MenuBar Load Runner — CPU \(Int(loadMonitor.smoothedUsage * 100))%")
```
so VoiceOver reflects current load, not just a static name.

**Risk/cost**: Trivial, one-line addition plus one line in the existing refresh function.

---

## 7. Overlay-text prompt uses a fragile triple-dispatch focus hack

**Status: RESOLVED (2026-07-06).** Done alongside item #2 (the hack was also a strict-concurrency
warning site). Focus is now handed to the field via `alert.window.initialFirstResponder = field`
before `runModal()` (the deterministic mechanism), replacing the three staggered post-presentation
dispatches. A single `DispatchQueue.main.async` hop remains as belt-and-suspenders — it re-asserts
`makeFirstResponder(field)` (in case an AppKit version ignores `initialFirstResponder` on an NSAlert
accessory view) and places the caret at the end of any pre-filled text, which needs the field editor
that only exists once focused. Closures capture `field`/`alertWindow` weakly.

**Manually verified working (2026-07-06)**: opened the overlay prompt from the real menu bar —
field has focus on open and accepts text correctly. (Could not be validated headlessly: a
bash-spawned probe process has no foreground window-server session, so `NSAlert.runModal()`
short-circuits and returns the default button immediately instead of presenting.)

**Where**: `promptOverlayText()`, lines 747-758:
```swift
let focusField: () -> Void = { ... }
DispatchQueue.main.async(execute: focusField)
DispatchQueue.main.asyncAfter(deadline: .now() + 0.03, execute: focusField)
DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: focusField)
```

**Issue**: This fires the same focus/select-text logic three times at staggered delays to work
around `NSAlert` occasionally not honoring first-responder assignment before the modal fully
presents. It's a known category of workaround but a timing-dependent one — it could still
race on a slow/loaded system (ironically, this app's own worst-case scenario is high CPU
load), and it leaves three scheduled closures alive referencing `field`/`alert.window` even
after the user may have already dismissed the alert via the immediate first call.

**Fix proposal**: Set the first responder *before* calling `runModal()` instead of racing
dispatched closures after presentation:
```swift
alert.window.initialFirstResponder = field
// ... after alert.window is made key (NSAlert handles this internally on runModal()):
```
If `initialFirstResponder` alone doesn't reliably win (this has been flaky in some AppKit
versions), fall back to a *single* `DispatchQueue.main.async` right before `runModal()` is
called rather than three staggered ones after — test empirically and keep only what's needed.

**Risk/cost**: Low — isolated to one modal flow, easy to test manually (open overlay prompt,
confirm text field has focus and cursor is at end of existing text).

---

## 8. `Timer(target: self, ...)` retain-cycle pattern

**Where**: `startLoadMonitoring()` (lines 526-537), `startGameLoop()` (lines 868-876).

**Issue**: `Timer(timeInterval:target:selector:userInfo:repeats:)` holds a strong reference to
`self`, and `self` holds the timer via `loadTimer`/`displayLinkTimer` — a retain cycle. Harmless
in this app today because the delegate lives for the whole process lifetime and is never
expected to deallocate before `NSApp.terminate`, but it's not the idiomatic modern pattern.

**Fix proposal**: Use the closure-based `Timer.scheduledTimer(withTimeInterval:repeats:)`
API with `[weak self]`:
```swift
loadTimer = Timer.scheduledTimer(withTimeInterval: Tuning.loadSampleInterval, repeats: true) { [weak self] _ in
    self?.sampleSystemLoad()
}
RunLoop.main.add(loadTimer!, forMode: .common)
```
(and equivalent for the game loop timer, dropping the `@objc` selector methods
`sampleSystemLoad`/`gameLoopTick` in favor of private non-`@objc` methods called from the
closure).

**Risk/cost**: Low, purely stylistic; do only if touching these functions for other reasons
(e.g. while doing item #3's `CADisplayLink` migration for the game loop, or item #4's
Low-Power-Mode changes for the load timer).

---

## 9. README omissions relative to the launcher's actual flag surface

**Where**: `README.md` (all sections), cross-checked against `menubar-load-runner`
(`print_help()`) and `CLAUDE.md`.

**Issue**: `README.md` is purely a usage/CLI reference (no design/implementation content —
that's entirely and appropriately in `CLAUDE.md`), but even within its own scope it has gaps:
1. `--extra` (allow launching a new instance even if one is already running) is documented in
   the launcher's own `--help` output but never mentioned in `README.md`.
2. `--detach`/`--no-detach` are only mentioned once, buried in the "Global Command Wrapper"
   section (line 46) — not in the top-level "Run Locally" section where a first-time reader
   would look.
3. The singleton enforcement (`pgrep -f "MenuBarLoadRunner.*\.gif"` — only one instance runs
   unless `--extra` is passed, per `CLAUDE.md`'s Commands section) is undocumented in the
   README. A user running any of the README's example commands twice would see nothing happen
   the second time with no explanation.
4. The detached-run log file location (`/tmp/menubar-load-runner.log`, overridable via
   `MENUBAR_LOAD_RUNNER_LOG_FILE` per `CLAUDE.md`) isn't mentioned anywhere in the README —
   the "Stop" section only shows `pkill`, with no pointer to logs for diagnosing a detached
   launch that silently fails.

**Fix proposal**: Add to `README.md`:
1. In "Run Locally," after the existing `--foreground` example, add a short "Notes" list:
   - Only one instance runs at a time (`pgrep`-based singleton check); pass `--extra` to
     override.
   - Detached output goes to `/tmp/menubar-load-runner.log` by default; override with
     `MENUBAR_LOAD_RUNNER_LOG_FILE`.
2. Add `--extra` to the "Help" section's implied flag list, or add a one-line "Flags" summary
   table near the top covering `--foreground`/`--no-detach`/`--detach`/`--extra`/`--width`/
   `--speed-multiplier`/`--overlay-text`/`--help` in one place instead of scattered across
   sections.
3. In "Stop," add: "If a detached instance won't stop or you're debugging a launch, check
   `/tmp/menubar-load-runner.log` (or `$MENUBAR_LOAD_RUNNER_LOG_FILE` if set) first."

**Risk/cost**: Trivial — docs-only change, no code touched.

---

## Suggested execution order

1. **#5** (fatalError → graceful quit) — trivial, pure safety win, do first.
2. **#9** (README gaps) — trivial, docs-only, no code risk.
3. **#6** (accessibility label) — trivial, one line.
4. **#2** (Swift 6 / `@MainActor`) — ✅ done (see status note above). Now that
   `-strict-concurrency=complete` is on, subsequent changes are caught by strict concurrency
   checking as they land.
5. **#1** (preset registry refactor) — ✅ done (see status note above); was the highest-value
   structural fix, and was completed before #3/#4 since both of those touch the game loop /
   speed logic that #1 has already consolidated behind `activePreset`.
6. **#7** (focus hack) — ✅ done, folded into #2 (shared strict-concurrency warning site).
   **#8** (retain cycle style) — still pending; low priority, opportunistic — fold into
   whichever of #3/#4 touches the same functions.
7. **#3** (CADisplayLink) — ✅ done (see status note above). **#4** (thermal/low-power
   awareness + occlusion pause) — ✅ done (see status note above). #8's game-loop retain-cycle concern is
   now moot for the loop driver — the `CADisplayLink`/`Timer` are held directly and torn down in
   `stopGameLoop()`; the `Timer(target:selector:)` retain-cycle note only still applies to
   `loadTimer` in `startLoadMonitoring()`.
