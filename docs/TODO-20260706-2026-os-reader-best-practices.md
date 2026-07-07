# OS reader best practices — cross-review vs. `actop`

Cross-review of `~/workspace_fullstack/actop` (a sudoless Apple Silicon performance monitor,
Python + ctypes) against this repo's `CPULoadMonitor` (`MenuBarLoadRunner.swift:157-225`),
to extract transferable best practices for reading OS/hardware metrics. Documentation only —
no code changes made as part of this review. Date: 2026-07-06.

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

`CPULoadMonitor` (`MenuBarLoadRunner.swift:157-225`) reads total CPU utilization via Mach's
`host_processor_info(PROCESSOR_CPU_LOAD_INFO)`, and `MenuBarLoadRunnerApp` separately reads
`getloadavg()` for the 1/5/15m averages (`readSystemLoadAverages()`, lines 837-848).

| Pattern | actop | `CPULoadMonitor` | Assessment |
|---|---|---|---|
| Unprivileged API | Yes (IOReport subscription, not `powermetrics`) | Yes (`host_processor_info` is a standard unprivileged Mach call) | Already aligned — no sudo dependency in either. |
| Cache expensive setup once | Yes (subscription created once) | N/A — `host_processor_info` has no setup/subscription step to cache; each call is already cheap and self-contained | No gap; the pattern doesn't apply here since there's nothing to cache. |
| Real elapsed-time delta | Yes (`time.monotonic()` between samples) | Partial — deltas the *tick counts* between two `host_processor_info` calls (a counter, correct), but never measures the *wall-clock* time between those two calls. Since the CPU tick counters and the 2-second `loadTimer` interval are decoupled, this works out numerically the same either way (it's a ratio of ticks, not ticks/second), so this isn't a bug — but it does mean the code has no explicit record of "how much real time this sample actually covers," which actop's model treats as necessary for correctness under a jittery timer. | Low-priority gap — current math is correct for a ratio-based CPU fraction; would only matter if the sampling interval became irregular and something needed to normalize *to* real time rather than just a fraction. |
| Unavailable vs. zero | Partial — `sampleUsage()`/`currentUsage()` correctly return `nil` (not `0.0`) when there's no prior sample yet or the Mach call fails (`MenuBarLoadRunner.swift:166,189,216-218,222`), and `refreshMenuMetrics()` shows "warming up..." rather than a fake `0%` (`:566-572`). `readSystemLoadAverages()` does the same — `nil` on failure, "unavailable" shown in the menu (`:589-591`). | **Already follows this pattern correctly for both readers in the file.** |
| Asymmetric error handling | Yes | Not really applicable at this scale — there's only one subsystem (CPU), so there's no "one sensor missing, rest still fine" case to design for yet. If this expands to multiple independent readers (see below), the asymmetric-degradation pattern becomes directly relevant. | No current gap; becomes relevant only if/when more readers are added. |
| Explicit resource cleanup | Yes (open/close, try/finally around releases) | N/A today — `host_processor_info`'s only resource is the `cpuInfo` buffer, already released via a `defer { vm_deallocate(...) }` immediately after use (`:191-194`), which is the correct Swift-native equivalent of actop's try/finally-around-CFRelease pattern. | **Already follows this pattern.** |
| No EMA in reader layer | actop avoids it entirely | `CPULoadMonitor` applies EMA smoothing (`Tuning.cpuSmoothingAlpha = 0.2`, `:173`) | Divergence, not a gap — the Swift app's EMA is a deliberate design choice for a *visual* animation speed signal where jitter is undesirable, whereas actop's readers feed a numeric dashboard/profiler where raw values (or plain averaging) are more useful for analysis. Neither is "more correct" in the abstract; they're serving different consumers. No change indicated. |

**Bottom line**: `CPULoadMonitor` already independently arrived at several of actop's core
correctness patterns (unprivileged API, `nil`-for-unavailable rather than fabricated zero,
explicit buffer cleanup via `defer`). The one true gap — not tracking real elapsed wall time
between samples — is low priority because the current ratio-based math doesn't actually need
it. There is no current deficiency worth a TODO item on its own.

---

## Where the patterns would matter: extending to other system-load readers

Not scoped for implementation now (see below), but the patterns above map directly onto any
future reader this app might add, roughly in order of how directly they'd port to Swift:

- **Thermal pressure** (`ProcessInfo.processInfo.thermalState`): a public Swift/Foundation
  API, mirrors actop's `NSProcessInfo.thermalState` read (`native_sys.py:208-221`) almost
  exactly — no ctypes/private-API bridging needed at all, same unprivileged-public-API
  pattern actop follows. Lowest-effort, most directly transferable.
- **Low Power Mode** (`ProcessInfo.processInfo.isLowPowerModeEnabled`): same category — public,
  synchronous, no subscription/cleanup lifecycle needed.
- **GPU / ANE / package power**: would require the same private, undocumented
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

None of these are being added now — this section exists so that if/when one is, the acquisition
design (privilege model, caching, unavailable-vs-zero, cleanup lifecycle) has a concrete
precedent to follow rather than being designed from scratch.
