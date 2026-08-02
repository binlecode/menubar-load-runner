# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.
`AGENTS.md` is the **canonical agent-instruction file for every tool** (the cross-tool standard read by
Codex, Copilot, Cursor, etc.) and `CLAUDE.md` is a symlink to it, so edit `AGENTS.md` only — never
duplicate rules into the other name. Keep it lean and high-SNR; specialized or verbose rules live in
`docs/` or `.claude/` with a one-line pointer here.

## What this is

A single-file native macOS menu bar app (Swift + AppKit, no Xcode project/SwiftPM package) that renders an
animated GIF in the status bar. Animation speed adapts automatically to system CPU load. No build system
beyond `swiftc`/`swift` invoked directly, and no unit-test framework.

## Testing rules

**Every test drives the real binary and asserts a real side effect.** `tests/qa.sh` is the harness; there
is no unit-test tier and adding one is a regression, not an improvement.

- **Never re-port app logic into a test.** Five probes (`readers`/`scaler`/`label`/`semver`/`restart`.swift)
  did exactly that — each copied a type out of `MenuBarLoadRunner.swift` and asserted against the copy,
  under a header saying "keep in sync with the real type". That gets the failure mode backwards: the copy
  passes while the app is broken, and the check that was supposed to protect the behavior only ever
  protected the transcription. **Deleted 2026-07-30.** A `private` type you can't reach from a test is a
  signal to assert its *effect*, not to duplicate it.
- **No mocks, no injection hooks for behavior.** Real `caffeinate`, real assertions
  (`tests/hold-assertion.swift` holds one), real status item. The only sanctioned hooks make the real thing
  *observable* or *bounded* — `MENUBAR_LOAD_RUNNER_LOG_*` (read state a shell can't otherwise see, since
  `screencapture` needs Screen Recording and AppleScript needs Accessibility, and an agent has neither),
  `EXIT_AFTER`, `STATE_FILE`, and `FORCE_BATTERY` (pins a reading that is otherwise unreachable on a
  desktop). Adding a hook that *changes a decision* is mocking with extra steps.
- **When the environment can't answer, report `NOTE`, never a false `PASS` or `FAIL`.** A machine's own
  sleep assertions, menu-bar crowding and battery are not the test's to control. §3c and §3e both do this;
  copy that shape rather than loosening the assertion until it passes.
- **What has no functional check gets recorded as verification debt in `docs/ROADMAP.md`** — never left
  looking covered. That table is the honest inventory; a deleted test that took real coverage with it must
  appear there the same day.

## Documentation

`docs/` holds SDLC documents. This `CLAUDE.md` stays focused on build/run commands and the architecture
map; **rationale does not live here** — when a section starts arguing, move the argument to the internal
`DESIGN-system.md` and leave behind only what an implementer must not break. The layout:

| Path | What | Naming |
|---|---|---|
| `docs/ROADMAP.md` | the standing tracker (see below) | — |
| `docs/RUNBOOK-<topic>.md` | operational procedures (QA/release, publishing) | no timestamp |
| `docs/TODO-<YYYYMMDD-HHMM>-<slug>.md` | one item being actively worked | timestamped |
| `docs/design-docs/` | **symlink into the private vault.** `DESIGN-system.md` is the canonical design record — invariants, rejected alternatives, probe facts, per-release verification. Also strategy + competitor research. Gitignored, **never committed**: the public repo carries only README / RUNBOOK / this file | — |
| `docs/cover.html`, `docs/media/` | the landing page and its assets | — |

`tmp/` is **scratch only, and gitignored** — treat everything in it as deletable at any moment. Nothing
durable may live there: not the source of a tracked asset, not a test whose coverage exists nowhere else,
not writing you'd mind losing. This has bitten twice: a `build_cover.py` + template pair sat in `tmp/`
looking like the cover's source long after `docs/cover.html` outgrew it (running it would have reverted the
cover ten versions), and launch copy accumulated there instead of the vault. If a scratch file turns out to
matter, promote it — tracked `tests/`/`scripts/` for tooling, `docs/` for SDLC, the vault for strategy
and marketing — and delete the scratch copy so there is one source of truth.

`docs/ROADMAP.md` is the **standing** tracker: every open item, declined proposal, known limit, and
verification gap, each with a stable `R<n>` ID. Check it before proposing work — an idea may already be
there as declined-with-a-reason or as a candidate whose design question is unsettled. Keep it at
tracking altitude (what, priority, blocker, status); it is deliberately not a design-rationale
document, and a `TODO-*.md` is for actively working one item, not for holding the backlog.

A TODO's timestamp is when the file was created, so filenames sort chronologically without a separate
changelog. When a TODO closes, its durable outcome moves into the internal `DESIGN-system.md` (and its ROADMAP
row is retired) and **the file is deleted** — see the git history for the pattern. That design doc is where
an implementer looks *before* changing a subsystem; a TODO is scaffolding and should not outlive the work.

## Commands

Run from the repository root:

```bash
./menubar-load-runner                       # default preset (horse-white), detached
./menubar-load-runner --foreground           # run attached to the current shell (see stderr/output directly)
./menubar-load-runner dog-black --label value   # adjacent slot shows the live source reading
./menubar-load-runner --help
```

- The launcher (`menubar-load-runner`, a zsh script) compiles `MenuBarLoadRunner.swift` with
  `swiftc -O -strict-concurrency=complete` into the `MenuBarLoadRunner` binary next to it, and only
  recompiles when the source is newer than the binary. If `swiftc` fails, it falls back to
  `swift <file>` (interpreted, no cached binary). The `-strict-concurrency=complete` flag opts into
  full data-race checking; the two classes are annotated `@MainActor`, so the build is warning-clean.
  It runs in Swift 5 mode, so any future concurrency violation surfaces as a warning, not a hard build
  break.
- There's no separate "build" step — editing `MenuBarLoadRunner.swift` and re-running `./menubar-load-runner`
  is the whole loop. To force a rebuild without relying on the mtime check:
  ```bash
  swiftc -O -strict-concurrency=complete MenuBarLoadRunner.swift -o MenuBarLoadRunner
  ```
- To check compile errors quickly without launching the app:
  ```bash
  swiftc -O -strict-concurrency=complete MenuBarLoadRunner.swift -o tmp/mblr-check
  ```
  Compile the **root** source — the output binary may live anywhere, but a copy of the source built
  from `tmp/` bakes `#filePath` into `tmp/`, so `gifs/presets.json` resolves to `tmp/gifs/` and the app
  dies at launch on a manifest error. That failure mode is silent to a test harness that only checks
  for a side effect (no caffeinate child reads as "correctly paused"), so build variant experiments
  with `ln -sfn ../gifs tmp/gifs` in place.
- To smoke-test at runtime, set `MENUBAR_LOAD_RUNNER_EXIT_AFTER=<seconds>` so the app self-terminates
  (exit 0) instead of blocking the AppKit run loop forever — no background/kill dance needed:
  ```bash
  MENUBAR_LOAD_RUNNER_EXIT_AFTER=5 ./tmp/mblr-check --load-source memory   # runs 5s, exits 0
  ```
  Prefer this (or `timeout 5 …`) over launch-then-`kill`. Note the raw binary bypasses the launcher's
  singleton, so stacked instances / a run wedged in a modal alert are what otherwise force a manual `pkill`.
  Pair it with `MENUBAR_LOAD_RUNNER_STATE_FILE=$PWD/tmp/state.json` for anything touching Keep Awake, so
  a test run can't read or clobber the real `~/Library/Application Support` state — and check for a
  leaked `caffeinate` by its `-w <pid>` signature, not by name (the developer's own running instance
  legitimately holds one).
- `MENUBAR_LOAD_RUNNER_FORCE_BATTERY=<pct>[:battery|:ac]` pins the power-source read (default `:battery`),
  so the low-battery and 5%-floor keep-awake paths are testable without draining a real battery — and on a
  desktop. Covered by `tests/qa.sh` §3a. This hook exists because the absence of it is *why* arming below
  20% stayed a silent no-op long enough to ship:
  ```bash
  MENUBAR_LOAD_RUNNER_FORCE_BATTERY=15:battery MENUBAR_LOAD_RUNNER_EXIT_AFTER=6 \
    ./tmp/mblr-check --keep-awake 30m     # expect: no caffeinate child, menu says paused
  ```
