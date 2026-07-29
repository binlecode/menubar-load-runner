// Menu-bar label width check — mirrors MenuBarLoadRunner.swift's `labelField` / `percentField` /
// `rateField` / `diskField` / `labelWidthTemplate` and `labelFont`. The app reserves the label slot's
// width from a per-shape template and holds it there, so the reading MUST measure the same at every
// value; if it doesn't, the slot resumes tracking the text and the animation next to it jitters twice a
// second — the bug this design exists to remove, and one nothing else can catch (item order and
// sub-point drift are invisible to menu-dump, the readers, and any screenshot diff).
//
// Uses real AppKit font metrics, which a CLI tool can do without a GUI. Keep in sync with the real
// functions; a mismatch = the port drifted.
// Exits 0 if all checks pass, 1 otherwise.  Run:  swiftc tests/label.swift -o tmp/label && ./tmp/label
import AppKit

// --- port -------------------------------------------------------------------
let percentScale = 100.0
let bytesPerMiB = 1_048_576.0
let rateCeiling = 999.9
let diskCeiling = 9999.0

let labelFont = NSFont.monospacedDigitSystemFont(
    ofSize: NSFont.menuBarFont(ofSize: 0).pointSize,
    weight: .regular
)

func labelField(_ value: Double, decimals: Int, ceiling: Double) -> String {
    let format = "%.\(decimals)f"
    let text = String(format: format, value)
    let width = String(format: format, ceiling).count
    return String(repeating: "\u{2007}", count: max(0, width - text.count)) + text
}

func percentField(_ fraction: Double) -> String {
    labelField(fraction * percentScale, decimals: 0, ceiling: percentScale)
}
func rateField(_ bytesPerSec: Double) -> String {
    labelField(bytesPerSec / bytesPerMiB, decimals: 1, ceiling: rateCeiling)
}
func diskField(_ bytesPerSec: Double) -> String {
    labelField(bytesPerSec / bytesPerMiB, decimals: 0, ceiling: diskCeiling)
}

// The whole reading, per shape — prose included, since that is what actually gets measured.
func percentReading(_ tag: String, _ fraction: Double) -> String { "\(tag) \(percentField(fraction))%" }
func netReading(_ inBps: Double, _ outBps: Double) -> String { "NET ↓\(rateField(inBps)) ↑\(rateField(outBps))" }
func diskReading(_ rBps: Double, _ wBps: Double) -> String { "DSK R\(diskField(rBps)) W\(diskField(wBps))" }

func width(_ text: String) -> CGFloat {
    (text as NSString).size(withAttributes: [.font: labelFont]).width
}

// --- harness ----------------------------------------------------------------
var pass = 0, fail = 0
func check(_ name: String, _ ok: Bool) {
    ok ? (pass += 1) : (fail += 1)
    print("  \(ok ? "PASS" : "FAIL") [\(name)]")
}

// Every reading in the list must measure identically, and match the template the app reserves from.
func checkConstantWidth(_ name: String, template: String, readings: [String]) {
    let target = width(template)
    let offenders = readings.filter { abs(width($0) - target) > 0.01 }
    check(name, offenders.isEmpty)
    if let worst = offenders.first {
        print("       template \"\(template)\" = \(target)pt, but \"\(worst)\" = \(width(worst))pt")
    }
}

// --- the premise the design rests on ---------------------------------------
// U+2007 FIGURE SPACE is defined to be as wide as a digit. If that ever stops holding in the menu-bar
// font, every fixed-width claim below collapses — so assert it directly rather than inferring it.
check("figure space == digit width", abs(width("\u{2007}") - width("0")) < 0.01)
check("normal space != digit width (why %3.0f padding won't do)", width(" ") < width("0") - 1)
check("monospaced digits: 111 and 888 measure alike", abs(width("111") - width("888")) < 0.01)
check("proportional font would NOT do", {
    let menuBar = NSFont.menuBarFont(ofSize: 0)
    let w: (String) -> CGFloat = { ($0 as NSString).size(withAttributes: [.font: menuBar]).width }
    return abs(w("111") - w("888")) > 0.01 || abs(w("\u{2007}") - w("0")) > 0.01
}())

// --- percent shapes (cpu / memory / gpu / fan / battery) --------------------
for tag in ["CPU", "MEM", "GPU", "FAN", "BAT"] {
    let fractions = [0, 0.04, 0.09, 0.1, 0.47, 0.5, 0.99, 0.995, 1.0]
    checkConstantWidth(
        "\(tag) constant width across 0–100%",
        template: percentReading(tag, 1),
        readings: fractions.map { percentReading(tag, $0) }
    )
}

// --- network (one decimal, ceiling 999.9 MB/s) -----------------------------
let netRates = [0, 0.04, 0.1, 3.4, 9.9, 12.3, 99.9, 123.4, 999.9].map { $0 * bytesPerMiB }
checkConstantWidth(
    "NET constant width across 0–999.9 MB/s",
    template: netReading(rateCeiling * bytesPerMiB, rateCeiling * bytesPerMiB),
    readings: netRates.flatMap { r in netRates.map { netReading(r, $0) } }
)

// --- disk (whole MB/s, ceiling 9999) ---------------------------------------
let diskRates = [0, 0.4, 4, 12, 99, 512, 3200, 9999].map { $0 * bytesPerMiB }
checkConstantWidth(
    "DSK constant width across 0–9999 MB/s",
    template: diskReading(diskCeiling * bytesPerMiB, diskCeiling * bytesPerMiB),
    readings: diskRates.flatMap { r in diskRates.map { diskReading(r, $0) } }
)

// --- the deliberate exception ----------------------------------------------
// Past its ceiling a field formats WIDER than the reservation rather than being cut off; the app's
// labelSlotWidth() takes max(template, text) so the slot widens for that tick. Assert the overflow is
// real (i.e. that max() is load-bearing and not dead code).
let burst = netReading(1500 * bytesPerMiB, 0.1 * bytesPerMiB)
check("a rate past the ceiling overflows the reservation (max() is load-bearing)",
      width(burst) > width(netReading(rateCeiling * bytesPerMiB, rateCeiling * bytesPerMiB)))

// --- accessibility ---------------------------------------------------------
// The app hands VoiceOver the reading with the padding stripped. Lossless because all padding is
// leading-within-a-field: removing it must yield exactly the unpadded reading.
check("stripping U+2007 yields the plain reading",
      percentReading("CPU", 0.47).replacingOccurrences(of: "\u{2007}", with: "") == "CPU 47%")
check("stripping U+2007 yields the plain reading (rates)",
      netReading(3.4 * bytesPerMiB, 0.1 * bytesPerMiB)
        .replacingOccurrences(of: "\u{2007}", with: "") == "NET ↓3.4 ↑0.1")

// --- the slot is wide enough for what goes in it ---------------------------
// Sanity on the padding constant: the reserved slot must never be narrower than the text it holds.
// 4pt matches what AppKit's own auto-sizing leaves around a status-item title (see Tuning).
let slotPadding: CGFloat = 4
for reading in ["MEM 100%", netReading(999.9 * bytesPerMiB, 999.9 * bytesPerMiB), "BUILD BOX 24 CHARS OK!!!"] {
    check("slot fits \"\(reading.prefix(12))…\"", ceil(width(reading)) + slotPadding > width(reading))
}

print("label: passes=\(pass) fails=\(fail)")
exit(fail == 0 ? 0 : 1)
