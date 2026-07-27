# ROADMAP

Standing tracker for open work, declined proposals, and known limits. Created 2026-07-26; current as
of v1.13.1.

Items are `R<n>`, assigned once, never reused. **P1** user-visible defect or silent failure · **P2**
real capability gap · **P3** nice to have · **P4** parity for its own sake. Nothing here is a
commitment or a date.

Keep this at tracking altitude — item, priority, blocker, and any catch an implementer would trip
over. Rationale belongs in the design record, not here; declined items keep a one-line reason so
nobody re-proposes them, not the full argument. Shipped items leave for the CHANGELOG.

---

## Open

| ID | Item | Pri | Blocked by |
|---|---|---|---|
| R2 | **No automation interface of its own.** Every flag is launch-time only and the per-user singleton refuses a second invocation, so a *running* instance can't be driven by anything this app declares. (Accessibility scripting can puppet any app's menus, but that's an OS affordance and it depends on menu wording that changes.) A URL scheme wants a bundle. | P2 | R3 |
| R3 | **Bundle-or-not is undecided, and it gates three things.** No bundle, signature, or notarization today. That single choice blocks a URL scheme (R2), a Homebrew cask, and a Sparkle-style updater, and is why state is a hand-rolled JSON file rather than `UserDefaults`. One architectural decision, not several features. | P2 | — |
| R4 | **No home for settings, which gates every new setting.** Menu-only by design, and the Keep Awake submenu already carries 13 rows plus a live status line. Anything adding more than one toggle needs "where do settings live" answered first. A prerequisite, not a feature. | P2 | — |
| R5 | **Battery threshold hardwired** at 20% (`Tuning.batteryLowThreshold`), no CLI/env/menu surface. Not a substitute for R1's override, which shipped: a configurable threshold *relocates* the cliff. **Catch:** that constant also sets the battery trace's red band (`loadHistoryView.lowThreshold`) — split it before adding any surface, or the sparkline recolors with the sleep policy. | P3 | R4 |
| R6 | **Fixed duration presets** (`Tuning.keepAwakeDurations` + a `Custom…` prompt). No add/remove or set-default; seconds only via CLI. | P4 | R4 |
| R7 | **No activate/deactivate notifications.** Engaging, pausing, and expiry are silent unless the menu is open — the track line is the only ambient signal. | P3 | — |
| R8 | **English only** — zero `NSLocalizedString`. | P4 | — |
| R9 | **Preset art is repo-only** (`gifs/presets.json`); no user art directory, no menu-bar highlight toggle. A custom GIF works per-launch only. | P4 | — |
| R10 | **GPU power / ANE / package power readers.** The one tier needing a private, unheadered API, which every current reader avoids. Also the first needing a long-lived subscription rather than a point read — its own design pass, not an add-a-reader task. | P4 | — |
| R11 | **Die-temperature sensors.** Not API-blocked: the unprivileged SMC path the fan reader already uses covers temperature keys. Nobody's needed it. | P4 | — |

## Candidate — design open, do not implement as specified

| ID | Item | Pri | Settle first |
|---|---|---|---|
| R12 | **Arm Keep Awake when an external display connects.** Wiring is nearly free: `screenObserver` already watches `didChangeScreenParametersNotification` and would read `NSScreen.screens.count` into `conditionsDidChange()`. | P3 | The asymmetry, not the wiring. Every condition in `keepAwakeSuspension` only turns keep-awake **off**; nothing turns it **on** by itself. Auto-engage inverts that and needs a matching auto-disengage on unplug, or the lock outlives its reason. |

## Declined

Re-propose only with a concrete report of the behavior being missed.

| Item | Why not |
|---|---|
| Idle-only sleep assertion (let the display sleep) | Would reintroduce a fixed bug: `-di` is deliberate because an idle-only assertion is unreliable on modern macOS — the system follows the display down, so the Mac slept with Keep Awake on. |
| Quit the app when a Keep Awake window expires | Would quit a load visualizer because a side feature timed out. |
| Release Keep Awake on fast user switching | Contradicts a chosen default: the window is a *time* promise, not a *task* promise — an unattended job in a background session is still running. |
| Low Power Mode as a release trigger | LPM is a performance policy, not a sleep policy; battery-low already guards drain. (LPM *is* observed, to cap animation speed.) |
| `--replace` / auto-kill a running instance | Silently killing a running instance is a surprising default. |
| Installer tag-pinning, `--ref`, `VERSION` | Cut as non-MVP; it tracks the default branch and power users check out a tag. |
| **Restart Now** on the update prompt | Needs install-type detection, which has no clean signal (a detached run also reparents to pid 1). |
| Persisted update-check throttle · in-app recompile+relaunch · persisted auto-check toggle · About version line | Cut for v1; the menu item is the real surface. |
| A doc-drift checker beyond version strings (grep prose for symbol names) | Version strings are the only mechanically checkable claim; the *semantic* drift found on 2026-07-26 (wrong reader count, max-vs-average, mA-vs-amps) is invisible to a grep. A symbol-name checker false-positives on every intentional rewording, which is how checks get disabled. Known cost is one nine-release miss on one comment. Version consistency **is** enforced — `tests/qa.sh` §2. |

## Known limits — not gaps

| Limit | Why |
|---|---|
| Keep Awake's *effect* is machine-wide | `caffeinate` holds the whole Mac awake; sleep is machine-level, so two users' windows don't compose. Per-user *state* is already correct (per-account Application Support). |
| A window held by a background login session is invisible from the foreground one | Consequence of the above. Nothing to store differently. |
| Clamshell sleep can't be prevented | `caffeinate` cannot inhibit it. |
| Below 5% on battery the Mac sleeps regardless | Deliberate floor under R1's override: an explicit "anyway" is honored from 20% to 5%, not into a hard power-off. |
| The interpreted-`swift` fallback isn't singleton-guarded | Runs only when `swiftc` fails; the guard matches the compiled binary's path. |

## Verification debt

| Claim | State |
|---|---|
| Per-user single-instance guard (`pgrep -U`) | Flag semantics proven in isolation; same-user rejection tested live. **Cross-user unverified** — needs a second account + fast user switching. `RUNBOOK-qa-release.md` §6. |
| Keep Awake radio-mark glyphs | Not scriptable: custom `onStateImage` leaves `AXMenuItemMarkChar` empty and `System Events` menus aren't rendered for screenshot. Parent title and status row *are* covered — read by index, since the ticking title makes a title-based reference go stale. |
| Thermal pause rendering | No way to force a thermal state. The battery reasons share the code path and are covered by `tests/qa.sh` §3a; only the thermal *trigger* is untested. |

## Release hygiene

A version bump moves five things together: `AppInfo.version` in `MenuBarLoadRunner.swift`, the
`CHANGELOG.md` heading, the `README.md` "Current version" line, the `docs/cover.html` badge, and the
git tag the in-app update check reads. A changed badge also means the cover wants a redeploy
(`publish-cover`).

**Four of the five are enforced** — `tests/qa.sh` §2 derives `VER` from `AppInfo.version` and asserts
it against `--help`, the CHANGELOG heading, the README line, and the cover badge, so a stale one fails
the core tier. The **git tag is deliberately not checked**: `qa.sh` runs *before* the tag exists, so
asserting it would fail every pre-release run. Tagging stays the one manual step to get right.

Why it's enforced at all: the README line was missing from this checklist until 2026-07-26 and fell two
releases behind (v1.13.0 and v1.13.1 both shipped it stale) while the CHANGELOG — the one surface §2
already checked — never drifted. The unenforced surface is the one that rots.
