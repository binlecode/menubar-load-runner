# Runbook: QA a release

How to validate `MenuBarLoadRunner.swift` before shipping. There is no automated test suite, so
this is the manual gate. It exercises the whole lifecycle (launch → run → clean exit), every CLI /
env surface, all five load-source readers, the error paths (bad GIF *and* bad preset manifest), the
version surface, and the launcher wrapper. Copy-paste the blocks in order; each is self-scoring
(PASS/FAIL) or prints a value to eyeball.

Run everything from the repo root.

> **Executable harness.** Sections 1–6 below are also available as runnable scripts so you don't have
> to copy-paste:
> - `tests/qa.sh` — runs §1–5 (build, CLI parse + version, lifecycle, error paths, readers + scaler),
>   self-scoring, exit 0 only if all pass. Add `--launcher` to also run §6 (it stops running instances).
> - `tests/install-smoke.sh` — install/uninstall round-trip in a `tmp/` sandbox (never touches your
>   real `~/.local` / LaunchAgents).
> - `tests/readers.swift`, `tests/scaler.swift` — the §5 probes as standalone files.
>
> The inline blocks below remain the reference (and cover §7's manual spot-check, which can't be
> automated). Keep the scripts and these blocks in sync.

---

## 0. Testing affordances (read first)

These make a *blocking GUI menu-bar app* testable from a shell:

- **`MENUBAR_LOAD_RUNNER_EXIT_AFTER=<seconds>`** — the app self-terminates (exit 0) after N
  seconds instead of blocking `NSApplication.run()` forever. It **also suppresses modal alerts**
  (startup/runtime errors print to stderr instead of popping a dialog), so an automated run never
  wedges on — or pops — an `NSAlert`. This is *the* knob that removes the launch-then-`kill` dance.
- **`timeout <s> …`** — fallback auto-reaper when you can't set `EXIT_AFTER` (e.g. testing the
  modal path deliberately). Collapses background + sleep + `kill` into one line.
- **Raw binary vs launcher** — `tmp/mblr-check` (raw `swiftc` output) has **no singleton guard**;
  the guard lives in the `menubar-load-runner` launcher script. Prefer `EXIT_AFTER` so instances
  can't pile up; if you background raw instances, clean up with `pkill -f 'mblr-check'`.
- **`MENUBAR_LOAD_RUNNER_FORCE_UNAVAILABLE=gpu,network,disk`** — marks the listed load sources
  unavailable regardless of hardware, so the availability-disable + launch-fallback-to-cpu path (§3)
  is testable on a machine where every reader actually works. Comma-separated source keys; unset = no
  override.

### Gotchas that have bitten us

- `--foreground` / `--no-detach` / `--extra` are **launcher-only** flags. Passing them to the raw
  binary makes it treat them as a positional GIF path → decode failure → (previously) a modal
  **startup error box**. Only pass launcher flags to `./menubar-load-runner`, never to `tmp/mblr-check`.
- The startup/runtime error paths are **modal** (`NSAlert.runModal`) for real users — always drive
  them under `EXIT_AFTER` (suppressed) or `timeout` during QA, or a dialog pops on your screen and
  blocks the process.
- The memory used-fraction is a **deliberate approximation** (available = free + purgeable +
  external), so it reads higher than Activity Monitor's "memory used" and higher than
  `memory_pressure`'s "free %". A high number on a loaded/​swapping machine is expected, not a bug.

---

## 1. Build (must be warning-clean)

The launcher builds with `-strict-concurrency=complete`; the app is annotated `@MainActor`, so the
build must be **warning-free** (a warning today = a Swift 6 error tomorrow).

```bash
swiftc -O -strict-concurrency=complete MenuBarLoadRunner.swift -o tmp/mblr-check
# ^ any output at all = FAIL. Silence = pass.
```

## 2. CLI parse paths (should NOT launch the GUI)

