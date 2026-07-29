# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## Public API (what semver governs)

MenuBar Load Runner is a CLI-launched app; the surface that MAJOR / MINOR / PATCH bumps apply to is:

- **Launcher CLI** — the positional preset keyword or GIF path, and the flags
  `--speed-multiplier`, `--label`, `--load-source`, `--keep-awake`, `--battery-threshold`,
  `--no-update-check`,
  `--foreground` / `--no-detach`, `--detach`, `--extra`, `-h` / `--help`.
- **Environment variables** — `MENUBAR_LOAD_RUNNER_PATH`, `MENUBAR_LOAD_RUNNER_LOAD_SOURCE`,
  `MENUBAR_LOAD_RUNNER_LABEL`, `MENUBAR_LOAD_RUNNER_KEEP_AWAKE`,
  `MENUBAR_LOAD_RUNNER_BATTERY_THRESHOLD`, `MENUBAR_LOAD_RUNNER_UPDATE_CHECK`,
  `MENUBAR_LOAD_RUNNER_LOG_FILE`, `MENUBAR_LOAD_RUNNER_BIN_NAME`, and the debug/QA hooks
  `MENUBAR_LOAD_RUNNER_EXIT_AFTER`, `MENUBAR_LOAD_RUNNER_FORCE_UNAVAILABLE`,
  `MENUBAR_LOAD_RUNNER_FORCE_BATTERY`, and `MENUBAR_LOAD_RUNNER_STATE_FILE`.
- **Built-in preset keywords** and the `gifs/presets.json` manifest schema.
- **Observable behavior** — the status menu structure, the default preset, and the load-adaptive
  speed contract.

Internal implementation details (Swift types, `Tuning` constants, file structure) are **not** part
of the public API and may change in any release.

## [Unreleased]

## [1.15.2] - 2026-07-28

"Updated — now go quit and relaunch it yourself" was the weakest sentence in the app. The update prompt
now has a **Restart** button, and the reason it took until now is worth stating: the app can't simply
re-exec itself, because the pull moves the *source* and it is the launcher that recompiles. Coming back
on the new version means re-invoking whatever started you — which the process cannot work out on its
own, since a detached run and a login-item run both reparent to pid 1. So each launch path now leaves a
signal, and launchd is *asked* rather than guessed at.

### Added

- **A `Restart` button on the post-update alert.** Click it and the app quits and comes straight back on
  the new version — no hunting for `Exit` and a terminal. It appears for a normal (detached) launcher run
  and for a start-at-login LaunchAgent; a `--foreground` run belongs to the shell that started it, so
  there the alert still says to quit and relaunch by hand.

  What carries across the restart: everything already saved to disk (Keep Awake window and tint, menu-bar
  label, battery threshold) **plus** the things that are not — the preset, load source, fixed
  `--speed-multiplier`, and the Other Sources disclosure you picked from the menu are passed on the
  re-exec, so a Restart doesn't quietly revert what you just set. An **indefinite** Keep Awake window is
  passed explicitly too, because the ordinary restore path refuses to resume one on purpose (a launch with
  nobody present must not hold the Mac awake forever) — a restart you asked for is a different situation.

  One documented asymmetry: under the LaunchAgent the relaunch uses the arguments baked into the login
  item, since nothing can inject into a plist's `ProgramArguments`. Menu-chosen preset/source reset to
  those there; everything saved to disk still carries over.

### Changed

- The launcher now exports `MENUBAR_LOAD_RUNNER_LAUNCHER` (its own symlink-resolved path) and
  `MENUBAR_LOAD_RUNNER_LAUNCH_MODE` (`detached`/`attached`), which is how the app knows whether — and
  how — it can restart itself. Neither affects normal operation.

## [1.15.1] - 2026-07-28

A one-click update that can't update is worse than no update button, and on a checkout that was copied
between machines rather than cloned, that is exactly what shipped: the pull needed a piece of git config
the copy never had, and the alert offered no way to supply it. The fix is to stop depending on the
config at all.

### Fixed

- **`Check for Updates` no longer dead-ends on a checkout with no upstream branch.** The update ran a
  bare `git pull --ff-only`, which needs `branch.<name>.remote`/`.merge` — config a *cloned* checkout
  always has, but one that was copied between machines (or whose branch was made with `--no-track`)
  does not. The pull then failed with git's "There is no tracking information for the current branch",
  an error nothing in the alert could fix: no button in the app writes git config, so the one-click
  update was stuck on a checkout that was otherwise a clean fast-forward. It now names the refspec
  explicitly — `git pull --ff-only origin <current-branch>` — whenever tracking is absent, using the
  same `origin` the update check reads its tags from. A detached HEAD still gets the bare form, so
  git's own "you are not currently on a branch" is what surfaces.

## [1.15.0] - 2026-07-28

The 20% battery cliff was never yours to move. Now it is — from the command line, from the menu, and it
remembers. The number had been hardwired since Keep Awake shipped, which is wrong in both directions:
too eager if you're finishing a render at 18%, too patient if you'd rather the Mac gave up earlier.
Note this *relocates* the cliff; it does not replace the arm-anyway override added in 1.13.1, which
answers a different question ("hold it anyway, just this once") and stays.

One thing that did not change, deliberately: the battery sparkline's red band still turns at 20%
whatever you set the release point to. Those two numbers had been a single constant, and separating
them was the first commit of this release precisely so moving one could never recolor the other.

### Added

