# ARCHITECTURE — As-Built System Architecture & Technical Specifications

> **Canonical as-built architecture document for MenuBar Load Runner (v1.22.0).**
> **Source ground truth:** `MenuBarLoadRunner.swift`, `menubar-load-runner` (launcher), `gifs/presets.json`.
> **Scope:** Complete architectural specifications, subsystem topologies, concurrency models, telemetry algorithms, and system invariants.

---

## 1. System Topology & Architectural Philosophy

MenuBar Load Runner is a single-file, unbundled native macOS menu bar application written in Swift and AppKit. It visualizes real-time hardware telemetry by driving the playback rate of an animated status-bar GIF and providing an integrated live diagnostic dashboard with built-in sleep inhibition.

```
                                    ┌────────────────────────┐
                                    │  menubar-load-runner   │
                                    │     (Zsh Launcher)     │
                                    └───────────┬────────────┘
                                                │ fork/exec / singleton guard
                                                ▼
┌────────────────────────────────────────────────────────────────────────────────────────────────────────┐
│                                       MenuBarLoadRunner (Swift)                                        │
│                                                                                                        │
│  ┌───────────────────────┐   ┌───────────────────────┐   ┌──────────────────────────────────────────┐  │
│  │   Config / StateStore │   │   CADisplayLink /     │   │      Telemetry Subsystems (8 Readers)    │  │
│  │  (CLI/Env/state.json) │   │     Timer (60Hz)      │   │  Mach / IORegistry / SMCClient / IOKit   │  │
│  └───────────┬───────────┘   └───────────┬───────────┘   └────────────────────┬─────────────────────┘  │
│              │                           │                                    │                        │
│              ▼                           ▼                                    ▼                        │
│  ┌───────────────────────┐   ┌───────────────────────┐   ┌──────────────────────────────────────────┐  │
│  │  Status Bar Items     │   │  Render Pipeline      │   │  ThroughputScaler / Hysteresis Logic     │  │
│  │  • Animation Item     │◄──┤  • Transparent Trim   │◄──┤  • Exponential Moving Average (EMA)      │  │
│  │  • Left/Right Label   │   │  • Aspect-Ratio Sizing│   │  • Adaptive Window Rate Normalization    │  │
│  │  • KeepAwake CALayer  │   │  • Vsync Game Loop    │   │  • Self-Throttling (Occlusion/Power/RM)  │  │
│  └───────────┬───────────┘   └───────────────────────┘   └──────────────────────────────────────────┘  │
│              │                                                                                         │
│              ▼                                                                                         │
│  ┌──────────────────────────────────────────────────────────────────────────────────────────────────┐  │
│  │                                  Interactive Dropdown Dashboard                                  │  │
│  │  • LoadHistoryView (60s Sparkline)   • Load Averages (1/5/15m)   • Active / Other Sources Readout │  │
│  │  • Keep Awake Control & Presets      • IOPMCopyAssertionsByProcess (Machine Assertion Inspector) │  │
│  │  • Settings Submenu                  • Preset Switcher           • Self-Update (UpdateChecker)   │  │
│  └───────────────────────────────────────────────┬──────────────────────────────────────────────────┘  │
│                                                  │                                                     │
└──────────────────────────────────────────────────┼─────────────────────────────────────────────────────┘
                                                   │ spawns & binds PID
                                                   ▼
                                    ┌────────────────────────┐
                                    │ caffeinate -di -w <pid>│
                                    │    (SleepPreventer)    │
                                    └────────────────────────┘
```

### Core Design Tenets

1. **Read-Only Telemetry & Self-Throttling:** The application observes the system without modifying system settings or CPU governors. When system load or thermal conditions escalate, the application throttles its own rendering footprint to avoid exacerbating contention.
2. **Zero-Xcode Single-File Architecture:** The entire runtime resides in `MenuBarLoadRunner.swift` (~6.6k lines) compiled via `swiftc` with complete concurrency checking (`-strict-concurrency=complete`).
3. **No Mocks / Non-Privileged Execution:** Every metric is collected via unprivileged public Mach, IOKit, and SMC APIs without root privileges, background daemons, or kernel extensions.
4. **Jitter-Free Menu Bar Real Estate:** Status item widths are strictly reserved using figure-space padding (U+2007) and monospaced digits, ensuring that value oscillations never cause lateral layout jitter.

