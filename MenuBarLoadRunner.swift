import AppKit
import CoreGraphics
import Darwin
import ImageIO
import IOKit
import QuartzCore

// Human-facing app version (semver). Surfaced in --help and the About dialog, and the anchor for
// CHANGELOG.md releases. Bump this together with a new CHANGELOG entry and git tag.
private enum AppInfo {
    static let version = "1.2.1"
}

private enum Tuning {
    static let defaultGifFrameDelay: TimeInterval = 0.1
    static let minGifFrameDelay: TimeInterval = 0.02
    // Fallback game-loop tick rate used only on macOS < 14, where CADisplayLink
    // (NSView.displayLink) is unavailable and a plain 60 Hz Timer drives the loop.
    static let gameLoopFallbackInterval: TimeInterval = 1.0 / 60.0
    // Any inter-tick gap larger than this (display sleep, app occlusion, clock jump)
    // is treated as a resync rather than replayed frame-by-frame, so the loop never
    // spins through thousands of catch-up frames on resume.
    static let maxFrameAdvanceDelta: TimeInterval = 1.0

    static let cpuSmoothingAlpha: Double = 0.2
    static let loadSampleInterval: TimeInterval = 2.0
    static let speedUpdateHysteresis: Double = 0.08
    // When the system is under power/thermal pressure (Low Power Mode, or serious/
    // critical thermal state), THIS APP caps ITS OWN animation speed to this fraction
    // of the preset's min..max range. This reduces only the app's own CPU use (fewer
    // frame advances/redraws); it does NOT throttle the system or any other process.
    // The app is strictly read-only w.r.t. system state. 0.5 = the app never animates
    // faster than the midpoint of the speed range while under pressure.
    static let constrainedSpeedCeilingFraction: Double = 0.5
    static let cpuStateLowThreshold: Double = 0.30
    static let cpuStateMediumThreshold: Double = 0.70
    // Per-preset speed ranges and slot scales now live in gifs/presets.json (see PresetManifest),
    // not here — the manifest is the single source of truth for preset profiles.
    static let speedOverrideMin: Double = 0.1
    static let speedOverrideMax: Double = 5.0
    static let initialSpeedMultiplier: Double = 1.0
    static let percentScale: Double = 100.0

    // Adaptive throughput scaling (borrowed from btop's Net::collect auto-scale). Unbounded rate
    // signals (network bytes/sec, disk bytes/sec, memory swap bytes/sec) have no natural 0..1 range,
    // so each `ThroughputScaler` tracks an evolving ceiling and normalizes speed as
    // min(speed / ceiling, 1). The ceiling = max(avg(last `scalerWindow` speeds) * headroom, floor),
    // recomputed only after `scalerRescaleCount` consecutive out-of-band samples (hysteresis: a lone
    // spike or dip can't move the scale). Headroom is asymmetric — tight when scaling up, generous
    // when scaling down so it doesn't immediately re-trigger. See btop src/osx/btop_collect.cpp.
    static let scalerWindow: Int = 5
    static let scalerRescaleCount: Int = 5
    static let scalerHeadroomUp: Double = 1.3
    static let scalerHeadroomDown: Double = 3.0
    // Per-source ceiling floors. btop uses 10 KiB/s; we raise them so idle background chatter
    // (keepalive packets, housekeeping I/O, lazy swap) doesn't peg a menu-bar toy at full speed.
    static let networkFloorBytesPerSec: Double = 1 * 1_048_576
    static let diskFloorBytesPerSec: Double = 4 * 1_048_576
    static let swapFloorBytesPerSec: Double = 1 * 1_048_576

    static let renderVerticalInset: CGFloat = 4
    static let minIconDimension: CGFloat = 12
    static let renderHorizontalInset: CGFloat = 2
    static let minAspect: CGFloat = 0.01
    static let minBaseSlotWidth: CGFloat = 18
    // Neutral slot-scale / aspect fallback used when there is no active preset (custom GIF) or a
    // frame's real aspect is unavailable. Preset slot scales live in gifs/presets.json.
    static let fallbackSlotScale: CGFloat = 1.0

    static let loadAverageSampleCount = 3
    static let loadAverage1mIndex = 0
    static let loadAverage5mIndex = 1
    static let loadAverage15mIndex = 2
    static let minAlphaPixelComponents = 4
    static let alphaVisibleThreshold: UInt8 = 3
    static let minWidthSlots = 1
    static let maxWidthSlots = 4
    static let overlayMinFontSize: CGFloat = 8
    static let overlayMaxFontSize: CGFloat = 14
    static let overlayHorizontalInset: CGFloat = 2
    static let overlayVerticalInset: CGFloat = 1
    static let overlayFontScale: CGFloat = 0.5
    static let overlayStrokeWidth: CGFloat = -2
    static let overlayMaxChars = 12
}

// Which system reader drives the animation speed. A single registry (key + menu title) so the
// CLI keyword, env fallback, menu item, and selection checks all derive from one source of truth,
// mirroring PresetDescriptor.
private enum LoadSource: Int, CaseIterable {
    case cpu = 0
    case memory = 1
    case gpu = 2
    case network = 3
    case disk = 4

    var key: String {
        switch self {
        case .cpu: return "cpu"
        case .memory: return "memory"
        case .gpu: return "gpu"
        case .network: return "network"
        case .disk: return "disk"
        }
    }

    var menuTitle: String {
        switch self {
        case .cpu: return "CPU"
        case .memory: return "Memory"
        case .gpu: return "GPU"
        case .network: return "Network"
        case .disk: return "Disk"
        }
    }

    static func from(key: String?) -> LoadSource? {
        guard let key = key?.lowercased(), !key.isEmpty else { return nil }
        return allCases.first { $0.key == key }
    }
}

private struct Config {
    enum ParseResult {
        case config(Config)
        case help
    }

    // A built-in preset keyword (e.g. "horse-white") or an absolute/tilde GIF path. Empty means
    // "no arg given" → the app falls back to the manifest's defaultPreset.
    // Keyword→path resolution happens in MenuBarLoadRunnerApp.init against `allPresets`,
    // so the shell launcher forwards this arg unchanged.
    let presetOrPath: String
    let widthSlots: Int?
    let speedMultiplierOverride: Double?
    let overlayText: String?
    // Which reader drives the animation. Resolved from --load-source / env here (unknown →
    // .cpu, never a launch failure), so the app receives a concrete source, not a raw string.
    let loadSource: LoadSource
    // Debug/test hook: if MENUBAR_LOAD_RUNNER_EXIT_AFTER=<seconds> (>0) is set, the app
    // self-terminates after that many seconds. Lets a smoke test exit 0 on its own instead of
    // an external kill/timeout against the blocking AppKit run loop. nil = run until quit.
    let exitAfterSeconds: TimeInterval?

    static func parse() -> ParseResult? {
        let args = CommandLine.arguments.dropFirst()
        var presetOrPath: String?
        var widthSlots: Int?
        var speedMultiplierOverride: Double?
        var overlayText: String?
        var loadSourceArg: String?

        var iterator = args.makeIterator()
        while let arg = iterator.next() {
            switch arg {
            case "--help", "-h":
                printUsage()
                return .help
            case "--width", "-w":
                guard
                    let value = iterator.next(),
                    let parsed = Int(value),
                    (Tuning.minWidthSlots...Tuning.maxWidthSlots).contains(parsed)
                else {
                    fputs("Invalid value for --width. Expected an integer slot count in 1...4.\n", stderr)
                    printUsage()
                    return nil
                }
                widthSlots = parsed
            case "--speed-multiplier":
                guard let value = iterator.next(), let parsed = Double(value), parsed > 0 else {
                    fputs("Invalid value for --speed-multiplier. Expected a positive number.\n", stderr)
                    printUsage()
                    return nil
                }
                speedMultiplierOverride = parsed
            case "--overlay-text":
                guard let value = iterator.next() else {
                    fputs("Invalid value for --overlay-text. Expected a non-empty string.\n", stderr)
                    printUsage()
                    return nil
                }
                let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty, text.count <= Tuning.overlayMaxChars else {
                    fputs("Invalid value for --overlay-text. Expected 1...\(Tuning.overlayMaxChars) characters.\n", stderr)
                    printUsage()
                    return nil
                }
                overlayText = text
            case "--load-source":
                guard let value = iterator.next() else {
                    fputs("Invalid value for --load-source. Expected one of: \(LoadSource.allCases.map(\.key).joined(separator: ", ")).\n", stderr)
                    printUsage()
                    return nil
                }
                loadSourceArg = value
            default:
                if presetOrPath == nil {
                    presetOrPath = arg
                } else {
                    fputs("Unexpected argument: \(arg)\n", stderr)
                    printUsage()
                    return nil
                }
            }
        }

        if presetOrPath == nil {
            presetOrPath = ProcessInfo.processInfo.environment["MENUBAR_LOAD_RUNNER_PATH"]
        }

        // No positional arg and no env override → empty, so the app resolves the manifest default.
        let value = (presetOrPath?.isEmpty == false) ? presetOrPath! : ""

        if loadSourceArg == nil {
            loadSourceArg = ProcessInfo.processInfo.environment["MENUBAR_LOAD_RUNNER_LOAD_SOURCE"]
        }
        // Unknown/absent → .cpu (today's behavior). Never a launch failure, per spec.
        let loadSource = LoadSource.from(key: loadSourceArg) ?? .cpu
        if let requested = loadSourceArg, LoadSource.from(key: requested) == nil, !requested.isEmpty {
            fputs("Unknown --load-source \"\(requested)\"; falling back to cpu. Known: \(LoadSource.allCases.map(\.key).joined(separator: ", ")).\n", stderr)
        }

        var exitAfterSeconds: TimeInterval?
        if let raw = ProcessInfo.processInfo.environment["MENUBAR_LOAD_RUNNER_EXIT_AFTER"],
           let parsed = Double(raw), parsed > 0 {
            exitAfterSeconds = parsed
        }

        return .config(
            Config(
                presetOrPath: NSString(string: value).expandingTildeInPath,
                widthSlots: widthSlots,
                speedMultiplierOverride: speedMultiplierOverride,
                overlayText: overlayText,
                loadSource: loadSource,
                exitAfterSeconds: exitAfterSeconds
            )
        )
    }

