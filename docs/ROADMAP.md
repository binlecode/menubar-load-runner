# ROADMAP

Standing tracker for open work, declined proposals, and known limits. Created 2026-07-26; current as
of v1.14.0.

Items are `R<n>`, assigned once, never reused. **P1** user-visible defect or silent failure · **P2**
real capability gap · **P3** nice to have · **P4** parity for its own sake. Nothing here is a
commitment or a date.

Keep this at tracking altitude — item, priority, blocker, and any catch an implementer would trip
over. Rationale belongs in the design record, not here; declined items keep a one-line reason so
nobody re-proposes them, not the full argument. Shipped items leave for the CHANGELOG. Refer to code
by **symbol, never by line number** — anchors rot every release, and a TODO file is where they belong.

---

## Open

| ID | Item | Pri | Blocked by |
|---|---|---|---|
| R5 | **Battery threshold hardwired** at 20% (`Tuning.batteryLowThresholdDefault`), no CLI/env/menu surface. A configurable threshold *relocates* the cliff — not a substitute for the arm-anyway override, which shipped. **In progress:** Steps 0–2 landed — the constant that also drove the battery trace's red band is split (`batteryChartLowThreshold` is chart-only and fixed), the sleep path reads a live `keepAwakeBatteryThreshold` (`0` = never release on charge; the clamp's min sits above the 5% floor, which stays hardwired), and `--battery-threshold <pct|off>` / `MENUBAR_LOAD_RUNNER_BATTERY_THRESHOLD` set it at launch (qa.sh §3a: 13 behavioral cases). Remaining: persistence, menu surface, apply-immediately. → `TODO-20260726-2332-r5-battery-threshold-surface.md` | P3 | — |
| R6 | **Fixed duration presets** (`Tuning.keepAwakeDurations` + a `Custom…` prompt). No add/remove or set-default; seconds only via CLI. The list can move to `PersistedState.Settings` with rows generated from it; an in-app add/remove/reorder editor wants a Preferences window, which was deferred, and set-default is a separate feature. → `TODO-20260726-2333-r6-duration-presets-configurable.md` | P4 | — |
| R7 | **No ambient signal for Keep Awake.** Engaging, pausing, and expiry are silent unless the menu is open — the track line is the only signal. Ships as an **in-app HUD panel**, not a system notification: `UNUserNotificationCenter.current()` *crashes* a bundle-less binary (`bundleProxyForCurrentProcess is nil`, verified 2026-07-26) and the app stays bundle-less by choice. → `TODO-20260726-2058-r7-keep-awake-notifications.md` | P3 | — |
| R8 | **English only** — zero `NSLocalizedString`. | P4 | — |
| R9 | **Preset art is repo-only** (`gifs/presets.json`); no user art directory, no menu-bar highlight toggle. A custom GIF works per-launch only. | P4 | — |
| R10 | **GPU power / ANE / package power readers.** The one tier needing a private, unheadered API, which every current reader avoids. Also the first needing a long-lived subscription rather than a point read — its own design pass, not an add-a-reader task. | P4 | — |
| R11 | **Die-temperature sensors.** Not API-blocked: the unprivileged SMC path the fan reader already uses covers temperature keys. **Catch:** that plumbing is private to `FanLoadMonitor` and must be extracted to a shared client (one `io_connect_t`, not two); key discovery is probe-a-candidate-list, since there is no `FNum`-equivalent for temperature. → `TODO-20260726-2059-r11-die-temperature-source.md` | P4 | — |

## Candidate — design open, do not implement as specified

