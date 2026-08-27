# ROADMAP

The product tracker: what is open, what was declined, known limits, and verification debt. Shipped
work is not tracked here — it is described as-built in `docs/ARCHITECTURE.md`. Created 2026-07-26;
current as of v1.22.0.

Items are `R<n>`, assigned once, never reused. **P1** user-visible defect or silent failure · **P2**
real capability gap · **P3** nice to have · **P4** parity for its own sake. Nothing here is a
commitment or a date.

Keep this at tracking altitude — item, priority, blocker, and any catch an implementer would trip
over. Design and technical rationale live in `docs/ARCHITECTURE.md` and the `AGENTS.md` architecture
map; release history lives in `CHANGELOG.md` and git. Refer to code by **symbol, never by line number** —
anchors rot every release.

---

## Where this sits

One line: a load *visualizer* that earns each new capability through unprivileged reads and
self-restraint — it only ever reads the system, and the only thing it throttles is itself.

**Shipped capability is not tracked here.** How the app got from v1.0 to today — which stage
established which invariant — is as-built and lives in `docs/ARCHITECTURE.md` § 12; a completed item's
durable outcome moves there and its row leaves this file.

The Open items sit on the same arc: R18 closes the loop on v1.21's self-update investment;
R9 extends preset identity beyond the repo;
R10 is the next sensor tier and the first to need a private API — which is exactly why it waits;
R8 is parity only.

## Open

Ordered by ROI, highest first — value against cost, not just the priority band.

| ID | Item | Pri | Blocked by |
|---|---|---|---|
| R18 | **Update discovery is once-per-launch.** The passive probe fires only from `applicationDidFinishLaunching` (a deliberate MVP cut, per the comment at the call site), so a start-at-login instance running for weeks never learns a release exists — the population most likely to be stale is the one the probe never reaches. `startUpdateProbe(userInitiated: false)` is already fail-silent and re-entrancy-guarded (`updatePhase`), so a periodic re-fire reuses everything. | P3 | — |
| R9 | **Preset art is repo-only** (`gifs/presets.json`); no user art directory, no menu-bar highlight toggle. A custom GIF works per-launch only. | P4 | — |
| R10 | **GPU power / ANE / package power readers.** The one tier needing a private, unheadered API, which every current reader avoids. Also the first needing a long-lived subscription rather than a point read — its own design pass, not an add-a-reader task. Assessed 2026-08-02: low ROI — of the three readings only ANE is a genuinely new signal (GPU power tracks the utilization reader; package power correlates with CPU/temperature, and battery mA already shows whole-system draw), against a permanent private-API maintenance surface and per-chip verification debt. Waits for a concrete user report wanting ANE/power visibility. | P4 | — |
| R8 | **English only** — zero `NSLocalizedString`. | P4 | — |

## Declined

A row earns its place here only by guarding a boundary the **current** design rests on, and only if the
reason lives nowhere else — a decline whose argument is already in `AGENTS.md`, or that merely records
something once cut for scope, is history and belongs in git. Re-propose only with a concrete report of
the behavior being missed.

| Item | Why not |
|---|---|
| An `.app` bundle · notarization · Homebrew cask · Sparkle · a URL scheme / automation interface | **Decided 2026-07-26: stays a source-built, bundle-less binary.** Notarization is $99/yr forever for a free OSS utility, and Homebrew disables unsigned casks on 2026-09-01 — ad-hoc signing can't substitute, since identity churns on every recompile. Bundling would also retire the git-checkout self-update and break the CLI-first interface, which a `.app` can't take argv for. |
| Release Keep Awake on fast user switching | Contradicts a chosen default: the window is a *time* promise, not a *task* promise — an unattended job in a background session is still running. |
| Any transient announcement of a Keep Awake event (HUD panel, notification) | A ~2s panel is gone by the time it matters — the pause worth reporting fires overnight, on battery, unattended, which is why R7 ships a persistent paused tone instead. System notifications are independently impossible: they need a bundle, which the row above declines. |

## Known limits — not gaps