    static func printUsage() {
        let envBin = ProcessInfo.processInfo.environment["MENUBAR_LOAD_RUNNER_BIN_NAME"]
        let bin = (envBin?.isEmpty == false) ? envBin! : URL(fileURLWithPath: CommandLine.arguments[0]).lastPathComponent
        print("MenuBar Load Runner \(AppInfo.version)")
        print("Usage: \(bin) <preset-name|path-to-gif> [--width <slots:1..4>] [--speed-multiplier <x>] [--overlay-text <text:1...\(Tuning.overlayMaxChars) chars>] [--load-source <\(LoadSource.allCases.map(\.key).joined(separator: "|"))>]")
        print("   or: MENUBAR_LOAD_RUNNER_PATH=<path-to-gif> \(bin) [--width <slots:1..4>] [--speed-multiplier <x>] [--overlay-text <text:1...\(Tuning.overlayMaxChars) chars>] [--load-source <\(LoadSource.allCases.map(\.key).joined(separator: "|"))>]")
        print("Load source: which reader drives animation speed (default cpu). Also via MENUBAR_LOAD_RUNNER_LOAD_SOURCE; unknown values fall back to cpu.")
        print("Default width: one slot (NSStatusItem.squareLength). With --width, GIF fills the configured slot count.")
        print("Width note: requested slots are clamped to each preset's minimum (e.g. totoro-group requires 4 slots).")
        print("Default speed: auto (preset-dependent; per-preset ranges defined in gifs/presets.json).")
    }
}

// Adaptive normalizer for unbounded throughput rates (network/disk/swap bytes-per-sec), ported from
// btop's Net::collect auto-scale. It maps a raw bytes/sec `speed` to 0…1 against a `ceiling` that
// tracks the recent workload instead of a fixed reference: full animation speed means "as busy as this
// machine has recently been," not a hardcoded MB/s. Hysteresis (rescale only after
// `scalerRescaleCount` consecutive out-of-band samples) keeps a lone spike from blowing the scale, and
// asymmetric headroom (tighter up, looser down) stops it re-triggering right after a rescale. The
// ceiling seeds from the first observed speed so a fresh source doesn't peg at 1.0 for a tick.
// A value type mutated in place by its owning @MainActor monitor.
private struct ThroughputScaler {
    private let floor: Double
    private var ceiling: Double
    private var seeded = false
    private var recent: [Double] = []
    private var overCount = 0
    private var underCount = 0

    init(floor: Double) {
        self.floor = floor
        self.ceiling = floor
    }

    // Feed one bytes/sec sample, get back its normalized 0…1 load against the current ceiling.
    mutating func normalize(speed: Double) -> Double {
        // Seed the ceiling from the first real sample so the first normalized value is ~sane rather
        // than speed/floor (which would peg at 1.0 whenever the first sample exceeds the floor).
        if !seeded {
            seeded = true
            ceiling = max(speed * Tuning.scalerHeadroomUp, floor)
        }

        recent.append(speed)
        if recent.count > Tuning.scalerWindow { recent.removeFirst(recent.count - Tuning.scalerWindow) }

        // btop hysteresis: count consecutive samples that sit above the ceiling or below a tenth of
        // it; the opposite counter decays so only a sustained trend triggers a rescale.
        if speed > ceiling {
            overCount += 1
            if underCount > 0 { underCount -= 1 }
        } else if ceiling > floor, speed < ceiling / 10 {
            underCount += 1
            if overCount > 0 { overCount -= 1 }
        }

        if overCount >= Tuning.scalerRescaleCount {
            ceiling = max(average() * Tuning.scalerHeadroomUp, floor)
            overCount = 0
            underCount = 0
        } else if underCount >= Tuning.scalerRescaleCount {
            ceiling = max(average() * Tuning.scalerHeadroomDown, floor)
            overCount = 0
            underCount = 0
        }

        guard ceiling > 0 else { return 0 }
        return min(speed / ceiling, 1)
    }

    private func average() -> Double {
        guard !recent.isEmpty else { return 0 }
        return recent.reduce(0, +) / Double(recent.count)
    }
}

@MainActor
private final class CPULoadMonitor {
    private var lastTotalTicks: UInt64?
    private var lastIdleTicks: UInt64?
    private var hasSmoothedUsage = false
    private(set) var smoothedUsage: Double = 0
    private let smoothingAlpha: Double = Tuning.cpuSmoothingAlpha
    var hasSample: Bool { hasSmoothedUsage }

    func sampleUsage() -> Double? {
        guard let usage = currentUsage() else { return nil }
        if !hasSmoothedUsage {
            smoothedUsage = usage
            hasSmoothedUsage = true
            return smoothedUsage
        }

        smoothedUsage = (smoothingAlpha * usage) + ((1 - smoothingAlpha) * smoothedUsage)
        return smoothedUsage
    }

    private func currentUsage() -> Double? {
        var cpuCount: natural_t = 0
        var cpuInfo: processor_info_array_t?
        var cpuInfoCount: mach_msg_type_number_t = 0

        let result = host_processor_info(
            mach_host_self(),
            PROCESSOR_CPU_LOAD_INFO,
            &cpuCount,
            &cpuInfo,
            &cpuInfoCount
        )
        guard result == KERN_SUCCESS, let cpuInfo else { return nil }

        defer {
            let size = vm_size_t(cpuInfoCount) * vm_size_t(MemoryLayout<integer_t>.size)
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: cpuInfo)), size)
        }

        var totalTicks: UInt64 = 0
        var idleTicks: UInt64 = 0
        let stride = Int(CPU_STATE_MAX)

        for cpu in 0..<Int(cpuCount) {
            let base = cpu * stride
            let user = UInt64(cpuInfo[base + Int(CPU_STATE_USER)])
            let system = UInt64(cpuInfo[base + Int(CPU_STATE_SYSTEM)])
            let nice = UInt64(cpuInfo[base + Int(CPU_STATE_NICE)])
            let idle = UInt64(cpuInfo[base + Int(CPU_STATE_IDLE)])

            totalTicks += user + system + nice + idle
            idleTicks += idle
        }

        defer {
            lastTotalTicks = totalTicks
            lastIdleTicks = idleTicks
        }

        guard let prevTotal = lastTotalTicks, let prevIdle = lastIdleTicks else {
            return nil
        }

        let deltaTotal = totalTicks &- prevTotal
        let deltaIdle = idleTicks &- prevIdle
        guard deltaTotal > 0, deltaIdle <= deltaTotal else { return nil }
        return Double(deltaTotal - deltaIdle) / Double(deltaTotal)
    }
}

// Reads memory pressure as a composite 0…1 load plus swap capacity. Same unprivileged Mach/sysctl
// tier as CPULoadMonitor — no private API, no subscription lifecycle. This is a *mixed domain*: the
// used-fraction is instantaneous (a point read, valid on the first tick, no EMA), while the swap
// *rate* is counter-delta (swapins+swapouts differenced over real elapsed wall-clock time, so it
// warms up one tick like the CPU reader). The driver value combines them, `currentMemoryLoad`; the
// menu still shows the raw used-fraction. No EMA on either — smoothing stays a conscious choice, not
// a default. "Unavailable" is nil, never a fabricated 0.
@MainActor
private final class MemoryLoadMonitor {
    private(set) var currentUsedFraction: Double = 0
    private(set) var hasSample = false
    private(set) var swapUsedBytes: UInt64 = 0
    private(set) var swapTotalBytes: UInt64 = 0
    private(set) var hasSwapSample = false
    // Composite driver value: max(usedFraction, adaptiveScaled(swapRate)). Equals the used-fraction
    // until swap activity warms up (one tick) and the scaled swap rate rises above it. See Tuning /
    // ThroughputScaler.
    private(set) var currentMemoryLoad: Double = 0
    private(set) var currentSwapRateBytesPerSec: Double = 0
    private(set) var hasSwapRateSample = false
    // Cumulative swapped bytes ((swapins+swapouts) * pageSize) at the previous sample; nil until the
    // first sample or after a cadence break (a source-switch re-sample passes elapsed = nil).
    private var lastSwapEvents: UInt64?
    // Swap rate is an unbounded bytes/sec signal, so it normalizes through the shared adaptive scaler
    // (same design as network/disk) rather than a fixed reference — heavy paging is judged relative to
    // this machine's recent paging.
    private var swapScaler = ThroughputScaler(floor: Tuning.swapFloorBytesPerSec)

    // One point read: refreshes the composite load (returned) plus, best-effort, swap capacity.
    // `elapsed` is the monotonic seconds since the previous sample (nil on the first tick or a
    // source-switch re-sample) — required to turn the swap counters into a rate. Returns nil only
    // when the used-fraction read itself fails; a failed swap read degrades just the swap
    // display/rate (hasSwapSample / hasSwapRateSample = false), never the fraction.
    func sampleUsage(elapsed: Double?) -> Double? {
        guard let sample = readVMSample() else { return nil }
        currentUsedFraction = sample.usedFraction
        hasSample = true
        readSwapUsage()
        updateSwapRate(swapEvents: sample.swapEvents, elapsed: elapsed)
        let swapLoad = hasSwapRateSample ? swapScaler.normalize(speed: currentSwapRateBytesPerSec) : 0
        currentMemoryLoad = max(sample.usedFraction, swapLoad)
        return currentMemoryLoad
    }

    // Swap rate is a counter-delta: it needs a prior sample AND real elapsed wall-clock time. When
    // elapsed is nil (first tick / source-switch re-sample) it stores the baseline and reports no
    // rate, so the composite falls back to the pure used-fraction until it warms up.
    private func updateSwapRate(swapEvents: UInt64, elapsed: Double?) {
        defer { lastSwapEvents = swapEvents }
        guard let elapsed, elapsed > 0, let prev = lastSwapEvents else {
            currentSwapRateBytesPerSec = 0
            hasSwapRateSample = false
            return
        }
        // Counters are monotonic; a decrease (shouldn't happen) resets rather than underflows.
        let deltaBytes = swapEvents >= prev ? swapEvents - prev : 0
        currentSwapRateBytesPerSec = Double(deltaBytes) / elapsed
        hasSwapRateSample = true
    }

