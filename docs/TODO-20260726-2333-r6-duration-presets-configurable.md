# R6 — Keep Awake duration presets as data

**Priority** P4 · **Blocked by** nothing. `PersistedState.Settings` (`:870`) shipped in v1.14.0.

Today the timed-release rows come from a hardcoded array (`Tuning.keepAwakeDurations`, `:264`). Move
the list into the settings block so it can be added to, removed from, and reordered by editing
`state.json`. **Scope is add/remove/reorder-by-file only** — no in-app editor (wants a Preferences
window, deferred) and no set-default (a different feature, see Catch 6).

Line anchors are against **v1.14.0** (`MenuBarLoadRunner.swift`, 4553 lines). Re-resolve by symbol if
they don't land.

---

## What exists now

| Piece | Anchor | Note |
|---|---|---|
| `Tuning.keepAwakeDurations` | `:264` | five entries, 30m…8h |
| `KeepAwakeDuration.presetRows` | `:519-521` | `static var`; **prepends `.indefinite`**, so row 0 is not a duration |
| Row construction | `:2459-2466` | once, in `applicationDidFinishLaunching`; `item.tag = index` into `presetRows` |
| `keepAwakeDurationItems` | `:2157` | the stored array the refresher addresses |
| Selection refresh | `:3351-3358` | marks by index; falls through to `Custom…` when nothing matches |
| Click handler | `:3648-3651` | reads its own tag, bounds-checked against a freshly computed `presetRows` |

## Step 1 — Back the list with settings

```swift
// PersistedState.Settings (:870)
var keepAwakeDurations: [TimeInterval]?   // nil / absent / malformed → Tuning.keepAwakeDurations
```

Keep `Tuning.keepAwakeDurations` as the default — don't delete it.

`presetRows` can no longer be a static read of `Tuning`. Make the list an explicit input:

```swift
static func presetRows(for durations: [TimeInterval]) -> [KeepAwakeDuration]
```

Three call sites: the row build (`:2459`), the refresher (`:3351`), the handler (`:3649`). Do not keep
a static that reads a mutable global — that reintroduces exactly the hidden coupling the tag comment at
`:2155` warns about.

## Step 2 — Sanitize on load (this is the actual work)

`sanitizeDurations(_:) -> [TimeInterval]`, applied once at launch:

- drop non-finite and `<= 0`;
- **floor to whole minutes and drop anything under 60s** — see Catch 1;
- clamp each to `Tuning.keepAwakeMaxHours * 3600` (`:265`), matching `parse` (`:603`) and the custom
  prompt (`:3783`);
- de-duplicate — a repeated value renders two identically-titled rows, and the second can never be
  marked, since `:3354` matches the first;
- cap the count (8 is reasonable) so the submenu can't be grown into a scroller;
- empty result → the `Tuning` default.

**Do not sort.** File order is display order; that ordering *is* the reorder control for now, and
silently re-sorting takes away the only one the user has.

## Step 3 — Document the file, since there is no UI

`~/Library/Application Support/menubar-load-runner/state.json` (override:
`MENUBAR_LOAD_RUNNER_STATE_FILE`), field `settings.keepAwakeDurations`, seconds as plain numbers,
**relaunch to apply**, and malformed input falls back silently by design (`:884-887`).

---

## Catches

1. **A sub-minute entry produces a broken row.** `menuTitle` (`:531-534`) formats with
   `[.hour, .minute]` and `.dropAll` (`:541-542`), so 30s formats to an empty string — the row renders
   blank or falls through to the indefinite title, giving two rows reading "Until turned off", the
   second of which arms a 30-second window. Reject sub-minute entries in the sanitizer; do not lean on
   the formatter to catch this.
2. **Tags are positional.** `item.tag = index` (`:2462`) indexes `presetRows`, and the handler
   bounds-checks against a `presetRows` recomputed at click time (`:3650`) — that catches
   out-of-range, not wrong-but-in-range. The list is read only at launch (`state.json` is never
   re-read after startup — see `applyLaunchLabelState` `:3720` / `applyLaunchKeepAwakeState` `:3737`).
   **Keep it that way.** If a live-reload path is ever added, it must rebuild the rows and re-tag in
   the same pass.
3. **Row 0 is `.indefinite`, not a duration** (`:520`). N configured entries make N+1 rows and every
   tag is offset by one. Map a tag back to a duration through `presetRows`, never by indexing the
   settings array.
4. **Leave the `Custom…` fallback alone.** `:3358` marks `Custom…` when no preset matches, which is how
   a *restored* window correctly reads (what resumed is the remainder, not the length originally
   picked — `AGENTS.md`). A user-added preset makes an accidental exact match marginally more likely
   (restoring with exactly 30m left would mark "30 minutes"). Harmless and vanishingly rare — note it
   so nobody "fixes" the fallback.
5. **`persistState()` is the only writer** (`:3689-3692`). This array is settings state the app reads
   but never mutates; it still has to be composed into every save (`:3707`), or the first tint change
   wipes the user's list. That is precisely the failure the single-writer rule exists to prevent.
6. **Set-default is out of scope.** "Default" today means which row is marked with nothing armed —
   `Until turned off` holds it (`:3348-3350`) because it describes what turning Keep Awake on from
   there would do. Changing that means changing what an arm-without-a-duration *means*, which touches
   `armKeepAwake` (`:3656`), the launch path, and `--keep-awake on`. Keep it on the roadmap.

## Acceptance criteria

- [ ] `swiftc -O -strict-concurrency=complete` is warning-clean.
- [ ] No settings block, or the field absent → the five stock rows, unchanged order and titles.
- [ ] `{"settings":{"keepAwakeDurations":[600,1800,21600]}}` → exactly four duration rows (Until turned
      off + 3) in file order, verified with `tests/menu-dump.applescript` (menus aren't scriptable from
      `qa.sh` — see the §3b header comment).
- [ ] Clicking the third row arms 6h: the countdown reads ≈ `5:59:5x`.
- [ ] All-invalid input (`[0, -5, 30]`) and a type-mismatched value both → stock list, rc 0, no modal.
- [ ] `90000` (25h) clamps to 24h; duplicates collapse; more than 8 entries truncate.
- [ ] A tint change after launch rewrites `state.json` with the custom array intact (§3b's
      single-writer invariant, applied to this field).
- [ ] `tests/qa.sh` §3a and §3b stay green; add a §3b case asserting the array round-trips.

## Docs to touch

`AGENTS.md` (the `PersistedState` two-blocks paragraph, and the Keep Awake timed-release paragraph
which names `Tuning.keepAwakeDurations` as the source), `README.md` (a short "customizing the duration
list" note), `docs/RUNBOOK-qa-release.md` §7 (the `menu-dump` check), `docs/ROADMAP.md` (R6 narrows to
the reorder-UI/set-default remainder rather than closing outright), `CHANGELOG.md`.