---

## 2. Launcher & Compilation Lifecycle

Execution is governed by the `menubar-load-runner` zsh script, which manages compilation, process singletons, and detached execution.

```
                      ┌────────────────────────────┐
                      │     Execution Request      │
                      └─────────────┬──────────────┘
                                    │
                                    ▼
                      ┌────────────────────────────┐
                      │  Per-User Singleton Check  │
                      │   (pgrep -U <uid> -f ...)  │
                      └─────────────┬──────────────┘
                                    │
                      ┌─────────────┴──────────────┐
             Instance Running?             No Instance Running
                      │                            │
                      ▼                            ▼
         [Exit with notice / --extra]   ┌────────────────────────────┐
                                        │ Is Source Newer than Mach-O│
                                        └─────────────┬──────────────┘
                                                      │
                                           ┌──────────┴──────────┐
                                         Stale                Up to date
                                           │                     │
                                           ▼                     │
                                ┌───────────────────────────┐    │
                                │   swiftc -O -strict-      │    │
                                │   concurrency=complete    │    │
                                │   -o MenuBarLoadRunner.new│    │
                                └──────────┬────────────────┘    │
                                           │                     │
                                           ▼                     │
                                ┌───────────────────────────┐    │
                                │ rename(2) atomically over │    │
                                │    MenuBarLoadRunner      │    │
                                └──────────┬────────────────┘    │
                                           │                     │
                                           ├─────────────────────┘
                                           ▼
                                ┌───────────────────────────┐
                                │ Launch Process (Detached  │
                                │      or Foreground)       │
                                └───────────────────────────┘
```

### Compilation Mechanics

- **Atomic Rename:** When compiling, the launcher outputs to `MenuBarLoadRunner.new` before invoking `mv` (`rename(2)`) over `MenuBarLoadRunner`. This guarantees that an existing live process paging from the Mach-O binary does not crash during a rebuild.
- **Precompilation Hook (`--precompile`):** Exposes the compilation branch without launching the process. Used by the in-app self-updater to build newly pulled source code while the current instance remains live.
- **Strict Concurrency Safety:** Compiled with Swift 5 `-strict-concurrency=complete`. All UI and state-managing classes are annotated `@MainActor`.
- **Interpreted Fallback:** If `swiftc` compilation fails or toolchain elements are unavailable, the launcher falls back to interpreted execution via `swift MenuBarLoadRunner.swift`.

---

## 3. Rendering Pipeline & Game Loop Engine

The visualizer transforms raw GIF frames into an aspect-ratio-fitted, vsync-aligned status bar animation.

### 3.1 Transparent Padding Trimming (`trimTransparentPadding`)

Many raw pixel-art GIFs contain uniform transparent margins. At initialization:
1. Every frame in the GIF is scanned at the raw pixel level (`CGImage` provider).
2. Alpha components below `Tuning.alphaVisibleThreshold` (3) are treated as transparent.
3. A single union bounding box is computed across all frames to prevent frame-to-frame shifting.
4. Frames are cropped to this union bounding box, deriving the canonical aspect ratio (`currentGifAspect`).

### 3.2 Dynamic Aspect & Slot Length Derivation

Width is not a fixed constant. It is derived at runtime:
$$\text{slotLength} = \max\left(\text{menuBarHeight} \times \text{clamp}(\text{aspect}, \text{minAspect}, \text{maxIconAspect}), \text{minBaseSlotWidth}\right)$$
- `Tuning.minAspect` = `0.01`
- `Tuning.maxIconAspect` = `6.0`
- `Tuning.minBaseSlotWidth` = `18.0 pt`
- Sizing is refreshed whenever a new GIF preset is loaded via `applySizing()`, triggering `updateRenderedFrames()`.

### 3.3 Vsync-Aligned Game Loop

On macOS 14+, the animation is driven by a `CADisplayLink` bound to the status item's button view (`NSView.displayLink(target:selector:)`). On older macOS releases, a 60 Hz fallback `Timer` (`Tuning.gameLoopFallbackInterval`) is used.

