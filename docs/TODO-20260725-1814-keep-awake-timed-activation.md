# TODO — Keep Awake: timed activation ("for the next __ hr __ min")

Created 2026-07-25 18:14. Status: **implemented** 2026-07-25 (preset windows 30m/1h/2h/4h/8h + custom;
verified by scratch-build runs — spawn args `-di -t <secs> -w <pid>`, natural expiry, intentional-Off
guard, and window replacement on re-arm; then dogfooded through the real menu — armed via AppleScript
clicks, `-t 1800` observed, countdown ticking 28:32 → 28:30 → 28:27, Off tearing it down). The countdown
was minute-rounded in the first cut and reworked to seconds + wall-clock end time after review.

## Why

`Keep Awake` is indefinite-only today: pick a color, caffeinate runs until you pick `Off` or quit.
The actual use is a bounded window — set a few hours for a long unattended task, go to bed, let the
Mac sleep on its own afterward. So: **a timed release with a countdown.** Nothing more.

## Design

`caffeinate` already does all of it. Verified:

```
$ time /usr/bin/caffeinate -di -t 3 -w $$
0.00s user 0.00s system 0% cpu 3.152 total    # exit 0
```

1. **Release** — add `-t <seconds>` to the spawn args. caffeinate exits on its own at the deadline;
   the Mac then sleeps per Energy Saver. Pass args as separate array elements (`"-t", "180"`), not
   KYA's single `"-t 180"` token.
2. **Notice the exit** — `Process.terminationHandler` clears `process` and calls back to disengage
   (hide the bar, move the radio mark to `Off`). Same mechanism as `KYASleepWakeTimer.m:122`.
   **Nil the handler inside `kill()` before `terminate()`**, or MLR's own condition-suspend
   (battery ≤20%, serious/critical thermal) reads as an expiry and clears the user's intent — the
   thing the `isEnabled`/`isRunning` split exists to prevent. KYA guards this the same way
   (`KYASleepWakeTimer.m:129-131`).
3. **Countdown** — store the deadline as a `Date` when arming. It is the source of truth for the
   displayed remaining time, and `deadline.timeIntervalSinceNow` is also what a respawn passes to
   `-t` (the condition-suspend path can kill and later respawn; using the original duration there
   would extend the window). One expression, both uses.
4. **Refresh** — the countdown text updates from `refreshKeepAwakeSelectionState()`, already called
   from `menuWillOpen` and `updateSleepPrevention()`; add the 2s tick (`sampleSystemLoad`,
   `MenuBarLoadRunner.swift:2465`) so an open menu counts down live. KYA never got here — its
   live-update method is dead code behind `// TODO: Use this for live updates of the menu item`.

No separate expiry enforcement path, no timers of our own, no sleep/wake observers. `-t` is the
mechanism; the deadline is display state.

## Menu shape

Current submenu is one merged radio group (`Off` + 5 tints), built at `MenuBarLoadRunner.swift:2003-2021`.
Add a second, independent radio group below it (tint × duration as rows would be 30 items):

```
Keep Awake: 29:24 ▸
  ● Off / Dusty Teal / Sand / Graphite / Mauve / Sage     ← unchanged group
  ────────────────
  Duration
  ● Until turned off
    30 minutes / 1 hour / 2 hours / 4 hours / 8 hours
    Custom…
  ────────────────
  29:24 left (until 8:18 PM)                              ← disabled row, hidden when indefinite
```

