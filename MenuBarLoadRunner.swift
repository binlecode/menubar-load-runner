import AppKit
import CoreGraphics
import Darwin
import ImageIO
import IOKit
import IOKit.ps
import IOKit.pwr_mgt
import QuartzCore

// Human-facing app version (semver). Surfaced in --help and the About dialog, and the anchor for
// CHANGELOG.md releases. Bump this together with a new CHANGELOG entry and git tag.
private enum AppInfo {
    static let version = "1.19.0"
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
        guard let result = runGit(pullArguments(in: repoDir), in: repoDir) else {
            return (false, "Could not run git.")
        }
        if result.status == 0 {
            return (true, result.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let raw = result.stderr.isEmpty ? result.stdout : result.stderr
        return (false, raw.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // Reads the two facts `pullArguments(upstreamConfigured:branch:)` decides on: whether
    // `@{upstream}` resolves, and the checked-out branch (nil when HEAD is detached).
    private static func pullArguments(in repoDir: URL) -> [String] {
        let upstream = runGit(["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"], in: repoDir)
        let head = runGit(["symbolic-ref", "--short", "--quiet", "HEAD"], in: repoDir)
        return pullArguments(
            upstreamConfigured: upstream?.status == 0,
            branch: head?.status == 0 ? head?.stdout.trimmingCharacters(in: .whitespacesAndNewlines) : nil
        )
    }

    // Bare `git pull --ff-only` needs `branch.<name>.remote`/`.merge`, and a checkout that was copied
    // rather than cloned (or whose branch was made with `--no-track`) has neither — the pull then dies
    // on "There is no tracking information for the current branch", which is *unfixable from inside the
    // app*: no button in the alert can write git config, so the one-click update dead-ends on a
    // checkout that is otherwise a clean fast-forward. Naming the refspec explicitly sidesteps the
    // config entirely. `origin` is the same remote `latestRemoteTag` already reads, so the update
    // applies from wherever the check looked. Detached HEAD keeps the bare form: git's own "You are not
    // currently on a branch" is the right message, and there is no branch to pull into anyway. Pure so
    // the decision is testable without a repo (mirrored in `tests/semver.swift`).
    static func pullArguments(upstreamConfigured: Bool, branch: String?) -> [String] {
        let base = ["pull", "--ff-only"]
        guard !upstreamConfigured, let branch, !branch.isEmpty else { return base }
        return base + ["origin", branch]
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

// Restarting the app after a self-update. The app can't just re-exec itself: `git pull` moves the
// *source*, and it is the launcher script that notices the source is newer than the binary and re-runs
// `swiftc` — so coming back on the new version means invoking whatever started us. That differs per
// install, and the difference is not inferrable from inside the process (a detached run and a
// launchd-supervised one both reparent to pid 1), so each launch path leaves a signal:
//   - launchd: no env marker works — a LaunchAgent job's XPC_SERVICE_NAME is "0", not the job label
//     (verified; it is the obvious-looking signal and it is wrong). Instead launchd is *asked*: it
//     reports the job's pid, and because the plist runs the launcher which `exec`s the binary, that pid
//     IS ours when we are the agent's process.
//   - the launcher: exports MENUBAR_LOAD_RUNNER_LAUNCHER / _LAUNCH_MODE, so a detached run knows the
//     script to re-run.
// Anything else — a `--foreground` run, a raw binary, an unrecognized environment — is `.unsupported`
// and simply gets no Restart button: a foreground run belongs to the shell waiting on it.
private enum Restarter {
    enum Mode: Equatable {
        case launchAgent
        case launcher(path: String)
        case unsupported
    }

    // Must match `LABEL` in scripts/install-login-item.sh — the plist that owns the login-item job.
    static let launchAgentLabel = "ai.bera.menubarloadrunner"

    // Pure so the mapping is testable without a launchd job or a real launcher (tests/restart.swift);
    // the one impure question ("am I the agent's process?") is answered by the caller and passed in.
    static func mode(environment: [String: String], isLaunchAgentJob: Bool) -> Mode {
        if isLaunchAgentJob { return .launchAgent }
        guard environment["MENUBAR_LOAD_RUNNER_LAUNCH_MODE"] == "detached",
              let launcher = environment["MENUBAR_LOAD_RUNNER_LAUNCHER"], !launcher.isEmpty else {
            return .unsupported
        }
        return .launcher(path: launcher)
    }

    // Asks launchd whether the login-item job's process is this one. `launchctl list <label>` prints
    // a `"PID" = <n>;` line for a running job (absent when the job is loaded but idle, and the whole
    // call fails when no such job exists — both correctly read as "not the agent").
    static func isLaunchAgentJob() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["list", launchAgentLabel]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return false
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, let text = String(data: data, encoding: .utf8) else { return false }
        return reportedPID(inLaunchctlList: text) == ProcessInfo.processInfo.processIdentifier
    }

    // Pure parse of `launchctl list <label>` output. nil when there is no PID line (job idle).
    static func reportedPID(inLaunchctlList text: String) -> Int32? {
        for line in text.split(whereSeparator: \.isNewline) where line.contains("\"PID\"") {
            let digits = line.filter(\.isNumber)
            return digits.isEmpty ? nil : Int32(digits)
        }
        return nil
    }

    // The argv to run *after* this process exits. For the agent, `kickstart` on a job that is no
    // longer running starts it fresh (no `-k`, which would SIGKILL us mid-quit and skip the clean
    // shutdown that kills the caffeinate child). For a launcher run, the launcher itself — with
    // arguments, which is why `.launchAgent` loses menu-chosen state a launcher run keeps: the plist's
    // baked ProgramArguments are fixed and nothing here can inject into them.
    static func restartCommand(mode: Mode, appArguments: [String], uid: uid_t) -> [String]? {
        switch mode {
        case .launchAgent:
            return ["/bin/launchctl", "kickstart", "gui/\(uid)/\(launchAgentLabel)"]
        case .launcher(let path):
            return [path] + appArguments
        case .unsupported:
            return nil
        }
    }

    // The argv that reproduces the configuration RUNNING NOW, not the one originally typed: preset,
    // driving source, label, battery threshold and the Other Sources disclosure are all menu-mutable,
    // and a Restart that reverted them would read as the app forgetting what you just set. Keep Awake
    // is the exception — its intent is in the state file and the new process restores it, so only an
    // *indefinite* window needs a flag, because that restore deliberately refuses to resume one (a
    // launch with nobody present must not hold the Mac awake forever; a user-initiated restart is a
    // different situation, and passing the flag is how that intent survives).
    static func appArguments(
        presetOrPath: String,
        loadSourceKey: String,
        labelArgument: String,
        batteryThresholdPercent: Int,
        speedMultiplierOverride: Double?,
        showAllSources: Bool,
        keepAwakeIndefinite: Bool
    ) -> [String] {
        var args: [String] = []
        if !presetOrPath.isEmpty { args.append(presetOrPath) }
        args += ["--load-source", loadSourceKey]
        args += ["--label", labelArgument]
        args += ["--battery-threshold", batteryThresholdPercent <= 0 ? "off" : String(batteryThresholdPercent)]
        if let speedMultiplierOverride {
            args += ["--speed-multiplier", String(speedMultiplierOverride)]
        }
        if showAllSources { args.append("--show-all-sources") }
        if keepAwakeIndefinite { args += ["--keep-awake", "on"] }
        return args
    }

    // Hands the restart to a detached `/bin/sh` that waits for our pid to disappear and then runs
    // `command`. It cannot be done in-process: the launcher's singleton guard refuses while we are
    // still alive, and launchd won't restart a job whose process is still up. The wait is bounded
    // (~30s) so a quit that hangs leaves no shell spinning forever — and if it does time out, the
    // command runs anyway and the singleton guard (or launchd) declines it harmlessly. Args go through
    // `sh`'s argv, never interpolated into the script, so a GIF path with a space or a quote in it
    // can't reshape the command.
    static func spawnRestart(command: [String]) -> Bool {
        guard !command.isEmpty else { return false }
        let script = """
        pid=$1; shift; i=0
        while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 150 ]; do sleep 0.2; i=$((i+1)); done
        exec "$@"
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, "sh", String(ProcessInfo.processInfo.processIdentifier)] + command
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return false
        }
        return true
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
    // Max length of a custom menu-bar label (the adjacent text slot). This bounds how much menu-bar
    // width one instance may claim; live-value readouts are always short and unaffected.
    static let labelMaxChars = 24

    // Adjacent-label slot sizing. The slot's width is RESERVED from the widest reading each shape can
    // produce and then held fixed, never auto-sized to the live text — auto-sizing is what made a value
    // change shove the neighbouring animation sideways twice a second.
    //
    // Each numeric field is sized for a ceiling (below) and padded out to it, so every value of a field
    // measures the same. Percentages use Tuning.percentScale, which is an exact ceiling. The two rate
    // shapes have no true maximum, so these are realistic ones in MB/s: a burst past them widens the slot
    // for that tick rather than clipping the number (see labelSlotWidth) — a rare nudge beats an
    // unreadable value. Raise them if you routinely saturate faster hardware; the cost is a wider slot
    // at all times.
    static let labelRateCeiling = 999.9    // network, one decimal
    static let labelDiskCeiling = 9999.0   // disk, whole MB/s
    // Slack between the text and the slot's content box, on top of the ~16pt of chrome AppKit adds to
    // every status item window regardless. 4pt because that is what AppKit's own variableLength sizing
    // uses: measured with MENUBAR_LOAD_RUNNER_LOG_SLOTS, an auto-sized slot holding a 66.8pt string
    // reported an 87pt window — 16 chrome + 71 content — so matching it keeps the reserved slot visually
    // identical to the native one at its widest, with none of the dead space a generous guess would leave
    // on the widest source (network reserves ~125pt of glyphs). Enough to absorb any rounding between
    // NSAttributedString.size() and the button's own layout, which measure the same string in the same
    // font; too little would truncate the text to an ellipsis, which is the failure to avoid.
    static let labelSlotPadding: CGFloat = 4

    // Keep Awake auto-disengage: on battery power at or below this charge fraction we kill
    // `caffeinate` so an unattended Mac doesn't drain to death mid-task. See SleepPreventer.
    //
    // SLEEP POLICY ONLY, and deliberately a *default* rather than the value read at runtime: this is
    // the release point the user can relocate, so the sleep path must read the live setting and never
    // this constant. It shares the number 0.20 with batteryChartLowThreshold and nothing else —
    // the two were one constant until R5, which is why the split has its own step: moving the release
    // point must not recolor the fuel gauge.
    static let batteryLowThresholdDefault: Double = 0.20

    // The floor under the override. Arming Keep Awake *while already* below the release threshold is
    // an explicit "I know, do it anyway" and is honored (keepAwakeBatteryOverride) — otherwise arming
    // was a silent no-op, the bug this exists to fix. But an override is not a licence to drain to a
    // hard power-off, so it stops being honored here and keep-awake releases regardless of intent.
    // NOT user-configurable, and tested before the low band (see keepAwakeSuspension): the README's
    // "below 5% the Mac sleeps regardless" guarantee has to stay literally true whatever the user
    // sets the release threshold to.
    static let batteryCriticalThreshold: Double = 0.05

    // Bounds on the user-configurable release threshold (keepAwakeBatteryThreshold). The minimum sits
    // strictly ABOVE batteryCriticalThreshold — that gap is what keeps the 5% floor unreachable from
    // any user surface, so the guarantee above holds no matter what is configured.
    //
    // ZERO IS A THIRD, VALID VALUE meaning "off": never release on charge alone. It is deliberately
    // outside [min, max] rather than being min-1%: a user who wants a 6% release point wants the
    // policy relocated, while a user who wants it gone wants it gone, and collapsing the two would
    // make "off" un-expressible. The 5% floor still applies to it — off disables the *low* band only.
    static let batteryThresholdOff: Double = 0.0
    static let batteryThresholdMin: Double = 0.06
    static let batteryThresholdMax: Double = 1.0

    // Clamp, never reject — every entry point (CLI, env, state file) funnels through this. A baked
    // login-item arg or a hand-edited state file must not cost the user the whole app over one bad
    // number, the same rule KeepAwakeDuration.parse documents. Anything at or below zero collapses to
    // off (the caller decides whether that shape was even spellable; this is the last line, not the
    // parser), anything above is pulled into the valid band.
    // The menu's ladder of release points, as charge fractions. A short span either side of the 20%
    // default — the menu exists for the common relocation, and anything else is one row further into
    // Custom…, which is cheaper than a row per percent. Kept ≥5% apart so no two rows can both match a
    // configured value (see refreshBatteryThresholdSelectionState's tolerance).
    static let batteryThresholdRows: [Double] = [0.10, 0.15, 0.20, 0.30]

    static func clampedBatteryThreshold(_ value: Double) -> Double {
        guard value.isFinite else { return batteryLowThresholdDefault }
        if value <= 0 { return batteryThresholdOff }
        return min(max(value, batteryThresholdMin), batteryThresholdMax)
    }

    // ── Other sleep assertions (SleepAssertionMonitor) ────────────────────────────────────────────
    // What the "Other Assertions" section under Keep Awake ▸ will show. The rows name owner + type and
    // nothing more: an assertion is NOT an effect (PreventUserIdleSystemSleep alone does not hold the
    // display, and the system follows the display down — which is why this app spawns `caffeinate -di`),
    // so "your Mac can't sleep" can be false while the list is accurate.
    //
    // BOTH FILTERS BELOW ARE A HEURISTIC, even though every line they let through is a fact. Unfiltered,
    // the list is mostly structure: WindowServer tickles UserIsActive on every keystroke and powerd holds
    // one whenever the display is on.
    //
    // (1) Type allowlist — the types whose NAME is about preventing sleep. Resolve AssertionTrueType
    // first (it resolves the deprecated aliases), fall back to AssertType. The last two are those
    // aliases, kept defensively. String literals, not the kIOPMAssertionType* constants: those are
    // `#define … CFSTR("…")` macros in IOPMLib.h and CFSTR macros aren't imported into Swift. No loss —
    // these ARE the wire format, and the raw string is what `pmset -g assertions` prints, so a user
    // cross-checking the app sees the same vocabulary.
    static let assertionSleepTypes: Set<String> = [
        "PreventUserIdleSystemSleep",
        "PreventUserIdleDisplaySleep",
        "PreventSystemSleep",
        "NoIdleSleepAssertion",
        "NoDisplaySleepAssertion",
    ]

    // (2) Owner denylist — deliberately TWO NAMED EXCEPTIONS, not a policy. An assertion is dropped only
    // when it is a structural consequence of the machine being in use: powerd's is literally named
    // "Prevent sleep while display is on", so it is present whenever anyone could be reading this menu
    // and carries zero information. Resist growing this into an is-a-daemon heuristic (e.g. "name ends in
    // d") — it gets the interesting cases wrong both ways: `backupd` (Time Machine) and `sharingd`
    // (Handoff) are exactly what someone asking "why won't it sleep" wants to see, while caffeinate,
    // Music and zoom.us don't end in `d` anyway. The type allowlist does the real work.
    static let assertionNoiseOwners: Set<String> = ["powerd", "WindowServer"]

    // (3) Of the allowed types, the ones that hold the DISPLAY awake — the rest hold idle/system sleep.
    // This split is what makes an *effect* inference possible at all, and it is the same fact that makes
    // this app spawn `caffeinate -di` rather than `-i`: on modern macOS an idle-only assertion is
    // unreliable, because once the display sleeps the system follows it down. So a holder with only an
    // idle-type assertion is NOT evidence the Mac will stay awake, and the machine-state row says so
    // instead of claiming a hold it can't support.
    static let assertionDisplaySleepTypes: Set<String> = [
        "PreventUserIdleDisplaySleep",
        "NoDisplaySleepAssertion",
    ]

    // Hysteresis. A renewal loop (`caffeinate -i -t 300` on repeat) GAPS between assertions, so a bare
    // per-tick read flickers the row in and out. Keep a holder listed this long after it stops appearing
    // — four 2s ticks, comfortably over a respawn gap and short enough that a finished job clears while
    // the user is still looking.
    static let assertionRetentionSeconds: Double = 8.0

    // Rows before the "…and N more" overflow line. The section is inline in a submenu that is already
    // ~17 rows, and the filtered list is 0–2 entries in practice; the overflow row exists so a cap is
    // never silent.
    static let assertionRowCap: Int = 4

    // Battery trace-chart color bands (charge fraction). The chart is a fuel gauge for the battery
    // source — low = alert — so ≤20% → red plus this mid band (≤40% → yellow, else green), mirroring
    // the macOS low-battery convention.
    //
    // CHART ONLY, and fixed. It is not the sleep threshold: the red band means "macOS considers this
    // low", which is a constant of the platform, while the release point is a user preference. Wiring
    // the chart to the sleep setting would make picking a 10% release repaint the gauge and quietly
    // redefine what red means.
    static let batteryChartLowThreshold: Double = 0.20
    static let batteryChargeMediumThreshold: Double = 0.40

    // Keep-awake track line tints — a warm/cool pairing (design POC). Each option carries two tones
    // so the 2pt line holds contrast on both menu-bar appearances: lighter on a dark bar, deeper on a
    // light one (the bestMatch lives in KeepAwakeColor.color(for:)). "Dusty Teal" is the default —
    // being chromatic it reads on grayscale preset art by hue rather than lightness, so it stays
    // legible even on full-height art where the near-neutral companions can fade. The set is
    // user-selectable via the Keep Awake submenu. Beyond Teal/Sand, three "post-AI minimal" tints:
    // Graphite (near-neutral cool gray), Mauve (desaturated lavender), Sage (grey-green with an olive
    // lean) — all heavily desaturated, same two-tone (lighter on dark bar, deeper on light) formula.
    static let keepAwakeBarTealDark = NSColor(srgbRed: 0.51, green: 0.70, blue: 0.69, alpha: 1)  // #82B3AF
    static let keepAwakeBarTealLight = NSColor(srgbRed: 0.33, green: 0.50, blue: 0.49, alpha: 1) // #557F7C
    static let keepAwakeBarSandDark = NSColor(srgbRed: 0.847, green: 0.765, blue: 0.608, alpha: 1) // #D8C39B
    static let keepAwakeBarSandLight = NSColor(srgbRed: 0.698, green: 0.604, blue: 0.431, alpha: 1) // #B29A6E
    static let keepAwakeBarGraphiteDark = NSColor(srgbRed: 0.659, green: 0.682, blue: 0.710, alpha: 1) // #A8AEB5
    static let keepAwakeBarGraphiteLight = NSColor(srgbRed: 0.420, green: 0.443, blue: 0.478, alpha: 1) // #6B717A
    static let keepAwakeBarMauveDark = NSColor(srgbRed: 0.702, green: 0.651, blue: 0.769, alpha: 1) // #B3A6C4
    static let keepAwakeBarMauveLight = NSColor(srgbRed: 0.494, green: 0.443, blue: 0.569, alpha: 1) // #7E7191
    static let keepAwakeBarSageDark = NSColor(srgbRed: 0.576, green: 0.710, blue: 0.514, alpha: 1) // #93B583
    static let keepAwakeBarSageLight = NSColor(srgbRed: 0.392, green: 0.522, blue: 0.353, alpha: 1) // #64855A
    static let keepAwakeBarThickness: CGFloat = 2

    // Opacity of the track line (and the label's tint) when the Mac is held awake by SOMEONE ELSE —
    // a bare `caffeinate`, another utility, another user's session. Deliberately not the same solid line
    // as our own hold: the glance has to answer "held awake?" AND "mine to turn off?", because Off can
    // only release ours. Same-looking tints would push AwakeHold's invariant 1 into the visual layer,
    // where it would be a lie the user can't see. Faint enough to read as secondary, opaque enough that
    // it isn't mistaken for nothing.
    static let keepAwakeBarForeignAlpha: CGFloat = 0.45

    // Keep Awake timed release. The preset windows offered in the Keep Awake submenu (seconds), plus
    // the bounds for a custom "__ hr __ min" entry. Biased toward multi-hour unattended runs — the
    // window exists so a Mac left working overnight sleeps on its own once the time budget is up.
    // `caffeinate -t` performs the release; nothing here polls for expiry.
    static let keepAwakeDurations: [TimeInterval] = [30 * 60, 60 * 60, 2 * 60 * 60, 4 * 60 * 60, 8 * 60 * 60]
    static let keepAwakeMaxHours = 24
    static let keepAwakeMaxMinutes = 59

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
    static let keepAwakeOff = "Off"
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

    // Parent row for menu-driven preferences (the menu-bar label and the battery release threshold).
    static let settings = "Settings"

    // Keep Awake's battery release threshold (under Settings ▸). The "never release on charge" value is
    // spelled **Never** here and `off` on the CLI, deliberately: the Keep Awake submenu already has an
    // Off row that means something else entirely (disarm keep-awake), and a second Off two rows away
    // meaning "disarm the *threshold*" is the kind of collision a user reads wrong once and distrusts
    // after. The parser accepts `never` too, so neither surface is lying about the other.
    static let batteryThresholdPrefix = "Battery Threshold"
    static func batteryThreshold(_ suffix: String) -> String { "\(batteryThresholdPrefix): \(suffix)" }
    static let batteryThresholdNever = "Never"
    static let batteryThresholdCustom = "Custom…"
    // Shared by the rows and the parent row's readout, so a row and the title it selects always agree.
    static func batteryThresholdValue(_ fraction: Double) -> String {
        fraction <= Tuning.batteryThresholdOff
            ? batteryThresholdNever
            : "\(Int((fraction * Tuning.percentScale).rounded()))%"
    }

    // Menu-bar label (the adjacent value/text slot).
    static let labelPrefix = "Menu Bar Label"
    static func label(_ suffix: String) -> String { "\(labelPrefix): \(suffix)" }
    static let labelOff = "off"
    static let labelOffItem = "Off"
    static let labelValueItem = "Live Value"
    static func labelCustomItem(max: Int) -> String { "Custom Text… (max \(max))" }
    static let labelPositionHeader = "Position"

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

    // Keep Awake timed release. `keepAwake` above is the submenu's own title; these are the duration
    // group's rows and the two places the remaining time is rendered (the parent row, so the window is
    // visible without opening the submenu, and the countdown readout inside it).
    static let keepAwakeDurationHeader = "Duration"
    static let keepAwakeIndefinite = "Until turned off"
    static let keepAwakeCustomDuration = "Custom…"
    static func keepAwakeRemaining(_ remaining: String) -> String { "\(keepAwake): \(remaining)" }
    // Both halves of the answer: time left, and the wall-clock moment it ends.
    static func keepAwakeRemainingRow(_ remaining: String, until: String) -> String {
        "\(remaining) left (until \(until))"
    }

    // Paused = the user's intent is on but a condition has caffeinate killed, so the Mac CAN sleep.
    // Said on the parent row (visible without opening the submenu) because the alternative — a ticked
    // color row and an absent 2pt track line — is not a signal anyone reads. The status row then says
    // which condition and, for battery, at what charge, so "why" needs no guessing.
    static let keepAwakePausedSuffix = "(paused)"
    static let keepAwakePausedBare = "\(keepAwake): paused"
    static func keepAwakePausedWithWindow(_ remaining: String) -> String {
        "\(keepAwake): \(remaining) \(keepAwakePausedSuffix)"
    }
    static func keepAwakePausedRow(_ reason: String) -> String { "paused — \(reason)" }

    // "Other Assertions" — the read-only section listing OTHER processes' sleep assertions. The row is
    // owner + raw assertion type and nothing else. Rendering the type verbatim rather than glossing it
    // ("prevents idle sleep") is the whole discipline of the section: the gloss is an effect claim this
    // data can't support, and the raw string is what `pmset -g assertions` prints, so a user checking the
    // app against the system reads the same vocabulary. `none` is a ROW, not an empty section — it is the
    // answer to the question someone opened this menu with.
    static let otherAssertions = "Other Assertions"
    static let otherAssertionsNone = "none"
    // One row per owner, listing every type it holds: `caffeinate — PreventUserIdleDisplaySleep,
    // PreventUserIdleSystemSleep ×2`. The ×N rides the TYPE, not the owner, so no information is lost
    // relative to the per-type rows this replaced — "which types, and how many of each" still reads off
    // the row exactly.
    static func otherAssertionRow(owner: String, types: [(type: String, count: Int)]) -> String {
        let parts = types.map { $0.count > 1 ? "\($0.type) ×\($0.count)" : $0.type }
        return "\(owner) — \(parts.joined(separator: ", "))"
    }
    static func otherAssertionsMore(_ count: Int) -> String { "…and \(count) more" }

    // The machine-state row: whether THIS MAC is being held awake right now, by anyone. The distinction
    // from every other keep-awake surface is that those report our own *intent* and this reports the
    // machine, so it is the one row that answers a `caffeinate` typed in a terminal.
    //
    // Two rules of wording, both load-bearing:
    //   - ALWAYS attributed ("this app" / the owner's name). Whether the thing you're looking at is
    //     yours to turn off is the next question after "is it held", and the Off row above can only
    //     release ours. An unattributed "held awake" would read as a promise this menu can't keep.
    //   - never a claim beyond the data. `pmset` policy, clamshell, the 5% floor and a user-initiated
    //     sleep are all invisible here, so the row says what is HOLDING sleep, never that the Mac
    //     will not sleep.
    static let machineAwakeNone = "Nothing holding sleep"
    static let machineAwakeSelf = "this app"
    // Idle held but the display is NOT: the honest answer is "may still sleep" — see
    // Tuning.assertionDisplaySleepTypes for why an idle-only hold doesn't survive the display going down.
    static let machineAwakePartial = "Idle sleep held, display is not — the Mac may still sleep"
    static func machineAwakeRow(_ detail: String) -> String { "Mac held awake — \(detail)" }
    static func machineAwakeOthers(_ count: Int) -> String {
        count == 1 ? "and 1 other" : "and \(count) others"
    }
    static func batteryLowReason(_ percent: Double) -> String {
        String(format: "battery low (%.0f%%)", percent)
    }
    static func batteryCriticalReason(_ percent: Double) -> String {
        String(format: "battery critical (%.0f%%)", percent)
    }
    static let thermalReason = "Mac is too warm"
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

    // Persisted form: a mode keyword plus the `.custom` payload as a SEPARATE field, mirroring how
    // PersistedState.KeepAwake splits `enabled` from `deadline`. Splitting them keeps the mode a small
    // closed set, so a hand-edited file with a typo'd mode degrades to "nothing saved" instead of
    // silently becoming a literal custom label reading "vaule".
    var persistedMode: String {
        switch self {
        case .off: return "off"
        case .value: return "value"
        case .custom: return "custom"
        }
    }

    var persistedCustomText: String? {
        if case .custom(let text) = self { return text }
        return nil
    }

    // The `--label` value that reproduces this mode, for the restart re-exec. Round-trips through
    // `parse` for every mode; a custom label reading literally "off" or "value" collapses to that
    // mode, which is the same thing typing it on the command line has always done.
    var launchArgument: String {
        switch self {
        case .off: return "off"
        case .value: return "value"
        case .custom(let text): return text
        }
    }

    // nil means "nothing usable saved" — an absent block, an unrecognized mode, or `custom` with no
    // text. Deliberately not `.off` for those: a corrupt entry should fall through to the launch
    // default, not pin the label off in a way the user never chose.
    static func fromPersisted(mode: String?, customText: String?) -> MenuBarLabel? {
        switch mode {
        case "off": return .off
        case "value": return .value
        case "custom":
            guard let text = customText?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else { return nil }
            return .custom(String(text.prefix(Tuning.labelMaxChars)))
        default: return nil
        }
    }
}

// Which side of the animation the label slot sits on. A registry like KeepAwakeColor — the menu rows,
// the radio-selection check, and the persisted keyword all derive from these cases, so adding one needs
// no menu edit. Menu-only and persisted, also like the tint: it is cosmetic, so it doesn't earn a CLI
// flag (a new flag is public API forever), and the restart-after-update path picks it up off disk.
//
// Why the side is a choice at all: it changes which neighbour absorbs the label's presence. Left (the
// default) keeps the animation pinned where it has always been, with the label growing away from it into
// the row of app icons; right puts the reading next to the system icons — nearer the clock, where the
// eye already goes for status — at the cost of shifting the creature by the width of the slot. Neither
// jitters, because the slot's width is reserved rather than auto-sized (see labelSlotWidth).
private enum MenuBarLabelSide: String, CaseIterable {
    case left
    case right

    var menuTitle: String {
        switch self {
        case .left: return "Left of Icon"
        case .right: return "Right of Icon"
        }
    }

    // nil means "nothing usable saved" (absent or unrecognized), so the caller falls through to the
    // launch default rather than pinning a side the user never chose — same rule as MenuBarLabel.
    static func fromPersisted(_ raw: String?) -> MenuBarLabelSide? {
        guard let raw else { return nil }
        return MenuBarLabelSide(rawValue: raw)
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
    case graphite = 2
    case mauve = 3
    case sage = 4

    var menuTitle: String {
        switch self {
        case .teal: return "Dusty Teal"
        case .sand: return "Sand"
        case .graphite: return "Graphite"
        case .mauve: return "Mauve"
        case .sage: return "Sage"
        }
    }

    // Lighter tone on a dark menu bar, deeper on a light one — the same bestMatch the rest of the app
    // uses for appearance-aware drawing, so the choice keeps its identity across theme switches.
    func color(for appearance: NSAppearance?) -> NSColor {
        let dark = appearance?.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        switch self {
        case .teal: return dark ? Tuning.keepAwakeBarTealDark : Tuning.keepAwakeBarTealLight
        case .sand: return dark ? Tuning.keepAwakeBarSandDark : Tuning.keepAwakeBarSandLight
        case .graphite: return dark ? Tuning.keepAwakeBarGraphiteDark : Tuning.keepAwakeBarGraphiteLight
        case .mauve: return dark ? Tuning.keepAwakeBarMauveDark : Tuning.keepAwakeBarMauveLight
        case .sage: return dark ? Tuning.keepAwakeBarSageDark : Tuning.keepAwakeBarSageLight
        }
    }
}

// A Keep Awake window: indefinite (the default — runs until turned off or the app quits) or a fixed
// length, after which `caffeinate -t` exits by itself and the Mac is free to sleep again. A registry
// like KeepAwakeColor, so the menu rows, the radio-selection check, the arming path, and the
// `--keep-awake` parser share one source of truth. Armable from the menu or at launch (CLI/env or a
// window restored from disk — see StateStore).
private enum KeepAwakeDuration: Equatable {
    case indefinite
    case seconds(TimeInterval)

    // The rows offered in the submenu's duration group, in display order.
    static var presetRows: [KeepAwakeDuration] {
        [.indefinite] + Tuning.keepAwakeDurations.map { .seconds($0) }
    }

    // nil for indefinite — the same nil that means "no `-t`" at the spawn site.
    var seconds: TimeInterval? {
        switch self {
        case .indefinite: return nil
        case .seconds(let value): return value
        }
    }

    var menuTitle: String {
        guard let seconds else { return MenuTitle.keepAwakeIndefinite }
        return Self.format(seconds, style: .full) ?? MenuTitle.keepAwakeIndefinite
    }

    // Localized row titles ("30 minutes", "2 hours"). Formatters are built per call rather than cached
    // in a static: DateComponentsFormatter isn't Sendable, and this runs a handful of times per refresh.
    static func format(_ seconds: TimeInterval, style: DateComponentsFormatter.UnitsStyle) -> String? {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = style
        formatter.allowedUnits = [.hour, .minute]
        formatter.zeroFormattingBehavior = .dropAll
        return formatter.string(from: seconds)
    }

    // Countdown rendering: positional, second-resolution, zero-padded — "29:58", "1:29:58". This is a
    // live count-down, so it has to visibly tick; a duration rounded to the minute reads as the length
    // the user picked rather than the time left (and looks frozen for a minute at a stretch). Seconds
    // round UP so the last partial second still shows a value instead of 00:00.
    static func countdown(_ remaining: TimeInterval) -> String? {
        let seconds = max(remaining.rounded(.up), 0)
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .positional
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute, .second] : [.minute, .second]
        formatter.zeroFormattingBehavior = .pad
        return formatter.string(from: seconds)
    }

    // Wall-clock time the window ends, in the user's locale/12-24h preference ("7:44 PM"). The
    // countdown answers "how long left"; this answers "until when" — the form that matters when you're
    // deciding whether the window covers the job before going to bed.
    static func clockTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    // `--keep-awake <value>` / MENUBAR_LOAD_RUNNER_KEEP_AWAKE. Accepts "on"/"indefinite" (no window)
    // or unit-suffixed durations, combinable: "30m", "2h", "1h30m", "90s". nil = unparseable, which the
    // caller turns into a warning + off rather than a launch failure.
    //
    // A UNIT IS REQUIRED — a bare "2" is rejected rather than guessed at. Minutes and hours are both
    // plausible readings of a bare number, and picking wrong is a 60× error in how long the Mac stays
    // awake; a warning the user can see beats a window they didn't ask for. Clamped to
    // Tuning.keepAwakeMaxHours, matching the custom-duration prompt (clamp, don't reject) — this value
    // can be baked into a login item, where a hard failure would cost the user the whole app.
    static func parse(_ raw: String) -> KeepAwakeDuration? {
        let lowered = raw.lowercased().trimmingCharacters(in: .whitespaces)
        if ["on", "yes", "true", "indefinite"].contains(lowered) { return .indefinite }

        var total: TimeInterval = 0
        var digits = ""
        var sawUnit = false
        for character in lowered {
            if character.isNumber {
                digits.append(character)
                continue
            }
            // A unit with no number in front of it ("h", "30mh") is malformed, not zero.
            guard let value = Double(digits) else { return nil }
            switch character {
            case "h": total += value * 3600
            case "m": total += value * 60
            case "s": total += value
            default: return nil
            }
            digits = ""
            sawUnit = true
        }
        // Trailing digits mean a missing unit ("1h30"), which is the ambiguity above in disguise.
        guard sawUnit, digits.isEmpty, total > 0 else { return nil }
        return .seconds(min(total, TimeInterval(Tuning.keepAwakeMaxHours) * 3600))
    }
}

// What `--keep-awake` asked for. Absent (nil) is distinct from `.off`: nil means the flag wasn't
// given, so a window persisted from the last run may be restored; `.off` is the user explicitly
// saying "launch with keep-awake disabled", which suppresses that restore.
private enum KeepAwakeLaunchOption {
    case off
    case window(KeepAwakeDuration)
}

// Why keep-awake is suspended right now, or nil to run. This replaced a plain `Bool`, because the
// reason has to be *shown* (a suspended keep-awake used to be silent — the tint stayed ticked, only
// the 2pt track line vanished) and because the reasons are no longer interchangeable: `.batteryLow`
// is the one an explicit user gesture may override, while `.batteryCritical` and `.thermal` always
// win. `.batteryCritical` is the floor under that override; `.thermal` isn't overridable at all,
// since overheating is genuinely transient and holding the Mac awake through it is a hardware risk,
// not a preference.
private enum KeepAwakeSuspension: Equatable {
    case batteryLow(percent: Double)
    case batteryCritical(percent: Double)
    case thermal

    // Whether an explicit arm-anyway gesture is allowed to ignore this.
    var isOverridable: Bool {
        if case .batteryLow = self { return true }
        return false
    }

    var reasonText: String {
        switch self {
        case .batteryLow(let percent): return MenuTitle.batteryLowReason(percent)
        case .batteryCritical(let percent): return MenuTitle.batteryCriticalReason(percent)
        case .thermal: return MenuTitle.thermalReason
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
    // nil = neither flag nor env given, which is distinct from `.off`: absent lets the mode saved by
    // the previous run be restored, while an explicit `off` suppresses it. Same distinction, and the
    // same reason, as KeepAwakeLaunchOption's nil-vs-.off.
    let label: MenuBarLabel?
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
    // Keep Awake at launch, from --keep-awake / MENUBAR_LOAD_RUNNER_KEEP_AWAKE. nil = not requested
    // (the persisted window, if any, is restored instead). This is LAUNCH-time arming only: the
    // launcher's singleton refuses a second invocation, so it can't arm an instance that's already
    // running — that would need IPC, which a bundle-less binary doesn't have.
    let keepAwake: KeepAwakeLaunchOption?
    // Keep Awake's battery release point, from --battery-threshold /
    // MENUBAR_LOAD_RUNNER_BATTERY_THRESHOLD, as a charge FRACTION (0.20), already clamped. nil = neither
    // flag nor env given, which is distinct from `0`: absent lets the saved setting stand, while `0` is
    // an explicit "never release on charge alone". Three states, not two — the asymmetry with `label`
    // is that here "off" is a value rather than a mode.
    let batteryThreshold: Double?

    // `--battery-threshold <pct|off>` / MENUBAR_LOAD_RUNNER_BATTERY_THRESHOLD → a charge fraction, or
    // nil if the text is not a form we accept (the caller warns and falls back).
    //
    // WHOLE PERCENTS ONLY: `20` and `20%` mean 20%, while `0.20` is refused rather than guessed at.
    // A bare `0.2` reads as 0.2% under one convention and 20% under the other, and picking wrong moves
    // the release point by two orders of magnitude — the same ambiguity KeepAwakeDuration.parse refuses
    // for a bare number. A trailing `%` is accepted because it *removes* that ambiguity rather than
    // adding to it. `0` is the numeric spelling of off, which is unambiguous for the same reason.
    static func parseBatteryThreshold(_ raw: String) -> Double? {
        var text = raw.lowercased().trimmingCharacters(in: .whitespaces)
        if ["off", "never", "none", "no"].contains(text) { return Tuning.batteryThresholdOff }
        if text.hasSuffix("%") { text.removeLast() }
        text = text.trimmingCharacters(in: .whitespaces)
        // ASCII digits only: this rejects "0.20" (the decimal form) via the ".", and "-5"/"1e2"/"½"
        // for free. Anything that survives is a whole percent.
        guard !text.isEmpty, text.allSatisfy({ $0.isASCII && $0.isNumber }), let percent = Double(text)
        else { return nil }
        // Returned UNCLAMPED: the caller clamps (never rejects — this can be baked into a login item)
        // and needs the requested value to say what the clamp did.
        return percent / Tuning.percentScale
    }

    // How a threshold reads back to a human, in whichever direction: "off" or "20%". Shared by the
    // stderr warnings here so the value we report is spelled the way the flag accepts it.
    static func batteryThresholdDescription(_ fraction: Double) -> String {
        fraction <= Tuning.batteryThresholdOff
            ? "off" : "\(Int((fraction * Tuning.percentScale).rounded()))%"
    }

    static func parse() -> ParseResult? {
        let args = CommandLine.arguments.dropFirst()
        var presetOrPath: String?
        var speedMultiplierOverride: Double?
        var labelArg: String?
        var loadSourceArg: String?
        var keepAwakeArg: String?
        var batteryThresholdArg: String?
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
            case "--keep-awake":
                guard let value = iterator.next() else {
                    fputs("Invalid value for --keep-awake. Expected off, on, or a duration with a unit (e.g. 30m, 2h, 1h30m).\n", stderr)
                    printUsage()
                    return nil
                }
                keepAwakeArg = value
            case "--battery-threshold":
                guard let value = iterator.next() else {
                    fputs("Invalid value for --battery-threshold. Expected a whole percent (e.g. 20) or off.\n", stderr)
                    printUsage()
                    return nil
                }
                batteryThresholdArg = value
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
        // An empty env value counts as absent (matching how the positional and --load-source treat
        // empty), so `MENUBAR_LOAD_RUNNER_LABEL=` doesn't read as an explicit off and clobber a saved
        // mode. Only a non-empty flag/env produces a non-nil launch request.
        let label = (labelArg?.isEmpty == false) ? MenuBarLabel.parse(labelArg) : nil
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

        if keepAwakeArg == nil {
            keepAwakeArg = ProcessInfo.processInfo.environment["MENUBAR_LOAD_RUNNER_KEEP_AWAKE"]
        }
        // An unparseable value degrades to an explicit off with a warning, the way --load-source
        // degrades to cpu: this can be baked into a LaunchAgent, and a bad value must never cost the
        // user their menu-bar app. It still counts as "the flag was given", so it also suppresses the
        // persisted-window restore — a user driving Keep Awake from the CLI stays in charge of it.
        var keepAwake: KeepAwakeLaunchOption?
        if let raw = keepAwakeArg?.trimmingCharacters(in: .whitespaces), !raw.isEmpty {
            if ["off", "no", "false", "0"].contains(raw.lowercased()) {
                keepAwake = .off
            } else if let parsed = KeepAwakeDuration.parse(raw) {
                keepAwake = .window(parsed)
            } else {
                fputs("Unrecognized --keep-awake \"\(raw)\"; launching with keep-awake off. Expected off, on, or a duration with a unit (e.g. 30m, 2h, 1h30m).\n", stderr)
                keepAwake = .off
            }
        }

        if batteryThresholdArg == nil {
            batteryThresholdArg = ProcessInfo.processInfo.environment["MENUBAR_LOAD_RUNNER_BATTERY_THRESHOLD"]
        }
        // An empty env value counts as absent, exactly as with --label: `…BATTERY_THRESHOLD=` must not
        // read as an explicit value and clobber the saved setting.
        var batteryThreshold: Double?
        if let raw = batteryThresholdArg?.trimmingCharacters(in: .whitespaces), !raw.isEmpty {
            if let requested = parseBatteryThreshold(raw) {
                let clamped = Tuning.clampedBatteryThreshold(requested)
                if abs(clamped - requested) > .ulpOfOne {
                    fputs("--battery-threshold \(raw) is out of range; using \(Self.batteryThresholdDescription(clamped)). Valid: off, or \(Int(Tuning.batteryThresholdMin * Tuning.percentScale))–\(Int(Tuning.batteryThresholdMax * Tuning.percentScale)) percent (the \(Int(Tuning.batteryCriticalThreshold * Tuning.percentScale))% floor is not configurable).\n", stderr)
                }
                batteryThreshold = clamped
            } else {
                // Unparseable degrades to the DEFAULT, not to absent and not to off: a garbage value
                // baked into a LaunchAgent must never silently disable the release policy, and it still
                // counts as "the flag was given" (like --keep-awake), so it also wins over the saved
                // setting rather than half-applying.
                fputs("Unrecognized --battery-threshold \"\(raw)\"; using the default \(Self.batteryThresholdDescription(Tuning.batteryLowThresholdDefault)). Expected a whole percent (e.g. 20 or 20%) or off — a decimal fraction like 0.20 is ambiguous and not accepted.\n", stderr)
                batteryThreshold = Tuning.batteryLowThresholdDefault
            }
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
                showAllSources: showAllSources,
                keepAwake: keepAwake,
                batteryThreshold: batteryThreshold
            )
        )
    }

    static func printUsage() {
        let envBin = ProcessInfo.processInfo.environment["MENUBAR_LOAD_RUNNER_BIN_NAME"]
        let bin = (envBin?.isEmpty == false) ? envBin! : URL(fileURLWithPath: CommandLine.arguments[0]).lastPathComponent
        print("MenuBar Load Runner \(AppInfo.version)")
        print("Usage: \(bin) <preset-name|path-to-gif> [--speed-multiplier <x>] [--label <off|value|text>] [--load-source <\(LoadSource.allCases.map(\.key).joined(separator: "|"))>] [--keep-awake <off|on|duration>] [--battery-threshold <pct|off>] [--show-all-sources] [--no-update-check]")
        print("   or: MENUBAR_LOAD_RUNNER_PATH=<path-to-gif> \(bin) [--speed-multiplier <x>] [--label <off|value|text>] [--load-source <\(LoadSource.allCases.map(\.key).joined(separator: "|"))>] [--keep-awake <off|on|duration>] [--battery-threshold <pct|off>] [--show-all-sources] [--no-update-check]")
        print("Load source: which reader drives animation speed (default cpu). Also via MENUBAR_LOAD_RUNNER_LOAD_SOURCE; unknown values fall back to cpu.")
        print("Label: an optional second menu-bar slot. --label value shows the active source's live reading; --label <text> (up to \(Tuning.labelMaxChars) chars) shows a fixed label; --label off (default) shows nothing. Also via MENUBAR_LOAD_RUNNER_LABEL; switchable from the menu.")
        print("Show all sources: --show-all-sources (or MENUBAR_LOAD_RUNNER_SHOW_ALL=1) starts with the menu's \"Other Sources\" list expanded, sampling every available reader and showing each as a live row; click a row to switch the driving source. Collapsed by default (active source only). Toggle from the menu's disclosure header.")
        print("Keep awake: --keep-awake <off|on|30m|2h|1h30m> arms sleep prevention at launch (a unit is required; up to \(Tuning.keepAwakeMaxHours)h). Also via MENUBAR_LOAD_RUNNER_KEEP_AWAKE. Off by default; switchable from the menu. An armed window is saved and resumed on the next launch — passing this flag (even as off) overrides what was saved.")
        print("Battery threshold: --battery-threshold <pct|off> sets the charge at or below which Keep Awake releases on battery (default \(Int(Tuning.batteryLowThresholdDefault * Tuning.percentScale))%; off never releases on charge alone). Whole percents only — 20 or 20%, not 0.20. Also via MENUBAR_LOAD_RUNNER_BATTERY_THRESHOLD. Out-of-range values are clamped to \(Int(Tuning.batteryThresholdMin * Tuning.percentScale))–\(Int(Tuning.batteryThresholdMax * Tuning.percentScale))%, and below \(Int(Tuning.batteryCriticalThreshold * Tuning.percentScale))% on battery the Mac sleeps regardless — that floor is not configurable.")
        print("Width: the menu-bar item sizes itself to the GIF's aspect ratio at menu-bar height — not configurable.")
        print("Default speed: auto (preset-dependent; per-preset ranges defined in gifs/presets.json).")
        print("Updates: on launch, checks the git origin's release tags for a newer version (network access). Apply is a menu click; disable with --no-update-check or MENUBAR_LOAD_RUNNER_UPDATE_CHECK=0.")
    }
}

// What survives a relaunch. Every field is Optional so a file written by an older or newer build
// degrades to "not saved" instead of failing to decode — a state file must never be able to break
// startup. `version` is informational for now (a hand-inspectable marker of the shape); the optionals
// are what actually does the compatibility work.
private struct PersistedState: Codable {
    struct KeepAwake: Codable {
        // KeepAwakeColor.rawValue. Purely cosmetic, so it is restored unconditionally.
        var tint: Int?
        // The instant the armed window ENDS — absolute, not a length. Storing "4 hours" and re-arming
        // four fresh hours on the next launch would silently extend every window across a reboot;
        // storing the end instant means what comes back is the window the user actually asked for,
        // already shortened by the time the app was down (and already expired if it elapsed).
        // nil when Keep Awake is indefinite.
        var deadline: Date?
        // The user's INTENT (SleepPreventer.isEnabled), never the transient running state: a
        // battery/thermal condition-suspend kills caffeinate while intent stands, and persisting
        // "not running" there would resurrect that distinction wrongly on the next launch.
        var enabled: Bool?
    }
    // Menu-driven preferences that should outlive a relaunch — the ones that are neither Keep Awake
    // intent nor transient runtime state. Kept as its own block (rather than more fields on the root)
    // so the file reads as two independent concerns, and so a future reader can tell a settings write
    // from a keep-awake write at a glance.
    struct Settings: Codable {
        // MenuBarLabel.persistedMode, with the `.custom` payload in the sibling field.
        var labelMode: String?
        var labelCustomText: String?
        // MenuBarLabelSide.rawValue — which side of the animation the label slot sits on. Cosmetic and
        // menu-only (no flag can override it), so it restores unconditionally, like the Keep Awake tint.
        var labelSide: String?
        // The Keep Awake battery release point, as a charge FRACTION (0.20 = 20%) — the same unit the
        // live property holds, not the whole percent the CLI takes, so the value round-trips exactly
        // and every reader stays in one unit. `0` is a real value (never release on charge alone) and
        // is distinct from absent; anything out of band is pulled in by Tuning.clampedBatteryThreshold
        // on the way back in, since a state file is one more untrusted entry point.
        var batteryThreshold: Double?
    }
    var version: Int
    var keepAwake: KeepAwake?
    var settings: Settings?
}

// A hand-rolled state file in Application Support. Deliberately NOT UserDefaults: this binary has no
// bundle id, so it has no reliable defaults domain — but a plist/JSON we open by path needs no bundle
// at all, which is why persistence was reachable here all along.
//
// Fail-silent in both directions, matching the update probe: an unreadable, corrupt, or unwritable
// file means "no saved state, carry on with defaults" — never a startup error, never a modal, never a
// reason the app doesn't launch. This is a convenience, unlike gifs/presets.json (app identity), whose
// failure IS fatal.
private enum StateStore {
    static let currentVersion = 1
    private static let directoryName = "menubar-load-runner"
    private static let fileName = "state.json"

    // Test scaffolding, like MENUBAR_LOAD_RUNNER_EXIT_AFTER: point the state file somewhere under
    // tmp/ so a smoke test never touches the real Application Support directory.
    static var fileURL: URL? {
        if let override = ProcessInfo.processInfo.environment["MENUBAR_LOAD_RUNNER_STATE_FILE"],
           !override.isEmpty {
            return URL(fileURLWithPath: NSString(string: override).expandingTildeInPath)
        }
        guard let base = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ) else { return nil }
        return base.appendingPathComponent(directoryName, isDirectory: true)
                   .appendingPathComponent(fileName)
    }

    static func load() -> PersistedState? {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(PersistedState.self, from: data)
    }

    static func save(_ state: PersistedState) {
        guard let url = fileURL else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601      // human-readable, so a wedged value is fixable in an editor
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(state) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        // Atomic: a crash mid-write leaves the previous file, not a truncated one that fails to decode.
        try? data.write(to: url, options: .atomic)
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
// per-machine, so it maps through as a percentage (average across fans of actual/max) — NOT via
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
// Reuses the same unprivileged IOPSCopyPowerSourcesInfo plumbing as evaluateBatteryState. `nil` (never a
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
        // fraction, matching how evaluateBatteryState reads kIOPSCurrentCapacityKey as 0–100.
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

// The READ side of sleep, paired with SleepPreventer below (the write side): which OTHER processes
// currently hold a sleep assertion, and of which type. Exists because the menu used to be truthful about
// itself and silent about the machine — it read `Off` while two agent-owned `caffeinate -i -t 300`
// renewals held PreventUserIdleSystemSleep and this app's own window had expired an hour earlier.
//
// `IOPMCopyAssertionsByProcess` — IOKit pwr_mgt, public, headered, unprivileged: the same tier as every
// load reader in this file. NEVER parse `pmset -g assertions` prose.
//
// Deliberately NOT a `LoadSource`: it drives no animation and has no 0…1 fraction, so it must stay out of
// LoadSource.allCases and out of Other Sources. What it reports is an OBSERVATION, never a conclusion —
// see Tuning.assertionSleepTypes for why "something is holding your Mac awake" would be a claim this data
// cannot support.
@MainActor
private final class SleepAssertionMonitor {
    // One filtered row: an owner, and every assertion type it holds. Grouped per OWNER rather than per
    // owner+type because a single process routinely holds several — `caffeinate -di` holds two, and one
    // process burning two of `Tuning.assertionRowCap` slots is what pushed a real 5-holder reading into
    // the overflow row. Per-type counts are kept, so collapsing the rows loses nothing: the count
    // matters because the founding observation was three simultaneous caffeinates.
    struct TypeCount {
        let type: String
        let count: Int
    }
    struct Holder {
        let owner: String
        let types: [TypeCount]
        // When this owner's hold ends, if it is timed — see deadline(from:) for the parse. `nil` means
        // indefinite (or unknowable), NEVER "already over": an owner holding one timed and one untimed
        // assertion is indefinite, so nil wins over any date.
        let until: Date?
        // Does this owner hold the DISPLAY awake, or only idle/system sleep? The distinction is the whole
        // basis of the "may still sleep" reading (Tuning.assertionDisplaySleepTypes).
        let displayHeld: Bool
    }

    private(set) var holders: [Holder] = []
    // Machine-level roll-up over the filtered list. Kept here rather than computed by the caller because
    // the type→category mapping is this class's business, not the menu's.
    var displayHeld: Bool { holders.contains { $0.displayHeld } }
    var idleHeld: Bool { holders.contains { holder in holder.types.contains { !Tuning.assertionDisplaySleepTypes.contains($0.type) } } }
    // Deliberately NO machine-wide "everything releases by" roll-up. The obvious version — all holders
    // timed, take the max — measured useless on a real machine: `bluetoothd`, `runningboardd` and
    // `AddressBookSourceSync` hold untimed idle assertions routinely, so one nil made the whole roll-up
    // nil and the clock time never rendered once (found by dogfooding 2026-07-30, not by review). The
    // deadline that means something is the one belonging to the holder a row NAMES — see Holder.until.
    // How many assertions were dropped for being OURS this sample. Exists to make the exclusion
    // observable: "not listed" and "listed but there are none" print identically, so the only way to
    // assert the app skipped its own child is to have it say how many it skipped. Reported by the
    // LOG_ASSERTIONS hook as `own=N`. Not a running total — it describes the latest sample.
    private(set) var excludedOwnCount = 0

    // Grouping key is owner+type, NEVER the pid or AssertionId: a renewal loop respawns caffeinate, so a
    // pid-keyed identity churns every cycle and the retention below could never see continuity.
    private struct Key: Hashable { let owner: String; let type: String }
    // `until` rides the retention window with the count: a renewal loop's newest deadline replaces the
    // old one on every sample, and a holder retained across a gap keeps the last deadline it reported
    // rather than reverting to "indefinite" mid-blink.
    private var lastSeen: [Key: (count: Int, at: TimeInterval, until: Date?)] = [:]

    // `ignoringPIDs` drops this app's own contribution — our caffeinate is already reported by the
    // countdown row right above the section, and listing it again reads as a second, mysterious holder.
    // Another *user's* instance still shows up as `caffeinate`, which is correct.
    func sample(now: TimeInterval, ignoringPIDs: Set<pid_t>) {
        var seen: [Key: Int] = [:]
        // Split rather than a `[Key: Date?]`, whose double optional reads as a puzzle at every use site.
        var seenUntil: [Key: Date] = [:]
        var seenIndefinite: Set<Key> = []
        excludedOwnCount = 0
        for entry in Self.currentAssertions() {
            // pid_t is Int32, so int32Value already is one. -1 can never be a real pid.
            let pid: pid_t = (entry["AssertPID"] as? NSNumber)?.int32Value ?? -1
            if ignoringPIDs.contains(pid) { excludedOwnCount += 1; continue }
            // AssertionTrueType resolves the deprecated aliases; AssertType is the fallback.
            let type = (entry["AssertionTrueType"] as? String) ?? (entry["AssertType"] as? String) ?? ""
            guard Tuning.assertionSleepTypes.contains(type) else { continue }
            let owner = ((entry["Process Name"] as? String) ?? "").trimmingCharacters(in: .whitespaces)
            // An unnamed owner is not actionable — a row reading "? — PreventSystemSleep" tells nobody
            // anything, and BundlePath can't stand in for a name (caffeinate reports powerd.bundle).
            guard !owner.isEmpty, !Tuning.assertionNoiseOwners.contains(owner) else { continue }
            let key = Key(owner: owner, type: type)
            seen[key, default: 0] += 1
            // One untimed assertion makes the whole key indefinite; among timed ones the LATEST wins,
            // since the Mac stays held until the last of them releases.
            if let until = Self.deadline(from: entry) {
                seenUntil[key] = max(seenUntil[key] ?? until, until)
            } else {
                seenIndefinite.insert(key)
            }
        }

        for (key, count) in seen {
            lastSeen[key] = (count, now, seenIndefinite.contains(key) ? nil : seenUntil[key])
        }
        lastSeen = lastSeen.filter { now - $0.value.at <= Tuning.assertionRetentionSeconds }
        // Retention stays keyed on owner+type while DISPLAY groups by owner. Deliberate: the blink this
        // guards against is an owner vanishing across a renewal gap, and keying the window per owner
        // would let an individual type flicker inside a still-present owner. Grouping is a rendering
        // concern; the hysteresis is not.
        //
        // Sorted at both levels every time: dictionary order is unstable, and unsorted rows (or types
        // within a row) would reshuffle each tick.
        holders = Dictionary(grouping: lastSeen, by: { $0.key.owner })
            .map { owner, entries in
                Holder(owner: owner,
                       types: entries
                           .map { TypeCount(type: $0.key.type, count: $0.value.count) }
                           .sorted { $0.type < $1.type },
                       // nil beats a date, one level up from the per-key rule: an owner holding one timed
                       // and one untimed assertion is holding indefinitely.
                       until: entries.contains { $0.value.until == nil }
                           ? nil
                           : entries.compactMap { $0.value.until }.max(),
                       displayHeld: entries.contains {
                           Tuning.assertionDisplaySleepTypes.contains($0.key.type)
                       })
            }
            .sorted { $0.owner < $1.owner }
    }

    // When a timed assertion releases, or nil if it is untimed. `AssertTimeoutTimeLeft` is NOT live — it
    // is the remaining time as of `AssertTimeoutUpdateTime`, verified 2026-07-30: a 30-minute assertion
    // 17 minutes old still reported 1800. Reading it as "time left from now" renders a countdown that
    // never moves, which is the whole trap here. `AssertStartWhen` + `TimeoutSeconds` is the fallback,
    // and an absent `TimeoutSeconds` means indefinite — absent is not zero.
    private static func deadline(from entry: [String: Any]) -> Date? {
        if let updated = entry["AssertTimeoutUpdateTime"] as? Date,
           let left = (entry["AssertTimeoutTimeLeft"] as? NSNumber)?.doubleValue, left > 0 {
            return updated.addingTimeInterval(left)
        }
        if let started = entry["AssertStartWhen"] as? Date,
           let timeout = (entry["TimeoutSeconds"] as? NSNumber)?.doubleValue, timeout > 0 {
            return started.addingTimeInterval(timeout)
        }
        return nil
    }

    private static func currentAssertions() -> [[String: Any]] {
        var dict: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&dict) == kIOReturnSuccess,
              let byProcess = dict?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else { return [] }
        return byProcess.values.flatMap { $0 }
    }
}

// Owns the `caffeinate` child process that keeps the Mac awake while "Keep Awake" is on. The key
// design choice is separating *intent* from *running state*: `isEnabled` is the user's toggle, while
// the process may be independently suspended by conditions (battery-low, serious thermal) and
// respawned when they clear — without losing the user's intent. `applyConditions(suspend:)` is a
// total function safe to call on every condition change and on toggle: it spawns iff the user wants
// it AND no condition suspends it, otherwise it kills.
//
// `caffeinate -di -w <pid>`: `-d` prevents display sleep and `-i` prevents idle system sleep. Both are
// needed to reliably keep the Mac awake — on modern macOS (notably Apple Silicon) an `-i`-only
// assertion is unreliable: once the display sleeps the system frequently follows it down, so the Mac
// slept even though caffeinate was running. Preventing display sleep too is what actually holds it
// awake (this matches KeepingYouAwake's default). `-w <pid>` binds the child to MLR's PID so the OS
// reaps it automatically if MLR crashes or is force-quit, so there's never an orphaned sleep lock.
@MainActor
private final class SleepPreventer {
    private static let caffeinatePath = "/usr/bin/caffeinate"
    private var process: Process?
    private(set) var isEnabled = false          // the user's toggle (intent)
    var isRunning: Bool { process != nil }      // whether caffeinate is actually spawned right now
    // The child's pid, so SleepAssertionMonitor can exclude OUR assertion from the "other holders" list.
    var childPID: pid_t? { process?.processIdentifier }
    // Bumped on every spawn and kill, and captured by each child's termination handler, so a handler
    // belonging to an already-replaced/already-killed child can't clear state that a newer one owns.
    // (An Int token rather than the Process itself: Process isn't Sendable, and the handler is.)
    private var generation = 0

    // Called on the main actor when caffeinate exited on its OWN — i.e. a `-t` window elapsed, so the
    // timed release just happened. Deliberately NOT called for our own kills (see kill()).
    var onWindowExpired: (() -> Void)?

    func setEnabled(_ on: Bool) { isEnabled = on }  // caller then drives applyConditions()

    // Spawn iff the user wants it AND no condition suspends it; otherwise kill. Idempotent.
    // `remaining` is the timed window's balance (nil = indefinite, no `-t`): a respawn after a
    // condition-suspend must pass what is LEFT, not the window's original length.
    func applyConditions(suspend: Bool, remaining: TimeInterval?) {
        if isEnabled && !suspend { spawn(remaining: remaining) } else { kill() }
    }

    // Replace a running child so it picks up a new window. `spawn` is a no-op while a child exists —
    // which is what makes a tint change free — but the `-t` value is baked in at spawn time, so
    // *changing the window* has to restart the process. No-op when nothing is running: the caller's
    // applyConditions() then does the spawn (or leaves it suspended).
    func restartForNewWindow(remaining: TimeInterval?) {
        guard isRunning else { return }
        kill()
        spawn(remaining: remaining)
    }

    private func spawn(remaining: TimeInterval?) {
        guard process == nil else { return }
        guard FileManager.default.isExecutableFile(atPath: Self.caffeinatePath) else {
            fputs("SleepPreventer: \(Self.caffeinatePath) is not available; cannot prevent sleep.\n", stderr)
            return
        }
        var arguments = ["-di"]
        // `-t <secs>` IS the timed release: caffeinate drops the assertion and exits on its own when
        // the window elapses, so the app needs no timer of its own. Floored at 1s — `-t 0` would
        // assert indefinitely, the opposite of what an already-elapsed window means.
        if let remaining {
            arguments += ["-t", String(max(Int(remaining.rounded()), 1))]
        }
        arguments += ["-w", String(ProcessInfo.processInfo.processIdentifier)]

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: Self.caffeinatePath)
        proc.arguments = arguments
        generation += 1
        let token = generation
        // Fires on ANY exit of this child. Our own terminate() detaches the handler first (see kill()),
        // so reaching here means caffeinate exited by itself — the window elapsed. Process calls this
        // on a background queue, hence the hop to main.
        // Strong capture, deliberately: `terminationHandler` is @Sendable, and capturing a weak var
        // inside it is a Swift 6 error. The transient cycle (proc → handler → self → proc) breaks on
        // either exit path — kill() nils the handler, and this handler nils `process` — after which
        // proc deallocates and releases its reference back to us. SleepPreventer is app-lifetime
        // regardless, so there is nothing to leak.
        proc.terminationHandler = { [self] _ in
            DispatchQueue.main.async { [self] in
                MainActor.assumeIsolated {
                    guard self.generation == token else { return }
                    self.process = nil
                    self.isEnabled = false   // the window is over; intent ends with it
                    self.onWindowExpired?()
                }
            }
        }
        do {
            try proc.run()
            process = proc
        } catch {
            fputs("SleepPreventer: caffeinate spawn failed: \(error.localizedDescription)\n", stderr)
        }
    }

    private func kill() {
        // Detach the handler BEFORE terminating: an intentional kill (Off, or a condition-suspend)
        // must not be mistaken for a window elapsing, which would clear the user's intent — the exact
        // thing the isEnabled/isRunning split exists to preserve. The generation bump makes any
        // handler already in flight a no-op too.
        generation += 1
        process?.terminationHandler = nil
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
    // The adjacent label (live value / custom text) — TWO status items, of which at most one is ever
    // wider than zero. Both exist because macOS assigns a status item its slot when it becomes visible,
    // orders slots by that moment (oldest = rightmost), and offers no API to reorder or re-place a
    // visible item. So "which side of the animation is the label on?" is decided entirely by creation
    // order, and a runtime switch is impossible for a single item: it would mean destroying and
    // rebuilding one of the two, and the one that would have to go is the *animation* (its button, layer,
    // keep-awake bar, display link and occlusion observer) whenever the label moved right.
    //
    // Creating both up front — right slot, animation, left slot — makes the switch free: pick which one
    // carries the text and zero the other.
    //
    // Both stay permanently visible because a slot is only adjacent to the animation if it was created
    // back-to-back with it: reveal an item later and it lands leftmost of *every* status item on the bar
    // (newest wins), with other apps' icons between it and ours. That rules out hiding the idle one, and
    // rules out creating either lazily. So `.off` and "not the active side" are both expressed as
    // length = 0; on, the active side gets the RESERVED width from labelSlotWidth (never variableLength —
    // see there). applyLabelMode()/updateValueLabel() are the only writers.
    //
    // **A length-0 item is not free: it still claims ~16pt of menu bar.** Measured with
    // MENUBAR_LOAD_RUNNER_LOG_SLOTS on macOS 26 — hiding the idle item moves its neighbour 16pt over,
    // reproducibly (an earlier comment here claimed "zero footprint, no clickable gap"; the width half of
    // that is simply false). So the pair costs 16pt more bar than a single item would, permanently. It is
    // still the right trade: the only way to switch sides without it is to destroy and rebuild the
    // ANIMATION item — its button, layer, keep-awake bar, display link and occlusion observer — on every
    // switch to the right, which is a lot of moving parts to break for 16pt. If that 16pt ever matters
    // more than an instant switch, the cheap retreat is to create only the persisted side's item at
    // launch and make the menu row take effect on the next launch.
    private var labelItemLeft: NSStatusItem!
    private var labelItemRight: NSStatusItem!
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
    // Second radio group in the same submenu: the slot's side. Rows carry indices into
    // MenuBarLabelSide.allCases, read only by selectLabelSide.
    private var labelSideItems: [NSMenuItem] = []
    // "Battery Threshold" submenu, the second Settings row: a radio group over
    // Tuning.batteryThresholdRows plus Never and Custom…, with the parent title carrying the readout
    // exactly as the label group's does. The rows' tags are indices into that array and are read ONLY
    // by selectBatteryThreshold, so this tag space is disjoint from the two Keep Awake groups' despite
    // the numeric overlap — the same arrangement their comments describe.
    private var batteryThresholdMenuItem: NSMenuItem!
    private var batteryThresholdItems: [NSMenuItem] = []
    private var batteryThresholdCustomItem: NSMenuItem!
    private static let batteryThresholdNeverTag = -1
    private var startAtLoginMenuItem: NSMenuItem!
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
    // "Menu Bar Label" menu. applyLabelMode() reconciles the two slot items' widths with it.
    private var labelMode: MenuBarLabel = .off
    // Which of the two label items is the live one (see labelItemLeft/labelItemRight). Menu-only, and
    // restored from the state file by applyLaunchLabelState(); mutated only by setLabelSide.
    private var labelSide: MenuBarLabelSide = .left
    // The slot on the chosen side. nil only before applicationDidFinishLaunching creates both.
    private var activeLabelItem: NSStatusItem? {
        labelSide == .left ? labelItemLeft : labelItemRight
    }
    // Menu-bar font with monospaced digits: a reading's width then depends only on how MANY characters
    // it has, not which digits it happens to show ("111%" and "888%" measure the same). That is what
    // lets one reserved width hold for a whole shape, and it stops the digits wobbling within it.
    private static let labelFont = NSFont.monospacedDigitSystemFont(
        ofSize: NSFont.menuBarFont(ofSize: 0).pointSize,
        weight: .regular
    )
    private var cachedLoadAverages: (Double, Double, Double)?
    private var screenObserver: NSObjectProtocol?
    private var powerStateObserver: NSObjectProtocol?
    private var thermalStateObserver: NSObjectProtocol?
    private var occlusionObserver: NSObjectProtocol?

    // Keep Awake. Intent is restored at launch from --keep-awake or the state file (see
    // applyLaunchKeepAwakeState) and saved on every change to it; the actual caffeinate process is
    // suspended/respawned by conditionsDidChange().
    private let sleepPreventer = SleepPreventer()
    // Parent of the "Keep Awake ▸" submenu, whose rows are one merged radio group: Off + one row per
    // KeepAwakeColor. Picking a color turns keep-awake on with that tint; picking Off turns it off — so
    // enabled-state and tint are a single choice (no separate toggle / color submenu).
    private var keepAwakeMenuItem: NSMenuItem!
    private var keepAwakeOptionItems: [NSMenuItem] = []
    // Sentinel tag for the submenu's "Off" row — distinct from every KeepAwakeColor.rawValue (0, 1, …).
    private static let keepAwakeOffTag = -1
    // Second, independent radio group in the same submenu: the timed window. Its rows carry indices
    // into KeepAwakeDuration.presetRows and are read ONLY by selectKeepAwakeDuration, so this tag
    // space is disjoint from the tint group's (which selectKeepAwakeOption owns) despite the overlap.
    private var keepAwakeDurationItems: [NSMenuItem] = []
    private var keepAwakeCustomDurationItem: NSMenuItem!
    private var keepAwakeStatusItem: NSMenuItem!
    private var machineAwakeItem: NSMenuItem!
    // Last tint state pushed to the bar/label, so the 2s tick only re-drives them on a real change.
    private var lastAwakeTintSignature = ""
    // "Other Assertions" — the read-only section listing other processes' sleep assertions. Rows are
    // pre-created (cap + the overflow line + the `none` line) and driven by isHidden/title, the
    // otherSourceRowItems pattern: refresh must never add or remove NSMenuItems.
    private var otherAssertionRowItems: [NSMenuItem] = []
    private var otherAssertionsMoreItem: NSMenuItem!
    private let assertionMonitor = SleepAssertionMonitor()
    // The armed window, kept alongside the deadline because remaining time alone can't say which row
    // to mark (it shrinks). `.indefinite` whenever no window is armed.
    private var keepAwakeSelectedDuration: KeepAwakeDuration = .indefinite
    // When the armed window ends, or nil when indefinite. The single source of truth for both the
    // countdown readout and the `-t` balance a respawn passes. caffeinate performs the release itself,
    // so nothing polls this for expiry.
    private var keepAwakeDeadline: Date?
    // 1s ticker that runs ONLY while the menu is open, so the countdown reads as a countdown (the 2s
    // load tick can't render seconds smoothly). See startKeepAwakeCountdownTicker.
    private var keepAwakeCountdownTicker: Timer?
    // Keep-awake bar tint, user-selectable via the Keep Awake submenu. Menu-only (no CLI/env), but
    // persisted: it is cosmetic and carries no sleep consequence, so it is restored unconditionally
    // at launch even when the saved window isn't.
    private var activeKeepAwakeColor: KeepAwakeColor = .teal
    // Updated by the IOKit power-source notification. `nil` on a desktop Mac (no battery) or a failed
    // read, so battery is never a disengage trigger there. Carries the charge FIGURE, not just a
    // low/not-low flag, because the paused menu row shows the percentage — and batteryMonitor can't
    // supply it, since reader sampling is active-only and Battery usually isn't the driving source.
    private var batteryState: (onBattery: Bool, percent: Double)?
    private var batteryRunLoopSource: CFRunLoopSource?
    // An explicit user gesture to keep the Mac awake despite a low battery. Set only by the two menu
    // paths (a color row, or arming a duration) — deliberately NOT by --keep-awake or the restored
    // window, both of which fire with nobody present, which is the same stale-flag risk that already
    // keeps an *indefinite* saved window from being restored. Memory-only for the same reason: a
    // relaunch is a fresh decision, so this never reaches state.json.
    private var keepAwakeBatteryOverride = false
    // The charge fraction at or below which keep-awake releases on battery — the live sleep policy,
    // read by keepAwakeSuspension. Starts at Tuning.batteryLowThresholdDefault; the CLI/env and the
    // state file relocate it at launch (applyLaunchBatteryThresholdState), and a later step adds the
    // menu — always through Tuning.clampedBatteryThreshold, since none of those entry points is
    // trusted. Tuning.batteryThresholdOff (0) means "never release on charge
    // alone"; the 5% critical floor is checked first either way and is not configurable.
    private var keepAwakeBatteryThreshold: Double = Tuning.batteryLowThresholdDefault
    // Sibling overlay layer on animationView.layer, on top of the frame contents. The keep-awake
    // track line; hidden unless caffeinate is actually running. NEVER composited into renderedFrames.
    private var keepAwakeBar: CALayer?

    init(config: Config) {
        self.config = config
        // nil (no flag/env) starts off and is reconciled against the saved mode in
        // applyLaunchLabelState(), which runs before the first applyLabelMode().
        self.labelMode = config.label ?? .off
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

        // Slot order is creation order, and it is fixed for the lifetime of a visible item (see the
        // labelItemLeft/labelItemRight doc comment), so all three items are created here, in the order
        // they appear on screen from RIGHT to left: the right-hand label slot, the animation, then the
        // left-hand label slot. applyLabelMode() decides which label slot is the live one; the other
        // stays at length 0 and is invisible in every sense that matters.
        labelItemRight = makeLabelItem()

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

        // The left-hand label slot — newest item, so it lands left of the animation.
        labelItemLeft = makeLabelItem()

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

        // "Settings ▸" — the home for menu-driven preferences. Its job is to have somewhere to put the
        // next setting: the root menu is the scarce surface (it also carries the metrics block, the
        // sources section, and Presets), and every new toggle used to land there by default.
        //
        // Menu Bar Label is reparented WHOLE, not flattened into this submenu. Its parent row's title
        // IS the readout — refreshLabelSelectionState writes "Menu Bar Label: value" into it — and
        // flattened, that string would have nowhere to live but this submenu's own title, which cannot
        // say "Label: value" once a second setting exists. One extra level is the cheaper trade.
        let settingsMenuItem = NSMenuItem(title: MenuTitle.settings, action: nil, keyEquivalent: "")
        let settingsSubmenu = NSMenu(title: MenuTitle.settings)

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

        // Second, independent radio group in the same submenu — which side of the animation the slot sits
        // on. Same shape as the Keep Awake submenu's tint + duration pair. These rows carry indices into
        // MenuBarLabelSide.allCases and are read ONLY by selectLabelSide, so they share no tag space with
        // anything else (the three mode rows above are distinguished by selector, and carry no tags).
        labelSubmenu.addItem(NSMenuItem.separator())
        let labelPositionHeaderItem = NSMenuItem(title: MenuTitle.labelPositionHeader, action: nil, keyEquivalent: "")
        labelPositionHeaderItem.isEnabled = false
        labelSubmenu.addItem(labelPositionHeaderItem)
        for (index, side) in MenuBarLabelSide.allCases.enumerated() {
            let item = NSMenuItem(title: side.menuTitle, action: #selector(selectLabelSide(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            useSelectionMark(item)
            labelSubmenu.addItem(item)
            labelSideItems.append(item)
        }

        labelMenuItem.submenu = labelSubmenu
        settingsSubmenu.addItem(labelMenuItem)

        // "Battery Threshold" radio group — the charge at which Keep Awake releases on battery. Same
        // shape as the label group, and here for the same reason: the parent title is the readout
        // ("Battery Threshold: 20%"), which flattening into Settings would leave nowhere to live.
        //
        // It belongs under Settings rather than in the Keep Awake submenu even though it governs Keep
        // Awake: that submenu is one merged on/off+tint radio group plus the duration group, i.e. all
        // actions, and this is a standing preference that outlives any single arm.
        batteryThresholdMenuItem = NSMenuItem(title: MenuTitle.batteryThresholdPrefix, action: nil, keyEquivalent: "")
        let batteryThresholdSubmenu = NSMenu(title: MenuTitle.batteryThresholdPrefix)

        for (index, fraction) in Tuning.batteryThresholdRows.enumerated() {
            let item = NSMenuItem(title: MenuTitle.batteryThresholdValue(fraction),
                                  action: #selector(selectBatteryThreshold(_:)), keyEquivalent: "")
            item.target = self          // nested — infoMenu's blanket target pass never reaches here
            item.tag = index
            useSelectionMark(item)
            batteryThresholdSubmenu.addItem(item)
            batteryThresholdItems.append(item)
        }

        let neverItem = NSMenuItem(title: MenuTitle.batteryThresholdNever,
                                   action: #selector(selectBatteryThreshold(_:)), keyEquivalent: "")
        neverItem.target = self
        neverItem.tag = Self.batteryThresholdNeverTag
        useSelectionMark(neverItem)
        batteryThresholdSubmenu.addItem(neverItem)
        batteryThresholdItems.append(neverItem)

        batteryThresholdCustomItem = NSMenuItem(title: MenuTitle.batteryThresholdCustom,
                                                action: #selector(promptCustomBatteryThreshold), keyEquivalent: "")
        batteryThresholdCustomItem.target = self
        useSelectionMark(batteryThresholdCustomItem)
        batteryThresholdSubmenu.addItem(batteryThresholdCustomItem)

        batteryThresholdMenuItem.submenu = batteryThresholdSubmenu
        settingsSubmenu.addItem(batteryThresholdMenuItem)

        settingsSubmenu.addItem(NSMenuItem.separator())
        startAtLoginMenuItem = NSMenuItem(
            title: "Start at Login",
            action: #selector(toggleStartAtLogin(_:)),
            keyEquivalent: ""
        )
        startAtLoginMenuItem.target = self
        useSelectionMark(startAtLoginMenuItem)
        settingsSubmenu.addItem(startAtLoginMenuItem)

        settingsMenuItem.submenu = settingsSubmenu
        infoMenu.addItem(settingsMenuItem)

        infoMenu.addItem(NSMenuItem.separator())
        // "Keep Awake ▸" submenu: one radio group merging the on/off state and the track-line tint.
        // Off disengages caffeinate; each color row engages it with that tint (selectKeepAwakeOption).
        keepAwakeMenuItem = NSMenuItem(title: MenuTitle.keepAwake, action: nil, keyEquivalent: "")
        let keepAwakeSubmenu = NSMenu(title: MenuTitle.keepAwake)

        // The machine-state row, ABOVE the radio group: whether this Mac is held awake by anyone, ours or
        // not. First because it is the question the submenu gets opened with, and separate from the group
        // below because a foreign hold must never tick a row that only releases ours (see AwakeHold).
        // Always visible — "Nothing holding sleep" is an answer, and a hidden row doesn't say the app
        // looked. Never disabled-looking-empty: it carries text from the first tick.
        machineAwakeItem = NSMenuItem(title: MenuTitle.machineAwakeNone, action: nil, keyEquivalent: "")
        machineAwakeItem.isEnabled = false
        keepAwakeSubmenu.addItem(machineAwakeItem)
        keepAwakeSubmenu.addItem(NSMenuItem.separator())

        let offItem = NSMenuItem(title: MenuTitle.keepAwakeOff, action: #selector(selectKeepAwakeOption(_:)), keyEquivalent: "")
        offItem.target = self
        offItem.tag = Self.keepAwakeOffTag
        useSelectionMark(offItem)
        keepAwakeSubmenu.addItem(offItem)
        keepAwakeOptionItems.append(offItem)
        for choice in KeepAwakeColor.allCases {
            let item = NSMenuItem(title: choice.menuTitle, action: #selector(selectKeepAwakeOption(_:)), keyEquivalent: "")
            item.target = self
            item.tag = choice.rawValue
            useSelectionMark(item)
            keepAwakeSubmenu.addItem(item)
            keepAwakeOptionItems.append(item)
        }

        // Second radio group: the timed window. Picking any row arms Keep Awake (see
        // selectKeepAwakeDuration) — arming a window and turning it on are one gesture.
        keepAwakeSubmenu.addItem(NSMenuItem.separator())
        let durationHeaderItem = NSMenuItem(title: MenuTitle.keepAwakeDurationHeader, action: nil, keyEquivalent: "")
        durationHeaderItem.isEnabled = false
        keepAwakeSubmenu.addItem(durationHeaderItem)
        for (index, duration) in KeepAwakeDuration.presetRows.enumerated() {
            let item = NSMenuItem(title: duration.menuTitle, action: #selector(selectKeepAwakeDuration(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            useSelectionMark(item)
            keepAwakeSubmenu.addItem(item)
            keepAwakeDurationItems.append(item)
        }
        keepAwakeCustomDurationItem = NSMenuItem(
            title: MenuTitle.keepAwakeCustomDuration,
            action: #selector(promptCustomKeepAwakeDuration),
            keyEquivalent: ""
        )
        keepAwakeCustomDurationItem.target = self
        useSelectionMark(keepAwakeCustomDurationItem)
        keepAwakeSubmenu.addItem(keepAwakeCustomDurationItem)

        // Live sub-state of Keep Awake, in one row with two modes: the countdown for an armed window,
        // or why keep-awake is paused. Hidden only when there is nothing to say (running, indefinite).
        keepAwakeStatusItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        keepAwakeStatusItem.isEnabled = false
        keepAwakeStatusItem.isHidden = true
        keepAwakeSubmenu.addItem(NSMenuItem.separator())
        keepAwakeSubmenu.addItem(keepAwakeStatusItem)

        // "Other Assertions": which OTHER processes hold a sleep assertion, and of which type. Inline
        // here rather than anywhere else, for three reasons. Not the root menu — it is the scarce surface
        // (Settings ▸ and Presets ▸ exist to keep it short) and someone wondering about sleep opens this
        // submenu. Not a nested submenu — that would be two deep, and tests/menu-dump.applescript
        // descends one level, the same verification gap already recorded against the Battery Threshold
        // rows. Not the parent row — its title already composes a countdown with (paused).
        keepAwakeSubmenu.addItem(NSMenuItem.separator())
        let assertionsHeaderItem = NSMenuItem(title: MenuTitle.otherAssertions, action: nil, keyEquivalent: "")
        assertionsHeaderItem.isEnabled = false
        keepAwakeSubmenu.addItem(assertionsHeaderItem)
        // `assertionRowCap` list rows; row 0 doubles as the `none` line when the list is empty.
        for _ in 0..<Tuning.assertionRowCap {
            let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            item.isEnabled = false
            item.indentationLevel = 1
            item.isHidden = true
            keepAwakeSubmenu.addItem(item)
            otherAssertionRowItems.append(item)
        }
        otherAssertionsMoreItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        otherAssertionsMoreItem.isEnabled = false
        otherAssertionsMoreItem.indentationLevel = 1
        otherAssertionsMoreItem.isHidden = true
        keepAwakeSubmenu.addItem(otherAssertionsMoreItem)

        keepAwakeMenuItem.submenu = keepAwakeSubmenu
        infoMenu.addItem(keepAwakeMenuItem)

        infoMenu.addItem(NSMenuItem.separator())
        // "Presets ▸". These were inline root rows under a disabled header, which is where most of the
        // root menu's length came from — one row per built-in preset, and the manifest keeps growing.
        // The submenu's own title replaces that header row. `presetMenuItems` is unaffected by the move:
        // refreshPresetSelectionState addresses stored items, never menu positions.
        let presetsMenuItem = NSMenuItem(title: MenuTitle.presets, action: nil, keyEquivalent: "")
        let presetsSubmenu = NSMenu(title: MenuTitle.presets)

        for (index, preset) in allPresets.enumerated() {
            let item = NSMenuItem(title: preset.menuTitle, action: #selector(selectPreset(_:)), keyEquivalent: "")
            item.target = self   // nested now, so the root-only target wiring below no longer reaches it
            item.tag = index
            useSelectionMark(item)
            presetsSubmenu.addItem(item)
            presetMenuItems.append(item)
        }
        presetsMenuItem.submenu = presetsSubmenu
        infoMenu.addItem(presetsMenuItem)

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
        // Root items only — anything nested in a submenu sets its own target at construction.
        infoMenu.items.forEach { $0.target = self }
        refreshStartAtLoginState()
        statusItem.menu = infoMenu
        // Both label slots share the animation's dropdown, so clicking the number opens the same menu.
        labelItemLeft.menu = infoMenu
        labelItemRight.menu = infoMenu
        refreshPresetSelectionState()
        refreshWidthInfo()
        applyLaunchLabelState()   // resolve --label vs. the saved mode/side BEFORE sizing the slots
        refreshLabelSelectionState()
        applyLabelMode()   // size the live slot now if launched with --label value / custom text
        refreshShowAllSourcesState()
        // caffeinate exited on its own → an armed window elapsed. Drop the window and let the UI fall
        // back to Off; the Mac is free to sleep from here. This is the whole timed release.
        sleepPreventer.onWindowExpired = { [weak self] in
            guard let self else { return }
            self.clearKeepAwakeWindow()
            // The gesture is spent with the window it authorized. Without this, a later arm from a
            // non-gesture path (a restored window) would inherit an override nobody granted it.
            self.keepAwakeBatteryOverride = false
            self.refreshKeepAwakeSelectionState()
            self.updateKeepAwakeBar()
            self.persistState()   // the window is spent; don't resume it on the next launch
        }
        // Before startBatteryMonitoring(), so the very first suspension is computed against the
        // requested threshold rather than the default. See applyLaunchBatteryThresholdState().
        applyLaunchBatteryThresholdState()
        refreshBatteryThresholdSelectionState()   // after the resolve above, or the menu shows the default
        // MUST precede applyLaunchKeepAwakeState(): arming reads `batteryState` to decide whether a
        // condition suspends the window, and this is what populates it. Registered later in this
        // function historically, which meant a launch-time arm saw a nil battery state and spawned
        // caffeinate even at a critical charge, self-correcting only on the next power-source
        // notification (minutes, at a charge where minutes matter).
        startBatteryMonitoring()
        applyLaunchKeepAwakeState()
        refreshKeepAwakeSelectionState()
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
        // Prime the other-holders list: the load timer doesn't fire for 2s, and unlike a load reader —
        // which honestly reads "warming up..." until it has two samples — an unsampled assertion list
        // would render `none`, a wrong answer rather than an absent one.
        sampleOtherAssertions(now: ProcessInfo.processInfo.systemUptime)
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
        stopKeepAwakeCountdownTicker()
        for observer in [screenObserver, powerStateObserver, thermalStateObserver, occlusionObserver] {
            if let observer {
                NotificationCenter.default.removeObserver(observer)
            }
        }
        // Dispatch source: cancel() (not removeObserver) — its own lifecycle.
        memoryPressureSource?.cancel()
        memoryPressureSource = nil

        // Save before the kill below: intent survives a quit, so a window still running when the app
        // exits (or when the machine reboots under it) is resumed — minus the downtime — next launch.
        persistState()

        // `-w <pid>` already reaps caffeinate on a crash, but a clean exit should terminate it
        // explicitly and tear down the power-source run-loop source. isEnabled is left intact; the
        // process is what we kill (suspend: true forces the kill branch).
        sleepPreventer.applyConditions(suspend: true, remaining: nil)
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
            // Names the Other Sources section, NOT a "Load Source menu" — that submenu was replaced by
            // the inline disclosure list and this string kept pointing at it.
            ? "Speed adapts to \(activeLoadSource.menuTitle) load (change it under \(MenuTitle.otherSources))."
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
                        self.showUpdateSucceeded(version: latest)
                    } else {
                        self.showUpdateFailed(message: result.message)
                    }
                }
            }
        }
    }

    // Update applied. The pull moved the source; the *running* process is still the old binary, so the
    // alert's job is to get the user onto the new one. Restart is offered only when we know how to come
    // back (`Restarter.Mode`) — otherwise the alert says what to do by hand, which is all there was
    // before. Resolved fresh on each alert rather than cached at launch: a login item can be installed
    // while the app runs, and this is a click-gated path where one `launchctl list` costs nothing.
    private func showUpdateSucceeded(version: SemVer) {
        let title = "Updated to \(version.tagString)"
        let mode = Restarter.mode(
            environment: ProcessInfo.processInfo.environment,
            isLaunchAgentJob: Restarter.isLaunchAgentJob()
        )
        let manualHint = "Restart MenuBar Load Runner to load the new version — quit from the menu and relaunch (it also starts fresh at next login)."
        guard mode != .unsupported else {
            informational(title: title, message: manualHint)
            return
        }
        if suppressModalAlerts {
            fputs("\(title): \(manualHint)\n", stderr)
            return
        }
        let alert = NSAlert()
        alert.messageText = title
        if let icon = makeMenuAlertIcon() {
            alert.icon = icon
        }
        alert.informativeText = "Restart now to load it. The app quits and comes straight back — your Keep Awake window, label, and settings carry over."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Restart")   // first = default (Return)
        alert.addButton(withTitle: "Later")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        restart(mode: mode)
    }

    // Spawns the waiter that relaunches us, then quits normally. Order matters: `terminate` runs
    // applicationWillTerminate, which persists intent and kills the caffeinate child — the waiter is
    // blocked on our pid until that has happened, so the new process reads a settled state file and
    // the launcher's singleton guard sees no live instance.
    private func restart(mode: Restarter.Mode) {
        let arguments = Restarter.appArguments(
            presetOrPath: activePreset?.key ?? activeGifPath,
            loadSourceKey: activeLoadSource.key,
            labelArgument: labelMode.launchArgument,
            batteryThresholdPercent: Int((keepAwakeBatteryThreshold * Tuning.percentScale).rounded()),
            speedMultiplierOverride: config.speedMultiplierOverride,
            showAllSources: showAllSources,
            keepAwakeIndefinite: sleepPreventer.isEnabled && keepAwakeDeadline == nil
        )
        guard let command = Restarter.restartCommand(mode: mode, appArguments: arguments, uid: getuid()),
              Restarter.spawnRestart(command: command) else {
            showRuntimeError("Couldn't restart automatically. Quit from the menu and relaunch to load the new version.")
            return
        }
        NSApp.terminate(nil)
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

        // Who else holds a sleep assertion. Sampled on the tick whether or not the menu is open, because
        // the hysteresis that keeps a renewal loop from blinking needs continuity — see the function.
        sampleOtherAssertions(now: now)
        // A foreign hold appearing or clearing changes the track line and the label tint, and neither is
        // behind the menu — so the bar has to be re-driven from the tick, not only from the toggle/resize
        // events it used to be. Guarded on the tint signature (which excludes the countdown) so a steady
        // state costs no CATransaction and no relayout every 2s.
        let tintSignature = awakeHold.tintSignature
        if tintSignature != lastAwakeTintSignature {
            lastAwakeTintSignature = tintSignature
            updateKeepAwakeBar()
        }
        logAwakeHoldIfRequested()

        refreshMenuMetrics()
        // Keep Awake's countdown is the one selection-state row that changes on its own, so it refreshes
        // on the tick as well as on menuWillOpen — an open menu counts down live.
        refreshKeepAwakeSelectionState()
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
        refreshBatteryThresholdSelectionState()
        refreshShowAllSourcesState()
        refreshKeepAwakeSelectionState()
        refreshUpdateStatus()
        refreshStartAtLoginState()
        startKeepAwakeCountdownTicker()
    }

    func menuDidClose(_ menu: NSMenu) {
        stopKeepAwakeCountdownTicker()
    }

    // The countdown lives inside the dropdown, so it is only ever *seen* while the menu is open — which
    // is exactly when the 2s load tick is too coarse for a seconds-resolution readout. Run a 1s ticker
    // for the lifetime of the open menu and nothing more: no cost when closed, and it keeps the
    // self-throttle ethos (the 2s tick still refreshes the row for the next open). `.common` mode is
    // required — a menu puts the run loop in modal tracking, where a default-mode timer wouldn't fire.
    private func startKeepAwakeCountdownTicker() {
        stopKeepAwakeCountdownTicker()
        // Our own window OR a foreign hold: the machine-state row renders our countdown too, so a running
        // hold with no window of ours still has a row that changes (and a foreign hold can start or clear
        // while the menu sits open). Nothing to count down at all → no ticker, as before.
        guard keepAwakeDeadline != nil || awakeHold.isHeld || awakeHold.isPartial else { return }
        let ticker = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshKeepAwakeSelectionState() }
        }
        keepAwakeCountdownTicker = ticker
        RunLoop.main.add(ticker, forMode: .common)
    }

    private func stopKeepAwakeCountdownTicker() {
        keepAwakeCountdownTicker?.invalidate()
        keepAwakeCountdownTicker = nil
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
            loadHistoryView.lowThreshold = Tuning.batteryChartLowThreshold
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
        logSlotGeometry()   // no-op unless MENUBAR_LOAD_RUNNER_LOG_SLOTS=1
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

    // Merged Keep Awake radio group (Off + one row per tint). Off is marked when caffeinate is disabled;
    // otherwise the active color's row is marked. All rows are always available (pure colors / off), so
    // no isEnabled dance is needed. Keyed on the toggle intent (isEnabled), not the transient running
    // state, so a condition-suspended caffeinate still shows its color as the chosen option.
    // The machine's actual sleep-hold state, derived from our own child plus the assertion monitor's
    // filtered list. This is the THIRD of three questions in this feature, and the only one that had no
    // surface until now:
    //   (a) intent      — did *I* arm Keep Awake?      sleepPreventer.isEnabled. Ours, controllable.
    //   (b) observation — what assertions exist?       SleepAssertionMonitor. Read-only.
    //   (c) effect      — is this Mac held awake?      THIS. An inference over (a) ∪ (b).
    //
    // Two invariants keep (c) honest, and they are the whole design:
    //
    // 1. (b) MUST NEVER DRIVE (a)'s CONTROLS. A foreign caffeinate must not tick a tint row or clear the
    //    Off mark. If it did, clicking Off would fail to turn off what the menu appears to describe — a
    //    control that lies. That is why this is a separate read-only row and not a smarter radio group.
    // 2. Always attributed. Rendered through MenuTitle.machineAwakeRow, which names the holder, because
    //    "is it mine to turn off" is the next question and Off can only release ours.
    //
    // Costs nothing: SleepAssertionMonitor already samples unconditionally on the 2s tick. That tick is
    // the reason this is affordable, and this is the second reason it must stay unconditional (the first
    // is in sampleOtherAssertions — menu-gated sampling reads `none` inside a renewal gap).
    private struct AwakeHold {
        let ownRunning: Bool
        let ownRemaining: TimeInterval?    // nil = indefinite
        let foreignOwners: [String]        // display-holders first, so the NAMED owner is the one holding
        let foreignDisplayHeld: Bool
        let foreignIdleHeld: Bool
        // When the NAMED foreign holder releases, nil if it holds indefinitely. Scoped to that one owner
        // on purpose: a machine-wide roll-up is nil in practice (see SleepAssertionMonitor), and the
        // clock time is only meaningful next to the name it belongs to.
        let foreignUntil: Date?

        // Keyed on the DISPLAY, not on idle sleep: this app spawns `-di` precisely because an idle-only
        // assertion doesn't survive the display going down (the system follows it), so idle-alone is not
        // evidence the Mac stays awake. Our own child always holds both.
        var isHeld: Bool { ownRunning || foreignDisplayHeld }
        // Something holds idle sleep but nothing holds the display — the case the row must NOT report as
        // held awake, because the Mac can still sleep.
        var isPartial: Bool { !isHeld && foreignIdleHeld }

        var rowText: String {
            guard isHeld else { return isPartial ? MenuTitle.machineAwakePartial : MenuTitle.machineAwakeNone }
            var detail: String
            if ownRunning {
                detail = MenuTitle.machineAwakeSelf
                if let remaining = ownRemaining, let text = KeepAwakeDuration.countdown(remaining) {
                    detail += " · \(text)"
                }
                if !foreignOwners.isEmpty {
                    detail += ", \(MenuTitle.machineAwakeOthers(foreignOwners.count))"
                }
            } else {
                detail = foreignOwners.first ?? ""
                if foreignOwners.count > 1 {
                    detail += " \(MenuTitle.machineAwakeOthers(foreignOwners.count - 1))"
                }
                if let until = foreignUntil {
                    detail += " · until \(KeepAwakeDuration.clockTime(until))"
                }
            }
            return MenuTitle.machineAwakeRow(detail)
        }

        // Change detection for the track line / label tint, which only care WHICH of the three tint
        // states applies — deliberately excludes the countdown, or the bar would redraw every second.
        var tintSignature: String { "\(isHeld)|\(ownRunning)|\(isPartial)|\(foreignOwners.count)" }
    }

    private var awakeHold: AwakeHold {
        // Display-holders first, then alphabetical: when isHeld comes from a foreign hold, the owner the
        // row names is one that is actually holding the display rather than whoever sorts first.
        let ordered = assertionMonitor.holders.sorted {
            ($0.displayHeld ? 0 : 1, $0.owner) < ($1.displayHeld ? 0 : 1, $1.owner)
        }
        let remaining = keepAwakeDeadline?.timeIntervalSinceNow
        return AwakeHold(
            ownRunning: sleepPreventer.isRunning,
            ownRemaining: (remaining ?? 0) > 0 ? remaining : nil,
            foreignOwners: ordered.map(\.owner),
            foreignDisplayHeld: assertionMonitor.displayHeld,
            foreignIdleHeld: assertionMonitor.idleHeld,
            foreignUntil: ordered.first?.until
        )
    }

    private func refreshKeepAwakeSelectionState() {
        let enabled = sleepPreventer.isEnabled
        for item in keepAwakeOptionItems {
            let selected = item.tag == Self.keepAwakeOffTag ? !enabled : (enabled && item.tag == activeKeepAwakeColor.rawValue)
            item.state = selected ? .on : .off
        }

        // Duration group. The armed window's row is marked; a custom length that matches no preset row
        // marks Custom… instead. With no window armed, "Until turned off" holds the mark — it describes
        // what turning Keep Awake on from here would do.
        let rows = KeepAwakeDuration.presetRows
        var matchedPresetRow = false
        for (index, item) in keepAwakeDurationItems.enumerated() where index < rows.count {
            let selected = rows[index] == keepAwakeSelectedDuration
            if selected { matchedPresetRow = true }
            item.state = selected ? .on : .off
        }
        keepAwakeCustomDurationItem.state = matchedPresetRow ? .off : .on

        // Status row + parent title. Three things can be true — keep-awake is on, a window is armed,
        // a condition has it paused — so both surfaces are composed rather than branched pairwise.
        // The paused state is stated on the PARENT row deliberately: it is the one line visible without
        // opening the submenu, and a paused keep-awake used to be signalled only by the absence of a
        // 2pt track line, which is not a signal anyone reads. `enabled` is intent; the pause comes from
        // the effective suspension, so an honored override reads as running, not paused.
        let countdown: (text: String, deadline: Date)? = {
            guard enabled, let deadline = keepAwakeDeadline else { return nil }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0, let text = KeepAwakeDuration.countdown(remaining) else { return nil }
            return (text, deadline)
        }()
        let suspension = enabled ? effectiveKeepAwakeSuspension : nil

        if let suspension {
            // Why beats how-long: the countdown keeps ticking on the parent row (the window is a
            // wall-clock deadline and elapses whether or not caffeinate is holding), but the row says
            // what to do about it. Plain `title`, not `attributedTitle`: this is prose that never ticks
            // so it needs no monospaced digits, and only `title` is exposed to accessibility — an
            // attributed-only row reads as an empty item to VoiceOver. Nil the attributed form or a
            // previous countdown render would keep winning for display.
            keepAwakeStatusItem.attributedTitle = nil
            keepAwakeStatusItem.title = MenuTitle.keepAwakePausedRow(suspension.reasonText)
            keepAwakeStatusItem.isHidden = false
            keepAwakeMenuItem.title = countdown.map { MenuTitle.keepAwakePausedWithWindow($0.text) }
                ?? MenuTitle.keepAwakePausedBare
        } else if let countdown {
            // Monospaced digits: the countdown refreshes on the 2s tick, including while the menu is
            // open, and proportional digits would make the row twitch as they change. `title` is set
            // too, and first: attributedTitle drives what's drawn, but accessibility reads `title`, so
            // an attributed-only row is silent to VoiceOver.
            let rowText = MenuTitle.keepAwakeRemainingRow(
                countdown.text, until: KeepAwakeDuration.clockTime(countdown.deadline))
            keepAwakeStatusItem.title = rowText
            keepAwakeStatusItem.attributedTitle = NSAttributedString(
                string: rowText,
                attributes: [.font: NSFont.monospacedDigitSystemFont(
                    ofSize: NSFont.menuFont(ofSize: 0).pointSize, weight: .regular)]
            )
            keepAwakeStatusItem.isHidden = false
            keepAwakeMenuItem.title = MenuTitle.keepAwakeRemaining(countdown.text)
        } else {
            keepAwakeStatusItem.isHidden = true
            keepAwakeMenuItem.title = MenuTitle.keepAwake
        }

        refreshMachineAwakeRow()
        refreshOtherAssertionRows()
    }

    // Render the machine-state row. Monospaced digits and `title`-as-well-as-`attributedTitle` for the
    // same two reasons as the countdown row above it: the text ticks while the menu is open so
    // proportional digits would twitch, and accessibility reads only `title` — an attributed-only row is
    // silent to VoiceOver. Anything scripting this menu must address it BY INDEX: this title ticks too.
    private func refreshMachineAwakeRow() {
        let text = awakeHold.rowText
        machineAwakeItem.title = text
        machineAwakeItem.attributedTitle = NSAttributedString(
            string: text,
            attributes: [.font: NSFont.monospacedDigitSystemFont(
                ofSize: NSFont.menuFont(ofSize: 0).pointSize, weight: .regular)]
        )
    }

    // Render the "Other Assertions" section from the monitor's already-filtered list. Addresses the
    // stored arrays, never menu positions. Two rules the rows encode:
    //   - `none` is a row, not an empty section: "nothing else holds one" is the answer someone opened
    //     this submenu for, and an absent section doesn't say the app looked.
    //   - the cap is never silent — the overflow row names how many were dropped.
    private func refreshOtherAssertionRows() {
        let holders = assertionMonitor.holders
        if holders.isEmpty {
            otherAssertionRowItems[0].title = MenuTitle.otherAssertionsNone
            otherAssertionRowItems[0].isHidden = false
            for item in otherAssertionRowItems.dropFirst() { item.isHidden = true }
            otherAssertionsMoreItem.isHidden = true
            return
        }

        let shown = min(holders.count, otherAssertionRowItems.count)
        for (index, item) in otherAssertionRowItems.enumerated() {
            guard index < shown else { item.isHidden = true; continue }
            let holder = holders[index]
            item.title = MenuTitle.otherAssertionRow(
                owner: holder.owner, types: holder.types.map { ($0.type, $0.count) })
            item.isHidden = false
        }
        let dropped = holders.count - shown
        otherAssertionsMoreItem.title = MenuTitle.otherAssertionsMore(dropped)
        otherAssertionsMoreItem.isHidden = dropped == 0
    }

    // Sample the other-holders list. Called from the 2s tick UNCONDITIONALLY — a deliberate exception to
    // the active-only sampling ethos that gates `showAllSources`, and not a thing to "fix" later. The
    // cheap-looking alternative (sample only while the menu is open) restores the exact bug this feature
    // exists to fix: with no history, a menu opened inside a renewal gap reads `none` while a
    // `caffeinate -t 300` loop is in fact holding. Hysteresis needs samples taken when nobody is looking.
    // Affordable because the IOKit call measures ~126 µs, i.e. a 0.006% duty cycle at one per 2s.
    private func sampleOtherAssertions(now: TimeInterval) {
        var ignored: Set<pid_t> = [ProcessInfo.processInfo.processIdentifier]
        if let childPID = sleepPreventer.childPID { ignored.insert(childPID) }
        assertionMonitor.sample(now: now, ignoringPIDs: ignored)
        guard logAssertions else { return }
        // Same contract as MENUBAR_LOAD_RUNNER_LOG_SLOTS: prints the FILTERED, post-hysteresis list, so a
        // shell with no TCC grant can assert the filter and the retention window — which neither
        // menu-dump.applescript (Accessibility) nor screencapture (Screen Recording) can reach.
        let rows = assertionMonitor.holders
            .map { holder in
                let types = holder.types.map { "\($0.type) x\($0.count)" }.joined(separator: ", ")
                return "[\(holder.owner): \(types)]"
            }
            .joined(separator: " ")
        fputs("ASSERTIONS n=\(assertionMonitor.holders.count) own=\(assertionMonitor.excludedOwnCount)"
              + (rows.isEmpty ? "" : " " + rows) + "\n", stderr)
    }

    // Debug/test hook: MENUBAR_LOAD_RUNNER_LOG_ASSERTIONS=1. Mirrors the LOG_SLOTS hook convention.
    private let logAssertions = ProcessInfo.processInfo.environment["MENUBAR_LOAD_RUNNER_LOG_ASSERTIONS"] == "1"

    // Debug/test hook: MENUBAR_LOAD_RUNNER_LOG_AWAKE=1, sibling to LOG_ASSERTIONS and LOG_SLOTS and there
    // for the same reason — a shell with no TCC grant can't read a menu, so the DERIVED state has to be
    // assertable from stderr or it goes verified by eyeball only. Prints the row text verbatim as well as
    // the flags, so qa.sh §3e can assert the rendering (attribution, "may still sleep", the countdown
    // moving) and not merely the booleans behind it.
    private let logAwake = ProcessInfo.processInfo.environment["MENUBAR_LOAD_RUNNER_LOG_AWAKE"] == "1"

    private func logAwakeHoldIfRequested() {
        guard logAwake else { return }
        let hold = awakeHold
        let state = hold.isHeld ? (hold.ownRunning ? (hold.foreignOwners.isEmpty ? "own" : "both") : "foreign")
            : (hold.isPartial ? "partial" : "none")
        fputs("AWAKE hold=\(state) own=\(hold.ownRunning ? 1 : 0)"
              + " display=\(hold.foreignDisplayHeld ? 1 : 0) idle=\(hold.foreignIdleHeld ? 1 : 0)"
              + " owners=\(hold.foreignOwners.count) row=\"\(hold.rowText)\"\n", stderr)
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

    // Debug/test hook: MENUBAR_LOAD_RUNNER_LOG_SLOTS=1 prints every status item's frame in SCREEN
    // coordinates on each 2s tick. Mirrors the EXIT_AFTER hook convention, and exists because the two
    // properties it measures are otherwise unverifiable outside a human's eyes:
    //
    //   1. slot ORDER — is the label left or right of the animation? (There is no API to ask.)
    //   2. slot STABILITY — does the animation's x, or the label's width, move as the value changes?
    //      This is the jitter bug; it is a few points twice a second, which no screenshot diff would
    //      reliably catch and which tests/label.swift can only reason about via font metrics.
    //
    // A status item's button lives in its own NSStatusBarWindow, whose frame is the slot. Reading it is
    // the app inspecting its own window, so unlike a screenshot (Screen Recording) or a menu dump
    // (Accessibility) it needs no TCC grant at all — which is what makes it scriptable in qa.sh §3.
    private func logSlotGeometry() {
        guard ProcessInfo.processInfo.environment["MENUBAR_LOAD_RUNNER_LOG_SLOTS"] == "1" else { return }
        func frame(_ item: NSStatusItem?) -> String {
            guard let f = item?.button?.window?.frame else { return "x=n/a w=n/a" }
            return String(format: "x=%.1f w=%.1f", f.minX, f.width)
        }
        let text = activeLabelItem?.button?.title ?? ""
        fputs(
            "SLOTS icon[\(frame(statusItem))] left[\(frame(labelItemLeft))]"
                + " right[\(frame(labelItemRight))] side=\(labelSide.rawValue) label=\"\(text)\"\n",
            stderr
        )
    }

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
        // Position group. The rows stay live while the label is off — picking a side then is a
        // preference for the next time it's on, not a no-op the user has to redo.
        let sides = MenuBarLabelSide.allCases
        for (index, item) in labelSideItems.enumerated() where sides.indices.contains(index) {
            item.state = (sides[index] == labelSide) ? .on : .off
        }
    }

    // Parent title carries the readout ("Battery Threshold: 20%" / ": Never") and the rows mark the
    // active choice; a value matching no row marks Custom… instead, the same fallback the duration
    // group uses. Addresses the stored array, never menu positions.
    private func refreshBatteryThresholdSelectionState() {
        batteryThresholdMenuItem.title =
            MenuTitle.batteryThreshold(MenuTitle.batteryThresholdValue(keepAwakeBatteryThreshold))

        let isNever = keepAwakeBatteryThreshold <= Tuning.batteryThresholdOff
        var matchedARow = false
        for item in batteryThresholdItems {
            let selected: Bool
            if item.tag == Self.batteryThresholdNeverTag {
                selected = isNever
            } else {
                // Every surface feeds this value as wholePercent/100, so exact equality would in fact
                // hold; the tolerance is here so a future half-percent source degrades to "Custom…"
                // rather than to a row that is merely close. Rows are ≥5% apart, so it can't match two.
                selected = !isNever
                    && abs(Tuning.batteryThresholdRows[item.tag] - keepAwakeBatteryThreshold) < 0.0005
            }
            item.state = selected ? .on : .off
            if selected { matchedARow = true }
        }
        batteryThresholdCustomItem.state = matchedARow ? .off : .on
    }

    // One of the two label slots. Both are built identically and differ only in when they were created,
    // which is what fixes them either side of the animation (see labelItemLeft/labelItemRight). Created
    // at variableLength but never left there: applyLabelMode gives the live one a reserved width and
    // zeroes the other. Menu is wired later, once infoMenu exists.
    private func makeLabelItem() -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.font = Self.labelFont
        item.button?.imagePosition = .noImage
        item.isVisible = true
        item.length = 0
        return item
    }

    // Reconcile both label slots with labelMode and labelSide: the slot on the chosen side carries the
    // text at its reserved width, the other is zeroed (~16pt, not 0 — see labelItemLeft). Nothing is
    // created, destroyed, hidden or shown: slot order is creation order, and both items must stay
    // visible to keep theirs.
    private func applyLabelMode() {
        guard let live = activeLabelItem, let left = labelItemLeft, let right = labelItemRight else { return }
        (live === left ? right : left).length = 0
        guard labelMode != .off else {
            live.length = 0
            return
        }
        // Align the text toward the animation, so the gap that a reserved slot sometimes leaves opens
        // away from the icon and the reading stays visually attached to it.
        live.button?.alignment = (labelSide == .left) ? .right : .left
        updateValueLabel()   // writes the text, the tint, and the width
    }

    // The width to hold the live slot at: the wider of the current text and a worst-case template for
    // the shape on show (Tuning.labelTemplate*). Reserving from the template — not measuring the live
    // text — is the whole point: an auto-sized slot changes width whenever the value does, and macOS
    // shifts every item to the LEFT of one that resizes, so the label used to drag its neighbour
    // sideways twice a second. Held fixed, the label can sit on either side without moving anything.
    //
    // max() rather than the template alone so an unbounded rate that overruns its realistic ceiling
    // widens the slot for that tick instead of being truncated to an ellipsis. That is the only case
    // where the width moves at all, and a wrong-looking number is worse than a rare nudge.
    private func labelSlotWidth(for text: String) -> CGFloat {
        let reserved: String
        switch labelMode {
        case .off:
            return 0
        case .value:
            reserved = labelWidthTemplate(for: activeLoadSource)
        case .custom(let label):
            reserved = label   // a fixed string is its own worst case
        }
        let width = max(measuredLabelWidth(reserved), measuredLabelWidth(text))
        return ceil(width) + Tuning.labelSlotPadding
    }

    private func measuredLabelWidth(_ text: String) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: Self.labelFont]).width
    }

    // Write the current label text into the live slot (no-op before the slots exist, or when off). In
    // .value mode this is the active source's compact live reading; in .custom mode, the fixed user
    // string. Also carries the slot's width and the Keep Awake tint (see below), so it is called both on
    // the 2s tick and from updateKeepAwakeBar() — a toggle/suspend must recolor at once, not up to 2s
    // later.
    private func updateValueLabel() {
        guard let item = activeLabelItem, let button = item.button else { return }
        let text: String
        switch labelMode {
        case .off:
            return
        case .value:
            text = compactLabelText(for: activeLoadSource)
        case .custom(let label):
            text = label
        }
        // Sizing before the text, so the slot is never briefly too narrow for what is about to go in it.
        // Assigning only on a real change keeps the 2s tick from handing AppKit a status-bar relayout it
        // doesn't need — the whole point of a reserved width is that this almost never fires twice.
        let width = labelSlotWidth(for: text)
        if abs(item.length - width) > 0.01 {
            item.length = width
        }
        // While the Mac is held awake, the label wears the same tint as the bar under the animation —
        // both through keepAwakeTintColor, so they cannot disagree: full tone for our own hold, faded for
        // someone else's, nothing when sleep is unheld. A battery/thermal suspend drops our own tone (the
        // hold reads on isRunning, not intent), and the two surfaces read as one indicator. Off, the
        // text goes back to inheriting the menu bar's own color, which is what tracks appearance and the
        // highlight when the dropdown is open; the tint has per-appearance tones for the same reason.
        // attributedTitle is the only way to color a status button's text, and it is invisible to
        // VoiceOver, hence the explicit accessibility label.
        if let color = keepAwakeTintColor(for: awakeHold, appearance: button.effectiveAppearance) {
            button.attributedTitle = NSAttributedString(
                string: text,
                attributes: [.foregroundColor: color, .font: Self.labelFont]
            )
        } else {
            button.title = text
        }
        // Strip the width padding for VoiceOver — the figure spaces are a layout device, and "CPU 47%"
        // is what the row means. (All padding is leading-within-a-field, so removing it is lossless.)
        button.setAccessibilityLabel(text.replacingOccurrences(of: "\u{2007}", with: ""))
    }

    // A short, menu-bar-sized readout of a source's live value: "CPU 47%", "MEM 63%", "NET ↓3.4 ↑0.1",
    // "DSK R12 W4", "GPU 30%", "FAN 45%", "BAT 88%" (MB/s implied for the rate sources). Compact
    // deliberately — the dropdown carries the fully-labeled figures; this is the at-a-glance number.
    //
    // Every number goes through labelField, so each is padded to a constant width (see there) — the
    // reading is a fixed-width readout with the digits in columns, not a string that grows and shrinks.
    private func compactLabelText(for source: LoadSource) -> String {
        let tag = source.menuTitle.prefix(3).uppercased()
        guard activeSourceHasSample else { return "\(tag) …" }
        switch source {
        case .cpu:
            return "CPU \(Self.percentField(loadMonitor.smoothedUsage))%"
        case .memory:
            return "MEM \(Self.percentField(memoryMonitor.currentUsedFraction))%"
        case .gpu:
            return "GPU \(Self.percentField(gpuMonitor.currentUtilization))%"
        case .network:
            return "NET ↓\(Self.rateField(networkMonitor.currentInboundBytesPerSec))"
                + " ↑\(Self.rateField(networkMonitor.currentOutboundBytesPerSec))"
        case .disk:
            return "DSK R\(Self.diskField(diskMonitor.currentReadBytesPerSec))"
                + " W\(Self.diskField(diskMonitor.currentWriteBytesPerSec))"
        case .fan:
            return "FAN \(Self.percentField(fanMonitor.currentUtilization))%"
        case .battery:
            return "BAT \(Self.percentField(batteryMonitor.currentChargeFraction))%"
        }
    }

    // The widest reading compactLabelText can produce for a source — measured by labelSlotWidth to
    // reserve the slot, never displayed. The numeric fields come from the same three field builders fed
    // their own ceilings, so a field's reservation cannot drift from the field itself; only the fixed
    // prose ("NET ↓", " W") is written in both places, so keep the two in step when editing a format.
    private func labelWidthTemplate(for source: LoadSource) -> String {
        switch source {
        case .cpu, .memory, .gpu, .fan, .battery:
            return "\(source.menuTitle.prefix(3).uppercased()) \(Self.percentField(1))%"
        case .network:
            return "NET ↓\(Self.rateField(Tuning.labelRateCeiling * Tuning.bytesPerMiB))"
                + " ↑\(Self.rateField(Tuning.labelRateCeiling * Tuning.bytesPerMiB))"
        case .disk:
            return "DSK R\(Self.diskField(Tuning.labelDiskCeiling * Tuning.bytesPerMiB))"
                + " W\(Self.diskField(Tuning.labelDiskCeiling * Tuning.bytesPerMiB))"
        }
    }

    // The three numeric field shapes the label uses. Each takes the reader's own unit (a 0…1 fraction,
    // or bytes/sec) so no caller has to remember the conversion, and each pads to the width of its
    // ceiling — the ceiling doubles as the reservation, so the two can't disagree.
    private static func percentField(_ fraction: Double) -> String {
        labelField(fraction * Tuning.percentScale, decimals: 0, ceiling: Tuning.percentScale)
    }

    private static func rateField(_ bytesPerSec: Double) -> String {
        labelField(bytesPerSec / Tuning.bytesPerMiB, decimals: 1, ceiling: Tuning.labelRateCeiling)
    }

    private static func diskField(_ bytesPerSec: Double) -> String {
        labelField(bytesPerSec / Tuning.bytesPerMiB, decimals: 0, ceiling: Tuning.labelDiskCeiling)
    }

    // Format one numeric field at a fixed width: the value, left-padded with FIGURE SPACE (U+2007) to
    // the character count of `ceiling`. U+2007 exists for exactly this — it is defined to be as wide as a
    // digit, which combined with the label's monospaced-digit font (labelFont) makes the field's width a
    // constant, independent of the value in it. A normal space would not do: at menu-bar size it is 3.6pt
    // against a digit's 8.1pt, so `%3.0f`-style padding still changes width as the digit count changes,
    // which is the jitter this whole path exists to remove.
    //
    // A value above the ceiling formats wider than the field and is NOT truncated — labelSlotWidth widens
    // the slot for that tick instead. Rare, honest, and self-correcting.
    private static func labelField(_ value: Double, decimals: Int, ceiling: Double) -> String {
        let format = "%.\(decimals)f"
        let text = String(format: format, value)
        let width = String(format: format, ceiling).count
        return String(repeating: "\u{2007}", count: max(0, width - text.count)) + text
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

    // One handler for the merged Keep Awake radio group. Off disengages caffeinate; a color row engages
    // it (if not already) and sets that tint. Enabled-state and tint are a single choice here.
    @objc
    private func selectKeepAwakeOption(_ sender: NSMenuItem) {
        if sender.tag == Self.keepAwakeOffTag {
            if sleepPreventer.isEnabled { sleepPreventer.setEnabled(false) }
            clearKeepAwakeWindow()   // Off ends any armed window too
            keepAwakeBatteryOverride = false   // Off withdraws the arm-anyway gesture with the intent
        } else if let choice = KeepAwakeColor(rawValue: sender.tag) {
            grantKeepAwakeBatteryOverrideIfOffered()
            activeKeepAwakeColor = choice
            if !sleepPreventer.isEnabled { sleepPreventer.setEnabled(true) }
        }
        updateSleepPrevention()   // spawns/suspends caffeinate, re-tints the bar, refreshes the group
        persistState()
    }

    // Duration group handler. Reads only its own rows' tags (indices into presetRows) — the sibling
    // tint group's tag space is selectKeepAwakeOption's business.
    @objc
    private func selectKeepAwakeDuration(_ sender: NSMenuItem) {
        let rows = KeepAwakeDuration.presetRows
        guard sender.tag >= 0, sender.tag < rows.count else { return }
        armKeepAwake(with: rows[sender.tag])
    }

    // Arm a window (or clear it, for .indefinite) and engage Keep Awake. Picking a duration while it's
    // off turns it on with the current tint — arming and enabling are one gesture.
    private func armKeepAwake(with duration: KeepAwakeDuration, isUserGesture: Bool = true) {
        keepAwakeSelectedDuration = duration
        keepAwakeDeadline = duration.seconds.map { Date(timeIntervalSinceNow: $0) }
        if !sleepPreventer.isEnabled { sleepPreventer.setEnabled(true) }
        // Picking a duration from the menu is an explicit arm — honor it despite a low battery, which
        // is otherwise the case where arming appears to work and silently does nothing. The launch path
        // passes false: --keep-awake and a restored window both fire with nobody present to decide.
        if isUserGesture { grantKeepAwakeBatteryOverrideIfOffered() }
        // A child already running carries the OLD window's `-t`, so it has to be replaced.
        sleepPreventer.restartForNewWindow(remaining: keepAwakeRemainingSeconds)
        updateSleepPrevention()
        persistState()
    }

    // Grant the battery override iff an overridable condition is actually in force right now. The
    // override answers a specific question — "the battery is low, still keep it awake?" — and that
    // question is only ever *asked* while keep-awake reads paused for a low battery. So this covers
    // both arming while already low and re-affirming while paused (clicking the row that is already
    // ticked, which would otherwise be a no-op at exactly the moment the user is reacting to it).
    //
    // Deliberately does NOT grant on an arm at a healthy charge: if the battery later crosses the
    // threshold, keep-awake pauses and *says why*, and the user can answer then. Granting up front
    // would bank a drain override against a question nobody put to them — and would behave differently
    // on AC than on battery for the very same click.
    private func grantKeepAwakeBatteryOverrideIfOffered() {
        if effectiveKeepAwakeSuspension?.isOverridable == true { keepAwakeBatteryOverride = true }
    }

    private func clearKeepAwakeWindow() {
        keepAwakeSelectedDuration = .indefinite
        keepAwakeDeadline = nil
    }

    // The ONLY writer for state.json, and the reason there is only one: StateStore.save() replaces the
    // whole file, so a keep-awake-only write would silently drop the settings block (and vice versa).
    // Both blocks are therefore composed from live in-memory state on every save — which also means
    // there is no read-modify-write window between the two kinds of caller.
    //
    // Called from the places INTENT can change: the tint/Off group, the arming path, the window-expired
    // callback, setLabelMode, and termination. Deliberately NOT from updateSleepPrevention(), which also
    // runs on every thermal/battery/power notification: those change the RUNNING state, not the intent,
    // and would write to disk for nothing.
    private func persistState() {
        StateStore.save(
            PersistedState(
                version: StateStore.currentVersion,
                keepAwake: PersistedState.KeepAwake(
                    tint: activeKeepAwakeColor.rawValue,
                    deadline: keepAwakeDeadline,
                    enabled: sleepPreventer.isEnabled
                ),
                settings: PersistedState.Settings(
                    labelMode: labelMode.persistedMode,
                    labelCustomText: labelMode.persistedCustomText,
                    labelSide: labelSide.rawValue,
                    batteryThreshold: keepAwakeBatteryThreshold
                )
            )
        )
    }

    // Launch-time label mode, the same precedence shape as applyLaunchKeepAwakeState: an explicit
    // --label / MENUBAR_LOAD_RUNNER_LABEL wins — including an explicit `off`, which suppresses the saved
    // mode — otherwise the mode saved by the previous run is restored. Unlike a keep-awake window there
    // is nothing self-limiting to weigh here: a label holds no assertion and costs nothing but a slot,
    // so every mode is restorable, not just bounded ones.
    private func applyLaunchLabelState() {
        let saved = StateStore.load()?.settings
        // The side has no flag to defer to (menu-only, like the Keep Awake tint), so it restores on its
        // own terms — independently of the mode, whose flag may well have won below.
        if let side = MenuBarLabelSide.fromPersisted(saved?.labelSide) {
            labelSide = side
        }
        guard config.label == nil else { return }
        guard let saved,
              let restored = MenuBarLabel.fromPersisted(mode: saved.labelMode,
                                                        customText: saved.labelCustomText)
        else { return }
        labelMode = restored
    }

    // Launch-time battery release threshold, in precedence order: an explicit --battery-threshold /
    // MENUBAR_LOAD_RUNNER_BATTERY_THRESHOLD wins, otherwise the value saved by the previous run is
    // restored, otherwise the property keeps Tuning.batteryLowThresholdDefault. Same shape as the
    // label, with one asymmetry worth naming: `off` here is a *value* (0), not a mode, so a flag can
    // only override a saved setting — it can never mean "absent" the way an empty env value does.
    //
    // Unlike a saved keep-awake window there is nothing to withhold: a threshold arms nothing and holds
    // no assertion, it only relocates when an already-armed window releases, so every value restores —
    // including off, whose whole point is to survive the relaunch that would otherwise reinstate 20%.
    //
    // Ordering is load-bearing — this MUST run before startBatteryMonitoring(), which is itself before
    // applyLaunchKeepAwakeState(): the first suspension is computed as soon as the battery read lands,
    // so a threshold applied after it would evaluate the launch against the default and then jump.
    private func applyLaunchBatteryThresholdState() {
        if let requested = config.batteryThreshold {
            keepAwakeBatteryThreshold = Tuning.clampedBatteryThreshold(requested)
            return
        }
        guard let saved = StateStore.load()?.settings?.batteryThreshold else { return }
        keepAwakeBatteryThreshold = Tuning.clampedBatteryThreshold(saved)
    }

    // Launch-time Keep Awake, in precedence order: an explicit --keep-awake wins, otherwise a window
    // saved by the previous run is resumed. Runs before the first refreshKeepAwakeSelectionState() so
    // the menu opens already showing the restored state; the bar picks it up from applySizing() below.
    //
    // Only a BOUNDED window is restored. Restoring a saved *indefinite* one is a materially different
    // promise — it is activate-on-launch, and it has no stopping condition, so a stale flag would keep
    // the Mac awake after every reboot until somebody noticed the menu bar. A bounded window is
    // self-limiting, and it is the case that actually hurts today (a 2am reboot silently dropping it).
    private func applyLaunchKeepAwakeState() {
        let saved = StateStore.load()?.keepAwake

        // Tint first: it applies in every branch, including an explicit CLI off.
        if let tint = saved?.tint.flatMap(KeepAwakeColor.init(rawValue:)) {
            activeKeepAwakeColor = tint
        }

        switch config.keepAwake {
        case .off:
            return                          // explicit CLI off — ignore any saved window
        case .window(let duration):
            // Not a user gesture: the flag can be baked into the login item, so it re-arms at every
            // login with nobody there to weigh a low battery against the task.
            armKeepAwake(with: duration, isUserGesture: false)   // engages, persists, spawns caffeinate
            return
        case nil:
            break                           // no flag — fall through to the saved window
        }

        guard saved?.enabled == true,
              let deadline = saved?.deadline,
              deadline.timeIntervalSinceNow > 0 else { return }
        // The mark lands on Custom… rather than the row originally picked, which is accurate: what is
        // being resumed is the REMAINDER of that window, not a fresh 4 hours.
        keepAwakeSelectedDuration = .seconds(deadline.timeIntervalSinceNow)
        keepAwakeDeadline = deadline
        sleepPreventer.setEnabled(true)
        updateSleepPrevention()
    }

    // Seconds left in the armed window, or nil when indefinite (→ no `-t` at the spawn site). Floored
    // at 1s: a window that elapsed while caffeinate was condition-suspended respawns for a moment,
    // exits on its own, and disengages through the normal expiry path — no separate check needed.
    private var keepAwakeRemainingSeconds: TimeInterval? {
        guard let keepAwakeDeadline else { return nil }
        return max(keepAwakeDeadline.timeIntervalSinceNow, 1)
    }

    // Prompt for a custom window. Minutes clamp to 0…59 and hours to Tuning.keepAwakeMaxHours rather
    // than erroring (KeepingYouAwake rejects out-of-range input with an inline error; a clamp is kinder
    // at bedtime). 0 hr 0 min is treated as Cancel — never arm a zero-length window.
    @objc
    private func promptCustomKeepAwakeDuration() {
        let alert = NSAlert()
        alert.messageText = "Keep Awake For…"
        alert.informativeText = "The Mac stays awake this long, then sleeps on its own. Up to \(Tuning.keepAwakeMaxHours) hours."
        alert.alertStyle = .informational
        if let icon = makeMenuAlertIcon() {
            alert.icon = icon
        }

        let hoursField = NSTextField(string: "1")
        hoursField.frame = NSRect(x: 0, y: 6, width: 56, height: 24)
        let hoursLabel = NSTextField(labelWithString: "Hours")
        hoursLabel.frame = NSRect(x: 0, y: 32, width: 56, height: 16)

        let minutesField = NSTextField(string: "0")
        minutesField.frame = NSRect(x: 76, y: 6, width: 56, height: 24)
        let minutesLabel = NSTextField(labelWithString: "Minutes")
        minutesLabel.frame = NSRect(x: 76, y: 32, width: 60, height: 16)

        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 52))
        for view in [hoursLabel, hoursField, minutesLabel, minutesField] {
            accessory.addSubview(view)
        }
        alert.accessoryView = accessory

        alert.addButton(withTitle: "Start")
        alert.addButton(withTitle: "Cancel")

        // Same focus mechanism as promptCustomLabel: initialFirstResponder is the deterministic part,
        // the async hop places the caret at the end of the pre-filled value.
        let alertWindow = alert.window
        alertWindow.initialFirstResponder = hoursField
        DispatchQueue.main.async { [weak hoursField, weak alertWindow] in
            guard let hoursField, let alertWindow else { return }
            alertWindow.makeFirstResponder(hoursField)
            hoursField.selectText(nil)
        }

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let hours = min(max(Int(hoursField.stringValue.trimmingCharacters(in: .whitespaces)) ?? 0, 0), Tuning.keepAwakeMaxHours)
        let minutes = min(max(Int(minutesField.stringValue.trimmingCharacters(in: .whitespaces)) ?? 0, 0), Tuning.keepAwakeMaxMinutes)
        let total = TimeInterval(hours * 3600 + minutes * 60)
        guard total > 0 else { return }
        armKeepAwake(with: .seconds(total))
    }

    @objc
    private func selectLabelOff() {
        setLabelMode(.off)
    }

    @objc
    private func selectLabelValue() {
        setLabelMode(.value)
    }

    // Tag is an index into MenuBarLabelSide.allCases — see the Position group's construction.
    @objc
    private func selectLabelSide(_ sender: NSMenuItem) {
        let sides = MenuBarLabelSide.allCases
        guard sides.indices.contains(sender.tag) else { return }
        setLabelSide(sides[sender.tag])
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

    // A row in the Battery Threshold group. Tags are indices into Tuning.batteryThresholdRows, with
    // batteryThresholdNeverTag for the Never row.
    @objc
    private func selectBatteryThreshold(_ sender: NSMenuItem) {
        if sender.tag == Self.batteryThresholdNeverTag {
            setBatteryThreshold(Tuning.batteryThresholdOff)
        } else if Tuning.batteryThresholdRows.indices.contains(sender.tag) {
            setBatteryThreshold(Tuning.batteryThresholdRows[sender.tag])
        }
    }

    // Prompt for a release point the rows don't cover. One field, whole percents — the same unit and
    // the same refusal of a decimal as --battery-threshold, since a value that reads as 0.2% under one
    // convention and 20% under the other is not something to guess at in either place.
    //
    // Where this DOES diverge from the flag: unparseable input changes nothing instead of falling back
    // to the default. "Clamp, never reject" exists because a bad value baked into a login item fires
    // with nobody present, and dropping the app or silently disabling the policy would be the worse
    // outcome. In a modal the user is right here — quietly applying 20% to a typo would be the
    // surprise. Out-of-*range* numbers still clamp, exactly as the flag's do.
    @objc
    private func promptCustomBatteryThreshold() {
        let alert = NSAlert()
        alert.messageText = "Release Keep Awake At…"
        alert.informativeText = """
            Keep Awake stops holding the Mac awake at or below this charge, on battery. \
            \(Int(Tuning.batteryThresholdMin * Tuning.percentScale))–\
            \(Int(Tuning.batteryThresholdMax * Tuning.percentScale))%, or 0 to never release on charge \
            alone. Below \(Int(Tuning.batteryCriticalThreshold * Tuning.percentScale))% the Mac sleeps \
            regardless.
            """
        alert.alertStyle = .informational
        if let icon = makeMenuAlertIcon() {
            alert.icon = icon
        }

        let current = Int((keepAwakeBatteryThreshold * Tuning.percentScale).rounded())
        let field = NSTextField(string: String(current))
        field.frame = NSRect(x: 0, y: 6, width: 56, height: 24)
        let fieldLabel = NSTextField(labelWithString: "Percent")
        fieldLabel.frame = NSRect(x: 0, y: 32, width: 60, height: 16)

        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 52))
        accessory.addSubview(fieldLabel)
        accessory.addSubview(field)
        alert.accessoryView = accessory

        alert.addButton(withTitle: "Apply")
        alert.addButton(withTitle: "Cancel")

        // Same focus mechanism as the other two prompts: initialFirstResponder is the deterministic
        // part, the async hop places the caret in the pre-filled field.
        let alertWindow = alert.window
        alertWindow.initialFirstResponder = field
        DispatchQueue.main.async { [weak field, weak alertWindow] in
            guard let field, let alertWindow else { return }
            alertWindow.makeFirstResponder(field)
            field.selectText(nil)
        }

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        var text = field.stringValue.trimmingCharacters(in: .whitespaces)
        if text.hasSuffix("%") { text.removeLast() }             // accepted, as on the CLI
        text = text.trimmingCharacters(in: .whitespaces)
        // A blank field, a decimal, or anything else unreadable = no change (see above). `0` is the
        // exception that must parse: it is the numeric spelling of Never. A negative is refused rather
        // than collapsed to Never by the clamp — a stray minus sign is a typo, not a policy decision.
        guard let percent = Int(text), percent >= 0 else { return }
        setBatteryThreshold(Double(percent) / Tuning.percentScale)
    }

    // Single point that changes the release threshold — the mutating gesture, so it persists, the same
    // rule setLabelMode and the Keep Awake intent writers follow. Three things have to happen together:
    //
    //  - Clamp here too, not just at the call sites: this is the last line before the live sleep policy.
    //  - Drop the override. It answered one question — "the battery is low, keep it awake anyway?" —
    //    asked about the OLD threshold. Raising the release point to 30% at 25% charge must not inherit
    //    a "yes" the user gave about 20%. (Setting a threshold is not itself an arm, so this never
    //    *grants* the override either — grantKeepAwakeBatteryOverrideIfOffered stays gesture-scoped.)
    //  - Apply it now. updateSleepPrevention() is what makes a live window pick the new point up
    //    immediately; without it the change waits for whenever the next thermal/battery/power event
    //    happens to fire, which is the latency conditionsDidChange() exists to avoid. It also does the
    //    menu/bar refresh, so only the threshold group's own state is left to update here.
    private func setBatteryThreshold(_ fraction: Double) {
        let clamped = Tuning.clampedBatteryThreshold(fraction)
        guard clamped != keepAwakeBatteryThreshold else { return }
        keepAwakeBatteryThreshold = clamped
        keepAwakeBatteryOverride = false
        updateSleepPrevention()
        refreshBatteryThresholdSelectionState()
        persistState()
    }

    // Single point that changes the label mode: updates state, reconciles the slot, refreshes the menu,
    // and persists. The persist belongs here and only here — this is the mutating gesture, the same rule
    // the Keep Awake intent writers follow.
    private func setLabelMode(_ mode: MenuBarLabel) {
        guard mode != labelMode else { return }
        labelMode = mode
        applyLabelMode()
        refreshLabelSelectionState()
        persistState()
    }

    // Single point that changes the label's side, same contract as setLabelMode. The move itself is just
    // applyLabelMode swapping which of the two slots is non-zero; nothing is rebuilt. Takes effect even
    // while the label is off, so the choice is already in place when it next comes on.
    private func setLabelSide(_ side: MenuBarLabelSide) {
        guard side != labelSide else { return }
        labelSide = side
        applyLabelMode()
        refreshLabelSelectionState()
        persistState()
    }

    private func isLoginItemEnabled() -> Bool {
        let plistPath = NSString(string: "~/Library/LaunchAgents/\(Restarter.launchAgentLabel).plist")
            .expandingTildeInPath
        return FileManager.default.fileExists(atPath: plistPath)
    }

    private func refreshStartAtLoginState() {
        startAtLoginMenuItem?.state = isLoginItemEnabled() ? .on : .off
    }

    @objc private func toggleStartAtLogin(_ sender: NSMenuItem) {
        guard let repoDir = repoDirURL else { return }

        if isLoginItemEnabled() {
            runShellScript(repoDir.appendingPathComponent("scripts/uninstall-login-item.sh").path)
        } else {
            let configArgs = Restarter.appArguments(
                presetOrPath: activePreset?.key ?? activeGifPath,
                loadSourceKey: activeLoadSource.key,
                labelArgument: labelMode.launchArgument,
                batteryThresholdPercent: Int((keepAwakeBatteryThreshold * Tuning.percentScale).rounded()),
                speedMultiplierOverride: config.speedMultiplierOverride,
                showAllSources: showAllSources,
                keepAwakeIndefinite: sleepPreventer.isEnabled && keepAwakeDeadline == nil
            )
            runShellScript(
                repoDir.appendingPathComponent("scripts/install-login-item.sh").path,
                arguments: configArgs
            )
        }

        refreshStartAtLoginState()
    }

    private func runShellScript(_ path: String, arguments: [String] = []) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = [path] + arguments
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do { try proc.run(); proc.waitUntilExit() } catch { return }
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
    // (fighting sleep while overheating makes it worse). NOT triggered by memory pressure (sleep
    // costs negligible RAM) or Low Power Mode (a performance policy, not a sleep policy — battery-low
    // already guards drain). Note caffeinate now holds the display awake too (`-di`), so the
    // battery-low guard matters more than under the old idle-only behavior.
    //
    // Thermal is checked BEFORE battery: both can hold at once, and a too-warm Mac is the more urgent
    // thing to report. Battery reports the tighter band first so the row never says "low" at 4%.
    private var keepAwakeSuspension: KeepAwakeSuspension? {
        let t = ProcessInfo.processInfo.thermalState
        if t == .serious || t == .critical { return .thermal }
        guard let batteryState, batteryState.onBattery else { return nil }
        let fraction = batteryState.percent / Tuning.percentScale
        if fraction <= Tuning.batteryCriticalThreshold {
            return .batteryCritical(percent: batteryState.percent)
        }
        // The live setting, not the default: this band is the part the user can relocate. At
        // Tuning.batteryThresholdOff (0) the band is gone entirely — a real charge never sits at or
        // below zero, and 0% itself is already claimed by the critical floor above.
        if fraction <= keepAwakeBatteryThreshold {
            return .batteryLow(percent: batteryState.percent)
        }
        return nil
    }

    // The suspension actually in force: an overridable one the user has explicitly overridden doesn't
    // suspend anything. Everything downstream (the spawn decision, the menu, the bar) reads THIS, so
    // an honored override is consistently reflected rather than showing as paused-but-running.
    private var effectiveKeepAwakeSuspension: KeepAwakeSuspension? {
        guard let suspension = keepAwakeSuspension else { return nil }
        if keepAwakeBatteryOverride && suspension.isOverridable { return nil }
        return suspension
    }

    private func updateSleepPrevention() {
        // Crossing the critical floor retires the override for good: at that point the user's
        // "do it anyway" has been honored as far as it safely can be, and leaving the flag set would
        // silently re-engage keep-awake if the charge ticked back up to 6% without them asking again.
        if case .batteryCritical = keepAwakeSuspension { keepAwakeBatteryOverride = false }
        // Plugged in → the override is moot. Clear it so a later unplug at 15% doesn't inherit a
        // stale "yes" from a decision made in a different power context.
        if let batteryState, !batteryState.onBattery { keepAwakeBatteryOverride = false }

        sleepPreventer.applyConditions(
            suspend: effectiveKeepAwakeSuspension != nil,
            remaining: keepAwakeRemainingSeconds
        )
        refreshKeepAwakeSelectionState()   // move the Off/color mark to match the new intent
        updateKeepAwakeBar()
    }

    // IOKit Power Sources — event-driven, mirroring the power/thermal notification pattern. Fires on
    // every power-source change (plug/unplug, % delta). A desktop Mac (no battery) skips setup
    // entirely, so batteryState stays nil and is never a disengage trigger there.
    private func startBatteryMonitoring() {
        // A forced state is static, so there is nothing to observe: adopt it and skip the run-loop
        // source. Checked BEFORE the power-source probe so the hook also works on a desktop, where
        // the probe below bails out and would otherwise leave the forced value unread.
        if let forced = Self.forcedBatteryState {
            batteryState = forced
            updateSleepPrevention()   // see below — apply, don't just record
            return
        }
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [Any],
              !list.isEmpty else { return }

        let callback: @convention(c) (UnsafeMutableRawPointer?) -> Void = { ctx in
            guard let ctx else { return }
            let app = Unmanaged<MenuBarLoadRunnerApp>.fromOpaque(ctx).takeUnretainedValue()
            MainActor.assumeIsolated {
                app.batteryState = MenuBarLoadRunnerApp.evaluateBatteryState()
                app.conditionsDidChange()
            }
        }
        batteryRunLoopSource = IOPSNotificationCreateRunLoopSource(
            callback, Unmanaged.passUnretained(self).toOpaque())?.takeRetainedValue()
        if let source = batteryRunLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        }
        batteryState = Self.evaluateBatteryState()  // initial read — don't wait for the first notification
        // Apply it, don't just record it. Harmless at launch (keep-awake intent is still off, so this
        // is a no-op), but it means the initial read can never again leave a stale suspension decision
        // in place if this call moves relative to the arming path — the ordering trap fixed above.
        updateSleepPrevention()
    }

    // Returns the charge figure and power state, not a low/not-low verdict: the thresholds are applied
    // in keepAwakeSuspension (one place), and the paused menu row needs the number to display.
    // `nil` = no battery (desktop) or an unreadable power source → battery never suspends keep-awake.
    private static func evaluateBatteryState() -> (onBattery: Bool, percent: Double)? {
        if let forced = forcedBatteryState { return forced }
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [Any],
              let first = list.first,
              let dict = IOPSGetPowerSourceDescription(blob, first as CFTypeRef)?
                            .takeUnretainedValue() as? [String: Any] else { return nil }
        let capacity = (dict[kIOPSCurrentCapacityKey] as? NSNumber)?.doubleValue ?? Tuning.percentScale
        let onBattery = (dict[kIOPSPowerSourceStateKey] as? String) == kIOPSBatteryPowerValue
        return (onBattery: onBattery, percent: capacity)   // capacity is 0–100
    }

    // Debug/test hook: MENUBAR_LOAD_RUNNER_FORCE_BATTERY=<pct>[:battery|:ac] pins the power-source read
    // so the low-battery and critical-floor paths are testable without draining a real battery — the
    // reason they went unverified long enough for arming below 20% to stay a silent no-op. Power state
    // defaults to `battery` (the interesting case); `:ac` exercises "threshold irrelevant". Unset or
    // unparseable = no override, real IOKit read. Mirrors MENUBAR_LOAD_RUNNER_FORCE_UNAVAILABLE.
    private static let forcedBatteryState: (onBattery: Bool, percent: Double)? = {
        guard let raw = ProcessInfo.processInfo.environment["MENUBAR_LOAD_RUNNER_FORCE_BATTERY"],
              !raw.isEmpty else { return nil }
        let parts = raw.lowercased().split(separator: ":", omittingEmptySubsequences: false)
        guard let percent = Double(parts[0].trimmingCharacters(in: .whitespaces)),
              percent >= 0, percent <= Tuning.percentScale else { return nil }
        let onBattery = parts.count < 2 || parts[1].trimmingCharacters(in: .whitespaces) != "ac"
        return (onBattery: onBattery, percent: percent)
    }()

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
        // The adjacent label wears the same tint on the same condition, so it recolors here rather than
        // waiting for the next 2s tick (see updateValueLabel).
        updateValueLabel()
        guard let bar = keepAwakeBar, let host = animationView?.layer else { return }
        // Keyed on the MACHINE being held, not just on our own child, so a bare `caffeinate` in a terminal
        // lights the line too — the whole point of R16, and the half of it that works without opening the
        // menu. A foreign-only hold draws the same line at reduced alpha (see keepAwakeBarForeignAlpha):
        // held is held, but only our own is ours to turn off.
        let hold = awakeHold
        bar.isHidden = !hold.isHeld
        guard !bar.isHidden else { return }
        // No implicit position/size animation — the bar should snap, not slide, on resize.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let thickness = Tuning.keepAwakeBarThickness
        bar.frame = CGRect(x: 0, y: 0, width: host.bounds.width, height: thickness)  // bottom edge
        bar.backgroundColor = keepAwakeTintColor(
            for: hold, appearance: statusItem.button?.effectiveAppearance)?.cgColor
        CATransaction.commit()
    }

    // The tint the bar and the label wear, or nil when nothing holds sleep. Our own hold gets the full
    // tone; a foreign-only hold gets it faded. One function so the two surfaces cannot disagree — they
    // read as a single indicator, and a bar that says "held" beside a label that says "not" is worse than
    // either alone.
    // `appearance` is the CALLER's button, not a shared one: the tint has per-appearance tones, and while
    // two adjacent status items will practically always resolve the same appearance, resolving each
    // against its own is free and removes the assumption.
    private func keepAwakeTintColor(for hold: AwakeHold, appearance: NSAppearance?) -> NSColor? {
        guard hold.isHeld else { return nil }
        let base = activeKeepAwakeColor.color(for: appearance)
        guard !hold.ownRunning else { return base }
        return base.withAlphaComponent(Tuning.keepAwakeBarForeignAlpha)
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