```swift
// Abridged from MenuBarLoadRunner.advanceFrames(now:) — elided: the empty-frames guard
// and the first-tick latch (lastTickTime == 0 returns without advancing).
let delta = now - lastTickTime
lastTickTime = now
// A backwards jump or a gap larger than maxFrameAdvanceDelta is DROPPED, not replayed and
// not resynced here: the next tick simply resumes from the current frame.
guard delta > 0, delta <= Tuning.maxFrameAdvanceDelta else { return }

accumulatedFrameTime += delta
var advanced = false
while true {
    let baseDelay = baseDurations[frameIndex]                              // this frame's GIF delay
    let requiredDelay = max(baseDelay / speedMultiplier, Tuning.minGifFrameDelay)
    if accumulatedFrameTime >= requiredDelay {
        accumulatedFrameTime -= requiredDelay
        frameIndex = (frameIndex + 1) % baseDurations.count
        advanced = true
    } else { break }
}
if advanced { renderCurrentFrame() }                                        // layer.contents = image
```

- **Speed is a divisor on each frame's own delay**, not a multiplier on elapsed time, and the result
  floors at `Tuning.minGifFrameDelay` (0.02s) so a fast preset can't outrun the display link.
- **`speedMultiplier` is read live**, so a speed change takes effect on the next tick without
  restarting the driver.
- **Sleep/Occlusion gaps are dropped, not replayed:** a delta over `Tuning.maxFrameAdvanceDelta` (1.0s) — sleep, occlusion, a clock jump — returns without advancing, so the animation resumes from the current frame instead of catching up in a burst. An explicit `resetGameLoopTiming()` exists for the *frame-source switch* and driver-(re)start paths, not for this one.

---

## 4. Hardware Telemetry & Scaling Subsystems

The application includes eight unprivileged telemetry monitors sampling system state every 2 seconds (`Tuning.loadSampleInterval`).

```
┌────────────────────────────────────────────────────────────────────────────────────────┐
│                                   Telemetry Monitors                                   │
├────────────────────────┬───────────────────────────┬───────────────────────────────────┤
│ Monitor Class          │ Primary Kernel/Mach API   │ Normalization / Scaling Model     │
├────────────────────────┼───────────────────────────┼───────────────────────────────────┤
│ CPULoadMonitor         │ host_processor_info()     │ Exponential Moving Average (EMA)  │
│ MemoryLoadMonitor      │ host_statistics64()       │ Composite: max(RAM%, ScaledSwap)  │
│ GPULoadMonitor         │ IORegistry IOAccelerator  │ Direct Percentage (0.0 .. 1.0)    │
│ SMCClient (Fan)        │ AppleSMCKeysEndpoint      │ RPM / Max RPM (Average of Fans)   │
│ SMCClient (Temp)       │ AppleSMCKeysEndpoint      │ Fixed 30°C .. 100°C Window        │
│ NetworkLoadMonitor     │ getifaddrs() (AF_LINK)    │ ThroughputScaler (Bytes/Sec)      │
│ DiskLoadMonitor        │ IOBlockStorageDriver      │ ThroughputScaler (Bytes/Sec)      │
│ BatteryLoadMonitor     │ IOKit Power Sources       │ ThroughputScaler (Discharge mA)   │
└────────────────────────┴───────────────────────────┴───────────────────────────────────┘
```

### 4.1 CPU Load Monitoring (`CPULoadMonitor`)

- Mach call: `host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, ...)`.
- Computes tick deltas across all system cores:
  $$\Delta \text{total} = \Delta \text{user} + \Delta \text{system} + \Delta \text{nice} + \Delta \text{idle}$$
  $$\text{rawFraction} = \frac{\Delta \text{user} + \Delta \text{system} + \Delta \text{nice}}{\Delta \text{total}}$$
- Smoothed via EMA with smoothing factor $\alpha = 0.20$ (`Tuning.cpuSmoothingAlpha`):
  $$\text{smoothedUsage}_t = \alpha \times \text{rawFraction} + (1 - \alpha) \times \text{smoothedUsage}_{t-1}$$

### 4.2 Composite Memory & Swap Monitoring (`MemoryLoadMonitor`)

