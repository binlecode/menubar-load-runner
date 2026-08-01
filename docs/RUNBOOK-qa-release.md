# Runbook: QA a release

One command is the gate. The rest of this file is only what a shell cannot do — clicks, eyes, and the
release mechanics. Run everything from the repo root.

## 1. The gate

```bash
tests/qa.sh              # build + GUI tiers — must end "QA: ALL PASS"
tests/qa.sh --launcher   # adds §6; stops running instances, so run it once before shipping
tests/qa.sh --core       # headless/CI subset (no WindowServer)
```

A `NOTE` is not a failure — it means this machine couldn't answer that case (its own sleep assertions,
menu-bar crowding and battery are not the harness's to control). **But read every NOTE against what this
release changed.** A NOTE sitting over the feature you are shipping is not an accepted environmental
limit; it is an unverified release. Neighbouring cases passing is not cover for it either — a tone's
*precedence* can pass green while the tone itself is never once observed.

Most §3e NOTEs come from one process holding a display assertion for the whole run. Name it and quit it:

```bash
pmset -g assertions | grep -i display     # the culprit is usually a browser playing media
```

| What it proves | qa.sh |
|---|---|
| build is warning-clean under `-strict-concurrency=complete` | §1 |
| CLI parse paths + every in-repo version surface agrees with `AppInfo.version` | §2 |
| all 7 load sources launch and exit 0, incl. availability fallback | §3 |
| label slot: adjacent, constant width, icon never moves | §3c |
| Keep Awake battery conditions, 5% floor, `--battery-threshold` | §3a |
| Keep Awake launch arming, window round-trip, saved states that must not return | §3f |
| settings persistence (label mode + side, battery threshold) | §3b |
| other processes' sleep assertions: detection, grouping, retention, own-child exclusion | §3d |
| machine sleep-hold row + the three track-line tones | §3e |
| error paths exit fast with no modal (bad GIF, bad manifest) | §4 |
| every reader's live readout: shape, range, reserved width | §5 |
| launcher compile-on-run, arg forwarding, singleton | §6 |

**Not gates:** `tests/install-smoke.sh` (install/uninstall round-trip in a `tmp/` sandbox) and
`tests/clamshell-sleep-check.sh` (a *diagnostic* — host power behavior varies per machine, so there is
nothing to assert; needs a quiet machine and a physical lid).

Known gaps live in `ROADMAP.md` § Verification debt — check it rather than assuming this table is total.
`ThroughputScaler`'s hysteresis/headroom is the notable one: §5 only proves its output stays in range.

## 2. Hooks for checking by hand

`AGENTS.md` carries the full rationale for each; this is the index.

| Env var | Use |
|---|---|
| `MENUBAR_LOAD_RUNNER_EXIT_AFTER=<s>` | self-terminate after N seconds **and suppress modal alerts** — the knob that makes a blocking GUI app scriptable |
| `MENUBAR_LOAD_RUNNER_STATE_FILE=<path>` | redirect persisted state. **Set it on every hand-run**, not just Keep Awake ones: any launch rewrites the file on exit |
| `MENUBAR_LOAD_RUNNER_FORCE_BATTERY=<pct>[:battery\|:ac]` | pin the power-source read — low-battery paths with no battery, on any Mac |
| `MENUBAR_LOAD_RUNNER_FORCE_UNAVAILABLE=gpu,…` | force sources unavailable, to see the disabled + fallback state on working hardware |
| `MENUBAR_LOAD_RUNNER_LOG_SLOTS=1` | every status item's frame per tick — the only way to answer "where is the item / did it move?" with no TCC grant |
| `MENUBAR_LOAD_RUNNER_LOG_ASSERTIONS=1` | the filtered other-holders list, plus `own=N` |
| `MENUBAR_LOAD_RUNNER_LOG_AWAKE=1` | derived sleep-hold state, the rendered row text, and `tint=` (which tone the line/label wear) |

**Test a TCC grant, never assume it.** Several checks here are labelled "needs Accessibility" or "needs
Screen Recording", and it is easy to read that as *you can't*. Whether the grant exists is one command
each, and a terminal that has been used for this work before usually has both:

