// Test fixture for the "Other Assertions" section (R13):
//
//   mblr-assert-probe <seconds>   hold one real sleep assertion, then release it and exit 0
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
// kIOPMAssertionType* constants are CFSTR macros, invisible to Swift; the literal is the wire format.
let sleepType = "PreventUserIdleSystemSleep"

let seconds = Double(CommandLine.arguments.dropFirst().first ?? "3") ?? 3
var assertionID: IOPMAssertionID = 0
let rc = IOPMAssertionCreateWithName(
    sleepType as CFString,
    IOPMAssertionLevel(kIOPMAssertionLevelOn),
    "MenuBar Load Runner test fixture" as CFString,
    &assertionID
)
guard rc == kIOReturnSuccess else {
    FileHandle.standardError.write("IOPMAssertionCreateWithName failed: \(rc)\n".data(using: .utf8)!)
    exit(1)
}
Thread.sleep(forTimeInterval: seconds)
IOPMAssertionRelease(assertionID)