- Picking a duration while `Off` engages with the current tint (one click to arm).
- Picking `Off`, or `Until turned off`, clears the deadline.
- A custom window marks the `Custom…` row. (KYA leaves nothing marked when the interval matches no
  row — reachable via its URL scheme. Don't reproduce that.)
- Parent title carries the remaining time via a `MenuTitle.keepAwake(_ suffix:)` helper, same pattern
  as `MenuTitle.label(_:)` (`MenuBarLoadRunner.swift:289`).
- Format the countdown positionally at **seconds** resolution (`29:24`, `1:29:24`) and show the
  wall-clock end time next to it (`29:24 left (until 8:18 PM)`). A minute-rounded value (the first cut,
  and KYA's `.short`-style phrasing) reads as *the duration you picked* and sits frozen for a minute —
  it's a countdown, so it has to tick. A 1s ticker runs only while the menu is open (that's the only
  time the row is visible); the 2s load tick keeps it current for the next open. Monospaced-digit font so the row doesn't jitter under an open menu.
- Own `@objc` handler (`selectKeepAwakeDuration(_:)`). Do not extend `selectKeepAwakeOption` — its tag
  space is `KeepAwakeColor.rawValue` (0…4) plus `keepAwakeOffTag` (-1).

## Custom prompt

Reuse the `promptCustomLabel()` NSAlert + accessoryView + `initialFirstResponder` pattern
(`MenuBarLoadRunner.swift:3072-3113`) with `Hours` and `Minutes` fields, pre-filled `1 hr 0 min`.
Clamp minutes to 0–59 and hours to `Tuning.keepAwakeMaxDuration` (24h); treat `0 hr 0 min` as Cancel.
KYA rejects out-of-range input with an inline error instead of clamping (`KYAAddDurationViewController.m`)
— clamping is better here; a validation dialog at bedtime is worse than a silently sane value.
Keep the alert dismissible: per CLAUDE.md, a run wedged in a modal forces a manual `pkill`.

## Steps

1. `Tuning` — `keepAwakeDurations: [TimeInterval]`, `keepAwakeMaxDuration`. No inline literals.
2. `MenuTitle` — duration titles, `Duration` header, countdown row, `keepAwake(_:)` qualifier.
3. `SleepPreventer` — `spawn(remaining:)` appending `-t`, `terminationHandler` + the intentional-kill
   guard, `applyConditions(suspend:remaining:)`.
4. App — `keepAwakeDeadline: Date?`, `selectKeepAwakeDuration(_:)`,
   `promptCustomKeepAwakeDuration()`, countdown in `refreshKeepAwakeSelectionState()`, tick wiring.
5. Build: `swiftc -O -strict-concurrency=complete MenuBarLoadRunner.swift -o tmp/mblr-check`.
6. Docs: README `Menu actions` Keep Awake bullet, CLAUDE.md Keep Awake bullet, `CHANGELOG.md`.

## Test plan

Short windows; verify with `pgrep -fl caffeinate` and `pmset -g assertions`.

- Arm 1 minute → args show `-di -t 60 -w <pid>`, assertion present. After ~60s: no caffeinate, no
  assertion, bar hidden, mark back on `Off`, countdown row gone.
- Countdown ticks down live with the menu held open.
- Tint change mid-window: deadline unchanged, no respawn (`spawn()` is guarded by
  `process == nil`, `MenuBarLoadRunner.swift:1535`).
- Condition-suspend mid-window (test build with a raised `Tuning.batteryLowThreshold`): bar hides,
  `Off` mark does **not** move; on clear, respawns with the *remaining* time, not the original.
- Real use: 2-minute window with `sudo pmset displaysleep 1` → display holds through minute 1, sleeps
  after expiry. Restore the pmset value.
- Custom prompt: `0 hr 0 min` cancels; `25 hr` clamps; `90 min` clamps to 59.

## Open decision

Preset list — proposed 30m / 1h / 2h / 4h / 8h, biased to multi-hour unattended runs (KYA's is
5m/10m/15m/30m/1h/2h/5h). Add a 15m row for short "don't sleep while I read" use, or leave that to
`Custom…`?

## Out of scope

No CLI/env surface, no persistence across relaunch (the binary has no bundle id — see
`MenuBarLoadRunner.swift:2141`), no notification at expiry, no forced sleep (`pmset sleepnow`), no
URL scheme. Expiry is a *time* promise, not a *task* promise: we release the assertion whether or not
the user's job finished — worth one sentence in the README.
