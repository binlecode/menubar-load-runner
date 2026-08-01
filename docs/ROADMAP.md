# ROADMAP

Standing tracker for open work, declined proposals, and known limits. Created 2026-07-26; current as
of v1.19.3.

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
| R8 | **English only** — zero `NSLocalizedString`. | P4 | — |
| R9 | **Preset art is repo-only** (`gifs/presets.json`); no user art directory, no menu-bar highlight toggle. A custom GIF works per-launch only. | P4 | — |
| R10 | **GPU power / ANE / package power readers.** The one tier needing a private, unheadered API, which every current reader avoids. Also the first needing a long-lived subscription rather than a point read — its own design pass, not an add-a-reader task. | P4 | — |
| R11 | **Die-temperature sensors.** Not API-blocked: the unprivileged SMC path the fan reader already uses covers temperature keys. **Catch:** that plumbing is private to `FanLoadMonitor` and must be extracted to a shared client (one `io_connect_t`, not two); key discovery is probe-a-candidate-list, since there is no `FNum`-equivalent for temperature. → `TODO-20260726-2059-r11-die-temperature-source.md` | P4 | — |

## Candidate — design open, do not implement as specified

| ID | Item | Pri | Settle first |
|---|---|---|---|
| R12 | **Arm Keep Awake when an external display connects.** Wiring is nearly free: `screenObserver` already watches `didChangeScreenParametersNotification` and would call `conditionsDidChange()`. Must be opt-in; `Settings ▸` is the home for that toggle. → `TODO-20260726-2100-r12-external-display-auto-arm.md` | P3 | Three things. (1) The asymmetry, not the wiring: every condition in `keepAwakeSuspension` only turns keep-awake **off**; auto-engage inverts that and needs a matching auto-disengage on unplug. (2) That notification also fires on display sleep/wake and resolution changes, and `NSScreen.screens.count > 1` is false in clamshell — the common case. (3) Whether the docked-clamshell scenario people mean is one `caffeinate` even affects; if not, decline. Probe committed (`tests/clamshell-sleep-check.sh`) and **unrun** — the remaining blocker is physical (lid open/close, idle time, no sleep-assertion holders), not code. |

## Declined

Re-propose only with a concrete report of the behavior being missed.

| Item | Why not |
|---|---|
| A transient HUD panel announcing Keep Awake events | **Declined 2026-07-30.** A ~2s panel is gone by the time it matters — the pause worth reporting fires overnight, on battery, unattended. R7 ships a persistent paused tone instead. This declines the *panel*, not the goal; system notifications stay independently impossible (they need a bundle). |
| Idle-only sleep assertion (let the display sleep) | Would reintroduce a fixed bug: `-di` is deliberate because an idle-only assertion is unreliable on modern macOS — the system follows the display down, so the Mac slept with Keep Awake on. |
| Quit the app when a Keep Awake window expires | Would quit a load visualizer because a side feature timed out. |
| Release Keep Awake on fast user switching | Contradicts a chosen default: the window is a *time* promise, not a *task* promise — an unattended job in a background session is still running. |
| Low Power Mode as a release trigger | LPM is a performance policy, not a sleep policy; battery-low already guards drain. (LPM *is* observed, to cap animation speed.) |
| `--replace` / auto-kill a running instance | Silently killing a running instance is a surprising default. |
| Installer tag-pinning, `--ref`, `VERSION` | Cut as non-MVP; it tracks the default branch and power users check out a tag. |
| An `.app` bundle · notarization · Homebrew cask · Sparkle · a URL scheme / automation interface | **Decided 2026-07-26: stays a source-built, bundle-less binary.** Notarization is $99/yr forever for a free OSS utility, and Homebrew disables unsigned casks on 2026-09-01 — ad-hoc signing can't substitute, since identity churns on every recompile. Bundling would also retire the git-checkout self-update and break the CLI-first interface, which a `.app` can't take argv for. |
| Persisted update-check throttle · persisted auto-check toggle · About version line | Cut for v1; the menu item is the real surface. |
| A doc-drift checker beyond version strings (grep prose for symbol names) | Version strings are the only mechanically checkable claim, and `qa.sh` §2 already enforces them; a symbol-name grep false-positives on every intentional rewording, which is how checks get disabled. |

## Known limits — not gaps

| Limit | Why |
|---|---|
| Keep Awake's *effect* is machine-wide | `caffeinate` holds the whole Mac awake; sleep is machine-level, so two users' windows don't compose. Per-user *state* is already correct (per-account Application Support). |
| A window held by a background login session is invisible from the foreground one | Consequence of the above. Nothing to store differently. |
| Clamshell sleep can't be prevented | `caffeinate` cannot inhibit it. |
| Below 5% on battery the Mac sleeps regardless | Deliberate floor under the arm-anyway override: an explicit "anyway" is honored from 20% to 5%, not into a hard power-off. |
| The interpreted-`swift` fallback isn't singleton-guarded | Runs only when `swiftc` fails; the guard matches the compiled binary's path. |
| The menu-bar label may not sit adjacent to the icon on a **full** bar | macOS owns status-item placement and offers no reorder API. Verified 2026-07-29: on a notched built-in display, 6/6 runs scattered the three items with foreign icons between, while a roomy external bar placed the same build correctly 100% of the time. Creation order decides *intent*; the bar decides the outcome. The v1.16.0 no-jitter guarantee is unaffected. `tests/qa.sh` §3c reports NOTE instead of FAIL when it detects scatter, so adjacency goes **unverified** on such a machine. |

## Verification debt

