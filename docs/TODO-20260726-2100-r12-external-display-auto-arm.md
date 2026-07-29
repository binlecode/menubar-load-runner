# R12 — Arm Keep Awake when an external display connects

**Priority** P3 · **Status** candidate — design open, **do not implement as specified**.
**Blocked by** nothing. The opt-in toggle it needs now has a home: `Settings ▸` (`:2405`) and
`PersistedState.Settings` (`:870`) shipped in v1.14.0.

The roadmap says the wiring is nearly free and the asymmetry is the problem. Both are true. Two more
things surfaced while writing this up, and either could sink the item.

Line anchors below are against **v1.14.0** (`MenuBarLoadRunner.swift`, 4553 lines) and are now
**~1,100 lines stale** — the file is 5647 lines at v1.17.1. Assume no `:NNN` lands; resolve every one by
symbol (`screenObserver` is registered near `:3222`, `conditionsDidChange()` near `:5115`, `Settings ▸`
near `:2971`, `PersistedState.Settings` near `:1283`).

**Re-checked against v1.17.1 on 2026-07-29 — status is unchanged: still a candidate, still do not
implement as specified.** The wiring premise holds (`screenObserver` still calls only `applySizing()` /
`renderCurrentFrame()`, so adding `conditionsDidChange()` is still the one-line change), and the blocker
is still not code: `tests/clamshell-sleep-check.sh` has been committed since 2026-07-27 (`da65f63`) and
**trial 2 is still unrun** — it needs physical lid open/close and real idle time. Nothing in this file
can be settled from a keyboard.

---

## The wiring (the easy part)

`screenObserver` (`MenuBarLoadRunner.swift:2566`) already watches
`NSApplication.didChangeScreenParametersNotification` and currently only calls
`applySizing()` / `renderCurrentFrame()`. Adding `conditionsDidChange()` (`:4027`) to it is a one-line
change. Nothing else in the observer plumbing needs to move.

## Problem 1 — the asymmetry (from the roadmap, still the core issue)

Every condition in `keepAwakeSuspension` (`:4041`) returns a reason to turn keep-awake **off**.
Nothing in the model turns it **on**. Auto-engage inverts that, and needs a matching auto-disengage on
unplug or the lock outlives its reason.

The clean shape is a **third intent state**, not a fourth suspension reason:

| State | Set by | Cleared by |
|---|---|---|
| off | default, Off row | — |
| user-armed | tint row, duration row, `--keep-awake`, restored window | Off row, window expiry |
| **auto-armed** | external display connect (opt-in only) | display disconnect |

Rules that fall out:
- Auto-arm only from **off**. Never override or extend a user-armed window.
- Any explicit gesture while auto-armed **promotes to user-armed** and clears the auto flag — otherwise
  unplugging silently undoes a choice the user just made by hand.
- Suspension still wins: `effectiveKeepAwakeSuspension` (`:4058`) is unchanged, so a low battery still
  pauses an auto-armed window. Auto-arm decides *intent*; suspension decides *running*. Do not
  conflate them — that split is the whole reason `SleepPreventer` separates `isEnabled` from
  `isRunning`.
- **Never persist the auto-armed flag.** It is derivable from the screen count at launch, and
  restoring "auto-armed" with nothing plugged in is precisely the stale-flag failure that made saved
  *indefinite* windows non-restorable. The opt-in toggle persists; the state does not.

## Problem 2 — `didChangeScreenParametersNotification` is not a connect/disconnect event

It also fires on resolution changes, arrangement changes, scale-factor changes, and **display sleep and
wake**. Acting on every notification would arm and disarm on ordinary display sleep.

Mitigations, both needed:
- Compare against a **cached screen fingerprint** and act only on a real transition, not on every
  notification.
- **Debounce.** A single physical connect fires several notifications in a row as the arrangement
  settles; coalesce over ~1s before deciding.

`NSScreen.screens.count > 1` is also the wrong predicate on its own:
- **Clamshell with one external display reports count == 1** — the built-in panel is gone from the
  list. The single most common "external monitor" setup would not trigger.
- **Mirroring** can collapse to one entry.

The better predicate is "is there a non-built-in screen": for each `NSScreen`, read
`deviceDescription[.init("NSScreenNumber")] as? CGDirectDisplayID` and test
`CGDisplayIsBuiltin(id) == 0`. Verify this on the target hardware before committing — it is the load-
bearing detection and the failure mode is silent.

## Problem 3 — check the use case actually pays off

The scenario people mean by "arm on external display" is usually *lid closed, driving a monitor*. Two
things to confirm before building:

1. With an external display and power connected, clamshell operation is macOS's normal supported mode
   and the Mac does not idle-sleep the way the roadmap's "clamshell sleep can't be prevented" known
   limit describes — that limit is about lid-closed with **no** external display or power. Confirm the
   distinction holds; if it does not, R12 is decoration.
2. If the Mac is already staying awake on its own in the intended scenario, the feature's real value is
   the *display* half of `caffeinate -di` (no screensaver / display sleep on the external panel), which
   is a narrower and more honest pitch than "keep awake when docked".

If neither survives contact, decline R12 with that reason rather than shipping a toggle nobody needs.

## Sequencing

1. **Settle Problem 3 first** — a 20-minute empirical check, no code. If the docked Mac already stays
   awake, decline the item instead of building it.
2. The opt-in toggle. Auto-arm must default off — silently holding a Mac awake because a monitor was
   plugged in is exactly the surprise `--replace` was declined for. It goes in `Settings ▸` and
   persists via `PersistedState.Settings`; the *state* does not persist (see Problem 1).
3. Then Problems 1 and 2, which are a day of careful work, not a one-line observer change.

## Acceptance criteria

- [ ] Default off. With the setting off, connecting a display changes nothing.
- [ ] With it on: connect from idle → armed indefinite; disconnect → disarmed.
- [ ] With it on and a **user-armed** window already running: connect and disconnect both leave the
      window untouched, including its deadline.
- [ ] Auto-armed, then the user picks a duration → the window survives a later disconnect.
- [ ] Display sleep/wake, a resolution change, and a rearrangement each cause **no** state change.
- [ ] Auto-armed + `MENUBAR_LOAD_RUNNER_FORCE_BATTERY=15:battery` → paused with the battery reason,
      intent intact; back to `:ac` → running again.
- [ ] Quit and relaunch while auto-armed with the display still attached → re-derived, not restored
      from disk. State file contains no auto-arm field.
- [ ] Clamshell + single external display is detected (Problem 2's predicate), verified on hardware.

## Docs to touch

`docs/ROADMAP.md` (R12 — move out of Candidate or decline it with the Problem 3 finding),
`AGENTS.md` (Keep Awake section: the intent model gains a third state), `README.md`,
`docs/RUNBOOK-qa-release.md`.

---

## Status as of 2026-07-28

**Problem 3 is unresolved. Zero trials have been run. The build-vs-decline call is unmade.**
Nothing in `MenuBarLoadRunner.swift` has changed for R12.

### Done

- **Probe harness committed** — `tests/clamshell-sleep-check.sh` (`da65f63`). Three trials, `mark`/
  `report` around a physical action, mining `pmset -g log` after the fact because the signal being
  measured *is* the machine sleeping, which suspends any watcher. `--help` is the protocol and the
  source of truth; `docs/RUNBOOK-qa-release.md` lists it as a diagnostic, not a coverage tier.
- **Problem 2's predicate half-verified** on Mac16,5 + one external (Sceptre Z32), **lid open**:
  `deviceDescription["NSScreenNumber"]` → `CGDisplayIsBuiltin` works, and `hasExternalDisplay` agrees
  with the naive `count > 1`. The clamshell case the TODO actually rests on — `count == 1` while
  `hasExternalDisplay` stays true — is **still unverified**, and its failure mode is silent.

### Measured facts (not findings)

- `powerd` holds a **display-gated** assertion, `PreventUserIdleSystemSleep` named "Prevent sleep
  while display is on". System idle sleep is therefore downstream of the *display* sleeping.
- This machine's AC timers: `displaysleep 10`, `sleep 1`.

**Do not promote this into a finding.** It *suggests* a docked idle Mac sleeps ~11 min in (display
off, then powerd releases, then system sleep), which would mean R12 has real value — but that is an
inference from an assertion's *name*, never observed. Trial 2 is what settles it. Writing the
inference into the roadmap is precisely the silent-failure mode Problem 2 warns about.

- `pmset -g log` history is **inconclusive**, not supportive: every logged `Clamshell Sleep` pairs
  with an AC→battery transition within ~5s, i.e. the undock pattern (display and power pulled, lid
  shut). There is no logged instance of this Mac sitting docked *and* idle long enough to find out.

### To continue

Run the protocol in `tests/clamshell-sleep-check.sh --help`. The blocker is **physical, not code**:
lid open/close, five untouched minutes per trial, and a machine with no sleep-assertion holders
(`preflight` enumerates them by role and must exit 0). Roughly 25 min with `fast`, ~35 without.
Then fill in the decision table from `--help` and either decline R12 here with the Problem 3
finding, or move it out of Candidate with Problems 1 and 2 as the remaining work.

Reports land in `tmp/r12-state/report-*.txt`, which is gitignored — the verdict has to come back
into this file and `docs/ROADMAP.md` or it evaporates.
