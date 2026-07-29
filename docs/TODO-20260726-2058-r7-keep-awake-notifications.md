# R7 — Ambient signal for Keep Awake engage / pause / expiry

**Priority** P3 · **Blocked by** nothing. **Implementation is settled: an in-app HUD panel.**
System notifications are off the table — they need a bundle, and the project decided on 2026-07-26 to
stay a source-built, bundle-less binary (see the Declined table in `ROADMAP.md`).

Line anchors below are against **v1.14.0** (`MenuBarLoadRunner.swift`, 4553 lines) and are now
**~1,100 lines stale** — the file is 5647 lines at v1.17.1. Assume no `:NNN` lands; resolve every one by
symbol.

**Re-checked against v1.17.1 on 2026-07-29 — the plan still applies unchanged.** Every symbol it depends
on is present and has the shape described (`SleepPreventer`, `onWindowExpired`, `keepAwakeStatusItem`,
`keepAwakeBar`/`updateKeepAwakeBar`), and nothing has been built toward it: the source has zero matches
for `HUD`, `NSPanel`, or `UNUserNotification`. What *has* changed around it is that `Keep Awake ▸` grew
the `Other Assertions` section (v1.17.0, regrouped per owner in v1.17.1), so the submenu is more crowded
than when this was written — which strengthens the case for an ambient signal outside the menu, not a
sixth row inside it.

Today, engaging, pausing, and expiry are silent unless the menu is open. The 2pt track line
(`keepAwakeBar`) is the only ambient signal, and it conveys running/not-running — never *why*.

---

## Why not a system notification (verified 2026-07-26, not inferred)

A bundle-less binary **cannot** use `UserNotifications`. Calling
`UNUserNotificationCenter.current()` raises:

```
NSInternalInconsistencyException: bundleProxyForCurrentProcess is nil:
mainBundle.bundleURL file:///…/menubar-load-runner/tmp/
```

and terminates the process. This is a hard crash inside `+[UNUserNotificationCenter
currentNotificationCenter]`, not a nil return or a permission denial — there is nothing to guard
against. `NSUserNotification`, the old bundle-tolerant API, is removed.

The bundle that would fix this was declined on cost grounds. So the HUD below is the implementation,
not a fallback — build it and close R7.

## The implementation — in-app HUD

A borderless, non-activating panel near the menu bar that fades in, holds ~2s, fades out.

```
NSPanel(styleMask: [.borderless, .nonactivatingPanel])
  .level = .statusBar          // above normal windows, below the menu itself
  .isFloatingPanel = true
  .hidesOnDeactivate = false
  .ignoresMouseEvents = true   // never steal a click from the menu bar
  .collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
```

Roughly 120-150 lines: the panel, a `CATextLayer`/`NSTextField` body, a fade in/out via
`NSAnimationContext`, and a coalescing timer so two events 200ms apart do not stack.

Placement: `NSScreen.main` (the screen with the key window / mouse), top-right, inset below
`NSStatusBar.system.thickness`. Do **not** cache the frame — `screenObserver`
(`MenuBarLoadRunner.swift:2566`) already exists for resolution/arrangement changes and the panel must
be repositioned or dismissed there.

Trade-offs, stated plainly:
- It bypasses Focus / Do Not Disturb. A custom window will pop over a presentation. Either respect
  focus manually (no clean public API for an unbundled app) or accept it and keep the HUD rare.
- No notification centre history — a HUD missed is gone.
- No Notifications pane in System Settings, so the only way to turn it off is the app's own setting.
  `Settings ▸` (`:2405`) and `PersistedState.Settings` (`:870`) both exist now, so a toggle has a home
  — decide between unconditional-but-rare and a persisted setting; don't leave it unswitchable.

---

## What to signal

| Event | Fires from | Text |
|---|---|---|
| Engaged | `selectKeepAwakeOption`, `armKeepAwake` | `Keep Awake on` / `Keep Awake on until 8:18 PM` |
| Paused | `updateSleepPrevention` when `effectiveKeepAwakeSuspension` goes nil → non-nil | `Keep Awake paused — <reason>` (reuse `KeepAwakeSuspension.reasonText`, `:633`) |
| Resumed | same, non-nil → nil | `Keep Awake resumed` |
| Window expired | `SleepPreventer.onWindowExpired` | `Keep Awake window ended` |
| Off | `selectKeepAwakeOption` (Off row) | nothing — the user just did it, they know |

**Not** signalled: tint changes, battery-% ticks, every `conditionsDidChange()` call.

## Catches

1. **`updateSleepPrevention()` runs on every thermal/battery/power event.** It is called far more often
   than the state changes. Notify on the *edge* only — cache the previous
   `effectiveKeepAwakeSuspension` and compare. This is exactly the reason `persistKeepAwakeState()` is
   deliberately not called from here (`AGENTS.md`, Keep Awake section); the same discipline applies.
2. **Expiry must not resurrect intent.** `onWindowExpired` arrives via `Process.terminationHandler`,
   and `kill()` detaches that handler and bumps `generation` precisely so an intentional Off/suspend is
   not misread as a window elapsing. The notification hook must sit on the *expiry* path only, or an
   Off will announce "window ended".
3. **Honour `suppressModalAlerts`.** Every user-facing surface already does (`informational(_:)`,
   `:2852`; the update probe; `promptSelfUpdate`). A HUD or a notification firing during
   `tests/qa.sh` §3/§3a would make headless QA interactive. Route through the same flag.
4. **The override interacts.** Arming below 20% sets `keepAwakeBatteryOverride`, so
   `effectiveKeepAwakeSuspension` drops the `.batteryLow` reason. Read the *effective* value, never
   `keepAwakeSuspension` — otherwise an honoured override announces a pause that is not in force.
5. Coalesce. Plug/unplug bounces can fire several power-source notifications in a second.

## Acceptance criteria

- [ ] Engage, pause, resume, and expiry each produce exactly one signal, and no signal fires on a
      no-op `conditionsDidChange()`.
- [ ] `MENUBAR_LOAD_RUNNER_FORCE_BATTERY=15:battery` (the §3a hook) produces a pause signal;
      `…=15:ac` does not.
- [ ] Nothing appears during a `suppressModalAlerts` run; `tests/qa.sh` stays non-interactive.
- [ ] The panel never takes focus — the menu bar stays clickable while it is visible — and
      repositions or dismisses on a display change.
- [ ] Toggling the tint produces no signal.

## Docs to touch

`docs/ROADMAP.md` (R7 — drop the row once the HUD ships), `AGENTS.md` (Keep Awake section),
`README.md`, `docs/RUNBOOK-qa-release.md` (Keep Awake steps).
