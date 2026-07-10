# TODO — In-app update check + user-initiated self-update

Created: 2026-07-10 14:13

## Goal

Give the running app an in-app way to (1) *notice* a newer release exists and (2) apply it —
`git pull --ff-only`, then restart to pick it up — but **only** on the user's explicit menu click.
Detection is automatic and check-only; applying is strictly user-initiated (two gestures: menu
click → confirm dialog). No auto-apply, no launch-time modal, no silent code path.

## MVP scope (post plan-review, 2026-07-10)

A read-only `Plan`-agent pass validated this TODO against the real source and trimmed it to the
smallest thing that works. Confirmed OK: the `menuWillOpen` refresh seam, the launchd label
(`ai.bera.menubarloadrunner`, reused for relaunch), Swift-5-mode concurrency (strict-concurrency
violations are warnings, and `DispatchQueue.main.async` hop-backs already exist), and the ls-remote
premise. **Cut for MVP** (see each task + Out of scope):

- **No persisted cache / no 24h throttle** — this binary has no app bundle, so
  `Bundle.main.bundleIdentifier` is `nil` and `UserDefaults.standard` has no reliable on-disk domain.
  Rather than introduce a suite just for a throttle, MVP checks **once per launch** + a manual
  **Check for Updates…** item. The app persists zero preferences today; keep it that way.
- **No in-app recompile/relaunch machinery** — the launcher already rebuilds when the source is newer
  than the binary (`menubar-load-runner` mtime check), so MVP apply = `git pull --ff-only` → alert
  "Updated to vX.Y.Z — restart to apply". Next launch recompiles automatically. An optional
  **Restart Now** button (try `launchctl kickstart -k`, fall back to detached launcher spawn) is a
  nice-to-have, not required.
- **No persisted auto-toggle** — keep only the `--no-update-check` flag / env (no UserDefaults).
- **No About-dialog line** — the menu item is the real surface.

## Context & decision

The app is source-based: `install.sh` clones into `~/.local/share/menubar-load-runner`, precompiles,
and symlinks the launcher onto `PATH`. Once installed, **the running app never learns a newer release
exists** — the user has to re-run the installer on a hunch. `AppInfo.version` (`"1.6.0"`) is compiled
in; releases are cut as annotated git tags (`v1.0.0` … `v1.6.0`). The gap is a *notification + apply*
mechanism.

**Why not Sparkle** — the community-standard macOS updater needs a signed + notarized `.app` with an
appcast feed, all three deferred as out-of-scope (see `TODO-20260710-0809-user-friendly-installer.md`
and the `install.sh` header). For a source-based git-clone app the idiomatic analog is: **detect** by
reading the origin's release tags (`git ls-remote`), **apply** by reusing the exact update path
`install.sh` already runs on re-run. No new packaging/signing/hosting dependency; `git` + `swiftc` are
already hard requirements.

**Decisions (locked):**
- Detection via `git ls-remote --tags` (no API token, no 60/hr unauth rate limit, respects the actual
  origin incl. forks and the `MENUBAR_LOAD_RUNNER_REPO_URL` test override — none of which a hardcoded
  `api.github.com/repos/binlecode/...` call honors).
- Apply = in-app self-update (`git pull --ff-only` → recompile via launcher → relaunch), user-click +
  confirm gated.
- Written as this TODO first (reviewable before code).

## Principles (commitments)

1. **Non-blocking & throttled** — probe off-main via `Process`, ≤ once / 24h
   (`Tuning.updateCheckInterval`), result cached. Launch/UI never delayed.
2. **Fail silent** — offline / non-git checkout / missing `git` / malformed tags → no error, no nag.
   Only a positive "newer exists" signal surfaces UI.
3. **Passive, actionable surface** — a menu item, never a launch modal. Plus manual
   **Check for Updates…** bypassing the throttle.
4. **Stable channel + correct semver** — only `v<major>.<minor>.<patch>` tags, compared numerically
   component-by-component (never string compare, never `-rc`/pre-release).
5. **Transparent & disableable** — disclosed (README + About); off via `--no-update-check`,
   `MENUBAR_LOAD_RUNNER_UPDATE_CHECK=0`, or a menu toggle.
6. **User-initiated apply** — automatic path only checks + relabels the menu; `git pull` runs only
   after menu click → confirm dialog.

## Scope (this task)

Implement detection, the menu surface, and the click-gated `git pull --ff-only` in
`MenuBarLoadRunner.swift`, with the config knob and launcher/README/QA touch-ups. No changes to
`install.sh`, and no in-app recompile — the launcher rebuilds on the next launch.

---

## Tasks

### 1. Semver + remote tag probe (`UpdateChecker`)

- [x] Add `struct SemVer: Comparable` with `init?(_ s: String)` accepting `"v1.6.0"`/`"1.6.0"`,
      rejecting anything not exactly three numeric components (drops `v1.2.3-rc1`, moved tags, junk).
- [x] Add `enum UpdateChecker` with the pure `highestTag(inLsRemoteOutput:)` (string → max `SemVer`)
      and the impure `latestRemoteTag(repoDir:)` running
      `git -C <repoDir> ls-remote --tags --refs origin 'v*'` (blocking `Process`; callers dispatch
      off-main). `--refs` strips `^{}` peel lines. Split so parsing is unit-testable without a network.
- [x] Compare max-remote vs `SemVer(AppInfo.version)`; `remote > local` ⇒ update available. Call site
      landed in `refreshUpdateStatus()` (Task 3). `UpdateChecker` also grew a shared `runGit` helper +
      `pull(repoDir:)` for the apply path (Task 4).

### 2. Anchor + check-once-per-launch

