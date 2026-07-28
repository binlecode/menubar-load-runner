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

## Step 1 — The runtime value and its bounds — **DONE 2026-07-28**

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

**Decided (Step 1): "off" is allowed**, spelled as the value `0` (`Tuning.batteryThresholdOff`),
deliberately outside `[min, max]` rather than min-minus-1% so it stays expressible. Original reasoning
kept below. — Recommend yes, as a distinct value meaning *never release on
battery charge*. Setting 6% is nearly the floor anyway, and a user who wants that wants the policy
gone, not relocated. The 5% critical floor still applies and is **not** configurable — the roadmap's
"Below 5% on battery the Mac sleeps regardless" known limit must stay literally true.

## Step 2 — CLI and env — **DONE 2026-07-28**

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

## Step 3 — Persistence — **DONE 2026-07-28**

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

## Step 4 — Menu surface — **DONE 2026-07-28**

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

## Step 5 — Apply immediately — **DONE 2026-07-28** (folded into Step 4)

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

- [x] `swiftc -O -strict-concurrency=complete` is warning-clean.
- [x] `--battery-threshold 10` + `MENUBAR_LOAD_RUNNER_FORCE_BATTERY=15:battery` → caffeinate **holds**
      (today: paused).
- [x] `--battery-threshold 30` + `25:battery` → **paused**, with the battery-low reason on the status row.
- [x] `--battery-threshold 2` → clamped to the min, warns on stderr, exits 0 (not rejected).
- [x] `--battery-threshold off` + `15:battery` → holds; `4:battery` still releases (the floor).
- [x] Set from the menu, relaunch with no flag → restored; an explicit flag still wins; an empty env
      value is absent, not a value. *(Step 3: asserted from the CLI, which is the only mutator until
      Step 4; the menu path inherits it because `setBatteryThreshold` will call the same `persistState`.)*
