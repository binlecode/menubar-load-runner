import AppKit
import CoreGraphics
import Darwin
import ImageIO
import IOKit
import IOKit.ps
import QuartzCore

// Human-facing app version (semver). Surfaced in --help and the About dialog, and the anchor for
// CHANGELOG.md releases. Bump this together with a new CHANGELOG entry and git tag.
private enum AppInfo {
    static let version = "1.10.0"
    static let name = "MenuBar Load Runner"
    static let tagline = "An animated GIF in the macOS menu bar, its playback speed driven by live system load."
    static let copyright = "© 2026 Bin Le"
    static let license = "MIT License"
    static let repositoryURL = "https://github.com/binlecode/menubar-load-runner"
    static var releasesURL: String { "\(repositoryURL)/releases" }
}

// A strict three-component semantic version (major.minor.patch). Used to compare the compiled-in
// AppInfo.version against the newest release tag on the origin remote (see UpdateChecker). The parse
// is deliberately strict — exactly three numeric components — so moved/dereferenced tags, pre-release
// tags (v1.2.3-rc1), and junk are rejected rather than mis-ranked.
private struct SemVer: Comparable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int

    // Accepts "1.6.0" or "v1.6.0" (a leading v/V is stripped). Returns nil for anything that is not
    // exactly three non-negative integer components.
    init?(_ raw: String) {
        var s = raw.trimmingCharacters(in: .whitespaces)
        if let first = s.first, first == "v" || first == "V" {
            s.removeFirst()
        }
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var nums: [Int] = []
        for part in parts {
            // Reject signs, spaces, and non-digits — Int("+1")/Int("1 ") would otherwise slip through
            // some inputs; require the component to be all ASCII digits and parseable.
            guard !part.isEmpty, part.allSatisfy(\.isNumber), let n = Int(part) else { return nil }
            nums.append(n)
        }
        (major, minor, patch) = (nums[0], nums[1], nums[2])
    }

    static func < (lhs: SemVer, rhs: SemVer) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }

    // Bare "1.6.0" form; callers prepend "v" for tag/menu display.
    var description: String { "\(major).\(minor).\(patch)" }
    var tagString: String { "v\(description)" }
}

// Detects whether a newer release exists by reading the origin remote's release tags. Uses
// `git ls-remote` rather than the GitHub API: no token, no rate limit, and it honors the checkout's
// actual origin (forks, and the MENUBAR_LOAD_RUNNER_REPO_URL test override). Fail-silent by design —
// any failure (offline, git missing, non-zero exit) yields nil, never an error surfaced to the user.
private enum UpdateChecker {
    // Result of running git: exit status plus captured stdout/stderr. nil (from runGit) means git
    // couldn't be launched at all (missing binary) — indistinguishable enough from failure that
    // callers treat both as "no result".
    struct GitResult { let status: Int32; let stdout: String; let stderr: String }