- **RAM Used Fraction:** Derived from `host_statistics64(HOST_VM_INFO64)` — measured from what is
  *reclaimable*, not from a sum of "used" buckets, which is why it reads higher than Activity Monitor
  (a deliberate approximation, documented at the call site):
  $$\text{availablePages} = \text{free\_count} + \text{purgeable\_count} + \text{external\_page\_count}$$
  $$\text{rawFraction} = 1 - \frac{\text{availablePages} \times \text{pageSize}}{\text{totalPhysicalRAM}}$$
  $$\text{adjustedRAMFraction} = \frac{\max(0, \text{rawFraction} - \text{memoryIdleFloor})}{1.0 - \text{memoryIdleFloor}}$$
  (`Tuning.memoryIdleFloor` = `0.55`, compensating for OS cache retention).
- **Swap Paging Rate:** Measures delta of `swapins` + `swapouts` over elapsed wall time $\Delta t$, normalized through `ThroughputScaler` (`swapFloorBytesPerSec` = 1 MiB/s).
- **Composite Driver:**
  $$\text{currentMemoryLoad} = \max(\text{adjustedRAMFraction}, \text{scaler.scale}(\text{swapRateBytesPerSec}))$$

### 4.3 SMC Sensor Architecture (`SMCClient`)

`SMCClient` is a thread-safe singleton communicating with `AppleSMCKeysEndpoint` using the standard 80-byte `SMCKeyData` protocol structure.

```
                          ┌───────────────────────────┐
                          │   SMCClient.ensureOpen()  │
                          │   IOServiceOpen("AppleSMC")│
                          └─────────────┬─────────────┘
                                        │
                                        ▼
                          ┌───────────────────────────┐
                          │ Discover Key Count (#KEY) │
                          └─────────────┬─────────────┘
                                        │
                                        ▼
                          ┌───────────────────────────┐
                          │ Binary Search Key Table   │
                          │   for Target Prefix (Tp*) │
                          └─────────────┬─────────────┘
                                        │ ~115 calls (20ms) vs 3385 full scan (600ms)
                                        ▼
                          ┌───────────────────────────┐
                          │ Filter & Read Sensor Data │
                          │ (Command 8 / readBytes)   │
                          └───────────────────────────┘
```

- **Binary Search Key Table Discovery:** Instead of sequential table scans (~600ms) or guesswork, `SMCClient.floatKeys(withPrefix:)` uses binary search across the ascending SMC key table (~20ms), discovering dynamic fan (`F{n}Ac`) and temperature (`Tp**`) keys across Intel and Apple Silicon chips.
- **Die Temperature Mapping:** Reads hottest cluster maxima (`Tpx*` cluster maximum sensors on Apple Silicon). Bounded strictly between $30^\circ\text{C}$ and $100^\circ\text{C}$ (`Tuning.temperatureFloorCelsius` to `temperatureCeilingCelsius`):
  $$\text{loadFraction} = \text{clamp}\left(\frac{T_{\text{max}} - 30.0}{100.0 - 30.0}, 0.0, 1.0\right)$$

### 4.4 The Adaptive `ThroughputScaler` (btop Hysteresis)

For unbounded rates (network bytes/sec, disk bytes/sec, swap bytes/sec, battery discharge mA), `ThroughputScaler` provides jitter-free normalization:

1. **Sliding Window Ceiling:** Computes rolling average over the last $N=5$ samples (`Tuning.scalerWindow`).
2. **Asymmetric Headroom:**
   - Headroom Up: $1.3\times$ (`Tuning.scalerHeadroomUp`)
   - Headroom Down: $3.0\times$ (`Tuning.scalerHeadroomDown`)
3. **Hysteresis Counters:** Rescaling requires $5$ consecutive out-of-band samples (`Tuning.scalerRescaleCount`) tracked in `overCount` and `underCount` registers, preventing single bursts from oscillating the display.

---

## 5. Power Management, Occlusion & Accessibility

The engine reduces its own footprint under thermal or battery strain.