| ID | Item | Pri | Settle first |
|---|---|---|---|
| R12 | **Arm Keep Awake when an external display connects.** Wiring is nearly free: `screenObserver` already watches `didChangeScreenParametersNotification` and would call `conditionsDidChange()`. Must be opt-in; `Settings ▸` is the home for that toggle. → `TODO-20260726-2100-r12-external-display-auto-arm.md` | P3 | Three things. (1) The asymmetry, not the wiring: every condition in `keepAwakeSuspension` only turns keep-awake **off**; auto-engage inverts that and needs a matching auto-disengage on unplug. (2) That notification also fires on display sleep/wake and resolution changes, and `NSScreen.screens.count > 1` is false in clamshell — the common case. (3) Whether the docked-clamshell scenario people mean is one `caffeinate` even affects; if not, decline. Probe committed (`tests/clamshell-sleep-check.sh`) and **unrun** — the remaining blocker is physical (lid open/close, idle time, no sleep-assertion holders), not code. Don't mistake `powerd`'s display-gated assertion for the answer; it is a hypothesis until trial 2 runs. |

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
| An `.app` bundle · notarization · Homebrew cask · Sparkle · a URL scheme / automation interface | **Decided 2026-07-26: stays a source-built, bundle-less binary.** Notarization is $99/yr forever for a free OSS utility, and Homebrew disables unsigned casks on 2026-09-01 — ad-hoc signing can't substitute, since identity churns on every recompile and this app recompiles on every update. Bundling would also retire the git-checkout self-update for Sparkle and break the CLI-first interface, which a `.app` can't take argv for. |
| **Restart Now** on the update prompt | Needs install-type detection, which has no clean signal (a detached run also reparents to pid 1). |
| Persisted update-check throttle · in-app recompile+relaunch · persisted auto-check toggle · About version line | Cut for v1; the menu item is the real surface. |
| A doc-drift checker beyond version strings (grep prose for symbol names) | Version strings are the only mechanically checkable claim; semantic drift (wrong reader count, max-vs-average, mA-vs-amps) is invisible to a grep, and a symbol-name checker false-positives on every intentional rewording, which is how checks get disabled. Version consistency **is** enforced — `tests/qa.sh` §2. |

## Known limits — not gaps

| Limit | Why |
|---|---|
| Keep Awake's *effect* is machine-wide | `caffeinate` holds the whole Mac awake; sleep is machine-level, so two users' windows don't compose. Per-user *state* is already correct (per-account Application Support). |
| A window held by a background login session is invisible from the foreground one | Consequence of the above. Nothing to store differently. |
| Clamshell sleep can't be prevented | `caffeinate` cannot inhibit it. |
| Below 5% on battery the Mac sleeps regardless | Deliberate floor under the arm-anyway override: an explicit "anyway" is honored from 20% to 5%, not into a hard power-off. |
| The interpreted-`swift` fallback isn't singleton-guarded | Runs only when `swiftc` fails; the guard matches the compiled binary's path. |

## Verification debt

| Claim | State |
|---|---|
| Per-user single-instance guard (`pgrep -U`) | Flag semantics proven in isolation; same-user rejection tested live. **Cross-user unverified** — needs a second account + fast user switching. `RUNBOOK-qa-release.md` §6. |
| Keep Awake radio-mark glyphs | Eyes-only. `AXMenuItemMarkChar` is empty (custom `onStateImage`), so AX can't read the mark; a synthesized `CGEvent` click *does* render the menu for a screenshot, but it needs the item's screen coordinates and AX reports those unreliably across displays — deliberately a rebuild-ad-hoc recipe (RUNBOOK §7), not a script. Menu *structure* is mechanical (`tests/menu-dump.applescript`); parent title and status row are covered, read by index since the ticking title makes a title-based reference go stale. |
| Thermal pause rendering | No way to force a thermal state. The battery reasons share the code path and are covered by `tests/qa.sh` §3a; only the thermal *trigger* is untested. |

## Release hygiene

A version bump moves five things together: `AppInfo.version` in `MenuBarLoadRunner.swift`, the
`CHANGELOG.md` heading, the `README.md` "Current version" line, the `docs/cover.html` badge, and the
git tag the in-app update check reads. A changed badge also means the cover wants a redeploy
(`publish-cover`).

**Four of the five are enforced** — `tests/qa.sh` §2 derives `VER` from `AppInfo.version` and asserts
it against `--help`, the CHANGELOG heading, the README line, and the cover badge. The **git tag is
deliberately not checked**: `qa.sh` runs *before* the tag exists. Tagging stays the one manual step to
get right. The check exists because the unenforced surface is the one that rots — the README line was
missing from this checklist and shipped stale through v1.13.0 and v1.13.1, while the CHANGELOG, which
§2 already covered, never drifted.
