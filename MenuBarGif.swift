import AppKit
import CoreGraphics
import Darwin
import ImageIO

private enum Tuning {
    static let defaultGifFrameDelay: TimeInterval = 0.1
    static let minGifFrameDelay: TimeInterval = 0.02

    static let cpuSmoothingAlpha: Double = 0.2
    static let loadSampleInterval: TimeInterval = 2.0
    static let speedUpdateHysteresis: Double = 0.08
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
            gifPath = ProcessInfo.processInfo.environment["MENUBAR_GIF_PATH"]
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
        let envBin = ProcessInfo.processInfo.environment["MENUBAR_GIF_BIN_NAME"]
        let bin = (envBin?.isEmpty == false) ? envBin! : URL(fileURLWithPath: CommandLine.arguments[0]).lastPathComponent
        print("Usage: \(bin) <path-to-gif> [--width <slots:1..4>] [--speed-multiplier <x>] [--overlay-text <text:1...\(Tuning.overlayMaxChars) chars>]")
        print("   or: MENUBAR_GIF_PATH=<path-to-gif> \(bin) [--width <slots:1..4>] [--speed-multiplier <x>] [--overlay-text <text:1...\(Tuning.overlayMaxChars) chars>]")
        print("Default width: one slot (NSStatusItem.squareLength). With --width, GIF fills the configured slot count.")
        print("Width note: requested slots are clamped to each preset's minimum (e.g. totoro-group requires 4 slots).")
        print("Default speed: auto (preset-dependent; dog-white/dog-black/custom \(Tuning.dogSpeedMin)x..\((Tuning.dogSpeedMax))x, horse \(Tuning.horseSpeedMin)x..\((Tuning.horseSpeedMax))x, totoro \(Tuning.totoroSpeedMin)x..\((Tuning.totoroSpeedMax))x, totoro-group-white/black \(Tuning.totoroGroupSpeedMin)x..\((Tuning.totoroGroupSpeedMax))x, raining \(Tuning.rainingSpeedMin)x..\((Tuning.rainingSpeedMax))x).")
    }
}

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

private final class MenuBarGifApp: NSObject, NSApplicationDelegate, NSMenuDelegate {
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

    private let config: Config
    private let builtInDogWhitePath: String
    private let builtInDogBlackPath: String
    private let builtInHorseBlackPath: String
    private let builtInHorseWhitePath: String
    private let builtInTotoroPath: String
    private let builtInTotoroGroupWhitePath: String
    private let builtInTotoroGroupBlackPath: String
    private let builtInTotoroWhitePath: String
    private let builtInTotoroBlackPath: String
    private let builtInRainingPath: String
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
    private var dogWhitePresetItem: NSMenuItem!
    private var dogBlackPresetItem: NSMenuItem!
    private var horseBlackPresetItem: NSMenuItem!
    private var horseWhitePresetItem: NSMenuItem!
    private var totoroPresetItem: NSMenuItem!
    private var totoroGroupWhitePresetItem: NSMenuItem!
    private var totoroGroupBlackPresetItem: NSMenuItem!
    private var totoroWhitePresetItem: NSMenuItem!
    private var totoroBlackPresetItem: NSMenuItem!
    private var rainingPresetItem: NSMenuItem!
    private var frames: [NSImage] = []
    private var frameAspects: [CGFloat] = []
    private var baseDurations: [TimeInterval] = []
    private var frameIndex = 0
    private var displayLinkTimer: Timer?
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