- `MENUBAR_LOAD_RUNNER_LOG_SLOTS=1` prints every status item's frame in **screen coordinates** each 2s
  tick, so slot order and slot stability become assertable instead of eyeball-only (`tests/qa.sh` §3c).
  This is the tool to reach for on any menu-bar layout question: a status item's button lives in its own
  window, and a process may always inspect its own windows, so unlike `screencapture` (needs Screen
  Recording) or `tests/menu-dump.applescript` (needs Accessibility) it works from any shell with **no TCC
  grant** — including an agent's, where both of those are denied. It is also how the 16pt cost of a
  `length = 0` item was measured. Assert on *relative* geometry: an unrelated menu-bar change shifts the
  whole group at once, which absolute x reads as jitter.
  ```bash
  MENUBAR_LOAD_RUNNER_LOG_SLOTS=1 MENUBAR_LOAD_RUNNER_EXIT_AFTER=9 \
    ./tmp/mblr-check --label value --load-source cpu 2>&1 | grep SLOTS
  # SLOTS icon[x=1089.0 w=47.0] left[x=994.0 w=95.0] right[x=1136.0 w=16.0] side=left label="CPU  11%"
  #        ^ left slot's maxX (994+95) == icon's minX → adjacent, and w=95 never changes
  ```
- `MENUBAR_LOAD_RUNNER_LOG_ASSERTIONS=1` prints the **filtered, post-hysteresis** other-sleep-assertions
  list each 2s tick, for the same no-TCC-grant reason as `LOG_SLOTS` (`tests/qa.sh` §3d). Pair it with
  `tests/hold-assertion.swift`, which holds a **real** assertion under a unique process name — the fixture
  exists because a `caffeinate` row proves nothing on a machine that already has a stray one. The line also
  reports `own=N` — how many assertions were dropped for being ours — which is the only race-free way to
  assert the app skipped its own child (`caffeinate -di` holds two, so an armed window reads `own=2`);
  comparing against a count taken from outside drifts mid-run on a machine with a renewal loop.
  ```bash
  swiftc -O tests/hold-assertion.swift -o tmp/mblr-assert-probe && tmp/mblr-assert-probe 6 &
  MENUBAR_LOAD_RUNNER_LOG_ASSERTIONS=1 MENUBAR_LOAD_RUNNER_EXIT_AFTER=6 ./tmp/mblr-check 2>&1 | grep ASSERTIONS
  # ASSERTIONS n=2 [caffeinate x3 PreventUserIdleSystemSleep] [mblr-assert-probe x1 PreventUserIdleSystemSleep]
  ```
  It takes `--display` and `--timeout <secs>` for the two axes the machine-state row reads.
- `MENUBAR_LOAD_RUNNER_LOG_AWAKE=1` prints the **derived** machine sleep-hold state each 2s tick plus the
  rendered row text verbatim, so `tests/qa.sh` §3e asserts the rendering, not just the booleans. Same
  no-TCC-grant reason as the two hooks above. Grepping trap: macOS separates a clock time from `AM`/`PM`
  with **U+202F** (`e2 80 af`) and the label pads with **U+2007** (`e2 80 87`) — ASCII-space patterns match
  nothing, and `/bin/bash` here is 3.2, so use `$'\xe2\x80\xaf'`, not `printf '\u202f'`.
  ```bash
  caffeinate -di -t 120 &                       # a foreign hold — the case that used to read Off
  MENUBAR_LOAD_RUNNER_LOG_AWAKE=1 MENUBAR_LOAD_RUNNER_EXIT_AFTER=5 ./tmp/mblr-check 2>&1 | grep AWAKE
  # AWAKE hold=foreign own=0 display=1 idle=1 owners=1 paused=0 tint=foreign row="Mac held awake — caffeinate · until 12:05 PM"
  # `tint` is the tone the line and the label actually wear, named by keepAwakeTint itself (R7).
  ```
- The launcher enforces a singleton via `pgrep -U "$(id -u)" -f "/MenuBarLoadRunner( |$)"` — only one
  instance **per user** runs unless `--extra` is passed. (The pattern matches the compiled binary path, not
  the process args, since args no longer carry a `.gif` path now that Swift resolves preset keywords. The
  `-U` scope is load-bearing: unscoped `pgrep -f` sees every account, so with fast user switching it refused
  a second user's *first* launch by naming a PID they can't see or kill. `uninstall.sh` and `tests/qa.sh`
  scope their `pgrep`/`pkill` the same way, for the same reason.) When iterating locally, stop any
  running instance first:
  ```bash
  pkill -f 'MenuBarLoadRunner'
  ```
- Detached runs log to `/tmp/menubar-load-runner.log` (override with `MENUBAR_LOAD_RUNNER_LOG_FILE`); use
  `--foreground` while developing so output goes straight to the terminal.
- The launcher exports `MENUBAR_LOAD_RUNNER_LAUNCHER` (its own symlink-resolved absolute path) and
  `MENUBAR_LOAD_RUNNER_LAUNCH_MODE` (`detached`/`attached`) purely so the app can restart itself after an
  update (see `Restarter` below). Keep them exported from **both** launch branches, and keep them derived
  from `resolve_script_path` — the PATH entry `install.sh` creates is a symlink whose *name* may differ, so
  the app must be handed the real file, not a name joined to the real dir.
- `MenuBarLoadRunner` (the compiled binary) is gitignored; `MenuBarLoadRunner.swift` is the only source of truth.

## Installer (`install.sh` — end-user install, already exists — do not rebuild)

`install.sh` at the repo root is the user-facing one-line installer (gitlogue-style curl|bash,
adapted for a *source-based* app — Homebrew/notarization are deferred, see Out of scope below). It
is intentionally MVP:

- Flow: preflight (macOS + `git`/`swiftc`, else `xcode-select --install`) → `git clone` into
  `~/.local/share/menubar-load-runner` (existing checkout → `git pull --ff-only`) → precompile
  (fail-fast; falls back to on-demand compile) → symlink launcher into `~/.local/bin` → optional
  `[y/N]` start-at-login prompt (via `/dev/tty`, so a piped `curl | bash` safely skips) → PATH hint.
- Env overrides: `MENUBAR_LOAD_RUNNER_HOME`, `BIN_DIR`, and `MENUBAR_LOAD_RUNNER_REPO_URL` (the last
  is test scaffolding — point it at a local clone to smoke-test into `./tmp/`). Flags: `--login`, `--help`.
- **Deliberately out of scope** (don't add without a reason — they were reviewed and cut as
  non-MVP): tag-pinning / `--ref` / `VERSION`, a Homebrew tap/formula, and a signed+notarized `.app`.
  It installs the latest default branch; power users `git checkout` a tag themselves.
- The installer *reuses* `scripts/install-login-item.sh` for start-at-login — it does not re-implement
  the LaunchAgent (see next section).
- `uninstall.sh` (repo root) reverses it: tears down the LaunchAgent (if enabled), stops any running
  instance, removes the `BIN_DIR` symlink (only if it points into the install dir), and removes the
  install dir (`[y/N]` confirm, `--yes` to skip; refuses/warns instead of deleting if the dir isn't
  its own git checkout).

## Start-at-login / LaunchAgent (already exists — do not rebuild)

Auto-start is **already implemented** as a per-user LaunchAgent; don't hand-roll a plist, `launchctl`
sequence, or `.app` bundle. Use the scripts:

```bash
./scripts/install-login-item.sh [preset] [flags]   # bake args, load + start now and at login
./scripts/uninstall-login-item.sh                  # deregister + delete plist and log
```

- Label `ai.bera.menubarloadrunner`; plist at `~/Library/LaunchAgents/`. No root, no signing.
- `ProgramArguments` = the **launcher script** + `--no-detach` (so `launchd` supervises the real
  process) + baked args. Because it runs the launcher (not a fixed binary), a source edit is picked up
  on the next agent start — restart with `launchctl kickstart -k "gui/$(id -u)/ai.bera.menubarloadrunner"`,
  no reinstall. Reinstall is **only** for changing baked args.