```bash
BIN=./tmp/mblr-check; pass=0; fail=0
chk(){ [ "$2" = "$3" ] && { echo "  PASS [$1] rc=$3"; pass=$((pass+1)); } || { echo "  FAIL [$1] want $2 got $3"; fail=$((fail+1)); }; }
$BIN --help >/dev/null 2>&1;                    chk "--help" 0 $?
$BIN --width 2 >/dev/null 2>&1;                 chk "--width removed (rejected)" 1 $?
$BIN --speed-multiplier 0 >/dev/null 2>&1;      chk "--speed-multiplier 0" 1 $?
$BIN --speed-multiplier -2 >/dev/null 2>&1;     chk "--speed-multiplier neg" 1 $?
$BIN --overlay-text "" >/dev/null 2>&1;         chk "--overlay-text empty" 1 $?
$BIN --overlay-text THIRTEENCHARS >/dev/null 2>&1; chk "--overlay-text >12" 1 $?
$BIN --load-source >/dev/null 2>&1;             chk "--load-source no value" 1 $?
$BIN foo bar >/dev/null 2>&1;                   chk "extra positional" 1 $?
echo "parse: passes=$pass fails=$fail"
```

Version surface — `--help` must print the semver line (matches `AppInfo.version`, About dialog, and
the current `CHANGELOG.md` release):

```bash
VER=$(grep -Eo 'static let version = "[0-9]+\.[0-9]+\.[0-9]+"' MenuBarLoadRunner.swift | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+')
./tmp/mblr-check --help 2>&1 | grep -q "MenuBar Load Runner $VER" \
  && echo "  PASS --help shows version $VER" || echo "  FAIL --help missing version $VER"
grep -q "## \[$VER\]" CHANGELOG.md && echo "  PASS CHANGELOG has [$VER] section" || echo "  FAIL CHANGELOG missing [$VER]"
```

## 3. Full launch lifecycle (EXIT_AFTER → clean exit 0, no unexpected stderr)

Covers both load sources, auto & fixed speed, overlay, a wide (high-aspect) preset, a custom path,
and both env vars. Each run must exit 0 with stderr containing only the expected lines.

```bash
BIN=./tmp/mblr-check; GIF="$PWD/gifs/totoro.gif"; pass=0; fail=0
run(){ desc="$1"; allow="$2"; shift 2
  err=$(MENUBAR_LOAD_RUNNER_EXIT_AFTER=2 "$@" 2>&1 >/dev/null); rc=$?
  un=$(echo "$err" | grep -v 'MENUBAR_LOAD_RUNNER_EXIT_AFTER=' | { [ -n "$allow" ] && grep -v "$allow" || cat; } | grep -v '^$')
  [ "$rc" = 0 ] && [ -z "$un" ] && { echo "  PASS [$desc]"; pass=$((pass+1)); } || { echo "  FAIL [$desc] rc=$rc <<$un>>"; fail=$((fail+1)); }; }
run "default cpu/auto"        "" $BIN
run "load-source memory"      "" $BIN --load-source memory
run "load-source cpu"         "" $BIN --load-source cpu
run "load-source gpu"         "" $BIN --load-source gpu
run "load-source network"     "" $BIN --load-source network
run "load-source disk"        "" $BIN --load-source disk
run "load-source bogus"       "Unknown --load-source" $BIN --load-source bogus
run "force-unavail gpu->cpu"  "unavailable on this machine" env MENUBAR_LOAD_RUNNER_FORCE_UNAVAILABLE=gpu $BIN --load-source gpu
run "force-unavail net(env)"  "unavailable on this machine" env MENUBAR_LOAD_RUNNER_FORCE_UNAVAILABLE=network,disk MENUBAR_LOAD_RUNNER_LOAD_SOURCE=network $BIN
run "force-unavail, other src" "" env MENUBAR_LOAD_RUNNER_FORCE_UNAVAILABLE=gpu $BIN --load-source disk
run "fixed speed"             "" $BIN --speed-multiplier 1.5
run "fixed + memory"          "" $BIN --speed-multiplier 1.5 --load-source memory
run "overlay + gpu"           "" $BIN --overlay-text GPU --load-source gpu
run "wide preset + overlay"   "" $BIN totoro-group-white --overlay-text NET --load-source network
run "totoro-group + disk"     "" $BIN totoro-group-white --load-source disk
run "custom path + memory"    "" $BIN "$GIF" --load-source memory
run "env LOAD_SOURCE"         "" env MENUBAR_LOAD_RUNNER_LOAD_SOURCE=network $BIN
run "env PATH=<gif>"          "" env MENUBAR_LOAD_RUNNER_PATH="$GIF" $BIN --load-source disk
echo "lifecycle: passes=$pass fails=$fail"
```

