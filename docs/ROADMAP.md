# ROADMAP

Standing tracker for open work, declined proposals, and known limits. Created 2026-07-26; current as
of v1.19.0.

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
| R5 | **Configurable Keep Awake battery threshold** (was hardwired at 20%). A configurable threshold *relocates* the cliff — not a substitute for the arm-anyway override, which shipped. **Code complete, all 6 steps:** the constant that also drove the battery trace's red band is split (`batteryChartLowThreshold` is chart-only and fixed), the sleep path reads a live `keepAwakeBatteryThreshold` (`0`/`Never` = never release on charge; the clamp's min sits above the 5% floor, which stays hardwired), `--battery-threshold <pct\|off>` / `MENUBAR_LOAD_RUNNER_BATTERY_THRESHOLD` set it at launch (qa.sh §3a: 18 cases), it persists in the `settings` block under that flag's precedence (qa.sh §3b: 18 cases), and `Settings ▸ Battery Threshold` sets it at runtime via `setBatteryThreshold` (persists, clears the override, applies to a live window at once). Its TODO file closed with v1.15.0. **Verified 2026-07-28:** §3a/§3b green; the readout + restore-with-no-flags half of RUNBOOK §3.2 confirmed mechanically (`menu-dump` read `Battery Threshold: 15%` off a no-flag instance against `batteryThreshold: 0.15` in the state file); Catch 6's wiring confirmed statically (`batteryChartLowThreshold` is chart-only, its sole reader `loadHistoryView.lowThreshold`). **Close after** the click-only residue: apply-immediately, override-retirement, the red band's *rendering*, the mark's position (AX can't read a custom `onStateImage`), and the threshold submenu's own row list (`menu-dump` descends one level; that submenu is two deep). | P3 | — |
| R6 | **Fixed duration presets** (`Tuning.keepAwakeDurations` + a `Custom…` prompt). No add/remove or set-default; seconds only via CLI. The list can move to `PersistedState.Settings` with rows generated from it; an in-app add/remove/reorder editor wants a Preferences window, which was deferred, and set-default is a separate feature. → `TODO-20260726-2333-r6-duration-presets-configurable.md` | P4 | — |
| R7 | **A paused Keep Awake looked identical to an off one** — a suspend kills the child, so the track line went dark, and `labelMode` defaults to `.off`, making that 2pt line a default user's only ambient indicator. **Rescoped 2026-07-30** to one persistent paused tone; the transient HUD is declined below, and system notifications stay impossible (they need a bundle). **Code complete 2026-07-30:** a third, fainter tone, so the bar now means *brightness tracks the strength of the hold*; qa.sh §3e asserts the rendered tone via `LOG_AWAKE`'s `tint=`. Design record: `DESIGN-system.md` §22.5. **Open, and it is now two things, not one.** (1) **Perceptibility** — until someone confirms the dim reads against both neighbours in a light *and* dark menu bar, this may be a no-op that tests green; RUNBOOK §3.1 carries the check. (2) **The automated case has never actually fired**: a foreign display hold correctly outranks our pause, so §3e's `tint=paused` NOTEs out on any machine holding the display, which is this one — see § Verification debt. Only the precedence half is confirmed. Both want the same quiet machine; **shipped in v1.19.2 with neither settled**. → `TODO-20260730-2129-r7-paused-keep-awake-tint.md` | P3 | A quiet machine — no display-sleep holder. |
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
| A transient HUD panel announcing Keep Awake events | **Declined 2026-07-30**, having been R7's settled plan since 2026-07-26. It is gone by the time it is needed: the pause worth reporting fires overnight, on battery, during an unattended job, and a panel that fades after ~2s has been gone for hours when the user returns — its own write-up conceded "a HUD missed is gone". The other three events it signalled don't need one (engage and resume are user-initiated or good news; expiry is a duration the user chose, with a live countdown already in the menu). R7 now ships a **persistent** paused tone instead. Note this declines the *panel*, not the goal — and system notifications stay independently impossible (they need a bundle). |
| Idle-only sleep assertion (let the display sleep) | Would reintroduce a fixed bug: `-di` is deliberate because an idle-only assertion is unreliable on modern macOS — the system follows the display down, so the Mac slept with Keep Awake on. |
| Quit the app when a Keep Awake window expires | Would quit a load visualizer because a side feature timed out. |
| Release Keep Awake on fast user switching | Contradicts a chosen default: the window is a *time* promise, not a *task* promise — an unattended job in a background session is still running. |
| Low Power Mode as a release trigger | LPM is a performance policy, not a sleep policy; battery-low already guards drain. (LPM *is* observed, to cap animation speed.) |
| `--replace` / auto-kill a running instance | Silently killing a running instance is a surprising default. |
| Installer tag-pinning, `--ref`, `VERSION` | Cut as non-MVP; it tracks the default branch and power users check out a tag. |
| An `.app` bundle · notarization · Homebrew cask · Sparkle · a URL scheme / automation interface | **Decided 2026-07-26: stays a source-built, bundle-less binary.** Notarization is $99/yr forever for a free OSS utility, and Homebrew disables unsigned casks on 2026-09-01 — ad-hoc signing can't substitute, since identity churns on every recompile and this app recompiles on every update. Bundling would also retire the git-checkout self-update for Sparkle and break the CLI-first interface, which a `.app` can't take argv for. |
| Persisted update-check throttle · persisted auto-check toggle · About version line | Cut for v1; the menu item is the real surface. (Relaunch-after-update **shipped** in v1.15.2 — as a `Restart` button that re-invokes the launcher, which is what recompiles; the app never compiles in-process.) |
| A doc-drift checker beyond version strings (grep prose for symbol names) | Version strings are the only mechanically checkable claim; semantic drift (wrong reader count, max-vs-average, mA-vs-amps) is invisible to a grep, and a symbol-name checker false-positives on every intentional rewording, which is how checks get disabled. Version consistency **is** enforced — `tests/qa.sh` §2. |

## Known limits — not gaps

| Limit | Why |
|---|---|
| Keep Awake's *effect* is machine-wide | `caffeinate` holds the whole Mac awake; sleep is machine-level, so two users' windows don't compose. Per-user *state* is already correct (per-account Application Support). |
| A window held by a background login session is invisible from the foreground one | Consequence of the above. Nothing to store differently. |
| Clamshell sleep can't be prevented | `caffeinate` cannot inhibit it. |
| Below 5% on battery the Mac sleeps regardless | Deliberate floor under the arm-anyway override: an explicit "anyway" is honored from 20% to 5%, not into a hard power-off. |
| The interpreted-`swift` fallback isn't singleton-guarded | Runs only when `swiftc` fails; the guard matches the compiled binary's path. |
| The menu-bar label may not sit adjacent to the icon on a **full** bar | macOS owns status-item placement and offers no reorder API. Verified 2026-07-29: on a notched built-in display, 6/6 runs scattered the three items (`icon=908 right=955 left=1117`, foreign icons between) while the external bar placed the same build correctly 100% of the time. Creation order still decides *intent*; the bar decides the outcome. The v1.16.0 no-jitter guarantee is unaffected (fixed width + no icon movement held throughout). `tests/qa.sh` §3c reports NOTE instead of FAIL when it detects this, so adjacency goes **unverified** on such a machine — re-run on a roomy bar. |

## Verification debt

| Claim | State |
|---|---|
| Keep Awake resume after a condition-suspend | **No check, and no longer named in the RUNBOOK** (it was a "hard to force by hand — trust the code path" bullet until the 2026-07-31 trim). When a battery/thermal suspend lifts, the respawn must pass the **remaining** window (`keepAwakeRemainingSeconds`), not the original length, and the tint mark must not move. Unreachable from `qa.sh`: `FORCE_BATTERY` pins one static value per process, so no run can cross the threshold mid-flight — forcing it needs a real draining battery or a hook that changes a decision, which is barred. |
| Per-user single-instance guard (`pgrep -U`) | Flag semantics proven in isolation; same-user rejection tested live. **Cross-user unverified** — needs a second account + fast user switching. `RUNBOOK-qa-release.md` §1. |
| Keep Awake radio-mark glyphs | Eyes-only. `AXMenuItemMarkChar` is empty (custom `onStateImage`), so AX can't read the mark; a synthesized `CGEvent` click *does* render the menu for a screenshot, but it needs the item's screen coordinates and AX reports those unreliably across displays — deliberately a rebuild-ad-hoc recipe (RUNBOOK §3.2), not a script. Menu *structure* is mechanical (`tests/menu-dump.applescript`); parent title and status row are covered, read by index since the ticking title makes a title-based reference go stale. |
| R13 is category-first ("no other menu-bar util tells you") | Only **KeepingYouAwake 1.6.8** was inspected — it links no assertion-read API. **Amphetamine and the standalone assertion-viewer utilities are unchecked.** R13 **shipped in v1.17.0** without the claim, which is the point: settle it before the claim reaches `README.md` or `docs/cover.html`. `pmset -g assertions` is one command, so any user can check it, and a wrong category claim is worse than no claim. |
| `ThroughputScaler` hysteresis, `SemVer` / `highestTag` parsing, `Restarter`'s argv + mode mapping | **No check at all as of 2026-07-30.** The five `.swift` probes covering these were deleted for asserting against re-ported *copies* of the app's logic (each carried "keep in sync with the real type" — the copy passes while the app is broken). Reader value-sanity and label-width reservation were **replaced functionally**: `qa.sh` §5 now reads all seven readouts back off the live status item (shape, range, and that the reserved slot width doesn't move). The three above have no reachable functional path yet and are honestly uncovered, not covered-by-a-port: the scaler needs sustained synthetic net/disk load to move its ceiling; the tag parse needs a checkout whose `origin` has canned `v*` tags; `Restarter`'s launchd branch needs a real LaunchAgent job (already noted below as flag-semantics-only). Don't "restore coverage" by re-adding a port — see `AGENTS.md` § Testing rules. |
| The v1.19.1 two-section `Keep Awake ▸` order | **Verified 2026-07-31** by `tests/menu-dump.applescript` (which needed a fix to read an armed menu at all — a stored row specifier is re-resolved by title, and the parent title ticks). Three dumps — unarmed, armed, paused — confirm the order (machine row → `Other Assertions` + rows → separator → disabled `This App` → Off + 5 tints → separator → `Duration` + rows → separator → countdown/paused row **last**) and the trailing-separator fix: row 12.21/12.22 and the status row are present when armed and both absent when not. Still eyes-only: the disabled header's *styling*, and the radio-mark glyphs (see the row above). Not in `qa.sh` — the dump needs an Accessibility grant. |
| R7's own `tint=paused` reading | **Unobserved, and structurally so.** `qa.sh` §3e case 7 asserts it, but a foreign display hold **correctly outranks** our pause, so the case NOTEs out on any machine where anything holds the display — a browser with a `Video Wake Lock` is enough, and that is the normal state of this one. Its precedence half (`paused=1 tint=foreign`) passes and is the reading actually confirmed here. So the tone R7 exists to add has been verified in neither of its two forms: not automatically (this row) and not by eye (R7's own row above). Both need a quiet machine; the eyes check needs one anyway. Same structural gate as the three readings below. |
| The machine sleep-hold row's `Nothing holding sleep` reading (R16) | **Unverified locally.** The other three readings are covered by `qa.sh` §3e and were dogfooded 2026-07-30 against a real idle-only renewal loop, a terminal `caffeinate -di -t 120`, and our own armed window. The unheld one needs a machine with **no sleep assertions at all**, which this one never was — §3e NOTEs it rather than faking a quiet system. Same structural gate hides two more cases there (attribution when another display holder sorts first; the idle-only reading when anything holds the display). |
| Thermal pause rendering | No way to force a thermal state. The battery reasons share the code path and are covered by `tests/qa.sh` §3a; only the thermal *trigger* is untested. |
| Label slot order is "creation order", assumed not guaranteed | The whole two-item side mechanism rests on oldest = rightmost. `tests/qa.sh` §3c asserts adjacency on both sides **only when the bar had room to answer** — as of v1.17.1 a scattered bar reports `NOTE`, not `PASS`, so on a machine that always scatters (the notched built-in display here) this claim goes unverified locally and wants a run on a roomy bar. A contiguous-but-wrong order still FAILs, so a real ordering regression can't hide behind the NOTE. During development the order was observed **inverted twice, consecutively** — `icon[x=950]` then `left[x=984]`, i.e. the "left" slot placed right of the animation — and never again in ~20 attempts since, including under heavy load, concurrent compiles, and a second instance. **2026-07-30 — the inversion tracks the DISPLAY, not the build, and is deterministic per display.** Measured
while the menu bar moved between screens mid-session: on the **external** display both the modified and the
unmodified binary placed correctly, 3/3 each (`icon=1851 left=1764`). On the **built-in notched** display
both produced the same inverted geometry, 3/3 each (`icon=936 left=983`) — contiguous, so the scatter
detector correctly does not fire and §3c **FAILs**. Identical output from an unmodified binary rules out any
code change as the cause. This is a sharper lead than the earlier "observed twice, unexplained": it is
reproducible on demand by moving the bar to the notched display, which is where `autosaveName` (below)
should be probed first. **Consequence for QA:** §3c goes red for an environmental reason on that display, so
read a §3c adjacency FAIL against which screen the bar was on before believing it. Deliberately NOT softened
into a NOTE — a contiguous-but-wrong order must keep failing, or a real ordering regression hides behind it.
Treat the ordering as *reliable but not contractual*. Two leads if it recurs: status items have been user-reorderable by ⌘-drag since Big Sur, and position persistence is keyed to `NSStatusItem.autosaveName`, which this app never sets — and a bundle-less binary has no defaults domain to persist one to (see `PersistedState`), so whatever ordering state the system keeps for these items has no stable identity to hang on. Worth probing `autosaveName` **before** blaming the creation-order assumption; if it works it is also a better answer to "which side" than two items (⌘-drag, no 16pt idle slot). |

## Release hygiene

A version bump moves five things together: `AppInfo.version` in `MenuBarLoadRunner.swift`, the
`CHANGELOG.md` heading, the `README.md` "Current version" line, the `docs/cover.html` badge, and the
git tag the in-app update check reads. A changed badge also means the cover wants a redeploy
(`publish-cover`) — **v1.19.0's is done**: verified live 2026-07-30 that `menubar-load-runner.pages.dev`
serves the v1.19.0 badge, the `Other Assertions` + machine-state prose (4 matches for `assertion`, up from
**zero**, which is what R15 was), and all five embedded GIFs at 200. That deploy is the one release step no
check can see, so verify it by fetching the live page — not by trusting the badge, which was already right
while the prose was missing.

The badge only proves the *version* matched at deploy time, never that the prose did — and the prose
has now drifted **twice in a row**. R14 was the first (the cover called `Battery Threshold` CLI-only
for two releases after the menu shipped; fixed and redeployed 2026-07-29). **R15 is the second, found
in the same sweep and still open**: the badge went to v1.17.1 while the cover said nothing at all about
`Other Assertions`, the feature that release was *about*. So treat it as a rule with a track record, not
a caution — a **new user-facing surface needs its cover paragraph in the same pass as its menu row**,
because no check will ever catch its absence, and the passing badge actively reads as "the cover is
current."

**A third drift, v1.19.2, and it was a new shape.** The cover's `#mark` prose didn't merely omit R7's
paused tone — it asserted the *opposite*, that on a suspend "the line and the label's color drop
together", which is the bug R7 removed, written up as intent. Worse, the Keep Awake **demo** reproduced
it: `awLine` toggled on `running` alone, so a suspended hold rendered at opacity 0, pixel-identical to
`Off`. Both were caught inside that release's own cut and fixed there. Take the lesson as separate from
prose drift: **the cover's demos are executable claims about behavior**, so a stale one doesn't read as
out-of-date, it reads as the specification. Neither is greppable. `RUNBOOK-qa-release.md` §4 step 2
carries both as a step.

**Four of the five are enforced** — `tests/qa.sh` §2 derives `VER` from `AppInfo.version` and asserts
it against `--help`, the CHANGELOG heading, the README line, and the cover badge. The **git tag is
deliberately not checked**: `qa.sh` runs *before* the tag exists. The check exists because the
unenforced surface is the one that rots — the README line was missing from this checklist and shipped
stale through v1.13.0 and v1.13.1, while the CHANGELOG, which §2 already covered, never drifted.

**Tagging is not the last manual step — pushing is, and the two fail differently.** A botched tag is
visible locally; an unpushed one is invisible everywhere except the remote, and the local repo reads as
fully released. It is not hypothetical: **v1.19.1 was cut correctly and never pushed**, so the remote's
newest tag stayed v1.19.0 while two releases came and went. That is worse here than in most repos —
`UpdateChecker` polls `git ls-remote --tags origin 'v*'`, so an unpushed tag silently tells every
installed copy the old version is current. Confirm with that same command (`sort -uV`, never a plain
`sort`: `v1.9.1` beats `v1.19.2` lexically). `RUNBOOK-qa-release.md` §4 steps 5–6.

**Currently unshipped: v1.19.1 and v1.19.2.** Both are committed and tagged locally only. v1.19.2 also
has its cover changes unpublished (prose + demo, above) and two open verification items — R7's
perceptibility, and the `tint=paused` row under § Verification debt. Push both tags together.