- [x] Promoted `scriptDirURL` to a stored `private let scriptDirURL: URL` (kept the name; assigned in
      `init` where the local was computed). Resolution logic unchanged.
- [x] Added computed `repoDirURL: URL?` gating `scriptDirURL` on `.git` existing. Nil ⇒ update UI
      hidden.
- [x] Launch probe added before the EXIT_AFTER hook: gated on `updateCheckEnabled && !suppressModalAlerts`
      (skips headless/QA so it stays offline), dispatched to `DispatchQueue.global(qos: .utility)`. The
      `[weak self]` capture is on the main-queue closure (not the background one) — required to stay
      warning-clean under `-strict-concurrency=complete`.
- [x] Result held in `latestKnownVersion: SemVer?` (in-memory only). **No `UserDefaults`, no throttle.**
      Added `updateCheckInFlight` to guard against stacking concurrent git processes.

### 3. Menu surface

- [x] Added `updateItem` + `checkForUpdatesItem`; `refreshUpdateStatus()` wired into `menuWillOpen`
      and the initial refresh batch.
- [x] State machine: newer-known → bold (attributed) **"Update available: vX.Y.Z →"**, action
      `promptSelfUpdate`; else `isHidden = true`. Both items hidden when `repoDirURL == nil`.
- [x] Added **Check for Updates…** above About → forces a fresh probe; `reportManualCheckResult`
      surfaces the outcome (up-to-date info / error / routes a newer find straight to the confirm).
- [x] ~~About-dialog line~~ — CUT for MVP (cosmetic; the menu item is the real surface).

### 4. Self-update (click-gated apply) — `promptSelfUpdate()`

- [x] **Confirm** `NSAlert` ("Update" default / "Cancel"), naming the target version — the second
      gesture; no path reaches `git pull` without it. Honors `suppressModalAlerts`.
- [x] **Pull** (background) via `UpdateChecker.pull` = `git -C <repoDir> pull --ff-only`. Failure ⇒
      `showUpdateFailed` shows git's message + **Open Releases Page** (`NSWorkspace.shared.open`). No
      `--force` / `reset`.
- [x] **On success → `informational` alert "Updated to vX.Y.Z — restart to apply."** No in-app
      recompile/relaunch; the launcher rebuilds on next launch.
- [ ] *(Optional, deferred)* **Restart Now** button — not shipped in v1 per MVP.

### 5. Config knobs

- [x] `Config` → `updateCheckEnabled: Bool` (default `true`) from `--no-update-check` +
      `MENUBAR_LOAD_RUNNER_UPDATE_CHECK` ∈ `{0,false,no}` (env only disables).
- [x] ~~Persisted "Check for Updates Automatically" menu toggle~~ — CUT for MVP.
- [x] Documented the flag/env + network disclosure in `Config.printUsage()`.

### 6. Launcher / README / QA

- [x] `menubar-load-runner` — documented `--no-update-check` in `print_help` + the usage synopsis.
- [x] `README.md` — added an "Updates" section (what it does, network disclosure, how to disable, the
      confirm→pull→restart flow) + the two menu items to "Menu actions".
- [x] `tests/qa.sh` — added §5 `tests/semver.swift` (14 checks: strict parse, numeric ordering,
      canned `ls-remote` parse — no network) + a `--no-update-check` acceptance/help check in §2.

### 7. Verify before shipping

- [x] Compile warning-clean (`-O -strict-concurrency=complete`); full core QA `tests/qa.sh --core`
      ALL PASS (incl. new §2 flag checks + §5 semver 14/14).
- [x] Fail-silent: an integration harness exercising the real `UpdateChecker` against a dir outside
      any repo returns `latestRemoteTag == nil` / `pull ok=false`; `repoDirURL` gate returns nil for a
      non-`.git` layout. Boot with and without `--no-update-check` is clean (exit 0, no stray stderr).
- [x] Happy path (local bare `origin` + on-branch clone reset to `v1.5.1` in `tmp/`): real
      `latestRemoteTag` returns `v1.6.0`; `pull --ff-only` fast-forwards and `AppInfo.version` moves
      `1.5.1 → 1.6.0` (so a restart runs the new version). Dirty tree aborts (exit 1) with git's
      "local changes would be overwritten" message → feeds the failure alert + releases-page hatch.
- [ ] **Manual (GUI)**: visually confirm the bold "Update available" item renders and the confirm
      dialog appears — the §7 interactive spot-check (menu interaction isn't scriptable here).
- [ ] *(N/A — Restart Now deferred.)*

---

## Open questions

- *(Resolved by plan-review — no longer blocking.)* Relaunch is CUT from MVP: apply is `git pull`
  + "restart to apply", and the launcher auto-rebuilds on next launch. The optional **Restart Now**
  avoids install-type detection (which has no clean signal — a detached ad-hoc run also reparents to
  pid 1) by just trying `launchctl kickstart -k` and falling back to a detached spawn. Full launchd
  mechanics in `DESIGN-system.md` §19.

## Out of scope (deliberately cut, matching installer MVP ethos)

- Auto-applying updates without the confirm click.
- Pre-release / beta channels, tag pinning, downgrade.
- Delta/binary downloads or an appcast (the Sparkle path — see Context).
- Notifying about un-tagged `main` commits (releases are tag-gated).
- Changes to `install.sh` (remains the bootstrap).

**Deferred to post-MVP** (cut by plan-review; add only if a need shows up): persisted cache + 24h
auto-throttle (needs a `UserDefaults` suite — no bundle id), in-app recompile + relaunch, a persisted
auto-check toggle, and the About-dialog line.

## When done

Fold the as-built details into `DESIGN-system.md` (new section) and reduce this TODO to a closed
state with per-task outcomes, per repo convention.