## 4. Error paths (must exit fast, NO modal box)

Under `EXIT_AFTER`, a fatal condition must print to stderr and terminate immediately (not hang, not
pop a dialog). If either case hangs or a box appears, the modal-suppression regressed. Two distinct
fatal paths: a bad GIF (decode failure) and a missing/invalid preset manifest (startup error).

**4a. Bad GIF path**

```bash
t0=$SECONDS
err=$(MENUBAR_LOAD_RUNNER_EXIT_AFTER=5 ./tmp/mblr-check /no/such/file.gif 2>&1 >/dev/null); rc=$?
echo "rc=$rc elapsed=$((SECONDS-t0))s (want rc=0, near-instant, NOT ~5s)"
echo "$err" | grep -q "GIF file not found" && echo "  PASS error printed" || echo "  FAIL no error msg"
pgrep -fl mblr-check || echo "  PASS no lingering process / no box"
```

**4b. Missing/invalid preset manifest** — `gifs/presets.json` is the source of truth for built-in
presets; a missing or corrupt manifest must surface `startupError` and quit cleanly (not `fatalError`,
not a hang). Temporarily moves the manifest aside and restores it.

```bash
mv gifs/presets.json gifs/presets.json.bak
t0=$SECONDS
err=$(MENUBAR_LOAD_RUNNER_EXIT_AFTER=5 ./tmp/mblr-check 2>&1 >/dev/null); rc=$?
mv gifs/presets.json.bak gifs/presets.json
echo "rc=$rc elapsed=$((SECONDS-t0))s (want rc=0, near-instant, NOT ~5s)"
echo "$err" | grep -q "Could not load preset manifest" && echo "  PASS manifest error printed" || echo "  FAIL no manifest error"
[ -f gifs/presets.json ] && echo "  PASS manifest restored" || echo "  FAIL manifest NOT restored — restore from git!"
```

## 5. Reader correctness (values in range, and sane)

Mirrors the actual readers across all five sources. **Percentage readers** (CPU counter-delta; memory
used-fraction instantaneous; GPU `Device Utilization %` instantaneous) are natural 0..1 and asserted in
range directly. **Rate readers** (network + disk throughput, and the memory **swap rate**) are
counter-deltas divided by real elapsed `systemUptime`, then normalized by the **btop-style adaptive
scaler** (ceiling = `max(avg(recent) × headroom, floor)`; for a single two-sample check the ceiling
seeds to `max(rate × 1.3, floor)`, so a non-zero rate normalizes to ≈0.77 and a zero rate to 0). On a
quiet machine `SWAP-RATE`/`NET`/`DISK` may read `0 B/s` and normalize to `0` — expected, not a failure;
the invariants (every normalized load in [0,1], `ceiling ≥ floor`, memory composite ≥ used-fraction) are
what must hold. To see non-zero rates: `memory_pressure -l` (swap), a download (net), or
`dd if=/dev/zero of=tmp/x bs=1m count=500` (disk), then re-run.