```
                                  ┌──────────────────────────┐
                                  │   Environmental Event    │
                                  └────────────┬─────────────┘
                                               │
              ┌────────────────────────────────┼────────────────────────────────┐
              │                                │                                │
              ▼                                ▼                                ▼
   [Occlusion State Change]       [Thermal / Power / Memory]         [Reduce Motion Toggle]
 (NSWindow Occlusion Notification)  (ProcessInfo / DispatchSource)   (NSWorkspace / Menu Toggle)
              │                                │                                │
              ▼                                ▼                                ▼
    Is Fully Occluded?              Is Under Power Pressure?             Is Animation Frozen?
     • Notch Coverage               • Low Power Mode                     • System Reduce Motion
     • Inactive Space               • Thermal Serious/Critical           • Manual Settings Toggle
     • Display Sleep                • Memory Warning/Critical                   │
              │                                │                                │
              ▼                                ▼                                ▼
    Halt Game Loop (0% CPU)         Cap Speed Multiplier             syncGameLoopRunning():
    Resume when visible             at Preset Midpoint (0.5×)        Hold frame, handoff to label
```

### 5.1 Occlusion Pausing (0% CPU)

- Listens for `NSWindow.didChangeOcclusionStateNotification` on the status item window.
- When `occlusionState` does not contain `.visible` (e.g. hidden behind a MacBook notch, displaced by menu bar crowding, situated on an inactive macOS Space, or display asleep), the `CADisplayLink` / `Timer` is stopped completely.
- Frame rendering and rasterization drop to **0.0% CPU**.

### 5.2 Power, Thermal & Memory Throttling

- **Triggers:**
  - `NSProcessInfo.isLowPowerModeEnabled` (`.NSProcessInfoPowerStateDidChange`)
  - `ProcessInfo.thermalState` is `.serious` or `.critical` (`ProcessInfo.thermalStateDidChangeNotification`)
  - Memory Pressure is `.warning` or `.critical` (`DispatchSource.makeMemoryPressureSource`)
- **Action:** Speed multiplier is capped at `Tuning.constrainedSpeedCeilingFraction` ($0.5\times$ range midpoint). Immediate recalculation bypasses standard 2s hysteresis.

### 5.3 Reduce Motion & Manual Freeze

- **System Accessibility:** Listens for `NSWorkspace.accessibilityDisplayOptionsDidChangeNotification` to observe `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion`.
- **Manual Toggle:** `Settings ▸ Freeze Animation` (persisted in `state.json`).
- **Unified Decider (`syncGameLoopRunning()`):** If either system reduce motion or manual freeze is active, the game loop stops, holding the current frame.
- **Label Handoff:** While frozen, if the menu bar label is configured to `off`, it automatically switches to `.value` mode temporarily so the user still receives live telemetry.

---

## 6. Status Bar Layout & Dual-Slot Label Model

To prevent lateral jitter and enable flexible placement, the application implements a dual status-item architecture.

```
                           macOS Menu Bar Item Creation Order
                   (Oldest Created = Rightmost Placement on Screen)
                   
          ┌─────────────────────┬─────────────────────┬─────────────────────┐
          │   labelItemRight    │     statusItem      │    labelItemLeft    │
          │   (Status Item 1)   │   (Status Item 2)   │   (Status Item 3)   │
          │   Created First     │   Created Second    │   Created Third     │
          └──────────┬──────────┴──────────┬──────────┴──────────┬──────────┘
                     │                     │                     │
                     ▼                     ▼                     ▼
          [Right Slot (Active)]    [Animated GIF Art]   [Left Slot (Hidden)]
              length = 87 pt         length = 47 pt         length = 0 pt
```

### 6.1 Fixed-Width Reservation & Jitter Elimination

Auto-sizing status items causes neighboring items to jitter on every telemetry update. MenuBar Load Runner guarantees $0\text{ pt}$ jitter:
1. **Monospaced Digits:** Uses `NSFont.monospacedDigitSystemFont(ofSize:weight:)`.
2. **Figure Space Padding (U+2007):** Padded with U+2007 (whose glyph width exactly matches numeric digits):
   ```swift
   func labelField(_ value: Double, ceiling: Double, decimals: Int) -> String
   ```
3. **Reserved Template Width (`labelSlotWidth`):** Computes maximum string dimension based on worst-case template bounds + `Tuning.labelSlotPadding` (4 pt). Slot length is fixed to this reservation.

### 6.2 Left/Right Placement Architecture

