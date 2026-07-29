// Restart-after-update check — mirrors MenuBarLoadRunner.swift `Restarter`: the launch-mode mapping,
// the `launchctl list` PID parse, the restart command per mode, and the argv that reproduces the
// running configuration. All pure, NO subprocesses and no launchd job, so it runs anywhere. Keep in
// sync with the real type; a mismatch = the port drifted. Exits 0 if all checks pass, 1 otherwise.
// Run:  swiftc tests/restart.swift -o tmp/restart && ./tmp/restart
import Foundation

enum Mode: Equatable {
    case launchAgent
    case launcher(path: String)
    case unsupported
}

let launchAgentLabel = "ai.bera.menubarloadrunner"

func mode(environment: [String: String], isLaunchAgentJob: Bool) -> Mode {
    if isLaunchAgentJob { return .launchAgent }
    guard environment["MENUBAR_LOAD_RUNNER_LAUNCH_MODE"] == "detached",
          let launcher = environment["MENUBAR_LOAD_RUNNER_LAUNCHER"], !launcher.isEmpty else {
        return .unsupported
    }
    return .launcher(path: launcher)
}

func reportedPID(inLaunchctlList text: String) -> Int32? {
    for line in text.split(whereSeparator: \.isNewline) where line.contains("\"PID\"") {
        let digits = line.filter(\.isNumber)
        return digits.isEmpty ? nil : Int32(digits)
    }
    return nil
}

func restartCommand(mode: Mode, appArguments: [String], uid: uid_t) -> [String]? {
    switch mode {
    case .launchAgent:
        return ["/bin/launchctl", "kickstart", "gui/\(uid)/\(launchAgentLabel)"]
    case .launcher(let path):
        return [path] + appArguments
    case .unsupported:
        return nil
    }
}

