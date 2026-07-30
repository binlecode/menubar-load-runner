# R11 — Die-temperature load source

**Priority** P4 · **Blocked by** nothing. Not API-blocked: the unprivileged SMC path `FanLoadMonitor`
already uses covers temperature keys. This is the cheapest remaining open item.

Deliverable: an eighth `LoadSource` driven by die temperature, at the same unprivileged tier as every
other reader.

Line anchors below are against **v1.14.0** (`MenuBarLoadRunner.swift`, 4553 lines) and are now
**~1,100 lines stale** — the file is 5647 lines at v1.17.1. Assume no `:NNN` lands; resolve every one by
symbol. `FanLoadMonitor`'s block has moved from `:1263-1452` to roughly `:1685-1870`.

**Re-checked against v1.17.1 on 2026-07-29 — the plan still applies unchanged, Step 1 included.** The SMC
plumbing is still `private` to `FanLoadMonitor` (`private struct SMCKeyData`, `private var connection:
io_connect_t`, `openSMC()`), and no `SMCClient` exists anywhere in the source — so the extraction this
plan opens with has not been done or partly done by another change.

---

## Step 1 — Extract the SMC plumbing (the only structural change)

Everything needed already exists inside `FanLoadMonitor` (`MenuBarLoadRunner.swift:1263-1452`) but is
`private` to it. Extract into a shared `@MainActor final class SMCClient`:

| Move | Anchor |
|---|---|
| `SMCBytes`, `SMCVersion`, `SMCPLimitData`, `SMCKeyInfoData`, `SMCKeyData` | `:1273-1298` |
| `selector`, `cmdReadKeyInfo`, `cmdReadBytes`, `typeFLT`, `KeyInfo` | `:1300-1306` |
| `openSMC()`, `smcCall()`, `readKeyInfo()`, `readBytes()`, `readFloat()`, `fourCharCode()` | `:1357-1450` |
| `connection`/`availabilityChecked` caching and the `MemoryLayout<SMCKeyData>.stride == 80` guard | `:1310-1312`, `:1345-1347` |

`FanLoadMonitor` keeps only what is about fans: `FanReading`, `FanKeys`, `discoverFanKeys()`,
`discoverFloatKey()`, the `actual/max` normalisation, and the average-across-fans driver value.

**Catches for the extraction:**

- The three trailing pad bytes in `SMCKeyInfoData` are load-bearing (`:1281-1286`) — Swift packs
  `result` into the tail padding without them, the struct becomes 76 bytes, and the kernel call fails
  with `kIOReturnBadArgument`. Carry the comment across verbatim; this is the memory
  `swift-c-struct-layout-smc` records.
- **Share one `io_connect_t`, do not open two.** `SMCClient` must be a single instance both monitors
  hold. There is no `IOServiceClose` and no `deinit` anywhere in the file today — the connection is
  process-lifetime by design, which is fine for one, sloppier for two.
- Keep the `stride == 80` guard as the availability gate, so a future toolchain layout change disables
  *both* sources rather than corrupting memory in either.
- Preserve `hasSample` semantics: `nil` on any read failure, never a fabricated `0`.

## Step 2 — `ThermalLoadMonitor`

**Key discovery is the real work.** Unlike fans there is no `FNum`-equivalent count key, and the
Apple Silicon key set is not the Intel one (`TC0P`/`TC0D`/`TC0E` are Intel; M-series uses `Tp01`…`Tp0D`
for P-core clusters, `Tg0x` for GPU, and the set varies by chip). Discovery must therefore be
**probe-a-candidate-list**, keeping only keys that:

1. return type `"flt "` with `dataSize == 4` from `readKeyInfo` (same test as `discoverFloatKey`), and
2. read a plausible value on first sample — `0 < °C < 125`. A present-but-garbage key is common.

No plausible key on this machine → `isAvailable == false` → the source is a disabled menu row and a
launch fallback to `.cpu`, exactly like fan on a fanless Mac. Expect this on VMs.

**Normalisation — not `ThroughputScaler`.** Temperature is bounded but is not a 0…1 fraction, so it
needs a floor/ceiling map, which is a third category alongside "bounded percentage" and "unbounded
rate". Add to `Tuning`:

```swift
static let thermalFloorCelsius: Double = 30      // below this → idle animation
static let thermalCeilingCelsius: Double = 100   // at/above → max
```

and map `clamp((c - floor) / (ceiling - floor), 0, 1)`. Document in the class comment that this is a
deliberate approximation, in the same voice as `MemoryLoadMonitor`'s composite.

**The one design decision: max or average across sensors?** `FanLoadMonitor` uses the average and says
why (one fan spinning up should not dominate). Temperature should use the **max** — the hottest die is
what throttling responds to, and averaging a P-core cluster against an idle GPU hides exactly the
event worth visualising. This inverts the fan precedent, so write the reason into the class comment or
the next reader will "fix" it to match. Keep per-sensor readings for the menu, as `perFan` does.

Point read, no warm-up: `sampleUsage()` takes **no `elapsed:`** argument (like fan and battery, unlike
network/disk/swap).

## Step 3 — Wire it in

Per `AGENTS.md`: "adding a source = add a `LoadSource` case + its reader + branches in the three
helpers". Concretely:

1. `LoadSource` (`:379`) — add `case temperature = 7`, plus `key` and `menuTitle`.
   **Name it "Temperature", not "Thermal".** `KeepAwakeSuspension.thermal` (`:625`) and the
   `throttleStatusItem` row already use "thermal" for `ProcessInfo.thermalState`; a "Thermal" load
   source sitting next to a "Thermal state" line reads as the same thing and is not.
2. `sampleActiveSource(elapsed:)`, `activeSourceHasSample`, `activeSourceCurrentUsage` — three branches.
3. `refreshMenuMetrics` — source-conditional readout (`72 °C`, plus a per-sensor line each, mirroring
   the per-fan lines).
4. `allSourcesRowText` — the Other Sources row.
5. `compactLabelText(for:)` — the menu-bar label form (`72°`).
6. `startLoadMonitoring` / the availability probe, so an unavailable source disables its row.

## Acceptance criteria

- [ ] `swiftc -O -strict-concurrency=complete` is warning-clean.
- [ ] Fan source behaves identically after the extraction — same RPM and utilisation readings.
- [ ] `--load-source temperature` drives the animation; values track a load spike (`yes > /dev/null`
      on all cores) within a few sample ticks.
- [ ] On a machine with no readable sensor, the row is disabled and launch falls back to `.cpu`
      without an error.
- [ ] Both sources active simultaneously (Other Sources expanded) share one SMC connection.
- [ ] `MENUBAR_LOAD_RUNNER_EXIT_AFTER=6 ./tmp/mblr-check --load-source temperature` exits 0.
- [ ] A `spec` line in `tests/qa.sh` §5 (`temp:TMP:%`) — it asserts the live readout, not a port.

## Docs to touch

`AGENTS.md` (reader list in Architecture, the `--load-source` values, `ThroughputScaler`'s
bounded-vs-unbounded note — temperature is a third category), `README.md` (load-source table),
`menubar-load-runner` `print_help` (**three** lines — the two usage strings `:31-32` *and* the
`--load-source` flag description `:50`), `docs/cover.html` if it lists sources, `docs/ROADMAP.md`
(close R11).