| Limit | Why |
|---|---|
| Keep Awake's *effect* is machine-wide | `caffeinate` holds the whole Mac awake; sleep is machine-level, so two users' windows don't compose. Per-user *state* is already correct (per-account Application Support). |
| A window held by a background login session is invisible from the foreground one | Consequence of the above. Nothing to store differently. |
| Clamshell sleep can't be prevented | `caffeinate` cannot inhibit it. |
| Below 5% on battery the Mac sleeps regardless | Deliberate floor under the arm-anyway override: an explicit "anyway" is honored from 20% to 5%, not into a hard power-off. |
| The interpreted-`swift` fallback isn't singleton-guarded | Runs only when `swiftc` fails; the guard matches the compiled binary's path. |
| The menu-bar label may not sit adjacent to the icon on a **full** bar | macOS owns status-item placement and offers no reorder API — verified 2026-07-29 (6/6 scattered on a notched built-in display, 100% correct on a roomy external). Creation order decides *intent*; the bar decides the outcome. The v1.16.0 no-jitter guarantee is unaffected; `tests/qa.sh` §3c reports NOTE on scatter, so adjacency goes **unverified** on such a machine. Full account: `AGENTS.md` § menu-bar label. |

## Verification debt

| Claim | State |
|---|---|
| Keep Awake resume after a condition-suspend | **No check.** When a battery/thermal suspend lifts, the respawn must pass the **remaining** window (`keepAwakeRemainingSeconds`), not the original length, and the tint mark must not move. Unreachable from `qa.sh`: `FORCE_BATTERY` pins one static value per process, so no run can cross the threshold mid-flight — forcing it needs a real draining battery or a hook that changes a decision, which is barred. |
| Battery Threshold (R5) click-path residue | Code complete and mechanically verified for the flag/env/persistence halves (`qa.sh` §3a/§3b, 18 cases each). **Click-only and unverified:** apply-immediately, override-retirement, the red band's *rendering*, the mark's position (AX can't read a custom `onStateImage`), and the threshold submenu's own row list (`menu-dump` descends one level; that submenu is two deep). |
| Per-user single-instance guard (`pgrep -U`) | Flag semantics proven in isolation; same-user rejection tested live. **Cross-user unverified** — needs a second account + fast user switching. |
| Keep Awake radio-mark glyphs, and the `This App` header's styling | Eyes-only. `AXMenuItemMarkChar` is empty (custom `onStateImage`), so AX can't read the mark; a synthesized `CGEvent` click renders the menu for a screenshot but needs screen coordinates AX reports unreliably across displays — deliberately checked ad hoc by looking, not by a script. Menu *structure* is mechanical (`tests/menu-dump.applescript`) and the v1.19.1 two-section order verified 2026-07-31. |
| R13 is category-first ("no other menu-bar util tells you") | Only **KeepingYouAwake 1.6.8** was inspected; Amphetamine and the standalone assertion-viewers are unchecked. The claim stays out of `README.md` and `docs/cover.html` until settled — `pmset -g assertions` is one command, so a wrong category claim is worse than none. |
| `ThroughputScaler` hysteresis, `SemVer` / `highestTag` parsing, `Restarter`'s argv + mode mapping | **No check at all.** These have no reachable functional path yet: the scaler needs sustained synthetic net/disk load to move its ceiling; the tag parse needs a checkout whose `origin` has canned `v*` tags; `Restarter`'s launchd branch needs a real LaunchAgent job. Don't "restore coverage" by re-adding a re-ported copy of the logic — see `AGENTS.md` § Testing rules. |
| The in-app update sequence: pull → `Builder.precompile` → Restart | **Click-only, unverified.** The pieces the launcher owns *are* covered — `qa.sh` §6 asserts `--precompile` builds and launches nothing, that a live instance survives the rebuild (the temp+rename), and that a rejected launch doesn't compile. What no run reaches is the modal path that drives them: the `Building vX.Y.Z…` row, the build-failed wording, and the restart actually being fast afterwards. Reaching it needs a checkout whose `origin` carries a newer canned tag — the same harness the row above wants — so it is walked by hand on the *previous* version's binary: `Check for Updates…` must become `Update available: vX.Y.Z`, the app must keep running while it pulls and compiles (reopen the menu: the row reads `Building vX.Y.Z…`), and **Restart** must come back within a second or two leaving exactly one instance. `rm -rf "$(getconf DARWIN_USER_CACHE_DIR)/clang/ModuleCache"` first to exercise the cold path — the *build* should then take ~30s and the restart still shouldn't. The failure being guarded against is silent and bimodal: with a warm module cache a deferred build costs ~7s and looks fine, so a regression only shows on the cold path. |
| Four §3e cases gated on a **quiet machine** (no display holder / no assertions at all) | §3e NOTEs each rather than faking a quiet system: R7's `tint=paused`, R16's `Nothing holding sleep`, attribution when another display holder sorts first, and the idle-only reading. Their states differ — R7's tone **is** confirmed by hand (2026-08-01: three consecutive `tint=paused` ticks, no `-w` child), so don't read its NOTE as the tone being unverified; the other three are unverified locally. The method for R7's tone, since anything holding the display masks a paused line entirely: `screencapture -x -R<x>,<y>,<w>,<h>` a strip of the bar (screen coords from `LOG_SLOTS`) and composite `bg×(1−α) + tint×α` to rank candidate alphas — a **proxy**, and where it and a direct look disagree the look decides (it did: the shipped `0.22` over the ratio's `0.30`). Don't soften any of them to make a run pass. |
| `SMCClient` holds exactly one `io_connect_t` | **Structural only** — IOKit connections aren't visible to `lsof`/`ps`, and counting `IOServiceOpen` calls needs dtrace (root + SIP off), so *exactly one* rests on the code's shape: one `static let shared`, one `openSMC()` call site, one write to `connection`. The weaker sharing-works claim **is** covered: fan and temperature driven together in one process, both correct (2026-08-01). Don't upgrade that into connection-counting, and don't "cover" the remainder with a re-ported copy of the client. |
| Temperature reader — three dark spots | (1) `Tpx*`-are-cluster-maxima verified on **one chip only** — re-run the ramp comparison on any new hardware; a wrong chip silently under-reads and no in-process sample can tell. (2) The all-clusters-parked branch (v1.20.1) has **no functional check and none is available** — hardware state, and forcing it needs a decision-changing hook, which is barred; reachable, not theoretical. (3) The map above ~78 °C is exercised by arithmetic only — the test machine peaks there. Don't cover any of these with a re-ported copy, and don't make the map adaptive. |
| Thermal pause rendering | No way to force a thermal state. The battery reasons share the code path and are covered by `tests/qa.sh` §3a; only the thermal *trigger* is untested. |
| Reduce Motion trigger (R17) | **No functional check.** The pref is the machine's, not the test's; forcing it needs a decision-changing hook, which is barred (`FORCE_BATTERY` got in only because a desktop has *no* battery to read — every Mac has a real, readable Reduce Motion setting). Everything downstream of the observer (freeze rendering, label handoff, persistence) is covered by `qa.sh` §3g via the manual toggle; only the notification→reading wiring is eyes-only: toggle System Settings → Accessibility → Display → Reduce Motion against a running instance — the icon freezes/resumes with no relaunch and the row reads `Freeze Animation — on via Reduce Motion` with the checkmark still tracking your own toggle. |
| Label slot order is "creation order", assumed not guaranteed | Confirmed on a roomy bar 2026-08-01 (§3c passed all six cases). The notched built-in display inverts the order **deterministically** (3/3, modified and unmodified binary) — environmental, not a code change, and contiguous-but-wrong, so §3c **FAILs** there: read an adjacency FAIL against which screen the bar was on before believing it. Deliberately not softened into a NOTE, or a real ordering regression hides behind it. Lead if it recurs: `NSStatusItem.autosaveName` is never set, and ⌘-drag positions persist against it — probe that first. |
| Everything behind a menu **click** | **Unscriptable, and checked by hand or nowhere.** No shell can click an `NSMenu`: preset switching via `Presets ▸`, the Other Sources ▸/▾ expand and its row-click source switch, `Settings ▸ Menu Bar Label` mode + `Position`, `Freeze Animation`, `Start at Login` (writes the real LaunchAgent with the *current* args), the Keep Awake tint pick / `Duration` / `Custom…` (`0 hr 0 min` cancels), and the low-battery arm **override**, which by design only a live click can set. Menu *structure* is a diff, not a squint — `osascript tests/menu-dump.applescript "$(pgrep -U "$(id -u)" -f '/MenuBarLoadRunner( |$)')"` (needs Accessibility for your terminal, resolve by **pid**, never by name); it cannot see selection marks, the menu bar itself, or what a click does. |

