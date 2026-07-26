# ROADMAP

Standing tracker for open work, declined proposals, and known limits. Created 2026-07-26, at
v1.13.0.

**What belongs here:** the *what* and *when* — an item, its priority, its status, what blocks it,
and any implementation catch a future implementer would otherwise trip over. One line per item, kept
current.

**What doesn't:** design rationale and tradeoff essays. When an item's *why* is longer than a
sentence, it belongs in a design note, not here — this file stays scannable. Declined items keep a
one-line reason so nobody re-proposes them from scratch, not the full argument.

Items are numbered `R<n>`, assigned once and never reused. Priorities: **P1** a user-visible defect
or silent failure · **P2** a real capability gap · **P3** nice to have · **P4** parity for its own
sake. Nothing here is a commitment or a date.

---

## Open

| ID | Item | Pri | Blocked by |
|---|---|---|---|
| R2 | **No automation interface of the app's own.** `--keep-awake` and every other flag are launch-time only, and the per-user singleton refuses a second invocation, so a *running* instance can't be driven by any interface this app declares. (Accessibility scripting can puppet any app's menus, but that's an OS affordance, not an interface this app offers, and it depends on menu wording that changes.) The obvious answer, a URL scheme, wants an app bundle — so this is coupled to R3. | P2 | R3 |
| R3 | **Bundle-or-not is undecided, and three items depend on it.** The app ships as a `swiftc`-compiled bare binary with no bundle, no signature, no notarization. That choice is what blocks a URL scheme (R2), a Homebrew cask, and a Sparkle-style updater; it's also why state lives in a hand-rolled JSON file rather than `UserDefaults`. Deciding it either way unblocks or permanently closes those. Treat as one architectural decision, not several features. | P2 | — |
| R4 | **No home for settings, which gates every new setting.** The app is menu-only by design, and the Keep Awake submenu already carries 13 rows plus a live countdown. Any proposal that adds more than one toggle needs a decision about *where settings live* first, or the menu becomes a preferences window by accretion. This is a prerequisite item, not a feature. | P2 | — |
| R5 | **Battery threshold is hardwired at 20%** (`Tuning.batteryLowThreshold`), with no CLI, env, or menu surface. Distinct from R1 and not a substitute for it: a configurable threshold *relocates* the cliff, an override *removes* it. **Implementation catch:** the constant does double duty — the sleep policy *and* the battery load-source trace's red band (`loadHistoryView.lowThreshold`). Exposing it as-is would drag the sparkline's coloring along with the sleep policy, so split the constant before adding any surface. | P3 | R4 |
| R6 | **Fixed duration presets.** Keep Awake windows come from `Tuning.keepAwakeDurations` plus an hr/min `Custom…` prompt; seconds are reachable only from the CLI (`--keep-awake 90s`). No add/remove or set-default. | P4 | R4 |
| R7 | **No activate/deactivate notifications.** Keep Awake engaging, disengaging on a condition, or a window expiring are all silent unless the menu is open (the track line is the only ambient signal). | P3 | — |
| R8 | **English only** — zero `NSLocalizedString`; every menu title, alert, and readout is a literal. | P4 | — |
| R9 | **Preset art is repo-only.** Presets come from `gifs/presets.json` next to the source; there's no user-supplied-GIF directory (a custom GIF works, but only per-launch via the positional arg or `MENUBAR_LOAD_RUNNER_PATH`). No menu-bar highlight toggle either. | P4 | — |
| R10 | **GPU power / ANE / package power readers.** The one load-source tier that would require a private, unheadered API, which every current reader deliberately avoids. Also the first reader that would need a long-lived subscription rather than a point read, so it needs its own design pass — not an add-a-reader task. | P4 | — |
| R11 | **Die-temperature sensors.** Unimplemented but *not* API-blocked: the same unprivileged SMC path the fan reader already uses covers temperature keys. Straightforward; nobody's needed it. | P4 | — |

## Candidate — design open, do not implement as specified

| ID | Item | Pri | What must be settled first |
|---|---|---|---|
| R12 | **Arm Keep Awake automatically when an external display is connected.** Cheap on wiring: `screenObserver` already watches `didChangeScreenParametersNotification` and would read `NSScreen.screens.count` in the same callback, fanning into `conditionsDidChange()`. | P3 | A semantic asymmetry, not the wiring. Every condition in `shouldDisengageSleepPrevention` only ever turns Keep Awake **off**; nothing in this app has ever turned it **on** by itself. An auto-engage inverts that and needs a matching auto-disengage on unplug, or the lock outlives its reason. Decide that before writing code. |

