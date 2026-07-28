# R5 — Configurable Keep Awake battery release threshold

**Priority** P3 · **Blocked by** nothing. `Settings ▸` (`:2405`) and `PersistedState.Settings`
(`:870`) shipped in v1.14.0, which is what this was waiting on — `AGENTS.md` already names this "the
next candidate" for the settings block.

Today Keep Awake releases at a hardwired 20% on battery (`Tuning.batteryLowThreshold`, `:224`). Give
it a CLI/env/menu surface, persisted. This *relocates* the cliff; it is not a substitute for the
arm-anyway override, which shipped separately and stays.

Line anchors are against **v1.14.0** (`MenuBarLoadRunner.swift`, 4553 lines). Re-resolve by symbol if
they don't land.

---

## Step 0 — Split the constant (do this first, and alone) — **DONE 2026-07-28**

`Tuning.batteryLowThreshold` has two consumers with unrelated jobs:

| Consumer | Anchor | Job |
|---|---|---|
| `keepAwakeSuspension` | `:4049` | sleep policy — when to kill `caffeinate` |
| `refreshMenuMetrics` → `loadHistoryView.lowThreshold` | `:3111` | the battery trace's red band, paired with `batteryChargeMediumThreshold` (`:238`) |

The comments at `:230-232` and `:235-237` already say these must not be conflated — they just share a
literal today. Split before anything else, so the rest of the work can't recolor the sparkline:

```swift
// Sleep policy: the DEFAULT for the user-configurable release threshold (keepAwakeBatteryThreshold).
static let batteryLowThresholdDefault: Double = 0.20
// Chart band ONLY — fixed, mirroring the macOS low-battery convention. Deliberately not the sleep
// threshold: moving the release point must not recolor the fuel gauge.
static let batteryChartLowThreshold: Double = 0.20
```

Point `:3111` at `batteryChartLowThreshold`, `:4049` at the runtime value from Step 1, and rewrite the
three comment blocks at `:222-238`, which currently describe the coupling as deliberate and shared.
This step is independently verifiable: behavior identical, `swiftc` clean.

## Step 1 — The runtime value and its bounds

Stored property on the app class, next to the other keep-awake state (`:2162`):

```swift
private var keepAwakeBatteryThreshold: Double = Tuning.batteryLowThresholdDefault
```

Bounds in `Tuning`:

```swift
static let batteryThresholdMin: Double = 0.06   // strictly above batteryCriticalThreshold
static let batteryThresholdMax: Double = 1.0
```

**Clamp, never reject**, at every entry point (CLI, env, state file) — the same rule
`KeepAwakeDuration.parse` documents at `:576-577`, for the same reason: this value can be baked into a
login item, where a hard failure costs the user the whole app. Warn on stderr, then carry on.

**Decide explicitly: allow "off".** Recommend yes, as a distinct value meaning *never release on
battery charge*. Setting 6% is nearly the floor anyway, and a user who wants that wants the policy
gone, not relocated. The 5% critical floor still applies and is **not** configurable — the roadmap's
"Below 5% on battery the Mac sleeps regardless" known limit must stay literally true.

## Step 2 — CLI and env

`--battery-threshold <pct|off>`, env `MENUBAR_LOAD_RUNNER_BATTERY_THRESHOLD`. Parse in the `Config`
arg switch (`:690`) on the shape of `--speed-multiplier` (`:695-701`): `guard let value =
iterator.next()`, message + `printUsage()` on a miss.

**Accept whole percents only** (`20`), not `20%` and not `0.20`. A bare `0.2` is 0.2% under that rule
and 20% under the other — the identical ambiguity `KeepAwakeDuration.parse` refuses to guess at
(`:573-577`). Reject values below 1 other than the literal `off`, and say which form you wanted.

Precedence mirrors the label (`applyLaunchLabelState`, `:3715-3727`): `Config.batteryThreshold` is
`Double?` where **nil (no flag, no env) is distinct from a value**, and an empty env string counts as
absent — see the `:745-750` fallback pattern and qa.sh §3b's "empty env != explicit off" case. Note the
asymmetry with `--label`: here `off` is a *value* (0), not a mode, so nil vs 0 vs 20 are three states.

## Step 3 — Persistence

Add to `PersistedState.Settings` (`:870`):

```swift
var batteryThreshold: Double?   // Optional like every field, so an older/newer file degrades
```

Compose it in `persistState()` (`:3707-3710`) — **the only writer** (`:3689-3692`). Add
`applyLaunchBatteryThresholdState()` beside `applyLaunchLabelState()` (`:3720`) and call it from
`applicationDidFinishLaunching` **before `startBatteryMonitoring()`** (`:4084`), which must itself stay
before `applyLaunchKeepAwakeState()`. Ordering is load-bearing: the threshold has to be in place
before the first suspension is computed, or launch evaluates against the default 20% and then jumps
when the saved value lands.

## Step 4 — Menu surface

`Settings ▸` (`:2405`) gains `Battery Threshold ▸`, built exactly like the label group
(`:2410-2429`) — the parent row's title carries the readout via `MenuTitle.line` (`:324`), e.g.
`Battery Threshold: 20%`, so no separate read-only line is needed. Rows from a new
`Tuning.batteryThresholdRows: [Double] = [0.10, 0.15, 0.20, 0.30]`, plus `Never` and a `Custom…`
percent prompt modeled on `promptCustomKeepAwakeDuration` (`:3780`) with one field instead of two.