## Release hygiene

A version bump moves five surfaces together: `AppInfo.version`, the `CHANGELOG.md` heading, the
`README.md` version line, the `docs/cover.html` badge, and the git tag `UpdateChecker` reads.
`tests/qa.sh` §2 enforces the first four; the tag is deliberately unchecked (qa.sh runs before it
exists), so **pushing the commit and tag is the last manual step**. One rule with no other home: **the
tag gates the prompt; the branch carries the code** — a behavioral change committed *after* its release
tag is an undeliverable fix (`UpdateChecker` sees equal versions and offers nothing), resolved only by
the next bump across all five surfaces. Never re-cut a published tag.

**Cutting a release, in this order.** Steps 2, 3 and 6 look skippable and are not — each fails
silently, and nothing upstream catches it:

1. Bump `AppInfo.version`; move `CHANGELOG.md`'s `[Unreleased]` items into a dated section.
   MAJOR/MINOR/PATCH follow the public-API definition at the top of `CHANGELOG.md` (CLI flags, env
   vars, preset keywords + `presets.json` schema, observable behavior).
2. Give `docs/cover.html` the release's **prose**, not just its badge, then redeploy (the
   `publish-cover` skill; `npx wrangler whoami` first — the OAuth token usually persists, so no
   interactive login is needed). qa.sh §2 greps the badge and nothing else, so a cover describing the
   *previous* release passes every check while the badge reads as proof it is current. Its interactive
   demos need the same pass and fail differently: they model app behavior in JS, so a stale demo goes
   on *reproducing* the bug this release fixed — prose drift reads as stale, a stale demo reads as a
   specification. Click the demo for whatever you changed.