- [x] A hand-edited garbage `batteryThreshold` → launch default, rc 0, no modal, and the `keepAwake`
      block survives the settings write (§3b's single-writer invariant).
- [ ] **Interactive only — RUNBOOK §7, not yet run.** Battery-source sparkline red band unchanged at 20%
      while the threshold is 10% (Catch 6); the menu group's rows/readout/Custom… prompt; a threshold
      change applying to a live window at once; a threshold change retiring the override.
- [x] `tests/qa.sh` §3a: extend the `ka()` helper with an args passthrough and add the first four cases
      above. §3b: add a persistence case.

## Docs to touch

`AGENTS.md` (Keep Awake section's threshold sentence; the `PersistedState` paragraph that names this as
the next settings candidate), `README.md`, `menubar-load-runner` `print_help` (usage strings `:31-32`
plus a flag line near `:50`), `docs/RUNBOOK-qa-release.md` (§3a/§3b), `docs/ROADMAP.md` (close R5 —
and confirm the 5% known-limit row still reads true), `CHANGELOG.md`.

---

## Status as of 2026-07-28

**All six steps done (0–5). Interactive verification is the only thing outstanding.**

**Step 0** split `Tuning.batteryLowThreshold` into two constants that share the number 0.20 and
nothing else:

| New constant | Consumer | Job |
|---|---|---|
| `batteryLowThresholdDefault` | `keepAwakeSuspension` (now only as the property's initial value) | sleep policy — the default Step 1 made configurable |
| `batteryChartLowThreshold` | `refreshMenuMetrics` → `loadHistoryView.lowThreshold` | chart red band, fixed forever |

The three comment blocks that described the coupling as deliberate now say the opposite, and
`batteryCriticalThreshold`'s comment records why it is *not* configurable (the README's "below 5% the
Mac sleeps regardless" guarantee must stay literally true whatever the release threshold is set to).

**Step 1** added, with no user-facing surface yet (that is Step 2 onward — the value is still always
the default at runtime):

- `keepAwakeBatteryThreshold: Double` on the app class, next to `keepAwakeBatteryOverride`, initialized
  to `Tuning.batteryLowThresholdDefault`.
- `Tuning.batteryThresholdOff` (0) / `batteryThresholdMin` (0.06) / `batteryThresholdMax` (1.0), with
  the min above the 5% floor so the floor is unreachable from any surface (Catch 3).
- `Tuning.clampedBatteryThreshold(_:)` — the single clamp every future entry point funnels through.
  `≤ 0` → off, non-finite → the default, otherwise pulled into `[min, max]`. Clamp, never reject.
- `keepAwakeSuspension`'s low band now reads the property; the Step 1 marker comment is gone.

Verified: `swiftc -O -strict-concurrency=complete` warning-clean; `tests/qa.sh` ALL PASS (§3a's five
cases confirm the default-valued behavior is unchanged). Because no entry point exists yet, the *live*
read was proved with two throwaway builds whose property default was patched to 0.30 and to off —
30%: 25% releases (the default would hold) and 35% holds; off: 15% holds (the default would release)
and 4% still releases, so the floor survives "off". Those four cases become real qa.sh cases in Step 2,
once `--battery-threshold` can express them.

One trap that first made the throwaway probe lie: a source copy built from `tmp/` bakes `#filePath`
into `tmp/`, so `gifs/presets.json` doesn't resolve and the app dies at launch — which a
caffeinate-presence check reads as a correct pause. `ln -sfn ../gifs tmp/gifs` fixes it; `AGENTS.md`'s
compile-check bullet now records this.

**Step 2** shipped the launch surface: `--battery-threshold <pct|off>` +
`MENUBAR_LOAD_RUNNER_BATTERY_THRESHOLD`, parsed by `Config.parseBatteryThreshold` and applied by
`applyLaunchBatteryThresholdState()` (before `startBatteryMonitoring()`, per the ordering rule above).

- **Deviation from this file's spec, deliberate:** a trailing `%` is *accepted* (`20%` ≡ `20`). The
  spec lumped it in with `0.20`, but the stated reason — an unguessable order-of-magnitude ambiguity —
  only applies to the decimal. `20%` removes ambiguity rather than adding it, so refusing a form the
  user naturally types bought nothing. `0.20` is still refused, and `0` is accepted as the numeric
  spelling of off.
- Out of range → clamped with a stderr warning naming the valid band and the non-configurable 5%
  floor. Unparseable → the **default**, not off and not absent: a garbage value baked into a
  LaunchAgent must not silently disable the release policy, and like `--keep-awake` it still counts as
  "the flag was given" so it overrides (Step 3's) saved setting rather than half-applying.
- Empty env value = absent, matching `--label` and qa.sh §3b's rule.

Verified: `swiftc` warning-clean, `tests/qa.sh` ALL PASS. §3a grew from 5 cases to 18, all behavioral
(caffeinate present or not under a pinned power state) — every threshold case is chosen so the 20%
default gives the *opposite* answer, and two of them were run against a build with the apply call
removed to confirm they actually fail when the flag is unwired. The `%` form, `off` + the 5% floor,
AC-ignores-the-threshold at 100%, the 6% clamp (observed at exactly 6% charge, the only charge that
separates clamped from unclamped), decimal-refused-not-misread (`0.50` at 30%), garbage→default, env,
empty env, and flag-beats-env are each one case. §2 keeps only the fatal contract
(`--battery-threshold` with no value → rc 1); the rc-0 "flag accepted" checks were dropped as
non-functional — §3a asserts what each form resolves to, which is the property that matters.

**Step 3** added `PersistedState.Settings.batteryThreshold`, composed in `persistState()` (still the
only writer) and restored in `applyLaunchBatteryThresholdState()` beneath the flag/env. No new call
site and no ordering change — the restore lands inside the function Step 2 already called before
`startBatteryMonitoring()`.

- Stored as the **charge fraction** (`0.1`), not the whole percent the CLI takes: it is the unit the
  live property holds, so it round-trips exactly and there is one unit inside the app. The two
  spellings only meet at the parser.
- Restored through `Tuning.clampedBatteryThreshold` like every other entry point — a state file is
  untrusted input, not a back door past the 6–100% bounds.
- **Every value restores, `off` included**, which is the one that matters: unlike a saved indefinite
  keep-awake window (withheld because it arms something with no stopping condition), a threshold arms
  nothing. Dropping a saved `off` would silently reinstate the 20% policy the user turned off.
- Known asymmetry, left as-is: `Tuning.clampedBatteryThreshold` maps any `≤ 0` to *off*, so a
  hand-edited **negative** in the state file reads as off, where `--battery-threshold -5` falls back to
  the default (the parser refuses the `-` before the clamp ever sees it). Only reachable by hand-editing
  — the app never writes a negative — and changing it would cost the `0`-spelling of off.

Verified: `swiftc -O -strict-concurrency=complete` warning-clean; `tests/qa.sh` ALL PASS. §3b grew from
12 to 18 cases (see the RUNBOOK §3b paragraph for what the six cover). One is worth its own note: a
wrong-*type* value fails the decode of the **whole file**, not just its field — the Optional fields
absorb missing keys, not garbage — so that case asserts the launch default plus the *presence* of both
blocks afterwards, not that the old `tint` survived. Nothing was readable, so what is under test there
is the single writer's contract, not the old values.

**Steps 4 and 5 landed together**, deliberately: Step 5's whole content is two lines *inside* the
mutator Step 4 creates, and shipping Step 4 alone would have meant committing a menu that looks like it
works and silently doesn't take effect until the next power event. `Settings ▸ Battery Threshold ▸` now
holds `Tuning.batteryThresholdRows` (10/15/20/30%) + `Never` + `Custom…`, with the readout in the parent
row's title and `setBatteryThreshold` as the sole mutator.

- **`Never`, not `Off`, in the menu** (the flag still says `off`, and the parser already accepts
  `never`). `Keep Awake ▸` has an `Off` row two rows away that means *disarm keep-awake*; a second `Off`
  meaning *disarm the threshold* is the kind of collision a user misreads once and then distrusts.
- **The prompt refuses what it can't read instead of defaulting.** This is a deliberate divergence from
  "clamp, never reject": that rule exists because a bad value baked into a login item fires with nobody
  present, where losing the app or the policy is the worse outcome. In a modal someone is right there,
  so applying 20% to a typo would be the surprise — a blank/garbage entry changes nothing, `0` is Never,
  and out-of-*range* numbers still clamp. Negatives are refused rather than collapsing to Never, which
  also resolves the Step 3 asymmetry the right way at the surface where a human types.
- **Catch 1 and Catch 2 both honored**: `setBatteryThreshold` clears `keepAwakeBatteryOverride` (that
  gesture answered a question about the old release point) and never grants it —
  `grantKeepAwakeBatteryOverrideIfOffered` stays gesture-scoped, and a threshold edit is not an arm.
- Selection state uses a 0.05% tolerance rather than `==`. Every surface feeds whole-percent/100, so
  equality would hold today; the tolerance means a future half-percent source falls through to
  `Custom…` instead of marking a row that is merely close. Rows are ≥5% apart, so two can't match.

Verified: `swiftc -O -strict-concurrency=complete` warning-clean; `tests/qa.sh` ALL PASS (unchanged
counts — §3a 18, §3b 18: the menu path adds no scriptable surface). **Not verified: anything requiring a
click.** The menu group, the immediate-apply behavior, the override retirement, and Catch 6 are all
interactive; RUNBOOK §7 gained five checkboxes for exactly those and they have not been run. R5 should
close only after that pass.
