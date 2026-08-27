# RESEARCH — Peer Survey: macOS Status Bar Load Visualizers & Telemetry Monitors

> **Scope:** Comprehensive technical peer survey and architectural comparison of open-source macOS status bar system monitors, load visualizers, and sleep inhibitors in 2026.
> **Peer set:** `menubar_runcat` (Kyome22), `zoomies` (KartikLabhshetwar), `DanceKunKun` (ygsgdbd), `tray-pulsy` (krissss), `stats` (exelban), `Hot` (macmade), `macstate` (snail007), `better-resource-monitor` (alexx855), `KeepingYouAwake` (newmarcel).
> **Methodology:** Public README / documentation review and capability mapping across the peer set, plus
> **direct source-code inspection of `newmarcel/KeepingYouAwake` 1.6.8 only** (§8). Everything said about the
> other peers is documentation-level, not source-verified, and none of them was runtime-profiled — so no
> claim here is a category-first claim (see `docs/ROADMAP.md` § Verification debt, the R13 row).
> **Snapshot:** July/August 2026. Star counts, activity dates and feature sets are point-in-time reads of
> other people's projects and **go stale on their schedule, not ours**.
> **Re-check or prune before 2027-02-01**, and before any public use of a comparative claim: confirm each
> peer's current release, then either re-date this line or delete the rows you did not re-verify. A survey
> that has silently aged is worse than no survey — per `AGENTS.md`, a research file is evidence, and
> evidence carries the date it was taken.

---

## 1. Executive Summary & 2026 Ecosystem Context

The macOS menu bar customization and system-monitoring category has experienced a developer-centric renaissance in 2026. While the proprietary App Store application **RunCat** remains the popular standard-bearer for CPU-driven status bar animations, open-source developers have built specialized alternatives addressing distinct architectural niches.

This trend is driven by three primary factors:

1. **App Store sandboxing backlash:** Developers seek utilities capable of reading unprivileged system telemetry and hardware details directly without restricted entitlements, and prefer scripting start-at-login via system LaunchAgents rather than heavy sandboxed `.app` bundles.
2. **Modular dotfile integration:** Power-users prefer lightweight, CLI-driven processes that can be launched, stopped, configured, and scripted via standard shell workflows rather than mouse-only GUI interfaces.
3. **Advanced telemetry needs:** Traditional animation tools have been strictly percentage-based (mapping CPU % to frame delays). Modern developer workflows demand visual feedback on unbounded, high-throughput metrics like disk I/O, network bandwidth, and active virtual-memory swap rates.

Within this landscape, **MenuBar Load Runner** occupies a specialized, command-line-first niche. It is a single-file Swift script backed by a Zsh launcher, featuring adaptive rate scaling, power-throttling, and occlusion-awareness usually reserved for heavyweight terminal system monitors like `btop` — while functioning as a lightweight animated indicator and live status-bar diagnostic monitor.

---

## 2. Direct Peers (Animated Load Visualizers)

These are open-source macOS status-bar projects whose core mission is to map hardware metrics into animated frame sequences.

### 2.1 MenuBar Load Runner