- **The battery level that releases Keep Awake is now yours to set.** It has always been a hardwired
  20%, which is wrong in both directions — too eager if you're finishing a render at 18%, too late if
  you want the Mac to give up earlier. `--battery-threshold <pct|off>` (or
  `MENUBAR_LOAD_RUNNER_BATTERY_THRESHOLD`) moves it: a whole percent from 6 to 100, or `off` to never
  release on charge alone. Whole percents only — `20` or `20%`, not `0.20`, which reads as 0.2% under
  one convention and 20% under the other. Out-of-range and unrecognized values warn on stderr and
  launch anyway (clamped, or at the 20% default), because this can be baked into a login item.
  **Below 5% on battery the Mac still sleeps regardless** — that floor is checked first and is not
  configurable, which is also why the minimum is 6%. The setting **survives a relaunch** — including
  `off`, the one value where forgetting it would quietly reinstate a policy you turned off — while an
  explicit flag or env value still wins over what was saved.

  It is also a menu setting: **`Settings ▸ Battery Threshold`** offers 10 / 15 / 20 / 30%, `Never`, and
  a `Custom…` percent prompt, with the current value in the parent row's title. Picking one applies
  **immediately** — a Keep Awake window that is already running moves to the new release point instead
  of waiting for the next battery event. The menu says `Never` where the flag says `off`, because the
  Keep Awake submenu two rows away already has an `Off` that means something else entirely. Changing
  the threshold also retires an active arm-anyway override: that gesture answered a question about the
  old release point, so raising the threshold can't inherit a "yes" you gave about a different number.

## [1.14.0] - 2026-07-26

A prerequisite shipped as a release: settings now have a home. The dropdown had become the only place
any preference could live, and it was full — ~33 rows on a 12-preset install, two of whose sections grow
on their own — so the next toggle had nowhere to go. This adds a `Settings` submenu and a `settings` block
in the state file, moves the preset list into its own submenu, and pays off the first debt that home
makes payable: the menu-bar label no longer forgets what you picked.

Nothing about the animation, the load sources, or Keep Awake changes. The menu *layout* does — see
Changed.

### Added