```bash
osascript -e 'tell application "System Events" to return name of first application process'  # Accessibility
screencapture -x -R0,0,80,20 tmp/tcc-probe.png && echo "screen recording OK"                 # Screen Recording
```

With those, the §3.2 menu walk and the pixel measurement in §3.1 are both available — no eyeballing and
no second person required.

Four things that bite:

- `--foreground` / `--no-detach` / `--extra` are **launcher-only**. Passed to the raw binary they read as
  a GIF path → decode failure → modal box.
- **Never grep for a leaked `caffeinate` by name** — your own real instance holds one. Match `-w <pid>`
  and check the pid is dead.
- Error paths are modal for real users; drive them under `EXIT_AFTER` or `timeout` or a dialog blocks.
- The memory used-fraction is a deliberate approximation (available = free + purgeable + external), so it
  reads higher than Activity Monitor. Not a bug.

## 3. By hand, once per release

### 3.1 Keep Awake — what needs a click

The override is set **only** by a live menu click, by design. Launch at a forced low charge, keep-awake
off: `MENUBAR_LOAD_RUNNER_STATE_FILE=$PWD/tmp/qa-state.json MENUBAR_LOAD_RUNNER_FORCE_BATTERY=15:battery ./tmp/mblr-check`

- [ ] Pick **Dusty Teal** → the track line appears and **stays at full strength** (an honored override is
      running, not paused), a `-w <pid>` child exists, and the parent row does **not** say paused.
- [ ] Relaunch with `--keep-awake 30m` (a flag is not a gesture) → `Keep Awake: 29:5x (paused)`,
      `paused — battery low (15%)`, no child. At `4:battery` → `paused — battery critical (4%)`.
- [ ] **Look at the menu bar, not the menu:** in that paused run the line is still there and visibly
      dimmer than when holding. Compare holding / paused / `Off` in a light *and* dark menu bar. qa.sh §3e
      proves which tone was chosen; only looking proves it reads. If it doesn't, retune
      `Tuning.keepAwakeBarPausedAlpha` — otherwise the feature is a no-op that tests green.
      **Three things make this harder than it sounds:**
    - **Anything holding the display masks the paused tone entirely** — correctly, since a foreign hold
      outranks our pause. A browser playing media is enough, and it *re-acquires silently* after you
      pause the video, so check at the moment of observation, not before:
      `pmset -g assertions | sed -n '/Listed by owning process/,$p' | grep -i displaysleep`
    - **Holding and paused cannot be shown side by side.** The holding instance's own `caffeinate` holds
      the display for the whole machine, so a paused instance next to it renders *foreign*. Compare them
      in sequence, one at a time. Paused vs `Off` — the pair the feature exists for — is safe together.
    - **Measure to compare candidates; decide by looking.** `screencapture -x -R<x>,<y>,<w>,<h>` a strip
      of the bar (coordinates from `LOG_SLOTS`, which reports screen coords), then read the line's pixels
      and composite the tone yourself: `bg×(1−α) + tint×α`. That turns "looks a bit faint" into a contrast
      ratio and lets you evaluate a candidate alpha without waiting for a machine quiet enough to render
      the paused state at all. **Expect the light bar to be the weak case** — its tint is darker than its
      background rather than lighter, so every tone lands at a lower contrast than its dark-bar twin.
      But the ratio is a **proxy** (and a text-legibility one, on a 2pt line): where it and a direct look
      disagree, the look decides. It did — the shipped `0.22` is the eyes' answer over the ratio's `0.30`,
      and the light bar's 1.29:1 is an accepted reading, not an open defect. `DESIGN-system.md` §22.5.
- [ ] The countdown **keeps ticking while paused** — the window is a wall-clock deadline and elapses
      whether or not the child is holding, so a pause must not freeze it (`29:55 → 29:44 → 29:34` on a
      paused instance). Same with the override active.
