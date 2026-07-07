# OS reader best practices — cross-review vs. `actop`

Cross-review of `~/workspace_fullstack/actop` (a sudoless Apple Silicon performance monitor,
Python + ctypes) against this repo's `CPULoadMonitor` (`MenuBarLoadRunner.swift:177-245`),
to extract transferable best practices for reading OS/hardware metrics. Documentation only —
no code changes made as part of this review. Date: 2026-07-06. Re-verified against source on
2026-07-07 (line references refreshed; power/thermal readers section updated) and extended
with actionable specs for memory-pressure + swap (swap folded into the memory reader) and a
CPU/GPU/memory/network/disk animation load-source selector (see final sections).

`actop` is an unrelated, independently-authored project; this document only extracts general
patterns from its reader layer, not project-specific code to copy verbatim (Python/ctypes vs.
Swift/Mach — the APIs don't transfer directly, but the *design patterns* do).

---

## What actop's reader layer does (source of the patterns below)

actop's OS-facing layer is split into:
- **L0 (raw bindings)**: `native_sys.py` (sysctl/Mach/IOKit/ObjC), `ioreport.py`
  (IOReport + CoreFoundation), `smc.py` (SMC via IOKit).
- **L1 (acquisition)**: `sampler.py`'s `IOReportSampler` — one stateful object per hardware
  subsystem, created once, reused for the process lifetime, exposing a single `sample()`
  call.
- **L2 (analytics)**, **L3 (public API)** — not relevant to this comparison (pure OS-read
  layer only).

Key patterns observed, each with its rationale as documented in actop's own code/comments:

1. **Always pick the unprivileged sibling API.** `IOReportCreateSubscription` instead of
   shelling out to `powermetrics` (which needs sudo); `IOServiceOpen` +
   `IOConnectCallStructMethod` against the *read-only* SMC keys (never the write-capable
   fan-control keys, by explicit design); `NSProcessInfo.thermalState` — a public,
   documented framework — for thermal pressure, no private API needed at all.
2. **Cache every expensive setup step once; never recreate a connection/subscription per
   sample.** The `IOReportSubscription` and the SMC `IOServiceOpen` connection (plus its
   discovered key list) are created exactly once at construction and reused for every
   subsequent read.
3. **Real elapsed-time deltas, not a fixed assumed interval.** Counter-domains (CPU/GPU/ANE
   energy, per-process CPU/GPU time) measure actual elapsed time between two cached samples
   via a monotonic clock, and divide by *that*, not by the nominally-requested sampling
   interval. Instantaneous domains (temperature, fans, RAM, swap) skip delta computation
   entirely — a raw point read.
4. **"Unavailable" and "zero" are different states, and the code keeps them different.** A
   fanless Mac's fan reading, a die temperature sensor that isn't present, or a memory
   controller channel that doesn't exist all surface as an explicit unavailable flag —
   never a fabricated `0.0` that would look like a real, healthy reading downstream. First
   time a metric is seen (no prior sample yet to delta against) is treated as "no data yet,"
   distinct from "measured zero."
5. **Error handling is intentionally asymmetric.** Per-metric/per-sensor absence degrades
   gracefully (that one field goes unavailable; everything else keeps working). Total
   subsystem unavailability (e.g. the private IOReport API disappearing or not existing on
   the platform at all) is allowed to be a fatal, loud, whole-process failure at startup —
   not silently degraded.
6. **Resource cleanup is explicit and defensive.** Every stateful reader has a real
   open/close lifecycle, and cleanup during a partial/mid-parse failure is wrapped so a
   release always happens even on an exception path.
7. **No exponential smoothing in the reader layer.** Where actop smooths at all, it's a
   plain arithmetic mean over a few sub-samples taken within one reporting tick — not an EMA
   carried across ticks.

---

## How `CPULoadMonitor` compares today

`CPULoadMonitor` (`MenuBarLoadRunner.swift:177-245`) reads total CPU utilization via Mach's
`host_processor_info(PROCESSOR_CPU_LOAD_INFO)`, and `MenuBarLoadRunnerApp` separately reads
`getloadavg()` for the 1/5/15m averages (`readSystemLoadAverages()`, lines 855-866).

| Pattern | actop | `CPULoadMonitor` | Assessment |
|---|---|---|---|
| Unprivileged API | Yes (IOReport subscription, not `powermetrics`) | Yes (`host_processor_info` is a standard unprivileged Mach call) | Already aligned — no sudo dependency in either. |
| Cache expensive setup once | Yes (subscription created once) | N/A — `host_processor_info` has no setup/subscription step to cache; each call is already cheap and self-contained | No gap; the pattern doesn't apply here since there's nothing to cache. |
| Real elapsed-time delta | Yes (`time.monotonic()` between samples) | Partial — deltas the *tick counts* between two `host_processor_info` calls (a counter, correct), but never measures the *wall-clock* time between those two calls. Since the CPU tick counters and the 2-second `loadTimer` interval are decoupled, this works out numerically the same either way (it's a ratio of ticks, not ticks/second), so this isn't a bug — but it does mean the code has no explicit record of "how much real time this sample actually covers," which actop's model treats as necessary for correctness under a jittery timer. | Low-priority gap — current math is correct for a ratio-based CPU fraction; would only matter if the sampling interval became irregular and something needed to normalize *to* real time rather than just a fraction. |
| Unavailable vs. zero | Partial — `sampleUsage()`/`currentUsage()` correctly return `nil` (not `0.0`) when there's no prior sample yet or the Mach call fails (`MenuBarLoadRunner.swift:186,209,237,242`), and `refreshMenuMetrics()` shows "warming up..." rather than a fake `0%` (`:637-638`). `readSystemLoadAverages()` does the same — `nil` on failure (`:860`), "unavailable" shown in the menu (`:660`). | **Already follows this pattern correctly for both readers in the file.** |
| Asymmetric error handling | Yes | Not really applicable at this scale — there's only one subsystem (CPU), so there's no "one sensor missing, rest still fine" case to design for yet. If this expands to multiple independent readers (see below), the asymmetric-degradation pattern becomes directly relevant. | No current gap; becomes relevant only if/when more readers are added. |
| Explicit resource cleanup | Yes (open/close, try/finally around releases) | N/A today — `host_processor_info`'s only resource is the `cpuInfo` buffer, already released via a `defer { vm_deallocate(...) }` immediately after use (`:211-214`), which is the correct Swift-native equivalent of actop's try/finally-around-CFRelease pattern. | **Already follows this pattern.** |
| No EMA in reader layer | actop avoids it entirely | `CPULoadMonitor` applies EMA smoothing (`Tuning.cpuSmoothingAlpha = 0.2`, `:182`/`:193`) | Divergence, not a gap — the Swift app's EMA is a deliberate design choice for a *visual* animation speed signal where jitter is undesirable, whereas actop's readers feed a numeric dashboard/profiler where raw values (or plain averaging) are more useful for analysis. Neither is "more correct" in the abstract; they're serving different consumers. No change indicated. |

**Bottom line**: `CPULoadMonitor` already independently arrived at several of actop's core
correctness patterns (unprivileged API, `nil`-for-unavailable rather than fabricated zero,
explicit buffer cleanup via `defer`). The one true gap — not tracking real elapsed wall time
between samples — is low priority because the current ratio-based math doesn't actually need
it. There is no current deficiency worth a TODO item on its own.

---

## Where the patterns would matter: extending to other system-load readers

The patterns above map directly onto any additional reader this app might add, roughly in
order of how directly they'd port to Swift. The two lowest-effort ones have since been added:

- **Thermal pressure** (`ProcessInfo.processInfo.thermalState`) — **implemented** (added in
  `afc3b81`, after this doc's initial commit). Read in `isUnderPowerPressure`
  (`MenuBarLoadRunner.swift:893-900`) and observed live via
  `ProcessInfo.thermalStateDidChangeNotification` (`:502-508`). It mirrors actop's
  `NSProcessInfo.thermalState` read (`native_sys.py:208-221`) almost exactly — a public
  Swift/Foundation API, no ctypes/private-API bridging, exactly the unprivileged-public-API
  pattern actop follows. This validated the "lowest-effort, most directly transferable"
  prediction: the actop pattern ported with zero bridging.
- **Low Power Mode** (`ProcessInfo.processInfo.isLowPowerModeEnabled`) — **implemented** (same
  commit). Also read in `isUnderPowerPressure` (`:895`) and observed via
  `.NSProcessInfoPowerStateDidChange` (`:495-501`). Same category — public, synchronous, no
  subscription/cleanup lifecycle needed. Note both feed the app's *self-throttling* decision
  (capping its own animation speed), not a displayed metric, but the acquisition pattern is
  identical.
- **Memory pressure / used fraction** (`host_statistics64(HOST_VM_INFO64)` +
  `DispatchSource.makeMemoryPressureSource`): unprivileged Mach call, same tier and style as
  the existing `host_processor_info` CPU reader — no private API. actop reads RAM as an
  instantaneous domain; the macOS equivalent is a point read of `vm_statistics64_data_t`, no
  delta needed. The dispatch memory-pressure source (`.normal`/`.warning`/`.critical`) is a
  tri-state that mirrors `thermalState` almost exactly and slots straight into the existing
  self-throttle path. **This is the highest-value next reader** and the actionable extension
  below specs it out.
- **Swap usage** (`sysctlbyname("vm.swapusage")` → `xsw_usage`): unprivileged sysctl, another
  instantaneous point read (matches actop's swap domain). Cheap, no lifecycle, but lower
  standalone value than memory pressure (swap activity is mostly interesting *alongside*
  memory pressure). Covered together with memory below.
- **GPU / ANE / package power**: still future — would require the same private, undocumented
  `libIOReport.dylib` subscription dance actop performs via ctypes
  (`IOReportCopyChannelsInGroup` → `IOReportCreateSubscription` →
  `IOReportCreateSamples(Delta)`) — reachable from Swift via a C shim or `dlopen`/`dlsym`,
  but it is unheadered private API, version-fragile (actop's own comments flag equivalent
  struct-offset fragility elsewhere in its codebase), and would need to follow actop's
  cache-the-subscription-once and explicit-close lifecycle to avoid the "recreate a
  connection every sample" anti-pattern. This is a materially bigger lift than CPU-tick-delta
  and would need its own design pass (subscription ownership, `close()`/`deinit` wiring,
  what happens if the subscription creation fails outright — fatal at startup like actop, or
  degrade the one feature).
- **Die temperature / fans**: same private-API caveat as above, via SMC (`IOServiceOpen` on
  `AppleSMCKeysEndpoint` + `IOConnectCallStructMethod`), with the added actop-documented
  pattern of *discovering* available sensor keys once at startup and caching that key list
  rather than re-discovering every read.

The two remaining readers (GPU/ANE/power, die-temp/fans) are not being added now — this
section exists so that if/when one is, the acquisition design (privilege model, caching,
unavailable-vs-zero, cleanup lifecycle) has a concrete precedent to follow rather than being
designed from scratch. The thermal/low-power readers above are worked examples of the
public-API tier of that precedent.

---

## Proposed next: memory-pressure and swap readers (the actionable extension)

CPU utilization and load average are the only *quantitative* load signals the app reads today.
Memory pressure is the obvious critical gap: on a memory-constrained Mac the system can be
under heavy load (swapping, compressing, stalling) while CPU% looks unremarkable, so a load
indicator that only watches CPU misreads that state entirely. Both readers below sit in the
same unprivileged Mach/sysctl tier as the existing CPU reader — no private API, no C shim, no
subscription lifecycle — which is why they, not GPU/ANE/fans, are the right next step.

Scope note: this is a spec, not implemented. It exists so the reader can be built to the same
patterns the rest of the file documents rather than designed ad hoc.

### 1. Memory pressure / used fraction (highest value)

Two complementary signals, both unprivileged:

- **Continuous used fraction** — `host_statistics64(mach_host_self(), HOST_VM_INFO64, ...)`
  fills a `vm_statistics64_data_t`. This is the direct sibling of the CPU reader's
  `host_processor_info` call (same privilege tier, same Mach style). Unlike
  `host_processor_info`, the result struct is caller-owned, so there's **no `vm_deallocate`
  to pair with a `defer`** — one fewer cleanup obligation than the CPU path. It's an
  *instantaneous* domain (like actop's RAM read): a point read, **no elapsed-time delta**, so
  the delta-tracking gap noted for the CPU reader doesn't apply here at all.
  - Used fraction: derive "available" from `free_count + purgeable_count + external_page_count`
    (file-backed, reclaimable) and treat the remainder (wired + compressed + anonymous) as in
    use; `used = 1 - available/total`. Multiply page counts by `vm_kernel_page_size`. Pin the
    exact formula in a `Tuning` comment — the "right" definition of memory pressure is a
    judgment call (Activity Monitor's green/yellow/red is not a simple free/total ratio), so
    document which one was chosen and why rather than leaving a bare arithmetic expression.
- **Pressure tri-state** — `DispatchSource.makeMemoryPressureSource(eventMask: [.warning,
  .critical], queue: .main)`, reading `.data` on each event. This is the memory analogue of
  `thermalStateDidChangeNotification`: event-driven, public, tri-state
  (`.normal`/`.warning`/`.critical`), and it should feed the **same `isUnderPowerPressure`
  self-throttle decision** the thermal/low-power readers already feed (`.warning`/`.critical`
  → back off this app's own animation). Wire it exactly like the two existing observers
  (`MenuBarLoadRunner.swift:495-508`): create in `applicationDidFinishLaunching`, store the
  source, cancel it in the same teardown path as the notification observers (`:527`), and
  call `reevaluateSpeedForCurrentConditions()` on change so the cap engages without waiting
  for the next 2s tick.

### 2. Swap — integrated into the memory reader, not standalone

Swap is not a separate reader; it folds into the memory module at two levels.

- **Swap capacity (menu display)** — `sysctlbyname("vm.swapusage", &usage, &size, nil, 0)`
  fills a `struct xsw_usage` (`xsu_total`, `xsu_used`, `xsu_avail`). Unprivileged sysctl,
  instantaneous point read, no lifecycle. Surface it on the *same* menu line as memory
  (e.g. `Memory: 68% · swap 1.2/4.0 GB`), not as its own top-level metric.
- **Swap activity (load signal)** — the pressure-relevant swap quantity is the *rate* of
  swapping, not bytes-in-swap: macOS swaps lazily even when healthy, so a nonzero swap-used is
  a poor pressure signal while active swapin/swapout is a strong one. Crucially, the swap
  *activity* counters (`swapins` / `swapouts`) are **already in the `vm_statistics64_data_t`**
  the used-fraction read above fetches — so integrating swap activity into the memory *load
  signal* costs **zero extra syscalls**: it's a counter-delta on fields already in hand
  (a delta domain, unlike the instantaneous used-fraction). Only the capacity display needs
  the separate `vm.swapusage` sysctl.
- **Composite memory load** — when memory is the selected animation source, combine into one
  0…1 fraction, e.g. `memoryLoad = max(usedFraction, saturating(swapRate))`, so heavy
  swapping pushes the animation even if the raw used-fraction looks moderate. Pin the
  combination in a `Tuning` comment alongside the used-fraction formula.

### How each reading reaches the animation (integration into the render pipeline)

Critical to get right, because the app has **two decoupled pipelines** and load only ever
touches one of them today:

- **`renderedFrames`** (the pixels) — `NSImage`s with sizing + overlay baked in, re-rasterized
  by `updateRenderedFrames()` (`MenuBarLoadRunner.swift:1022`) **only** on width / overlay-text
  / bold changes. System load does *not* feed this pipeline at all.
- **`speedMultiplier`** (the timing) — the `advanceFrames` game loop paces `frameIndex` by
  `baseDelay / speedMultiplier` (`:996`), reading the multiplier live. This scalar is the
  **only** channel from any system reading to the visible animation, and it's fed from exactly
  one function: `speedMultiplier(forUsage:)` (`:878`), which takes a **single** `Double`.

So each proposed reader must choose one of three integration points — there is no fourth:

1. **Pressure tri-state → self-throttle cap (already wired, no rendering change).** The memory
   `DispatchSource` `.warning`/`.critical` plugs into the same path the thermal/low-power
   readers use: flip `isUnderPowerPressure`, which makes `speedMultiplier(forUsage:)` clamp to
   the mid-range ceiling (`:883-886`), applied immediately via
   `reevaluateSpeedForCurrentConditions()`. Lowers `speedMultiplier` → fewer frame advances.
   This *throttles the app's own work*; it does not depict more load. This is the drop-in path
   and needs no new rendering code.
2. **Used-fraction → the load signal itself, via a source selector.**
   `speedMultiplier(forUsage:)` consumes one scalar, so a used-fraction reaches the animation
   only by *becoming* that scalar. Two ways to arbitrate which reading supplies it: blend all
   readers into a composite (`usage = max(cpuUsage, memUsage)` or a weighted mix), or let the
   user pick one active source. **The selector is the chosen design** (see the "load-source
   selector" feature section below) — it sidesteps the composite's judgment-call formula and
   makes the reframe from *CPU* load runner to *system* load runner explicit and
   user-controlled. Until a source other than CPU is selected (and its reader exists), the
   used-fraction is menu-only.
3. **Swap (and, if not driving the composite, mem%) → menu-only.** Displayed via
   `refreshMenuMetrics` (`:627`), zero effect on frames or speed. Safe default.

**Out of scope for this reader spec:** modulating *appearance* by load — tinting frames under
memory pressure, or baking a live mem% into the overlay. That would require
`updateRenderedFrames()` to take a load input and re-rasterize all frames on threshold
crossings, which contradicts the current design (frames re-rasterize only on width/overlay
change, never per-sample) and is materially more expensive. It's a separate feature, not part
of adding these readers.

### Applying the documented patterns to these readers

- **Unavailable vs. zero** (the pattern the CPU reader already nails): both must return `nil`,
  never a fabricated `0`, when `host_statistics64` / `sysctlbyname` returns non-`KERN_SUCCESS`
  / non-zero. "0% memory used" and "0 bytes swap" are legitimate healthy readings and must be
  visually distinct from "couldn't read" — reuse the existing "warming up…" / "unavailable"
  menu convention (`:637-638`, `:660`).
- **Asymmetric error handling** (previously "not applicable at this scale"): adding a second
  and third independent reader makes this **live for the first time**. A failed memory or swap
  read must degrade *only that field* — the CPU animation, the whole point of the app, must
  keep running. Do not let a memory-reader failure throw past the CPU path. Conversely there's
  still no subsystem here whose absence should be fatal at startup (that asymmetry only arrives
  with the private-API tier).
- **No EMA in the reader** — same call as the CPU reader: the memory *used-fraction* feeds the
  menu (and possibly a future visual signal), so if it ever drives animation it may warrant
  the same deliberate EMA the CPU path uses; the *pressure tri-state* and swap are discrete /
  point values and must **not** be smoothed. Keep any smoothing a conscious per-consumer
  choice, mirrored on the CPU reader's rationale, not a default.
- **Where it lives** — the continuous used-fraction reader is a natural sibling to
  `CPULoadMonitor` (either a peer `MemoryLoadMonitor` `@MainActor` class or a second method on
  a renamed monitor); the pressure tri-state belongs with the power/thermal observers, not the
  sampling monitor, since it's event-driven and feeds `isUnderPowerPressure`. Menu wiring goes
  through the existing `refreshMenuMetrics` refresh-on-open path (`:627-662`), not a reactive
  push, to match how every other metric is displayed.

---

## Feature: animation load-source selector (CPU / GPU / memory / network / disk)

A menu control to switch **which reader drives the animation speed**: CPU, GPU, memory,
network, or disk I/O. This is the concrete arbitration mechanism referenced in integration
point #2 above — instead of blending readers into a composite, the user picks one active
source. Default `cpu` (today's behavior, unchanged). (Swap is not a selector source — it folds
into the memory source per the swap section above.)

### Semantics: a radio group, not independent checkboxes

Only one source drives the animation at a time, so despite being drawn as checkmark items this
is a **mutually-exclusive (radio) group** — exactly what the width submenu already does with
`widthAutoItem`/`widthSlotItems` (`MenuBarLoadRunner.swift:687-690`) and the preset list does
with `presetMenuItems` (`:664-670`): one item `.on`, the rest `.off`. It is *not* a set of
independent toggles (two sources both "on" has no meaning for a single-scalar speed input).

### Menu + selection wiring (mirror the width/preset pattern exactly)

- A **"Load Source" submenu** with one checkmark item per source, built alongside the width
  submenu in `applicationDidFinishLaunching` (`:404-424` is the template), stored as
  `loadSourceMenuItems: [NSMenuItem]` with the source encoded in `.tag`.
- A `refreshLoadSourceSelectionState()` that sets `item.state = (item.tag == activeLoadSource)`
  and is called from `menuWillOpen` next to the other four refreshers (`:620-624`) — selection
  state is pulled on open, never pushed, matching every other menu control.
- An `@objc selectLoadSource(_ sender: NSMenuItem)` action mirroring `selectPreset` (`:704-709`)
  / `selectWidthSlot` (`:719-725`): set `activeLoadSource`, then call
  `reevaluateSpeedForCurrentConditions()` (`:906`) so the switch takes effect **immediately**,
  bypassing the 2s-tick hysteresis, the same way preset switches re-derive on the spot.
- The active source also belongs in the speed line of `refreshMenuMetrics` (`:642-655`), e.g.
  `Speed Multiplier (auto CPU horse 1.0x..3.0x): 1.8x`, so the dashboard shows *what* is
  driving the animation, not just the resulting multiplier.

### Model, CLI, and config

- `enum LoadSource { case cpu, gpu, memory, network, disk }` with a `key` (`"cpu"`/`"gpu"`/…)
  and a menu title, following `PresetKind`/`PresetDescriptor`'s single-registry approach so the
  CLI keyword, menu item, and selection checks all derive from one source of truth.
- `activeLoadSource: LoadSource` on the app (default `.cpu`).
- A `--load-source <cpu|gpu|memory|network|disk>` CLI flag plus
  `MENUBAR_LOAD_RUNNER_LOAD_SOURCE` env fallback, parsed in `Config` next to the preset keyword
  (`:95-162`). Unknown value → fall back to `.cpu`, don't fail launch.

### The single-scalar contract each source must satisfy

`speedMultiplier(forUsage:)` (`:878`) expects a **0…1 fraction**. Each source is a
`() -> Double?` that returns a normalized fraction or `nil` (unavailable / warming up):

- **CPU** — already have it: `CPULoadMonitor.sampleUsage()`, natively 0…1. Counter-delta domain.
- **Memory** — the used-fraction from the `host_statistics64` reader specced above, natively
  0…1. Instantaneous domain (no delta).
- **GPU** — utilization %, natively 0…1. Available **unprivileged** from IORegistry:
  match `IOAccelerator`/`IOAcceleratorClass` and read `PerformanceStatistics` →
  `"Device Utilization %"`. This does *not* need the private IOReport dance (that's only for
  GPU *power*, not utilization), so GPU-utilization is a lighter lift than the "GPU/ANE/power"
  bullet in the survey above implies — worth splitting: utilization = unprivileged IORegistry,
  power/energy = private IOReport. Instantaneous point read.
- **Network** — throughput has **no natural 0…1 domain**, which makes it the awkward one.
  Read per-interface byte counters via `getifaddrs` → `if_data.ifi_ibytes/ifi_obytes`
  (unprivileged), delta over **real elapsed wall-clock time** → bytes/sec, then map to 0…1 via
  a saturating scale (e.g. against a configurable nominal link speed in `Tuning`, or an
  adaptive running peak). Two consequences: (a) the normalization curve is a judgment call to
  document, and (b) **this is the reader that finally makes actop's real-elapsed-time-delta
  pattern mandatory** — the one the comparison table flagged as a "low-priority gap" for CPU
  (ratio math didn't need it) is a hard requirement here, because bytes/sec is meaningless
  without dividing by actual elapsed time. Use a monotonic clock between samples, not the
  nominal 2s interval.
- **Disk I/O** — network's twin; same tier, same shape. Read cumulative bytes from IOKit:
  `IOServiceGetMatchingServices` for `IOBlockStorageDriver`, then each driver's `Statistics`
  dict → `"Bytes (Read)"` / `"Bytes (Write)"`, summed across drivers (unprivileged IORegistry
  read, no IOReport). Same **counter-delta over real elapsed wall-clock time** → bytes/sec, and
  the same **no-natural-0…1** problem → saturating scale against a `Tuning` reference (or
  adaptive peak). It shares network's normalization and elapsed-time machinery; the only
  difference is the source (IOKit block-storage class vs `getifaddrs`). Counter-delta domain.

- **Sampling** happens on the existing `loadSampleInterval` tick in `sampleSystemLoad`
  (`:603-618`). Sample the **active** source to drive the animation; sampling the inactive
  ones too (for menu display) is optional and cuts against the app's self-throttle ethos, so
  prefer active-only. Note the counter-delta sources (CPU, network, disk) need a warm-up tick
  after a switch before they can produce a value — reuse the existing "warming up…" state per
  source. (Memory used-fraction and GPU utilization are instantaneous, so they read on the
  first tick.)
- **Availability / disable** — a source with no reader available (no discrete GPU, `getifaddrs`
  fails, IORegistry key absent) must show its menu item **disabled**, exactly as
  `refreshPresetSelectionState` disables a preset whose file is missing (`item.isEnabled =
  fileExists`, `:667`). `nil`-not-zero applies: an unavailable GPU is disabled, not "0%".
- **Runtime fallback** — if the *active* source becomes unavailable (or was selected via CLI
  but isn't present), fall back to `.cpu` rather than freezing the animation on a stale
  multiplier. This is the **asymmetric-error-handling** pattern made concrete: one reader going
  dark degrades gracefully to CPU; it never takes down the animation.

### Orthogonality to presets

The load *source* is independent of the preset's `SpeedProfile`. Selecting a source changes
*which 0…1 value* is mapped through the active preset's min/max/exponent — it does **not**
change the speed range. A `raining` preset keeps its eased curve and its
`rainingSpeedMin..Max` whether driven by CPU or network; only the input fraction changes. No
per-source `SpeedProfile` is needed.