* **What it is:** A native, CLI-first macOS status bar visualizer for developers and power-users, written in unbundled Swift and AppKit.
* **Core mechanics:** Animates a dynamic GIF in the status bar whose playback speed correlates with a smoothed hardware metric (CPU, memory, GPU, network, disk, fan speed, battery discharge, or die temperature — eight available readers).
* **Strengths:**
  - **Zero-Xcode single-file architecture:** Built as a single Swift file (`MenuBarLoadRunner.swift`) run via a Zsh wrapper. No Xcode project, App Store provisioning, or heavy `.app` bundle required. This maximizes auditability, customization speed, and scriptability.
  - **Unbounded rate scaling:** Employs an adaptive `ThroughputScaler` (ported from the Linux `btop` utility) to normalize infinite, highly dynamic byte streams (disk operations, network throughput, swap rate) to a smooth 0–1 animation speed range.
  - **Power and occlusion awareness:** Monitors window/notch occlusion and pauses frame rasterization and display loops when hidden, dropping rendering CPU usage to **0%**. Automatically caps its own animation rate under thermal or Low Power pressure. Honors the macOS **Reduce Motion** accessibility setting (freezing the icon on the current frame, live via workspace notification) and provides a manual **Freeze Animation** toggle — while frozen, the live reading hands off to the adjacent label slot so the indicator never goes silent.
  - **Telemetry variety:** Supports 8 unprivileged hardware inputs (CPU load, memory load + swap rate, GPU usage, network bandwidth, disk I/O, fan speed, battery discharge current, and die temperature — the last two SMC/IOKit-backed through a shared read-only `SMCClient`). Each source is capability-probed at launch (`isAvailable`), so hardware-dependent inputs degrade gracefully (e.g. fanless Macs disable the Fan source in the menu, and `--load-source fan` falls back cleanly to CPU).
  - **Live in-menu diagnostic dashboard:** The status-bar dropdown functions as a lightweight monitor refreshed every 2s. It displays a **60-second load-history sparkline** (`LoadHistoryView`, 30 samples × 2s, color-coded green/yellow/red by threshold), the active source's numeric readout (CPU/GPU/fan %, memory % + swap capacity + live MB/s, network ↓↑ or disk r/w in MB/s), system **load averages (1/5/15m)** via `getloadavg`, a load/pressure **state** line, the current **speed multiplier**, and a named **self-throttle cause** line when active.
  - **Built-in Keep Awake (sleep inhibitor):** A menu selection spawns `caffeinate -di -w <pid>` (display and idle sleep prevention, bound to the app's PID) so long builds and downloads finish uninterrupted, with battery- and thermal-aware auto-disengage protection. A timed window can be armed via presets or custom duration, surviving relaunches and accepting launch-time CLI flags.
* **Trade-offs and Limitations:**
  - **No dedicated preferences window:** Runtime settings are accessible via the status-bar dropdown (load source, preset, Keep Awake state/color/duration, plus a `Settings ▸` submenu holding persisted preferences: label mode/side, Keep Awake battery threshold, Freeze Animation, and Start-at-Login LaunchAgent management). Adding custom GIFs requires editing `gifs/presets.json`.
  - **Source-based distribution:** Distributed as a source repository rather than a prebuilt `.dmg` or App Store package (though a one-line `curl | bash` installer, a LaunchAgent generator, and a git-native in-app update check with click-gated `git pull` self-update streamline deployment).
  - **Static asset registry:** Relies on GIF assets registered on disk rather than dynamic in-app pixel editors.
  - **Lightweight diagnostic scope:** Deliberately excludes battery health cycle counts and per-PID process breakdowns to maintain zero-config, unprivileged execution.

### 2.2 Kyome22 / menubar_runcat (509 Stars)

* **What it is:** A lightweight, reduced open-source edition of the official App Store **RunCat** app, written in native Swift and AppKit.
* **Core mechanics:** Animates a running cat in the menu bar; the frame interval scales inversely with system CPU load.
* **Strengths:**
  - Simplicity and historical pedigree (created by the original RunCat developer).
  - Minimal memory and CPU footprint due to a stripped-down AppKit codebase.
* **Weaknesses:**
  - Monitored input is limited to CPU only in open-source form.
  - Archived repository (read-only on GitHub, last commit May 2023); serves primarily as a reference implementation.
  - Requires Xcode to compile and packages as a standard `.app` bundle.

### 2.3 KartikLabhshetwar / zoomies (19 Stars)

* **What it is:** A modern SwiftUI-based macOS menu bar utility that turns system load into a living pixel-art pet.
* **Core mechanics:** Translates CPU, GPU, or RAM percentage into a state machine that shifts through distinct animation speeds: **idle → walk → fast walk → run**.
* **Strengths:**
  - Visual-first design with 9 distinct pixel creatures (dog, fox, panda, skeleton, deno, vampire, cat, etc.) and up to 11 color variants.
  - Graphical Settings window built in native SwiftUI.
  - Interactive status dropdown with clean numeric readouts.
* **Weaknesses:**
  - No headless or command-line scripting support — must run as a standard GUI `.app`.
  - Limited to percentage-bound metrics (CPU %, GPU %, RAM %); cannot track or scale unbounded rate metrics like network or disk speeds.
  - Higher runtime memory footprint typical of multi-view SwiftUI applications.

### 2.4 ygsgdbd / DanceKunKun (37 Stars)

* **What it is:** A meme-focused macOS menu bar app in SwiftUI featuring an animated character dancing to system CPU usage.
* **Core mechanics:** Animation loop scaling frame rates on-the-fly with CPU spikes.
* **Strengths:**
  - High novelty and direct installation of pre-compiled binaries.
* **Weaknesses:**
  - Hardcoded to a single character animation.
  - SwiftUI rendering overhead relative to single-purpose scope.

### 2.5 krissss / tray-pulsy (21 Stars)

* **What it is:** An open-source Swift clone of RunCat implementing customizable menu bar runners.
* **Weaknesses:** Lacks multi-sensor telemetry, unbounded rate scaling, self-throttling, or developer-focused CLI launchers.

---

## 3. Adjacent Peers (General System Monitors & Utilities)

These are non-animated utilities that live in the macOS menu bar to display hardware telemetry or manage sleep assertions. They lack animation visualizers but represent popular alternatives for system monitoring and power management.

* **exelban / stats (Highly Popular):** The benchmark for open-source macOS system monitoring. Written in Swift, it occupies the traditional comprehensive dashboard space — graphs, transfer rates, temperatures, battery health, and per-process usage breakdowns. Highly customizable, running a persistent background daemon.
* **macmade / Hot (3,000+ Stars):** A specialized native menu bar utility focused strictly on thermal limits — monitoring whether macOS is throttling CPU speed due to hardware heat or power constraints.
* **snail007 / macstate (44 Stars) & alexx855 / better-resource-monitor (32 Stars):** Compact menu bar resource monitors designed for minimal memory footprints, the latter built on Rust and Tauri.
* **newmarcel / KeepingYouAwake:** Dedicated sleep inhibitor and status bar menu utility wrapping `caffeinate` (analyzed in depth in §8).

---

## 4. Deep Architectural Comparisons

| Architectural Pillar | MenuBar Load Runner | Kyome22/menubar_runcat | KartikLabhshetwar/zoomies | exelban / stats |
| :--- | :--- | :--- | :--- | :--- |
| **Primary Goal** | Scriptable load runner & dashboard | Simple CPU tracking | Playful desktop pixel pet | Comprehensive system monitoring |
| **Build Philosophy** | Single-file Swift script | Xcode `.app` project | Xcode `.app` project | Complex multi-module app |
| **Packaging & Execution** | Unbundled; launcher script | Compiled `.app` bundle | Compiled `.app` bundle | Compiled `.app` bundle |
| **Load Sources** | CPU, Memory, GPU, Net, Disk, Fan, Battery, Die Temp | CPU only | CPU, GPU, RAM | Full hardware telemetry suite |
| **Scaling Logic** | Adaptive hysteresis scaler (`btop`) | Inverse linear percentage | Step-based state machine | Numerical & graph plots |
| **In-Menu Readout** | 60s sparkline + numeric + load avgs | Minimal | Numeric dropdown | Full graphs/temps/per-process |
| **Sensor Temps / Battery Health / Per-Process** | Die temp yes (SMC); battery health + per-process none | None | None | Yes (all three) |
| **Power Throttling** | Occlusion pause + thermal/LPM/memory cap + Reduce Motion honor / manual freeze | None | None | None (constant polling) |
| **Sleep Inhibitor** | Built-in Keep Awake (`caffeinate`), auto-disengage, machine assertion visibility | None | None | None |
| **CLI & Automation** | Native launcher flags, env vars, LaunchAgents | None | None | None |
| **Update Mechanism** | Git tag check + `git pull --ff-only` self-update (precompiles before restart) | Manual rebuild | App Store / GitHub release | Sparkle / GitHub release |

---

## 5. Feature Analysis & Technical Differentiators

### 5.1 No-Xcode Scriptable Compilation

While bundled alternatives require full Xcode installations and code signing configurations, MenuBar Load Runner runs directly via a single Swift file (`MenuBarLoadRunner.swift`) and a Zsh launcher.

* The launcher checks whether the source file is newer than the cached binary.
* If stale, it recompiles with optimization: `swiftc -O -strict-concurrency=complete`.
* If compilation fails or developer tools are absent, it falls back to interpreted execution with `swift <file>`.
* Supports foreground execution for interactive debugging or detached execution logging to `/tmp/`.

### 5.2 The Adaptive `ThroughputScaler` (btop Hysteresis)

Unlike percentage-bound monitors, MenuBar Load Runner supports unbounded rate telemetry (network TX/RX bytes/sec, disk read/write throughput, swap rate). Because throughput metrics have no fixed ceiling, mapping raw bytes to animation speed is non-trivial. The custom `ThroughputScaler`, ported from `btop`'s `Net::collect`, addresses this:

* **Ceiling tracking:** Maintains an evolving rolling maximum based on the average of the last $N$ samples (`Tuning.scalerWindow = 5`).
* **Hysteresis counters:** Uses `overCount`/`underCount` registers. A transient spike or dip decays the opposing counter but does not trigger an immediate rescale, preventing animation jitter on momentary bursts.
* **Asymmetric headroom:** Enforces tighter thresholds when scaling up (`scalerHeadroomUp = 1.3`) and looser thresholds when scaling down (`scalerHeadroomDown = 3.0`) to avoid oscillating scale factors.

### 5.3 Battery-Conscious Self-Throttling & Occlusion Awareness

Continuous menu bar animations can consume non-trivial CPU, adding overhead to the system under load. The engine implements multi-layered power optimizations:

1. **Occlusion pausing:** Subscribes to `NSWindow.didChangeOcclusionStateNotification`. When the status item becomes occluded (hidden under a MacBook notch, displaced by menu overflow, shifted to an inactive Space, or when displays sleep), the game loop pauses entirely, dropping rendering CPU usage to **0%**.
2. **Thermal, power & memory pressure throttling:** Subscribes to `.NSProcessInfoPowerStateDidChange` (Low Power Mode), thermal state notifications, and `DispatchSource` memory pressure notifications. Under serious/critical thermal states, Low Power Mode, or memory pressure, the app caps its animation speed at `Tuning.constrainedSpeedCeilingFraction = 0.5` (the midpoint of the active preset range). Each trigger recalculates speed immediately, engaging and releasing the cap without hysteresis delay.
3. **Reduce Motion integration & manual freeze:** Subscribes to `NSWorkspace.accessibilityDisplayOptionsDidChangeNotification` to honor the OS **Reduce Motion** accessibility setting, freezing the icon on its current frame. A `Settings ▸ Freeze Animation` menu toggle allows manual freezing for presentation or low-distraction environments. When frozen, the live reading automatically hands off to the adjacent label slot so telemetry remains visible.

### 5.4 Advanced Composite Memory & Swap Monitoring

While basic monitors poll physical RAM percentages, MenuBar Load Runner captures the composite nature of virtual memory pressure:

* Reads physical RAM allocation via unprivileged Mach APIs (`host_statistics64(HOST_VM_INFO64)`).
* Samples swap-in and swap-out rates over real elapsed time ($\Delta t$), computing active paging throughput.
* Computes composite load as `currentMemoryLoad = max(usedFraction, scaled(swapRate))`, ensuring that background swap thrashing is visualized by increased animation speed even when resident RAM usage appears static.

### 5.5 Live In-Menu Diagnostic Dashboard

The status dropdown functions as an integrated diagnostic panel, refreshed every 2 seconds:

* **60-second load-history sparkline:** `LoadHistoryView` renders the last 30 driving samples as a color-coded bar chart (green/yellow/red mapped to load state thresholds), captioned with the active source.
* **Source-conditional numeric readout:** The active source's metrics are shown in the primary block (CPU/GPU/fan %, memory % + swap metrics, network/disk MB/s, battery draw, or die temperature °C). An expandable **Other Sources** section allows monitoring non-active telemetry readers and switching the driving input with a single click.
* **System load averages:** Reports 1, 5, and 15-minute system load averages via `getloadavg`.
* **State, speed, and throttle telemetry:** Displays load/pressure state, current speed multiplier, and explicit throttle reasons (thermal vs. Low Power Mode vs. memory pressure).

### 5.6 Adjacent Live-Value Label (Second Menu-Bar Slot)

The `--label` option configures a dedicated status-bar text slot adjacent to the animation:

* **Live value (`--label value`):** Displays compact real-time telemetry matching the driving source (`CPU 15%`, `MEM 63%`, `NET ↓3.4 ↑0.1`, `DSK R12 W4`, `GPU 30%`, `FAN 45%`, `BAT 88%`, `TEMP 54°`).
* **Custom text (`--label <text>`):** Displays fixed identifiers for distinguishing multiple instances across separate load sources.
* **Jitter elimination:** Employs reserved template widths, figure-space padding (U+2007), and monospaced digits so that value fluctuations never shift neighboring menu bar items. Supports left and right placement via two coordinated `NSStatusItem` instances.

### 5.7 Git-Native In-App Update Check & Click-Gated Self-Update

Distributed as a source checkout, update management uses native git operations:

* **Tag-based check:** On launch, `UpdateChecker` inspects `git ls-remote --tags --refs origin 'v*'` against the configured remote origin, parsing strict SemVer tags without requiring API tokens or incurring GitHub API rate limits.
* **Fail-silent execution:** Network failures or offline states resolve cleanly without dialogs or warnings.
* **Safe self-update:** Updating executes `git pull --ff-only`, preventing unintended overwrites of local modifications.
* **Precompile before restart:** After pulling updates, the application precompiles the new binary while remaining live in the menu bar (`Building vX.Y.Z…`), avoiding menu bar downtime during subsequent process restarts.

### 5.8 Integrated Keep Awake & Machine-Wide Sleep Assertion Visibility

Rather than requiring a secondary sleep management utility, sleep inhibition is integrated directly:

* **PID-bound inhibition:** `SleepPreventer` spawns `caffeinate -di -w <pid>` (preventing display and idle sleep, tied to the app PID).
* **State and intent separation:** Distinguishes user intent (`isEnabled`) from process running state, allowing temporary suspension during thermal spikes or low battery without dropping the user's configuration.
* **Safety disengage & overrides:** Automatically releases sleep locks on battery at or below a configurable threshold (default 20%, adjustable from 6% to 100% or `Never`; the menu offers 10/15/20/30% plus `Custom…`) or under elevated thermal states. An explicit manual arm below the threshold is honored down to a hard 5% safety floor.
* **Timed durations & persistence:** Supports presets (30m, 1h, 2h, 4h, 8h) and custom durations (`caffeinate -di -t <secs>`), with active windows persisted across relaunches via target end timestamps.
* **Machine-wide assertion visibility:** Queries `IOPMCopyAssertionsByProcess` to report whether any process on the system is holding sleep assertions (identifying foreign holders and scheduled release times) alongside a breakdown of other active sleep assertions.

---

## 6. Trade-offs & Workflow Fit

### 6.1 Command-Line & Developer Workflows

MenuBar Load Runner is optimized for terminal-centric workflows, systems engineers, and dotfile-managed environments:

1. **Automation & process integration:** Integrates cleanly with shell scripts, process management (`pgrep` singletons), and user LaunchAgents (`scripts/install-login-item.sh`).
2. **Adaptive throughput scaling:** Normalizes high-throughput unbounded streams (network downloads, disk compilation I/O) without clipping or flatlining.
3. **Power efficiency:** Pauses rendering when occluded (0% CPU) and throttles animation rates under system pressure, honoring macOS accessibility settings.
4. **Unified utility footprint:** Merges animation, metric dashboarding, and sleep management into a single status-bar item.

### 6.2 GUI-First & Deep Diagnostic Needs

Alternative tools are preferable under specific requirements:

* **Graphical configuration:** Users seeking dedicated graphical preferences windows for asset management and drag-and-drop animations may prefer **zoomies**.
* **Detailed diagnostic breakdown:** Users requiring per-process PID breakdowns, detailed core-by-core telemetry graphs, and battery health cycle counts should use **stats** (exelban) or **Hot** (macmade).

### 6.3 Technical Synthesis

MenuBar Load Runner balances visual indication with telemetry diagnostics and power efficiency. Its architecture avoids external build systems, provides robust rate scaling across diverse hardware metrics, and incorporates safety mechanisms suitable for unattended operation.

---

## 7. Emerging Architectural Synthesis

The macOS menu bar utility ecosystem reflects a broader shift toward modular, auditable, and scriptable tools. Implementing the application in a single Swift source file with shell supervision demonstrates how native AppKit capabilities, IOKit telemetry, and Mach system APIs can be combined with minimal footprint, high performance, and zero compilation complexity.

---

## 8. Deep Dive: Integrated Sleep Inhibition vs. Dedicated Sleep Utilities (KeepingYouAwake)

A key architectural aspect of MenuBar Load Runner is the integration of Keep Awake functionality alongside telemetry visualizers. Below is a head-to-head comparison against **KeepingYouAwake** (newmarcel/KeepingYouAwake), the standard dedicated open-source macOS menu bar sleep inhibitor.

### 8.1 Comparative Grounding

Grounded in source review of `newmarcel/KeepingYouAwake` against MenuBar Load Runner:

| Capability | MenuBar Load Runner | KeepingYouAwake | Comparison Note |
|---|---|---|---|
| **Inhibition Mechanism** | `caffeinate -di` | `caffeinate -di` (configurable to `-i`) | Both prevent display and idle sleep by default |
| **Process Binding** | PID-bound (`-w <pid>`) | PID-bound (`-w <pid>`) | Identical safety model |
| **Timed Durations** | `-t <secs>`; presets (30m–8h) + custom | `-t <secs>`; preset list + user-editable list | Both leverage native `caffeinate` timer |
| **Live Countdown** | Seconds-resolution countdown + wall clock end time | Static menu row refreshed on open | MLR updates countdown dynamically every 1s while menu is open |
| **Low-Battery Disengage** | Configurable threshold (6–100% or Never) + 5% hard floor | Configurable slider (10–90%) | Both protect battery; MLR enforces hard 5% floor |
| **Thermal Disengage** | Automatic suspension on `.serious` / `.critical` thermal state | None | MLR releases sleep assertions under thermal load |
| **Low-Battery Arm Override** | Explicit menu arm honored above 5% floor | Not supported below cutoff | MLR supports intentional override with hard safety floor |
| **Machine Assertion Visibility** | Queries `IOPMCopyAssertionsByProcess` to show foreign holders and assertion list | Shows internal application state only | MLR surfaces system-wide sleep assertion state |
| **State vs Intent Preservation** | Decoupled (`isEnabled` vs `isRunning`); respawns with remaining time | Deactivation clears timer state | MLR resumes remaining duration after condition suspension |
| **Relaunch Persistence** | Persists target deadline timestamp to local state JSON | Persists activate-on-launch preference | MLR restores remaining bounded window without clock reset |
| **Launch-Time Scripting** | `--keep-awake <duration>` / environment variable | URL Scheme (`keepingyouawake:///activate`) | Different automation models (CLI vs URL handler) |

### 8.2 Architectural Differences

1. **Automation interfaces:**
   - **KeepingYouAwake** registers a custom URL scheme (`keepingyouawake:///activate?seconds=...`, `/deactivate`, `/toggle`), enabling integration with `open`, Shortcuts, and web automation without special permissions.
   - **MenuBar Load Runner** provides launch-time flags (`--keep-awake`, `--battery-threshold`) and environment variables designed for shell scripts and LaunchAgent configurations. Dynamic runtime control is accessible via standard macOS Accessibility scripting.

2. **Configuration surface:**
   - **KeepingYouAwake** provides a dedicated multi-tab Preferences window (General, Battery, Durations, Advanced, Updates, About) and localization across 21 languages.
   - **MenuBar Load Runner** concentrates settings in the status dropdown (`Settings ▸` submenu) to maintain a compact, single-file codebase without bundle dependencies.

3. **Assertion policy and visibility:**
   - **MenuBar Load Runner** queries machine-wide power management assertions via `IOPMCopyAssertionsByProcess`, presenting external sleep locks (such as terminal `caffeinate` sessions or media players) and their scheduled release times directly in the menu.

### 8.3 Practical Summary

For developers managing build tasks and downloads within command-line environments, integrated sleep prevention in MenuBar Load Runner covers timed assertion requirements while eliminating the need for a secondary menu bar utility. Users requiring custom URL schemes, multi-language localization, or standalone preferences windows continue to be well-served by dedicated tools like KeepingYouAwake.
