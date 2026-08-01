# R7 — A paused Keep Awake must not look like an off one

**Priority** P3 · **Blocked by** nothing · **Status** **code complete 2026-07-30; one eyes-only check left**

Built, verified and documented: §2's third tone, §3's five catches, §4's hook, and §6's docs (AGENTS.md,
ROADMAP, README, RUNBOOK §3b/§7, DESIGN-system §22.5 incl. the rejected HUD). The only open item is §5's
last box — **perceptibility** — which is a person's job, not a script's. Do that, then delete this file and
retire the ROADMAP row. Two notes on how it was built, both departures worth knowing:

- **The paused state is a second PARAMETER, not a field on `AwakeHold`** (`keepAwakeTintColor(for:paused:)`,
  flag from `keepAwakeArmedNotHolding`, tick guard composed at the call site). §2 said "give the function a
  third tone" without saying how it learns about the pause; `AwakeHold` knows nothing about intent and also
  feeds the This Mac row, so putting it there would have mixed the subject v1.19.1 just separated.
- **Catch 1 is real but defensive, not load-bearing.** Every path that mutates `isEnabled` also calls
  `updateSleepPrevention()`, which repaints synchronously — so no tick-only path today can strand the old
  tone. The paused term is in the signature anyway, because the guard must track everything the tone reads;
  the "will silently half-ship" framing overstated today's call graph.

Replaces `TODO-20260726-2058-r7-keep-awake-notifications.md` (deleted). That plan was an in-app HUD
panel signalling four events. **Rescoped 2026-07-30 to one persistent state change on the track line.**
Why, in one line: the HUD's own listed trade-off — *"no notification centre history, a HUD missed is
gone"* — makes it fail the only case that motivates the feature. The reasoning is in §1; don't re-derive
it, and don't re-propose the panel without reading it.

---

## 1. The problem, and why the old plan missed it

`updateKeepAwakeBar()` sets `bar.isHidden = !hold.isHeld`. A paused Keep Awake has had its `caffeinate`
killed, so with no foreign hold the line goes dark. **Ambiently, `paused` and `off` are the same
picture** — and `labelMode` defaults to `.off`, so for a default user the track line is the *only*
ambient indicator. Nothing outside the menu reports that the thing they switched on stopped.

The old plan signalled four events. Its own reasoning excludes three of them:

| Event | Verdict |
|---|---|
| Engaged | **No signal.** User-initiated — the same argument the old plan used to exclude `Off`. |
| Resumed | **No signal.** Good news nobody is harmed by missing. |
| Expired | **No signal.** The user chose the duration and the menu already carries a live countdown. |
| Paused | **The whole feature.** Fires from a condition the user didn't trigger and can't predict (battery crossing the release threshold, or serious/critical thermal), and silently ends what they asked for. |

And a transient panel is the wrong mechanism for that one: the pause that matters happens overnight, on
battery, during an unattended job. A panel that fades after ~2s has been gone for hours by the time
anyone looks. A **persistent** state change is still there in the morning. That is the entire rescope.

## 2. The change

Give `keepAwakeTintColor(for:appearance:)` a third tone: **armed but nothing holding** → the user's own
chosen tint at a new `Tuning.keepAwakeBarPausedAlpha`, fainter than the existing foreign tone.

Alpha becomes **monotonic in how much hold there is**, which is what keeps this from breaking the
v1.19.0 invariant rather than merely bending it:

| Tone | Meaning |
|---|---|
| Full | our own hold is running |
| `keepAwakeBarForeignAlpha` (0.45) | someone else is holding the Mac |
| `keepAwakeBarPausedAlpha` (new, fainter) | **we are armed and nothing is holding** |
| Hidden | nothing armed, nothing holding |

Read the rule as *brightness tracks the strength of the hold*, not as *lit means held*. Restate it that
way in `AGENTS.md` — the current text says the bar is "keyed on `awakeHold.isHeld`, **not** `isEnabled`",
and that sentence stops being true here. This is the one deliberate invariant change in the task and it
must be written down, not slipped in.

**Deliberately not** an amber/warning colour. It collides with the five-tint palette, and alarm is the
wrong register for this app — the same discipline that keeps the machine row from claiming the Mac won't
sleep. The user's own tint, dimmed, says "your thing, not currently in force" without editorialising.

The **label gets this for free and must**: both surfaces resolve through this one function precisely so
they cannot disagree. Don't special-case one.

## 3. Catches

