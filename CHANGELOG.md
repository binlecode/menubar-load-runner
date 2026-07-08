# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## Public API (what semver governs)

MenuBar Load Runner is a CLI-launched app; the surface that MAJOR / MINOR / PATCH bumps apply to is:

- **Launcher CLI** — the positional preset keyword or GIF path, and the flags `--width`,
  `--speed-multiplier`, `--overlay-text`, `--load-source`, `--foreground` / `--no-detach`,
  `--detach`, `--extra`, `-h` / `--help`.
- **Environment variables** — `MENUBAR_LOAD_RUNNER_PATH`, `MENUBAR_LOAD_RUNNER_LOAD_SOURCE`,
  `MENUBAR_LOAD_RUNNER_LOG_FILE`, `MENUBAR_LOAD_RUNNER_BIN_NAME`, and the debug/QA hooks
  `MENUBAR_LOAD_RUNNER_EXIT_AFTER` and `MENUBAR_LOAD_RUNNER_FORCE_UNAVAILABLE`.
- **Built-in preset keywords** and the `gifs/presets.json` manifest schema.
- **Observable behavior** — the status menu structure, the default preset, and the load-adaptive
  speed contract.

Internal implementation details (Swift types, `Tuning` constants, file structure) are **not** part
of the public API and may change in any release.

## [Unreleased]

_Nothing yet._

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
  `docs/DESIGN-system.md` = source-anchored mechanism). The README "Start at login" section is
  trimmed to install/uninstall usage; the full LaunchAgent mechanics — `--no-detach` supervision,
  `RunAtLoad` timing, the `bootout` reload race, and Background Task Management ("Allow in the
  Background") behavior — now live in `docs/DESIGN-system.md` §19.

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
- Documentation: `README.md`, `docs/DESIGN-system.md` (source-anchored architecture map),
  `docs/RUNBOOK-qa-release.md` (release QA gate), and `CLAUDE.md`.

### Engineering notes

- Built warning-clean under `-strict-concurrency=complete`; both classes are `@MainActor`-isolated.
- Startup errors (including a missing or invalid `gifs/presets.json`) surface as an alert and quit
  cleanly, rather than calling `fatalError`.