- `RunAtLoad`, no `KeepAlive` (menu **Exit** quits until next login). Shows under System Settings →
  Login Items → "Allow in the Background". One mechanic worth knowing: reinstall does
  `bootout` + `bootstrap`, and `bootout` completes asynchronously — the install script polls for
  deregistration before re-bootstrapping rather than sleeping a fixed interval.

## Architecture

Everything lives in `MenuBarLoadRunner.swift` (~5600 lines), organized top to bottom as:

- **`Tuning`** — every magic number (icon-aspect clamp, label char cap, alpha trim threshold,
  hysteresis, etc.) lives here. When adjusting behavior, change constants here rather than inlining new
  literals. **Exception:** per-preset speed ranges live in `gifs/presets.json` (see the
  preset-registry note below), not `Tuning`. Width is not tuned per-preset — it derives from each GIF's
  aspect ratio at runtime (`currentGifAspect`/`slotLength`).
- **`Config`** — CLI arg / env var parsing (`--speed-multiplier`, `--label`, `--keep-awake`,
  `--battery-threshold`, positional
  preset keyword or GIF path, `MENUBAR_LOAD_RUNNER_PATH` fallback). Values that can be baked into a
  login item are **clamped, never rejected** — a bad number must not cost the user the app — but a
  *shape* the parser can't read unambiguously is refused rather than guessed at: `--keep-awake`
  requires a unit, and `--battery-threshold` takes whole percents (`20`, `20%`) and refuses `0.20`,
  both because the wrong guess is an order-of-magnitude error the user can't see. The positional arg is captured verbatim as
  `presetOrPath`; when absent it is left empty and the app resolves the manifest's `defaultPreset`
  (`horse-white`). Keyword→path resolution
  happens in `MenuBarLoadRunnerApp.init` (matching `allPresets` by `key`, then by `path`), *not* in the shell
  launcher, which now forwards the arg unchanged.
- **`PersistedState` / `StateStore`** — the app's only on-disk state, a JSON file at
  `~/Library/Application Support/menubar-load-runner/state.json` (override with
  `MENUBAR_LOAD_RUNNER_STATE_FILE` — test scaffolding, point it under `tmp/`). Deliberately **not**
  `UserDefaults`: a bundle-less binary has no defaults domain, but a file opened by path needs no
  bundle — which is why the old "can't persist without a bundle id" comment was wrong. Every field is
  Optional so an older/newer file degrades instead of failing to decode, and both load and save are
  **fail-silent** (missing/corrupt/unwritable → defaults, never a startup error or a modal). Contrast
  `gifs/presets.json`, whose failure IS fatal — that's app identity, this is a convenience. Two blocks:
  `keepAwake` (intent — tint, deadline, enabled) and `settings` (menu-driven preferences that outlive a
  relaunch; today the menu-bar label's mode and side, and the Keep Awake battery release threshold, the
  last stored as a charge *fraction* — the unit the live property holds, not the whole percent the CLI
  takes).
  **`persistState()` is the only writer, and must stay the only one:** `StateStore.save()` replaces the
  whole file, so a block-specific writer would silently drop the block it doesn't own. It composes both
  blocks from live in-memory state, which also removes any read-modify-write window. Call it from the
  places *intent* changes (the tint/Off group, `armKeepAwake`, the window-expired callback,
  `setLabelMode`, termination) and never from `updateSleepPrevention()`, which fires on every
  thermal/battery/power event and would write disk for a change in *running* state.
  Launch precedence for a persisted setting mirrors Keep Awake's: `Config.label` is
  `MenuBarLabel?` where **nil (no flag/env) is distinct from `.off`** — absent restores the saved mode,
  an explicit `off` suppresses it — resolved in `applyLaunchLabelState()` before the first
  `applyLabelMode()`. An empty env value counts as absent, so `MENUBAR_LOAD_RUNNER_LABEL=` can't clobber
  a saved mode. Unlike a keep-awake window, *every* label mode is restorable: a label holds no assertion,
  so there's no runaway state to guard against. The label's **side** sits at the other end of that
  spectrum — no flag exists to defer to, so it restores unconditionally and independently of the mode,
  before the same `applyLabelMode()`. The battery threshold restores the same way
  (`applyLaunchBatteryThresholdState()`: flag/env → saved value → `batteryLowThresholdDefault`), with one
  asymmetry — `off` is a *value* (`0`), not a mode, so a flag can only override the saved setting, never
  read as absent. Every value restores, `off` most of all: dropping it would reinstate a release policy
  the user turned off. The state file is an untrusted entry point like any other, so the restored value
  goes through `Tuning.clampedBatteryThreshold` too.
- **`CPULoadMonitor`** — reads `host_processor_info`/`PROCESSOR_CPU_LOAD_INFO` via Mach APIs and exposes an
  EMA-smoothed CPU usage fraction (`Tuning.cpuSmoothingAlpha`). Requires two samples to produce a delta, so
  usage is nil until the second `sampleSystemLoad` tick.
- **`MemoryLoadMonitor`** — sibling reader, a *mixed domain*: an *instantaneous* memory used-fraction
  via `host_statistics64(HOST_VM_INFO64)` (a point read, no EMA, valid on the first sample) plus a
  *counter-delta* swap rate — `swapins`/`swapouts` from the same `vm_statistics64` read, differenced
  over the real elapsed wall time passed into `sampleUsage(elapsed:)` (so the rate warms up one tick,
  like the CPU reader). The driver value is `currentMemoryLoad = max(usedFraction, scaled(swapRate))`
  where the unbounded swap *rate* normalizes through a shared `ThroughputScaler` (see below), not a
  fixed reference; the menu still shows the raw used-fraction (+ swap capacity via
  `sysctlbyname("vm.swapusage")` and, when paging, the live MB/s rate). Same unprivileged Mach/sysctl
  tier as `CPULoadMonitor`. `nil` (never `0`) on failure. Used-fraction + composite formulas are
  documented in the class comment / `Tuning` (a deliberate approximation, not Activity Monitor's exact
  algorithm).