```bash
cat > tmp/rcheck.swift <<'EOF'
import Darwin; import Foundation; import IOKit
// Adaptive scaler seed for a single two-sample check: ceiling = max(rate*headroomUp, floor).
func norm(_ rate:Double,_ floor:Double)->(load:Double,ceil:Double){let c=max(rate*1.3,floor);return (min(rate/c,1),c)}
func ticks()->(UInt64,UInt64)?{var n:natural_t=0;var i:processor_info_array_t?;var c:mach_msg_type_number_t=0
 guard host_processor_info(mach_host_self(),PROCESSOR_CPU_LOAD_INFO,&n,&i,&c)==KERN_SUCCESS,let i else{return nil}
 defer{vm_deallocate(mach_task_self_,vm_address_t(UInt(bitPattern:i)),vm_size_t(c)*vm_size_t(MemoryLayout<integer_t>.size))}
 var t:UInt64=0;var d:UInt64=0;let s=Int(CPU_STATE_MAX)
 for k in 0..<Int(n){let b=k*s;t+=UInt64(i[b+Int(CPU_STATE_USER)])+UInt64(i[b+Int(CPU_STATE_SYSTEM)])+UInt64(i[b+Int(CPU_STATE_NICE)])+UInt64(i[b+Int(CPU_STATE_IDLE)]);d+=UInt64(i[b+Int(CPU_STATE_IDLE)])}
 return (t,d)}
let a=ticks()!;usleep(300000);let b=ticks()!;let f=Double((b.0-a.0)-(b.1-a.1))/Double(b.0-a.0)
print(String(format:"CPU %.3f in[0,1]:%@",f,(f>=0&&f<=1) ? "YES":"NO"))
// memory used-fraction + cumulative swapped bytes from one vm_statistics64 read (matches readVMSample)
func mem()->(used:Double,swapBytes:UInt64){
 var st=vm_statistics64_data_t();var c=mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size/MemoryLayout<integer_t>.size)
 _=withUnsafeMutablePointer(to:&st){p in p.withMemoryRebound(to:integer_t.self,capacity:Int(c)){host_statistics64(mach_host_self(),HOST_VM_INFO64,$0,&c)}}
 var ps:vm_size_t=0;_=host_page_size(mach_host_self(),&ps)
 let tot=Double(ProcessInfo.processInfo.physicalMemory)
 let av=(Double(st.free_count)+Double(st.purgeable_count)+Double(st.external_page_count))*Double(ps)
 let u=min(max(1.0-av/tot,0),1)
 let sw=(UInt64(max(0,st.swapins)) &+ UInt64(max(0,st.swapouts))) &* UInt64(ps)
 return (u,sw)}
// GPU util (instantaneous), network + disk cumulative byte counters (counter-delta)
func gpu()->Double?{for cls in ["IOAccelerator","AGXAccelerator"]{guard let m=IOServiceMatching(cls) else{continue};var it:io_iterator_t=0
 guard IOServiceGetMatchingServices(kIOMainPortDefault,m,&it)==KERN_SUCCESS else{continue};defer{IOObjectRelease(it)};var best:Double?;var e=IOIteratorNext(it)
 while e != 0{defer{IOObjectRelease(e);e=IOIteratorNext(it)};guard let p=IORegistryEntryCreateCFProperty(e,"PerformanceStatistics" as CFString,kCFAllocatorDefault,0),let s=p.takeRetainedValue() as? [String:Any],let pct=(s["Device Utilization %"] as? NSNumber)?.doubleValue else{continue};best=max(best ?? 0,min(max(pct/100,0),1))};if let best{return best}};return nil}
func net()->UInt64?{var p:UnsafeMutablePointer<ifaddrs>?;guard getifaddrs(&p)==0,let f=p else{return nil};defer{freeifaddrs(p)};var t:UInt64=0;var c:UnsafeMutablePointer<ifaddrs>?=f
 while let x=c{defer{c=x.pointee.ifa_next};guard let ad=x.pointee.ifa_addr,ad.pointee.sa_family==UInt8(AF_LINK) else{continue};if String(cString:x.pointee.ifa_name)=="lo0"{continue};guard let dp=x.pointee.ifa_data else{continue};let d=dp.assumingMemoryBound(to:if_data.self).pointee;t&+=UInt64(d.ifi_ibytes)&+UInt64(d.ifi_obytes)};return t}
func disk()->UInt64?{guard let m=IOServiceMatching("IOBlockStorageDriver") else{return nil};var it:io_iterator_t=0;guard IOServiceGetMatchingServices(kIOMainPortDefault,m,&it)==KERN_SUCCESS else{return nil};defer{IOObjectRelease(it)};var t:UInt64=0;var fnd=false;var e=IOIteratorNext(it)
 while e != 0{defer{IOObjectRelease(e);e=IOIteratorNext(it)};guard let p=IORegistryEntryCreateCFProperty(e,"Statistics" as CFString,kCFAllocatorDefault,0),let s=p.takeRetainedValue() as? [String:Any] else{continue};t&+=((s["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0)&+((s["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0);fnd=true};return fnd ? t:nil}
let m0=mem();let n0=net();let d0=disk();let t0=ProcessInfo.processInfo.systemUptime;usleep(500000)
let m1=mem();let n1=net();let d1=disk();let dt=ProcessInfo.processInfo.systemUptime-t0
print(String(format:"MEM %.3f in[0,1]:%@",m1.used,(m1.used>=0&&m1.used<=1) ? "YES":"NO"))
let srate=Double(m1.swapBytes>=m0.swapBytes ? m1.swapBytes-m0.swapBytes:0)/dt
let sw=norm(srate,1*1_048_576.0)                     // Tuning.swapFloorBytesPerSec = 1 MiB/s
let comp=max(m1.used,sw.load)
print(String(format:"SWAP-RATE %.0f B/s load=%.3f in[0,1]:%@ ceil>=floor:%@",srate,sw.load,(sw.load>=0&&sw.load<=1) ? "YES":"NO",(sw.ceil>=1_048_576.0) ? "YES":"NO"))
print(String(format:"COMPOSITE %.3f in[0,1]:%@ >=used:%@",comp,(comp>=0&&comp<=1) ? "YES":"NO",(comp>=m1.used-1e-9) ? "YES":"NO"))
if let g=gpu(){print(String(format:"GPU %.3f in[0,1]:%@",g,(g>=0&&g<=1) ? "YES":"NO"))}else{print("GPU: unavailable (nil)")}
if let a=n0,let b=n1{let r=Double(b>=a ? b-a:0)/dt;let x=norm(r,1*1_048_576.0);print(String(format:"NET %.0f B/s load=%.3f in[0,1]:%@ ceil>=floor:%@",r,x.load,(x.load>=0&&x.load<=1) ? "YES":"NO",(x.ceil>=1_048_576.0) ? "YES":"NO"))}else{print("NET: unavailable")}
if let a=d0,let b=d1{let r=Double(b>=a ? b-a:0)/dt;let x=norm(r,4*1_048_576.0);print(String(format:"DISK %.0f B/s load=%.3f in[0,1]:%@ ceil>=floor:%@",r,x.load,(x.load>=0&&x.load<=1) ? "YES":"NO",(x.ceil>=4*1_048_576.0) ? "YES":"NO"))}else{print("DISK: unavailable")}
EOF
swiftc tmp/rcheck.swift -o tmp/rcheck && ./tmp/rcheck; rm -f tmp/rcheck tmp/rcheck.swift
```

