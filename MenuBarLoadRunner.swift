import AppKit
import CoreGraphics
import Darwin
import ImageIO
import QuartzCore

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
    static let dogSpeedMin: Double = 0.5
    static let dogSpeedMax: Double = 2.5
    static let horseSpeedMin: Double = 0.45
    static let horseSpeedMax: Double = 2.3
    static let totoroSpeedMin: Double = 0.5
    static let totoroSpeedMax: Double = 2.6
    static let totoroGroupSpeedMin: Double = 0.2
    static let totoroGroupSpeedMax: Double = 2.0
    static let rainingSpeedMin: Double = 0.15
    static let rainingSpeedMax: Double = 4.25
    static let linearSpeedCurveExponent: Double = 1.0
    static let rainingSpeedCurveExponent: Double = 2.6
    static let speedOverrideMin: Double = 0.1
    static let speedOverrideMax: Double = 5.0
    static let initialSpeedMultiplier: Double = 1.0
    static let percentScale: Double = 100.0

    static let renderVerticalInset: CGFloat = 4
    static let minIconDimension: CGFloat = 12
    static let renderHorizontalInset: CGFloat = 2
    static let minAspect: CGFloat = 0.01
    static let minBaseSlotWidth: CGFloat = 18
    static let horseSlotScale: CGFloat = 1.2
    static let totoroSlotScale: CGFloat = 1.25
    static let totoroGroupSlotScale: CGFloat = 4.0
    static let rainingSlotScale: CGFloat = 1.15
    static let dogSlotScale: CGFloat = 1.0

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

private struct Config {
    enum ParseResult {
        case config(Config)
        case help
    }

    let gifPath: String
    let widthSlots: Int?
    let speedMultiplierOverride: Double?
    let overlayText: String?

