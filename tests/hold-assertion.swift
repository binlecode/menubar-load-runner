// Test fixture for the "Other Assertions" section (R13) and the machine-state row (R16):
//
//   mblr-assert-probe <seconds> [--display] [--timeout <secs>]
//       hold one real sleep assertion, then release it and exit 0
//
//   --display   hold PreventUserIdleDisplaySleep instead of the idle/system type. The two are not
//               interchangeable: idle-alone is what makes the machine-state row say "may still sleep",
//               and only a DISPLAY hold reads as held awake (see Tuning.assertionDisplaySleepTypes).
//   --timeout   attach a real assertion timeout, so the row's "until <clock>" has something to render.
//               Distinct from <seconds>, which is just how long this process lives: the timeout is what
//               the app READS out of the assertion dictionary, and reading it wrong is a live trap (see
//               SleepAssertionMonitor.deadline(from:) — AssertTimeoutTimeLeft is stale, not live).
//
// Why hold one here instead of just running `caffeinate -i -t N`? Because a row is keyed on owner+type,
// and any machine may already have a caffeinate holding one (an agent's renewal loop, another user's
// MenuBar Load Runner, the developer's own instance) — so a `caffeinate` row proves nothing about
// detection, and its presence after expiry proves nothing about the retention window. This binary's name
// is its own row, so both become deterministic. It also exercises the real API rather than a mock of it.
//
// It deliberately does NOT count assertions from outside for comparison: doing that to check the app
// excludes its own child is a race on any machine with a renewal loop (the foreign total drifts mid-run),
// which is how that case first failed. The app reports `own=N` for exactly this reason — see qa.sh §3d.
import Foundation
import IOKit
import IOKit.pwr_mgt

// Must match one of Tuning.assertionSleepTypes or the app filters this fixture out. The
// kIOPMAssertionType* constants — and the property keys below — are CFSTR macros, invisible to Swift;
// the literals ARE the wire format, which is also what `pmset -g assertions` prints.
let args = Array(CommandLine.arguments.dropFirst())
let sleepType = args.contains("--display") ? "PreventUserIdleDisplaySleep" : "PreventUserIdleSystemSleep"
let timeout: Double? = args.firstIndex(of: "--timeout").flatMap { i in
    args.count > i + 1 ? Double(args[i + 1]) : nil
}

let seconds = Double(args.first { !$0.hasPrefix("--") } ?? "3") ?? 3
var assertionID: IOPMAssertionID = 0
// CreateWithProperties only when a timeout is asked for — CreateWithName is the simpler call and stays
// the path the pre-existing cases exercise.
let rc: IOReturn = {
    guard let timeout else {
        return IOPMAssertionCreateWithName(
            sleepType as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "MenuBar Load Runner test fixture" as CFString,
            &assertionID
        )
    }
    let properties: [String: Any] = [
        "AssertType": sleepType,
        "AssertName": "MenuBar Load Runner test fixture",
        "TimeoutSeconds": timeout,
        "TimeoutAction": "TimeoutActionRelease",
    ]
    return IOPMAssertionCreateWithProperties(properties as CFDictionary, &assertionID)
}()
guard rc == kIOReturnSuccess else {
    FileHandle.standardError.write("IOPMAssertionCreateWithName failed: \(rc)\n".data(using: .utf8)!)
    exit(1)
}
Thread.sleep(forTimeInterval: seconds)
IOPMAssertionRelease(assertionID)