    init(config: Config) {
        self.config = config
        self.activeGifPath = config.gifPath
        self.requestedWidthSlots = config.widthSlots
        self.requestedOverlayText = config.overlayText

        let scriptDirURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        self.builtInDogWhitePath = scriptDirURL.appendingPathComponent("gifs/running-dog-white.gif").path
        self.builtInDogBlackPath = scriptDirURL.appendingPathComponent("gifs/running-dog-black.gif").path
        self.builtInHorseBlackPath = scriptDirURL.appendingPathComponent("gifs/running-horse-black.gif").path
        self.builtInHorseWhitePath = scriptDirURL.appendingPathComponent("gifs/running-horse-white.gif").path
        self.builtInTotoroPath = scriptDirURL.appendingPathComponent("gifs/totoro.gif").path
        self.builtInTotoroGroupWhitePath = scriptDirURL.appendingPathComponent("gifs/totoro-group-white.gif").path
        self.builtInTotoroGroupBlackPath = scriptDirURL.appendingPathComponent("gifs/totoro-group-black.gif").path
        self.builtInTotoroWhitePath = scriptDirURL.appendingPathComponent("gifs/totoro-white.gif").path
        self.builtInTotoroBlackPath = scriptDirURL.appendingPathComponent("gifs/totoro-black.gif").path
        self.builtInRainingPath = scriptDirURL.appendingPathComponent("gifs/raining.gif").path
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = statusItem.button else {
            fatalError("Unable to create NSStatusItem button")
        }

        button.imagePosition = .imageOnly
        button.imageScaling = requestedWidthSlots == nil ? .scaleProportionallyUpOrDown : .scaleAxesIndependently
        button.toolTip = activeGifPath

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
        infoMenu.addItem(NSMenuItem(title: "Presets", action: nil, keyEquivalent: ""))

        dogWhitePresetItem = NSMenuItem(title: "Dog (White)", action: #selector(selectDogWhitePreset), keyEquivalent: "")
        dogWhitePresetItem.target = self
        infoMenu.addItem(dogWhitePresetItem)

        dogBlackPresetItem = NSMenuItem(title: "Dog (Black)", action: #selector(selectDogBlackPreset), keyEquivalent: "")
        dogBlackPresetItem.target = self
        infoMenu.addItem(dogBlackPresetItem)

        horseBlackPresetItem = NSMenuItem(title: "Horse (Black)", action: #selector(selectHorseBlackPreset), keyEquivalent: "")
        horseBlackPresetItem.target = self
        infoMenu.addItem(horseBlackPresetItem)

        horseWhitePresetItem = NSMenuItem(title: "Horse (White)", action: #selector(selectHorseWhitePreset), keyEquivalent: "")
        horseWhitePresetItem.target = self
        infoMenu.addItem(horseWhitePresetItem)

        totoroPresetItem = NSMenuItem(title: "Totoro", action: #selector(selectTotoroPreset), keyEquivalent: "")
        totoroPresetItem.target = self
        infoMenu.addItem(totoroPresetItem)

        totoroGroupWhitePresetItem = NSMenuItem(title: "Totoro (Group, White)", action: #selector(selectTotoroGroupWhitePreset), keyEquivalent: "")
        totoroGroupWhitePresetItem.target = self
        infoMenu.addItem(totoroGroupWhitePresetItem)

        totoroGroupBlackPresetItem = NSMenuItem(title: "Totoro (Group, Black)", action: #selector(selectTotoroGroupBlackPreset), keyEquivalent: "")
        totoroGroupBlackPresetItem.target = self
        infoMenu.addItem(totoroGroupBlackPresetItem)

        totoroWhitePresetItem = NSMenuItem(title: "Totoro (White)", action: #selector(selectTotoroWhitePreset), keyEquivalent: "")
        totoroWhitePresetItem.target = self
        infoMenu.addItem(totoroWhitePresetItem)

        totoroBlackPresetItem = NSMenuItem(title: "Totoro (Black)", action: #selector(selectTotoroBlackPreset), keyEquivalent: "")
        totoroBlackPresetItem.target = self
        infoMenu.addItem(totoroBlackPresetItem)

        rainingPresetItem = NSMenuItem(title: "Raining", action: #selector(selectRainingPreset), keyEquivalent: "")
        rainingPresetItem.target = self
        infoMenu.addItem(rainingPresetItem)

        infoMenu.addItem(NSMenuItem.separator())
        infoMenu.addItem(NSMenuItem(title: "About", action: #selector(showAbout), keyEquivalent: ""))
        infoMenu.addItem(NSMenuItem(title: "Exit", action: #selector(exitApp), keyEquivalent: "q"))
        infoMenu.items.forEach { $0.target = self }
        infoMenu.item(withTitle: "Presets")?.isEnabled = false
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
            self?.applySizing()
            self?.renderCurrentFrame()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        displayLinkTimer?.invalidate()
        loadTimer?.invalidate()
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
    }

    @objc
    private func showAbout() {
        let alert = NSAlert()
        alert.messageText = "About MenuBarGif"
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
        guard let source = NSImage(contentsOfFile: builtInHorseBlackPath) else {
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
        alert.messageText = "MenuBarGif startup error"
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
                    speedMultiplier = candidate
                    displayLinkTimer?.invalidate()
                    displayLinkTimer = nil
                    startGameLoop()
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
        } else {
            cpuUsageItem.title = "CPU Usage (smoothed): warming up..."
            cpuStateItem.title = "CPU State: warming up..."
        }

        if config.speedMultiplierOverride == nil {
            let profile = currentSpeedProfile()
            speedMultiplierItem.title = String(
                format: "Speed Multiplier (auto %@ %.2fx..%.2fx): %.2fx",
                profile.label,
                profile.min,
                profile.max,
                speedMultiplier
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
        dogWhitePresetItem.isEnabled = fileManager.fileExists(atPath: builtInDogWhitePath)
        dogBlackPresetItem.isEnabled = fileManager.fileExists(atPath: builtInDogBlackPath)
        horseBlackPresetItem.isEnabled = fileManager.fileExists(atPath: builtInHorseBlackPath)
        horseWhitePresetItem.isEnabled = fileManager.fileExists(atPath: builtInHorseWhitePath)
        totoroPresetItem.isEnabled = fileManager.fileExists(atPath: builtInTotoroPath)
        totoroGroupWhitePresetItem.isEnabled = fileManager.fileExists(atPath: builtInTotoroGroupWhitePath)
        totoroGroupBlackPresetItem.isEnabled = fileManager.fileExists(atPath: builtInTotoroGroupBlackPath)
        totoroWhitePresetItem.isEnabled = fileManager.fileExists(atPath: builtInTotoroWhitePath)
        totoroBlackPresetItem.isEnabled = fileManager.fileExists(atPath: builtInTotoroBlackPath)
        rainingPresetItem.isEnabled = fileManager.fileExists(atPath: builtInRainingPath)

        dogWhitePresetItem.state = activeGifPath == builtInDogWhitePath ? .on : .off
        dogBlackPresetItem.state = activeGifPath == builtInDogBlackPath ? .on : .off
        horseBlackPresetItem.state = activeGifPath == builtInHorseBlackPath ? .on : .off
        horseWhitePresetItem.state = activeGifPath == builtInHorseWhitePath ? .on : .off
        totoroPresetItem.state = activeGifPath == builtInTotoroPath ? .on : .off
        totoroGroupWhitePresetItem.state = activeGifPath == builtInTotoroGroupWhitePath ? .on : .off
        totoroGroupBlackPresetItem.state = activeGifPath == builtInTotoroGroupBlackPath ? .on : .off
        totoroWhitePresetItem.state = activeGifPath == builtInTotoroWhitePath ? .on : .off
        totoroBlackPresetItem.state = activeGifPath == builtInTotoroBlackPath ? .on : .off
        rainingPresetItem.state = activeGifPath == builtInRainingPath ? .on : .off
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
    private func selectDogWhitePreset() {
        switchToGif(at: builtInDogWhitePath)
    }

    @objc
    private func selectDogBlackPreset() {
        switchToGif(at: builtInDogBlackPath)
    }

    @objc
    private func selectHorseBlackPreset() {
        switchToGif(at: builtInHorseBlackPath)
    }

    @objc
    private func selectHorseWhitePreset() {
        switchToGif(at: builtInHorseWhitePath)
    }

    @objc
    private func selectTotoroPreset() {
        switchToGif(at: builtInTotoroPath)
    }

    @objc
    private func selectTotoroGroupWhitePreset() {
        switchToGif(at: builtInTotoroGroupWhitePath)
    }

    @objc
    private func selectTotoroGroupBlackPreset() {
        switchToGif(at: builtInTotoroGroupBlackPath)
    }

    @objc
    private func selectTotoroWhitePreset() {
        switchToGif(at: builtInTotoroWhitePath)
    }

    @objc
    private func selectTotoroBlackPreset() {
        switchToGif(at: builtInTotoroBlackPath)
    }

    @objc
    private func selectRainingPreset() {
        switchToGif(at: builtInRainingPath)
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

        let focusField: () -> Void = {
            let window = field.window ?? alert.window
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(field)
            field.selectText(nil)
            if let editor = field.currentEditor() {
                editor.selectedRange = NSRange(location: field.stringValue.count, length: 0)
            }
        }
        DispatchQueue.main.async(execute: focusField)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03, execute: focusField)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: focusField)

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

    private func switchToGif(at path: String) {
        let expanded = NSString(string: path).expandingTildeInPath
        guard expanded != activeGifPath else { return }

        let previousPath = activeGifPath
        let previousFrames = frames
        let previousDurations = baseDurations
        let previousFrameIndex = frameIndex

        guard loadFrames(from: expanded) else {
            activeGifPath = previousPath
            frames = previousFrames
            baseDurations = previousDurations
            frameIndex = previousFrameIndex
            showRuntimeError("Failed to load GIF at: \(expanded)")
            refreshPresetSelectionState()
            return
        }

        activeGifPath = expanded
        frameIndex = 0
        statusItem.button?.toolTip = activeGifPath

        applySizing()
        renderCurrentFrame()
        refreshWidthSelectionState()
        refreshOverlaySelectionState()

        displayLinkTimer?.invalidate()
        displayLinkTimer = nil
        startGameLoop()
        refreshPresetSelectionState()
    }

    private func showRuntimeError(_ message: String) {
        NSSound.beep()
        let alert = NSAlert()
        alert.messageText = "MenuBarGif"
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
        let value = profile.min + ((profile.max - profile.min) * curvedUsage)
        return min(max(value, profile.min), profile.max)
    }

    private func startGameLoop() {
        displayLinkTimer?.invalidate()
        lastTickTime = ProcessInfo.processInfo.systemUptime
        accumulatedFrameTime = 0

        let timer = Timer(timeInterval: 1.0 / 60.0, target: self, selector: #selector(gameLoopTick), userInfo: nil, repeats: true)
        displayLinkTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    @objc private func gameLoopTick() {
        guard !baseDurations.isEmpty, !renderedFrames.isEmpty else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let delta = now - lastTickTime
        lastTickTime = now

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
        if activeGifPath == builtInHorseBlackPath || activeGifPath == builtInHorseWhitePath {
            return Tuning.horseSlotScale
        }
        if activeGifPath == builtInTotoroGroupWhitePath || activeGifPath == builtInTotoroGroupBlackPath {
            return Tuning.totoroGroupSlotScale
        }
        if activeGifPath == builtInTotoroPath
            || activeGifPath == builtInTotoroWhitePath
            || activeGifPath == builtInTotoroBlackPath
        {
            return Tuning.totoroSlotScale
        }
        if activeGifPath == builtInRainingPath {
            return Tuning.rainingSlotScale
        }
        return Tuning.dogSlotScale
    }

    private func currentSpeedProfile() -> SpeedProfile {
        speedProfile(for: currentPresetKind())
    }

    private func currentPresetKind() -> PresetKind {
        if activeGifPath == builtInHorseBlackPath || activeGifPath == builtInHorseWhitePath {
            return .horse
        }
        if activeGifPath == builtInTotoroGroupWhitePath || activeGifPath == builtInTotoroGroupBlackPath {
            return .totoroGroup
        }
        if activeGifPath == builtInTotoroPath
            || activeGifPath == builtInTotoroWhitePath
            || activeGifPath == builtInTotoroBlackPath
        {
            return .totoro
        }
        if activeGifPath == builtInRainingPath {
            return .raining
        }
        if activeGifPath == builtInDogWhitePath || activeGifPath == builtInDogBlackPath {
            return .dog
        }
        return .custom
    }

    private func speedProfile(for preset: PresetKind) -> SpeedProfile {
        switch preset {
        case .dog:
            return SpeedProfile(
                label: "dog",
                min: Tuning.dogSpeedMin,
                max: Tuning.dogSpeedMax,
                responseExponent: Tuning.linearSpeedCurveExponent
            )
        case .horse:
            return SpeedProfile(
                label: "horse",
                min: Tuning.horseSpeedMin,
                max: Tuning.horseSpeedMax,
                responseExponent: Tuning.linearSpeedCurveExponent
            )
        case .totoro:
            return SpeedProfile(
                label: "totoro",
                min: Tuning.totoroSpeedMin,
                max: Tuning.totoroSpeedMax,
                responseExponent: Tuning.linearSpeedCurveExponent
            )
        case .totoroGroup:
            return SpeedProfile(
                label: "totoro-group",
                min: Tuning.totoroGroupSpeedMin,
                max: Tuning.totoroGroupSpeedMax,
                responseExponent: Tuning.linearSpeedCurveExponent
            )
        case .raining:
            return SpeedProfile(
                label: "raining",
                min: Tuning.rainingSpeedMin,
                max: Tuning.rainingSpeedMax,
                responseExponent: Tuning.rainingSpeedCurveExponent
            )
        case .custom:
            return SpeedProfile(
                label: "custom",
                min: Tuning.dogSpeedMin,
                max: Tuning.dogSpeedMax,
                responseExponent: Tuning.linearSpeedCurveExponent
            )
        }
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
    let delegate = MenuBarGifApp(config: config)
    app.delegate = delegate
    app.run()
case .help:
    exit(0)
case nil:
    exit(1)
}