1. **The 2s tick will not notice the pause edge unless you extend the signature.** This is the one that
   will silently half-ship the feature. `lastAwakeTintSignature` (`:3867`) guards the tick against
   needless redraws, and it is fed by `AwakeHold.tintSignature` (`:4287`) —
   `"\(isHeld)|\(ownRunning)|\(isPartial)|\(foreignOwners.count)"`, which knows **nothing about
   suspension**. Change only the colour function and the bar keeps its old tone until some unrelated
   event happens to call `updateKeepAwakeBar()`. The paused state has to enter that signature.
2. **Read `effectiveKeepAwakeSuspension`, never `keepAwakeSuspension`.** Arming below the threshold from
   the menu sets `keepAwakeBatteryOverride` and the effective value drops `.batteryLow`. An honoured
   override is **running**, and must show the full tone — showing it paused would contradict a gesture
   the user just made.
3. **Foreign hold outranks our pause.** If we are paused and someone else holds the Mac, the Mac *is*
   held: show the foreign tone. Define the precedence explicitly rather than letting branch order decide
   it — the surface reports the machine first.
4. **Render only; persist nothing.** This is reached from `updateSleepPrevention()`, which fires on every
   thermal/battery/power event. The existing rule stands: persist intent, never running state.
5. **Expiry stays invisible, and that is the accepted scope.** A window ending clears intent, so the bar
   goes dark like `Off`. If that turns out to matter it is a separate item, not scope creep into this one.

## 4. Make it functionally testable (do this, don't ship it eyes-only)

Extend `MENUBAR_LOAD_RUNNER_LOG_AWAKE=1` to print the **rendered tint state** alongside the hold state it
already reports (`hold=`, `own=`, `display=`, `idle=`, `owners=`, `row=`). That is a sanctioned hook — it
makes the real thing observable without changing a decision — and it converts this from an eyes-only
change into one `tests/qa.sh` §3a can assert, using the `FORCE_BATTERY` hook that already exists. Without
it this ships as verification debt; with it, only perceptibility does.

## 5. Acceptance criteria

- [x] `FORCE_BATTERY=15:battery` + `--keep-awake 30m` → paused tone, no `caffeinate` child. *(verified live
      2026-07-30: `armed=1 paused=1 tint=paused`, twice, on a quiet machine; qa.sh §3e case 7. That case
      NOTEs while another process holds the display — Brave did, later the same session — which is the
      foreign tone correctly outranking the pause, not a failure.)*
- [x] `FORCE_BATTERY=15:ac` → full tone, child present. *(qa.sh §3e case 5, folded into the existing
      attribution assertion.)*
- [ ] Arming from the menu below the threshold (override honoured) → **full** tone, not paused.
      **Not scriptable** — only a menu click sets the override, so this is a RUNBOOK §3b step, not a qa.sh
      case. §4's claim that the hook left *only* perceptibility eyes-only was wrong about this one.
- [x] A foreign hold while ours is paused → **foreign** tone, not paused. *(qa.sh §3e case 7, second half,
      against `tests/hold-assertion.swift --display`; asserts `paused=1 tint=foreign` — both halves, so it
      can't pass by our pause having silently cleared.)*
- [x] `Off` → hidden. Nothing armed and nothing holding → hidden. *(qa.sh §3e case 6, folded in.)*
- [x] The pause edge repaints on the **2s tick alone**, with no menu interaction (catch 1). *(The verified
      runs above never open a menu, and `tint=` is read off the same function the surfaces call. See the
      status note above on why the signature term is defensive rather than load-bearing.)*
- [x] The label and the bar always agree. *(Structural: one function, two call sites, `updateKeepAwakeBar`
      calls `updateValueLabel` — unchanged from v1.19.0.)*
- [ ] **Perceptibility — the one eyes-only criterion, and the real risk.** The paused tone must be
      distinguishable from both the lit and the dark states on a 2pt line, in light and dark menu bars.
      If it is not, the feature is a no-op that tests green. Tune the alpha against a real menu bar
      before closing; if it can't be made to read, fall back to a desaturated tone and say so here.

## 6. Docs to touch

`AGENTS.md` (Keep Awake — restate the bar's keying per §2), `docs/ROADMAP.md` (R7 row: retire on ship;
its pointer already targets this file), `README.md`, `docs/RUNBOOK-qa-release.md` (Keep Awake steps),
and `DESIGN-system.md` §22.5 (the track-line indicator) — plus a note there recording the rejected HUD,
since "notify on Keep Awake events" is the intuitive proposal that will otherwise come back.

## 7. Still-live alternative: decline R7 instead

Worth keeping on the table until someone commits. Pause requires battery below the release threshold or
serious thermal, so it never fires on a desktop or a plugged-in laptop; the menu already explains it in
two places when opened; and the recorded position on this feature area is that the overnight case wants
a timed release and a countdown, not a state machine around it. Closing R7 with that reasoning is
cheaper than building this and is not a failure — but it should be a decision, not a lapse.