func appArguments(
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

var pass = 0, fail = 0
func check(_ n: String, _ c: Bool) { c ? (pass += 1) : (fail += 1); print("  \(c ? "PASS" : "FAIL") [\(n)]") }

// --- Launch-mode mapping ---------------------------------------------------
let detachedEnv = ["MENUBAR_LOAD_RUNNER_LAUNCH_MODE": "detached",
                   "MENUBAR_LOAD_RUNNER_LAUNCHER": "/Users/x/.local/share/menubar-load-runner/menubar-load-runner"]
check("detached launcher -> .launcher",
      mode(environment: detachedEnv, isLaunchAgentJob: false)
        == .launcher(path: "/Users/x/.local/share/menubar-load-runner/menubar-load-runner"))
// The agent's plist runs the launcher with --no-detach, so the env says "attached" — launchd's own
// answer has to win over the env, or a login-item run would be read as unsupported.
check("launchd job wins over attached env",
      mode(environment: ["MENUBAR_LOAD_RUNNER_LAUNCH_MODE": "attached"], isLaunchAgentJob: true) == .launchAgent)
check("launchd job wins over detached env",
      mode(environment: detachedEnv, isLaunchAgentJob: true) == .launchAgent)
check("--foreground (attached, not launchd) -> unsupported",
      mode(environment: ["MENUBAR_LOAD_RUNNER_LAUNCH_MODE": "attached",
                         "MENUBAR_LOAD_RUNNER_LAUNCHER": "/x/menubar-load-runner"],
           isLaunchAgentJob: false) == .unsupported)
check("raw binary (no markers) -> unsupported", mode(environment: [:], isLaunchAgentJob: false) == .unsupported)
check("detached but no launcher path -> unsupported",
      mode(environment: ["MENUBAR_LOAD_RUNNER_LAUNCH_MODE": "detached"], isLaunchAgentJob: false) == .unsupported)
check("detached with empty launcher path -> unsupported",
      mode(environment: ["MENUBAR_LOAD_RUNNER_LAUNCH_MODE": "detached", "MENUBAR_LOAD_RUNNER_LAUNCHER": ""],
           isLaunchAgentJob: false) == .unsupported)

// --- `launchctl list <label>` PID parse (real output shape) ----------------
check("parses PID line", reportedPID(inLaunchctlList: "{\n\t\"Label\" = \"x\";\n\t\"PID\" = 64345;\n}") == 64345)
check("loaded-but-idle job (no PID line) -> nil",
      reportedPID(inLaunchctlList: "{\n\t\"Label\" = \"x\";\n\t\"LastExitStatus\" = 0;\n}") == nil)
check("empty output -> nil", reportedPID(inLaunchctlList: "") == nil)

// --- Restart command per mode ---------------------------------------------
check("agent -> kickstart without -k (no SIGKILL mid-quit)",
      restartCommand(mode: .launchAgent, appArguments: ["horse-white"], uid: 501)
        == ["/bin/launchctl", "kickstart", "gui/501/ai.bera.menubarloadrunner"])
check("launcher -> script + args",
      restartCommand(mode: .launcher(path: "/x/menubar-load-runner"), appArguments: ["dog-black", "--label", "off"], uid: 501)
        == ["/x/menubar-load-runner", "dog-black", "--label", "off"])
check("unsupported -> no command",
      restartCommand(mode: .unsupported, appArguments: ["horse-white"], uid: 501) == nil)

// --- argv reproduces the RUNNING configuration ----------------------------
check("menu-chosen preset + source + label survive",
      appArguments(presetOrPath: "dog-black", loadSourceKey: "gpu", labelArgument: "value",
                   batteryThresholdPercent: 20, speedMultiplierOverride: nil,
                   showAllSources: false, keepAwakeIndefinite: false)
        == ["dog-black", "--load-source", "gpu", "--label", "value", "--battery-threshold", "20"])
check("threshold 0 renders as off (never release on charge alone)",
      appArguments(presetOrPath: "horse-white", loadSourceKey: "cpu", labelArgument: "off",
                   batteryThresholdPercent: 0, speedMultiplierOverride: nil,
                   showAllSources: false, keepAwakeIndefinite: false)
        .contains(where: { $0 == "off" }))
check("fixed speed carries (auto would silently take over without it)",
      appArguments(presetOrPath: "horse-white", loadSourceKey: "cpu", labelArgument: "off",
                   batteryThresholdPercent: 20, speedMultiplierOverride: 1.5,
                   showAllSources: false, keepAwakeIndefinite: false)
        .joined(separator: " ").contains("--speed-multiplier 1.5"))
check("auto speed passes no multiplier",
      !appArguments(presetOrPath: "horse-white", loadSourceKey: "cpu", labelArgument: "off",
                    batteryThresholdPercent: 20, speedMultiplierOverride: nil,
                    showAllSources: false, keepAwakeIndefinite: false)
        .contains("--speed-multiplier"))
check("expanded Other Sources carries",
      appArguments(presetOrPath: "horse-white", loadSourceKey: "cpu", labelArgument: "off",
                   batteryThresholdPercent: 20, speedMultiplierOverride: nil,
                   showAllSources: true, keepAwakeIndefinite: false)
        .contains("--show-all-sources"))
// A bounded window restores from the state file's deadline, so passing a flag would be wrong (the
// flag re-arms a LENGTH); only the indefinite case, which the restore path refuses, needs one.
check("indefinite Keep Awake passes --keep-awake on",
      appArguments(presetOrPath: "horse-white", loadSourceKey: "cpu", labelArgument: "off",
                   batteryThresholdPercent: 20, speedMultiplierOverride: nil,
                   showAllSources: false, keepAwakeIndefinite: true)
        .joined(separator: " ").hasSuffix("--keep-awake on"))
check("bounded/off Keep Awake passes no flag (deadline restores from state)",
      !appArguments(presetOrPath: "horse-white", loadSourceKey: "cpu", labelArgument: "off",
                    batteryThresholdPercent: 20, speedMultiplierOverride: nil,
                    showAllSources: false, keepAwakeIndefinite: false)
        .contains("--keep-awake"))
// A custom GIF path takes the positional slot exactly as a preset keyword does.
check("custom GIF path is the positional arg",
      appArguments(presetOrPath: "/Users/x/my cat.gif", loadSourceKey: "cpu", labelArgument: "off",
                   batteryThresholdPercent: 20, speedMultiplierOverride: nil,
                   showAllSources: false, keepAwakeIndefinite: false)
        .first == "/Users/x/my cat.gif")
check("empty preset omits the positional arg",
      appArguments(presetOrPath: "", loadSourceKey: "cpu", labelArgument: "off",
                   batteryThresholdPercent: 20, speedMultiplierOverride: nil,
                   showAllSources: false, keepAwakeIndefinite: false)
        .first == "--load-source")

print("restart: passes=\(pass) fails=\(fail)"); exit(fail == 0 ? 0 : 1)
