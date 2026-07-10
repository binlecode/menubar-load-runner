// Reader correctness check — mirrors the actual load-source readers in MenuBarLoadRunner.swift across
// all five sources and asserts each value is in range and sane. Percentage readers (CPU counter-delta;
// memory used-fraction; GPU utilization) are natural 0..1. Rate readers (network + disk throughput,
// memory swap rate) are counter-deltas over real elapsed time, normalized by the btop-style adaptive
// scaler seed (ceiling = max(rate*headroom, floor)). On a quiet machine NET/DISK/SWAP may read 0 B/s
// and normalize to 0 — expected, not a failure. GPU/NET/DISK "unavailable" (nil) is also not a failure.
// Exits 0 if every in-range invariant holds, 1 otherwise.  Run:
//   swiftc tests/readers.swift -o tmp/readers && ./tmp/readers
import Darwin; import Foundation; import IOKit

var ok = true
func inv(_ label: String, _ pass: Bool) { if !pass { ok = false }; print("  \(pass ? "PASS" : "FAIL") [\(label)]") }
func norm(_ rate: Double, _ floor: Double) -> (load: Double, ceil: Double) { let c = max(rate * 1.3, floor); return (min(rate / c, 1), c) }

func ticks() -> (UInt64, UInt64)? {
    var n: natural_t = 0; var i: processor_info_array_t?; var c: mach_msg_type_number_t = 0
    guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &n, &i, &c) == KERN_SUCCESS, let i else { return nil }
    defer { vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: i)), vm_size_t(c) * vm_size_t(MemoryLayout<integer_t>.size)) }
    var t: UInt64 = 0; var d: UInt64 = 0; let s = Int(CPU_STATE_MAX)
    for k in 0..<Int(n) { let b = k * s; t += UInt64(i[b+Int(CPU_STATE_USER)]) + UInt64(i[b+Int(CPU_STATE_SYSTEM)]) + UInt64(i[b+Int(CPU_STATE_NICE)]) + UInt64(i[b+Int(CPU_STATE_IDLE)]); d += UInt64(i[b+Int(CPU_STATE_IDLE)]) }
    return (t, d)
}
let a = ticks()!; usleep(300000); let b = ticks()!
let f = Double((b.0 - a.0) - (b.1 - a.1)) / Double(b.0 - a.0)
print(String(format: "CPU %.3f", f)); inv("CPU in [0,1]", f >= 0 && f <= 1)