| Claim | State |
|---|---|
| Keep Awake resume after a condition-suspend | **No check.** When a battery/thermal suspend lifts, the respawn must pass the **remaining** window (`keepAwakeRemainingSeconds`), not the original length, and the tint mark must not move. Unreachable from `qa.sh`: `FORCE_BATTERY` pins one static value per process, so no run can cross the threshold mid-flight — forcing it needs a real draining battery or a hook that changes a decision, which is barred. |
| Battery Threshold (R5) click-path residue | Code complete and mechanically verified for the flag/env/persistence halves (`qa.sh` §3a/§3b, 18 cases each). **Click-only and unverified:** apply-immediately, override-retirement, the red band's *rendering*, the mark's position (AX can't read a custom `onStateImage`), and the threshold submenu's own row list (`menu-dump` descends one level; that submenu is two deep). |
| Per-user single-instance guard (`pgrep -U`) | Flag semantics proven in isolation; same-user rejection tested live. **Cross-user unverified** — needs a second account + fast user switching. `RUNBOOK-qa-release.md` §1. |
| Keep Awake radio-mark glyphs, and the `This App` header's styling | Eyes-only. `AXMenuItemMarkChar` is empty (custom `onStateImage`), so AX can't read the mark; a synthesized `CGEvent` click renders the menu for a screenshot but needs screen coordinates AX reports unreliably across displays — deliberately a rebuild-ad-hoc recipe (RUNBOOK §3.2), not a script. Menu *structure* is mechanical (`tests/menu-dump.applescript`) and the v1.19.1 two-section order verified 2026-07-31. |
| R13 is category-first ("no other menu-bar util tells you") | Only **KeepingYouAwake 1.6.8** was inspected. **Amphetamine and the standalone assertion-viewer utilities are unchecked.** R13 shipped in v1.17.0 without the claim, which is the point: settle it before the claim reaches `README.md` or `docs/cover.html`. `pmset -g assertions` is one command, so any user can check it, and a wrong category claim is worse than no claim. |
| `ThroughputScaler` hysteresis, `SemVer` / `highestTag` parsing, `Restarter`'s argv + mode mapping | **No check at all.** These have no reachable functional path yet: the scaler needs sustained synthetic net/disk load to move its ceiling; the tag parse needs a checkout whose `origin` has canned `v*` tags; `Restarter`'s launchd branch needs a real LaunchAgent job. Don't "restore coverage" by re-adding a re-ported copy of the logic — see `AGENTS.md` § Testing rules. |
| R7's `tint=paused`, **caught by the harness** | The reading itself is confirmed by hand (2026-08-01: `hold=partial own=0 display=0 idle=1 paused=1 tint=paused`, three consecutive ticks with no `-w` child). **§3e has never fired the case in a full run** — it needs a machine with no display holder and NOTEs otherwise. Don't read that NOTE as the tone being unverified, and don't soften the case to make it pass. |
| The machine sleep-hold row's `Nothing holding sleep` reading (R16) | **Unverified locally.** The other three readings are covered by `qa.sh` §3e. The unheld one needs a machine with **no sleep assertions at all** — §3e NOTEs it rather than faking a quiet system. The same gate hides two more cases (attribution when another display holder sorts first; the idle-only reading when anything holds the display). |
| Thermal pause rendering | No way to force a thermal state. The battery reasons share the code path and are covered by `tests/qa.sh` §3a; only the thermal *trigger* is untested. |
| Label slot order is "creation order", assumed not guaranteed | Confirmed on a roomy bar 2026-08-01 — §3c passed all six cases (adjacency both sides, 87pt slot, constant width, icon stationary). Unexplained: the notched built-in display inverts the order **deterministically**, 3/3 for both a modified and an unmodified binary, so it is environmental, not a code change. Contiguous-but-wrong, so the scatter detector doesn't fire and §3c **FAILs** — read a §3c adjacency FAIL against which screen the bar was on before believing it. Deliberately not softened into a NOTE, or a real ordering regression hides behind it. Lead if it recurs: status items are ⌘-draggable and their position persists against `NSStatusItem.autosaveName`, which this app never sets — probe that before blaming the creation-order assumption. |

## Release hygiene

A version bump moves five things together: `AppInfo.version` in `MenuBarLoadRunner.swift`, the
`CHANGELOG.md` heading, the `README.md` "Current version" line, the `docs/cover.html` badge, and the
git tag the in-app update check reads. **Four of the five are enforced** — `tests/qa.sh` §2 derives
`VER` from `AppInfo.version` and asserts the other four. The git tag is deliberately not checked:
`qa.sh` runs *before* the tag exists.

Three rules with a track record, each learned from a shipped miss:

- **A new user-facing surface needs its cover paragraph in the same pass as its menu row.** Prose drift
  is not greppable and the passing badge actively reads as "the cover is current". The cover's **demos
  are executable claims** too — a stale one doesn't read as out of date, it reads as the specification.
  `RUNBOOK-qa-release.md` §4 step 2.
- **Pushing is the last manual step, not tagging, and the two fail differently.** An unpushed tag is
  invisible locally and tells every installed copy the old version is current (`UpdateChecker` polls
  `git ls-remote --tags origin 'v*'`). Confirm with that same command and `sort -uV`, never a plain
  `sort` — `v1.9.1` beats `v1.19.2` lexically. `RUNBOOK-qa-release.md` §4 steps 5–6.
- **The tag gates the prompt; the branch carries the code.** A behavioral change committed *after* its
  release tag is an undeliverable fix, not a stale tag: `UpdateChecker` finds the versions equal and
  offers no update, while `git pull --ff-only` would have delivered it. The only resolution is a
  version bump across the five surfaces. Never re-cut a published tag in place.

**Outstanding:** the cover is unpublished two releases running — v1.19.2's prose + demo changes, and now
v1.19.3's badge. Needs a `publish-cover` redeploy. (The stranded paused-alpha `0.22` fix shipped in
v1.19.3, which is what that release was for.)