macOS orders status items right-to-left based on creation time with no reordering API. To allow dynamic side switching at runtime without rebuilding the animation layer:
- Two label items are allocated at launch: `labelItemRight` (before animation item) and `labelItemLeft` (after animation item).
- The active side gets the computed reservation length; the inactive side is collapsed to `length = 0`.

---

## 7. Integrated Sleep Prevention (`SleepPreventer`) & Assertion Monitor

Sleep inhibition integrates directly into the visualizer while observing system-wide power management.

```
                                  ┌──────────────────────────┐
                                  │   User Arms Keep Awake   │
                                  └────────────┬─────────────┘
                                               │
                                               ▼
                                  ┌──────────────────────────┐
                                  │ StateStore Persists      │
                                  │ Target Deadline (JSON)   │
                                  └────────────┬─────────────┘
                                               │
                                               ▼
                                  ┌──────────────────────────┐
                                  │  Evaluate Safety Release │
                                  └────────────┬─────────────┘
                                               │
               ┌───────────────────────────────┴───────────────────────────────┐
               │                                                               │
               ▼                                                               ▼
   [Battery ≤ 5% Hard Floor OR]                                    [Safe Operating State]
   [Battery ≤ Configured Threshold without Override]                           │
               │                                                               ▼
               ▼                                                   ┌───────────────────────────┐
   KeepAwake Suspended / Paused                                    │ Spawns Subprocess:        │
   (caffeinate terminated, intent kept)                            │ caffeinate -di -w <pid>   │
                                                                   │            -t <seconds>   │
                                                                   └───────────────────────────┘
```

### 7.1 Child Process Binding & Intent Separation

- **Subprocess Execution:** Spawns `/usr/bin/caffeinate -di -w <app_pid> [-t <seconds>]`.
- **Display + Idle Sleep:** Uses `-di` (preventing display and idle sleep).
- **Intent vs Running State:** `SleepPreventer` maintains `isEnabled` (user intent) separately from `isRunning` (child process active). When suspended by low battery or thermal events, intent remains set, and the child respawns automatically when conditions normalize.

### 7.2 Safety Floor & Configurable Thresholds

- **Configurable Battery Release:** Defaults to 20% (`Tuning.batteryLowThresholdDefault`), adjustable via CLI `--battery-threshold` or menu. The accepted range is **6%–100%** (`Tuning.batteryThresholdMin`…`batteryThresholdMax`), or `Never` / `0`; the menu offers 10 / 15 / 20 / 30% as rows plus `Custom…` for any whole percent in range. The minimum sits **above** the 5% floor on purpose, so no setting can reach it.
- **5% Hard Critical Floor:** `Tuning.batteryCriticalThreshold` (0.05). If battery drops to $\le 5\%$, all sleep assertions release immediately, overriding manual user overrides.
- **Low Battery Override:** Arming Keep Awake while already below the threshold sets `keepAwakeBatteryOverride`, honoring user intent down to the 5% hard floor.

### 7.3 System Assertion Telemetry (`SleepAssertionMonitor`)