- **Your menu-bar label choice is remembered.** Picking `Live Value` or a custom text from the menu used
  to last only until you quit — the setting existed solely as a launch flag. It now survives a relaunch,
  saved in `state.json` alongside Keep Awake. `--label` / `MENUBAR_LOAD_RUNNER_LABEL` still wins for that
  run, and an explicit `--label off` starts with no label even if one was saved (an empty env value counts
  as *not given*, so it can't clobber a saved mode).
- **A `Settings` submenu**, so preferences have somewhere to live that isn't the top level. It holds
  `Menu Bar Label` today; the battery threshold and duration presets are the next candidates.

### Changed

- **The 12 preset rows moved into a `Presets ▸` submenu**, and the label selector moved under `Settings ▸`.
  The root menu drops from ~33 rows to 13 as launched (19 with `Other Sources` expanded on a 7-source
  Mac). The trade is honest: picking a preset now costs one extra hover, and the label selector is one
  level deeper. `Keep Awake` stays at the root — its Off row and tints are a single radio group, so it's
  an action, not a preference.
- **The About dialog no longer points at a menu that doesn't exist.** It read "change it in the Load
  Source menu"; that submenu was replaced by the inline **Other Sources** list and the string was never
  updated. It now names the real one.
- **`state.json` now has one writer, `persistState()`, and must keep having exactly one.** The file is
  saved whole, so a block-specific writer would drop the block it doesn't own — arming Keep Awake would
  have erased a saved label, and changing the label would have erased an armed window. Both blocks are
  composed from live state on every save. `tests/qa.sh` §3b asserts the cross-block case directly.

## [1.13.1] - 2026-07-26

Two silent failures, both of the same kind: the app accepted an instruction, did nothing, and said
nothing. Keep Awake armed on a low battery released itself immediately while still showing as on, and
the launcher's single-instance guard refused a second user's first launch by naming a process in
another account's session. No new features; the only addition is a QA hook that makes the first one
testable.

### Fixed

- **Keep Awake no longer pretends to work on a low battery.** Arming it while on battery at or below 20%
  used to engage and then release immediately — the tint stayed ticked in the menu, but `caffeinate` was
  killed, so the Mac slept anyway. The only hint was the absence of a 2pt track line. Two changes:

  - **An explicit arm from the menu is now honored.** Turning Keep Awake on, picking a duration, or
    clicking a tint row while it reads paused all count as "I know the battery is low, do it anyway."
    A **new 5% floor** (`Tuning.batteryCriticalThreshold`) still ends it regardless, so an override
    can't drain the Mac to a hard power-off. Above the 20% threshold nothing changes.
  - **A paused Keep Awake is never silent.** The menu's `Keep Awake` row shows `(paused)` — visible
    without opening the submenu — and the row inside states why: `paused — battery low (15%)`,
    `paused — battery critical (4%)`, or `paused — Mac is too warm`. This covers the thermal pause too,
    which was equally invisible before.

  The override is deliberately **not persisted** and is set only by a live menu gesture — never by
  `--keep-awake` or a restored window, which fire at login with nobody present to weigh a low battery
  against the task. Thermal pauses remain non-overridable: overheating is transient, and holding the Mac
  awake through it is a hardware risk rather than a preference.

- **A launch-time Keep Awake window ignored the battery entirely.** `--keep-awake`, `MENUBAR_LOAD_RUNNER_KEEP_AWAKE`,
  and a restored window were all applied *before* battery monitoring started, so they armed against an
  unknown charge and spawned `caffeinate` even at a critical level, correcting only when the next
  power-source notification arrived — minutes, at a charge where minutes matter. Battery monitoring now
  starts first, and the initial reading applies conditions rather than merely recording them.

- **The Keep Awake countdown row is now readable by VoiceOver.** It set only `attributedTitle` (needed for
  the monospaced digits that stop the countdown twitching), which accessibility does not expose, so the
  row announced as empty. It now sets `title` as well.

- **The launcher's single-instance guard is now per-user.** It matched running instances with
  `pgrep -f`, which searches **every** user's processes, not the caller's. On a Mac with fast user
  switching that meant a second logged-in user's *first* launch was refused with "*An instance of
  MenuBarLoadRunner is already running (PID: …)*", naming a process inside another account's session —
  one they cannot see, click, or quit. Their only way in was `--extra`, whose help text says it launches
  a *second* instance when in fact they would be launching their first. The guard is now scoped with
  `pgrep -U "$(id -u)"`: its purpose is "don't stack instances in *my* menu bar", and a menu bar is
  per-session. `uninstall.sh` is scoped the same way, so uninstalling as one user no longer targets
  another user's running instance. Single-user Macs see no behavior change.

  Note that per-user *state* was already correct — the armed Keep Awake window, deadline, and track-line
  tint live in `~/Library/Application Support/`, so each account has always had its own. The *effect* of
  Keep Awake is inherently machine-wide: `caffeinate` holds the whole Mac awake, so the machine stays
  awake while any user holds a window.

### Added

- **`MENUBAR_LOAD_RUNNER_FORCE_BATTERY=<pct>[:battery|:ac]`** — a debug/QA hook that pins the
  power-source read, so the low-battery and critical-floor Keep Awake paths can be tested without
  draining a real battery, and on machines that have none. New `tests/qa.sh` §3a asserts the whole
  matrix by checking whether a `caffeinate` child bound to that run's PID exists.

### Changed

- **QA harness + docs.** `tests/qa.sh` §6 and the profiling recipes in `README.md` scope their
  `pgrep`/`pkill` to the calling user, matching the guard under test. `tests/install-smoke.sh`'s
  sandbox neutralizer now matches the whole `if pkill …` line instead of the substring `if pkill -f`,
  which the new `-U` flag would have silently broken — the smoke test would have run the real `pkill`
  against a live instance while still reporting all-pass. Harness/docs only; no app behavior change.

## [1.13.0] - 2026-07-26

### Added

- **Keep Awake survives a relaunch.** An armed window is saved to
  `~/Library/Application Support/menubar-load-runner/state.json` and resumed on the next launch, so a
  reboot in the middle of an overnight window no longer silently drops it. The *end instant* is what
  gets saved, not the length, so what comes back is the remainder — a window that elapsed while the
  app was down doesn't come back at all. The track-line color is restored too. A saved *indefinite*
  window is deliberately **not** restored: it has no stopping condition, and a stale flag keeping the
  Mac awake after every reboot is a worse failure than re-arming by hand. (No bundle id was needed for
  any of this — `UserDefaults` requires one, a file we open by path doesn't.)
- **`--keep-awake <off|on|duration>`** (also `MENUBAR_LOAD_RUNNER_KEEP_AWAKE`) arms Keep Awake at
  launch — `on` for no window, or a unit-suffixed duration (`30m`, `2h`, `1h30m`, up to 24h). A unit
  is required: a bare number is rejected rather than read as minutes-or-hours, where guessing wrong is
  a 60× error. Unrecognized values warn on stderr and launch with Keep Awake off instead of failing,
  since this can be baked into a login item
  (`./scripts/install-login-item.sh --keep-awake 4h`). Passing the flag — including
  `--keep-awake off` — overrides the persisted window. This is launch-time arming only: the launcher's
  singleton means it cannot re-arm an instance that is already running.

### Notes

- The state file is a convenience, never a dependency: if it's missing, unreadable, unwritable, or
  corrupt, the app launches normally with Keep Awake off. No alert, no startup error.

## [1.12.0] - 2026-07-25

### Added

- **Keep Awake: timed release.** The `Keep Awake` submenu gained a `Duration` radio group — `Until
  turned off` (the previous, still-default behavior), `30 minutes`, `1 hour`, `2 hours`, `4 hours`,
  `8 hours`, and `Custom…` (hours + minutes, up to 24h). Picking a duration engages Keep Awake, so
  arming a window is a single click. It reads as a real countdown, not a chosen duration: the
  `Keep Awake` row shows `Keep Awake: 29:24` and the submenu shows `29:24 left (until 8:18 PM)` —
  seconds resolution plus the wall-clock end time, ticking once a second while the menu is open (a 1s
  ticker that exists only for the open menu; the countdown isn't visible otherwise). The release
  itself is `caffeinate -t <seconds>`, so the assertion drops
  and the Mac may sleep exactly when the window ends, with no timer of the app's own. An intentional
  `Off` (or a battery-low/thermal suspend) is distinguished from a window elapsing, so a suspend still
  preserves your intent and a resume re-spawns with the *remaining* time rather than the full window.

## [1.11.2] - 2026-07-24

Bugfix: **the adjacent value label no longer disappears behind a wide GIF.**

### Fixed

- **Menu-bar label stays visible with wide presets.** The optional value/custom label
  (`--label value` / `--label <text>`) is a second `NSStatusItem`, and macOS orders status items by
  the time each becomes *visible* (oldest = rightmost) with no API to reorder. The label item used to
  be created lazily *after* the animation item, so it landed to the animation's **left** — the first
  slot macOS hides when the menu bar runs out of room. A wide, high-aspect preset (e.g.
  `totoro-group-white`, aspect ≈ 4.8) widened the animation item enough to push the label off/under
  the notch, so the reading vanished. The label item is now created **once, up front, before the
  animation item, and kept permanently visible** (width `0` when off — no clickable gap — and
  `variableLength` when on), pinning it to the **right** of the animation, adjacent to the system
  icons. A wide GIF now gets clipped near the notch before the number does. Affects every load source
  (CPU / Memory / GPU / Network / Disk / Fan / Battery). No CLI/env/behavior change.

Bugfix: **Keep Awake now actually keeps the Mac awake.**

### Fixed

- **Keep Awake no longer lets the system sleep.** The `caffeinate` child is now spawned with `-di`
  (prevent both **d**isplay and **i**dle system sleep) instead of `-i` (idle only). On modern macOS
  — notably Apple Silicon — an idle-only assertion is unreliable: once the display sleeps the system
  frequently follows it down, so the Mac slept even with Keep Awake enabled and `caffeinate` running.
  Preventing display sleep too is what reliably holds the machine awake. This matches
  [KeepingYouAwake](https://github.com/newmarcel/KeepingYouAwake)'s default. Battery-low and
  serious/critical-thermal auto-disengage are unchanged (the battery-low guard now matters a bit more
  since the display is held on). Menu-only; no CLI/env change.

## [1.11.0] - 2026-07-16

Keep Awake menu is now a single control with an expanded, restraint-first color palette.

### Added

- **Three new Keep Awake track-line tints**, alongside the existing Dusty Teal and Sand:
  **Graphite** (near-neutral cool gray), **Mauve** (desaturated lavender), and **Sage** (a muted
  green, pitched distinctly greener than Dusty Teal's cyan lean so the two read apart). All follow
  the same heavily desaturated, two-tone formula — a lighter shade on a dark menu bar, a deeper one
  on a light bar — so each holds its identity across appearance.

### Changed

- **Keep Awake and Keep Awake Color merged into one `Keep Awake` submenu.** Where there were two
  top-level items (an on/off checkbox plus a separate color submenu), there is now a single
  **Keep Awake ▸** submenu holding one radio group: **Off** plus a row per color. Picking a color
  turns keep-awake on with that tint; **Off** turns it off — so the enabled state and the tint are a
  single choice. This is an observable menu-structure change; the behavior (idle-sleep inhibition via
  `caffeinate`, auto-disengage, session-only intent) is unchanged. Menu-only, as before — no CLI/env.

## [1.10.1] - 2026-07-16

Documentation and distribution-tooling release — no changes to the app binary or its public API.

### Changed

- **Installer hardening.** `install.sh` now runs its whole body from a `main()` invoked on the
  last line, so a truncated `curl | bash` download can't execute a partial install. `uninstall.sh`
  now defaults to *keeping* the install directory unless deletion is explicitly consented to
  (`--yes`, or an interactive `y/N`); a non-interactive run without `--yes` no longer silently
  `rm -rf`s it.
- **Docs.** Added a factual "How it compares" feature matrix to the README (feature presence vs.
  `menubar_runcat` / `zoomies` / `stats`; no performance claims). The deep source-anchored design
  document and the competitor-analysis research doc were moved out of the public repo, and the
  remaining public surfaces (README, RUNBOOK, `CLAUDE.md`) were made self-contained.

### Fixed

- **QA harness (§6).** The launcher/singleton check no longer reports a false failure under
  `set -o pipefail`: the second launch's output is captured and matched without a pipe (avoiding
  the launcher taking `SIGPIPE` when `grep` closes early), and it polls for the victim instance to
  register instead of a fixed `sleep`. Harness-only — the singleton behavior was never broken.

## [1.10.0] - 2026-07-15

### Added

- **Battery load source.** A seventh reader — `--load-source battery` (or
  `MENUBAR_LOAD_RUNNER_LOAD_SOURCE=battery`) — drives the animation from the battery's discharge
  current (a fast drain animates faster; on AC power the draw is zero, so it idles), and the menu
  shows the live charge level. Reads unprivileged IOKit Power Sources; unavailable on desktop Macs
  with no battery, which fall back to `cpu`. The trace chart plots charge as an inverted fuel gauge
  (low reads red).
- **"Other Sources" multi-source dashboard.** A collapsible section in the status menu lists every
  *other* available reader (CPU / Memory / GPU / Network / Disk / Fan / Battery, minus the active
  one) with its live readout; click a row to switch the driving source. Expanding samples every
  reader each tick; collapsed (the default) keeps the existing active-only sampling. Launch expanded
  with the new `--show-all-sources` flag or `MENUBAR_LOAD_RUNNER_SHOW_ALL=1`.
- **Adjacent live-value label (`--label`).** An optional second menu-bar slot beside the animation,
  switchable at runtime (Off / Live Value / Custom Text). `--label value` shows the active source's
  compact reading (`CPU 15%`, `MEM 63%`, `BAT 88%`, …) refreshed on the 2s tick; `--label <text>`
  shows a fixed label (up to 24 chars, handy for disambiguating multiple instances); `--label off`
  (default) claims no space. Also via `MENUBAR_LOAD_RUNNER_LABEL`. Rendered as a separate
  `NSStatusItem` in the native menu-bar font, so it never touches the animation's frame pipeline.

### Changed

- **Selection marks in the menu** (Presets, Keep Awake, Keep Awake Color) now render as a small
  solid dot instead of the native checkmark — sized to the menu font so it matches the disclosure
  glyph. Presentational only.
- The former `Load Source` submenu is superseded by the inline "Other Sources" section above; the
  active source stays on top with the sparkline.

### Removed

- **`--overlay-text`** (and its baked-on-the-GIF text overlay) is replaced by the adjacent
  `--label` slot above. Baking live text onto the ~22 pt animated icon was barely legible and
  re-rasterized every frame on each update; the separate label slot stays crisp and is free to
  update.

## [1.9.1] - 2026-07-15

### Changed

- **Internal: centralized menu-item title strings.** Every fixed `NSMenuItem` label and every label
  *prefix* rebuilt by a refresh function now lives in a single `MenuTitle` namespace (sibling to
  `Tuning`) instead of being inlined at both the item's creation site and its refresh site. This
  removes a class of latent drift where a placeholder and its live value could disagree — two lines
  already did: `CPU Usage` (placeholder `CPU Usage:` vs. refresh `CPU Usage (smoothed):`) and
  `Speed Multiplier` (placeholder `Speed Multiplier:` vs. refresh `Speed Multiplier (auto:…)` /
  `(fixed)`). Pure refactor: every menu title renders byte-for-byte identical; no CLI, env, preset,
  or observable-behavior change. (Internal implementation detail, not part of the public API.)

## [1.9.0] - 2026-07-15

### Added

- **`Keep Awake Color` submenu.** The bottom track line shown while Keep Awake is holding the Mac
  awake now has a selectable tint: **Dusty Teal** (the default) or **Sand**. Each option carries two
  tones — lighter on a dark menu bar, deeper on a light one — chosen per menu-bar appearance so the
  2 pt line keeps its contrast across theme switches. Dusty Teal is chromatic (reads on the grayscale
  preset art by hue), Sand is a warm near-neutral companion. Menu-only, session-lived like the
  `Keep Awake` toggle itself (no CLI flag or env var); the line's color is never the system accent, so
  it won't collide with other menu-bar glyphs. Modeled as a `KeepAwakeColor` registry wired like
  `Load Source` (`selectKeepAwakeColor` / `refreshKeepAwakeColorSelectionState`).

## [1.8.0] - 2026-07-15

### Added

- **`Keep Awake` menu checkbox.** Keeps the Mac awake while the app runs by spawning
  `caffeinate -i -w <pid>` — idle-sleep only (the display may still sleep), bound to the app's PID so
  the OS reaps it automatically on crash/force-quit (no orphaned sleep lock). No second utility
  (KeepingYouAwake, Amphetamine) needed just to stop a Mac napping mid-compile/-train/-download.
  Owned by the new `SleepPreventer` class, which separates *intent* (`isEnabled`, the toggle) from
  *running state* (the process, which conditions may suspend and respawn without losing intent).
  - **Auto-disengage** on critically low battery (≤ 20% on battery power) or serious/critical thermal
    state, re-engaging when the condition clears — so an unattended Mac doesn't drain to death and a
    hot Mac isn't kept fighting sleep. Deliberately *not* triggered by lid/display sleep (idle-sleep
    prevention intentionally allows the display to sleep), memory pressure, or Low Power Mode.
    Battery is read via an event-driven IOKit Power Sources run-loop source (desktop Macs with no
    battery skip it entirely); thermal reuses the existing `ProcessInfo.thermalState` observer.
  - A thin **Dusty Teal** track line along the icon's bottom edge shows while it's *actively* keeping
    the Mac awake (keyed on running state, so it hides while a condition has it suspended). It's a
    sibling overlay `CALayer`, never composited into the rendered frames — a toggle costs no
    re-rasterization.
  - Intent is memory-only: the toggle resets to off on launch. Auto-restore across launches and an
    activate/deactivate notification are deferred.

## [1.7.1] - 2026-07-10

### Changed

- **Right-sized the chihiro and dog preset GIFs for menu-bar rendering.** Both were stored far larger
  than the ~40px-tall menu-bar render size, so the load-time decode pass (which reads every frame at
  full resolution to compute the shared alpha bounding box before downsampling) spiked memory on launch
  and on preset switch. chihiro `293×621 → 147×311` (color file 474 KB → 196 KB); dog `466×220 → 300×142`.
  Load-peak footprint drops from ~24 MB (chihiro) / ~14 MB (dog) to a flat ~10 MB baseline shared by
  every preset — bar a ~2 MB residual on chihiro's 21 tall frames. Frame count, per-frame delays, and
  the infinite-loop flag are preserved, and sources stay above the ~120px downsample threshold so edges
  still anti-alias with no visible quality change. Steady-state memory and per-frame CPU are unchanged.
  Assets only — no CLI, env, or observable-behavior change.

## [1.7.0] - 2026-07-10

### Changed

- **Menu-bar animation now drives a dedicated `CALayer`'s `contents` instead of the status
  button's image.** Previously each GIF frame called `-[NSStatusBarButton setImage:]`, which made
  AppKit re-run `NSStatusItem._adjustLength` and a full Auto Layout constraint solve *every frame* —
  redundant work, since the item width is fixed and GIF-derived. Frames are now pre-rasterized once to
  `CGImage`s at the display's backing scale and swapped onto a layer-backed subview pinned over the
  button, so the per-frame cost is a GPU-side pointer swap with no layout, draw, or constraint pass.
  Steady-state CPU drops from ~2.8% to ~0.4% of one core (≈6–7×), verified with `sample`/`top`: the
  entire `setImage:`→`_adjustLength`→`NSISEngine` cascade is gone from the profile, while CoreAnimation
  still composites the frame `CGImage` each cycle. Purely internal — no CLI, env, or observable-behavior
  change (see the Public API note above).

## [1.6.1] - 2026-07-10

### Added

- **In-app update check + user-initiated self-update.** On launch (fail-silent, off the main thread)
  and via a new **Check for Updates…** menu item, the app reads the git origin's release tags
  (`git ls-remote --tags`) and compares the highest to the running version. When a newer release
  exists it shows an **Update available: vX.Y.Z** item. Applying is always a deliberate two-step user
  action — click the item, confirm the dialog — after which it runs `git pull --ff-only` (never
  `--force`/`reset`; a dirty/diverged checkout aborts cleanly with a *View Releases* escape hatch) and
  asks you to restart to load the new version. New flag `--no-update-check` and env
  `MENUBAR_LOAD_RUNNER_UPDATE_CHECK=0` disable it.
- **Asset attribution** section in the README for the bundled third-party preset GIFs — clarifies the
  MIT license covers the source code only, and provides a takedown path.
- **Executable QA harness** in `tests/` (`qa.sh`, `install-smoke.sh`, `readers.swift`, `scaler.swift`,
  `semver.swift`) — the runnable form of `docs/RUNBOOK-qa-release.md` §1–6 (previously copy-paste blocks).

### Changed

- **About panel** reworked to a standard macOS About layout: a *name + version* title, the tagline,
  the live speed mode, a `© 2026 Bin Le · MIT License` line, a third-party-artwork attribution note,
  and a **View on GitHub** button.

## [1.6.0] - 2026-07-10

### Added

- **Open-sourced under the MIT License** (`LICENSE.md`) — covers the source code only.
- **One-line installer** (`install.sh`) and matching **`uninstall.sh`**. `install.sh` is a
  gitlogue-style `curl | bash` installer adapted for this source-based app: it preflights macOS +
  the Xcode Command Line Tools (`git`/`swiftc`), clones the repo to
  `~/.local/share/menubar-load-runner` (updating in place on re-run), compiles the binary, symlinks
  the launcher onto `PATH` at `~/.local/bin/menubar-load-runner`, and optionally sets up
  start-at-login (interactive `[y/N]` prompt, or `--login`). `uninstall.sh` reverses it — removes the
  LaunchAgent, the PATH symlink, and the install dir — touching only what the installer created. No
  Apple signing, notarization, or Homebrew required. See the README "Install" section.

### Removed

- **Width customization** — the `--width` / `-w` CLI flag and the `Width Options` menu submenu
  (`auto` / `1` / `2` / `3` / `4` slots) are gone, along with the per-preset `slotScale` field in
  `gifs/presets.json`. The menu-bar item width is no longer user-configurable. **Breaking:** an
  invocation or baked login-item arg that passes `--width <n>` now fails to launch (unknown
  argument); remove it. A read-only `Width` line remains in the menu (see below).

### Changed

- **Width is now GIF-based.** The menu-bar item sizes itself directly to the loaded GIF's aspect
  ratio at menu-bar height (width = height × aspect, clamped to `Tuning.maxIconAspect` and floored
  at `Tuning.minBaseSlotWidth`), instead of a hand-tuned per-preset slot count. A wide GIF gets a
  wide item; a tall/narrow one gets a narrow item. The `Width` menu line is read-only and reports
  the resulting width in points plus the GIF aspect ratio.
- **Overlay char limit is adaptive to the item width.** The interactive `Set Text...` prompt (and
  its menu title) now cap input at roughly how many monospaced glyphs fit across the current
  GIF-derived width — from `Tuning.overlayMinChars` (1) up to the `Tuning.overlayMaxChars` (12)
  ceiling — so a narrow GIF allows fewer characters than a wide one. The `--overlay-text` CLI flag
  still validates against the absolute 12-char ceiling, since the GIF width isn't known at parse
  time; rendering truncates as a backstop either way.
- Overlay menu tidy-up: dropped the separate read-only `Overlay Text: …` status line; the current
  overlay state (text + style, or `off`) is now shown directly on the `Overlay Text` submenu
  parent item, so one line does the job of two.
- Self-throttle status line now names the specific active cause instead of the generic
  `Throttled: low power/thermal` tag, and reserves the word "throttling" for the one condition
  where macOS actually throttles the hardware. The line reads `Slowing animation — <cause(s)>`
  where each cause is one of **thermal throttling** (macOS is clocking the CPU/GPU down —
  `thermalState` `.serious`/`.critical`), **Low Power Mode** (a user-chosen power policy), or
  **memory pressure** (memory reclamation — compression/swap/jetsam, not compute throttling).
  Multiple simultaneous causes are joined into the one line. All three still slow the app's own
  animation (the intent is unchanged — reduce this app's footprint when the machine is strained);
  only the wording is corrected so low power and memory pressure are no longer mislabeled as
  throttling. Detection and the menu wording now share one source of truth (`loadReductionReasons`).

## [1.5.1] - 2026-07-10

### Fixed

- `Speed Multiplier` menu line: dropped the preset's speed-profile label and min/max range from
  the auto-mode title — the label just restated the preset name (already visible from the checked
  item in the `Presets` submenu) and the range was tuning-internal detail, not something a user
  acts on. The line now reads `Speed Multiplier (auto: <source>): <value>x`. The
  low-power/thermal/memory-pressure throttle notice, previously appended inline (making the item
  even wider exactly when it was already busiest), is now its own `Throttled: low power/thermal`
  menu line that's hidden unless the cap is active.

## [1.5.0] - 2026-07-09

### Changed

- **Memory** load source: the used-fraction term now has an idle floor (`Tuning.memoryIdleFloor`,
  0.55) subtracted and the remainder rescaled to 0…1 before it drives the animation. macOS keeps
  most physical RAM resident as cache/wired, so a healthy Mac idles high (often 0.8–0.9 used); the
  previous linear map from the raw fraction drove the animation well up its speed range at rest.
  With the floor, an idle machine reads ~0 and the preset's full min..max range maps onto the
  fraction's real operating band. The swap-rate term is unchanged (already 0-based via the adaptive
  scaler) and is still max'd in un-floored, so active paging drives full speed regardless. The
  Memory menu line still shows the **raw** used-fraction — only the speed driver is floored. Affects
  `--load-source memory` only; CPU (the default) and the other 0-idle sources are unchanged.

## [1.4.0] - 2026-07-09

### Changed

- **Network**, **Disk**, and **Fan** load sources now report each axis separately and drive the
  animation from the *average* of those axes rather than a single combined figure. A one-directional
  transfer or a single spun-up fan no longer counts the same as balanced activity, and the status
  menu surfaces the breakdown:
  - **Network** tracks inbound and outbound throughput independently — the readout shows
    `↓X MB/s ↑Y MB/s` and speed follows the average of the two (previously a single summed rx+tx
    total).
  - **Disk** tracks read and write throughput independently — the readout shows
    `read X MB/s write Y MB/s` and speed follows their average (previously a summed total).
  - **Fan** reports every fan's RPM and utilization as one `Fan N: NNNN RPM (NN%)` segment per fan,
    and speed follows the average utilization across fans (previously the max across fans, so one
    ramped fan dominated).

### Fixed

- Frame registration: `loadFrames` previously cropped each GIF frame to its **own** independent
  alpha bounding box, so a preset whose limb extent varies frame to frame (a running or walking
  gait) rendered at a different size on different frames — visible as the whole menu-bar icon
  resizing/wobbling as it animated. Measured up to a 55% frame-to-frame aspect-ratio swing on the
  `chihiro` preset and 40% on `dog-white`/`dog-black`. Frames are now cropped to one shared
  bounding box — the union of every frame's own alpha extent — so the icon's rendered size is
  constant across a preset's whole animation; only the artwork inside it moves.

## [1.3.0] - 2026-07-09

### Added

- New **`fan`** load source — drives the animation from fan speed as a thermal/cooling signal.
  Reads per-fan tachometers from the SMC (`AppleSMCKeysEndpoint`) unprivileged and read-only
  (never touches fan-control keys), normalizing current RPM as a fraction of the fan's max (max
  across fans). It's a lagging signal that trails actual work and only ramps under sustained
  thermal load; idle fans keep some visible motion, and a genuinely stopped fan still crawls at
  the preset's minimum speed rather than freezing. Fanless Macs (e.g. MacBook Air, which report
  `FNum == 0`) have the source unavailable — it's disabled in the `Load Source` menu and a launch
  request falls back to `cpu`, matching the gpu/disk availability contract. Selectable via
  `--load-source fan`, `MENUBAR_LOAD_RUNNER_LOAD_SOURCE=fan`, or the `Load Source` menu, and
  honors `MENUBAR_LOAD_RUNNER_FORCE_UNAVAILABLE=fan` for QA.

## [1.2.2] - 2026-07-09

### Changed

- Dog preset (`dog-white` / `dog-black`) re-rendered by **vector-tracing** the silhouette with
  `potrace` instead of raster upscaling. Each frame's alpha mask is preprocessed (`mkbitmap`) and
  traced to resolution-independent Bézier curves, then rasterized at 466×220, so the menu bar
  downsamples clean curves rather than a fixed 72×34 pixel staircase — edges now read as smooth as
  the horse preset. The stylistic ground/motion streak under the paws was removed (banded
  morphological opening) so the dog floats like the other silhouettes. 12 frames, delay 3, infinite
  loop, transparent background unchanged; no keyword, timing, or manifest change.

### Added

- CLI forgiveness for common argument mix-ups — neither now triggers the fatal startup error box:
  - A load-source keyword (`cpu` / `memory` / `gpu` / `network` / `disk`) given in the **positional**
    (preset) slot is interpreted as `--load-source` and the default preset is used, with a stderr
    note. An explicit `--load-source` always wins (the positional is then ignored).
  - An unknown positional **bareword** (not a known preset keyword and not an existing file) falls
    back to the default preset with a stderr warning. An explicit GIF **path** (contains `/` or ends
    `.gif`) that doesn't exist still fails fast with the fatal "GIF file not found" — the QA §4a
    contract is preserved, since naming a specific missing file is worth surfacing.
- README "The menu (live dashboard)" section documenting the status-item menu's trace chart and
  numeric readouts.

## [1.2.1] - 2026-07-09

### Changed

- Dog preset (`dog-white` / `dog-black`) art re-rendered from a higher-resolution source so the menu
  bar downsamples it instead of upscaling — edges are smoother rather than blocky. GIF stores only
  1-bit transparency, so a preset looks crisp only when its source out-resolves the ~40 px render
  height; the dog was 72×34 (below it) and is now 288×136. No keyword, timing, or manifest change.

### Added

- `docs/cover.html` — design/marketing cover page for the project.
- `docs/RUNBOOK-pages-publish.md` — runbook to build the cover bundle and deploy it to Cloudflare
  Pages via `wrangler` direct upload.
- `.claude/skills/build-visuals/` — reusable skill + scripts for smoothing preset GIFs and generating
  white/black silhouette variants.

## [1.2.0] - 2026-07-07

### Added

- Chihiro walking presets: `chihiro` (full-color walk cycle), `chihiro-white`, and `chihiro-black`
  silhouettes (293×621, 21 frames, shared "chihiro" speed profile). Wired through `gifs/presets.json`,
  the launcher help, and README.

## [1.1.3] - 2026-07-07

### Fixed

- About dialog: the auto-speed line was hardcoded to "CPU load"; it now names the active load source
  (e.g. "Speed adapts to GPU load …"), matching the Speed Multiplier menu line.
- About/alert icon: the horse art (~3:2) was squished into a 48×48 square and rasterized at 1× with
  default interpolation. It is now aspect-fit and centered, backed at the display (Retina) scale, and
  drawn with high interpolation — smooth, with correct proportions.
- Resource resolution hardened: `gifs/` and `presets.json` are now located relative to the running
  executable (falling back to `#filePath` for the interpreted `swift <file>` dev path) rather than
  `#filePath` alone. A binary compiled with a relative source path and run under `launchd` (working
  directory `/`) previously resolved the manifest to `/gifs/presets.json` and failed at startup; the
  new anchor is independent of both the working directory and the compile-time path.

## [1.1.2] - 2026-07-07

### Changed

- Documentation only: split the login-item docs to match the repo convention (README = usage,
  the internal design doc = source-anchored mechanism). The README "Start at login" section is
  trimmed to install/uninstall usage; the full LaunchAgent mechanics — `--no-detach` supervision,
  `RunAtLoad` timing, the `bootout` reload race, and Background Task Management ("Allow in the
  Background") behavior — live in the internal design doc.

## [1.1.1] - 2026-07-07

### Fixed

- `scripts/install-login-item.sh` re-install (running install while already installed, e.g. to
  change the baked-in preset / `--load-source` args) failed with launchctl error 5 ("Input/output
  error"). `launchctl bootout` is asynchronous, so the follow-up `bootstrap` raced the still-tearing-
  down service. Install now polls until the old service is fully gone before re-`bootstrap`. First
  install and uninstall were unaffected.

## [1.1.0] - 2026-07-07

### Added

- Optional start-at-login support for personal use, via two scripts:
  `scripts/install-login-item.sh` and `scripts/uninstall-login-item.sh`. Install registers a
  per-user LaunchAgent (`~/Library/LaunchAgents/ai.bera.menubarloadrunner.plist`) that runs the
  launcher with `--no-detach` so `launchd` supervises the process; it starts immediately and on
  every login, and passes through any launcher args (preset keyword, `--load-source`, etc.).
- Fully reversible uninstall: the LaunchAgent is deregistered (`launchctl bootout`) and its plist +
  log deleted, leaving no residue (no root writes, no receipts database, no Background Task
  Management entry). Documented under "Start at login" in the README.

### Notes

- No `.app` bundle, `.dmg`, `.pkg`, or code signing is involved — this is the minimal, low-footprint
  auto-start path for a personal single-machine setup. Distribution to other Macs would still call
  for a signed/notarized bundle (out of scope for this release).

## [1.0.0] - 2026-07-07

Initial stable release.

### Added

- Native macOS menu bar app (Swift + AppKit, single source file, no Xcode project) that renders an
  animated GIF as the image of one `NSStatusItem`.
- Automatic animation-speed adaptation to a selectable system load source, sampled every 2 s. All
  readers are unprivileged (no `sudo`), and the app only ever *reads* system state:
  - `cpu` (default) — EMA-smoothed CPU usage across all cores.
  - `memory` — memory-in-use composited with the swap-paging rate.
  - `gpu` — GPU device utilization.
  - `network` — total interface throughput (rx + tx, loopback excluded).
  - `disk` — total block-device throughput (read + write across all drives).
  Selectable via `--load-source`, `MENUBAR_LOAD_RUNNER_LOAD_SOURCE`, or the live `Load Source` menu;
  sources with no readable hardware are disabled and fall back to `cpu`.
- btop-style adaptive auto-scaling for the unbounded throughput sources (network / disk / swap
  rate): bytes-per-second are normalized to 0..1 against an adaptive, hysteresis-guarded ceiling
  that calibrates to recent activity on the machine.
- Nine built-in presets (dog, horse, and Totoro variants) whose profiles — keyword, menu title, GIF
  file, slot width, speed range, and the default preset — are externalized to `gifs/presets.json`.
  Presets can be added or tweaked by editing the manifest, with no Swift change.
- Custom GIF playback via a positional path argument or `MENUBAR_LOAD_RUNNER_PATH`.
- Fixed-speed override (`--speed-multiplier`) that disables load adaptation.
- Menu-bar width control in slots (`--width 1..4`), clamped to each preset's minimum width.
- Runtime text overlay baked onto each rendered frame (`--overlay-text`, up to 12 characters, with a
  bold toggle) without modifying the GIF file.
- Live status menu: the active source's metric and state line, load averages (1 / 5 / 15 m), speed
  multiplier, and radio selectors for load source, width, overlay text, and preset — plus About and
  Exit.
- Self-throttling: the app caps its *own* animation speed under Low Power Mode, thermal state
  `serious` / `critical`, or memory pressure `warning` / `critical`, so the indicator adds as little
  as possible to the load it visualizes.
- Full animation pause when the status item is occluded (notch/overflow, another Space, display
  off), driven by occlusion notifications.
- `CADisplayLink`-driven, vsync-aligned game loop on macOS 14+, with a 60 Hz `Timer` fallback on
  older systems; large inter-tick gaps (sleep, clock jump) resync instead of replaying every frame.
- zsh launcher with compile-on-change (`swiftc -O -strict-concurrency=complete`, interpreted `swift`
  fallback), singleton enforcement (`--extra` to allow an extra instance), and detached-by-default
  launch with logging (`--foreground` / `--no-detach` / `--detach`, `MENUBAR_LOAD_RUNNER_LOG_FILE`).
- Debug / QA hooks: `MENUBAR_LOAD_RUNNER_EXIT_AFTER` (self-terminate after N seconds) and
  `MENUBAR_LOAD_RUNNER_FORCE_UNAVAILABLE` (force a load source unavailable).
- In-app version string, shown in the About dialog and `--help`.
- Documentation: `README.md`, `docs/RUNBOOK-qa-release.md` (release QA gate), and `CLAUDE.md`.

### Engineering notes

- Built warning-clean under `-strict-concurrency=complete`; both classes are `@MainActor`-isolated.
- Startup errors (including a missing or invalid `gifs/presets.json`) surface as an alert and quit
  cleanly, rather than calling `fatalError`.