### Adaptive scaler behavior (btop-style normalization)

The §5 reader check only covers a single two-sample delta; the **`ThroughputScaler`** (network / disk /
swap-rate normalization) has distinctive behavior — seeding, hysteresis, asymmetric headroom, floor —
that a point read can't exercise. This drives synthetic speed sequences through a faithful port of the
scaler and asserts each property. Keep it in sync with `ThroughputScaler` + the `Tuning.scaler*`
constants (window 5, rescale 5, headroom 1.3↑/3.0↓); a mismatch here means the reimplementation drifted.

```bash
cat > tmp/scalercheck.swift <<'EOF'
import Foundation
struct Scaler {   // mirrors MenuBarLoadRunner.swift ThroughputScaler + Tuning.scaler*
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
EOF
swiftc tmp/scalercheck.swift -o tmp/scalercheck && ./tmp/scalercheck; rm -f tmp/scalercheck tmp/scalercheck.swift
```

## 6. Launcher wrapper (compile-on-run, arg forwarding, singleton)

```bash
pkill -f 'MenuBarLoadRunner' 2>/dev/null; sleep 1
# forwards --load-source, self-exits:
MENUBAR_LOAD_RUNNER_EXIT_AFTER=3 ./menubar-load-runner --foreground --load-source memory 2>&1 | tail -2
# singleton: 2nd instance rejected
MENUBAR_LOAD_RUNNER_EXIT_AFTER=8 ./menubar-load-runner --load-source memory >/dev/null 2>&1; sleep 1
./menubar-load-runner --load-source cpu 2>&1 | grep -qi 'already running' && echo "  PASS singleton rejects 2nd" || echo "  FAIL singleton"
pkill -f 'MenuBarLoadRunner' 2>/dev/null
```

## 7. Interactive spot-check (manual, ~1 min)

`EXIT_AFTER` can't click menus. Once per release, launch for real and eyeball the menu:

```bash
./menubar-load-runner --load-source memory --foreground   # Ctrl-C when done
```

- [ ] Icon animates in the menu bar; speed responds to load over ~10s.
- [ ] Menu shows **Memory: NN% · swap …** and **Memory Pressure: Normal** (not CPU lines).
- [ ] Under memory pressure (e.g. `memory_pressure -l` or a big allocation), the memory line adds a
      live **· N.N MB/s** swap-rate segment and the animation speeds up beyond what used-% alone would
      give (composite `max(usedFraction, adaptiveScaled(swapRate))` drives). It disappears when paging stops.