Reads machine-wide power management state via `IOPMCopyAssertionsByProcess`:
- **Noise Filtering:** `Tuning.assertionNoiseOwners` is **two named exceptions**, `powerd` and `WindowServer` — not an is-a-daemon test. (`powerd`'s assertion is literally "Prevent sleep while display is on", so it is present whenever anyone could read the menu.) `backupd` and `sharingd` are signal and must keep showing; don't grow this list into a policy.
- **Display vs Idle Classification:** Isolates display sleep assertions (`PreventUserIdleDisplaySleep`, `NoDisplaySleepAssertion`) from idle-only assertions.
- **Machine Hold State (`AwakeHold`):** Determines if any external application is keeping the Mac awake, reporting holder name and scheduled release times in the menu.
- **3-Tier Visual Indicator:**
  1. Full Tone ($1.0\alpha$): App's own sleep hold running.
  2. Foreign Tone ($0.45\alpha$, `keepAwakeBarForeignAlpha`): Mac held awake by an external process.
  3. Paused Tone ($0.22\alpha$, `keepAwakeBarPausedAlpha`): Armed but suspended due to battery/thermal conditions.

---

## 8. In-Menu Dashboard & State Persistence

### 8.1 Live Sparkline View (`LoadHistoryView`)

- Implemented as an `NSView` inside the status dropdown menu.
- Holds a circular buffer of 30 samples $\times$ 2s tick $\approx$ 60 seconds of history (`Tuning.loadHistoryCapacity`).
- Draws color-coded vertical bars:
  - Green: Load $< 0.30$ (`Tuning.cpuStateLowThreshold`)
  - Yellow: Load $0.30 \le x < 0.70$
  - Red: Load $\ge 0.70$ (`Tuning.cpuStateMediumThreshold`)

### 8.2 State Persistence (`StateStore`)

State is persisted to `~/Library/Application Support/menubar-load-runner/state.json`:

```json
// `deadline` is a Swift `Date` under JSONEncoder's default strategy: seconds since the
// 2001 reference date, NOT the Unix epoch.
{
  "version": 1,
  "keepAwake": {
    "enabled": true,
    "tint": 0,
    "deadline": 780000000.0
  },
  "settings": {
    "labelMode": "value",
    "labelSide": "left",
    "batteryThreshold": 0.20,
    "freezeAnimation": false
  }
}
```

- **Fail-Silent:** Corrupt, missing, or unwritable files fall back to system defaults without surfacing dialogs.
- **Atomic Persistence:** `data.write(to:options: .atomic)` — Foundation writes a temp file and renames it into place.
- **Single-Writer Rule:** `persistState()` is the sole disk writer, assembling memory state atomically to avoid race conditions.

---

## 9. Preset Registry & Self-Updating

### 9.1 Data-Driven Presets (`gifs/presets.json`)

Built-in preset identities are decoupled from Swift code into `gifs/presets.json`:

```json
{
  "defaultPreset": "horse-white",
  "presets": [
    {
      "key": "horse-white",
      "menuTitle": "Horse (White)",
      "file": "running-horse-white.gif",
      "speed": {
        "label": "horse",
        "min": 0.45,
        "max": 2.30,
        "responseExponent": 1.0
      }
    }
  ]
}
```

At launch, `JSONDecoder` hydrates `allPresets: [PresetDescriptor]`, determining menu items, keywords, and speed curves dynamically.

### 9.2 Git-Native In-App Update Engine

- **Update Probe (`UpdateChecker`):** Executes `git ls-remote --tags --refs origin 'v*'` against the origin remote, comparing the highest strict three-component SemVer against `AppInfo.version`.
- **Precompile Before Restart (`Builder`):** On user confirmation, runs `git pull --ff-only` followed by `menubar-load-runner --precompile`.
- **Supervisor-Preserving Relaunch (`Restarter`):** Dispatches a detached `/bin/sh` script waiting for the old process PID to terminate, then relaunches via either `launchctl kickstart` (for LaunchAgent jobs) or the original launcher command line.

---

## 10. Key Invariants & System Guardrails

| Subsystem | Hard Invariant | Architectural Rationale |
|---|---|---|
| **Process Model** | Single binary execution per UID (`pgrep -U`) | Prevents duplicate menu bar status items across accidental terminal launches while supporting Fast User Switching. |
| **SMC Access** | Exactly one `io_connect_t` instance | `SMCClient.shared` holds process-lifetime connection without opening redundant kernel handles. |
| **Sleep Assertion** | Hard 5% critical battery floor | Sleep assertions unconditionally terminate at $\le 5\%$ battery, protecting laptop hardware from deep discharge. |
| **Menu Layout** | Static slot width reservation | Status items must never resize based on live data values to guarantee zero layout jitter on the menu bar. |
| **Game Loop** | Occlusion stops driver completely | Full occlusion (notch, inactive space, display off) must reduce render CPU utilization to exactly 0.0%. |
| **State File** | Single-writer centralized save | `persistState()` is the only function permitted to write `state.json`, eliminating partial block overwrites. |

---

## 11. Tuning & Parameter Reference

Comprehensive reference of values defined in `Tuning`:

| Constant Name | Value | Unit | Functional Role |
|---|---|---|---|
| `loadSampleInterval` | `2.0` | Seconds | Telemetry sampling and dashboard refresh period |
| `cpuSmoothingAlpha` | `0.2` | Fraction | Exponential moving average alpha for CPU load smoothing |
| `speedUpdateHysteresis` | `0.08` | Fraction | Minimum load delta required to adjust animation speed |
| `constrainedSpeedCeilingFraction` | `0.5` | Fraction | Animation speed cap under thermal/power/memory pressure |
| `maxFrameAdvanceDelta` | `1.0` | Seconds | Threshold to trigger game loop clock resync after sleep/pause |
| `scalerWindow` | `5` | Samples | Window size for adaptive throughput rolling average |
| `scalerRescaleCount` | `5` | Samples | Hysteresis consecutive sample count before rate rescaling |
| `scalerHeadroomUp` | `1.3` | Multiplier | Ceiling headroom when expanding rate scale |
| `scalerHeadroomDown` | `3.0` | Multiplier | Floor headroom when contracting rate scale |
| `temperatureFloorCelsius` | `30.0` | °C | Lower anchor for die temperature speed mapping |
| `temperatureCeilingCelsius` | `100.0` | °C | Upper anchor for die temperature speed mapping |
| `memoryIdleFloor` | `0.55` | Fraction | Baseline RAM fraction subtracted before speed scaling |
| `batteryLowThresholdDefault` | `0.20` | Fraction | Default battery release point for Keep Awake (20%) |
| `batteryCriticalThreshold` | `0.05` | Fraction | Hard safety release floor for Keep Awake (5%) |
| `keepAwakeBarForeignAlpha` | `0.45` | Alpha | Opacity of track line when machine is held awake externally |
| `keepAwakeBarPausedAlpha` | `0.22` | Alpha | Opacity of track line when Keep Awake is armed but suspended |
| `assertionRetentionSeconds` | `8.0` | Seconds | Hysteresis retention time for external sleep assertion display |
| `assertionRowCap` | `4` | Rows | Maximum external assertion rows displayed before overflow row |
| `labelSlotPadding` | `4.0` | Points | Slack padding added to reserved status item label widths |

---

## 12. Capability Lineage (As-Shipped)

How the current architecture was reached. Each stage is complete and in the binary today; this section
exists so an implementer can see *why* a subsystem has the shape it has, without reading the release
history. Forward-looking candidates live in `docs/ROADMAP.md`, never here.

One line: a load *visualizer* that earns each new capability through unprivileged reads and
self-restraint — it only ever reads the system, and the only thing it throttles is itself.

| Stage | What landed | What it established |
|---|---|---|
| **v1.0** — the thesis | A GIF whose playback speed *is* the load readout: five unprivileged readers (CPU / memory / GPU / network / disk), btop-style adaptive scaling for unbounded rates, self-throttle under power/thermal/memory pressure | One source file, no bundle, no Xcode (§ 1, § 2). The read-only + self-throttle tenet everything since is measured against |
| **v1.6** — distribution without a bundle | MIT license, one-line installer, git-checkout self-update | The standing decision every later one leans on — no `.app`, no notarization, so the update engine is git-native (§ 9.2) and the interface stays CLI-first |
| **v1.8 → v1.13** — the first *action*: Keep Awake | From a checkbox spawning `caffeinate` to the intent/running split, timed windows, persistence across relaunches, and battery/thermal release | The visualizer learned to hold state responsibly: intent vs. running state (§ 7.1), the safety floor (§ 7.2), and single-writer persistence (§ 8.2) |
| **v1.10 → v1.16** — the second slot | The live-value label as its own status item: reserved width, figure-space padding, the no-jitter guarantee | The dual-slot layout model and the jitter-free contract (§ 6, § 6.1, § 6.2); the dropdown becomes a live dashboard (§ 8) |
| **v1.17 → v1.19** — from *our* hold to *the machine's* | Other sleep assertions, the machine-hold row, brightness-tracks-the-hold tint | Report the whole truth about sleep, not just this app's part of it (§ 7.3); the submenu's subject-grouped layout |
| **v1.20** — the sensor tier | A shared `SMCClient` opened fan, then die temperature | The family of hardware readings the app can keep growing through without privileges (§ 4.3) |
| **v1.21 → v1.22** — restart cost, and standing still | Build-before-restart in the update path; Freeze Animation honoring Reduce Motion | The compile moved out of the window where the app is gone (§ 9.2); a single stop/start decider total over occlusion + freeze (§ 5.1, § 5.3) |