- **`GPULoadMonitor` / `NetworkLoadMonitor` / `DiskLoadMonitor` / `FanLoadMonitor` /
  `BatteryLoadMonitor` / `TemperatureLoadMonitor`** — the other six load-source readers, same unprivileged tier (IORegistry +
  `getifaddrs` + SMC + IOKit Power Sources; `import IOKit`, `import IOKit.ps`). GPU is an instantaneous
  0…1 point read (`IOAccelerator → PerformanceStatistics → "Device Utilization %"`); network
  (`getifaddrs → if_data`, AF_LINK, skip `lo0`) and disk (`IOBlockStorageDriver → Statistics → Bytes
  (Read)/(Write)`) are counter-deltas over `elapsed:`. Each has an `isAvailable` probe (`nil` reader →
  disabled menu item + launch fallback to `.cpu`).
  - **`SMCClient`** — the shared read-only client every SMC-backed source reads keys through, and the
    only place holding the *undocumented* 80-byte `SMCKeyData` layout (`AppleSMCKeysEndpoint`; never
    the root-only `F{n}Tg`/`F{n}Md` control keys). Three things are load-bearing. It is a **singleton
    (`SMCClient.shared`), and a second instance is the bug to avoid**: the file has no
    `IOServiceClose` and no `deinit` anywhere, so the `io_connect_t` is process-lifetime by design —
    fine for one, sloppy for two. The `MemoryLayout<SMCKeyData>.stride == 80` check in `ensureOpen()`
    is the availability gate for **every** SMC source at once, so a toolchain that lays the struct out
    differently disables them all rather than corrupting memory in any. And the three trailing pad
    bytes in `SMCKeyInfoData` are load-bearing — without them Swift packs `result` into the tail
    padding, the struct becomes 76 bytes, and the kernel call fails `kIOReturnBadArgument`. Reads
    (`readKeyInfo`/`readBytes`/`readFloat`/`floatKey`) return `nil`, never a fabricated `0`.
    `floatKeys(withPrefix:)` discovers a whole sensor family from the SMC's **own** key table (`#KEY`
    for the count, command `8` to read the key at an index) rather than probing a guessed candidate
    list — the key set varies by chip, so a guess can't tell "absent" from "didn't think of it". It
    **binary-searches** the prefix range because the table is sorted ascending: ~115 calls (~20 ms)
    against ~600 ms to walk all 3385 entries, which is the difference between a usable launch-time
    availability probe and a visible stall. Sortedness is the one assumption and it fails **safe** —
    every key the forward scan collects is re-checked against the prefix, so an unsorted table yields
    *fewer* sensors (caller reports unavailable) and never the wrong ones.
  - **`FanLoadMonitor`** — fan RPM as a cooling/thermal signal, read through `SMCClient`, discovering
    `F{n}Ac`/`F{n}Mx` from `FNum`. Bounded per-machine, so it maps through
    as a percentage — NOT via `ThroughputScaler`. Two deliberate choices: `actual/max` rather than the
    min-anchored `(actual-min)/(max-min)` (idle RPM sits well above 0, so motion stays visible), and
    the driver is the **average** across fans, not the max — one fan spinning up shouldn't dominate
    while the rest of the system is quiet (`perFan` keeps the per-fan readings for the menu lines).
    Fanless Macs report `FNum == 0` → unavailable, as does a machine whose SMC endpoint won't open.
  - **`BatteryLoadMonitor`** — a *mixed domain* like `MemoryLoadMonitor`: the driver is the
    instantaneous **discharge current in mA** (IOKit Power Sources `"Current"`), which despite being a
    point read (no warm-up tick) is an *unbounded* magnitude and so normalizes through the shared
    `ThroughputScaler`; charge level is a readout only. On AC the draw is 0 → idle animation. Reuses
    the same `IOPSCopyPowerSourcesInfo` plumbing as `evaluateBatteryState`; desktop Macs → unavailable.
  - **`TemperatureLoadMonitor`** — die temperature, the *leading* thermal signal where `FanLoadMonitor`
    is the lagging one. Point read through `SMCClient` (no `elapsed:`). Three things not to undo:
    it takes the **max, not the average — deliberately inverting the fan precedent one bullet up**
    (throttling responds to the hottest die; averaging a loaded cluster against an idle one hides the
    event worth showing); the max is over a **curated family**, because the five *hottest* keys on an
    M-series die (`Tf06`/`Tf16`/`Tf26`/`Tf36`/`Tf46`, 94–107 °C) are **frozen constants** — trip points
    that never moved across a 12s all-core load that moved 245 other sensors, so a max over every `T`
    key pins the animation at a plausible-looking 106.73 °C forever; and a key earns its place by
    **moving under load**, never by reading a sane number once. The family is `Tp**`, of which the
    ~12 `Tpx*` **per-cluster maxima** are sampled when present (identical max to all 102 keys in 22/22
    ramp samples, 2.3 ms a tick against 20 ms — 20 ms/2 s would roughly triple this app's own CPU,
    which the self-throttle ethos won't have), falling back to the whole family on a chip without them.
    A parked cluster answers `0`/`≈ -4`, not a refusal, so `Tuning.temperatureMinPlausibleCelsius`
    drops those from both the max and the menu's range line. No readable sensor → unavailable (VMs).
- **`ThroughputScaler`** — shared value type (ported from btop `Net::collect`) that normalizes any
  *unbounded rate* signal (network/disk/swap bytes-per-sec, battery discharge mA) to 0…1 against an adaptive ceiling:
  `max(avg(last Tuning.scalerWindow) × headroom, floor)`, rescaled only after
  `Tuning.scalerRescaleCount` consecutive out-of-band samples (hysteresis), asymmetric headroom
  (`scalerHeadroomUp`/`scalerHeadroomDown`), per-source floor. **Bounded** percentage signals (CPU %,
  memory-used %, GPU %, fan %) are NOT scaled — they map through directly. Note the split is
  bounded-vs-unbounded, not delta-vs-point-read: battery mA is an instantaneous read that still scales.
  Die temperature is a **third category**: bounded, but not already a fraction, so it maps through a
  fixed `Tuning.temperatureFloorCelsius`…`temperatureCeilingCelsius` (30…100 °C) window and never
  through the scaler. Absolute on purpose — a given speed then means the same temperature on every Mac
  and every day, at the cost that a well-cooled Mac never reaches the top of its range (measured: idle
  40 °C, sustained all-core 78 °C, i.e. the 0.14…0.69 band). Don't "fix" that by making it adaptive.
- **`MenuBarLoadRunnerApp`** (`NSApplicationDelegate`/`NSMenuDelegate`) — the entire app. Key internal
  concepts to know before changing behavior:
  - **Preset identity is externalized to `gifs/presets.json`.** That manifest (`defaultPreset` + a
    `presets` array of `{key, menuTitle, file, speed:{label,min,max,responseExponent}}`) is the
    single source of truth for every built-in preset's profile. `init(config:)` decodes it via `JSONDecoder`
    into the `PresetManifest` Codable structs and maps each entry into `allPresets: [PresetDescriptor]`
    (`file` is resolved to an absolute path relative to `#filePath`'s directory). The Swift code holds **no**
    hardcoded preset list, and there are no per-preset speed constants in `Tuning` anymore. Selecting a
    preset resolves `activePreset` once (in `switchToGif(to:descriptor:)`); `currentSpeedProfile()`
    is a trivial read of `activePreset` (falling back to `defaultDescriptor`, the
    manifest's declared default). A custom/user-supplied GIF that matches no entry leaves `activePreset` `nil`
    and borrows `defaultDescriptor`'s profile (or `Self.customSpeedProfile` if the
    manifest itself failed to load). If the manifest can't be loaded/decoded, `init` records `startupError` and
    `applicationDidFinishLaunching` shows it and quits. The default preset is the manifest's `defaultPreset`
    field, resolved when `config.presetOrPath` is empty (no arg / env override).
  - **Two decoupled pipelines**: `frames`/`frameAspects`/`baseDurations` hold the raw decoded GIF (from
    `loadFrames`, which also trims transparent padding via `trimTransparentPadding` so preset art isn't
    padded to a square). `renderedFrames` holds the actual per-frame `NSImage`s sized for the current status
    item length, produced by `updateRenderedFrames()` (frames render clean — no text is baked in; the label
    is a separate status item, see below). Any change to width must call `updateRenderedFrames()` (usually via
    `applySizing()`) before `renderCurrentFrame()` picks up the new images.
  - **Game loop**: a `CADisplayLink` (macOS 14+, via `NSView.displayLink` on the status item button; a 60 Hz
    `Timer` fallback on older systems) drives `advanceFrames(now:)`, which accumulates real elapsed time
    (`link.timestamp`) and advances `frameIndex` based on each frame's GIF delay divided by the current
    `speedMultiplier`, looping (possibly multiple frames per tick) until under budget. Ticks are vsync-aligned
    and follow the screen's refresh rate. Speed changes take effect immediately since the driver reads
    `speedMultiplier` live — `sampleSystemLoad` no longer restarts the driver on a speed change. `startGameLoop`
    (re)creates the driver; `resetGameLoopTiming` re-syncs the clock (used on frame-source switch). Gaps larger
    than `Tuning.maxFrameAdvanceDelta` (sleep/occlusion/clock jump) resync instead of replaying every frame.
  - **Auto speed**: on each `loadSampleInterval` (2s) tick, `speedMultiplier(forUsage:)` maps the active
    load source's 0..1 fraction through the current preset's `SpeedProfile` (min/max/response exponent —
    linear for every preset), and only applies the new value if the change exceeds
    `Tuning.speedUpdateHysteresis`, to avoid visible jitter. Disabled entirely when
    `--speed-multiplier` is passed.
  - **Load source selector**: `activeLoadSource: LoadSource` (`.cpu` default; `.memory`, `.gpu`,
    `.network`, `.disk`, `.fan`, `.battery`, `.temperature` also available, the last three
    hardware-dependent — and the case is spelled **`temperature`, never `thermal`**, because
    `KeepAwakeSuspension.thermal` and the throttle row already use "thermal" for
    `ProcessInfo.thermalState`, a different thing;
    `--load-source`/`MENUBAR_LOAD_RUNNER_LOAD_SOURCE`, unknown → `.cpu`) picks *which* reader drives the
    animation, independent of the preset's speed range. `LoadSource` is a single registry (key + menu title)
    like `PresetDescriptor`. The speed path reads the active source, never `loadMonitor` directly, through
    three helpers: `sampleActiveSource(elapsed:)` (in `sampleSystemLoad`), `activeSourceHasSample` /
    `activeSourceCurrentUsage` (in `reevaluateSpeedForCurrentConditions`). Sampling is **active-only** (the
    inactive monitor isn't polled), so `refreshMenuMetrics` is **source-conditional**: it shows the active
    source's metric + state (CPU%/CPU State, or Memory%+swap/Memory Pressure) — not both. The switcher is
    the **Other Sources** collapsible section (there is no separate `Load Source` submenu): a disclosure
    header row (`otherSourcesHeaderItem`, whose view is a `DisclosureMenuItemView` that draws its own ▸/▾
    glyph since NSMenuItem has no native disclosure control) toggles `showAllSources`, which reveals an inline row per
    *available, non-active* reader (`otherSourceRowItems`, built in `applicationDidFinishLaunching`, state
    driven by `refreshShowAllSourcesState`). Each row shows that reader's live readout (`allSourcesRowText`)
    and, clicked, switches the driving source (`selectLoadSource`) — the active source is never listed (it's
    on top with the sparkline). Expanded = sample every reader each tick; collapsed = active-only sampling
    (the self-throttle ethos). Adding a source = add a `LoadSource` case + its reader + branches in the
    three helpers (plus `refreshMenuMetrics`/`allSourcesRowText`/`compactLabelText` for its readout).
    Counter-delta sources divide by the real elapsed wall time captured
    each tick in `sampleSystemLoad` (`ProcessInfo.systemUptime` → `lastSampleUptime`, threaded as the
    `elapsed:` arg); the memory source's swap rate already uses it, and network/disk reuse it (a source
    switch resets `lastSampleUptime` so rates re-warm cleanly). Fan, battery and temperature are point
    reads and take no `elapsed:`.
  - **Self-throttling under pressure** (the app throttles *its own* animation, never the system —
    it only ever *reads* system state): the indicator reduces its own CPU use so it doesn't add to
    the load it visualizes. `speedMultiplier(forUsage:)` caps *this app's* auto animation speed at the
    midpoint of the preset's range (`Tuning.constrainedSpeedCeilingFraction`) when `isUnderPowerPressure`
    (Low Power Mode on, `thermalState` `.serious`/`.critical`, or memory pressure `.warning`/`.critical`).
    Fewer frame advances/redraws = less CPU spent by the app; nothing about the system or other processes
    is changed. It subscribes to `.NSProcessInfoPowerStateDidChange` /
    `ProcessInfo.thermalStateDidChangeNotification` and a `DispatchSource.makeMemoryPressureSource` (mask
    **must** include `.normal` to lift the cap — memory pressure is event-only with no synchronous getter,
    so `memoryPressureLevel` is cached; its lifecycle is `resume()`/`cancel()`, NOT `removeObserver`), each
    calling `reevaluateSpeedForCurrentConditions()` (recomputes immediately, bypassing hysteresis) so the
    cap engages/lifts without waiting for the next 2s tick. Separately, `updateAnimationForOcclusion()` (driven by
    `NSWindow.didChangeOcclusionStateNotification` on the status button's window) stops the game loop
    entirely when the item is fully occluded (notch/overflow, another Space, display off) and restarts
    it when visible — no re-rasterizing frames no one can see. It only ever pauses in response to a
    positive occlusion event, so a never-firing notification leaves animation running (no freeze risk).
  - **Keep Awake**: a menu checkbox spawns `caffeinate -di -w <pid>` (prevents both display and
    idle system sleep, bound to the app's PID) via the `SleepPreventer` class, which separates *intent*
    (`isEnabled`, the toggle) from *running state* (the process may be suspended/respawned by conditions
    without losing intent). `applyConditions(suspend:)` is the total function. `-di` (not the earlier
    `-i`-only) is deliberate: on modern macOS an idle-only assertion is unreliable — once the display
    sleeps the system follows it down, so the Mac slept with Keep Awake on. Preventing display sleep is
    what actually holds it awake (matches KeepingYouAwake's default). Auto-disengage conditions are a
    **reason, not a Bool** (`keepAwakeSuspension` → `KeepAwakeSuspension?`, `nil` = run): serious/critical
    thermal, battery ≤ `Tuning.batteryCriticalThreshold` (5%), or battery ≤
    `keepAwakeBatteryThreshold` (the live release point, default
    `Tuning.batteryLowThresholdDefault` = 20%, `0` = never release on charge; set at launch by
    `--battery-threshold` / `MENUBAR_LOAD_RUNNER_BATTERY_THRESHOLD`, or restored from the `settings`
    block, both via
    `applyLaunchBatteryThresholdState()`, which **must** run before `startBatteryMonitoring()` or the
    first suspension is computed against the default and then jumps; changed at runtime by
    `setBatteryThreshold`, the sole mutator, which persists, **clears `keepAwakeBatteryOverride`** (that
    gesture answered a question about the *old* threshold — raising it to 30% at 25% charge must not
    inherit a "yes" given about 20%), and calls `updateSleepPrevention()` so a live window picks the new
    point up at once instead of waiting for the next power event. Every entry point clamps
    through `Tuning.clampedBatteryThreshold`, and its min sits above the 5% floor so that floor stays
    unreachable from any surface) — deliberately NOT
    memory pressure (sleep costs negligible RAM), or Low Power Mode (a performance policy,
    not a sleep policy; the battery-low threshold already guards drain).
    Only `.batteryLow` is **overridable**: arming from the menu on a low battery sets
    `keepAwakeBatteryOverride`, so an explicit arm is honored instead of being a silent no-op, and
    `effectiveKeepAwakeSuspension` (what the spawn decision, menu, and bar all read) drops it. The
    override is **memory-only and gesture-only** — never persisted, and never set by `--keep-awake` or a
    restored window, both of which fire with nobody present; it is cleared by Off, window expiry,
    plugging in, and crossing the 5% floor. `startBatteryMonitoring()` **must** run before
    `applyLaunchKeepAwakeState()`: arming reads `batteryState`, so the old ordering armed against a `nil`
    reading and spawned caffeinate even at a critical charge. A paused keep-awake is **never silent** —
    the parent row says `(paused)` and the status row says why (see the menu section below). The
    power/thermal/battery observers fan through
    `conditionsDidChange()` (calls the guarded speed recompute AND the *unguarded* `updateSleepPrevention()`),
    so keep-awake still disengages under `--speed-multiplier`; memory pressure keeps calling the reevaluate
    directly (not a sleep trigger). Battery is an event-driven IOKit Power Sources run-loop source
    (`import IOKit.ps`), torn down in `applicationWillTerminate` alongside an explicit caffeinate kill.
    The indicator is a **sibling `CALayer`** (`keepAwakeBar`) on `animationView.layer` on TOP of the frame
    contents — a bottom track line, updated by `updateKeepAwakeBar()` (toggle/resize/color change, plus the
    2s tick when the machine's hold or our own pause changes). The rule is **brightness tracks the strength
    of the hold**, NOT *lit means held* — `keepAwakeTint(for:paused:)` holds the precedence: ours running →
    full; the Mac held by anyone → `Tuning.keepAwakeBarForeignAlpha` (**outranks** our pause); armed and
    nothing holding → `keepAwakeBarPausedAlpha` (R7); else hidden. Bar and label both resolve through
    `keepAwakeTintColor(for:paused:appearance:)` so they can't disagree. Three things not to break:
    `keepAwakeArmedNotHolding` is the **spawn outcome** (`isEnabled && !isRunning`), never a re-derivation of
    `effectiveKeepAwakeSuspension` — that is what makes an honored battery override read as running; expiry
    stays dark because the termination handler clears `isEnabled`; and the tick's redraw guard is
    `"\(awakeHold.tintSignature)|\(keepAwakeArmedNotHolding)"`, composed at the call site because
    `AwakeHold`'s subject is the machine. `LOG_AWAKE` prints `tint=` off `keepAwakeTint` itself, so qa.sh §3e
    asserts the rendered tone; perceptibility stays eyes-only (RUNBOOK §3.1). Rationale: `DESIGN-system.md`
    §22.5. It must NEVER be composited into `renderedFrames` (that would re-rasterize every frame on toggle). Enabled-state and tint are **one merged radio group** under the **Keep Awake**
    submenu (there is no separate toggle or Keep Awake Color submenu): an **Off** row plus one row per
    `KeepAwakeColor` case — Dusty Teal (default), Sand, Graphite, Mauve, Sage — each a dark/light tone
    chosen per menu-bar appearance. The enum drives the rows, so adding a case needs no menu edit; it does
    need the user-facing lists updated in lockstep (`README.md`, `docs/cover.html`,
    `docs/RUNBOOK-qa-release.md` §3.2), which name the tints deliberately.
    Off disengages caffeinate; a color row engages it *and* sets that tint (`selectKeepAwakeOption`,
    `refreshKeepAwakeSelectionState`, Off tagged `keepAwakeOffTag`). The tint is menu-only (no CLI/env)
    but persisted. A **second, independent radio group** in the same submenu is the **timed release** (`Duration`):
    `KeepAwakeDuration` (`.indefinite` + `Tuning.keepAwakeDurations`) plus a `Custom…` hr/min prompt,
    handled by `selectKeepAwakeDuration` / `promptCustomKeepAwakeDuration` → `armKeepAwake`. Its rows'
    tags are indices into `presetRows` and are read ONLY by that handler, so they don't collide with the
    tint group's tag space. The release is **`caffeinate -t <secs>`** — the app runs no timer of its
    own; `keepAwakeDeadline` exists to render the countdown and to supply `keepAwakeRemainingSeconds`,
    which a respawn after a condition-suspend passes so the window isn't extended (an already-elapsed
    window floors at `-t 1` and self-corrects through the normal expiry path). Natural expiry arrives via
    `Process.terminationHandler` → `SleepPreventer.onWindowExpired`; `kill()` **must** detach that handler
    (and bump `generation`) first, or an intentional Off/suspend reads as a window elapsing and clears the
    user's intent. Changing tint does *not* respawn (`spawn` is guarded by `process == nil`), but changing
    the *window* must — hence `restartForNewWindow`. The readout is a **countdown, not a duration**:
    `KeepAwakeDuration.countdown` renders positional seconds-resolution time left (`29:24`, `1:29:24`)
    and `clockTime` the wall-clock end (`until 8:18 PM`) — a minute-rounded value read as "the length I
    picked" and looked frozen. Because the countdown only exists inside the dropdown, a **1s ticker runs
    solely while the menu is open** (`startKeepAwakeCountdownTicker` from `menuWillOpen`, torn down in
    `menuDidClose`; `.common` run-loop mode, since an open menu puts the loop in modal tracking). The 2s
    load tick still refreshes it so the row is current at the next open.
    That row is `keepAwakeStatusItem` (renamed from `…CountdownItem`) and has **two modes**: the countdown,
    or `paused — <reason>` when `effectiveKeepAwakeSuspension` is non-nil; it hides only when there is
    nothing to say (running, indefinite). The parent row composes with it — `Keep Awake: 3:59:12 (paused)`
    when both a window and a pause are live. Two gotchas: the countdown sets `title` **as well as**
    `attributedTitle` (the monospaced digits need the attributed form, but accessibility reads only
    `title`, so an attributed-only row is silent to VoiceOver), and the paused form sets `title` and nils
    `attributedTitle`, or a previous countdown render keeps winning for display. Anything scripting this
    menu must resolve items **by index, not by title** — the parent title ticks every second while open,
    so a title-based reference goes stale mid-script (`-1728`).
  - **Other sleep assertions — the read side of sleep** (`SleepAssertionMonitor`, immediately above
    `SleepPreventer`; rendered by `refreshOtherAssertionRows` from `refreshKeepAwakeSelectionState`).
    `IOPMCopyAssertionsByProcess` (IOKit `pwr_mgt`, public, headered, unprivileged — `import
    IOKit.pwr_mgt`), **never** `pmset -g assertions` prose. Deliberately **not** a `LoadSource`: no 0…1
    fraction, nothing driven — keep it out of `LoadSource.allCases` and out of Other Sources. Six things
    are load-bearing:
    - **It reports the observation, never the conclusion.** Rows are `owner — RawAssertionType` and must
      never render as "something is holding your Mac awake": an assertion is not an effect
      (`PreventUserIdleSystemSleep` alone doesn't hold the display, and the system follows the display
      down — the reason this app spawns `-di`), so that sentence can be false while the list is accurate.
      The type is printed **raw**, not glossed, so a user can diff the rows against `pmset -g assertions`.
    - **Identity is `owner + type`, never the pid or `AssertionId`.** A renewal loop
      (`caffeinate -i -t 300` on repeat) is a *new process* each cycle, so a pid-keyed identity churns and
      the retention window below can never see continuity. **Rows then group by owner alone** — one row
      listing every type that owner holds, with `×N` on the *type* — because `caffeinate -di` holds two and
      one process burning two of `Tuning.assertionRowCap` slots pushed a real 5-holder reading into the
      overflow row. Retention stays keyed on owner+type on purpose: the blink it guards is an owner
      vanishing across a gap, and a per-owner window would let a type flicker inside a present owner.
    - **Sampling is unconditional on the 2s tick** — a deliberate exception to the active-only ethos that
      gates `showAllSources`, and not a thing to "fix". Menu-gated sampling restores the founding bug: with
      no history a menu opened inside a renewal gap reads `none` while a loop is in fact holding. The
      IOKit call measures ~126 µs, i.e. 0.006% duty. It is also primed once in
      `applicationDidFinishLaunching`, because an unsampled list renders `none` — a wrong answer, where a
      load reader would honestly say `warming up...`.
    - **Both filters are a heuristic** even though every line they pass is a fact
      (`Tuning.assertionSleepTypes` + `assertionNoiseOwners`). The type allowlist does the real work;
      the owner denylist is **two named exceptions** (`powerd`'s is literally "Prevent sleep while display
      is on", so it is present whenever anyone could read the menu), not a policy. Don't grow it into an
      is-a-daemon test — `backupd` and `sharingd` are signal, and `caffeinate`/`Music`/`zoom.us` wouldn't
      match anyway. `BundlePath` can't stand in either: `caffeinate` reports `powerd.bundle`.
    - **Our own child is excluded** via `SleepPreventer.childPID` — the countdown row two lines above
      already reports it. Another *user's* instance still shows as `caffeinate`, correctly.
    - **The section is inline in `Keep Awake ▸`, not a nested submenu**: that would be two deep, and
      `tests/menu-dump.applescript` descends one level. Rows are pre-created (`otherAssertionRowItems` +
      `otherAssertionsMoreItem`) and driven by `isHidden`/`title`, the `otherSourceRowItems` pattern.
      `none` is a **row**, not an empty section, and the `…and N more` overflow row is required — a cap
      must never be silent. The `kIOPMAssertionType*` constants are `CFSTR` macros and don't import into
      Swift, so the type strings are literals.
  - **The submenu is grouped by SUBJECT, in two sections (v1.19.1)** — the one layout rule to preserve
    when adding a row. Section 1, **This Mac**, is read-only and unheaded: the machine-hold row, then
    `Other Assertions` and its rows, which sit there as that row's *evidence*. Section 2, **This App**
    (`MenuTitle.keepAwakeThisApp`, a disabled header), is everything that acts on our own hold: the
    Off/tint group, `Duration`, then the countdown/paused row. A new row goes in the section matching its
    subject; nothing may straddle. This exists because the machine row and a ticked `Off` have *different
    subjects*, and with the assertion list previously at the bottom the two read as a contradiction —
    the v1.19.0 layout let a separator carry that distinction alone, and it could not. The header is
    also what makes the "`Off` can only release ours" invariant legible in the UI instead of only in this
    file. The countdown row's separator is **stored** (`keepAwakeStatusSeparatorItem`) and hidden with the
    row via `setKeepAwakeStatusRowVisible` — that row is now the submenu's last, and AppKit trims a
    *leading* separator, not a trailing one. Rejected here and worth not re-proposing: merging the
    assertion rows into the machine row (breaks `none`-is-a-row, and drops the "other"-scoping that our
    own excluded child depends on), and dropping the tint/`Duration` separator (two adjacent radio groups
    with only a disabled header between them is the same under-signalled boundary).
  - **Is this Mac held awake? — the derived state** (`AwakeHold` / `awakeHold`, rendered by
    `refreshMachineAwakeRow` into `machineAwakeItem`, the **first row** of `Keep Awake ▸`). Reports whether
    the *machine* is held awake by anyone, ours or not — the case where a bare `caffeinate -di` in a
    terminal used to leave every keep-awake surface reading `Off`. Two invariants you must not break:
    a foreign hold **never** drives the Off/tint group or the bar's own-hold tone (`Off` can only release
    ours), and the row is **always attributed** and never claims the Mac won't sleep. Held is keyed on the
    **display**, not idle sleep (`Tuning.assertionDisplaySleepTypes`) — idle-alone reads "may still sleep".
    Two IOKit facts an implementer will otherwise re-derive: `AssertionTrueType` splits display- from
    idle-sleep holds, and a timed foreign hold exposes a deadline — but `AssertTimeoutTimeLeft` is stale as
    of `AssertTimeoutUpdateTime`, **not** live, so reading it as time-from-now makes the deadline slide
    forward every tick. Full rationale: internal `DESIGN-system.md` §22.11 (vault, not in this repo).
  - **Keep Awake at launch and across launches** (`applyLaunchKeepAwakeState`, run from
    `applicationDidFinishLaunching` before the first `refreshKeepAwakeSelectionState`). Precedence:
    `--keep-awake` / `MENUBAR_LOAD_RUNNER_KEEP_AWAKE` (parsed by `KeepAwakeDuration.parse` into a
    `KeepAwakeLaunchOption`) beats the `StateStore` file; `.off` is distinct from *absent* precisely so
    an explicit off can suppress a saved window. **Only a bounded window is restored** — a saved
    *indefinite* one is activate-on-launch with no stopping condition, so a stale flag would hold the
    Mac awake after every reboot; a bounded one is self-limiting. The saved value is the **deadline**,
    not the length (a length would silently extend the window on every relaunch), which also makes an
    elapsed window restore as "expired" for free. The restored row marks `Custom…`, correctly: what
    resumed is the remainder, not the 4 hours originally picked. `persistKeepAwakeState()` is called
    from exactly the three intent mutators (`selectKeepAwakeOption`, `armKeepAwake`, the
    `onWindowExpired` callback) plus `applicationWillTerminate` — **not** from
    `updateSleepPrevention()`, which also runs on every thermal/battery/power event and would write
    disk for a change in *running* state. Persist intent, never running state: the
    `isEnabled`/`isRunning` split has to survive a relaunch too.
  - **Self-update, and the restart after it** (`UpdateChecker` / `Restarter`, both above `Tuning`). The
    check is `git ls-remote --tags origin 'v*'` (no token, no API, honors the checkout's own origin);
    applying is a click-gated `git pull --ff-only`, never `--force`. Two things are load-bearing:
    - **The pull names its refspec when tracking is missing.** A bare `pull --ff-only` needs
      `branch.<name>.remote`/`.merge`, which a *copied* (not cloned) checkout lacks — it then dies on
      "no tracking information", an error no button in the alert can fix. So `pullArguments` falls back to
      `pull --ff-only origin <branch>`, and detached HEAD keeps the bare form so git's own message shows.
    - **The app cannot restart itself directly** — the pull moves the *source*, and the launcher is what
      recompiles, so the restart re-invokes whoever started us. That is not inferrable in-process (a
      detached run and a launchd job both reparent to pid 1), hence the launcher's exported markers, and
      hence launchd being *asked* rather than sniffed: a LaunchAgent job's `XPC_SERVICE_NAME` is `"0"`,
      **not** the label (verified — it is the obvious-looking signal and it is wrong), so `isLaunchAgentJob`
      compares our pid to the one `launchctl list <label>` reports, which works because the plist's launcher
      `exec`s the binary and `exec` preserves the pid. The relaunch runs from a detached `/bin/sh` that
      waits for our pid to disappear (bounded ~30s) — required, since the launcher's singleton guard
      refuses while we live and launchd won't restart a job whose process is up — and `kickstart` is
      deliberately **without `-k`**, which would SIGKILL us mid-quit and skip the caffeinate teardown.
      `appArguments` reproduces the *running* config (menu-chosen preset/source/label/threshold/disclosure
      and a fixed `--speed-multiplier`), because none of those persist; Keep Awake needs a flag only when
      **indefinite**, since a bounded window restores from the saved deadline and the restore path refuses
      indefinite ones on purpose. The `.launchAgent` path can't inject argv (baked `ProgramArguments`), so
      it resumes those baked args — a documented asymmetry, not a bug.
  - **Menu bar state is menu-driven**: the status item menu doubles as a live dashboard — metrics and
    selection state are refreshed on `menuWillOpen` (`refreshMenuMetrics`, `refreshPresetSelectionState`,
    `refreshWidthInfo`, `refreshLabelSelectionState`, `refreshBatteryThresholdSelectionState`,
    `refreshShowAllSourcesState`) rather
    than pushed reactively. When adding
    a new piece of runtime state, wire it into these refresh functions and into the initial
    `applicationDidFinishLaunching` setup.
  - **Width model**: width is **GIF-derived, not configurable**. `currentGifAspect()` reads the loaded
    GIF's aspect (frames share one union bbox from `trimTransparentPadding`, so any frame represents the
    whole animation), clamped to `[Tuning.minAspect, Tuning.maxIconAspect]`. `slotLength()` maps that to
    the status-item length (menu-bar height × aspect, floored at `Tuning.minBaseSlotWidth`) — the sole
    driver of item width, used by both `applySizing()` and the read-only `refreshWidthInfo()` menu line.
    There is no user width control (`--width` / slot submenu removed) and no per-preset slot constant.
  - **Menu-bar label is a separate status item — in fact two of them.** `MenuBarLabel`
    (`.off`/`.value`/`.custom(String)`, parsed from `--label` / `MENUBAR_LOAD_RUNNER_LABEL`) drives an
    adjacent `NSStatusItem`, NOT text baked onto the animation (that was the old overlay; illegible on a
    22pt icon, and it re-rasterized frames on every value change). `updateValueLabel()` (called from
    `refreshMenuMetrics`, so it tracks the 2s tick) writes the text — `compactLabelText(for:)` in `.value`
    mode, the fixed string in `.custom` — plus the width and the tint. Four things are load-bearing:
    - **Two items (`labelItemLeft`, `labelItemRight`), because slot order is creation order and cannot be
      changed.** macOS assigns a status item its slot when it becomes *visible*, orders slots oldest =
      rightmost, and offers no reorder API. So the label's side is decided by whether it was created before
      (→ right) or after (→ left) the animation, and a runtime switch with one item would mean tearing down
      and rebuilding the *animation* (button, layer, keep-awake bar, display link, occlusion observer) every
      time the label moved right. Instead both are created up front — right slot, animation, left slot —
      and `applyLabelMode()` gives the live one its width and zeroes the other. Both stay permanently
      visible because adjacency comes from being created back-to-back with the animation: reveal an item
      later and it lands leftmost of *every* item on the bar, other apps' icons in between. So `.off` and
      "wrong side" are both just `length = 0`.
      **Back-to-back creation buys adjacency only on a bar with room** — measured 2026-07-29, and the
      earlier unqualified claim here was wrong. macOS owns placement, and when the bar is full it does not
      keep one process's items together: on a notched built-in display, six consecutive runs placed ours as
      `icon=908 right=955 left=1117` with other apps' icons interleaved, while the roomy external display
      placed the same build correctly every time. Nothing in-process can fix this (no reorder API), so it is
      a **known limit**, not a bug to chase — see `docs/ROADMAP.md`. What survives a scattered bar is the
      v1.16.0 no-jitter promise: fixed width and no icon movement held throughout. `tests/qa.sh` §3c
      detects the scatter geometrically and reports NOTE rather than a false FAIL. `activeLabelItem` is the one on `labelSide`; **address the
      slot through it, never by name.** Cost, measured with `MENUBAR_LOAD_RUNNER_LOG_SLOTS` (below): a
      `length = 0` item still claims **~16pt** of menu bar — hiding it moves its neighbour 16pt over — so
      the pair permanently costs 16pt more than one item would. An older comment here claimed "zero
      footprint"; that half is false. Accepted because the only alternative is rebuilding the *animation*
      item on every switch to the right; the retreat, if 16pt ever outweighs an instant switch, is to
      create only the persisted side's item and defer the menu row to the next launch.
    - **The width is RESERVED, never auto-sized** (`labelSlotWidth`). A `variableLength` slot resizes with
      its text, and macOS shifts every item to the *left* of one that resizes, so the label used to shove
      its neighbour sideways twice a second (1.11.2 → 1.15.2 put the label on the right, which moved the
      jitter onto the icon; that's the bug this replaced). Each number goes through `labelField`, which pads
      it with **U+2007 FIGURE SPACE** — a space defined to be exactly as wide as a digit — out to the
      character count of that field's ceiling (`Tuning.percentScale`, `labelRateCeiling`,
      `labelDiskCeiling`), and the font is `labelFont`, the menu-bar font with **monospaced digits**. Both
      halves are required: monospaced digits make `111` and `888` measure alike, and the figure space makes
      the pad measure like a digit (a normal space is 3.6pt against a digit's 8.1pt, so `%3.0f` padding
      still moves). Result: every reading of a shape measures identically, so the reservation from
      `labelWidthTemplate` holds exactly and the text fills it with no dead space. `qa.sh` §5 asserts it
      per shape off the **live** status item (one distinct slot width across many distinct readings);
      §3c asserts the icon next to it never moves. Overflow past a ceiling formats wider and `max()`
      widens the slot for that tick rather than truncating.
    - **VoiceOver gets the depadded string.** Coloring a status button's text needs `attributedTitle`,
      which is invisible to VoiceOver, hence the explicit `setAccessibilityLabel` — and it is handed the
      reading with U+2007 stripped (lossless: all padding is leading-within-a-field).
    - **It wears the Keep Awake tint whenever the bar does** — through
      `keepAwakeTintColor(for:paused:appearance:)`, the same function `updateKeepAwakeBar()` uses, so the two
      can never disagree (full tone for our own hold, `keepAwakeBarForeignAlpha` for someone else's,
      `keepAwakeBarPausedAlpha` while ours is armed but suspended). Don't special-case one surface: the pair
      reads as a single indicator. The bar
      calls `updateValueLabel()`, so a toggle/suspend/foreign-hold change recolors at once instead of up to
      2s later. The plain `title =` assignment in the untinted branch resets
      the color back to the default catalog color — that default is what tracks appearance and dropdown
      highlighting, so don't "fix" it into an explicit `.labelColor`.

    Menu switcher: the **Menu Bar Label** submenu holds two independent radio groups — the mode
    (`labelOffItem`/`labelValueItem`/`labelCustomItem`, distinguished by selector, no tags) and the side
    (`labelSideItems`, tags = indices into `MenuBarLabelSide.allCases`, read only by `selectLabelSide`),
    both refreshed by `refreshLabelSelectionState` and mutated through `setLabelMode` / `setLabelSide`,
    which persist — they are the mutating gestures. The side is **menu-only, like the Keep Awake tint**: no
    flag, no env var (a new flag is public API forever, and this is cosmetic), so it restores from the
    `settings` block unconditionally in `applyLaunchLabelState()` — independently of the mode, whose flag
    may have won — and the restart-after-update path picks it up off disk rather than through `argv`.
  - **Root-menu layout, and why two things are submenus.** The root menu is the scarce surface: it also
    carries the 7-row metrics block, the Other Sources section (up to 6 rows expanded), and Update/About/
    Exit, so a new setting landing there by default is what made it ~33 rows. Two containers absorb that:
    - **`Settings ▸`** — the home for menu-driven preferences. `Menu Bar Label` is reparented **whole**,
      not flattened into it: that parent row's title *is* the readout (`refreshLabelSelectionState` writes
      `Menu Bar Label: value` into it), and flattened, the string would have nowhere to live but the
      `Settings` row itself, which can't say `Label: value` once a second setting exists. The second
      setting is **`Battery Threshold ▸`** (`batteryThresholdItems` over
      `Tuning.batteryThresholdRows` + `Never` + `Custom…`, readout in the parent title via
      `refreshBatteryThresholdSelectionState`, mutated through `setBatteryThreshold`). The third is
      **"Start at Login"** — a simple on/off toggle (`startAtLoginMenuItem`, checked when the
      LaunchAgent plist exists at `~/Library/LaunchAgents/ai.bera.menubarloadrunner.plist`) that
      shells out to `scripts/install-login-item.sh` / `scripts/uninstall-login-item.sh` with the
      current config, so enabling it bakes in the active preset, load source, label, and
      Keep Awake state. Battery Threshold governs Keep
      Awake but lives here, not in that submenu, because it is a standing preference that outlives any
      single arm, whereas every *gesture* in `Keep Awake ▸` is an action (its two readout sections — the
      countdown/paused row and `Other Assertions` — report on the thing this submenu does, so they belong
      with it). Its rows spell the zero value **`Never`**
      where the CLI says `off`: `Keep Awake ▸` already has an `Off` row meaning *disarm keep-awake*, and
      a second `Off` nearby meaning *disarm the threshold* is a collision worth one word to avoid (the
      parser accepts `never`, so the surfaces agree).
    - **`Presets ▸`** — the 12 preset rows, previously inline under a disabled header row. The submenu's
      own title replaces that header.
    Keep Awake stays a **root** submenu on purpose: its Off row and five tints are one merged radio group
    (clicking a color *is* the on gesture), so it is an action, not a setting, and splitting it would
    recreate the separate Keep Awake Color submenu that was deliberately removed.
    Two invariants when moving items: `infoMenu.items.forEach { $0.target = self }` wires **root items
    only**, so anything nested must set its own `target` at construction (the preset rows do); and the
    selection-state refreshers address **stored arrays** (`presetMenuItems`, `keepAwakeOptionItems`, …),
    never menu positions, so reparenting is invisible to them.

## Adding a new built-in preset

No Swift edit is needed — preset profiles are data in `gifs/presets.json`. Touch these together, or the
preset will be inconsistent across the CLI, menu, and README:
1. Add the GIF to `gifs/`.
2. `gifs/presets.json` — add one object to the `presets` array: `{key, menuTitle, file,
   speed:{label, min, max, responseExponent}}`. `file` is the GIF filename relative to `gifs/`. This is the
   single source of the preset's keyword, menu title, path, and speed profile — the CLI keyword,
   menu item, `@objc` action, and every selection-state check all derive from it at startup. (Optionally set
   `defaultPreset` to a `key` in the array to change the no-arg default.) There is no width field — the
   menu-bar item sizes itself to the GIF's aspect ratio, so just make sure the GIF is trimmed/proportioned
   the way you want it to appear.
3. `menubar-load-runner` — add a line to `print_help`'s preset list and usage string (docs only; the launcher
   forwards the keyword to Swift unchanged).
4. `README.md` — add it to the file list, the built-in presets command list, and the auto speed ranges table.
