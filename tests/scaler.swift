// Adaptive-scaler behavior check — mirrors MenuBarLoadRunner.swift `ThroughputScaler` + the
// `Tuning.scaler*` constants (window 5, rescale 5, headroom 1.3↑/3.0↓). Drives synthetic byte-rate
// sequences through a faithful port and asserts the distinctive properties (seeding, hysteresis,
// asymmetric headroom, floor, range). Keep in sync with the real type; a mismatch = the port drifted.
// Exits 0 if all checks pass, 1 otherwise.  Run:  swiftc tests/scaler.swift -o tmp/scaler && ./tmp/scaler
import Foundation

struct Scaler {
    let floor: Double; var ceiling: Double; var seeded = false
    var recent: [Double] = []; var over = 0; var under = 0
    let window = 5, rescaleN = 5; let hUp = 1.3, hDown = 3.0
    init(_ f: Double) { floor = f; ceiling = f }
    mutating func normalize(_ speed: Double) -> Double {
        if !seeded { seeded = true; ceiling = max(speed * hUp, floor) }
        recent.append(speed); if recent.count > window { recent.removeFirst(recent.count - window) }
        if speed > ceiling { over += 1; if under > 0 { under -= 1 } }
        else if ceiling > floor, speed < ceiling / 10 { under += 1; if over > 0 { over -= 1 } }
        if over >= rescaleN { ceiling = max(avg() * hUp, floor); over = 0; under = 0 }
        else if under >= rescaleN { ceiling = max(avg() * hDown, floor); over = 0; under = 0 }
        return ceiling > 0 ? min(speed / ceiling, 1) : 0
    }
    func avg() -> Double { recent.isEmpty ? 0 : recent.reduce(0, +) / Double(recent.count) }
}

let MiB = 1_048_576.0, F = 1 * 1_048_576.0
var pass = 0, fail = 0
func check(_ n: String, _ c: Bool) { c ? (pass += 1) : (fail += 1); print("  \(c ? "PASS" : "FAIL") [\(n)]") }

var s1 = Scaler(F); let l0 = s1.normalize(10 * MiB)
check("seed not pegged (~0.77, <1.0)", l0 > 0.6 && l0 < 0.99)
var s2 = Scaler(F); var last = 0.0; for _ in 0..<20 { last = s2.normalize(10 * MiB) }
check("steady-state stable & in-range", last > 0.5 && last <= 1.0)
var s3 = Scaler(F); _ = s3.normalize(5 * MiB); let cB = s3.ceiling; _ = s3.normalize(100 * MiB)
check("lone spike does not rescale", s3.ceiling == cB)
var s4 = Scaler(F); _ = s4.normalize(5 * MiB); let c4 = s4.ceiling
var lHigh = 0.0; for _ in 0..<5 { lHigh = s4.normalize(100 * MiB) }
check("5 highs raise ceiling", s4.ceiling > c4)
check("adapted high-load dropped below 1.0", lHigh < 1.0)
var s5 = Scaler(F); _ = s5.normalize(5 * MiB); for _ in 0..<5 { _ = s5.normalize(100 * MiB) }
let cHigh = s5.ceiling; for _ in 0..<6 { _ = s5.normalize(2 * MiB) }
check("sustained lows drop ceiling", s5.ceiling < cHigh)
var s6 = Scaler(F); var z = true; for _ in 0..<10 { if s6.normalize(0) != 0 { z = false } }
check("zero input -> load 0, ceiling>=floor", z && s6.ceiling >= F)
var s7 = Scaler(F); var ok = true
for v in [0,1,50,3,3,3,200,200,200,200,200,0,0,7,7] as [Double] { let l = s7.normalize(v * MiB); if l < 0 || l > 1 { ok = false } }
check("all outputs in [0,1]", ok)
print("scaler: passes=\(pass) fails=\(fail)"); exit(fail == 0 ? 0 : 1)