3. **Re-run `tests/qa.sh --core`** — §2 can only compare the version surfaces *after* you have edited
   them; skip it and a mistyped surface ships silently.
4. Tag `vX.Y.Z` — the fifth surface, and the only unchecked one.
5. Push the commit **and** the tag: `git push origin main vX.Y.Z`.
6. **Confirm it shipped with the command the app itself polls:**
   ```bash
   git ls-remote --tags origin 'v*' | sed 's|.*refs/tags/||; s|\^{}||' | sort -uV | tail -3
   ```
   A tag that never left your machine tells every installed copy the old version is current, silently,
   with the local repo looking fully released. Sort `-V`, never plain `sort`: lexically `v1.9.1` beats
   `v1.19.2`, which stopped being hypothetical at `v1.10.0`.

Ship when `tests/qa.sh` says ALL PASS, the click-only checks above are done, and **no NOTE covers what
this release changed** — a NOTE is an unanswered case, not an accepted one, and neighbouring cases
passing is not cover for it. Before signing off, check for a leaked keep-awake child by its `-w <pid>`
signature, never by name (your own instance holds one legitimately), with `ps -p`, never `kill -0`
(EPERM calls another user's healthy child a leak):

```bash
ps -o args= -ax | grep '^/usr/bin/caffeinate' | grep -- '-w ' | while read -r l; do
  ps -p "${l##*-w }" >/dev/null 2>&1 || echo "  LEAK: $l"; done
```

Don't record the cover's published state here — fetch it. This file has been wrong in *both*
directions, and a `curl` of the live badge settles it in one command; the flow, including the two
checks that read as a failed deploy and aren't, is the `publish-cover` skill's.