    // Used-fraction formula (a deliberate approximation — the "right" definition is a judgment
    // call): "available" = pages reclaimable without pressure = free + purgeable + external
    // (file-backed). used = 1 - available / physicalMemory. Chosen over a raw free/total ratio
    // because macOS keeps most RAM occupied by reclaimable cache, so free/total reads alarmingly
    // high at idle; this tracks Activity Monitor's pressure notion more closely, without claiming
    // to reproduce its exact green/yellow/red algorithm. total comes from
    // ProcessInfo.physicalMemory (unprivileged, no extra syscall). One host_statistics64 read yields
    // both the used-fraction and the cumulative swap counters (swapins+swapouts), so swap rate costs
    // zero extra syscalls — it's a counter-delta on fields already in hand.
    private func readVMSample() -> (usedFraction: Double, swapEvents: UInt64)? {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        let total = Double(ProcessInfo.processInfo.physicalMemory)
        guard total > 0 else { return nil }

        // Query the page size via Mach rather than the `vm_kernel_page_size` global (a mutable
        // global, which isn't concurrency-safe under strict checking). The vm_statistics64 counts
        // are in units of this page size.
        var pageSize: vm_size_t = 0
        guard host_page_size(mach_host_self(), &pageSize) == KERN_SUCCESS else { return nil }

        let availablePages = Double(stats.free_count) + Double(stats.purgeable_count) + Double(stats.external_page_count)
        let used = 1.0 - ((availablePages * Double(pageSize)) / total)

        // swapins/swapouts are cumulative page counts (int64_t, monotonic); as bytes they're a
        // counter the caller differences over elapsed time. clamp negatives defensively.
        let swapPages = UInt64(max(0, stats.swapins)) &+ UInt64(max(0, stats.swapouts))
        let swapEvents = swapPages &* UInt64(pageSize)
        return (min(max(used, 0), 1), swapEvents)
    }

    // vm.swapusage: unprivileged sysctl, instantaneous point read, no lifecycle.
    private func readSwapUsage() {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.stride
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else {
            hasSwapSample = false
            return
        }
        swapUsedBytes = UInt64(usage.xsu_used)
        swapTotalBytes = UInt64(usage.xsu_total)
        hasSwapSample = true
    }
}

// GPU utilization via unprivileged IORegistry. IOAccelerator's PerformanceStatistics dictionary
// exposes "Device Utilization %" (0…100), an instantaneous point read valid on the first tick — no
// counter-delta, no EMA. Natively 0…1 after /100, so it does NOT use ThroughputScaler (only unbounded
// rates do). GPU *power/energy* would need the private IOReport dance; utilization does not. `nil`
// (never a fabricated 0) when no accelerator matches or the key is absent → the source disables.
@MainActor
private final class GPULoadMonitor {
    private(set) var currentUtilization: Double = 0
    private(set) var hasSample = false
    // Availability probed once and cached: a machine with no readable accelerator disables the source.
    private var availabilityChecked = false
    private var available = false

    var isAvailable: Bool {
        if !availabilityChecked {
            available = (readUtilization() != nil)
            availabilityChecked = true
        }
        return available
    }

    func sampleUsage() -> Double? {
        guard let util = readUtilization() else {
            hasSample = false
            return nil
        }
        currentUtilization = util
        hasSample = true
        return util
    }

    // Max "Device Utilization %" across matched accelerators. The IOClass is HW-specific
    // (e.g. AGXAcceleratorG16X on Apple Silicon), so match the provider class "IOAccelerator" first,
    // then fall back to "AGXAccelerator".
    private func readUtilization() -> Double? {
        for matchKey in ["IOAccelerator", "AGXAccelerator"] {
            if let util = readUtilization(matching: matchKey) { return util }
        }
        return nil
    }

    private func readUtilization(matching className: String) -> Double? {
        guard let matching = IOServiceMatching(className) else { return nil }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }

        var best: Double?
        var entry = IOIteratorNext(iterator)
        while entry != 0 {
            defer {
                IOObjectRelease(entry)
                entry = IOIteratorNext(iterator)
            }
            guard let prop = IORegistryEntryCreateCFProperty(
                entry, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0
            ) else { continue }
            guard let stats = prop.takeRetainedValue() as? [String: Any],
                  let pct = (stats["Device Utilization %"] as? NSNumber)?.doubleValue else { continue }
            let util = min(max(pct / Tuning.percentScale, 0), 1)
            best = max(best ?? 0, util)
        }
        return best
    }
}

// Network throughput as a 0…1 load. Cumulative interface byte counters (getifaddrs → if_data) are
// differenced over real elapsed wall time into bytes/sec (counter-delta, warms up one tick like CPU),
// then normalized by the shared adaptive ThroughputScaler. Only AF_LINK entries carry valid if_data,
// and lo0 is skipped so loopback traffic doesn't inflate the number.
@MainActor
private final class NetworkLoadMonitor {
    private(set) var hasSample = false
    private(set) var currentThroughputBytesPerSec: Double = 0
    // Last normalized 0…1 load (the scaler's output), so the speed path can re-read it without
    // re-sampling — mirrors MemoryLoadMonitor.currentMemoryLoad.
    private(set) var currentLoad: Double = 0
    private var lastBytes: UInt64?
    private var scaler = ThroughputScaler(floor: Tuning.networkFloorBytesPerSec)
    // getifaddrs is always present on macOS; the source is effectively always available.
    var isAvailable: Bool { true }

    func sampleUsage(elapsed: Double?) -> Double? {
        guard let total = readTotalBytes() else {
            hasSample = false
            return nil
        }
        defer { lastBytes = total }
        // Counter-delta: needs a prior sample AND real elapsed time. First tick / source-switch
        // re-sample (elapsed nil) just stores the baseline and reports no rate yet.
        guard let elapsed, elapsed > 0, let prev = lastBytes else {
            currentThroughputBytesPerSec = 0
            hasSample = false
            return nil
        }
        let deltaBytes = total >= prev ? total - prev : 0
        currentThroughputBytesPerSec = Double(deltaBytes) / elapsed
        hasSample = true
        currentLoad = scaler.normalize(speed: currentThroughputBytesPerSec)
        return currentLoad
    }

    private func readTotalBytes() -> UInt64? {
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let first = ifaddrPtr else { return nil }
        defer { freeifaddrs(ifaddrPtr) }

        var total: UInt64 = 0
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            defer { cursor = current.pointee.ifa_next }
            guard let addr = current.pointee.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_LINK) else { continue }
            if String(cString: current.pointee.ifa_name) == "lo0" { continue }
            guard let dataPtr = current.pointee.ifa_data else { continue }
            let data = dataPtr.assumingMemoryBound(to: if_data.self).pointee
            total &+= UInt64(data.ifi_ibytes) &+ UInt64(data.ifi_obytes)
        }
        return total
    }
}

// Disk I/O throughput as a 0…1 load — twin of NetworkLoadMonitor. Every IOBlockStorageDriver's
// Statistics dict carries cumulative "Bytes (Read)"/"Bytes (Write)"; summed across drivers, differenced
// over real elapsed time into bytes/sec, and normalized by the shared adaptive ThroughputScaler.
@MainActor
private final class DiskLoadMonitor {
    private(set) var hasSample = false
    private(set) var currentThroughputBytesPerSec: Double = 0
    private(set) var currentLoad: Double = 0
    private var lastBytes: UInt64?
    private var scaler = ThroughputScaler(floor: Tuning.diskFloorBytesPerSec)
    private var availabilityChecked = false
    private var available = false

    var isAvailable: Bool {
        if !availabilityChecked {
            available = (readTotalBytes() != nil)
            availabilityChecked = true
        }
        return available
    }

    func sampleUsage(elapsed: Double?) -> Double? {
        guard let total = readTotalBytes() else {
            hasSample = false
            return nil
        }
        defer { lastBytes = total }
        guard let elapsed, elapsed > 0, let prev = lastBytes else {
            currentThroughputBytesPerSec = 0
            hasSample = false
            return nil
        }
        let deltaBytes = total >= prev ? total - prev : 0
        currentThroughputBytesPerSec = Double(deltaBytes) / elapsed
        hasSample = true
        currentLoad = scaler.normalize(speed: currentThroughputBytesPerSec)
        return currentLoad
    }

    private func readTotalBytes() -> UInt64? {
        guard let matching = IOServiceMatching("IOBlockStorageDriver") else { return nil }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }

        var total: UInt64 = 0
        var found = false
        var entry = IOIteratorNext(iterator)
        while entry != 0 {
            defer {
                IOObjectRelease(entry)
                entry = IOIteratorNext(iterator)
            }
            guard let prop = IORegistryEntryCreateCFProperty(
                entry, "Statistics" as CFString, kCFAllocatorDefault, 0
            ) else { continue }
            guard let stats = prop.takeRetainedValue() as? [String: Any] else { continue }
            let read = (stats["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
            let write = (stats["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
            total &+= read &+ write
            found = true
        }
        return found ? total : nil
    }
}

@MainActor
private final class MenuBarLoadRunnerApp: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private struct SpeedProfile {
        let label: String
        let min: Double
        let max: Double
        let responseExponent: Double
    }

    private struct PresetDescriptor {
        let key: String
        let menuTitle: String
        let path: String
        let slotScale: CGFloat
        let speedProfile: SpeedProfile
    }

    // Codable mirror of gifs/presets.json — the externalized source of truth for every built-in
    // preset's profile. Decoded once in init() and mapped into `PresetDescriptor`s; the Swift code
    // holds no hardcoded preset list. `file` is a GIF filename relative to the manifest's directory.
    private struct PresetManifest: Decodable {
        let defaultPreset: String
        let presets: [Entry]

        struct Entry: Decodable {
            let key: String
            let menuTitle: String
            let file: String
            let slotScale: Double
            let speed: Speed
        }

        struct Speed: Decodable {
            let label: String
            let min: Double
            let max: Double
            let responseExponent: Double
        }
    }

    // Last-resort speed profile: used only when there is neither an active preset nor a manifest
    // default descriptor to borrow from (i.e. a custom GIF loaded while the manifest failed). In the
    // normal path a custom GIF inherits `defaultDescriptor`'s profile. Literal, self-contained.
    private static let customSpeedProfile = SpeedProfile(
        label: "custom",
        min: 0.5,
        max: 2.5,
        responseExponent: 1.0
    )

    private let config: Config
    private let allPresets: [PresetDescriptor]
    // The manifest's declared default preset, resolved once in init. Also the profile fallback for
    // a custom/user-supplied GIF that matches no preset (its slotScale/speedProfile stand in).
    private let defaultDescriptor: PresetDescriptor?
    // Set when the preset manifest could not be loaded/decoded; applicationDidFinishLaunching shows
    // it and quits. nil on success.
    private let startupError: String?
    private var activePreset: PresetDescriptor?
    private var activeGifPath: String
    // These menu/status-item IUOs are all assigned exactly once in
    // applicationDidFinishLaunching and only read afterwards (menu-delegate callbacks,
    // refresh functions, @objc actions) — never before launch. The `!` reflects that
    // single-init lifecycle; they are guaranteed non-nil for the app's lifetime.
    private var statusItem: NSStatusItem!
    private var infoMenu: NSMenu!
    // Source-conditional: holds the active load source's primary metric (CPU% / Memory%) and
    // its state qualifier (CPU State Low/Med/High / Memory Pressure Normal/Warning/Critical).
    private var usageItem: NSMenuItem!
    private var loadAverageItem: NSMenuItem!
    private var stateItem: NSMenuItem!
    private var speedMultiplierItem: NSMenuItem!
    private var loadSourceMenuItem: NSMenuItem!
    private var loadSourceMenuItems: [NSMenuItem] = []
    private var widthStatusItem: NSMenuItem!
    private var widthMenuItem: NSMenuItem!
    private var widthAutoItem: NSMenuItem!
    private var widthSlotItems: [NSMenuItem] = []
    private var overlayStatusItem: NSMenuItem!
    private var overlayMenuItem: NSMenuItem!
    private var overlaySetItem: NSMenuItem!
    private var overlayClearItem: NSMenuItem!
    private var presetMenuItems: [NSMenuItem] = []
    private var frames: [NSImage] = []
    private var frameAspects: [CGFloat] = []
    private var baseDurations: [TimeInterval] = []
    private var frameIndex = 0
    private var displayLink: CADisplayLink?
    private var fallbackTimer: Timer?
    private var lastTickTime: TimeInterval = 0
    private var accumulatedFrameTime: TimeInterval = 0
    private var renderedFrames: [NSImage] = []
    private var loadTimer: Timer?
    // Monotonic timestamp of the previous load sample, for counter-delta sources (swap rate now;
    // network/disk later). nil until the first tick / after a source switch, so rate-based signals
    // warm up one sample. systemUptime (not Date) — immune to wall-clock changes.
    private var lastSampleUptime: Double?
    private var loadMonitor = CPULoadMonitor()
    private var memoryMonitor = MemoryLoadMonitor()
    private var gpuMonitor = GPULoadMonitor()
    private var networkMonitor = NetworkLoadMonitor()
    private var diskMonitor = DiskLoadMonitor()
    private var activeLoadSource: LoadSource
    // Last memory-pressure level seen from the dispatch source. Cached because — unlike
    // thermalState/isLowPowerModeEnabled — there is NO synchronous getter for memory pressure;
    // it is event-only, so isUnderPowerPressure reads this stored value.
    private var memoryPressureLevel: DispatchSource.MemoryPressureEvent = .normal
    private var memoryPressureSource: DispatchSourceMemoryPressure?
    private var speedMultiplier: Double = Tuning.initialSpeedMultiplier
    private var requestedWidthSlots: Int?
    private var requestedOverlayText: String?
    private var requestedOverlayBold = true
    private var cachedLoadAverages: (Double, Double, Double)?
    private var screenObserver: NSObjectProtocol?
    private var powerStateObserver: NSObjectProtocol?
    private var thermalStateObserver: NSObjectProtocol?
    private var occlusionObserver: NSObjectProtocol?

    init(config: Config) {
        self.config = config
        self.requestedWidthSlots = config.widthSlots
        self.requestedOverlayText = config.overlayText
        self.activeLoadSource = config.loadSource

        // Resolve the resource base directory (which holds `gifs/`). Prefer the running executable's
        // own directory: the compiled `MenuBarLoadRunner` binary sits next to `gifs/`, and the
        // executable path is absolute and independent of both the current working directory and the
        // path passed to the compiler. This is the robust anchor — `#filePath` (the source path baked
        // in at compile time) is only correct when the binary is run from the right CWD *and* was
        // compiled with an absolute path, which is exactly how a relative-path build broke the launchd
        // login item (CWD=`/` → `/gifs/presets.json`). `#filePath`'s directory is kept as a fallback
        // for the interpreted `swift <file>` dev path, where there is no standalone executable beside
        // `gifs/`. Pick the first candidate that actually contains the manifest.
        let fileDirURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let candidateBases = [Bundle.main.executableURL?.deletingLastPathComponent(), fileDirURL]
            .compactMap { $0 }
        let scriptDirURL = candidateBases.first {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("gifs/presets.json").path)
        } ?? fileDirURL
        let manifestURL = scriptDirURL.appendingPathComponent("gifs/presets.json")

        // Load the externalized preset profiles. On any failure, leave the registry empty and record
        // a startup error — the app can't offer built-in presets without it (a user-supplied GIF path
        // still works, falling through to the custom profile).
        var presets: [PresetDescriptor] = []
        var manifestDefaultKey: String?
        var loadError: String?
        do {
            let data = try Data(contentsOf: manifestURL)
            let manifest = try JSONDecoder().decode(PresetManifest.self, from: data)
            manifestDefaultKey = manifest.defaultPreset
            presets = manifest.presets.map { entry in
                PresetDescriptor(
                    key: entry.key,
                    menuTitle: entry.menuTitle,
                    path: scriptDirURL.appendingPathComponent("gifs/\(entry.file)").path,
                    slotScale: CGFloat(entry.slotScale),
                    speedProfile: SpeedProfile(
                        label: entry.speed.label,
                        min: entry.speed.min,
                        max: entry.speed.max,
                        responseExponent: entry.speed.responseExponent
                    )
                )
            }
        } catch {
            loadError = "Could not load preset manifest at \(manifestURL.path): \(error.localizedDescription)"
        }

        self.allPresets = presets
        self.defaultDescriptor = presets.first { $0.key == manifestDefaultKey }
        self.startupError = loadError

        // Resolve the positional arg (a preset keyword or a GIF path). The shell launcher forwards it
        // verbatim; this is the single place keywords become paths. Empty → the manifest default.
        let requested = config.presetOrPath.isEmpty ? (manifestDefaultKey ?? "") : config.presetOrPath
        if let matched = presets.first(where: { $0.key == requested }) {
            self.activeGifPath = matched.path
            self.activePreset = matched
        } else {
            // Not a known keyword — treat it as a (custom) GIF path. Still match by path so a
            // raw path pointing at a built-in GIF adopts that preset's profile.
            self.activeGifPath = requested
            self.activePreset = presets.first { $0.path == requested }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        if let startupError {
            showStartupErrorAndQuit(startupError)
            return
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = statusItem.button else {
            showStartupErrorAndQuit("Unable to create NSStatusItem button.")
            return
        }

        button.imagePosition = .imageOnly
        // imageScaling is set by applySizing() below (before the first renderCurrentFrame).
        button.toolTip = activeGifPath
        // Base label for VoiceOver; refreshMenuMetrics() enriches it with live CPU load.
        button.setAccessibilityLabel("MenuBar Load Runner")

        infoMenu = NSMenu()
        infoMenu.delegate = self

        usageItem = NSMenuItem(title: "CPU Usage: --", action: nil, keyEquivalent: "")
        usageItem.isEnabled = false
        infoMenu.addItem(usageItem)

        loadAverageItem = NSMenuItem(title: "Load Avg (1/5/15m): -- / -- / --", action: nil, keyEquivalent: "")
        loadAverageItem.isEnabled = false
        infoMenu.addItem(loadAverageItem)

        stateItem = NSMenuItem(title: "CPU State: --", action: nil, keyEquivalent: "")
        stateItem.isEnabled = false
        infoMenu.addItem(stateItem)

        speedMultiplierItem = NSMenuItem(title: "Speed Multiplier: --", action: nil, keyEquivalent: "")
        speedMultiplierItem.isEnabled = false
        infoMenu.addItem(speedMultiplierItem)

        loadSourceMenuItem = NSMenuItem(title: "Load Source", action: nil, keyEquivalent: "")
        let loadSourceSubmenu = NSMenu(title: "Load Source")
        for source in LoadSource.allCases {
            let item = NSMenuItem(title: source.menuTitle, action: #selector(selectLoadSource(_:)), keyEquivalent: "")
            item.target = self
            item.tag = source.rawValue
            loadSourceSubmenu.addItem(item)
            loadSourceMenuItems.append(item)
        }
        loadSourceMenuItem.submenu = loadSourceSubmenu
        infoMenu.addItem(loadSourceMenuItem)

        // Availability fallback: if the requested source (--load-source / env) can't produce a value on
        // this hardware — realistically only GPU — degrade to CPU rather than driving off a dead reader.
        // An absent source never fails launch (design principle 4); the menu item stays disabled.
        if !isSourceAvailable(activeLoadSource) {
            fputs("Load source \"\(activeLoadSource.key)\" is unavailable on this machine; falling back to cpu.\n", stderr)
            activeLoadSource = .cpu
        }

        widthStatusItem = NSMenuItem(title: "Width: --", action: nil, keyEquivalent: "")
        widthStatusItem.isEnabled = false
        infoMenu.addItem(widthStatusItem)

        widthMenuItem = NSMenuItem(title: "Width Options", action: nil, keyEquivalent: "")
        let widthSubmenu = NSMenu(title: "Width Options")

        widthAutoItem = NSMenuItem(title: "Auto (preset)", action: #selector(selectWidthAuto), keyEquivalent: "")
        widthAutoItem.target = self
        widthSubmenu.addItem(widthAutoItem)
        widthSubmenu.addItem(.separator())

        for slots in Tuning.minWidthSlots...Tuning.maxWidthSlots {
            let title = "\(slots) slot" + (slots == 1 ? "" : "s")
            let item = NSMenuItem(title: title, action: #selector(selectWidthSlot(_:)), keyEquivalent: "")
            item.target = self
            item.tag = slots
            widthSubmenu.addItem(item)
            widthSlotItems.append(item)
        }

        widthMenuItem.submenu = widthSubmenu
        infoMenu.addItem(widthMenuItem)

        overlayStatusItem = NSMenuItem(title: "Overlay Text: --", action: nil, keyEquivalent: "")
        overlayStatusItem.isEnabled = false
        infoMenu.addItem(overlayStatusItem)

        overlayMenuItem = NSMenuItem(title: "Overlay Text", action: nil, keyEquivalent: "")
        let overlaySubmenu = NSMenu(title: "Overlay Text")

        overlaySetItem = NSMenuItem(title: "Set Text... (max \(Tuning.overlayMaxChars))", action: #selector(promptOverlayText), keyEquivalent: "")
        overlaySetItem.target = self
        overlaySubmenu.addItem(overlaySetItem)

        overlayClearItem = NSMenuItem(title: "Clear", action: #selector(clearOverlayText), keyEquivalent: "")
        overlayClearItem.target = self
        overlaySubmenu.addItem(overlayClearItem)

        overlayMenuItem.submenu = overlaySubmenu
        infoMenu.addItem(overlayMenuItem)

        infoMenu.addItem(NSMenuItem.separator())
        let presetsHeaderItem = NSMenuItem(title: "Presets", action: nil, keyEquivalent: "")
        infoMenu.addItem(presetsHeaderItem)

        for (index, preset) in allPresets.enumerated() {
            let item = NSMenuItem(title: preset.menuTitle, action: #selector(selectPreset(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            infoMenu.addItem(item)
            presetMenuItems.append(item)
        }

        infoMenu.addItem(NSMenuItem.separator())
        infoMenu.addItem(NSMenuItem(title: "About", action: #selector(showAbout), keyEquivalent: ""))
        infoMenu.addItem(NSMenuItem(title: "Exit", action: #selector(exitApp), keyEquivalent: "q"))
        infoMenu.items.forEach { $0.target = self }
        presetsHeaderItem.isEnabled = false
        statusItem.menu = infoMenu
        refreshPresetSelectionState()
        refreshWidthSelectionState()
        refreshOverlaySelectionState()
        refreshLoadSourceSelectionState()

        if !loadFrames(from: activeGifPath) {
            showStartupErrorAndQuit("Failed to decode GIF at: \(activeGifPath)")
            return
        }

        applySizing()
        renderCurrentFrame()
        if let override = config.speedMultiplierOverride {
            speedMultiplier = min(max(override, Tuning.speedOverrideMin), Tuning.speedOverrideMax)
        }
        startLoadMonitoring()
        startGameLoop()
        refreshMenuMetrics()

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // Registered with `queue: .main`, so this always fires on the main thread;
            // assert that to the compiler to reach the @MainActor-isolated methods.
            MainActor.assumeIsolated {
                self?.applySizing()
                self?.renderCurrentFrame()
            }
        }

        // Back off under power/thermal pressure the moment it changes, rather than
        // waiting up to loadSampleInterval for the next CPU sample to notice.
        powerStateObserver = NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reevaluateSpeedForCurrentConditions() }
        }
        thermalStateObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reevaluateSpeedForCurrentConditions() }
        }

        // Memory pressure is the third self-throttle input alongside low-power/thermal, but its
        // lifecycle differs: it is event-only (no synchronous getter), so we cache the level and
        // MUST include `.normal` in the mask to ever lift the throttle. It also needs an explicit
        // resume() and is torn down via cancel(), not removeObserver() — a sibling lifecycle to
        // the notification observers above, hence its own property.
        let pressureSource = DispatchSource.makeMemoryPressureSource(
            eventMask: [.normal, .warning, .critical],
            queue: .main
        )
        pressureSource.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let level = self.memoryPressureSource?.data else { return }
                self.memoryPressureLevel = level
                self.reevaluateSpeedForCurrentConditions()
                self.refreshMenuMetrics()
            }
        }
        memoryPressureSource = pressureSource
        pressureSource.resume()

        // Pause the whole game loop when the status item's window is fully occluded
        // (hidden behind the notch / menu-bar overflow, another Space, display off):
        // there's no point re-rasterizing frames no one can see.
        if let window = statusItem.button?.window {
            occlusionObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateAnimationForOcclusion() }
            }
        }

        // Debug/test hook (MENUBAR_LOAD_RUNNER_EXIT_AFTER): self-terminate so smoke tests exit 0
        // on their own rather than relying on an external kill against the blocking run loop.
        if let seconds = config.exitAfterSeconds {
            fputs("MENUBAR_LOAD_RUNNER_EXIT_AFTER=\(seconds): terminating after \(seconds)s.\n", stderr)
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
                MainActor.assumeIsolated { NSApp.terminate(nil) }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopGameLoop()
        loadTimer?.invalidate()
        for observer in [screenObserver, powerStateObserver, thermalStateObserver, occlusionObserver] {
            if let observer {
                NotificationCenter.default.removeObserver(observer)
            }
        }
        // Dispatch source: cancel() (not removeObserver) — its own lifecycle.
        memoryPressureSource?.cancel()
        memoryPressureSource = nil
    }

    @objc
    private func showAbout() {
        let alert = NSAlert()
        alert.messageText = "About MenuBar Load Runner"
        if let icon = makeMenuAlertIcon() {
            alert.icon = icon
        }
        let speedMode = isAutoSpeed
            ? "Speed adapts to \(activeLoadSource.menuTitle) load (switch source in the Load Source menu)."
            : "Fixed speed multiplier: \(String(format: "%.2f", speedMultiplier))x."
        alert.informativeText = "Version \(AppInfo.version)\nDisplays an animated GIF in the macOS menu bar.\n\(speedMode)"
        alert.alertStyle = .informational
        alert.runModal()
    }

    @objc
    private func exitApp() {
        NSApp.terminate(nil)
    }

    private func makeMenuAlertIcon() -> NSImage? {
        guard
            let iconPath = allPresets.first(where: { $0.key == "horse-black" })?.path,
            let source = NSImage(contentsOfFile: iconPath)
        else {
            return nil
        }
        let box = NSSize(width: 48, height: 48)
        // Aspect-fit into the square box (the art is ~3:2, so a plain square draw would squish it),
        // centered with transparent padding.
        let sourceSize = source.size
        let fit = min(box.width / max(sourceSize.width, 1), box.height / max(sourceSize.height, 1))
        let drawSize = NSSize(width: sourceSize.width * fit, height: sourceSize.height * fit)
        let drawRect = NSRect(
            x: (box.width - drawSize.width) / 2,
            y: (box.height - drawSize.height) / 2,
            width: drawSize.width,
            height: drawSize.height
        )
        // Back the bitmap at the display scale (Retina) and interpolate at high quality, so the
        // scaled horse is smooth rather than jagged/blocky.
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(box.width * scale),
            pixelsHigh: Int(box.height * scale),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return nil
        }
        rep.size = box
        NSGraphicsContext.saveGraphicsState()
        if let ctx = NSGraphicsContext(bitmapImageRep: rep) {
            NSGraphicsContext.current = ctx
            ctx.imageInterpolation = .high
            source.draw(
                in: drawRect,
                from: NSRect(origin: .zero, size: sourceSize),
                operation: .sourceOver,
                fraction: 1.0
            )
            ctx.flushGraphics()
        }
        NSGraphicsContext.restoreGraphicsState()
        let icon = NSImage(size: box)
        icon.addRepresentation(rep)
        return icon
    }

    // Modal alerts block the run loop waiting for a click — fine for a real user, but they'd
    // wedge an automated/headless run indefinitely and pop an intrusive dialog during QA. When
    // the EXIT_AFTER test hook is active we treat the run as non-interactive: report to stderr
    // instead of showing a modal.
    private var suppressModalAlerts: Bool { config.exitAfterSeconds != nil }

    private func showStartupErrorAndQuit(_ message: String) {
        fputs(message + "\n", stderr)
        if suppressModalAlerts {
            NSApp.terminate(nil)
            return
        }
        let alert = NSAlert()
        alert.messageText = "MenuBar Load Runner startup error"
        if let icon = makeMenuAlertIcon() {
            alert.icon = icon
        }
        alert.informativeText = message
        alert.alertStyle = .critical
        alert.runModal()
        NSApp.terminate(nil)
    }



    private func startLoadMonitoring() {
        loadTimer?.invalidate()
        let timer = Timer(
            timeInterval: Tuning.loadSampleInterval,
            target: self,
            selector: #selector(sampleSystemLoad),
            userInfo: nil,
            repeats: true
        )
        loadTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    @objc
    private func sampleSystemLoad() {
        cachedLoadAverages = readSystemLoadAverages()

        // Real elapsed wall-clock since the last tick (nil on the first), for counter-delta sources.
        // The nominal 2s interval isn't trustworthy — a tick can slip under load/sleep — so rates
        // divide by this, not the interval.
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = lastSampleUptime.map { now - $0 }
        lastSampleUptime = now

        // Sample only the active source (active-only, per the self-throttle ethos): the inactive
        // monitors aren't polled, so their menu lines aren't shown while another source drives.
        if let usage = sampleActiveSource(elapsed: elapsed) {
            if isAutoSpeed {
                let candidate = speedMultiplier(forUsage: usage)
                if abs(candidate - speedMultiplier) >= Tuning.speedUpdateHysteresis {
                    // The driver reads speedMultiplier live via the accumulator, so the
                    // new speed takes effect on the next tick — no need to restart it.
                    speedMultiplier = candidate
                }
            }
        }

        refreshMenuMetrics()
    }

    // Sample whichever reader currently drives the animation, returning its 0…1 fraction (or nil
    // if unavailable / not warmed up). The single point where the active source is read for speed.
    private func sampleActiveSource(elapsed: Double?) -> Double? {
        switch activeLoadSource {
        case .cpu: return loadMonitor.sampleUsage()
        case .memory: return memoryMonitor.sampleUsage(elapsed: elapsed)
        case .gpu: return gpuMonitor.sampleUsage()
        case .network: return networkMonitor.sampleUsage(elapsed: elapsed)
        case .disk: return diskMonitor.sampleUsage(elapsed: elapsed)
        }
    }

    // Whether the active source has produced at least one usable sample.
    private var activeSourceHasSample: Bool {
        switch activeLoadSource {
        case .cpu: return loadMonitor.hasSample
        case .memory: return memoryMonitor.hasSample
        case .gpu: return gpuMonitor.hasSample
        case .network: return networkMonitor.hasSample
        case .disk: return diskMonitor.hasSample
        }
    }

    // The active source's most recent driving fraction, without re-sampling. For memory this is the
    // composite load (used-fraction ∨ scaled swap rate); for network/disk it's the scaler's last
    // normalized value — matching what sampleActiveSource returns, not the raw metric shown in the menu.
    private var activeSourceCurrentUsage: Double {
        switch activeLoadSource {
        case .cpu: return loadMonitor.smoothedUsage
        case .memory: return memoryMonitor.currentMemoryLoad
        case .gpu: return gpuMonitor.currentUtilization
        case .network: return networkMonitor.currentLoad
        case .disk: return diskMonitor.currentLoad
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        refreshMenuMetrics()
        refreshPresetSelectionState()
        refreshWidthSelectionState()
        refreshOverlaySelectionState()
        refreshLoadSourceSelectionState()
    }

    private func refreshMenuMetrics() {
        // Source-conditional: usageItem/stateItem show the ACTIVE source's metric + state. The
        // inactive source isn't sampled (see sampleSystemLoad), so showing its stale line would
        // mislead — instead only the driver's figures appear. Load Avg stays (system-wide).
        switch activeLoadSource {
        case .cpu:
            if loadMonitor.hasSample {
                usageItem.title = String(format: "CPU Usage (smoothed): %.1f%%", loadMonitor.smoothedUsage * Tuning.percentScale)
                stateItem.title = "CPU State: \(cpuStateText(for: loadMonitor.smoothedUsage))"
                statusItem.button?.setAccessibilityLabel(String(
                    format: "MenuBar Load Runner — CPU %.0f%%, %@",
                    loadMonitor.smoothedUsage * Tuning.percentScale,
                    cpuStateText(for: loadMonitor.smoothedUsage)
                ))
            } else {
                usageItem.title = "CPU Usage (smoothed): warming up..."
                stateItem.title = "CPU State: warming up..."
                statusItem.button?.setAccessibilityLabel("MenuBar Load Runner — measuring CPU load")
            }
        case .memory:
            // Memory pressure (state line) reflects the cached dispatch-source level and is valid
            // even before the first used-fraction sample, so it's shown unconditionally.
            stateItem.title = "Memory Pressure: \(memoryPressureText())"
            if memoryMonitor.hasSample {
                usageItem.title = memoryUsageLineText()
                statusItem.button?.setAccessibilityLabel(String(
                    format: "MenuBar Load Runner — memory %.0f%%, pressure %@",
                    memoryMonitor.currentUsedFraction * Tuning.percentScale,
                    memoryPressureText()
                ))
            } else {
                usageItem.title = "Memory: warming up..."
                statusItem.button?.setAccessibilityLabel("MenuBar Load Runner — measuring memory load")
            }
        case .gpu:
            if gpuMonitor.hasSample {
                usageItem.title = String(format: "GPU: %.0f%%", gpuMonitor.currentUtilization * Tuning.percentScale)
                stateItem.title = "GPU State: \(cpuStateText(for: gpuMonitor.currentUtilization))"
                statusItem.button?.setAccessibilityLabel(String(
                    format: "MenuBar Load Runner — GPU %.0f%%, %@",
                    gpuMonitor.currentUtilization * Tuning.percentScale,
                    cpuStateText(for: gpuMonitor.currentUtilization)
                ))
            } else {
                usageItem.title = "GPU: warming up..."
                stateItem.title = "GPU State: warming up..."
                statusItem.button?.setAccessibilityLabel("MenuBar Load Runner — measuring GPU load")
            }
        case .network:
            if networkMonitor.hasSample {
                usageItem.title = networkUsageLineText()
                stateItem.title = "Network State: \(cpuStateText(for: networkMonitor.currentLoad))"
                statusItem.button?.setAccessibilityLabel(String(
                    format: "MenuBar Load Runner — network %.1f MB/s, %@",
                    networkMonitor.currentThroughputBytesPerSec / 1_048_576.0,
                    cpuStateText(for: networkMonitor.currentLoad)
                ))
            } else {
                usageItem.title = "Network: warming up..."
                stateItem.title = "Network State: warming up..."
                statusItem.button?.setAccessibilityLabel("MenuBar Load Runner — measuring network load")
            }
        case .disk:
            if diskMonitor.hasSample {
                usageItem.title = diskUsageLineText()
                stateItem.title = "Disk State: \(cpuStateText(for: diskMonitor.currentLoad))"
                statusItem.button?.setAccessibilityLabel(String(
                    format: "MenuBar Load Runner — disk %.1f MB/s, %@",
                    diskMonitor.currentThroughputBytesPerSec / 1_048_576.0,
                    cpuStateText(for: diskMonitor.currentLoad)
                ))
            } else {
                usageItem.title = "Disk: warming up..."
                stateItem.title = "Disk State: warming up..."
                statusItem.button?.setAccessibilityLabel("MenuBar Load Runner — measuring disk load")
            }
        }

        if isAutoSpeed {
            let profile = currentSpeedProfile()
            let constrained = isUnderPowerPressure ? " [throttled: low power/thermal]" : ""
            // Includes the active source so the dashboard shows WHAT drives the animation.
            speedMultiplierItem.title = String(
                format: "Speed Multiplier (auto %@ %@ %.2fx..%.2fx): %.2fx%@",
                activeLoadSource.menuTitle,
                profile.label,
                profile.min,
                profile.max,
                speedMultiplier,
                constrained
            )
        } else {
            speedMultiplierItem.title = String(format: "Speed Multiplier (fixed): %.2fx", speedMultiplier)
        }

        if let (avg1, avg5, avg15) = cachedLoadAverages {
            loadAverageItem.title = String(format: "Load Avg (1/5/15m): %.2f / %.2f / %.2f", avg1, avg5, avg15)
        } else {
            loadAverageItem.title = "Load Avg (1/5/15m): unavailable"
        }
    }

    private func memoryPressureText() -> String {
        if memoryPressureLevel.contains(.critical) { return "Critical" }
        if memoryPressureLevel.contains(.warning) { return "Warning" }
        return "Normal"
    }

    private func memoryUsageLineText() -> String {
        let pct = memoryMonitor.currentUsedFraction * Tuning.percentScale
        var line = String(format: "Memory: %.0f%%", pct)
        if memoryMonitor.hasSwapSample, memoryMonitor.swapTotalBytes > 0 {
            let gib = 1_073_741_824.0
            line += String(
                format: " · swap %.1f/%.1f GB",
                Double(memoryMonitor.swapUsedBytes) / gib,
                Double(memoryMonitor.swapTotalBytes) / gib
            )
        }
        // Show the swap *rate* when actively paging — it's part of what drives the animation, so the
        // dashboard shouldn't read "Memory: 40%" while swap activity pushes the speed higher.
        if memoryMonitor.hasSwapRateSample, memoryMonitor.currentSwapRateBytesPerSec > 0 {
            let mibps = 1_048_576.0
            line += String(format: " · %.1f MB/s", memoryMonitor.currentSwapRateBytesPerSec / mibps)
        }
        return line
    }

    // Network/disk metric lines: the human-meaningful throughput (MB/s), not the adaptive-normalized
    // 0…1 load that actually drives the animation (that's activeSourceCurrentUsage). Mirrors the
    // memory line showing raw used-% while the composite drives speed.
    private func networkUsageLineText() -> String {
        String(format: "Network: %.1f MB/s", networkMonitor.currentThroughputBytesPerSec / 1_048_576.0)
    }

    private func diskUsageLineText() -> String {
        String(format: "Disk: %.1f MB/s", diskMonitor.currentThroughputBytesPerSec / 1_048_576.0)
    }

    private func refreshPresetSelectionState() {
        let fileManager = FileManager.default
        for (item, preset) in zip(presetMenuItems, allPresets) {
            item.isEnabled = fileManager.fileExists(atPath: preset.path)
            item.state = (activePreset?.key == preset.key) ? .on : .off
        }
    }

    // Radio group: the active source is `.on`, the rest `.off` — mirrors the width/preset selection
    // pattern. A source whose reader can't produce a value on this hardware (e.g. no readable GPU
    // accelerator) is disabled, like refreshPresetSelectionState disables a missing-GIF preset.
    private func refreshLoadSourceSelectionState() {
        for item in loadSourceMenuItems {
            item.state = (item.tag == activeLoadSource.rawValue) ? .on : .off
            if let source = LoadSource(rawValue: item.tag) {
                item.isEnabled = isSourceAvailable(source)
            }
        }
    }

    // Whether a source's reader can produce a value on this machine. CPU/memory are always available
    // (core Mach/sysctl); gpu/network/disk defer to their monitor's probe. Availability is static, so
    // an unavailable source is disabled in the menu and, if requested at launch, falls back to CPU —
    // no per-tick fallback loop is needed (a reader erroring mid-run just yields nil that tick and the
    // animation holds its last speed; it never crashes).
    private func isSourceAvailable(_ source: LoadSource) -> Bool {
        // Test hook: force listed sources unavailable so QA can exercise the disable + launch-fallback
        // path on hardware where every reader actually works.
        if forcedUnavailableSources.contains(source.key) { return false }
        switch source {
        case .cpu, .memory: return true
        case .gpu: return gpuMonitor.isAvailable
        case .network: return networkMonitor.isAvailable
        case .disk: return diskMonitor.isAvailable
        }
    }

    // Debug/test hook: MENUBAR_LOAD_RUNNER_FORCE_UNAVAILABLE=gpu,network,disk marks those sources
    // unavailable regardless of hardware, so §3/§7 QA can verify the disabled menu item and the
    // launch-time fallback-to-cpu. Empty/unset = no override. Mirrors the EXIT_AFTER hook convention.
    private let forcedUnavailableSources: Set<String> = {
        guard let raw = ProcessInfo.processInfo.environment["MENUBAR_LOAD_RUNNER_FORCE_UNAVAILABLE"] else { return [] }
        return Set(raw.lowercased().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
    }()

    private func refreshWidthSelectionState() {
        let minSlots = minimumSlotsForCurrentPreset()
        let requested = requestedWidthSlots
        let effective = effectiveWidthSlots()

        if let requested {
            if requested < minSlots {
                widthStatusItem.title = "Width: \(effective) slots (requested \(requested), min \(minSlots) for preset)"
            } else {
                widthStatusItem.title = "Width: \(effective) slots"
            }
        } else {
            widthStatusItem.title = String(format: "Width: auto (preset scale %.2fx)", currentPresetScale())
        }

        widthAutoItem.state = requested == nil ? .on : .off
        for item in widthSlotItems {
            item.state = (requested != nil && item.tag == effective) ? .on : .off
        }
    }

    private func refreshOverlaySelectionState() {
        if let text = requestedOverlayText {
            let style = requestedOverlayBold ? "bold" : "regular"
            overlayStatusItem.title = "Overlay Text: \(text) (\(style))"
            overlayClearItem.isEnabled = true
        } else {
            overlayStatusItem.title = "Overlay Text: off"
            overlayClearItem.isEnabled = false
        }
    }

    @objc
    private func selectPreset(_ sender: NSMenuItem) {
        guard allPresets.indices.contains(sender.tag) else { return }
        let preset = allPresets[sender.tag]
        switchToGif(to: preset.path, descriptor: preset)
    }

    @objc
    private func selectLoadSource(_ sender: NSMenuItem) {
        guard let source = LoadSource(rawValue: sender.tag), source != activeLoadSource else { return }
        activeLoadSource = source
        // Sample the newly-active source at once and re-derive speed immediately (bypassing the
        // 2s-tick hysteresis), the same way preset switches re-derive on the spot. Pass elapsed=nil:
        // an on-demand resample has no meaningful interval, so counter-delta signals (memory's swap
        // rate) just store a baseline here and re-warm over the next tick. Reset lastSampleUptime so
        // that next tick treats the gap as a fresh start rather than dividing by a stale interval.
        // reevaluateSpeedForCurrentConditions no-ops until the source has a usable sample.
        _ = sampleActiveSource(elapsed: nil)
        lastSampleUptime = nil
        reevaluateSpeedForCurrentConditions()
        refreshLoadSourceSelectionState()
        refreshMenuMetrics()
    }

    @objc
    private func selectWidthAuto() {
        requestedWidthSlots = nil
        applySizing()
        renderCurrentFrame()
        refreshWidthSelectionState()
    }

    @objc
    private func selectWidthSlot(_ sender: NSMenuItem) {
        requestedWidthSlots = min(max(sender.tag, Tuning.minWidthSlots), Tuning.maxWidthSlots)
        applySizing()
        renderCurrentFrame()
        refreshWidthSelectionState()
    }

    @objc
    private func promptOverlayText() {
        let alert = NSAlert()
        alert.messageText = "Set Overlay Text"
        alert.informativeText = "Enter up to \(Tuning.overlayMaxChars) characters."
        alert.alertStyle = .informational
        if let icon = makeMenuAlertIcon() {
            alert.icon = icon
        }

        let field = NSTextField(string: requestedOverlayText ?? "")
        field.placeholderString = "TEXT"
        field.frame = NSRect(x: 0, y: 32, width: 260, height: 24)

        let textLabel = NSTextField(labelWithString: "Overlay text")
        textLabel.frame = NSRect(x: 0, y: 58, width: 260, height: 16)

        let boldToggle = NSButton(checkboxWithTitle: "Bold", target: nil, action: nil)
        boldToggle.state = requestedOverlayBold ? .on : .off
        boldToggle.frame = NSRect(x: 0, y: 6, width: 120, height: 18)

        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 78))
        accessory.addSubview(textLabel)
        accessory.addSubview(field)
        accessory.addSubview(boldToggle)
        alert.accessoryView = accessory

        alert.addButton(withTitle: "Apply")
        alert.addButton(withTitle: "Cancel")

        // Focus the text field. `initialFirstResponder` is the deterministic mechanism —
        // NSAlert makes its window key during runModal() and honors it — and replaces the
        // old three staggered post-presentation focus retries. One post-present hop remains
        // as a belt-and-suspenders (some AppKit versions have ignored initialFirstResponder
        // on NSAlert accessory views) and to place the caret at the end of any pre-filled
        // text, which needs the field editor that only exists once the field is focused.
        let alertWindow = alert.window
        alertWindow.initialFirstResponder = field
        DispatchQueue.main.async { [weak field, weak alertWindow] in
            guard let field, let alertWindow else { return }
            alertWindow.makeFirstResponder(field)
            field.selectText(nil)
            if let editor = field.currentEditor() {
                editor.selectedRange = NSRange(location: field.stringValue.count, length: 0)
            }
        }

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        requestedOverlayBold = boldToggle.state == .on
        let input = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else {
            applyOverlayCleared()
            return
        }

        guard input.count <= Tuning.overlayMaxChars else {
            showRuntimeError("Overlay text must be at most \(Tuning.overlayMaxChars) characters.")
            return
        }

        requestedOverlayText = input
        updateRenderedFrames()
        renderCurrentFrame()
        refreshOverlaySelectionState()
    }

    @objc
    private func clearOverlayText() {
        applyOverlayCleared()
    }

    private func applyOverlayCleared() {
        requestedOverlayText = nil
        updateRenderedFrames()
        renderCurrentFrame()
        refreshOverlaySelectionState()
    }

    private func switchToGif(to path: String, descriptor: PresetDescriptor?) {
        let expanded = NSString(string: path).expandingTildeInPath
        guard expanded != activeGifPath else { return }

        let previousPath = activeGifPath
        let previousPreset = activePreset
        let previousFrames = frames
        let previousDurations = baseDurations
        let previousFrameIndex = frameIndex

        guard loadFrames(from: expanded) else {
            activeGifPath = previousPath
            activePreset = previousPreset
            frames = previousFrames
            baseDurations = previousDurations
            frameIndex = previousFrameIndex
            showRuntimeError("Failed to load GIF at: \(expanded)")
            refreshPresetSelectionState()
            return
        }

        activeGifPath = expanded
        activePreset = descriptor
        frameIndex = 0
        statusItem.button?.toolTip = activeGifPath

        applySizing()
        renderCurrentFrame()
        refreshWidthSelectionState()
        refreshOverlaySelectionState()

        // New frame source: re-sync timing on the running driver rather than tearing it
        // down (the link's button/screen is unchanged, only the frames/durations differ).
        resetGameLoopTiming()
        refreshPresetSelectionState()
    }

    private func showRuntimeError(_ message: String) {
        NSSound.beep()
        if suppressModalAlerts {
            fputs(message + "\n", stderr)
            return
        }
        let alert = NSAlert()
        alert.messageText = "MenuBar Load Runner"
        if let icon = makeMenuAlertIcon() {
            alert.icon = icon
        }
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }

    private func readSystemLoadAverages() -> (Double, Double, Double)? {
        var samples = [Double](repeating: 0, count: Tuning.loadAverageSampleCount)
        let count = samples.withUnsafeMutableBufferPointer { buffer in
            getloadavg(buffer.baseAddress, Int32(buffer.count))
        }
        guard count >= Int32(Tuning.loadAverageSampleCount) else { return nil }
        return (
            samples[Tuning.loadAverage1mIndex],
            samples[Tuning.loadAverage5mIndex],
            samples[Tuning.loadAverage15mIndex]
        )
    }

    private func cpuStateText(for usage: Double) -> String {
        if usage < Tuning.cpuStateLowThreshold {
            return "Low"
        }
        if usage < Tuning.cpuStateMediumThreshold {
            return "Medium"
        }
        return "High"
    }

    private func speedMultiplier(forUsage usage: Double) -> Double {
        let profile = currentSpeedProfile()
        let clampedUsage = min(max(usage, 0), 1)
        let curvedUsage = pow(clampedUsage, profile.responseExponent)
        var value = profile.min + ((profile.max - profile.min) * curvedUsage)
        if isUnderPowerPressure {
            let ceiling = profile.min + (profile.max - profile.min) * Tuning.constrainedSpeedCeilingFraction
            value = min(value, ceiling)
        }
        return min(max(value, profile.min), profile.max)
    }

    // Reads system power/thermal/memory-pressure state (getters only — never mutates it). True
    // when the Mac is in Low Power Mode, thermally throttling, or under memory pressure, i.e.
    // when this app should reduce its OWN animation work rather than add to the load it displays.
    private var isUnderPowerPressure: Bool {
        let info = ProcessInfo.processInfo
        if info.isLowPowerModeEnabled { return true }
        switch info.thermalState {
        case .serious, .critical: return true
        default: break
        }
        // Memory pressure is event-only (no synchronous getter), so this reads the cached level
        // updated by the dispatch source. Requires `.normal` in the source's mask to ever clear.
        if memoryPressureLevel.contains(.warning) || memoryPressureLevel.contains(.critical) {
            return true
        }
        return false
    }

    // Recompute this app's OWN auto animation speed from the active source's latest sample
    // immediately, bypassing the sample-tick hysteresis. Called when power/thermal/memory-
    // pressure state flips, or when the load source changes, so the app's self-imposed speed
    // cap engages (or lifts) — or the new source takes over — without waiting for the next
    // loadSampleInterval tick. Consults the ACTIVE source, not CPU specifically. Changes nothing
    // outside this app.
    private func reevaluateSpeedForCurrentConditions() {
        guard isAutoSpeed, activeSourceHasSample else { return }
        speedMultiplier = speedMultiplier(forUsage: activeSourceCurrentUsage)
        refreshMenuMetrics()
    }

    // Pause the game loop while the status item is fully occluded, resume when it
    // becomes visible again. On resume startGameLoop() re-syncs timing, so the
    // animation picks up from the current frame rather than replaying skipped ones.
    private func updateAnimationForOcclusion() {
        guard let window = statusItem.button?.window else { return }
        if window.occlusionState.contains(.visible) {
            if displayLink == nil, fallbackTimer == nil {
                startGameLoop()
            }
        } else {
            stopGameLoop()
        }
    }

    // Drives frame advancement off the display's refresh signal via CADisplayLink
    // (macOS 14+), so ticks are vsync-aligned and follow the status item's screen
    // (including its refresh rate on ProMotion). Falls back to a 60 Hz Timer on older
    // systems. The link/timer reads `speedMultiplier` live through the accumulator, so a
    // speed change never needs the driver to be recreated — only a frame-source or
    // driver (re)start resets timing.
    private func startGameLoop() {
        stopGameLoop()
        resetGameLoopTiming()

        if #available(macOS 14.0, *), let button = statusItem.button {
            let link = button.displayLink(target: self, selector: #selector(displayLinkTick(_:)))
            displayLink = link
            link.add(to: .main, forMode: .common)
        } else {
            let timer = Timer(
                timeInterval: Tuning.gameLoopFallbackInterval,
                target: self,
                selector: #selector(fallbackTimerTick),
                userInfo: nil,
                repeats: true
            )
            fallbackTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    private func stopGameLoop() {
        displayLink?.invalidate()
        displayLink = nil
        fallbackTimer?.invalidate()
        fallbackTimer = nil
    }

    // Re-syncs the clock on the next tick (0 sentinel) and clears accumulated time.
    // Used when the driver (re)starts or the frame source changes under a live driver.
    private func resetGameLoopTiming() {
        lastTickTime = 0
        accumulatedFrameTime = 0
    }

    @available(macOS 14.0, *)
    @objc private func displayLinkTick(_ link: CADisplayLink) {
        advanceFrames(now: link.timestamp)
    }

    @objc private func fallbackTimerTick() {
        advanceFrames(now: ProcessInfo.processInfo.systemUptime)
    }

    private func advanceFrames(now: TimeInterval) {
        guard !baseDurations.isEmpty, !renderedFrames.isEmpty else { return }

        // First tick after a (re)start: just latch the clock, don't advance.
        if lastTickTime == 0 {
            lastTickTime = now
            return
        }

        let delta = now - lastTickTime
        lastTickTime = now
        // Ignore backwards jumps and large gaps (sleep/occlusion) instead of replaying
        // every skipped frame; the next tick resumes cleanly from the current frame.
        guard delta > 0, delta <= Tuning.maxFrameAdvanceDelta else { return }

        accumulatedFrameTime += delta
        var advanced = false

        while true {
            let baseDelay = baseDurations[frameIndex]
            let requiredDelay = max(baseDelay / speedMultiplier, Tuning.minGifFrameDelay)
            if accumulatedFrameTime >= requiredDelay {
                accumulatedFrameTime -= requiredDelay
                frameIndex = (frameIndex + 1) % baseDurations.count
                advanced = true
            } else {
                break
            }
        }

        if advanced {
            renderCurrentFrame()
        }
    }

    private func renderCurrentFrame() {
        guard let button = statusItem.button, !renderedFrames.isEmpty, frameIndex < renderedFrames.count else { return }
        button.image = renderedFrames[frameIndex]
    }

    private func effectiveOverlayText() -> String? {
        guard let raw = requestedOverlayText else { return nil }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private func updateRenderedFrames() {
        guard !frames.isEmpty else {
            renderedFrames = []
            return
        }

        let availableHeight = max(NSStatusBar.system.thickness - Tuning.renderVerticalInset, 1)
        let availableWidth = max(statusItem.length - Tuning.renderHorizontalInset, 1)
        let overlayText = effectiveOverlayText()

        var newRenderedFrames: [NSImage] = []
        newRenderedFrames.reserveCapacity(frames.count)

        for (i, rawImage) in frames.enumerated() {
            let aspect = i < frameAspects.count ? frameAspects[i] : Tuning.fallbackSlotScale
            let targetSize: NSSize
            
            if requestedWidthSlots != nil {
                targetSize = NSSize(width: availableWidth, height: availableHeight)
            } else {
                let maxHeight = max(availableHeight, Tuning.minIconDimension)
                let maxWidth = max(availableWidth, Tuning.minIconDimension)
                let targetHeight = min(maxHeight, maxWidth / max(aspect, Tuning.minAspect))
                let targetWidth = targetHeight * aspect
                targetSize = NSSize(width: targetWidth, height: targetHeight)
            }

            // Using closure initializer for Retina resolution scaling
            let rendered = NSImage(size: targetSize, flipped: false) { dstRect in
                let imageRect = NSRect(origin: .zero, size: targetSize)
                rawImage.draw(in: imageRect, from: NSRect(origin: .zero, size: rawImage.size), operation: .sourceOver, fraction: 1.0)

                if let text = overlayText {
                    let fontSize = min(max(targetSize.height * Tuning.overlayFontScale, Tuning.overlayMinFontSize), Tuning.overlayMaxFontSize)
                    let fontWeight: NSFont.Weight = self.requestedOverlayBold ? .bold : .regular
                    let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: fontWeight)
                    let paragraph = NSMutableParagraphStyle()
                    paragraph.alignment = .center
                    paragraph.lineBreakMode = .byTruncatingTail

                    let attributes: [NSAttributedString.Key: Any] = [
                        .font: font,
                        .foregroundColor: NSColor.white,
                        .strokeColor: NSColor.black,
                        .strokeWidth: Tuning.overlayStrokeWidth,
                        .paragraphStyle: paragraph
                    ]

                    let textSize = (text as NSString).size(withAttributes: attributes)
                    let textRect = NSRect(
                        x: Tuning.overlayHorizontalInset,
                        y: max((targetSize.height - textSize.height) / 2, Tuning.overlayVerticalInset),
                        width: max(targetSize.width - (Tuning.overlayHorizontalInset * 2), 1),
                        height: min(textSize.height, max(targetSize.height - (Tuning.overlayVerticalInset * 2), 1))
                    )
                    (text as NSString).draw(in: textRect, withAttributes: attributes)
                }
                return true
            }
            rendered.isTemplate = false
            newRenderedFrames.append(rendered)
        }
        renderedFrames = newRenderedFrames
    }

    private func applySizing() {
        guard !frames.isEmpty else { return }
        // imageScaling depends only on auto vs. fixed width, which changes on a width/preset
        // selection — never per frame. Set it here (every mode-change path calls applySizing)
        // rather than in the per-frame renderCurrentFrame hot path.
        statusItem.button?.imageScaling = requestedWidthSlots != nil ? .scaleAxesIndependently : .scaleProportionallyUpOrDown
        let baseSlotWidth = max(NSStatusBar.system.thickness, Tuning.minBaseSlotWidth)
        if requestedWidthSlots != nil {
            statusItem.length = ceil(baseSlotWidth * CGFloat(effectiveWidthSlots()))
        } else {
            statusItem.length = ceil(baseSlotWidth * currentPresetScale())
        }
        updateRenderedFrames()
    }

    private func effectiveWidthSlots() -> Int {
        let minSlots = minimumSlotsForCurrentPreset()
        let requested = requestedWidthSlots ?? minSlots
        return min(max(requested, minSlots), Tuning.maxWidthSlots)
    }

    private func minimumSlotsForCurrentPreset() -> Int {
        let scaled = Int(ceil(currentPresetScale()))
        return min(max(scaled, Tuning.minWidthSlots), Tuning.maxWidthSlots)
    }

    private func currentPresetScale() -> CGFloat {
        activePreset?.slotScale ?? defaultDescriptor?.slotScale ?? Tuning.fallbackSlotScale
    }

    private func currentSpeedProfile() -> SpeedProfile {
        activePreset?.speedProfile ?? defaultDescriptor?.speedProfile ?? Self.customSpeedProfile
    }

    // True when animation speed is CPU-driven (no `--speed-multiplier` override).
    private var isAutoSpeed: Bool { config.speedMultiplierOverride == nil }

    private func loadFrames(from path: String) -> Bool {
        let gifURL = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: gifURL.path) else {
            fputs("GIF file not found: \(gifURL.path)\n", stderr)
            return false
        }

        guard let src = CGImageSourceCreateWithURL(gifURL as CFURL, nil) else {
            fputs("Unable to open GIF source at \(gifURL.path)\n", stderr)
            return false
        }

        let count = CGImageSourceGetCount(src)
        guard count > 0 else {
            fputs("No image frames found in GIF: \(gifURL.path)\n", stderr)
            return false
        }

        var nextFrames: [NSImage] = []
        var nextAspects: [CGFloat] = []
        var nextDurations: [TimeInterval] = []
        nextFrames.reserveCapacity(count)
        nextAspects.reserveCapacity(count)
        nextDurations.reserveCapacity(count)

        for i in 0..<count {
            guard let cgImage = CGImageSourceCreateImageAtIndex(src, i, nil) else {
                continue
            }
            let preparedImage = trimTransparentPadding(from: cgImage)

            let duration = frameDuration(from: src, frameIndex: i)
            nextDurations.append(duration)

            let image = NSImage(
                cgImage: preparedImage,
                size: NSSize(width: preparedImage.width, height: preparedImage.height)
            )
            nextFrames.append(image)
            let aspect = preparedImage.height > 0
                ? CGFloat(preparedImage.width) / CGFloat(preparedImage.height)
                : Tuning.fallbackSlotScale
            nextAspects.append(max(aspect, Tuning.minAspect))
        }

        guard
            !nextFrames.isEmpty,
            nextFrames.count == nextDurations.count,
            nextFrames.count == nextAspects.count
        else {
            fputs("Failed to decode usable GIF frames from: \(gifURL.path)\n", stderr)
            return false
        }

        frames = nextFrames
        frameAspects = nextAspects
        baseDurations = nextDurations
        return true
    }

    private func trimTransparentPadding(from image: CGImage) -> CGImage {
        let bitmap = NSBitmapImageRep(cgImage: image)
        guard bitmap.hasAlpha, let base = bitmap.bitmapData else { return image }

        let width = bitmap.pixelsWide
        let height = bitmap.pixelsHigh
        let bytesPerRow = bitmap.bytesPerRow
        let bytesPerPixel = max(bitmap.samplesPerPixel, 1)
        guard width > 0, height > 0, bytesPerPixel >= Tuning.minAlphaPixelComponents else { return image }

        let alphaOffset: Int
        switch image.alphaInfo {
        case .alphaOnly, .first, .premultipliedFirst, .noneSkipFirst:
            alphaOffset = 0
        case .last, .premultipliedLast, .noneSkipLast:
            alphaOffset = bytesPerPixel - 1
        default:
            return image
        }

        var minX = width
        var maxX = -1
        var minY = height
        var maxY = -1
        for y in 0..<height {
            let row = base.advanced(by: y * bytesPerRow)
            for x in 0..<width {
                let pixel = row.advanced(by: x * bytesPerPixel)
                let alpha = pixel[alphaOffset]
                if alpha > Tuning.alphaVisibleThreshold {
                    if x < minX { minX = x }
                    if x > maxX { maxX = x }
                    if y < minY { minY = y }
                    if y > maxY { maxY = y }
                }
            }
        }

        guard maxX >= minX, maxY >= minY else { return image }
        if minX == 0 && maxX == width - 1 && minY == 0 && maxY == height - 1 {
            return image
        }

        let cropRect = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
        return image.cropping(to: cropRect) ?? image
    }

    private func frameDuration(from source: CGImageSource, frameIndex: Int) -> TimeInterval {
        guard
            let properties = CGImageSourceCopyPropertiesAtIndex(source, frameIndex, nil) as? [CFString: Any],
            let gifProperties = properties[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        else {
            return Tuning.defaultGifFrameDelay
        }

        let unclamped = gifProperties[kCGImagePropertyGIFUnclampedDelayTime] as? Double
        let clamped = gifProperties[kCGImagePropertyGIFDelayTime] as? Double
        let value = unclamped ?? clamped ?? Tuning.defaultGifFrameDelay
        return max(value, Tuning.minGifFrameDelay)
    }
}

switch Config.parse() {
case .config(let config):
    let app = NSApplication.shared
    let delegate = MenuBarLoadRunnerApp(config: config)
    app.delegate = delegate
    app.run()
case .help:
    exit(0)
case nil:
    exit(1)
}
