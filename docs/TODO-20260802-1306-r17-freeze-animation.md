# TODO — R17: honor Reduce Motion + manual Freeze Animation

Roadmap `R17` (P2). The app self-throttles under pressure and pauses when occluded, but ignores the
one OS signal saying *this user* needs less motion (`NSWorkspace.accessibilityDisplayShouldReduceMotion`),
and offers no manual way to calm the icon short of quitting. This adds both triggers over one
mechanism: a frozen icon whose readout moves to the label.

Everything below was verified against the source as of v1.21.0 — symbols, call order, and guard
shapes are the real ones. Delete this file when done; durable outcome goes to `DESIGN-system.md`,
the R17 row retires, and the one unverifiable trigger gets a verification-debt row (§8).

---

## 1. Decisions (settled — don't re-open without cause)

| Decision | Choice | Why |
|---|---|---|
| State shape | A **reason, not a Bool**: `manualFreeze: Bool` (intent, persisted) + `systemReduceMotion: Bool` (cached OS reading) → computed `animationFreeze: AnimationFreeze?` (`nil` = animate) | The `KeepAwakeSuspension` precedent. The two inputs have different owners (user vs OS) and different persistence rules, so they never merge into one flag. |
| Reason precedence | `.reduceMotion` outranks `.manual` for *reporting* | If both hold, the OS-imposed one is the one worth naming; behavior is identical either way. |
| What freezes | The game loop stops (`stopGameLoop()`), display stays on the **current frame** | Cheapest true restraint: zero CADisplayLink ticks, zero redraws — strictly less work than min-speed animation. Current frame, not frame 0: no visible jump on engage, and no assumption that frame 0 is a "rest pose" (no preset guarantees one). |
| What keeps running | The 2s sample timer, menu dashboard, label updates, keep-awake bar, assertion sampling, occlusion observer | Freeze is about *motion*, not about the app's job. The dropdown stays a live dashboard; keep-awake conditions keep evaluating. |
| Label handoff | While frozen and `labelMode == .off`, the label transiently shows `.value`. `.custom` is **respected, never overridden**. The override is memory-only — never persisted. | The R17 catch: speed *is* the readout, so a frozen icon with no label is a load indicator gone silent. Custom text was an explicit user choice; off was too, but off + frozen = zero information, which is the one combination the product can't defend. |
| Menu surface | `Settings ▸ Freeze Animation`, a simple toggle row next to Start at Login | It's a standing preference (persists, outlives relaunch) → Settings, per the Battery Threshold precedent. Not root: root is the scarce surface. |
| Row semantics under system RM | Row stays **enabled**; checkmark = `manualFreeze` only; title gains ` — on via Reduce Motion` while `systemReduceMotion` | Intent stays editable while a condition holds (same split as Keep Awake's `isEnabled` vs suspension, and same philosophy as the side rows staying live while the label is off). Disabling the row would trap a stale manual intent behind an OS setting. |
| CLI / env | **None.** Menu-only, restored from the `settings` block unconditionally | The label-side precedent verbatim: a new flag is public API forever, and the restart-after-update / LaunchAgent paths already pick persisted settings up off disk. |
| Naming | "Freeze Animation" / `freezeAnimation` / `AnimationFreeze` | "Pause" collides with Keep Awake's `(paused)` vocabulary (a condition-suspend); "static mode" reads as a noun with no verb. Freeze is the verb, and unambiguous. |
| New Tuning constants | None needed | No magic numbers anywhere in this feature. |
| Test observability | New hook `MENUBAR_LOAD_RUNNER_LOG_ANIMATION=1`, printed on the 2s tick | Sanctioned category (makes real state observable; changes no decision). Without it, "not animating" is only assertable by CPU proxy or screenshot, both barred/fragile. |

## 2. State + enum

Near `KeepAwakeSuspension` (`MenuBarLoadRunner.swift:1126`) add:

```swift
// Why the animation is frozen, when it is. A reason rather than a Bool for the same cause as
// KeepAwakeSuspension: the two triggers have different owners (the OS vs the user), different
// persistence (a reading is never persisted; intent always is), and the menu reports which one holds.
private enum AnimationFreeze: Equatable {
    case reduceMotion   // NSWorkspace.accessibilityDisplayShouldReduceMotion — the OS speaks for the user
    case manual         // the Settings ▸ Freeze Animation toggle
}
```

On `MenuBarLoadRunnerApp`:

```swift
// Intent — the Settings toggle. Persisted (settings.freezeAnimation), restored unconditionally.
private var manualFreeze = false
// Cached OS reading — event-driven via accessibilityDisplayOptionsDidChangeNotification, like
// memoryPressureLevel (no polling; re-read on the notification). Never persisted: it's a reading.
private var systemReduceMotion = false
// The one derivation every consumer reads. reduceMotion outranks manual for reporting only.
private var animationFreeze: AnimationFreeze? {
    if systemReduceMotion { return .reduceMotion }
    if manualFreeze { return .manual }
    return nil
}
private var reduceMotionObserver: NSObjectProtocol?
private var freezeAnimationMenuItem: NSMenuItem!
```

## 3. Game-loop gating — `syncGameLoopRunning()`

**This refactor is the correctness core, not a cleanup.** Today `updateAnimationForOcclusion()`
(`:6093`) is the only stop/start decider, and its resume branch starts the loop *blindly* when the
window becomes visible. Left as is, freeze + occlusion interleave wrongly: freeze while on another
Space → switch back → occlusion resume restarts a loop the freeze should hold stopped.

Replace the body's decision with one total function; occlusion and freeze become inputs:

```swift
// The one place that decides whether the frame driver runs. Total over both inputs (occlusion,
// freeze) so no caller can resume past a condition it didn't check — the occlusion path used to
// start the loop blindly on visibility, which a freeze must survive.
private func syncGameLoopRunning() {
    let occluded: Bool
    if let window = statusItem.button?.window {
        occluded = !window.occlusionState.contains(.visible)
    } else {
        occluded = false   // no window yet (early launch) — matches the old unconditional start
    }
    let shouldRun = !occluded && animationFreeze == nil
    if shouldRun {
        if displayLink == nil, fallbackTimer == nil { startGameLoop() }
    } else {
        stopGameLoop()
    }
}

private func updateAnimationForOcclusion() { syncGameLoopRunning() }
```

Notes that must survive review:
- `startGameLoop()` already calls `resetGameLoopTiming()` (`:6112`), so unfreeze resumes from the
  current frame with no gap replay — identical to occlusion resume. Nothing new needed.
- The freeze-only property "only ever pauses in response to a positive event" still holds for the
  occlusion input: with no window, `occluded = false`, so a never-firing occlusion notification
  still can't stop anything — the no-freeze-risk argument in `AGENTS.md` is preserved.
- No `renderCurrentFrame()` on freeze: the last advance already drew the frame on screen.
- `switchToGif` (`:5744`) needs **no change**: it calls `applySizing()` + `renderCurrentFrame()`
  itself, so a preset switch while frozen renders the new GIF's frame 0 and stays frozen (its
  timing re-sync touches a driver that simply isn't running).
- In `applicationDidFinishLaunching`, replace the `startGameLoop()` call (`:3698`) with
  `syncGameLoopRunning()` — this is what makes a frozen launch never animate a few frames first.

## 4. The shared change handler

Both triggers funnel through one function (the `conditionsDidChange()` shape):

```swift
// Everything that must react when the effective freeze changes, from either trigger. Persisting is
// NOT here — the observer path is a reading, not intent, and persistState() stays gesture-only.
private func freezeDidChange() {
    syncGameLoopRunning()
    applyLabelMode()                  // engage/release the label handoff (resizes the slot)
    refreshFreezeAnimationState()
    refreshLabelSelectionState()      // parent readout may gain/lose the handoff suffix
}
```

## 5. Reduce Motion observer

Register alongside the other observers (after `:3714`), **on the workspace center**:

```swift
reduceMotionObserver = NSWorkspace.shared.notificationCenter.addObserver(
    forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
    object: nil,
    queue: .main
) { [weak self] _ in
    MainActor.assumeIsolated {
        guard let self else { return }
        let reading = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard reading != self.systemReduceMotion else { return }   // options changed, but not ours
        self.systemReduceMotion = reading
        self.freezeDidChange()
    }
}
```

Two catches:
- **Teardown targets the wrong center if you follow the existing loop.** `applicationWillTerminate`'s
  observer loop (`:3786`) removes from `NotificationCenter.default`; this observer lives on
  `NSWorkspace.shared.notificationCenter` and must be removed from *that* center separately. Do not
  add it to the existing array.
- The notification fires for every accessibility display option (contrast, transparency, …) — hence
  the `guard reading != systemReduceMotion` so unrelated changes don't churn `freezeDidChange()`.

## 6. Launch wiring — `applyLaunchFreezeState()`

New peer of the other `applyLaunch*` functions:

```swift
// Launch-time freeze. Menu-only like the label side, so it restores unconditionally from the
// settings block — no flag exists to defer to. The OS reading is taken here too, so a launch under
// Reduce Motion (or with a saved manual freeze) never animates before the first sync.
private func applyLaunchFreezeState() {
    manualFreeze = StateStore.load()?.settings?.freezeAnimation ?? false
    systemReduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
}
```

**Call order is load-bearing.** Insert the call immediately before `applyLaunchLabelState()`
(`:3653`): it must precede `applyLabelMode()` (`:3655`) so a frozen launch sizes the label slot for
the handoff in the same pass, and it must precede `refreshLabelSelectionState()` (`:3654`) so the
parent readout renders the suffix. It has no interaction with the battery/keep-awake ordering chain
(`:3669`–`:3679`). Also call `refreshFreezeAnimationState()` next to `refreshStartAtLoginState()`
(`:3646`). Section 3 already replaced `startGameLoop()` at `:3698`.

`StateStore.load()` per-function is the existing pattern (`applyLaunchLabelState` and
`applyLaunchBatteryThresholdState` each load separately) — follow it, don't invent a shared load.

## 7. Menu

**Construction** — in the Settings submenu, after the separator at `:3486`, *before* Start at Login
(two plain toggles grouped together, radio-group submenus above them):

```swift
freezeAnimationMenuItem = NSMenuItem(
    title: MenuTitle.freezeAnimation,
    action: #selector(toggleFreezeAnimation(_:)),
    keyEquivalent: ""
)
freezeAnimationMenuItem.target = self   // nested — infoMenu's blanket target pass never reaches here
useSelectionMark(freezeAnimationMenuItem)
settingsSubmenu.addItem(freezeAnimationMenuItem)
```

`MenuTitle` additions (`:676`):

```swift
static let freezeAnimation = "Freeze Animation"
static let freezeAnimationViaReduceMotion = "Freeze Animation — on via Reduce Motion"
```

**Refresh** — checkmark is *intent*, title names the *condition*:

```swift
private func refreshFreezeAnimationState() {
    freezeAnimationMenuItem?.state = manualFreeze ? .on : .off
    freezeAnimationMenuItem?.title = systemReduceMotion
        ? MenuTitle.freezeAnimationViaReduceMotion
        : MenuTitle.freezeAnimation
}
```

Wire `refreshFreezeAnimationState()` into `menuWillOpen` alongside the other refreshers, per the
menu-driven-state rule.

**Action** — the one mutating gesture, and the only new `persistState()` call site:

```swift
@objc private func toggleFreezeAnimation(_ sender: NSMenuItem) {
    manualFreeze.toggle()
    freezeDidChange()
    persistState()
}
```

## 8. Label handoff

Add one computed property and repoint exactly three switch sites:

```swift
// What the label SLOT renders, as opposed to what the user chose (labelMode, which the menu marks
// and persistState read). Differs only while frozen with the label off: a frozen icon carries no
// reading, so the slot borrows .value rather than letting the indicator go silent. Memory-only —
// the persisted mode is untouched, and .custom is respected (that text was an explicit choice).
private var effectiveLabelMode: MenuBarLabel {
    (animationFreeze != nil && labelMode == .off) ? .value : labelMode
}
```

- `applyLabelMode()` (`:5011`) — the `guard labelMode != .off` becomes `effectiveLabelMode`.
- `labelSlotWidth(for:)` (`:5033`) — `switch labelMode` becomes `switch effectiveLabelMode`.
- `updateValueLabel()` (`:5056`) — `switch labelMode` becomes `switch effectiveLabelMode`.

Everything else **stays on `labelMode`**: `refreshLabelSelectionState()` (radio marks show the
user's choice), `setLabelMode`, and `persistState()` (`labelMode.persistedMode` — the override must
never leak to disk). `freezeDidChange()` calling `applyLabelMode()` is what engages/releases the
slot; the reserved-width machinery, tint plumbing, and the VoiceOver depadded
`setAccessibilityLabel` all come along for free because the handoff *is* `.value` mode.

Parent readout while the handoff is live — `refreshLabelSelectionState()` `.off` branch becomes:

```swift
case .off:
    let suffix = (effectiveLabelMode == .value) ? " (value while frozen)" : ""
    labelMenuItem.title = MenuTitle.label(MenuTitle.labelOff + suffix)
```

(An invisible override would violate the never-silent ethos; one suffix keeps the menu honest.)

Width note: engaging/releasing the handoff moves the icon's neighbours once per toggle — identical
to the user switching label mode by hand, and the no-jitter promise is about the 2s tick, not about
mode changes. Not a bug; don't "fix" it.

## 9. Persistence

`PersistedState.Settings` (`:1442`) gains:

```swift
// Settings ▸ Freeze Animation — the MANUAL freeze intent only. Menu-only like labelSide, so it
// restores unconditionally. The Reduce Motion half is never persisted: it's an OS reading with its
// own owner, re-read fresh at every launch.
var freezeAnimation: Bool?
```

`persistState()` (`:5361`) passes `freezeAnimation: manualFreeze`. Optional field → older files
decode fine; older builds ignore the new key. No `StateStore.currentVersion` bump (same as every
settings addition to date). `persistState()` remains the only writer; the new call site in
`toggleFreezeAnimation` is a gesture, satisfying the intent-not-running-state rule (the observer
path deliberately does not persist).

**Restart/update path: no code needed.** `Restarter.appArguments` has no flag to pass; the restarted
instance restores `manualFreeze` from disk, exactly like the label side. Same for LaunchAgent baked
args (`toggleStartAtLogin` bakes flags only; freeze has none).

## 10. `MENUBAR_LOAD_RUNNER_LOG_ANIMATION=1`

Sibling of `LOG_AWAKE` (`:4862`) — same shape, same placement:

```swift
// Debug/test hook: MENUBAR_LOAD_RUNNER_LOG_ANIMATION=1, sibling to LOG_SLOTS/LOG_ASSERTIONS/
// LOG_AWAKE and there for the same no-TCC-grant reason: whether the icon is animating is otherwise
// only visible to a screenshot (Screen Recording) or an eyeball. Prints the DERIVED gate plus the
// raw frame cursor, so a test asserts both the decision and its effect (frame stops moving).
private let logAnimation = ProcessInfo.processInfo.environment["MENUBAR_LOAD_RUNNER_LOG_ANIMATION"] == "1"

private func logAnimationIfRequested() {
    guard logAnimation else { return }
    let freeze: String
    switch animationFreeze {
    case .reduceMotion: freeze = "reduceMotion"
    case .manual:       freeze = "manual"
    case nil:           freeze = "none"
    }
    let running = (displayLink != nil || fallbackTimer != nil) ? 1 : 0
    let handoff = (effectiveLabelMode != labelMode) ? 1 : 0
    print("ANIM running=\(running) freeze=\(freeze) frame=\(frameIndex) " +
          String(format: "speed=%.2f", speedMultiplier) + " labelHandoff=\(handoff)")
}
```

Call it from `sampleSystemLoad()`'s tail next to `logAwakeHoldIfRequested()` (`:4238`). Frame-advance
sanity: at the slowest preset floor a GIF frame lasts well under 2s, so `frame=` must differ across
consecutive ticks when running — assertable without timing games.

## 11. Tests — `tests/qa.sh`, new §3g + §3b rows

New section `§3g freeze animation [gui — needs WindowServer]`, driving the real binary via the
state file (the toggle itself is a menu click no agent can perform — restore-side is what's
mechanical, the click path goes to the RUNBOOK, the §3b precedent):

1. **Frozen launch**: write `$TMP/state.json` with
   `{"version":1,"settings":{"freezeAnimation":true}}`; launch `tmp/mblr-check` with
   `STATE_FILE=$TMP/state.json LOG_ANIMATION=1 EXIT_AFTER=8`; assert every `ANIM` line has
   `running=0 freeze=manual labelHandoff=1`, and `frame=` is one constant across all ticks.
2. **Label handoff on the bar**: same run with `LOG_SLOTS=1` — the active label slot's `label="…"`
   must be non-empty (the depadded reading made it to the slot) despite no `--label` flag.
3. **Handoff respects an explicit mode**: same state file plus `--label "hi"`; assert
   `labelHandoff=0` and the slot shows `hi` (custom never overridden).
4. **Running baseline**: launch with no state file; assert `running=1 freeze=none` and `frame=`
   takes ≥2 distinct values. **Gate on the machine's own Reduce Motion first**: read
   `defaults read com.apple.universalaccess reduceMotion` (missing key = off); if it's on, the
   baseline inverts by design — report `NOTE`, never a false FAIL (the §3c/§3e shape: the
   machine's accessibility settings are not the test's to control).
5. **Persistence round-trip** (§3b, one new row in the existing table): seed
   `freezeAnimation:true`, run with `EXIT_AFTER`, assert the file still carries
   `"freezeAnimation":true` after termination's `persistState()` — and that a run where the state
   file omits the key round-trips to `false`/absent without error (Optional-field degradation).

**Not testable, recorded, never faked**: the Reduce Motion *trigger* (observer → freeze). Flipping
the real pref mutates the developer's system, and a `FORCE_REDUCE_MOTION` hook would change a
decision (barred — mocking with extra steps; note `FORCE_BATTERY` got in only because a desktop has
*no* battery to read, whereas every Mac has a real, readable Reduce Motion setting). The shared
code path past the observer is exactly what §3g covers via `manualFreeze`. This mirrors the
existing "Thermal pause rendering" debt row verbatim — on completion, add to `docs/ROADMAP.md`
verification debt:

> | Reduce Motion trigger (R17) | **No functional check.** The pref is the machine's, not the
> test's; forcing it needs a decision-changing hook, which is barred. Everything downstream of the
> observer (freeze rendering, label handoff, persistence) is covered by `qa.sh` §3g via the manual
> toggle; only the notification→reading wiring is eyes-only (RUNBOOK). |

## 12. Docs + release surfaces

- **`AGENTS.md`**: one architecture bullet (map-altitude — the freeze state, two triggers, the
  `syncGameLoopRunning` single-decider rule, the handoff, "checkmark = intent, title = condition");
  one `LOG_ANIMATION` example block in Commands next to the other three LOG hooks. Rationale stays
  out (it lives in `DESIGN-system.md` when this closes).
- **`README.md`**: the self-restraint feature bullet gains freeze + Reduce Motion; the comparison
  row "Pauses when hidden; self-throttles under power/thermal pressure" becomes "…; honors Reduce
  Motion"; Settings menu docs gain the row.
- **`docs/RUNBOOK-qa-release.md`**: add the two eyes-only checks — toggle System Settings →
  Accessibility → Display → Reduce Motion and confirm the icon freezes/resumes live (the debt row's
  wiring check), and confirm the frozen frame + handoff label *look* right (perceptibility is
  eyes-only, per the R7 precedent).
- **`docs/cover.html`**: gets its paragraph in the release pass, not before (release-hygiene rule).
- **On completion**: retire the R17 row, add the §11 debt row, write the durable outcome into
  `DESIGN-system.md`, delete this file.

## 13. Explicitly out of scope

- Any auto-freeze on screen *sharing/recording* detection (`SCShareableContent` etc.) — the manual
  toggle covers the case; detection is a privacy-sensitive read with its own design pass.
- A "reduce, don't stop" tier (slow-but-moving under Reduce Motion). Apple's own guidance for the
  setting is to remove non-essential motion, and half-motion satisfies nobody; the label carries
  the signal instead.
- A CLI flag/env for freeze (menu-only precedent, §1) — revisit only on a concrete report.
- Touching `updateKeepAwakeBar()`/tint plumbing — the bar is a sibling layer refreshed on the 2s
  tick and is deliberately unaffected by the frame driver stopping.