- [ ] **Load Source** submenu: switching between CPU / Memory / GPU / Network / Disk flips the metric
      line immediately; radio checkmark moves; speed line shows the active source (`auto Network horse …`).
      Rate sources (memory/network/disk) re-warm after a switch (no rate for ~1 tick).
- [ ] **GPU**: line reads **GPU: NN%**; running a GPU load (e.g. a game / WebGL) speeds the animation.
- [ ] **Network**: line reads **Network: N.N MB/s**; a download speeds it up. Adaptive scale settles —
      a single burst spikes then calms within a few ticks (no permanent max-out, no jitter at idle).
- [ ] **Disk**: line reads **Disk: N.N MB/s**; `dd if=/dev/zero of=tmp/x bs=1m count=500; rm tmp/x`
      speeds it up.
- [ ] **Availability**: every source with readable hardware is enabled. To see the disabled state on
      working hardware, relaunch with `MENUBAR_LOAD_RUNNER_FORCE_UNAVAILABLE=gpu,network,disk
      ./menubar-load-runner --foreground` — those three items are greyed out in the **Load Source**
      submenu, and requesting one at launch logs a fallback-to-cpu line (also covered automatically in §3).
- [ ] `Width` line is read-only and shows the GIF-derived width + aspect; Overlay / Preset submenus
      still work (the overlay `Set Text...` limit tracks the preset's width); **About** shows the
      current version; Exit works.

## 8. Cleanup + sign-off

```bash
pkill -f 'mblr-check' 2>/dev/null; pkill -f 'MenuBarLoadRunner' 2>/dev/null
rm -f tmp/mblr-check
./scripts/uninstall-login-item.sh 2>/dev/null || true   # if a login item was installed while testing
git status --short   # confirm only intended files changed
```

Ship when: build warning-clean · §2–6 all PASS (incl. §2 version surface, §4a/§4b error paths, §5
reader ranges + adaptive-scaler behavior) · §7 checklist ticked · `git diff` reviewed.

**Cutting a release (semver):** bump `AppInfo.version` in `MenuBarLoadRunner.swift`, move the
`CHANGELOG.md` `[Unreleased]` items into a new dated version section, and tag the commit
(`git tag vX.Y.Z`). MAJOR/MINOR/PATCH follow the public-API definition at the top of `CHANGELOG.md`
(CLI flags, env vars, preset keywords + `gifs/presets.json` schema, observable behavior). Confirm
`--help` and the About dialog show the new version.

---

## Adding coverage when the app grows

- **New CLI flag / env var** → add a parse-path case to §2 and a lifecycle run to §3.
- **New load source** → add a §3 run, a §5 reader check, and the source's availability-disable +
  runtime-fallback to the §7 checklist. Percentage sources assert the value in [0,1] directly; rate
  (counter-delta) sources copy the swap-rate/NET/DISK block in §5 as the template — difference a
  cumulative counter over `systemUptime`, normalize through the adaptive scaler seed
  (`max(rate*headroom, floor)`), and assert `load ∈ [0,1]` and `ceiling ≥ floor`. See
  `docs/DESIGN-system.md` §7.13 for the full checklist.
- **New normalization / scaling logic** → add a behavior check like the §5 adaptive-scaler block:
  drive synthetic sequences through a faithful port and assert the distinctive properties (seeding,
  hysteresis, floor, range). Note the drift risk — keep the port in sync with the real type + `Tuning`.
- **New availability-gated source** → make it honor `MENUBAR_LOAD_RUNNER_FORCE_UNAVAILABLE` (via
  `isSourceAvailable`) and add a `force-unavail …` fallback run to §3.
- **New modal** → make sure it honors `suppressModalAlerts` (else §4 will hang) and add it to §7.
- **New built-in preset** → add it to `gifs/presets.json` (§ "Adding a new built-in preset" in
  `CLAUDE.md`) and add a §3 lifecycle run for its keyword. No Swift change is needed for a preset.
- **Preset manifest schema change** → update the §4b expectation if the failure message changes, and
  re-confirm §3 default/no-arg launch still resolves the manifest's `defaultPreset`.