Two invariants: call `useSelectionMark(item)` on each row, and set `item.target = self` **at
construction** — `infoMenu.items.forEach { $0.target = self }` wires root items only. Add
`refreshBatteryThresholdSelectionState()` to the `menuWillOpen` refresh set, and address the stored
`[NSMenuItem]` array, never menu positions.

The mutator `setBatteryThreshold(_:)` mirrors `setLabelMode` (`:3887`): it is the mutating gesture, so
it persists.

## Step 5 — Apply immediately

`setBatteryThreshold` must call `updateSleepPrevention()` (`:4064`). Without it a live window keeps
running on the old threshold until the next power event happens to fire — the same latency problem
`conditionsDidChange()` (`:4027`) exists to solve. Do **not** route it through
`reevaluateSpeedForCurrentConditions()`; animation speed is unrelated to this setting.

---

## Catches

1. **Clear the override on a threshold change.** `keepAwakeBatteryOverride` answers one specific
   question — "the battery is low, keep it awake anyway?" — asked against one specific threshold.
   Changing the threshold invalidates the answer, so clear it in `setBatteryThreshold`, joining the
   three existing clears (critical floor `:4068`, plugged in `:4071`, Off/expiry). Otherwise raising
   the threshold to 30% at 25% charge inherits a "yes" the user gave about 20%.
2. **Don't grant the override as a side effect.** `grantKeepAwakeBatteryOverrideIfOffered()` (`:3680`)
   is deliberately gesture-scoped and deliberately does not fire on an arm at a healthy charge
   (`:3676-3679`). A threshold edit is not an arm.
3. **The 5% floor stays hardwired.** `batteryCriticalThreshold` (`:233`) is tested first (`:4046`), so
   it already wins — but only while the configured threshold can't be set beneath it. That is what
   `batteryThresholdMin` buys.
4. **Don't reorder `keepAwakeSuspension`.** Critical-before-low is deliberate so the row never says
   "low" at 4% (`:4039-4040`).
5. **The pause text needs no change.** `.batteryLow(percent:)` (`:623`) renders the *charge*, not the
   threshold. Resist adding the threshold to it — that row is already composed with the countdown and
   the parent title (`:3360-3365`).
6. **Re-verify the chart after Step 0.** Switch to the battery source with a non-default threshold; the
   red band must still turn at 20%.

## Acceptance criteria

- [ ] `swiftc -O -strict-concurrency=complete` is warning-clean.
- [ ] `--battery-threshold 10` + `MENUBAR_LOAD_RUNNER_FORCE_BATTERY=15:battery` → caffeinate **holds**
      (today: paused).
- [ ] `--battery-threshold 30` + `25:battery` → **paused**, with the battery-low reason on the status row.
- [ ] `--battery-threshold 2` → clamped to the min, warns on stderr, exits 0 (not rejected).
- [ ] `--battery-threshold off` + `15:battery` → holds; `4:battery` still releases (the floor).
- [ ] Set from the menu, relaunch with no flag → restored; an explicit flag still wins; an empty env
      value is absent, not a value.
- [ ] A hand-edited garbage `batteryThreshold` → launch default, rc 0, no modal, and the `keepAwake`
      block survives the settings write (§3b's single-writer invariant).
- [ ] Battery-source sparkline red band unchanged at 20% while the threshold is 10%.
- [ ] `tests/qa.sh` §3a: extend the `ka()` helper with an args passthrough and add the first four cases
      above. §3b: add a persistence case.

## Docs to touch

`AGENTS.md` (Keep Awake section's threshold sentence; the `PersistedState` paragraph that names this as
the next settings candidate), `README.md`, `menubar-load-runner` `print_help` (usage strings `:31-32`
plus a flag line near `:50`), `docs/RUNBOOK-qa-release.md` (§3a/§3b), `docs/ROADMAP.md` (close R5 —
and confirm the 5% known-limit row still reads true), `CHANGELOG.md`.

---

## Status as of 2026-07-28

**Step 0 done, uncommitted. Steps 1–5 not started.**

`Tuning.batteryLowThreshold` is gone, split into two constants that share the number 0.20 and
nothing else:

| New constant | Consumer | Job |
|---|---|---|
| `batteryLowThresholdDefault` | `keepAwakeSuspension` | sleep policy — the default Step 1 makes configurable |
| `batteryChartLowThreshold` | `refreshMenuMetrics` → `loadHistoryView.lowThreshold` | chart red band, fixed forever |

The three comment blocks that described the coupling as deliberate now say the opposite, and
`batteryCriticalThreshold`'s comment records why it is *not* configurable (the README's "below 5% the
Mac sleeps regardless" guarantee must stay literally true whatever the release threshold is set to).
`keepAwakeSuspension` carries a one-line marker pointing at Step 1.

Verified: `swiftc -O -strict-concurrency=complete` warning-clean; `tests/qa.sh` ALL PASS, with §3a
covering the preserved semantics directly — healthy holds, AC-at-15% holds, low releases, the 20%
boundary releases, critical floor releases. Behavior is identical by construction (a rename plus a
second constant of equal value).

**Next: Step 1** — the stored `keepAwakeBatteryThreshold` property and its bounds, then have
`keepAwakeSuspension` read it instead of the default. Catch 6 (re-verify the chart's red band still
turns at 20% with a non-default threshold) only becomes testable once Step 1 exists; at Step 0 both
constants are 0.20, so it is trivially true and proves nothing.
