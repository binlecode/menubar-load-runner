# TODO: Keep Awake submenu — two sections, stated scope

**Date:** 2026-07-30
**Scope:** `Keep Awake ▸` submenu only (`MenuBarLoadRunner.swift`)
**Status:** Implemented, pending §7 eyes-on

---

## 1. Problem Statement

In MLR v1.19.0 the `Keep Awake` submenu gained a machine-status row (`Mac held awake — caffeinate`)
above the `Off`/tint radio group.

When the Mac is held awake by an external `caffeinate` (a terminal, `keep-awake.sh`, Zoom, a backup):

* the top row reads `Mac held awake — caffeinate`, while the radio group two rows below still marks **`Off`**;
* read together they look like a contradiction — *"why does it say Off when the Mac is being kept awake?"*

The two rows have **different subjects** — one reports the machine, one reports this app — and nothing in
the layout said so. A separator was carrying the entire weight of that distinction.

---

## 2. Rejected: unify the state into one On/Off

The original proposal here was to drive a single `On`/`Off` from *any* active assertion and have `Off`
clear them all. **Declined 2026-07-30** — it breaks four things:

1. **`Off` cannot release a foreign hold.** An IOKit assertion is releasable only by its owner; the only
   way to "clear" a terminal `caffeinate` is to kill someone else's process — possibly another user's.
   Hence the standing invariant: *`Off` can only release ours*.
2. **Foreign state would masquerade as user intent.** The tint and duration rows encode *our* intent; a
   foreign hold has neither, so there is no honest row to mark, and the group would flip to `Off` on its
   own when that process exits. The `isEnabled`/`isRunning` split exists to stop exactly this, and intent
   is persisted — foreign state must never reach the state file.
3. **"Any assertion → On" is a false claim.** `PreventUserIdleSystemSleep` alone does not hold the
   display and the system follows the display down — the reason this app spawns `-di`. An idle-only
   foreign hold would render `On` while the Mac in fact sleeps.
4. **Menu-gated sampling restores the founding bug.** A `menuWillOpen`-only read that lands inside a
   renewal loop's gap reports `none` while a loop is holding. The 2s sample costs ~126 µs (0.006% duty),
   and the bar/label tint need the state while the menu is **closed** anyway.

The confusion in §1 was real; the diagnosis (too many states) was wrong. It was a **layout** problem —
two subjects interleaved with no stated boundary.

---

## 3. Implemented: group by subject, name the scope

Reorder into two sections and add one header row. No behavior, no new state, no invariant touched.

```
Mac held awake — caffeinate · until 12:05 PM     ← §1 THIS MAC (read-only, unheaded)
Other Assertions
    caffeinate ×2 — PreventUserIdleSystemSleep
──────────────
This App                                          ← §2 THIS APP (disabled header, new)
Off ●  ·  Dusty Teal … Sage
──────────────
Duration
Until turned off · 30 min … 8 hours · Custom…
──────────────
3:59:12 left (until 8:18 PM)                      ← hidden with its separator when idle
```

Three changes:

* **`Other Assertions` moves from last to directly under the machine row**, where it reads as that row's
  evidence: the row names who holds sleep, the list shows the raw assertions behind it. Previously the
  machine's story was split across the whole submenu with this app's controls wedged in the middle —
  that sandwich is what made the `Off` mark look like a rebuttal.
* **A disabled `This App` header** opens section 2. `Off` under it cannot be read as a claim about the
  Mac. Section 1 needs no header: the machine row is its own headline.
* **The countdown/paused row's separator is now stored and hidden with the row.** That row became the
  submenu's last, and AppKit trims a *leading* separator, not a trailing one.

Section 1 is exactly the rows that report the machine; section 2 is exactly the rows that act on this
app. Nothing straddles.

### Why not merge the assertion list into the machine row

Considered, and rejected: it renegotiates `none`-is-a-row (the machine row's `Nothing holding sleep`
would have to serve as the none-answer), and the "other"-scoping goes implicit — with our own window
armed the machine row says `this app` but no detail row corroborates it, since our own child is
deliberately excluded from the list.

### Why the tint/Duration separator stays

Two independent radio groups adjacent with only a disabled header between them is the same
under-signalled boundary this TODO exists to fix. One row is worth the clarity.

---

## 4. Verification

* Builds warning-clean (`swiftc -O -strict-concurrency=complete`).
* `tests/qa.sh` (core + gui) **ALL PASS** — §3d (6) and §3e (4) cover the assertion list and the machine
  row and are unaffected by the move, as expected: every refresher addresses stored arrays
  (`otherAssertionRowItems`, `keepAwakeOptionItems`, …), never menu positions.
* `tests/menu-dump.applescript` enumerates rows generically, so it needs no index edits — but it is the
  **only** mechanical check of row order and must be run once by a human (Accessibility grant; an agent
  has none). RUNBOOK §7 gained a bullet for the two-section order, the `Off`-under-`This App` reading
  against a live foreign hold, and the no-dangling-separator case.

**Open (eyes-only, §7):** the rendered order, the header's disabled styling, and that the countdown
row's separator disappears with it.

---

## 5. On close

Fold §2 (the rejected unification, with its four reasons) and §3's subject-grouping rule into
`DESIGN-system.md` §22.11, retire any ROADMAP row, and delete this file.