    // Runs `git -C <repoDir> <args…>` and captures both streams. Blocking — callers dispatch this off
    // the main thread. Read-then-wait is safe here because git's output for our commands (ls-remote /
    // ff-only pull) is far under the OS pipe buffer, so neither stream can block the child.
    private static func runGit(_ args: [String], in repoDir: URL) -> GitResult? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", repoDir.path] + args
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        do {
            try process.run()
        } catch {
            return nil
        }
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return GitResult(
            status: process.terminationStatus,
            stdout: String(data: outData, encoding: .utf8) ?? "",
            stderr: String(data: errData, encoding: .utf8) ?? ""
        )
    }

    // Runs `git ls-remote --tags --refs origin 'v*'` and returns the highest release tag as a SemVer,
    // or nil on any failure / no tags. `--refs` strips the peeled "^{}" dereference lines; "v*" is a
    // literal argument (no shell), so git does the server-side ref matching.
    static func latestRemoteTag(repoDir: URL) -> SemVer? {
        guard let result = runGit(["ls-remote", "--tags", "--refs", "origin", "v*"], in: repoDir),
              result.status == 0 else {
            return nil
        }
        return highestTag(inLsRemoteOutput: result.stdout)
    }

    // Fast-forward-only pull. Returns whether it succeeded plus a human-readable message (git's own
    // output on failure — dirty tree, non-fast-forward, conflict). Never --force / reset --hard, so a
    // diverged or dirty checkout aborts cleanly rather than losing work. Blocking; dispatch off-main.
    static func pull(repoDir: URL) -> (ok: Bool, message: String) {
        guard let result = runGit(["pull", "--ff-only"], in: repoDir) else {
            return (false, "Could not run git.")
        }
        if result.status == 0 {
            return (true, result.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let raw = result.stderr.isEmpty ? result.stdout : result.stderr
        return (false, raw.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // Parses `ls-remote` output: each line is "<sha>\trefs/tags/<tag>". Extracts the tag after the
    // last "refs/tags/", keeps only strict three-component SemVers, and returns the max. Pure/testable
    // (no process), so QA can feed canned lines without a network.
    static func highestTag(inLsRemoteOutput text: String) -> SemVer? {
        text.split(whereSeparator: \.isNewline)
            .compactMap { line -> SemVer? in
                guard let range = line.range(of: "refs/tags/", options: .backwards) else { return nil }
                return SemVer(String(line[range.upperBound...]))
            }
            .max()
    }
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
    // How many 0…1 load samples the menu's trace chart retains (one per loadSampleInterval tick).
    // 30 × 2s ≈ 60s of visible history.
    static let loadHistoryCapacity: Int = 30
    // Per-preset speed ranges now live in gifs/presets.json (see PresetManifest), not here — the
    // manifest is the single source of truth for preset profiles. Width is not a preset constant;
    // it's derived at runtime from each GIF's real aspect ratio (see currentGifAspect/slotLength).
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
    // Byte-unit divisors, shared by the ceiling floors below and the MB/GB menu readouts.
    static let bytesPerMiB: Double = 1_048_576
    static let bytesPerGiB: Double = 1_073_741_824
    // Per-source ceiling floors. btop uses 10 KiB/s; we raise them so idle background chatter
    // (keepalive packets, housekeeping I/O, lazy swap) doesn't peg a menu-bar toy at full speed.
    static let networkFloorBytesPerSec: Double = 1 * bytesPerMiB
    static let diskFloorBytesPerSec: Double = 4 * bytesPerMiB
    static let swapFloorBytesPerSec: Double = 1 * bytesPerMiB
    // Battery discharge-current ceiling floor (milliamps). Not a byte rate, but the same adaptive
    // ThroughputScaler normalizes it: idle laptop draw sits a few hundred mA, so this floor keeps a
    // resting drain from pegging the animation while still letting a real workload's multi-amp draw
    // rise through the range.
    static let batteryFloorMilliamps: Double = 500

    // Memory used-fraction rests high on a healthy Mac (the OS holds most physical RAM as cache/
    // wired), so a linear map from raw used-fraction would drive the animation well up its speed
    // range while the machine is effectively idle. This floor is subtracted from the *used-fraction
    // term only* (see MemoryLoadMonitor.sampleUsage) and the remainder rescaled to 0…1, so an idle
    // Mac reads ~0 and the full min..max range maps onto the fraction's real operating band. It is a
    // deliberate fixed approximation (real idle varies with RAM size/workload); the swap-rate term is
    // already 0-based via ThroughputScaler and is NOT floored. The menu still shows the raw fraction.
    static let memoryIdleFloor: Double = 0.55

    static let renderVerticalInset: CGFloat = 4
    static let minIconDimension: CGFloat = 12
    static let renderHorizontalInset: CGFloat = 2
    static let minAspect: CGFloat = 0.01
    // Minimum status-item length (points) so a tall/narrow GIF still gets a tappable slot.
    static let minBaseSlotWidth: CGFloat = 18
    // Neutral aspect (width/height) fallback used when a frame's real aspect is unavailable.
    static let fallbackAspect: CGFloat = 1.0
    // Upper bound on the GIF-derived slot aspect, so a freakishly wide GIF can't blow out the bar.
    static let maxIconAspect: CGFloat = 6.0

    static let loadAverageSampleCount = 3
    static let loadAverage1mIndex = 0
    static let loadAverage5mIndex = 1
    static let loadAverage15mIndex = 2
    static let minAlphaPixelComponents = 4
    static let alphaVisibleThreshold: UInt8 = 3
    // Max length of a custom menu-bar label (the adjacent text slot). The slot auto-sizes
    // (variableLength), so this only bounds how much menu-bar width one instance may claim; live-value
    // readouts are always short and unaffected.
    static let labelMaxChars = 24

    // Keep Awake auto-disengage: on battery power at or below this charge fraction
    // we kill `caffeinate` so an unattended Mac doesn't drain to death mid-task. See SleepPreventer.
    static let batteryLowThreshold: Double = 0.20

    // Battery trace-chart color bands (charge fraction). The chart is a fuel gauge for the battery
    // source — low = alert — so it reuses batteryLowThreshold (≤20% → red) plus this mid band
    // (≤40% → yellow, else green), mirroring the macOS low-battery convention.
    static let batteryChargeMediumThreshold: Double = 0.40

    // Keep-awake track line tints — a warm/cool pairing (design POC). Each option carries two tones
    // so the 2pt line holds contrast on both menu-bar appearances: lighter on a dark bar, deeper on a
    // light one (the bestMatch lives in KeepAwakeColor.color(for:)). "Dusty Teal" is the default —
    // being chromatic it reads on grayscale preset art by hue rather than lightness, so it stays
    // legible even on full-height art where the near-neutral "Sand" companion can fade. The two are
    // user-selectable via the Keep Awake Color submenu.
    static let keepAwakeBarTealDark = NSColor(srgbRed: 0.51, green: 0.70, blue: 0.69, alpha: 1)  // #82B3AF
    static let keepAwakeBarTealLight = NSColor(srgbRed: 0.33, green: 0.50, blue: 0.49, alpha: 1) // #557F7C
    static let keepAwakeBarSandDark = NSColor(srgbRed: 0.847, green: 0.765, blue: 0.608, alpha: 1) // #D8C39B
    static let keepAwakeBarSandLight = NSColor(srgbRed: 0.698, green: 0.604, blue: 0.431, alpha: 1) // #B29A6E
    static let keepAwakeBarThickness: CGFloat = 2

    // Selection-mark dot size, as a fraction of the menu font's cap height (the same font the
    // disclosure header draws its ▸ at), so the dot reads at that toggle's scale rather than the
    // oversized native ✓. ~0.6 gives a compact bullet, not a heavy blob.
    static let menuSelectionMarkCapHeightFraction: CGFloat = 0.6
}

// Centralized menu-item vocabulary — every fixed label and every label *prefix* that a refresh
// function rebuilds lives here, so a rename touches one site and the placeholder can't drift from
// the live value. Data-driven groups (LoadSource.menuTitle, PresetDescriptor.menuTitle,
// KeepAwakeColor.menuTitle) are already single-source and stay there; this namespace covers the
// literals that were previously inlined at both a creation site and a refresh site.
//
// Two rows model a qualifier that sits *between* the prefix and the colon (`CPU Usage (smoothed):`,
// `Speed Multiplier (auto: …)`): the bare prefix is stored once and the qualified forms derive from
// it via the helpers below, so the placeholder and refresh can't disagree as they did before.
//
// Ellipsis style is frozen as-is per string (some use `…`, some ASCII `...`) — this is a pure
// centralization, not a wording change, so titles render byte-for-byte identical.
private enum MenuTitle {
    // Group 1 — static, single-site labels (moved for inventory completeness).
    static let loadHistory = "Load History"
    static let keepAwake = "Keep Awake"
    static let keepAwakeColor = "Keep Awake Color"
    // The disclosure header row uses a view (DisclosureMenuItemView) that draws its own ▸/▾ glyph, so
    // only the bare label lives here.
    static let otherSources = "Other Sources"
    static let presets = "Presets"
    static let about = "About"
    static let exit = "Exit"
    static let clear = "Clear"

    // Update-check items.
    static let updateAvailablePrefix = "Update available"
    static let checkForUpdates = "Check for Updates…"
    static let checkingForUpdates = "Checking for Updates…"

    // Menu-bar label (the adjacent value/text slot).
    static let labelPrefix = "Menu Bar Label"
    static func label(_ suffix: String) -> String { "\(labelPrefix): \(suffix)" }
    static let labelOff = "off"
    static let labelOffItem = "Off"
    static let labelValueItem = "Live Value"
    static func labelCustomItem(max: Int) -> String { "Custom Text… (max \(max))" }

    // Read-only readouts.
    static let widthPrefix = "Width"
    static let placeholderValue = "--"
    static let warmingUp = "warming up..."
    static let loadAvgPrefix = "Load Avg (1/5/15m)"
    static let loadAvgUnavailable = "unavailable"

    // Generic "<Prefix>: <value>" formatter — the shape every readout line shares, so the prefix is
    // stored once and both the placeholder and the refresh format through this.
    static func line(_ prefix: String, _ value: String) -> String { "\(prefix): \(value)" }

    // Metric state line. Derives as "<Source> State:" for every source EXCEPT .memory (which shows
    // "Memory Pressure:"); the usage prefix is source-specific (`.cpu` qualifies with "(smoothed)",
    // the rest use a bare "<Source>:").
    static let memoryPressurePrefix = "Memory Pressure"
    static func statePrefix(for source: LoadSource) -> String { "\(source.menuTitle) State" }

    static let cpuUsagePrefix = "CPU Usage"
    static let cpuUsageQualified = "\(cpuUsagePrefix) (smoothed)"

    // Speed multiplier. Bare prefix stored once; the qualified forms (auto/fixed) derive from it so
    // the placeholder ("Speed Multiplier: --") and the refresh ("Speed Multiplier (auto: …)") share
    // a base and can't drift.
    static let speedMultiplierPrefix = "Speed Multiplier"
    static func speedAuto(_ source: String) -> String { "\(speedMultiplierPrefix) (auto: \(source))" }
    static let speedFixed = "\(speedMultiplierPrefix) (fixed)"

    // Self-throttle line.
    static let slowingAnimation = "Slowing animation"
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
    case fan = 5
    case battery = 6

    var key: String {
        switch self {
        case .cpu: return "cpu"
        case .memory: return "memory"
        case .gpu: return "gpu"
        case .network: return "network"
        case .disk: return "disk"
        case .fan: return "fan"
        case .battery: return "battery"
        }
    }

    var menuTitle: String {
        switch self {
        case .cpu: return "CPU"
        case .memory: return "Memory"
        case .gpu: return "GPU"
        case .network: return "Network"
        case .disk: return "Disk"
        case .fan: return "Fan"
        case .battery: return "Battery"
        }
    }

    static func from(key: String?) -> LoadSource? {
        guard let key = key?.lowercased(), !key.isEmpty else { return nil }
        return allCases.first { $0.key == key }
    }
}

// The optional second menu-bar slot's content. `.off` claims no slot; `.value` shows the active
// source's live reading (refreshed on the 2s tick); `.custom` shows a fixed user string (handy for
// labeling multiple instances). Replaces the old baked-on overlay, which was illegible atop a 22pt
// animated icon — an adjacent slot renders in the native menu-bar font instead. Parsed from
// `--label <off|value|text>` / MENUBAR_LOAD_RUNNER_LABEL; `off` and `value` are reserved keywords, so
// a literal custom label of "off"/"value" isn't expressible (documented; a non-issue in practice).
private enum MenuBarLabel: Equatable {
    case off
    case value
    case custom(String)

    // Parse a raw `--label` / env value. nil/empty → .off. "off"/"value" are keywords; anything else
    // is trimmed and truncated to Tuning.labelMaxChars as custom text (empty after trim → .off).
    static func parse(_ raw: String?) -> MenuBarLabel {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return .off }
        switch raw.lowercased() {
        case "off": return .off
        case "value": return .value
        default: return .custom(String(raw.prefix(Tuning.labelMaxChars)))
        }
    }
}

// Keep-awake bar tint options. A registry (menu title + per-appearance tint) so the menu items, the
// radio-selection check, and the drawn bar color all derive from one source of truth — mirroring
// LoadSource/PresetDescriptor. The pairing is the design POC's verdict: cool Dusty Teal drives the
// mark (default), with near-neutral Sand as the warm companion. Menu-only, like Keep Awake itself —
// no CLI/env, so the rawValue exists only to tag the menu items for the radio group.
private enum KeepAwakeColor: Int, CaseIterable {
    case teal = 0
    case sand = 1

    var menuTitle: String {
        switch self {
        case .teal: return "Dusty Teal"
        case .sand: return "Sand"
        }
    }

    // Lighter tone on a dark menu bar, deeper on a light one — the same bestMatch the rest of the app
    // uses for appearance-aware drawing, so the choice keeps its identity across theme switches.
    func color(for appearance: NSAppearance?) -> NSColor {
        let dark = appearance?.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        switch self {
        case .teal: return dark ? Tuning.keepAwakeBarTealDark : Tuning.keepAwakeBarTealLight
        case .sand: return dark ? Tuning.keepAwakeBarSandDark : Tuning.keepAwakeBarSandLight
        }
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
    let speedMultiplierOverride: Double?
    // Content of the optional adjacent menu-bar label slot. Resolved from --label / env here.
    let label: MenuBarLabel
    // Which reader drives the animation. Resolved from --load-source / env here (unknown →
    // .cpu, never a launch failure), so the app receives a concrete source, not a raw string.
    let loadSource: LoadSource
    // Debug/test hook: if MENUBAR_LOAD_RUNNER_EXIT_AFTER=<seconds> (>0) is set, the app
    // self-terminates after that many seconds. Lets a smoke test exit 0 on its own instead of
    // an external kill/timeout against the blocking AppKit run loop. nil = run until quit.
    let exitAfterSeconds: TimeInterval?
    // Whether to probe origin's release tags on launch (and enable the manual "Check for Updates…").
    // Default true; disabled by --no-update-check or MENUBAR_LOAD_RUNNER_UPDATE_CHECK ∈ {0,false,no}.
    let updateCheckEnabled: Bool
    // Launch default for the multi-source dashboard mode. Default false (active-only sampling);
    // enabled by --show-all-sources or MENUBAR_LOAD_RUNNER_SHOW_ALL ∈ {1,true,yes}. Still runtime-
    // toggleable from the menu regardless.
    let showAllSources: Bool

    static func parse() -> ParseResult? {
        let args = CommandLine.arguments.dropFirst()
        var presetOrPath: String?
        var speedMultiplierOverride: Double?
        var labelArg: String?
        var loadSourceArg: String?
        var updateCheckEnabled = true
        var showAllSources = false

        var iterator = args.makeIterator()
        while let arg = iterator.next() {
            switch arg {
            case "--help", "-h":
                printUsage()
                return .help
            case "--speed-multiplier":
                guard let value = iterator.next(), let parsed = Double(value), parsed > 0 else {
                    fputs("Invalid value for --speed-multiplier. Expected a positive number.\n", stderr)
                    printUsage()
                    return nil
                }
                speedMultiplierOverride = parsed
            case "--label":
                guard let value = iterator.next() else {
                    fputs("Invalid value for --label. Expected off, value, or custom text.\n", stderr)
                    printUsage()
                    return nil
                }
                labelArg = value
            case "--load-source":
                guard let value = iterator.next() else {
                    fputs("Invalid value for --load-source. Expected one of: \(LoadSource.allCases.map(\.key).joined(separator: ", ")).\n", stderr)
                    printUsage()
                    return nil
                }
                loadSourceArg = value
            case "--no-update-check":
                updateCheckEnabled = false
            case "--show-all-sources":
                showAllSources = true
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

        if labelArg == nil {
            labelArg = ProcessInfo.processInfo.environment["MENUBAR_LOAD_RUNNER_LABEL"]
        }
        let label = MenuBarLabel.parse(labelArg)
        // Unknown/absent → .cpu (today's behavior). Never a launch failure, per spec.
        var loadSource = LoadSource.from(key: loadSourceArg) ?? .cpu
        if let requested = loadSourceArg, LoadSource.from(key: requested) == nil, !requested.isEmpty {
            fputs("Unknown --load-source \"\(requested)\"; falling back to cpu. Known: \(LoadSource.allCases.map(\.key).joined(separator: ", ")).\n", stderr)
        }

        // Forgiveness: a load-source keyword (cpu/memory/gpu/network/disk) typed in the POSITIONAL
        // (preset) slot is a common mix-up with --load-source — and would otherwise be treated as a
        // GIF path and fail to launch with a fatal error box. Interpret it as the load source and let
        // the default preset stand in. An explicit --load-source always wins.
        var positional = value
        if let src = LoadSource.from(key: positional) {
            if loadSourceArg == nil || loadSourceArg?.isEmpty == true {
                loadSource = src
                fputs("Interpreting positional \"\(positional)\" as --load-source \(src.key); using the default preset. (Pass a preset keyword or GIF path as the positional argument.)\n", stderr)
            } else {
                fputs("Ignoring positional \"\(positional)\" (looks like a load source, but --load-source \(loadSource.key) was given); using the default preset.\n", stderr)
            }
            positional = ""
        }

        var exitAfterSeconds: TimeInterval?
        if let raw = ProcessInfo.processInfo.environment["MENUBAR_LOAD_RUNNER_EXIT_AFTER"],
           let parsed = Double(raw), parsed > 0 {
            exitAfterSeconds = parsed
        }

        // Env can only disable (the --no-update-check flag already covers the CLI side). If the flag
        // disabled it, the env check is moot.
        if updateCheckEnabled,
           let raw = ProcessInfo.processInfo.environment["MENUBAR_LOAD_RUNNER_UPDATE_CHECK"]?.lowercased(),
           ["0", "false", "no"].contains(raw) {
            updateCheckEnabled = false
        }

        // Env can only enable the launch default (the menu toggle covers turning it off at runtime).
        if !showAllSources,
           let raw = ProcessInfo.processInfo.environment["MENUBAR_LOAD_RUNNER_SHOW_ALL"]?.lowercased(),
           ["1", "true", "yes"].contains(raw) {
            showAllSources = true
        }

        return .config(
            Config(
                presetOrPath: NSString(string: positional).expandingTildeInPath,
                speedMultiplierOverride: speedMultiplierOverride,
                label: label,
                loadSource: loadSource,
                exitAfterSeconds: exitAfterSeconds,
                updateCheckEnabled: updateCheckEnabled,
                showAllSources: showAllSources
            )
        )
    }

    static func printUsage() {
        let envBin = ProcessInfo.processInfo.environment["MENUBAR_LOAD_RUNNER_BIN_NAME"]
        let bin = (envBin?.isEmpty == false) ? envBin! : URL(fileURLWithPath: CommandLine.arguments[0]).lastPathComponent
        print("MenuBar Load Runner \(AppInfo.version)")
        print("Usage: \(bin) <preset-name|path-to-gif> [--speed-multiplier <x>] [--label <off|value|text>] [--load-source <\(LoadSource.allCases.map(\.key).joined(separator: "|"))>] [--show-all-sources] [--no-update-check]")
        print("   or: MENUBAR_LOAD_RUNNER_PATH=<path-to-gif> \(bin) [--speed-multiplier <x>] [--label <off|value|text>] [--load-source <\(LoadSource.allCases.map(\.key).joined(separator: "|"))>] [--show-all-sources] [--no-update-check]")
        print("Load source: which reader drives animation speed (default cpu). Also via MENUBAR_LOAD_RUNNER_LOAD_SOURCE; unknown values fall back to cpu.")
        print("Label: an optional second menu-bar slot. --label value shows the active source's live reading; --label <text> (up to \(Tuning.labelMaxChars) chars) shows a fixed label; --label off (default) shows nothing. Also via MENUBAR_LOAD_RUNNER_LABEL; switchable from the menu.")
        print("Show all sources: --show-all-sources (or MENUBAR_LOAD_RUNNER_SHOW_ALL=1) starts with the menu's \"Other Sources\" list expanded, sampling every available reader and showing each as a live row; click a row to switch the driving source. Collapsed by default (active source only). Toggle from the menu's disclosure header.")
        print("Width: the menu-bar item sizes itself to the GIF's aspect ratio at menu-bar height — not configurable.")
        print("Default speed: auto (preset-dependent; per-preset ranges defined in gifs/presets.json).")
        print("Updates: on launch, checks the git origin's release tags for a newer version (network access). Apply is a menu click; disable with --no-update-check or MENUBAR_LOAD_RUNNER_UPDATE_CHECK=0.")
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
    // Composite driver value: max(idleFloored(usedFraction), adaptiveScaled(swapRate)). The used-
    // fraction is floored/rescaled by Tuning.memoryIdleFloor before the max, so it drives ~0 on an
    // idle Mac; the scaled swap rate (0-based) takes over once paging warms up (one tick) and rises
    // above it. currentUsedFraction (the menu figure) stays the RAW fraction. See Tuning /
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
        // Reclaim the high resting band of the used-fraction (see Tuning.memoryIdleFloor) so an idle
        // Mac drives ~0 speed and the full range maps onto the fraction's real operating band. Applied
        // to the used-fraction term ONLY — swapLoad is already 0-based, so it's max'd in unfloored.
        let flooredUsed = max(0, (sample.usedFraction - Tuning.memoryIdleFloor) / (1 - Tuning.memoryIdleFloor))
        currentMemoryLoad = max(flooredUsed, swapLoad)
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

// Fan speed as a 0…1 *thermal/cooling* load — a lagging signal (fans trail actual work by seconds and
// ramp only under sustained thermal load), so this reads "how hard is cooling working," not
// instantaneous compute. Ported from actop's SMCReader: opens
// AppleSMCKeysEndpoint unprivileged and read-only (never writes fan-control keys F{n}Tg/F{n}Md,
// which need root), discovers per-fan actual/max RPM keys (F{n}Ac / F{n}Mx, SMC type "flt ", 4-byte
// little-endian float) via the FNum fan count. Fanless Macs (MacBook Air, most M-series laptops)
// report FNum == 0 → isAvailable false → the source disables and launch falls back to CPU. Bounded
// per-machine, so it maps through as a percentage (max across fans of actual/max) — NOT via
// ThroughputScaler (that's only for unbounded byte/sec rates). actual/max (rather than the
// min-anchored (actual-min)/(max-min)) is deliberate: idle RPM ≈ min sits well above 0, so the
// animation keeps some visible motion even when the fans are barely spinning. `nil`, never a
// fabricated 0, on any read failure. This is the only reader using the *undocumented* 80-byte
// SMCKeyData struct layout (the stable, reverse-engineered layout every fan tool uses); we guard on
// its computed stride == 80 and disable the source if a future toolchain lays it out differently.
@MainActor
private final class FanLoadMonitor {
    // One fan's current readout: actual RPM and its 0…1 utilization (actual/max).
    struct FanReading { let rpm: Double; let utilization: Double }
    // Average utilization across fans — drives the animation. Per-fan readings (one menu line
    // per fan) are in `perFan`.
    private(set) var currentUtilization: Double = 0
    private(set) var perFan: [FanReading] = []
    private(set) var hasSample = false

    // --- SMC KeyData struct (natural C alignment; total stride must be 80 to match the kernel) ---
    private typealias SMCBytes = (
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
    )
    private struct SMCVersion { var major: UInt8 = 0; var minor: UInt8 = 0; var build: UInt8 = 0; var reserved: UInt8 = 0; var release: UInt16 = 0 }
    private struct SMCPLimitData { var version: UInt16 = 0; var length: UInt16 = 0; var cpuPLimit: UInt32 = 0; var gpuPLimit: UInt32 = 0; var memPLimit: UInt32 = 0 }
    // The three trailing pad bytes are load-bearing: C rounds this member up to a 12-byte stride,
    // but Swift would otherwise pack the next field (`result`) into keyInfo's tail padding at offset
    // 37 instead of 40, shifting everything after it and making the struct 76 bytes — the kernel call
    // then fails with kIOReturnBadArgument. Explicit padding forces size == stride == 12, so the full
    // struct is the required 80 bytes. (See the stride == 80 guard in ensureOpen.)
    private struct SMCKeyInfoData { var dataSize: UInt32 = 0; var dataType: UInt32 = 0; var dataAttributes: UInt8 = 0; var pad0: UInt8 = 0; var pad1: UInt8 = 0; var pad2: UInt8 = 0 }
    private struct SMCKeyData {
        var key: UInt32 = 0
        var vers = SMCVersion()
        var pLimitData = SMCPLimitData()
        var keyInfo = SMCKeyInfoData()
        var result: UInt8 = 0
        var status: UInt8 = 0
        var data8: UInt8 = 0
        var data32: UInt32 = 0
        var bytes: SMCBytes = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                               0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    }

    private static let selector: UInt32 = 2      // kernel selector for SMC struct calls
    private static let cmdReadKeyInfo: UInt8 = 9
    private static let cmdReadBytes: UInt8 = 5
    private static let typeFLT = fourCharCode("flt ")

    // A discovered SMC key with its cached size/type, so reads skip the key-info round trip.
    private struct KeyInfo { let key: UInt32; let size: UInt32; let type: UInt32 }
    // One fan's discovered keys: actual RPM (always present) and max RPM (may be absent).
    private struct FanKeys { let ac: KeyInfo; let mx: KeyInfo? }

    private var connection: io_connect_t = 0
    private var fanKeys: [FanKeys] = []
    private var availabilityChecked = false
    private var available = false

    var isAvailable: Bool { ensureOpen() }

    func sampleUsage() -> Double? {
        guard ensureOpen() else { hasSample = false; return nil }
        var readings: [FanReading] = []
        for fan in fanKeys {
            guard let acVal = readFloat(fan.ac) else { continue }
            let current = Double(acVal)
            guard let mxKey = fan.mx, let mxVal = readFloat(mxKey), Double(mxVal) > 0 else { continue }
            // actual/max, not (actual-min)/(max-min): idle RPM sits well above 0, so this keeps
            // visible motion when the fans are barely spinning (a redline fan still reads ~1). A
            // genuinely stopped fan reads 0 → the speed path floors it at the preset's min speed,
            // so the animation still crawls rather than freezing.
            let clamped = min(max(current / Double(mxVal), 0), 1)
            readings.append(FanReading(rpm: current, utilization: clamped))
        }
        guard !readings.isEmpty else { hasSample = false; return nil }
        perFan = readings
        // Average across fans, not the max of any one — a single fan spinning up shouldn't
        // dominate the animation speed while the rest of the system is quiet.
        let averageFraction = readings.map(\.utilization).reduce(0, +) / Double(readings.count)
        currentUtilization = averageFraction
        hasSample = true
        return averageFraction
    }

    // Lazily open the SMC connection and discover fan keys; cache the result. Guard the struct
    // layout up front — if the toolchain ever lays SMCKeyData out at != 80 bytes the kernel call
    // would corrupt memory, so we disable the source instead.
    private func ensureOpen() -> Bool {
        if availabilityChecked { return available }
        availabilityChecked = true
        guard MemoryLayout<SMCKeyData>.stride == 80, let conn = openSMC() else {
            available = false
            return false
        }
        connection = conn
        fanKeys = discoverFanKeys()
        available = !fanKeys.isEmpty
        return available
    }

    private func openSMC() -> io_connect_t? {
        guard let matching = IOServiceMatching("AppleSMC") else { return nil }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }

        var service = IOIteratorNext(iterator)
        while service != 0 {
            var nameBuf = [CChar](repeating: 0, count: 128)
            IORegistryEntryGetName(service, &nameBuf)
            let name = String(cString: nameBuf)
            if name.contains("AppleSMCKeysEndpoint") {
                var conn: io_connect_t = 0
                let kr = IOServiceOpen(service, mach_task_self_, 0, &conn)
                IOObjectRelease(service)
                if kr == KERN_SUCCESS { return conn }
            } else {
                IOObjectRelease(service)
            }
            service = IOIteratorNext(iterator)
        }
        return nil
    }

    // Read FNum (fan count), then probe F{n}Ac / F{n}Mx for each fan. A fan with no readable
    // actual-RPM key is skipped; a missing max key is kept as nil (that fan is then ignored in
    // sampleUsage, which needs a max to normalize).
    private func discoverFanKeys() -> [FanKeys] {
        guard let fnum = readKeyInfo(Self.fourCharCode("FNum")),
              let raw = readBytes(key: fnum.key, size: fnum.size, type: fnum.type),
              let count = raw.first else { return [] }
        var result: [FanKeys] = []
        for i in 0..<Int(count) {
            guard let ac = discoverFloatKey("F\(i)Ac") else { continue }
            result.append(FanKeys(ac: ac, mx: discoverFloatKey("F\(i)Mx")))
        }
        return result
    }

    private func discoverFloatKey(_ keyStr: String) -> KeyInfo? {
        let key = Self.fourCharCode(keyStr)
        guard let info = readKeyInfo(key), info.type == Self.typeFLT, info.size == 4 else { return nil }
        return KeyInfo(key: key, size: info.size, type: info.type)
    }

    private func readKeyInfo(_ key: UInt32) -> (key: UInt32, size: UInt32, type: UInt32)? {
        var input = SMCKeyData()
        input.key = key
        input.data8 = Self.cmdReadKeyInfo
        guard let out = smcCall(&input) else { return nil }
        return (key, out.keyInfo.dataSize, out.keyInfo.dataType)
    }

    private func readBytes(key: UInt32, size: UInt32, type: UInt32) -> [UInt8]? {
        var input = SMCKeyData()
        input.key = key
        input.data8 = Self.cmdReadBytes
        input.keyInfo.dataSize = size
        input.keyInfo.dataType = type
        guard let out = smcCall(&input) else { return nil }
        let n = Int(min(size, 32))
        return withUnsafeBytes(of: out.bytes) { Array($0.prefix(n)) }
    }

    private func readFloat(_ ki: KeyInfo) -> Float? {
        guard let raw = readBytes(key: ki.key, size: ki.size, type: ki.type), raw.count >= 4 else { return nil }
        // SMC "flt " values are little-endian; both Apple architectures are LE, so a raw copy of
        // the first 4 bytes reproduces Python's struct.unpack("<f", …).
        var value: Float = 0
        withUnsafeMutableBytes(of: &value) { $0.copyBytes(from: raw.prefix(4)) }
        return value
    }

    private func smcCall(_ input: inout SMCKeyData) -> SMCKeyData? {
        guard connection != 0 else { return nil }
        var output = SMCKeyData()
        var outputSize = MemoryLayout<SMCKeyData>.stride
        let kr = IOConnectCallStructMethod(
            connection, Self.selector,
            &input, MemoryLayout<SMCKeyData>.stride,
            &output, &outputSize
        )
        guard kr == KERN_SUCCESS else { return nil }
        return output
    }

    // 4-char SMC key → big-endian UInt32 (first char in the high byte), matching the kernel's
    // packing (Python's struct.unpack(">I", key)).
    private static func fourCharCode(_ s: String) -> UInt32 {
        var result: UInt32 = 0
        for byte in s.utf8.prefix(4) { result = (result << 8) | UInt32(byte) }
        return result
    }
}

// Network throughput as a 0…1 load. Cumulative interface byte counters (getifaddrs → if_data) are
// differenced over real elapsed wall time into inbound/outbound bytes/sec (counter-delta, warms up
// one tick like CPU); the driving signal normalized by the shared adaptive ThroughputScaler is the
// average of the two, not the sum, so a single-direction transfer isn't double-counted against a
// symmetric one. Only AF_LINK entries carry valid if_data, and lo0 is skipped so loopback traffic
// doesn't inflate the number.
@MainActor
private final class NetworkLoadMonitor {
    private(set) var hasSample = false
    private(set) var currentInboundBytesPerSec: Double = 0
    private(set) var currentOutboundBytesPerSec: Double = 0
    // Last normalized 0…1 load (the scaler's output, fed the in/out average), so the speed path can
    // re-read it without re-sampling — mirrors MemoryLoadMonitor.currentMemoryLoad.
    private(set) var currentLoad: Double = 0
    private var lastInBytes: UInt64?
    private var lastOutBytes: UInt64?
    private var scaler = ThroughputScaler(floor: Tuning.networkFloorBytesPerSec)
    // getifaddrs is always present on macOS; the source is effectively always available.
    var isAvailable: Bool { true }

    func sampleUsage(elapsed: Double?) -> Double? {
        guard let (inBytes, outBytes) = readInterfaceBytes() else {
            hasSample = false
            return nil
        }
        defer {
            lastInBytes = inBytes
            lastOutBytes = outBytes
        }
        // Counter-delta: needs a prior sample AND real elapsed time. First tick / source-switch
        // re-sample (elapsed nil) just stores the baseline and reports no rate yet.
        guard let elapsed, elapsed > 0, let prevIn = lastInBytes, let prevOut = lastOutBytes else {
            currentInboundBytesPerSec = 0
            currentOutboundBytesPerSec = 0
            hasSample = false
            return nil
        }
        let deltaIn = inBytes >= prevIn ? inBytes - prevIn : 0
        let deltaOut = outBytes >= prevOut ? outBytes - prevOut : 0
        currentInboundBytesPerSec = Double(deltaIn) / elapsed
        currentOutboundBytesPerSec = Double(deltaOut) / elapsed
        hasSample = true
        currentLoad = scaler.normalize(speed: (currentInboundBytesPerSec + currentOutboundBytesPerSec) / 2)
        return currentLoad
    }

    private func readInterfaceBytes() -> (inBytes: UInt64, outBytes: UInt64)? {
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let first = ifaddrPtr else { return nil }
        defer { freeifaddrs(ifaddrPtr) }

        var inTotal: UInt64 = 0
        var outTotal: UInt64 = 0
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            defer { cursor = current.pointee.ifa_next }
            guard let addr = current.pointee.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_LINK) else { continue }
            if String(cString: current.pointee.ifa_name) == "lo0" { continue }
            guard let dataPtr = current.pointee.ifa_data else { continue }
            let data = dataPtr.assumingMemoryBound(to: if_data.self).pointee
            inTotal &+= UInt64(data.ifi_ibytes)
            outTotal &+= UInt64(data.ifi_obytes)
        }
        return (inTotal, outTotal)
    }
}

// Disk I/O throughput as a 0…1 load — twin of NetworkLoadMonitor. Every IOBlockStorageDriver's
// Statistics dict carries cumulative "Bytes (Read)"/"Bytes (Write)"; summed across drivers, differenced
// over real elapsed time into read/write bytes/sec, and the average of the two (not the sum) is
// normalized by the shared adaptive ThroughputScaler, so a read-only or write-only burst isn't
// double-counted against a balanced read+write load.
@MainActor
private final class DiskLoadMonitor {
    private(set) var hasSample = false
    private(set) var currentReadBytesPerSec: Double = 0
    private(set) var currentWriteBytesPerSec: Double = 0
    private(set) var currentLoad: Double = 0
    private var lastReadBytes: UInt64?
    private var lastWriteBytes: UInt64?
    private var scaler = ThroughputScaler(floor: Tuning.diskFloorBytesPerSec)
    private var availabilityChecked = false
    private var available = false

    var isAvailable: Bool {
        if !availabilityChecked {
            available = (readWriteBytes() != nil)
            availabilityChecked = true
        }
        return available
    }

    func sampleUsage(elapsed: Double?) -> Double? {
        guard let (readBytes, writeBytes) = readWriteBytes() else {
            hasSample = false
            return nil
        }
        defer {
            lastReadBytes = readBytes
            lastWriteBytes = writeBytes
        }
        guard let elapsed, elapsed > 0, let prevRead = lastReadBytes, let prevWrite = lastWriteBytes else {
            currentReadBytesPerSec = 0
            currentWriteBytesPerSec = 0
            hasSample = false
            return nil
        }
        let deltaRead = readBytes >= prevRead ? readBytes - prevRead : 0
        let deltaWrite = writeBytes >= prevWrite ? writeBytes - prevWrite : 0
        currentReadBytesPerSec = Double(deltaRead) / elapsed
        currentWriteBytesPerSec = Double(deltaWrite) / elapsed
        hasSample = true
        currentLoad = scaler.normalize(speed: (currentReadBytesPerSec + currentWriteBytesPerSec) / 2)
        return currentLoad
    }

    private func readWriteBytes() -> (readBytes: UInt64, writeBytes: UInt64)? {
        guard let matching = IOServiceMatching("IOBlockStorageDriver") else { return nil }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }

        var readTotal: UInt64 = 0
        var writeTotal: UInt64 = 0
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
            readTotal &+= (stats["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
            writeTotal &+= (stats["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
            found = true
        }
        return found ? (readTotal, writeTotal) : nil
    }
}

// Battery as a load source — a *mixed domain* like MemoryLoadMonitor: an instantaneous charge-level
// point read (valid on the first sample) plus an instantaneous discharge *current* (mA, from IOKit
// Power Sources' "Current" key). The discharge current — NOT a counter-delta, so no one-tick warm-up
// — is the driver: while on battery its magnitude normalizes through the shared adaptive
// ThroughputScaler (each machine's draw ceiling differs), so a fast drain → faster animation and AC
// power (current 0) → idle. Charge level is a readout, not the driver. Available only when a battery
// exists (desktop Macs → source disabled + launch fallback to CPU, exactly like Fan on fanless Macs).
// Reuses the same unprivileged IOPSCopyPowerSourcesInfo plumbing as evaluateBatteryLow. `nil` (never a
// fabricated 0) on read failure.
@MainActor
private final class BatteryLoadMonitor {
    private(set) var currentChargeFraction: Double = 0      // 0…1, readout only
    private(set) var currentDischargeMilliamps: Double = 0  // magnitude, 0 on AC
    private(set) var onBattery = false
    private(set) var currentLoad: Double = 0                // scaler-normalized 0…1 driver
    private(set) var hasSample = false
    // Discharge current is an unbounded rate-like signal (mA), so it normalizes through the shared
    // adaptive scaler like network/disk/swap — just fed an instantaneous magnitude, not a delta.
    private var scaler = ThroughputScaler(floor: Tuning.batteryFloorMilliamps)
    private var availabilityChecked = false
    private var available = false

    var isAvailable: Bool {
        if !availabilityChecked {
            available = Self.batteryPresent()
            availabilityChecked = true
        }
        return available
    }

    func sampleUsage() -> Double? {
        guard let reading = Self.readBattery() else { hasSample = false; return nil }
        currentChargeFraction = reading.charge
        onBattery = reading.onBattery
        // Discharge current only counts while on battery; on AC the draw is 0 → idle animation.
        currentDischargeMilliamps = reading.onBattery ? abs(reading.currentMilliamps) : 0
        hasSample = true
        currentLoad = scaler.normalize(speed: currentDischargeMilliamps)
        return currentLoad
    }

    private static func batteryPresent() -> Bool {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [Any] else { return false }
        return !list.isEmpty
    }

    private struct Reading { let charge: Double; let currentMilliamps: Double; let onBattery: Bool }

    private static func readBattery() -> Reading? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [Any],
              let first = list.first,
              let dict = IOPSGetPowerSourceDescription(blob, first as CFTypeRef)?
                            .takeUnretainedValue() as? [String: Any] else { return nil }
        // Capacity/max are percentages in IOPS (max is typically 100); their ratio is the charge
        // fraction, matching how evaluateBatteryLow reads kIOPSCurrentCapacityKey as 0–100.
        let capacity = (dict[kIOPSCurrentCapacityKey] as? NSNumber)?.doubleValue ?? 0
        let maxCap = (dict[kIOPSMaxCapacityKey] as? NSNumber)?.doubleValue ?? 100
        let charge = maxCap > 0 ? min(max(capacity / maxCap, 0), 1) : 0
        let onBattery = (dict[kIOPSPowerSourceStateKey] as? String) == kIOPSBatteryPowerValue
        // "Current" (mA) is instantaneous and signed (negative while discharging); may be absent on
        // some sources → treat as 0 (the source stays available for the charge readout, animation idles).
        let mA = (dict[kIOPSCurrentKey] as? NSNumber)?.doubleValue ?? 0
        return Reading(charge: charge, currentMilliamps: mA, onBattery: onBattery)
    }
}

// The color ramp direction for the trace chart. For utilization sources high = alert (green→red as
// the value rises); for the battery fuel gauge low = alert (the ramp inverts).
private enum ColorPolarity { case highIsHot, lowIsHot }

// A compact bar-chart trace of the active load source's recent 0…1 fraction, shown as the top item
// of the status menu (a live counterpart to the numeric readout lines below it). Newest sample sits
// at the right edge; the buffer fills leftward until full, then scrolls. For every source except
// battery the plotted value is the driving fraction, colored by the same Low/Medium/High thresholds
// as the CPU/GPU State line (high = red) so the chart and text agree. Battery is a fuel gauge: it
// plots charge level with an inverted ("low is hot") ramp, so a low battery reads red — the caller
// sets `colorPolarity`/thresholds per source. Non-interactive (hosted in a disabled NSMenuItem); it
// only ever draws.
@MainActor
private final class LoadHistoryView: NSView {
    // Most-recent-last, 0…1, at most `capacity` entries.
    var samples: [Double] = [] { didSet { needsDisplay = true } }
    // Shown in the caption, e.g. "CPU". Set alongside samples on each refresh.
    var sourceLabel: String = "" { didSet { needsDisplay = true } }
    // True before the active source has produced a usable sample (empty chart → "measuring…").
    var warmingUp: Bool = true { didSet { needsDisplay = true } }
    // Coloring config, set per active source by the caller. Defaults reproduce the utilization
    // behavior (high = red at the CPU State thresholds); battery overrides to an inverted fuel gauge.
    var colorPolarity: ColorPolarity = .highIsHot { didSet { needsDisplay = true } }
    var lowThreshold: Double = Tuning.cpuStateLowThreshold { didSet { needsDisplay = true } }
    var mediumThreshold: Double = Tuning.cpuStateMediumThreshold { didSet { needsDisplay = true } }

    private let capacity: Int

    init(capacity: Int) {
        self.capacity = capacity
        super.init(frame: NSRect(x: 0, y: 0, width: 224, height: 46))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var intrinsicContentSize: NSSize { NSSize(width: 224, height: 46) }

    // Menu-item left gutter (checkmark column) + trailing padding, so bars line up under the text rows.
    private let insetLeft: CGFloat = 21
    private let insetRight: CGFloat = 14
    private let insetTop: CGFloat = 5
    private let insetBottom: CGFloat = 7
    private let captionHeight: CGFloat = 13
    private let barGap: CGFloat = 1.5

    private func color(for value: Double) -> NSColor {
        switch colorPolarity {
        case .highIsHot:
            if value < lowThreshold { return .systemGreen }
            if value < mediumThreshold { return .systemYellow }
            return .systemRed
        case .lowIsHot:
            if value < lowThreshold { return .systemRed }
            if value < mediumThreshold { return .systemYellow }
            return .systemGreen
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let content = NSRect(
            x: insetLeft,
            y: insetBottom,
            width: bounds.width - insetLeft - insetRight,
            height: bounds.height - insetTop - insetBottom
        )
        guard content.width > 4, content.height > captionHeight else { return }

        let windowSeconds = Int((Double(capacity) * Tuning.loadSampleInterval).rounded())
        let caption: String
        if warmingUp || samples.isEmpty {
            caption = sourceLabel.isEmpty ? "measuring…" : "\(sourceLabel) · measuring…"
        } else {
            caption = "\(sourceLabel) · last \(windowSeconds)s"
        }
        let captionAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let captionSize = (caption as NSString).size(withAttributes: captionAttrs)
        (caption as NSString).draw(
            at: NSPoint(x: content.minX, y: content.maxY - captionSize.height),
            withAttributes: captionAttrs
        )

        // Bars occupy everything under the caption.
        let plot = NSRect(
            x: content.minX,
            y: content.minY,
            width: content.width,
            height: content.height - captionHeight
        )
        guard plot.height > 2 else { return }

        // Faint baseline track so an empty/idle chart still reads as a chart.
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(rect: NSRect(x: plot.minX, y: plot.minY, width: plot.width, height: 1)).fill()

        guard !samples.isEmpty else { return }

        let slotWidth = plot.width / CGFloat(capacity)
        let barWidth = max(1, slotWidth - barGap)
        let count = min(samples.count, capacity)
        let trailing = samples.suffix(count)
        for (offset, value) in trailing.enumerated() {
            let clamped = min(max(value, 0), 1)
            // Right-align: oldest of the visible window starts at (capacity - count).
            let slot = capacity - count + offset
            let x = plot.minX + CGFloat(slot) * slotWidth
            let h = max(1, CGFloat(clamped) * plot.height)
            let rect = NSRect(x: x, y: plot.minY, width: barWidth, height: h)
            color(for: clamped).withAlphaComponent(0.9).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 0.75, yRadius: 0.75).fill()
        }
    }
}

// View-based menu item used as the "Other Sources" disclosure header. A plain NSMenuItem with an
// action dismisses the whole menu the instant it's clicked; a *view-based* item does not — the view
// handles the click itself and the menu stays open. That's what lets this section expand/collapse in
// place (the toggle flips the sibling rows' `isHidden`, which an open NSMenu re-lays-out live) instead
// of forcing a close-and-reopen. Draws a native-looking row: a leading disclosure triangle (▸/▾) +
// title, with an accent highlight while hovered (view-based items must draw their own selection —
// AppKit doesn't). Title x-inset matches LoadHistoryView's gutter so it lines up with the rows around
// it.
@MainActor
private final class DisclosureMenuItemView: NSView {
    var title: String = "" { didSet { needsDisplay = true } }
    var isExpanded: Bool = false { didSet { needsDisplay = true } }

    private let onToggle: () -> Void
    private var isHighlighted = false { didSet { needsDisplay = true } }
    private var trackingArea: NSTrackingArea?

    private let insetLeft: CGFloat = 21   // checkmark-gutter column, matching LoadHistoryView
    private let height: CGFloat = 22

    init(onToggle: @escaping () -> Void) {
        self.onToggle = onToggle
        super.init(frame: NSRect(x: 0, y: 0, width: 224, height: height))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: height) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHighlighted = true }
    override func mouseExited(with event: NSEvent) { isHighlighted = false }
    // Toggle on click without letting the click bubble up as a menu selection (which would dismiss).
    override func mouseUp(with event: NSEvent) { onToggle() }

    override func draw(_ dirtyRect: NSRect) {
        if isHighlighted {
            NSColor.selectedContentBackgroundColor.setFill()
            bounds.fill()
        }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.menuFont(ofSize: 0),
            .foregroundColor: isHighlighted ? NSColor.selectedMenuItemTextColor : NSColor.labelColor,
        ]
        let text = "\(isExpanded ? "▾" : "▸")  \(title)" as NSString
        let size = text.size(withAttributes: attrs)
        text.draw(at: NSPoint(x: insetLeft, y: (bounds.height - size.height) / 2), withAttributes: attrs)
    }
}

// Owns the `caffeinate` child process that keeps the Mac awake while "Keep Awake" is on. The key
// design choice is separating *intent* from *running state*: `isEnabled` is the user's toggle, while
// the process may be independently suspended by conditions (battery-low, serious thermal) and
// respawned when they clear — without losing the user's intent. `applyConditions(suspend:)` is a
// total function safe to call on every condition change and on toggle: it spawns iff the user wants
// it AND no condition suspends it, otherwise it kills.
//
// `caffeinate -i -w <pid>`: `-i` prevents idle sleep only (the display may still sleep — intended for
// keeping work running, not the screen on); `-w <pid>` binds the child to MLR's PID so the OS reaps
// it automatically if MLR crashes or is force-quit, so there's never an orphaned sleep lock.
@MainActor
private final class SleepPreventer {
    private static let caffeinatePath = "/usr/bin/caffeinate"
    private var process: Process?
    private(set) var isEnabled = false          // the user's toggle (intent)
    var isRunning: Bool { process != nil }      // whether caffeinate is actually spawned right now

    func setEnabled(_ on: Bool) { isEnabled = on }  // caller then drives applyConditions()

    // Spawn iff the user wants it AND no condition suspends it; otherwise kill. Idempotent.
    func applyConditions(suspend: Bool) {
        if isEnabled && !suspend { spawn() } else { kill() }
    }

    private func spawn() {
        guard process == nil else { return }
        guard FileManager.default.isExecutableFile(atPath: Self.caffeinatePath) else {
            fputs("SleepPreventer: \(Self.caffeinatePath) is not available; cannot prevent sleep.\n", stderr)
            return
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: Self.caffeinatePath)
        proc.arguments = ["-i", "-w", String(ProcessInfo.processInfo.processIdentifier)]
        do {
            try proc.run()
            process = proc
        } catch {
            fputs("SleepPreventer: caffeinate spawn failed: \(error.localizedDescription)\n", stderr)
        }
    }

    private func kill() {
        process?.terminate()
        process = nil
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

    // The selection mark for every radio/toggle menu item — a small solid dot in place of the heavy
    // native ✓, matching the minimalist menu-bar aesthetic. Built once as a *template* image so it
    // adopts the menu's label / highlight tint automatically (no per-appearance color handling), and
    // assigned as each item's `onStateImage` (the `.off` state stays blank, so the gutter still
    // aligns).
    private static let selectionMarkImage: NSImage = {
        // A small solid dot in place of the heavy native ✓. Diameter is derived from the menu font's
        // cap height (the same font the disclosure header uses) so the mark sits at that toggle's
        // scale. Drawn as a *template* image so AppKit tints it to the label / highlight color.
        let diameter = (NSFont.menuFont(ofSize: 0).capHeight * Tuning.menuSelectionMarkCapHeightFraction).rounded()
        let image = NSImage(size: NSSize(width: diameter, height: diameter))
        image.lockFocus()
        NSColor.black.setFill() // template image; the color is ignored, AppKit re-tints
        NSBezierPath(ovalIn: NSRect(x: 0, y: 0, width: diameter, height: diameter)).fill()
        image.unlockFocus()
        image.isTemplate = true
        return image
    }()

    // Applies the shared selection mark to a radio/toggle item so its "selected" state renders as the
    // filled dot instead of the native ✓. Call at construction for every item whose `.state` toggles.
    private func useSelectionMark(_ item: NSMenuItem) {
        item.onStateImage = Self.selectionMarkImage
    }

    private let config: Config
    private let allPresets: [PresetDescriptor]
    // The manifest's declared default preset, resolved once in init. Also the profile fallback for
    // a custom/user-supplied GIF that matches no preset (its speedProfile stands in).
    private let defaultDescriptor: PresetDescriptor?
    // Set when the preset manifest could not be loaded/decoded; applicationDidFinishLaunching shows
    // it and quits. nil on success.
    private let startupError: String?
    // Directory holding the app's resources (gifs/presets.json). For an installed build this is the
    // git worktree root (install.sh git-clones the repo here). Resolved once in init and reused as the
    // update-checker's repo dir via `repoDirURL`.
    private let scriptDirURL: URL
    // The app's own git checkout, if it is one. nil for a copied-binary / non-git layout, which
    // disables the whole update-check UI (nothing to pull from). Cheap enough to compute on demand.
    private var repoDirURL: URL? {
        let dotGit = scriptDirURL.appendingPathComponent(".git")
        return FileManager.default.fileExists(atPath: dotGit.path) ? scriptDirURL : nil
    }
    private var activePreset: PresetDescriptor?
    private var activeGifPath: String
    // These menu/status-item IUOs are all assigned exactly once in
    // applicationDidFinishLaunching and only read afterwards (menu-delegate callbacks,
    // refresh functions, @objc actions) — never before launch. The `!` reflects that
    // single-init lifecycle; they are guaranteed non-nil for the app's lifetime.
    private var statusItem: NSStatusItem!
    // Optional second slot for the adjacent label (live value / custom text). Created lazily when the
    // label mode is not .off and torn down when it returns to .off, so an off label claims no menu-bar
    // real estate. variableLength — it auto-sizes to its text. See applyLabelMode()/updateValueLabel().
    private var valueStatusItem: NSStatusItem?
    private var infoMenu: NSMenu!
    // Trace chart of the active source's recent driving fractions, and its ring buffer. The buffer
    // holds only the active source's samples (cleared on a source switch, since a mixed-source
    // history would be meaningless); recorded each tick in sampleSystemLoad, pushed to the view in
    // refreshMenuMetrics (so it updates both on the 2s tick and on menuWillOpen).
    private var historyMenuItem: NSMenuItem!
    private var loadHistoryView: LoadHistoryView!
    private var loadHistory: [Double] = []
    // Source-conditional: holds the active load source's primary metric (CPU% / Memory%) and
    // its state qualifier (CPU State Low/Med/High / Memory Pressure Normal/Warning/Critical).
    private var usageItem: NSMenuItem!
    private var loadAverageItem: NSMenuItem!
    private var stateItem: NSMenuItem!
    private var speedMultiplierItem: NSMenuItem!
    private var throttleStatusItem: NSMenuItem!
    private var widthStatusItem: NSMenuItem!
    // "Menu Bar Label" submenu: a radio group (Off / Live Value / Custom Text…). The parent title
    // doubles as the current-state readout, like the load-source rows.
    private var labelMenuItem: NSMenuItem!
    private var labelOffItem: NSMenuItem!
    private var labelValueItem: NSMenuItem!
    private var labelCustomItem: NSMenuItem!
    private var presetMenuItems: [NSMenuItem] = []
    // In-app update check. `latestKnownVersion` is the newest release tag found on origin (nil until a
    // probe completes, or on any failure — fail-silent). `updateItem` is the passive "Update
    // available" line (hidden when up to date / not a git checkout); `checkForUpdatesItem` forces a
    // fresh probe. Both driven by refreshUpdateStatus(). See SemVer / UpdateChecker.
    private var latestKnownVersion: SemVer?
    private var updateItem: NSMenuItem!
    private var checkForUpdatesItem: NSMenuItem!
    // Set while a probe is running so overlapping manual checks don't stack git processes.
    private var updateCheckInFlight = false
    private var frames: [NSImage] = []
    private var frameAspects: [CGFloat] = []
    private var baseDurations: [TimeInterval] = []
    private var frameIndex = 0
    private var displayLink: CADisplayLink?
    private var fallbackTimer: Timer?
    private var lastTickTime: TimeInterval = 0
    private var accumulatedFrameTime: TimeInterval = 0
    // Pre-rasterized frames as CGImages. Per frame the game loop only assigns one to the
    // animation layer's `contents` (a cheap pointer swap) — see renderCurrentFrame(). We keep
    // CGImage rather than NSImage so that assignment never triggers a rasterization.
    private var renderedFrames: [CGImage] = []
    // Layer-backed host view pinned over the status-item button. Frame swaps go to its
    // layer.contents, bypassing NSButton's setImage: → _adjustLength → Auto Layout cascade.
    private var animationView: NSView?
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
    private var fanMonitor = FanLoadMonitor()
    private var batteryMonitor = BatteryLoadMonitor()
    private var activeLoadSource: LoadSource
    // Multi-source dashboard mode / other-sources disclosure state: when on (expanded), every
    // AVAILABLE reader is sampled each tick (not just the active one) and its live readout is surfaced
    // as an inline row under the "Other Sources" disclosure header, while the active source alone still
    // drives the animation. Off by default (collapsed → active-only sampling, the self-throttle ethos);
    // opt-in via the disclosure header or --show-all-sources / MENUBAR_LOAD_RUNNER_SHOW_ALL.
    private var showAllSources: Bool
    // Disclosure header row for the collapsible other-sources section, and the inline per-source
    // rows nested under it. The rows double as the source switcher (clicking one drives the animation
    // from that reader), replacing the former Load Source submenu.
    private var otherSourcesHeaderItem: NSMenuItem!
    private var otherSourcesHeaderView: DisclosureMenuItemView!
    private var otherSourceRowItems: [NSMenuItem] = []
    // Last memory-pressure level seen from the dispatch source. Cached because — unlike
    // thermalState/isLowPowerModeEnabled — there is NO synchronous getter for memory pressure;
    // it is event-only, so isUnderPowerPressure reads this stored value.
    private var memoryPressureLevel: DispatchSource.MemoryPressureEvent = .normal
    private var memoryPressureSource: DispatchSourceMemoryPressure?
    private var speedMultiplier: Double = Tuning.initialSpeedMultiplier
    // Content of the adjacent label slot (see MenuBarLabel). Initialized from config; mutated by the
    // "Menu Bar Label" menu. applyLabelMode() reconciles valueStatusItem's existence with it.
    private var labelMode: MenuBarLabel = .off
    private var cachedLoadAverages: (Double, Double, Double)?
    private var screenObserver: NSObjectProtocol?
    private var powerStateObserver: NSObjectProtocol?
    private var thermalStateObserver: NSObjectProtocol?
    private var occlusionObserver: NSObjectProtocol?

    // Keep Awake. Memory-only intent (resets to off on launch — KeepingYouAwake behaves the same);
    // the actual caffeinate process is suspended/respawned by conditionsDidChange().
    private let sleepPreventer = SleepPreventer()
    private var keepAwakeMenuItem: NSMenuItem!
    // Keep-awake bar tint, user-selectable via the Keep Awake Color submenu. Menu-only (no CLI/env),
    // so it starts at the default and lives only for the session, like the Keep Awake toggle itself.
    private var activeKeepAwakeColor: KeepAwakeColor = .teal
    private var keepAwakeColorMenuItem: NSMenuItem!
    private var keepAwakeColorMenuItems: [NSMenuItem] = []
    // Updated by the IOKit power-source notification. Stays false on a desktop Mac (no battery), so
    // battery is never a disengage trigger there.
    private var batteryLow = false
    private var batteryRunLoopSource: CFRunLoopSource?
    // Sibling overlay layer on animationView.layer, on top of the frame contents. The keep-awake
    // track line; hidden unless caffeinate is actually running. NEVER composited into renderedFrames.
    private var keepAwakeBar: CALayer?

    init(config: Config) {
        self.config = config
        self.labelMode = config.label
        self.activeLoadSource = config.loadSource
        self.showAllSources = config.showAllSources

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
        self.scriptDirURL = scriptDirURL
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
        } else if !requested.isEmpty,
                  !requested.contains("/"),
                  !requested.lowercased().hasSuffix(".gif"),
                  !FileManager.default.fileExists(atPath: requested),
                  let fallback = presets.first(where: { $0.key == manifestDefaultKey }) {
            // A BAREWORD that is neither a known preset keyword nor a file on disk — a typo or a
            // stray keyword. Fall back to the default preset with a stderr warning instead of
            // quitting with a fatal error box, which users kept hitting. An explicit GIF PATH
            // (contains "/" or ends ".gif") is deliberately NOT caught here: if it's missing,
            // loadFrames still surfaces the fatal "GIF file not found", per the QA §4a contract —
            // pointing at a specific file that isn't there is worth telling the user about.
            fputs("\"\(requested)\" is not a known preset or an existing GIF file; using the default preset \"\(fallback.key)\". Run with --help to list presets.\n", stderr)
            self.activeGifPath = fallback.path
            self.activePreset = fallback
        } else {
            // A GIF path (has "/" or ".gif", or exists on disk), or no default to fall back to —
            // treat it as a (custom) GIF path. Still match by path so a raw path pointing at a
            // built-in GIF adopts its profile. A missing path fails later in loadFrames (fatal).
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
        // Animation is driven through a dedicated layer-backed subview, not button.image:
        // setting a status button's image on every GIF frame makes AppKit re-run _adjustLength
        // and a full Auto Layout constraint solve per frame. Swapping a CALayer's `contents`
        // instead is a GPU-side pointer swap with no layout/draw cycle. The view fills the
        // button and tracks its size via autoresizing (the button resizes on preset switch).
        let animationView = NSView(frame: button.bounds)
        animationView.wantsLayer = true
        animationView.autoresizingMask = [.width, .height]
        if let layer = animationView.layer {
            layer.contentsGravity = .resizeAspect  // matches the former .scaleProportionallyUpOrDown
            layer.masksToBounds = true
            installKeepAwakeBar(on: layer)
        }
        button.addSubview(animationView)
        self.animationView = animationView
        button.toolTip = activeGifPath
        // Base label for VoiceOver; refreshMenuMetrics() enriches it with live CPU load.
        button.setAccessibilityLabel("MenuBar Load Runner")

        infoMenu = NSMenu()
        infoMenu.delegate = self

        loadHistoryView = LoadHistoryView(capacity: Tuning.loadHistoryCapacity)
        historyMenuItem = NSMenuItem(title: MenuTitle.loadHistory, action: nil, keyEquivalent: "")
        historyMenuItem.isEnabled = false
        historyMenuItem.view = loadHistoryView
        infoMenu.addItem(historyMenuItem)

        usageItem = NSMenuItem(title: MenuTitle.line(MenuTitle.cpuUsagePrefix, MenuTitle.placeholderValue), action: nil, keyEquivalent: "")
        usageItem.isEnabled = false
        infoMenu.addItem(usageItem)

        loadAverageItem = NSMenuItem(title: MenuTitle.line(MenuTitle.loadAvgPrefix, "-- / -- / --"), action: nil, keyEquivalent: "")
        loadAverageItem.isEnabled = false
        infoMenu.addItem(loadAverageItem)

        stateItem = NSMenuItem(title: MenuTitle.line(MenuTitle.statePrefix(for: .cpu), MenuTitle.placeholderValue), action: nil, keyEquivalent: "")
        stateItem.isEnabled = false
        infoMenu.addItem(stateItem)

        speedMultiplierItem = NSMenuItem(title: MenuTitle.line(MenuTitle.speedMultiplierPrefix, MenuTitle.placeholderValue), action: nil, keyEquivalent: "")
        speedMultiplierItem.isEnabled = false
        infoMenu.addItem(speedMultiplierItem)

        // Title is set live in refreshMenuMetrics to name the active cause(s); hidden until then.
        throttleStatusItem = NSMenuItem(title: MenuTitle.slowingAnimation, action: nil, keyEquivalent: "")
        throttleStatusItem.isEnabled = false
        throttleStatusItem.isHidden = true
        infoMenu.addItem(throttleStatusItem)

        // Read-only: the item sizes itself to the GIF's aspect ratio; there is no width control.
        // Grouped with the other read-only readouts, above the control items below.
        widthStatusItem = NSMenuItem(title: MenuTitle.line(MenuTitle.widthPrefix, MenuTitle.placeholderValue), action: nil, keyEquivalent: "")
        widthStatusItem.isEnabled = false
        infoMenu.addItem(widthStatusItem)

        infoMenu.addItem(NSMenuItem.separator())

        // Availability fallback: if the requested source (--load-source / env) can't produce a value on
        // this hardware — realistically only GPU — degrade to CPU rather than driving off a dead reader.
        // An absent source never fails launch (design principle 4); its row stays hidden.
        if !isSourceAvailable(activeLoadSource) {
            fputs("Load source \"\(activeLoadSource.key)\" is unavailable on this machine; falling back to cpu.\n", stderr)
            activeLoadSource = .cpu
        }

        // Unified other-sources section (replaces the old Load Source submenu + Show All Sources
        // checkbox + All Sources submenu). A disclosure header expands an inline list of every *other*
        // available reader; each row shows that reader's live readout and, when clicked, switches the
        // animation's driving source to it. The active source is never listed — it's shown on top with
        // the sparkline. Collapsing hides the rows AND restores active-only sampling (nothing else is
        // polled), so the indicator keeps to its self-throttle ethos unless the user opts in. The
        // `showAllSources` flag is both the expanded state and the sample-everything switch.
        // View-based so clicking it toggles the section in place instead of dismissing the menu.
        otherSourcesHeaderItem = NSMenuItem(title: MenuTitle.otherSources, action: nil, keyEquivalent: "")
        otherSourcesHeaderView = DisclosureMenuItemView(onToggle: { [weak self] in self?.toggleShowAllSources() })
        otherSourcesHeaderView.title = MenuTitle.otherSources
        otherSourcesHeaderView.isExpanded = showAllSources
        otherSourcesHeaderItem.view = otherSourcesHeaderView
        infoMenu.addItem(otherSourcesHeaderItem)

        for source in LoadSource.allCases {
            let item = NSMenuItem(title: source.menuTitle, action: #selector(selectLoadSource(_:)), keyEquivalent: "")
            item.target = self
            item.tag = source.rawValue
            item.indentationLevel = 1   // nest visually under the disclosure header
            item.isHidden = true        // revealed only while expanded (refreshShowAllSourcesState)
            infoMenu.addItem(item)
            otherSourceRowItems.append(item)
        }

        infoMenu.addItem(NSMenuItem.separator())

        // "Menu Bar Label" radio group. The parent title carries the current state (off / value /
        // the custom text), so no separate read-only line is needed — mirrors the old overlay item.
        labelMenuItem = NSMenuItem(title: MenuTitle.labelPrefix, action: nil, keyEquivalent: "")
        let labelSubmenu = NSMenu(title: MenuTitle.labelPrefix)

        labelOffItem = NSMenuItem(title: MenuTitle.labelOffItem, action: #selector(selectLabelOff), keyEquivalent: "")
        labelOffItem.target = self
        useSelectionMark(labelOffItem)
        labelSubmenu.addItem(labelOffItem)

        labelValueItem = NSMenuItem(title: MenuTitle.labelValueItem, action: #selector(selectLabelValue), keyEquivalent: "")
        labelValueItem.target = self
        useSelectionMark(labelValueItem)
        labelSubmenu.addItem(labelValueItem)

        labelCustomItem = NSMenuItem(title: MenuTitle.labelCustomItem(max: Tuning.labelMaxChars), action: #selector(promptCustomLabel), keyEquivalent: "")
        labelCustomItem.target = self
        useSelectionMark(labelCustomItem)
        labelSubmenu.addItem(labelCustomItem)

        labelMenuItem.submenu = labelSubmenu
        infoMenu.addItem(labelMenuItem)

        infoMenu.addItem(NSMenuItem.separator())
        keepAwakeMenuItem = NSMenuItem(title: MenuTitle.keepAwake, action: #selector(toggleKeepAwake), keyEquivalent: "")
        keepAwakeMenuItem.target = self
        useSelectionMark(keepAwakeMenuItem)
        infoMenu.addItem(keepAwakeMenuItem)

        // Sibling submenu (a radio group) for the track-line tint — the Keep Awake item stays a
        // one-click toggle, so the color choice lives alongside it like Load Source does, not nested.
        keepAwakeColorMenuItem = NSMenuItem(title: MenuTitle.keepAwakeColor, action: nil, keyEquivalent: "")
        let keepAwakeColorSubmenu = NSMenu(title: MenuTitle.keepAwakeColor)
        for choice in KeepAwakeColor.allCases {
            let item = NSMenuItem(title: choice.menuTitle, action: #selector(selectKeepAwakeColor(_:)), keyEquivalent: "")
            item.target = self
            item.tag = choice.rawValue
            useSelectionMark(item)
            keepAwakeColorSubmenu.addItem(item)
            keepAwakeColorMenuItems.append(item)
        }
        keepAwakeColorMenuItem.submenu = keepAwakeColorSubmenu
        infoMenu.addItem(keepAwakeColorMenuItem)

        infoMenu.addItem(NSMenuItem.separator())
        let presetsHeaderItem = NSMenuItem(title: MenuTitle.presets, action: nil, keyEquivalent: "")
        infoMenu.addItem(presetsHeaderItem)

        for (index, preset) in allPresets.enumerated() {
            let item = NSMenuItem(title: preset.menuTitle, action: #selector(selectPreset(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            useSelectionMark(item)
            infoMenu.addItem(item)
            presetMenuItems.append(item)
        }

        infoMenu.addItem(NSMenuItem.separator())
        // Update-check items. `updateItem` is a passive "Update available" line, hidden until a probe
        // finds a newer release; "Check for Updates…" forces a fresh probe. Both are hidden entirely
        // when this isn't a git checkout (repoDirURL == nil) — see refreshUpdateStatus(). Top-level, so
        // the blanket target-wiring below covers them.
        updateItem = NSMenuItem(title: MenuTitle.updateAvailablePrefix, action: #selector(promptSelfUpdate), keyEquivalent: "")
        updateItem.isHidden = true
        infoMenu.addItem(updateItem)
        checkForUpdatesItem = NSMenuItem(title: MenuTitle.checkForUpdates, action: #selector(checkForUpdates), keyEquivalent: "")
        infoMenu.addItem(checkForUpdatesItem)

        infoMenu.addItem(NSMenuItem.separator())
        infoMenu.addItem(NSMenuItem(title: MenuTitle.about, action: #selector(showAbout), keyEquivalent: ""))
        infoMenu.addItem(NSMenuItem(title: MenuTitle.exit, action: #selector(exitApp), keyEquivalent: "q"))
        infoMenu.items.forEach { $0.target = self }
        presetsHeaderItem.isEnabled = false
        statusItem.menu = infoMenu
        refreshPresetSelectionState()
        refreshWidthInfo()
        refreshLabelSelectionState()
        applyLabelMode()   // create the value slot now if launched with --label value / custom text
        refreshShowAllSourcesState()
        refreshKeepAwakeColorSelectionState()
        refreshUpdateStatus()

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
            MainActor.assumeIsolated { self?.conditionsDidChange() }
        }
        thermalStateObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.conditionsDidChange() }
        }
        startBatteryMonitoring()

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

        // One-shot update probe on launch: fail-silent, off the main thread. MVP has no
        // throttle/persistence (the binary has no bundle id, so UserDefaults has no reliable domain) —
        // we check once per launch and let "Check for Updates…" re-check on demand. Skipped when
        // disabled by flag/env and under smoke-test runs (suppressModalAlerts) so QA stays offline.
        if config.updateCheckEnabled && !suppressModalAlerts {
            startUpdateProbe(userInitiated: false)
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

        // `-w <pid>` already reaps caffeinate on a crash, but a clean exit should terminate it
        // explicitly and tear down the power-source run-loop source. isEnabled is left intact; the
        // process is what we kill (suspend: true forces the kill branch).
        sleepPreventer.applyConditions(suspend: true)
        if let source = batteryRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
            batteryRunLoopSource = nil
        }
    }

    @objc
    private func showAbout() {
        let alert = NSAlert()
        // messageText is the bold title; keep it the app + version, the way a standard macOS About
        // panel reads. The body carries the tagline, live mode, and the OSS credits/copyright block.
        alert.messageText = "\(AppInfo.name) \(AppInfo.version)"
        if let icon = makeMenuAlertIcon() {
            alert.icon = icon
        }
        let speedMode = isAutoSpeed
            ? "Speed adapts to \(activeLoadSource.menuTitle) load (change it in the Load Source menu)."
            : "Fixed speed: \(String(format: "%.2f", speedMultiplier))×."
        alert.informativeText = [
            AppInfo.tagline,
            speedMode,
            "\(AppInfo.copyright) · \(AppInfo.license)",
            "Preset artwork © its respective creators — see the repository for attribution.",
        ].joined(separator: "\n\n")
        alert.alertStyle = .informational
        // Standard OSS About affordance: a link out to the project. First button is the default
        // (rightmost / Return); "View on GitHub" sits to its left and opens the repo.
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "View on GitHub")
        if alert.runModal() == .alertSecondButtonReturn, let url = URL(string: AppInfo.repositoryURL) {
            NSWorkspace.shared.open(url)
        }
    }

    @objc
    private func exitApp() {
        NSApp.terminate(nil)
    }

    // MARK: - Update check

    // Reflects the latest probe result into the menu. Read-only of already-fetched state (never blocks
    // on git) since it runs on every menuWillOpen. When this isn't a git checkout there's nothing to
    // pull, so both update items are hidden entirely.
    private func refreshUpdateStatus() {
        guard repoDirURL != nil else {
            updateItem.isHidden = true
            checkForUpdatesItem.isHidden = true
            return
        }
        checkForUpdatesItem.isHidden = false
        checkForUpdatesItem.isEnabled = !updateCheckInFlight
        checkForUpdatesItem.title = updateCheckInFlight ? MenuTitle.checkingForUpdates : MenuTitle.checkForUpdates

        if let latest = latestKnownVersion, let current = SemVer(AppInfo.version), latest > current {
            let title = MenuTitle.line(MenuTitle.updateAvailablePrefix, "\(latest.tagString) →")
            let bold = NSFontManager.shared.convert(NSFont.menuFont(ofSize: 0), toHaveTrait: .boldFontMask)
            updateItem.attributedTitle = NSAttributedString(string: title, attributes: [.font: bold])
            updateItem.isHidden = false
        } else {
            updateItem.isHidden = true
        }
    }

    // Kicks off a single off-main `ls-remote` probe. Fail-silent for the launch check; a user-initiated
    // check (from "Check for Updates…") reports its outcome via reportManualCheckResult. Guards against
    // stacking concurrent git processes.
    private func startUpdateProbe(userInitiated: Bool) {
        guard let repoDir = repoDirURL else {
            if userInitiated {
                showRuntimeError("Updates aren't available — this build isn't a git checkout.")
            }
            return
        }
        guard !updateCheckInFlight else { return }
        updateCheckInFlight = true
        refreshUpdateStatus()
        DispatchQueue.global(qos: .utility).async {
            let latest = UpdateChecker.latestRemoteTag(repoDir: repoDir)
            // Weak capture goes on the main-queue closure (not the background one) to avoid capturing a
            // mutable `self` var across the concurrency boundary — matches the notification-handler idiom.
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.updateCheckInFlight = false
                    if let latest { self.latestKnownVersion = latest }
                    self.refreshUpdateStatus()
                    if userInitiated { self.reportManualCheckResult(latest: latest) }
                }
            }
        }
    }

    // Feedback for a user-initiated check (the menu has closed by now, so the passive item alone isn't
    // enough). A newer version routes straight to the confirm; otherwise a brief info/warning alert.
    private func reportManualCheckResult(latest: SemVer?) {
        guard let latest else {
            showRuntimeError("Couldn't check for updates. Check your connection and try again.")
            return
        }
        guard let current = SemVer(AppInfo.version), latest > current else {
            informational(title: "You're up to date",
                          message: "MenuBar Load Runner \(AppInfo.version) is the latest release.")
            return
        }
        promptSelfUpdate()
    }

    @objc
    private func checkForUpdates() {
        startUpdateProbe(userInitiated: true)
    }

    // The click-gated apply: confirm, then fast-forward pull. This is the ONLY path that mutates the
    // checkout, and it always requires the menu click plus this confirm — never automatic.
    @objc
    private func promptSelfUpdate() {
        guard let repoDir = repoDirURL,
              let latest = latestKnownVersion,
              let current = SemVer(AppInfo.version), latest > current else {
            return   // state changed since the menu rendered; nothing to do
        }
        if suppressModalAlerts {
            fputs("Update available: \(latest.tagString) (self-update skipped in headless run).\n", stderr)
            return
        }
        let alert = NSAlert()
        alert.messageText = "Update to \(latest.tagString)?"
        if let icon = makeMenuAlertIcon() {
            alert.icon = icon
        }
        alert.informativeText = "This runs 'git pull --ff-only' in \(repoDir.path), then you restart the app to load the new version."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Update")   // first = default (Return)
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        updateCheckInFlight = true
        refreshUpdateStatus()
        DispatchQueue.global(qos: .userInitiated).async {
            let result = UpdateChecker.pull(repoDir: repoDir)
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.updateCheckInFlight = false
                    self.refreshUpdateStatus()
                    if result.ok {
                        self.informational(
                            title: "Updated to \(latest.tagString)",
                            message: "Restart MenuBar Load Runner to load the new version — quit from the menu and relaunch (it also starts fresh at next login)."
                        )
                    } else {
                        self.showUpdateFailed(message: result.message)
                    }
                }
            }
        }
    }

    // Update failed (dirty tree / non-fast-forward / conflict): surface git's message and offer the
    // releases page as an escape hatch. No --force fallback — a diverged checkout is the user's call.
    private func showUpdateFailed(message: String) {
        let detail = message.isEmpty ? "git pull failed." : message
        if suppressModalAlerts {
            fputs("Update failed: \(detail)\n", stderr)
            return
        }
        let alert = NSAlert()
        alert.messageText = "Update failed"
        if let icon = makeMenuAlertIcon() {
            alert.icon = icon
        }
        alert.informativeText = "\(detail)\n\nYou can update manually with 'git pull', or open the releases page."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open Releases Page")   // first = default (Return)
        alert.addButton(withTitle: "Close")
        if alert.runModal() == .alertFirstButtonReturn, let url = URL(string: AppInfo.releasesURL) {
            NSWorkspace.shared.open(url)
        }
    }

    // Small informational-alert helper (honors suppressModalAlerts for headless runs).
    private func informational(title: String, message: String) {
        if suppressModalAlerts {
            fputs("\(title): \(message)\n", stderr)
            return
        }
        let alert = NSAlert()
        alert.messageText = title
        if let icon = makeMenuAlertIcon() {
            alert.icon = icon
        }
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.runModal()
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
            recordLoadSample(chartSample(forDriver: usage))
            if isAutoSpeed {
                let candidate = speedMultiplier(forUsage: usage)
                if abs(candidate - speedMultiplier) >= Tuning.speedUpdateHysteresis {
                    // The driver reads speedMultiplier live via the accumulator, so the
                    // new speed takes effect on the next tick — no need to restart it.
                    speedMultiplier = candidate
                }
            }
        }

        // Show-all mode: also refresh the inactive available readers so the other-sources rows aren't
        // stale. They share this tick's `elapsed` (correct for counter-delta sources, whose baselines
        // are kept fresh by priming on engage). Return values are ignored — only the active source
        // drives speed. Skipped when off, preserving active-only sampling by default.
        if showAllSources {
            for source in LoadSource.allCases where source != activeLoadSource && isSourceAvailable(source) {
                _ = sampleSource(source, elapsed: elapsed)
            }
        }

        refreshMenuMetrics()
    }

    // Sample whichever reader currently drives the animation, returning its 0…1 fraction (or nil
    // if unavailable / not warmed up). The single point where the active source is read for speed.
    private func sampleActiveSource(elapsed: Double?) -> Double? {
        sampleSource(activeLoadSource, elapsed: elapsed)
    }

    // Sample one specific reader (any source, not just the active one), returning its 0…1 fraction.
    // Used by sampleActiveSource, by the show-all-sources fan-out, and by the baseline-priming pass.
    private func sampleSource(_ source: LoadSource, elapsed: Double?) -> Double? {
        switch source {
        case .cpu: return loadMonitor.sampleUsage()
        case .memory: return memoryMonitor.sampleUsage(elapsed: elapsed)
        case .gpu: return gpuMonitor.sampleUsage()
        case .network: return networkMonitor.sampleUsage(elapsed: elapsed)
        case .disk: return diskMonitor.sampleUsage(elapsed: elapsed)
        case .fan: return fanMonitor.sampleUsage()
        case .battery: return batteryMonitor.sampleUsage()
        }
    }

    // The 0…1 value the trace chart should plot for the active source. Identical to the driving
    // fraction for every source except battery, where the chart is a fuel gauge (charge level) rather
    // than the discharge-current driver — because on a battery LOW is the alert, not high. Charge is
    // valid whether plugged in or not, so this works on AC too. The driver still governs speed.
    private func chartSample(forDriver driver: Double) -> Double {
        activeLoadSource == .battery ? batteryMonitor.currentChargeFraction : driver
    }

    // Append a 0…1 chart value to the trace-chart ring buffer, trimming to capacity.
    private func recordLoadSample(_ usage: Double) {
        loadHistory.append(min(max(usage, 0), 1))
        if loadHistory.count > Tuning.loadHistoryCapacity {
            loadHistory.removeFirst(loadHistory.count - Tuning.loadHistoryCapacity)
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
        case .fan: return fanMonitor.hasSample
        case .battery: return batteryMonitor.hasSample
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
        case .fan: return fanMonitor.currentUtilization
        case .battery: return batteryMonitor.currentLoad
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        refreshMenuMetrics()
        refreshPresetSelectionState()
        refreshWidthInfo()
        refreshLabelSelectionState()
        refreshShowAllSourcesState()
        refreshKeepAwakeColorSelectionState()
        refreshUpdateStatus()
    }

    private func refreshMenuMetrics() {
        // Trace chart mirrors the active source's recent driving fractions (0…1), the same values
        // that map to the speed multiplier. Pushed here so it refreshes both on the 2s tick (menu
        // open or not) and on menuWillOpen.
        loadHistoryView.sourceLabel = activeLoadSource.menuTitle
        loadHistoryView.warmingUp = !activeSourceHasSample
        loadHistoryView.samples = loadHistory
        // Battery is a fuel gauge (charge level, low = alert); everyone else plots the driving
        // fraction (high = alert) at the CPU State thresholds. See chartSample(forDriver:).
        if activeLoadSource == .battery {
            loadHistoryView.colorPolarity = .lowIsHot
            loadHistoryView.lowThreshold = Tuning.batteryLowThreshold
            loadHistoryView.mediumThreshold = Tuning.batteryChargeMediumThreshold
        } else {
            loadHistoryView.colorPolarity = .highIsHot
            loadHistoryView.lowThreshold = Tuning.cpuStateLowThreshold
            loadHistoryView.mediumThreshold = Tuning.cpuStateMediumThreshold
        }

        // Source-conditional: usageItem/stateItem show the ACTIVE source's metric + state. The
        // inactive source isn't sampled (see sampleSystemLoad), so showing its stale line would
        // mislead — instead only the driver's figures appear. Load Avg stays (system-wide).
        switch activeLoadSource {
        case .cpu:
            if loadMonitor.hasSample {
                usageItem.title = MenuTitle.line(MenuTitle.cpuUsageQualified, String(format: "%.1f%%", loadMonitor.smoothedUsage * Tuning.percentScale))
                stateItem.title = MenuTitle.line(MenuTitle.statePrefix(for: .cpu), cpuStateText(for: loadMonitor.smoothedUsage))
                statusItem.button?.setAccessibilityLabel(String(
                    format: "MenuBar Load Runner — CPU %.0f%%, %@",
                    loadMonitor.smoothedUsage * Tuning.percentScale,
                    cpuStateText(for: loadMonitor.smoothedUsage)
                ))
            } else {
                usageItem.title = MenuTitle.line(MenuTitle.cpuUsageQualified, MenuTitle.warmingUp)
                stateItem.title = MenuTitle.line(MenuTitle.statePrefix(for: .cpu), MenuTitle.warmingUp)
                statusItem.button?.setAccessibilityLabel("MenuBar Load Runner — measuring CPU load")
            }
        case .memory:
            // Memory pressure (state line) reflects the cached dispatch-source level and is valid
            // even before the first used-fraction sample, so it's shown unconditionally.
            stateItem.title = MenuTitle.line(MenuTitle.memoryPressurePrefix, memoryPressureText())
            if memoryMonitor.hasSample {
                usageItem.title = memoryUsageLineText()
                statusItem.button?.setAccessibilityLabel(String(
                    format: "MenuBar Load Runner — memory %.0f%%, pressure %@",
                    memoryMonitor.currentUsedFraction * Tuning.percentScale,
                    memoryPressureText()
                ))
            } else {
                usageItem.title = MenuTitle.line(LoadSource.memory.menuTitle, MenuTitle.warmingUp)
                statusItem.button?.setAccessibilityLabel("MenuBar Load Runner — measuring memory load")
            }
        case .gpu:
            if gpuMonitor.hasSample {
                usageItem.title = MenuTitle.line(LoadSource.gpu.menuTitle, String(format: "%.0f%%", gpuMonitor.currentUtilization * Tuning.percentScale))
                stateItem.title = MenuTitle.line(MenuTitle.statePrefix(for: .gpu), cpuStateText(for: gpuMonitor.currentUtilization))
                statusItem.button?.setAccessibilityLabel(String(
                    format: "MenuBar Load Runner — GPU %.0f%%, %@",
                    gpuMonitor.currentUtilization * Tuning.percentScale,
                    cpuStateText(for: gpuMonitor.currentUtilization)
                ))
            } else {
                usageItem.title = MenuTitle.line(LoadSource.gpu.menuTitle, MenuTitle.warmingUp)
                stateItem.title = MenuTitle.line(MenuTitle.statePrefix(for: .gpu), MenuTitle.warmingUp)
                statusItem.button?.setAccessibilityLabel("MenuBar Load Runner — measuring GPU load")
            }
        case .network:
            if networkMonitor.hasSample {
                usageItem.title = networkUsageLineText()
                stateItem.title = MenuTitle.line(MenuTitle.statePrefix(for: .network), cpuStateText(for: networkMonitor.currentLoad))
                statusItem.button?.setAccessibilityLabel(String(
                    format: "MenuBar Load Runner — network ↓%.1f MB/s ↑%.1f MB/s, %@",
                    networkMonitor.currentInboundBytesPerSec / Tuning.bytesPerMiB,
                    networkMonitor.currentOutboundBytesPerSec / Tuning.bytesPerMiB,
                    cpuStateText(for: networkMonitor.currentLoad)
                ))
            } else {
                usageItem.title = MenuTitle.line(LoadSource.network.menuTitle, MenuTitle.warmingUp)
                stateItem.title = MenuTitle.line(MenuTitle.statePrefix(for: .network), MenuTitle.warmingUp)
                statusItem.button?.setAccessibilityLabel("MenuBar Load Runner — measuring network load")
            }
        case .disk:
            if diskMonitor.hasSample {
                usageItem.title = diskUsageLineText()
                stateItem.title = MenuTitle.line(MenuTitle.statePrefix(for: .disk), cpuStateText(for: diskMonitor.currentLoad))
                statusItem.button?.setAccessibilityLabel(String(
                    format: "MenuBar Load Runner — disk read %.1f MB/s write %.1f MB/s, %@",
                    diskMonitor.currentReadBytesPerSec / Tuning.bytesPerMiB,
                    diskMonitor.currentWriteBytesPerSec / Tuning.bytesPerMiB,
                    cpuStateText(for: diskMonitor.currentLoad)
                ))
            } else {
                usageItem.title = MenuTitle.line(LoadSource.disk.menuTitle, MenuTitle.warmingUp)
                stateItem.title = MenuTitle.line(MenuTitle.statePrefix(for: .disk), MenuTitle.warmingUp)
                statusItem.button?.setAccessibilityLabel("MenuBar Load Runner — measuring disk load")
            }
        case .fan:
            if fanMonitor.hasSample {
                usageItem.title = fanUsageLineText()
                stateItem.title = MenuTitle.line(MenuTitle.statePrefix(for: .fan), cpuStateText(for: fanMonitor.currentUtilization))
                statusItem.button?.setAccessibilityLabel(String(
                    format: "MenuBar Load Runner — fan avg %.0f%%, %@",
                    fanMonitor.currentUtilization * Tuning.percentScale,
                    cpuStateText(for: fanMonitor.currentUtilization)
                ))
            } else {
                usageItem.title = MenuTitle.line(LoadSource.fan.menuTitle, MenuTitle.warmingUp)
                stateItem.title = MenuTitle.line(MenuTitle.statePrefix(for: .fan), MenuTitle.warmingUp)
                statusItem.button?.setAccessibilityLabel("MenuBar Load Runner — measuring fan load")
            }
        case .battery:
            if batteryMonitor.hasSample {
                usageItem.title = batteryUsageLineText()
                // State names the drain band while on battery (the driver), or "On AC" when plugged in
                // (current 0 → idle animation) — more useful than a Low/Med/High of a zero draw.
                let stateText = batteryMonitor.onBattery ? cpuStateText(for: batteryMonitor.currentLoad) : "On AC"
                stateItem.title = MenuTitle.line(MenuTitle.statePrefix(for: .battery), stateText)
                statusItem.button?.setAccessibilityLabel(String(
                    format: "MenuBar Load Runner — battery %.0f%%, %@",
                    batteryMonitor.currentChargeFraction * Tuning.percentScale,
                    stateText
                ))
            } else {
                usageItem.title = MenuTitle.line(LoadSource.battery.menuTitle, MenuTitle.warmingUp)
                stateItem.title = MenuTitle.line(MenuTitle.statePrefix(for: .battery), MenuTitle.warmingUp)
                statusItem.button?.setAccessibilityLabel("MenuBar Load Runner — measuring battery load")
            }
        }

        if isAutoSpeed {
            // Includes the active source so the dashboard shows WHAT drives the animation.
            speedMultiplierItem.title = MenuTitle.line(
                MenuTitle.speedAuto(activeLoadSource.menuTitle),
                String(format: "%.2fx", speedMultiplier)
            )
            // Name the active self-throttle cause(s) rather than a generic "throttled" tag, so the
            // line distinguishes true thermal throttling from Low Power Mode / memory pressure.
            let reasons = loadReductionReasons
            if reasons.isEmpty {
                throttleStatusItem.isHidden = true
            } else {
                throttleStatusItem.title = MenuTitle.slowingAnimation + " — " + reasons.joined(separator: ", ")
                throttleStatusItem.isHidden = false
            }
        } else {
            speedMultiplierItem.title = MenuTitle.line(MenuTitle.speedFixed, String(format: "%.2fx", speedMultiplier))
            throttleStatusItem.isHidden = true
        }

        if let (avg1, avg5, avg15) = cachedLoadAverages {
            loadAverageItem.title = MenuTitle.line(MenuTitle.loadAvgPrefix, String(format: "%.2f / %.2f / %.2f", avg1, avg5, avg15))
        } else {
            loadAverageItem.title = MenuTitle.line(MenuTitle.loadAvgPrefix, MenuTitle.loadAvgUnavailable)
        }

        // Refresh the adjacent live-value slot on the same cadence (2s tick + menuWillOpen). Cheap
        // when the label is off or custom — updateValueLabel() only rebuilds text in .value mode.
        updateValueLabel()
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
            line += String(
                format: " · swap %.1f/%.1f GB",
                Double(memoryMonitor.swapUsedBytes) / Tuning.bytesPerGiB,
                Double(memoryMonitor.swapTotalBytes) / Tuning.bytesPerGiB
            )
        }
        // Show the swap *rate* when actively paging — it's part of what drives the animation, so the
        // dashboard shouldn't read "Memory: 40%" while swap activity pushes the speed higher.
        if memoryMonitor.hasSwapRateSample, memoryMonitor.currentSwapRateBytesPerSec > 0 {
            line += String(format: " · %.1f MB/s", memoryMonitor.currentSwapRateBytesPerSec / Tuning.bytesPerMiB)
        }
        return line
    }

    // Network/disk/fan metric lines: the human-meaningful readouts (MB/s per direction, RPM per fan),
    // not the adaptive-normalized 0…1 load that actually drives the animation (that's
    // activeSourceCurrentUsage — the average of the two figures shown here). Mirrors the memory line
    // showing raw used-% while the composite drives speed.
    private func networkUsageLineText() -> String {
        String(
            format: "Network: ↓%.1f MB/s ↑%.1f MB/s",
            networkMonitor.currentInboundBytesPerSec / Tuning.bytesPerMiB,
            networkMonitor.currentOutboundBytesPerSec / Tuning.bytesPerMiB
        )
    }

    private func diskUsageLineText() -> String {
        String(
            format: "Disk: read %.1f MB/s write %.1f MB/s",
            diskMonitor.currentReadBytesPerSec / Tuning.bytesPerMiB,
            diskMonitor.currentWriteBytesPerSec / Tuning.bytesPerMiB
        )
    }

    // One "RPM (util%)" segment per fan, joined with " · " — mirrors memoryUsageLineText's
    // multi-clause style.
    private func fanUsageLineText() -> String {
        let segments = fanMonitor.perFan.enumerated().map { index, reading in
            String(format: "Fan %d: %.0f RPM (%.0f%%)", index + 1, reading.rpm, reading.utilization * Tuning.percentScale)
        }
        return segments.joined(separator: " · ")
    }

    // Battery line: charge % (the readout) plus the discharge current in amps while on battery — the
    // drain that drives the animation — or "AC" when plugged in. Mirrors the memory line showing the
    // raw figure alongside what actually drives speed (the scaler-normalized draw).
    private func batteryUsageLineText() -> String {
        let pct = batteryMonitor.currentChargeFraction * Tuning.percentScale
        var line = String(format: "Battery: %.0f%%", pct)
        if batteryMonitor.onBattery {
            if batteryMonitor.currentDischargeMilliamps > 0 {
                line += String(format: " · %.1f A", batteryMonitor.currentDischargeMilliamps / 1000)
            }
        } else {
            line += " · AC"
        }
        return line
    }

    private func refreshPresetSelectionState() {
        let fileManager = FileManager.default
        for (item, preset) in zip(presetMenuItems, allPresets) {
            item.isEnabled = fileManager.fileExists(atPath: preset.path)
            item.state = (activePreset?.key == preset.key) ? .on : .off
        }
    }

    // Radio group for the keep-awake track-line tint — same shape as the load-source/preset checks.
    // Both options are always available (they're pure colors), so no isEnabled dance is needed.
    private func refreshKeepAwakeColorSelectionState() {
        for item in keepAwakeColorMenuItems {
            item.state = (item.tag == activeKeepAwakeColor.rawValue) ? .on : .off
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
        case .fan: return fanMonitor.isAvailable
        case .battery: return batteryMonitor.isAvailable
        }
    }

    // Debug/test hook: MENUBAR_LOAD_RUNNER_FORCE_UNAVAILABLE=gpu,network,disk marks those sources
    // unavailable regardless of hardware, so §3/§7 QA can verify the disabled menu item and the
    // launch-time fallback-to-cpu. Empty/unset = no override. Mirrors the EXIT_AFTER hook convention.
    private let forcedUnavailableSources: Set<String> = {
        guard let raw = ProcessInfo.processInfo.environment["MENUBAR_LOAD_RUNNER_FORCE_UNAVAILABLE"] else { return [] }
        return Set(raw.lowercased().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
    }()

    // Read-only: report the GIF-derived item size (there is no width control). Shows the slot
    // width in points and the GIF's aspect ratio that produced it.
    private func refreshWidthInfo() {
        guard !frames.isEmpty else {
            widthStatusItem.title = MenuTitle.line(MenuTitle.widthPrefix, MenuTitle.placeholderValue)
            return
        }
        widthStatusItem.title = MenuTitle.line(
            MenuTitle.widthPrefix,
            String(format: "%.0f pt (GIF aspect %.2f×)", slotLength(), currentGifAspect())
        )
    }

    // Reflect the current label mode in the submenu: parent title shows the state, and the radio
    // checks mark the active choice. Called on menuWillOpen and after any mode change.
    private func refreshLabelSelectionState() {
        switch labelMode {
        case .off:
            labelMenuItem.title = MenuTitle.label(MenuTitle.labelOff)
        case .value:
            labelMenuItem.title = MenuTitle.label(MenuTitle.labelValueItem.lowercased())
        case .custom(let text):
            labelMenuItem.title = MenuTitle.label("\"\(text)\"")
        }
        labelOffItem.state = (labelMode == .off) ? .on : .off
        labelValueItem.state = (labelMode == .value) ? .on : .off
        if case .custom = labelMode { labelCustomItem.state = .on } else { labelCustomItem.state = .off }
    }

    // Reconcile the value slot's existence and content with labelMode. .off tears the second status
    // item down (freeing the menu-bar slot); .value / .custom create it on demand and refresh its text.
    private func applyLabelMode() {
        if labelMode == .off {
            if let item = valueStatusItem {
                NSStatusBar.system.removeStatusItem(item)
                valueStatusItem = nil
            }
            return
        }
        if valueStatusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            // Native menu-bar text look; button.title (not attributedTitle) so the color tracks the
            // menu-bar appearance automatically. Shares the same dropdown as the animation item.
            item.button?.font = NSFont.menuBarFont(ofSize: 0)
            item.button?.imagePosition = .noImage
            item.menu = infoMenu
            valueStatusItem = item
        }
        updateValueLabel()
    }

    // Write the current label text into the value slot (no-op if the slot doesn't exist). In .value
    // mode this is the active source's compact live reading; in .custom mode, the fixed user string.
    private func updateValueLabel() {
        guard let button = valueStatusItem?.button else { return }
        switch labelMode {
        case .off:
            return
        case .value:
            button.title = compactLabelText(for: activeLoadSource)
        case .custom(let text):
            button.title = text
        }
    }

    // A short, menu-bar-sized readout of a source's live value: "CPU 47%", "MEM 63%", "NET ↓3.4↑0.1",
    // "DSK R12 W4", "GPU 30%", "FAN 45%", "BAT 88%" (MB/s implied for the rate sources). Compact
    // deliberately — the dropdown carries the fully-labeled figures; this is the at-a-glance number.
    private func compactLabelText(for source: LoadSource) -> String {
        let tag = source.menuTitle.prefix(3).uppercased()
        guard activeSourceHasSample else { return "\(tag) …" }
        switch source {
        case .cpu:
            return String(format: "CPU %.0f%%", loadMonitor.smoothedUsage * Tuning.percentScale)
        case .memory:
            return String(format: "MEM %.0f%%", memoryMonitor.currentUsedFraction * Tuning.percentScale)
        case .gpu:
            return String(format: "GPU %.0f%%", gpuMonitor.currentUtilization * Tuning.percentScale)
        case .network:
            return String(
                format: "NET ↓%.1f ↑%.1f",
                networkMonitor.currentInboundBytesPerSec / Tuning.bytesPerMiB,
                networkMonitor.currentOutboundBytesPerSec / Tuning.bytesPerMiB
            )
        case .disk:
            return String(
                format: "DSK R%.0f W%.0f",
                diskMonitor.currentReadBytesPerSec / Tuning.bytesPerMiB,
                diskMonitor.currentWriteBytesPerSec / Tuning.bytesPerMiB
            )
        case .fan:
            return String(format: "FAN %.0f%%", fanMonitor.currentUtilization * Tuning.percentScale)
        case .battery:
            return String(format: "BAT %.0f%%", batteryMonitor.currentChargeFraction * Tuning.percentScale)
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
        // A mixed-source history would be meaningless, so drop the old source's trace; seed it with
        // the on-demand resample if that source already has a usable value (e.g. CPU/GPU/memory).
        loadHistory.removeAll(keepingCapacity: true)
        if let seed = sampleActiveSource(elapsed: nil) {
            recordLoadSample(chartSample(forDriver: seed))
        }
        lastSampleUptime = nil
        reevaluateSpeedForCurrentConditions()
        // Rebuild the other-source rows so the newly-active source drops out of the list and the
        // previously-active one (re)joins it — the list only ever shows the *other* readers.
        refreshShowAllSourcesState()
        refreshMenuMetrics()
    }

    @objc
    private func toggleShowAllSources() {
        showAllSources.toggle()
        // Priming on engage refreshes the dormant counter-delta readers' baselines, so their first
        // delta after the mode turns on isn't computed over a stale multi-minute gap (a rate spike).
        if showAllSources {
            primeInactiveSources()
        }
        refreshShowAllSourcesState()
        refreshMenuMetrics()
    }

    // Store fresh counter baselines for readers that haven't been sampled while inactive, so their
    // first real delta once show-all begins is measured over a single tick, not the whole dormant gap.
    // elapsed=nil → each counter-delta reader just stores its baseline and reports no rate (it warms up
    // on the next 2s tick); instantaneous readers (cpu/gpu/fan/battery) are point reads, so this is a
    // harmless refresh for them. lastSampleUptime is reset so the next tick starts a fresh interval.
    private func primeInactiveSources() {
        for source in LoadSource.allCases where source != activeLoadSource && isSourceAvailable(source) {
            _ = sampleSource(source, elapsed: nil)
        }
        lastSampleUptime = nil
    }

    // Update the disclosure header glyph and the inline per-source rows. Collapsed → every row hidden.
    // Expanded → one compact readout row per *available, non-active* source (the active source is shown
    // on top with the sparkline, and unavailable sources — Fan on fanless Macs, Battery on desktops —
    // stay hidden, mirroring the old disabled Load Source rows). Each visible row is clickable and
    // switches the animation's driving source (selectLoadSource).
    private func refreshShowAllSourcesState() {
        otherSourcesHeaderView.isExpanded = showAllSources
        for item in otherSourceRowItems {
            guard let source = LoadSource(rawValue: item.tag) else { continue }
            if showAllSources, source != activeLoadSource, isSourceAvailable(source) {
                item.isHidden = false
                item.title = allSourcesRowText(for: source)
            } else {
                item.isHidden = true
            }
        }
    }

    // One compact "<Source>: <value>" row for the other-sources list, reusing the same line builders
    // as the single-source dashboard so the two never drift. "warming up..." until the reader (a
    // counter-delta source) has produced its first usable sample.
    private func allSourcesRowText(for source: LoadSource) -> String {
        let warming = MenuTitle.line(source.menuTitle, MenuTitle.warmingUp)
        switch source {
        case .cpu:
            guard loadMonitor.hasSample else { return warming }
            return String(format: "CPU: %.1f%%", loadMonitor.smoothedUsage * Tuning.percentScale)
        case .memory:
            guard memoryMonitor.hasSample else { return warming }
            return memoryUsageLineText()
        case .gpu:
            guard gpuMonitor.hasSample else { return warming }
            return String(format: "GPU: %.0f%%", gpuMonitor.currentUtilization * Tuning.percentScale)
        case .network:
            guard networkMonitor.hasSample else { return warming }
            return networkUsageLineText()
        case .disk:
            guard diskMonitor.hasSample else { return warming }
            return diskUsageLineText()
        case .fan:
            guard fanMonitor.hasSample else { return warming }
            return fanUsageLineText()
        case .battery:
            guard batteryMonitor.hasSample else { return warming }
            return batteryUsageLineText()
        }
    }

    @objc
    private func selectKeepAwakeColor(_ sender: NSMenuItem) {
        guard let choice = KeepAwakeColor(rawValue: sender.tag), choice != activeKeepAwakeColor else { return }
        activeKeepAwakeColor = choice
        updateKeepAwakeBar()   // re-tint immediately; a no-op paint if the bar is currently hidden
        refreshKeepAwakeColorSelectionState()
    }

    @objc
    private func selectLabelOff() {
        setLabelMode(.off)
    }

    @objc
    private func selectLabelValue() {
        setLabelMode(.value)
    }

    // Prompt for a fixed custom label. Switches to .custom on Apply; an empty field means .off.
    @objc
    private func promptCustomLabel() {
        let alert = NSAlert()
        alert.messageText = "Set Menu Bar Label"
        alert.informativeText = "Shown in its own menu-bar slot. Up to \(Tuning.labelMaxChars) characters; leave blank for none."
        alert.alertStyle = .informational
        if let icon = makeMenuAlertIcon() {
            alert.icon = icon
        }

        let current: String = { if case .custom(let t) = labelMode { return t } else { return "" } }()
        let field = NSTextField(string: current)
        field.placeholderString = "TEXT"
        field.frame = NSRect(x: 0, y: 6, width: 260, height: 24)

        let textLabel = NSTextField(labelWithString: "Label text")
        textLabel.frame = NSRect(x: 0, y: 32, width: 260, height: 16)

        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 52))
        accessory.addSubview(textLabel)
        accessory.addSubview(field)
        alert.accessoryView = accessory

        alert.addButton(withTitle: "Apply")
        alert.addButton(withTitle: "Cancel")

        // Focus the text field. `initialFirstResponder` is the deterministic mechanism —
        // NSAlert makes its window key during runModal() and honors it. One post-present hop
        // remains as a belt-and-suspenders and to place the caret at the end of any pre-filled text.
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

        let input = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        setLabelMode(input.isEmpty ? .off : .custom(String(input.prefix(Tuning.labelMaxChars))))
    }

    // Single point that changes the label mode: updates state, reconciles the slot, refreshes the menu.
    private func setLabelMode(_ mode: MenuBarLabel) {
        guard mode != labelMode else { return }
        labelMode = mode
        applyLabelMode()
        refreshLabelSelectionState()
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
        refreshWidthInfo()

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

    // The distinct system conditions under which this app slows its OWN animation so it doesn't
    // add to a strained machine (getters only — never mutates system state). Ordered most-serious
    // first so the combined menu line reads sensibly. Precise wording matters: only the *thermal*
    // case is throttling macOS actually imposes (it clocks the CPU/GPU down); Low Power Mode is a
    // user-chosen policy, and memory pressure is memory *reclamation* (compression/swap/jetsam),
    // not compute throttling — so neither is called "throttling."
    private var loadReductionReasons: [String] {
        var reasons: [String] = []
        let info = ProcessInfo.processInfo
        switch info.thermalState {
        case .serious, .critical: reasons.append("thermal throttling")
        default: break
        }
        if info.isLowPowerModeEnabled { reasons.append("Low Power Mode") }
        // Memory pressure is event-only (no synchronous getter), so this reads the cached level
        // updated by the dispatch source. Requires `.normal` in the source's mask to ever clear.
        if memoryPressureLevel.contains(.warning) || memoryPressureLevel.contains(.critical) {
            reasons.append("memory pressure")
        }
        return reasons
    }

    // True when any self-throttle condition is active — i.e. when this app should reduce its OWN
    // animation work rather than add to the load it displays. Derived from loadReductionReasons so
    // detection and the menu wording share one source of truth.
    private var isUnderPowerPressure: Bool { !loadReductionReasons.isEmpty }

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

    // Single entry point for the power / thermal / battery observers. Keeps the two concerns
    // independent: the speed recompute keeps its auto-speed guard (it no-ops under
    // --speed-multiplier or before the first sample), while sleep prevention must run
    // unconditionally so it can still DISENGAGE in those cases — so it does NOT piggyback on the
    // guarded recompute. Memory pressure is not a sleep trigger, so its dispatch source keeps
    // calling reevaluateSpeedForCurrentConditions() directly.
    private func conditionsDidChange() {
        reevaluateSpeedForCurrentConditions()   // existing, guarded (auto-speed only)
        updateSleepPrevention()                 // unguarded (always applies keep-awake conditions)
    }

    // Conditions under which we kill caffeinate even while the user's toggle is on. Deliberately
    // minimal: battery critically low (unattended drain protection) and serious/critical thermal
    // (fighting sleep while overheating makes it worse). NOT triggered by lid/display sleep (`-i`
    // intentionally allows the display to sleep), memory pressure, or Low Power Mode — see
    // docs/DESIGN-system.md §22.2 for the rationale.
    private var shouldDisengageSleepPrevention: Bool {
        if batteryLow { return true }
        let t = ProcessInfo.processInfo.thermalState
        return t == .serious || t == .critical
    }

    private func updateSleepPrevention() {
        sleepPreventer.applyConditions(suspend: shouldDisengageSleepPrevention)
        keepAwakeMenuItem?.state = sleepPreventer.isEnabled ? .on : .off
        updateKeepAwakeBar()
    }

    @objc private func toggleKeepAwake() {
        sleepPreventer.setEnabled(!sleepPreventer.isEnabled)
        updateSleepPrevention()   // spawns now, or immediately suspends if a condition is already active
    }

    // IOKit Power Sources — event-driven, mirroring the power/thermal notification pattern. Fires on
    // every power-source change (plug/unplug, % delta). A desktop Mac (no battery) skips setup
    // entirely, so batteryLow stays false and is never a disengage trigger there.
    private func startBatteryMonitoring() {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [Any],
              !list.isEmpty else { return }

        let callback: @convention(c) (UnsafeMutableRawPointer?) -> Void = { ctx in
            guard let ctx else { return }
            let app = Unmanaged<MenuBarLoadRunnerApp>.fromOpaque(ctx).takeUnretainedValue()
            MainActor.assumeIsolated {
                app.batteryLow = MenuBarLoadRunnerApp.evaluateBatteryLow()
                app.conditionsDidChange()
            }
        }
        batteryRunLoopSource = IOPSNotificationCreateRunLoopSource(
            callback, Unmanaged.passUnretained(self).toOpaque())?.takeRetainedValue()
        if let source = batteryRunLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        }
        batteryLow = Self.evaluateBatteryLow()   // initial read — don't wait for the first notification
    }

    private static func evaluateBatteryLow() -> Bool {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [Any],
              let first = list.first,
              let dict = IOPSGetPowerSourceDescription(blob, first as CFTypeRef)?
                            .takeUnretainedValue() as? [String: Any] else { return false }
        let capacity = (dict[kIOPSCurrentCapacityKey] as? NSNumber)?.doubleValue ?? 100   // 0–100
        let onBattery = (dict[kIOPSPowerSourceStateKey] as? String) == kIOPSBatteryPowerValue
        return onBattery && capacity <= Tuning.batteryLowThreshold * 100
    }

    // Built once during animation-view setup. A sibling sublayer ON TOP of the frame-content layer,
    // hidden by default. It NEVER touches the frame contents, so a toggle costs no re-rasterization.
    private func installKeepAwakeBar(on host: CALayer) {
        let bar = CALayer()
        bar.isHidden = true
        host.addSublayer(bar)
        keepAwakeBar = bar
    }

    // Called on toggle, on suspend/resume via conditions, and whenever the item resizes
    // (applySizing). Uses isRunning (not isEnabled), so the bar vanishes while a battery/thermal
    // condition has caffeinate suspended and reappears when it resumes — it tracks the ACTUAL state.
    private func updateKeepAwakeBar() {
        guard let bar = keepAwakeBar, let host = animationView?.layer else { return }
        bar.isHidden = !sleepPreventer.isRunning
        guard !bar.isHidden else { return }
        // No implicit position/size animation — the bar should snap, not slide, on resize.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let thickness = Tuning.keepAwakeBarThickness
        bar.frame = CGRect(x: 0, y: 0, width: host.bounds.width, height: thickness)  // bottom edge
        bar.backgroundColor = activeKeepAwakeColor.color(for: statusItem.button?.effectiveAppearance).cgColor
        CATransaction.commit()
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
        guard let layer = animationView?.layer, !renderedFrames.isEmpty, frameIndex < renderedFrames.count else { return }
        // Cheap: hand CoreAnimation a pre-rasterized CGImage. No drawRect, no layout, no
        // constraint solve — the whole point of the layer-backed approach.
        layer.contents = renderedFrames[frameIndex]
    }

    private func updateRenderedFrames() {
        guard !frames.isEmpty else {
            renderedFrames = []
            return
        }

        let availableHeight = max(NSStatusBar.system.thickness - Tuning.renderVerticalInset, 1)
        let availableWidth = max(statusItem.length - Tuning.renderHorizontalInset, 1)
        // Rasterize at the display's backing scale so the CGImages are crisp on Retina; the
        // layer's contentsScale (set below) must match so CoreAnimation maps pixels 1:1.
        let scale = backingScale()

        var newRenderedFrames: [CGImage] = []
        newRenderedFrames.reserveCapacity(frames.count)

        for (i, rawImage) in frames.enumerated() {
            let aspect = i < frameAspects.count ? frameAspects[i] : Tuning.fallbackAspect
            // The slot width already matches the GIF aspect (see slotLength()), so the art fills
            // the slot; this just fits each frame proportionally within the available box.
            let maxHeight = max(availableHeight, Tuning.minIconDimension)
            let maxWidth = max(availableWidth, Tuning.minIconDimension)
            let targetHeight = min(maxHeight, maxWidth / max(aspect, Tuning.minAspect))
            let targetWidth = targetHeight * aspect
            let targetSize = NSSize(width: targetWidth, height: targetHeight)

            // Draw into a bitmap sized in pixels (points × scale). The context is scaled so the
            // drawing code below works in point coordinates, exactly as the old NSImage path did.
            let pixelWidth = max(Int((targetSize.width * scale).rounded()), 1)
            let pixelHeight = max(Int((targetSize.height * scale).rounded()), 1)
            guard let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: pixelWidth,
                pixelsHigh: pixelHeight,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            ), let ctx = NSGraphicsContext(bitmapImageRep: rep) else { continue }

            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = ctx
            ctx.imageInterpolation = .high
            ctx.cgContext.scaleBy(x: scale, y: scale)  // draw in points; bitmap is in pixels

            let imageRect = NSRect(origin: .zero, size: targetSize)
            rawImage.draw(in: imageRect, from: NSRect(origin: .zero, size: rawImage.size), operation: .sourceOver, fraction: 1.0)

            NSGraphicsContext.restoreGraphicsState()
            if let cgImage = rep.cgImage {
                newRenderedFrames.append(cgImage)
            }
        }
        renderedFrames = newRenderedFrames
        animationView?.layer?.contentsScale = scale
    }

    // Backing scale of the display the status item lives on (for crisp Retina rasterization).
    private func backingScale() -> CGFloat {
        statusItem.button?.window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 2.0
    }

    private func applySizing() {
        guard !frames.isEmpty else { return }
        // GIF-based sizing: the item width follows the loaded GIF's own aspect ratio at menu-bar
        // height — no per-preset constant, no user override. The layer's .resizeAspect gravity
        // fills the slot proportionally.
        statusItem.length = slotLength()
        // Re-sync the layer-host view to the (possibly resized) button. Autoresizing tracks live
        // resizes, but setting length may not have laid the button out yet, so pin it explicitly.
        if let button = statusItem.button {
            animationView?.frame = button.bounds
        }
        updateRenderedFrames()
        updateKeepAwakeBar()   // re-lay the overlay bar over the (possibly) resized item
    }

    // The GIF's width/height aspect (frames share one union bbox, so any frame represents the
    // whole animation), clamped to a sane band. This is the sole driver of the item's width.
    private func currentGifAspect() -> CGFloat {
        let aspect = frameAspects.first ?? Tuning.fallbackAspect
        return min(max(aspect, Tuning.minAspect), Tuning.maxIconAspect)
    }

    // Status-item length (points) the GIF maps to: menu-bar height × aspect, floored so a
    // tall/narrow GIF still gets a tappable slot. Shared by applySizing and refreshWidthInfo.
    private func slotLength() -> CGFloat {
        let barHeight = max(NSStatusBar.system.thickness - Tuning.renderVerticalInset, 1)
        return ceil(max(barHeight * currentGifAspect() + Tuning.renderHorizontalInset, Tuning.minBaseSlotWidth))
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

        var rawImages: [CGImage] = []
        var nextDurations: [TimeInterval] = []
        rawImages.reserveCapacity(count)
        nextDurations.reserveCapacity(count)

        for i in 0..<count {
            guard let cgImage = CGImageSourceCreateImageAtIndex(src, i, nil) else {
                continue
            }
            rawImages.append(cgImage)
            nextDurations.append(frameDuration(from: src, frameIndex: i))
        }

        guard !rawImages.isEmpty, rawImages.count == nextDurations.count else {
            fputs("Failed to decode usable GIF frames from: \(gifURL.path)\n", stderr)
            return false
        }

        // Crop every frame to ONE shared bounding box (the union of each frame's own alpha
        // extent) rather than each frame's own tight box. A running/walking gait's limbs
        // extend by a different amount on different frames; trimming each frame independently
        // (the prior behavior) made the resulting image's own size — and therefore its
        // rendered aspect ratio in updateRenderedFrames — change frame to frame, which reads
        // as the whole icon wobbling/resizing as it animates. Trimming to one shared box keeps
        // every frame the same size, so only the artwork inside it moves.
        let unionBox = alphaBoundingBoxUnion(of: rawImages)

        var nextFrames: [NSImage] = []
        var nextAspects: [CGFloat] = []
        nextFrames.reserveCapacity(rawImages.count)
        nextAspects.reserveCapacity(rawImages.count)

        for cgImage in rawImages {
            let preparedImage = crop(cgImage, to: unionBox)
            let image = NSImage(
                cgImage: preparedImage,
                size: NSSize(width: preparedImage.width, height: preparedImage.height)
            )
            nextFrames.append(image)
            let aspect = preparedImage.height > 0
                ? CGFloat(preparedImage.width) / CGFloat(preparedImage.height)
                : Tuning.fallbackAspect
            nextAspects.append(max(aspect, Tuning.minAspect))
        }

        frames = nextFrames
        frameAspects = nextAspects
        baseDurations = nextDurations
        return true
    }

    private struct AlphaBox {
        let minX: Int
        let maxX: Int
        let minY: Int
        let maxY: Int
    }

    // Tight alpha bounding box of a single frame, in the frame's own pixel coordinates.
    // Returns nil when the image has no alpha channel, an unsupported pixel layout, or no
    // pixels above the visibility threshold (fully transparent frame).
    private func alphaBoundingBox(of image: CGImage) -> AlphaBox? {
        let bitmap = NSBitmapImageRep(cgImage: image)
        guard bitmap.hasAlpha, let base = bitmap.bitmapData else { return nil }

        let width = bitmap.pixelsWide
        let height = bitmap.pixelsHigh
        let bytesPerRow = bitmap.bytesPerRow
        let bytesPerPixel = max(bitmap.samplesPerPixel, 1)
        guard width > 0, height > 0, bytesPerPixel >= Tuning.minAlphaPixelComponents else { return nil }

        let alphaOffset: Int
        switch image.alphaInfo {
        case .alphaOnly, .first, .premultipliedFirst, .noneSkipFirst:
            alphaOffset = 0
        case .last, .premultipliedLast, .noneSkipLast:
            alphaOffset = bytesPerPixel - 1
        default:
            return nil
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

        guard maxX >= minX, maxY >= minY else { return nil }
        return AlphaBox(minX: minX, maxX: maxX, minY: minY, maxY: maxY)
    }

    // Smallest box covering every frame's own alpha bounding box, so all frames of a GIF
    // share one crop rect. Frames with no visible pixels (or an unsupported layout) don't
    // contribute. Returns nil if no frame contributed (crop is skipped entirely).
    private func alphaBoundingBoxUnion(of images: [CGImage]) -> AlphaBox? {
        var union: AlphaBox?
        for image in images {
            guard let box = alphaBoundingBox(of: image) else { continue }
            guard let current = union else { union = box; continue }
            union = AlphaBox(
                minX: min(current.minX, box.minX),
                maxX: max(current.maxX, box.maxX),
                minY: min(current.minY, box.minY),
                maxY: max(current.maxY, box.maxY)
            )
        }
        return union
    }

    private func crop(_ image: CGImage, to box: AlphaBox?) -> CGImage {
        guard let box else { return image }
        if box.minX == 0 && box.maxX == image.width - 1 && box.minY == 0 && box.maxY == image.height - 1 {
            return image
        }
        let cropRect = CGRect(x: box.minX, y: box.minY, width: box.maxX - box.minX + 1, height: box.maxY - box.minY + 1)
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