    static func parse() -> ParseResult? {
        let args = CommandLine.arguments.dropFirst()
        var gifPath: String?
        var widthSlots: Int?
        var speedMultiplierOverride: Double?
        var overlayText: String?

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
            default:
                if gifPath == nil {
                    gifPath = arg
                } else {
                    fputs("Unexpected argument: \(arg)\n", stderr)
                    printUsage()
                    return nil
                }
            }
        }

        if gifPath == nil {
            gifPath = ProcessInfo.processInfo.environment["MENUBAR_LOAD_RUNNER_PATH"]
        }

        guard let path = gifPath, !path.isEmpty else {
            fputs("Missing GIF path.\n", stderr)
            printUsage()
            return nil
        }

        return .config(
            Config(
                gifPath: NSString(string: path).expandingTildeInPath,
                widthSlots: widthSlots,
                speedMultiplierOverride: speedMultiplierOverride,
                overlayText: overlayText
            )
        )
    }

    static func printUsage() {
        let envBin = ProcessInfo.processInfo.environment["MENUBAR_LOAD_RUNNER_BIN_NAME"]
        let bin = (envBin?.isEmpty == false) ? envBin! : URL(fileURLWithPath: CommandLine.arguments[0]).lastPathComponent
        print("Usage: \(bin) <path-to-gif> [--width <slots:1..4>] [--speed-multiplier <x>] [--overlay-text <text:1...\(Tuning.overlayMaxChars) chars>]")
        print("   or: MENUBAR_LOAD_RUNNER_PATH=<path-to-gif> \(bin) [--width <slots:1..4>] [--speed-multiplier <x>] [--overlay-text <text:1...\(Tuning.overlayMaxChars) chars>]")
        print("Default width: one slot (NSStatusItem.squareLength). With --width, GIF fills the configured slot count.")
        print("Width note: requested slots are clamped to each preset's minimum (e.g. totoro-group requires 4 slots).")
        print("Default speed: auto (preset-dependent; dog-white/dog-black/custom \(Tuning.dogSpeedMin)x..\((Tuning.dogSpeedMax))x, horse \(Tuning.horseSpeedMin)x..\((Tuning.horseSpeedMax))x, totoro \(Tuning.totoroSpeedMin)x..\((Tuning.totoroSpeedMax))x, totoro-group-white/black \(Tuning.totoroGroupSpeedMin)x..\((Tuning.totoroGroupSpeedMax))x, raining \(Tuning.rainingSpeedMin)x..\((Tuning.rainingSpeedMax))x).")
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

@MainActor
private final class MenuBarLoadRunnerApp: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private enum PresetKind {
        case dog
        case horse
        case totoro
        case totoroGroup
        case raining
        case custom
    }

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
        let kind: PresetKind
        let slotScale: CGFloat
        let speedProfile: SpeedProfile
    }

    private static let customSpeedProfile = SpeedProfile(
        label: "custom",
        min: Tuning.dogSpeedMin,
        max: Tuning.dogSpeedMax,
        responseExponent: Tuning.linearSpeedCurveExponent
    )

    private let config: Config
    private let allPresets: [PresetDescriptor]
    private var activePreset: PresetDescriptor?
    private var activeGifPath: String
    private var statusItem: NSStatusItem!
    private var infoMenu: NSMenu!
    private var cpuUsageItem: NSMenuItem!
    private var loadAverageItem: NSMenuItem!
    private var cpuStateItem: NSMenuItem!
    private var speedMultiplierItem: NSMenuItem!
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
    private var loadMonitor = CPULoadMonitor()
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

        let scriptDirURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        func resolvedPath(_ relative: String) -> String {
            scriptDirURL.appendingPathComponent(relative).path
        }

        let dogProfile = SpeedProfile(label: "dog", min: Tuning.dogSpeedMin, max: Tuning.dogSpeedMax, responseExponent: Tuning.linearSpeedCurveExponent)
        let horseProfile = SpeedProfile(label: "horse", min: Tuning.horseSpeedMin, max: Tuning.horseSpeedMax, responseExponent: Tuning.linearSpeedCurveExponent)
        let totoroProfile = SpeedProfile(label: "totoro", min: Tuning.totoroSpeedMin, max: Tuning.totoroSpeedMax, responseExponent: Tuning.linearSpeedCurveExponent)
        let totoroGroupProfile = SpeedProfile(label: "totoro-group", min: Tuning.totoroGroupSpeedMin, max: Tuning.totoroGroupSpeedMax, responseExponent: Tuning.linearSpeedCurveExponent)
        let rainingProfile = SpeedProfile(label: "raining", min: Tuning.rainingSpeedMin, max: Tuning.rainingSpeedMax, responseExponent: Tuning.rainingSpeedCurveExponent)

        let presets: [PresetDescriptor] = [
            PresetDescriptor(key: "dog-white", menuTitle: "Dog (White)", path: resolvedPath("gifs/running-dog-white.gif"), kind: .dog, slotScale: Tuning.dogSlotScale, speedProfile: dogProfile),
            PresetDescriptor(key: "dog-black", menuTitle: "Dog (Black)", path: resolvedPath("gifs/running-dog-black.gif"), kind: .dog, slotScale: Tuning.dogSlotScale, speedProfile: dogProfile),
            PresetDescriptor(key: "horse-black", menuTitle: "Horse (Black)", path: resolvedPath("gifs/running-horse-black.gif"), kind: .horse, slotScale: Tuning.horseSlotScale, speedProfile: horseProfile),
            PresetDescriptor(key: "horse-white", menuTitle: "Horse (White)", path: resolvedPath("gifs/running-horse-white.gif"), kind: .horse, slotScale: Tuning.horseSlotScale, speedProfile: horseProfile),
            PresetDescriptor(key: "totoro", menuTitle: "Totoro", path: resolvedPath("gifs/totoro.gif"), kind: .totoro, slotScale: Tuning.totoroSlotScale, speedProfile: totoroProfile),
            PresetDescriptor(key: "totoro-group-white", menuTitle: "Totoro (Group, White)", path: resolvedPath("gifs/totoro-group-white.gif"), kind: .totoroGroup, slotScale: Tuning.totoroGroupSlotScale, speedProfile: totoroGroupProfile),
            PresetDescriptor(key: "totoro-group-black", menuTitle: "Totoro (Group, Black)", path: resolvedPath("gifs/totoro-group-black.gif"), kind: .totoroGroup, slotScale: Tuning.totoroGroupSlotScale, speedProfile: totoroGroupProfile),
            PresetDescriptor(key: "totoro-white", menuTitle: "Totoro (White)", path: resolvedPath("gifs/totoro-white.gif"), kind: .totoro, slotScale: Tuning.totoroSlotScale, speedProfile: totoroProfile),
            PresetDescriptor(key: "totoro-black", menuTitle: "Totoro (Black)", path: resolvedPath("gifs/totoro-black.gif"), kind: .totoro, slotScale: Tuning.totoroSlotScale, speedProfile: totoroProfile),
            PresetDescriptor(key: "raining", menuTitle: "Raining", path: resolvedPath("gifs/raining.gif"), kind: .raining, slotScale: Tuning.rainingSlotScale, speedProfile: rainingProfile),
        ]

        self.allPresets = presets
        self.activeGifPath = config.gifPath
        self.activePreset = presets.first { $0.path == config.gifPath }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = statusItem.button else {
            showStartupErrorAndQuit("Unable to create NSStatusItem button.")
            return
        }

        button.imagePosition = .imageOnly
        button.imageScaling = requestedWidthSlots == nil ? .scaleProportionallyUpOrDown : .scaleAxesIndependently
        button.toolTip = activeGifPath
        // Base label for VoiceOver; refreshMenuMetrics() enriches it with live CPU load.
        button.setAccessibilityLabel("MenuBar Load Runner")

        infoMenu = NSMenu()
        infoMenu.delegate = self

        cpuUsageItem = NSMenuItem(title: "CPU Usage: --", action: nil, keyEquivalent: "")
        cpuUsageItem.isEnabled = false
        infoMenu.addItem(cpuUsageItem)

        loadAverageItem = NSMenuItem(title: "Load Avg (1/5/15m): -- / -- / --", action: nil, keyEquivalent: "")
        loadAverageItem.isEnabled = false
        infoMenu.addItem(loadAverageItem)

        cpuStateItem = NSMenuItem(title: "CPU State: --", action: nil, keyEquivalent: "")
        cpuStateItem.isEnabled = false
        infoMenu.addItem(cpuStateItem)

        speedMultiplierItem = NSMenuItem(title: "Speed Multiplier: --", action: nil, keyEquivalent: "")
        speedMultiplierItem.isEnabled = false
        infoMenu.addItem(speedMultiplierItem)

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
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopGameLoop()
        loadTimer?.invalidate()
        for observer in [screenObserver, powerStateObserver, thermalStateObserver, occlusionObserver] {
            if let observer {
                NotificationCenter.default.removeObserver(observer)
            }
        }
    }

    @objc
    private func showAbout() {
        let alert = NSAlert()
        alert.messageText = "About MenuBar Load Runner"
        if let icon = makeMenuAlertIcon() {
            alert.icon = icon
        }
        let speedMode = config.speedMultiplierOverride == nil
            ? "Speed adapts to system CPU load."
            : "Fixed speed multiplier: \(String(format: "%.2f", speedMultiplier))x."
        alert.informativeText = "Displays an animated GIF in the macOS menu bar.\n\(speedMode)"
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
        let iconSize = NSSize(width: 48, height: 48)
        let icon = NSImage(size: iconSize)
        icon.lockFocus()
        source.draw(
            in: NSRect(origin: .zero, size: iconSize),
            from: NSRect(origin: .zero, size: source.size),
            operation: .sourceOver,
            fraction: 1.0
        )
        icon.unlockFocus()
        return icon
    }

    private func showStartupErrorAndQuit(_ message: String) {
        fputs(message + "\n", stderr)
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

        if let usage = loadMonitor.sampleUsage() {
            if config.speedMultiplierOverride == nil {
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

    func menuWillOpen(_ menu: NSMenu) {
        refreshMenuMetrics()
        refreshPresetSelectionState()
        refreshWidthSelectionState()
        refreshOverlaySelectionState()
    }

    private func refreshMenuMetrics() {
        if loadMonitor.hasSample {
            cpuUsageItem.title = String(format: "CPU Usage (smoothed): %.1f%%", loadMonitor.smoothedUsage * Tuning.percentScale)
            cpuStateItem.title = "CPU State: \(cpuStateText(for: loadMonitor.smoothedUsage))"
            statusItem.button?.setAccessibilityLabel(String(
                format: "MenuBar Load Runner — CPU %.0f%%, %@",
                loadMonitor.smoothedUsage * Tuning.percentScale,
                cpuStateText(for: loadMonitor.smoothedUsage)
            ))
        } else {
            cpuUsageItem.title = "CPU Usage (smoothed): warming up..."
            cpuStateItem.title = "CPU State: warming up..."
            statusItem.button?.setAccessibilityLabel("MenuBar Load Runner — measuring CPU load")
        }

        if config.speedMultiplierOverride == nil {
            let profile = currentSpeedProfile()
            let constrained = isUnderPowerPressure ? " [throttled: low power/thermal]" : ""
            speedMultiplierItem.title = String(
                format: "Speed Multiplier (auto %@ %.2fx..%.2fx): %.2fx%@",
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

    private func refreshPresetSelectionState() {
        let fileManager = FileManager.default
        for (item, preset) in zip(presetMenuItems, allPresets) {
            item.isEnabled = fileManager.fileExists(atPath: preset.path)
            item.state = (activePreset?.key == preset.key) ? .on : .off
        }
    }

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
            requestedOverlayText = nil
            updateRenderedFrames()
            renderCurrentFrame()
            refreshOverlaySelectionState()
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

    // Reads system power/thermal state (getters only — never mutates it). True when
    // the Mac is in Low Power Mode or thermally throttling, i.e. when this app should
    // reduce its OWN animation work rather than add to the load it's displaying.
    private var isUnderPowerPressure: Bool {
        let info = ProcessInfo.processInfo
        if info.isLowPowerModeEnabled { return true }
        switch info.thermalState {
        case .serious, .critical: return true
        default: return false
        }
    }

    // Recompute this app's OWN auto animation speed from the latest smoothed usage
    // immediately, bypassing the sample-tick hysteresis. Called when power/thermal
    // state flips so the app's self-imposed speed cap engages (or lifts) without
    // waiting for the next loadSampleInterval tick. Changes nothing outside this app.
    private func reevaluateSpeedForCurrentConditions() {
        guard config.speedMultiplierOverride == nil, loadMonitor.hasSample else { return }
        speedMultiplier = speedMultiplier(forUsage: loadMonitor.smoothedUsage)
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
        
        button.imageScaling = requestedWidthSlots != nil ? .scaleAxesIndependently : .scaleProportionallyUpOrDown
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
            let aspect = i < frameAspects.count ? frameAspects[i] : Tuning.dogSlotScale
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
        activePreset?.slotScale ?? Tuning.dogSlotScale
    }

    private func currentSpeedProfile() -> SpeedProfile {
        activePreset?.speedProfile ?? Self.customSpeedProfile
    }

    private func currentPresetKind() -> PresetKind {
        activePreset?.kind ?? .custom
    }

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
                : Tuning.dogSlotScale
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