- [ ] Change the threshold while armed at `25:battery` → the child dies *at once* and the row says
      `paused — battery low (25%)`, without waiting for a power event. Back to 10% re-engages.
      Changing the threshold at all must also **retire** a granted override.
- [ ] The **default** state path works (qa.sh always redirects it, so a broken Application Support path
      would go unnoticed): with no real state of your own, `MENUBAR_LOAD_RUNNER_EXIT_AFTER=3
      ./tmp/mblr-check --keep-awake 45s`, confirm
      `~/Library/Application Support/menubar-load-runner/state.json` was written, then delete it.

### 3.2 Menu walk

```bash
./menubar-load-runner --load-source memory --foreground     # Ctrl-C when done
osascript tests/menu-dump.applescript "$(pgrep -U "$(id -u)" -f '/MenuBarLoadRunner( |$)')"
```

The dump makes structure a diff instead of a squint (needs Accessibility for your terminal, which is why
it isn't in qa.sh). It works on a raw `./tmp/mblr-check` too, so you needn't stop your real instance, and
it reads an **armed** menu — the state most worth dumping.

It settles these mechanically, so treat the boxes as a diff: root row order and count, both Keep Awake
sections and their order, the countdown/paused row and its separator appearing only when armed, the
`Settings ▸` / `Presets ▸` contents, and every parent-row readout. It cannot see selection marks (a custom
`onStateImage`, so `AXMenuItemMarkChar` is blank, and an AX-opened menu isn't rendered), anything about the
menu *bar* itself (tint, jitter, animation), or what a click does. Two traps: resolve by **pid, never by
name** (a stale instance holds the *previous* build's menu), and the status item is `menu bar 1`.

- [ ] Icon animates; speed responds to load over ~10s. Selection marks render as a solid **dot**.
- [ ] Trace chart at the top of the active source; newest sample right; color tracks Low→High — except
      battery, an inverted fuel gauge (low charge reads red).
- [ ] The metric lines are the **active** source's only. Under `memory_pressure -l` the memory line gains
      a live `· N.N MB/s` swap segment and the animation outruns used-% alone.
- [ ] **Other Sources** collapses/expands inline (▸/▾), one row per available non-active reader with its
      own live readout; clicking a row switches the driving source (lines + trace flip, rate sources
      re-warm one tick). `--show-all-sources` starts it expanded.
- [ ] Each source's readout has the right shape (`GPU: NN%`, `Network: ↓N.N MB/s ↑N.N MB/s`,
      `Disk: read N.N MB/s write N.N MB/s`, `Fan N: NNNN RPM (NN%)` — one ` · `-joined segment per fan,
      `Battery: NN% · N.N A` on battery / `Battery: NN% · AC` plugged in) and a real load on it speeds
      the animation. The trailing clause is the part worth reading: the amps figure is what drives the
      battery source, the way swap does for memory. Network settles after a burst — no permanent
      max-out, no idle jitter. Loads to hand: `memory_pressure -l` (swap), a download (net),
      `dd if=/dev/zero of=tmp/x bs=1m count=500` (disk — §4 deletes it).
- [ ] Relaunched with `MENUBAR_LOAD_RUNNER_FORCE_UNAVAILABLE=gpu,network,disk,fan,battery`, those sources
      are **absent from the Other Sources list** — qa.sh §3 sees only the fallback log line, not the menu.
- [ ] **Keep Awake ▸ is two sections:** **This Mac** first and unheaded (machine-hold row, then
      `Other Assertions` and its indented rows as that row's evidence), then a disabled **This App**
      header with Off + five tints, `Duration`, and the countdown/paused row last. Check the reading the
      split exists for: with a foreign `caffeinate -di -t 120` running, the top row says the Mac is held
      while `Off` stays ticked below, and the two do not read as a contradiction. With nothing armed the
      countdown row **and the separator above it** both hide.
- [ ] Picking a tint engages (a `-di -w <pid>` child appears); switching tints recolors live and must
      **not** respawn (same pid) — only changing the window does. **Sage** reads green, distinct from
      **Dusty Teal**.
- [ ] `Duration` arms in one click; `Custom…` takes hr + min (`0 hr 0 min` **cancels**, changing
      nothing); the countdown **ticks every second** with the menu held open. Let a
      short window elapse → caffeinate exits itself, the mark returns to **Off**, the line disappears.
      (Dark is correct at expiry: it clears intent. A *pause* keeps a dimmed line — §3.1.)
- [ ] Arm a window, **Exit**, relaunch → the *remaining* time resumes, not the full length, and the tint
      returns. (qa.sh §3f asserts this against a redirected file; this is the visual half.)
- [ ] **Other Assertions** rows: indented, unclickable, one row per **owner** with the **raw** type
      strings (never a gloss — an assertion is not an effect), and this app's own child never listed.
      Force one with `swiftc -O tests/hold-assertion.swift -o tmp/mblr-assert-probe && tmp/mblr-assert-probe 30`.
- [ ] **`Settings ▸ Menu Bar Label`**: Off / Live Value / Custom Text…, the parent row reads
      `Menu Bar Label: live value`, and `Position` moves the slot to either side immediately (the icon shifts
      once, by the slot width — that's the move). Set it while Off too, then turn the label on. Both
      survive a no-flag relaunch. Eyes-only residue §3c/§5 can't see: no `…` truncation, no obvious dead
      space (`--load-source network` is widest), digits reading as columns.
- [ ] With Keep Awake running the label is tinted like the track line (pick Sage or Mauve), and both
      revert together on Off or suspend.
- [ ] **`Settings ▸ Battery Threshold`**: parent reads `Battery Threshold: 20%`, mark on the matching
      row, an uncovered value (`18`) marks **Custom…**; a blank/non-numeric custom entry changes nothing.
      The trace's red band must still turn at **20%** under `--battery-threshold 10` — it is not the
      release point. Set 15% from the menu, Exit, relaunch with no flags: it still reads 15%.
- [ ] **`Presets ▸`** switches the animation on click and the mark follows. qa.sh §3 only ever launches
      a keyword, so the click is checked here or nowhere.
- [ ] **`Settings ▸ Start at Login`** toggles the LaunchAgent: enabling writes
      `~/Library/LaunchAgents/ai.bera.menubarloadrunner.plist` with the *current* preset/source/label baked
      in and the row reads checked on the next open; disabling removes it. Nothing in qa.sh touches this —
      it shells out to `scripts/(un)install-login-item.sh` and changes your account.
- [ ] Root menu reads: trace · 5 metric lines · `▸ Other Sources` · `Settings` · `Keep Awake` ·
      `Presets` · `Check for Updates…` · `About` · `Exit` — **13 rows** as launched, 19 with Other
      Sources expanded on a 7-source Mac (15 / 21 with the `Slowing animation` and `Update available`
      lines). `Width` is read-only, **About** shows the version, **Exit** works.
- [ ] **Update check + restart** (needs a real newer tag, so check it on the *previous* version's
      binary): `Check for Updates…` becomes `Update available: vX.Y.Z`; the success alert's **Restart**
      quits and comes back on the new version within seconds, with exactly one instance afterwards. Switch
      the preset and source first — a **detached** run carries them over on the re-exec, a **LaunchAgent**
      correctly resets to the plist's baked args. Under `--foreground` there must be **no** Restart button.
      `--no-update-check` removes the check entirely.

## 4. Sign-off, then cut the release

```bash
pkill -U "$(id -u)" -f 'mblr-check' 2>/dev/null
pkill -U "$(id -u)" -f 'MenuBarLoadRunner' 2>/dev/null   # -U like every other pgrep/pkill in this repo
# ^ this also stops your OWN instance. The LaunchAgent has no KeepAlive, so a login-item one stays down
#   until next login — `launchctl kickstart gui/$(id -u)/ai.bera.menubarloadrunner` brings it back.
rm -rf tmp/mblr-check tmp/mblr-assert-probe tmp/qa-* tmp/x   # incl. §3.2's 500MB disk-load file
sleep 1   # `caffeinate -w <pid>` exits when its parent does — don't race it into a false LEAK
ps -o args= -ax | grep '^/usr/bin/caffeinate' | grep -- '-w ' | while read -r l; do
  ps -p "${l##*-w }" >/dev/null 2>&1 || echo "  LEAK: $l"; done   # a child bound to a dead pid
git status --short
```

`-w <pid>` is always the **last** argument the app passes, so `${l##*-w }` is the whole pid. Use `ps -p`,
not `kill -0`: on a shared Mac another user's instance shows here too, and `kill -0` fails it with EPERM
and calls a healthy child a leak.

Ship when `tests/qa.sh` says ALL PASS, §3 is ticked, no NOTE covers what this release changed, and the
diff is reviewed.

**Cutting it, in this order.** Steps 2, 3 and 6 are the ones that look skippable and are not — each
fails silently, and none of them is caught by anything upstream:

1. Bump `AppInfo.version`; move `CHANGELOG.md`'s `[Unreleased]` items into a dated section.
   MAJOR/MINOR/PATCH follow the public-API definition at the top of `CHANGELOG.md` (CLI flags, env vars,
   preset keywords + `presets.json` schema, observable behavior).
2. **Give `docs/cover.html` the release's prose, not just its badge**, then redeploy (`publish-cover`).
   The deploy is described as needing an interactive Cloudflare login, but the OAuth token persists
   between publishes — check with `npx wrangler whoami` before assuming a human has to sign in.
   qa.sh §2 greps the badge and nothing else, so a cover describing the *previous* release passes every
   check while the current badge reads as proof it is current. This is the surface that drifts most —
   `ROADMAP.md` § Release hygiene keeps the tally.
   **Its interactive demos need the same pass, and they fail differently.** They model app behavior in
   JS, so a demo can go on *reproducing* the bug the release just fixed — rendering a state the app now
   distinguishes as the state it used to be confused with. Prose drift at least reads as stale; a stale
   demo reads as a specification. Neither is greppable, so click the demo for whatever you changed.
3. **Re-run `tests/qa.sh --core`.** §2's entire job is asserting the four in-repo version surfaces agree,
   and it can only do that *after* you've edited them. Skip it and a mistyped surface ships silently.
4. Tag `vX.Y.Z`. The tag is the fifth surface and the only unchecked one — qa.sh runs before it exists.
5. Push the commit **and** the tag: `git push origin main vX.Y.Z`.
6. **Confirm it shipped, using the command the app itself uses:**
   ```bash
   git ls-remote --tags origin 'v*' | sed 's|.*refs/tags/||; s|\^{}||' | sort -uV | tail -3
   ```
   `UpdateChecker` polls exactly this, so a tag that never left your machine tells every installed copy
   the old version is current — silently, and with the local repo looking fully released. A tag can be
   cut correctly and still never ship; this is the only step that can tell you. Sort with `-V`, never a
   plain `sort`: lexically `v1.9.0` beats `v1.10.0`, so the naive form names the wrong "latest" the
   moment a minor reaches double digits — and then hides exactly the gap you are checking for.

## 5. Adding coverage when the app grows

- **New CLI flag / env var** → a parse case in qa.sh §2 and a lifecycle run in §3. If it can be baked
  into a login item, assert a *bad value* is non-fatal.
- **New persisted state** → give it a `STATE_FILE`-style override *before* writing any test, then a
  round-trip in §3b. State only a real user path can write is state QA will silently corrupt.
- **New load source** → a §3 run, a line in §5's `spec` loop, and its availability/fallback to §3.2.
  App-side steps are in `AGENTS.md`.
- **New normalization/scaling** → drive the **real binary** and assert the readout. Never re-port the
  type into a probe — that pattern fails by *passing* (`AGENTS.md` § Testing rules). No functional path
  yet? Say so in `ROADMAP.md` § Verification debt.
- **New modal** → honor `suppressModalAlerts` (else §4 hangs) and add it to §3.2.
- **New preset** → `gifs/presets.json` plus a §3 lifecycle run for the keyword. No Swift change needed.