## Declined

Reasons are one line by design. Re-propose only with a concrete report of the behavior being missed.

| Item | Why not |
|---|---|
| An idle-only sleep assertion (let the display sleep, keep the system awake) | Would reintroduce a fixed bug. `caffeinate -di` is deliberate: an idle-only assertion is unreliable on modern macOS — once the display sleeps the system tends to follow it down, so the Mac slept with Keep Awake on. Cheap to build, and quietly may not hold. If ever revisited it must state the risk in the UI, not read as a neutral preference. |
| Quit the app when a Keep Awake window expires | Would quit a load visualizer because a side feature timed out. |
| Release Keep Awake when another user logs in (fast user switching) | Contradicts a chosen default: the timed window is a *time* promise, not a *task* promise — an unattended job in a background session is still running, and dropping the lock defeats the feature. Genuinely ambiguous, so it stays as-is rather than becoming a setting (see R4). |
| Low Power Mode as a Keep Awake release trigger | LPM is a performance policy, not a sleep policy; the battery-low guard already covers drain. (LPM *is* observed, to cap the app's own animation speed.) |
| `--replace` / auto-kill a running instance on relaunch | Silently killing a running instance is a surprising default. |
| Tag-pinning, `--ref`, or a `VERSION` file in the installer | Reviewed and cut as non-MVP; the installer tracks the default branch and power users check out a tag themselves. |
| **Restart Now** button on the update prompt | Needs install-type detection, which has no clean signal (a detached ad-hoc run also reparents to pid 1). |
| Persisted 24h update-check throttle, in-app recompile+relaunch, persisted auto-check toggle, About-dialog version line | Cut for v1; the menu item is the real surface. |

## Known limits — not gaps, not fixable here

| Limit | Why it can't be closed |
|---|---|
| Keep Awake's *effect* is machine-wide, not per-user | `caffeinate` holds the whole Mac awake. Sleep is a machine-level property, so two users' windows don't compose — the Mac stays awake while *either* holds one. Per-user *state* is already correct (`~/Library/Application Support`, per-account). |
| A Keep Awake window held by a background login session is invisible from the foreground one | Consequence of the above. Nothing to store or sync differently. |
| Clamshell (lid-close) sleep can't be prevented | `caffeinate` cannot inhibit it at all. |
| Below the 5% Keep Awake floor, the Mac will sleep | Deliberate (added with R1's override): an explicit "keep it awake anyway" is honored from 20% down to 5%, but not into a hard power-off. |
| The interpreted-`swift` fallback isn't singleton-guarded | Deliberate: it runs only when `swiftc` fails, and the guard matches the compiled binary's path. |

## Done

| ID | Item | Landed |
|---|---|---|
| R1 | Keep Awake was a silent no-op below the battery threshold. An explicit menu arm now overrides the battery pause down to a 5% floor, and every paused state names its reason on the parent row and in the submenu. Two adjacent bugs fell out of it: a launch-time window armed before battery monitoring started (so it ignored the charge entirely), and the countdown row was invisible to VoiceOver. New `MENUBAR_LOAD_RUNNER_FORCE_BATTERY` hook + `tests/qa.sh` §3a made the whole matrix testable without a real battery. | unreleased |

## Verification debt

| Claim | State |
|---|---|
| The single-instance guard is per-user (v1.13.0+, `pgrep -U "$(id -u)"`) | `pgrep -U` scoping proven in isolation; same-user rejection tested live. **The cross-user case is unverified** — needs a second account plus fast user switching. See `RUNBOOK-qa-release.md` §6. |
| Keep Awake radio-mark glyphs | Unverifiable by script: marks are drawn with a custom `onStateImage`, so `AXMenuItemMarkChar` reads empty and `System Events` menus aren't rendered for screenshot. The parent title and status row are covered — both are read by index in the scripted checks, since the ticking parent title makes a title-based reference go stale. |
| Thermal pause rendering (`paused — Mac is too warm`) | Unverified: there is no way to force a thermal state. The battery reasons share the same code path and are covered by §3a; only the thermal *trigger* is untested. |

## Release hygiene

- `[Unreleased]` in `CHANGELOG.md` holds the per-user singleton fix **and** R1 — neither shipped in a version yet. R1 adds observable behavior and a new env hook, so this wants a **1.14.0** minor, not the 1.13.1 a lone singleton fix would have taken. A version bump moves four things together: `Tuning.version` in `MenuBarLoadRunner.swift`, the `CHANGELOG.md` heading, the `docs/cover.html` badge, and the git tag the in-app update check reads.