func mem() -> (used: Double, swapBytes: UInt64) {
    var st = vm_statistics64_data_t(); var c = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
    _ = withUnsafeMutablePointer(to: &st) { p in p.withMemoryRebound(to: integer_t.self, capacity: Int(c)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &c) } }
    var ps: vm_size_t = 0; _ = host_page_size(mach_host_self(), &ps)
    let tot = Double(ProcessInfo.processInfo.physicalMemory)
    let av = (Double(st.free_count) + Double(st.purgeable_count) + Double(st.external_page_count)) * Double(ps)
    let u = min(max(1.0 - av / tot, 0), 1)
    let sw = (UInt64(max(0, st.swapins)) &+ UInt64(max(0, st.swapouts))) &* UInt64(ps)
    return (u, sw)
}
func gpu() -> Double? {
    for cls in ["IOAccelerator", "AGXAccelerator"] { guard let m = IOServiceMatching(cls) else { continue }; var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, m, &it) == KERN_SUCCESS else { continue }; defer { IOObjectRelease(it) }; var best: Double?; var e = IOIteratorNext(it)
        while e != 0 { defer { IOObjectRelease(e); e = IOIteratorNext(it) }; guard let p = IORegistryEntryCreateCFProperty(e, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0), let s = p.takeRetainedValue() as? [String: Any], let pct = (s["Device Utilization %"] as? NSNumber)?.doubleValue else { continue }; best = max(best ?? 0, min(max(pct/100, 0), 1)) }; if let best { return best } }
    return nil
}
func net() -> UInt64? {
    var p: UnsafeMutablePointer<ifaddrs>?; guard getifaddrs(&p) == 0, let f = p else { return nil }; defer { freeifaddrs(p) }; var t: UInt64 = 0; var c: UnsafeMutablePointer<ifaddrs>? = f
    while let x = c { defer { c = x.pointee.ifa_next }; guard let ad = x.pointee.ifa_addr, ad.pointee.sa_family == UInt8(AF_LINK) else { continue }; if String(cString: x.pointee.ifa_name) == "lo0" { continue }; guard let dp = x.pointee.ifa_data else { continue }; let d = dp.assumingMemoryBound(to: if_data.self).pointee; t &+= UInt64(d.ifi_ibytes) &+ UInt64(d.ifi_obytes) }; return t
}
func disk() -> UInt64? {
    guard let m = IOServiceMatching("IOBlockStorageDriver") else { return nil }; var it: io_iterator_t = 0; guard IOServiceGetMatchingServices(kIOMainPortDefault, m, &it) == KERN_SUCCESS else { return nil }; defer { IOObjectRelease(it) }; var t: UInt64 = 0; var fnd = false; var e = IOIteratorNext(it)
    while e != 0 { defer { IOObjectRelease(e); e = IOIteratorNext(it) }; guard let p = IORegistryEntryCreateCFProperty(e, "Statistics" as CFString, kCFAllocatorDefault, 0), let s = p.takeRetainedValue() as? [String: Any] else { continue }; t &+= ((s["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0) &+ ((s["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0); fnd = true }; return fnd ? t : nil
}

let m0 = mem(); let n0 = net(); let d0 = disk(); let t0 = ProcessInfo.processInfo.systemUptime; usleep(500000)
let m1 = mem(); let n1 = net(); let d1 = disk(); let dt = ProcessInfo.processInfo.systemUptime - t0
print(String(format: "MEM %.3f", m1.used)); inv("MEM in [0,1]", m1.used >= 0 && m1.used <= 1)
let srate = Double(m1.swapBytes >= m0.swapBytes ? m1.swapBytes - m0.swapBytes : 0) / dt
let sw = norm(srate, 1 * 1_048_576.0)
let comp = max(m1.used, sw.load)
print(String(format: "SWAP-RATE %.0f B/s load=%.3f", srate, sw.load)); inv("SWAP load in [0,1] & ceil>=floor", sw.load >= 0 && sw.load <= 1 && sw.ceil >= 1_048_576.0)
print(String(format: "COMPOSITE %.3f", comp)); inv("COMPOSITE in [0,1] & >= used", comp >= 0 && comp <= 1 && comp >= m1.used - 1e-9)
if let g = gpu() { print(String(format: "GPU %.3f", g)); inv("GPU in [0,1]", g >= 0 && g <= 1) } else { print("GPU: unavailable (nil) — OK") }
if let a = n0, let b = n1 { let r = Double(b >= a ? b - a : 0) / dt; let x = norm(r, 1 * 1_048_576.0); print(String(format: "NET %.0f B/s load=%.3f", r, x.load)); inv("NET load in [0,1] & ceil>=floor", x.load >= 0 && x.load <= 1 && x.ceil >= 1_048_576.0) } else { print("NET: unavailable — OK") }
if let a = d0, let b = d1 { let r = Double(b >= a ? b - a : 0) / dt; let x = norm(r, 4 * 1_048_576.0); print(String(format: "DISK %.0f B/s load=%.3f", r, x.load)); inv("DISK load in [0,1] & ceil>=floor", x.load >= 0 && x.load <= 1 && x.ceil >= 4 * 1_048_576.0) } else { print("DISK: unavailable — OK") }

print("readers: \(ok ? "all invariants hold" : "FAILURES above")"); exit(ok ? 0 : 1)
