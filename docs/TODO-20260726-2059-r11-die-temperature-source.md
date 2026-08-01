# R11 — Die-temperature load source

**Priority** P4 · **Unblocked.** The prerequisite SMC extraction shipped in v1.19.4, so the plumbing
this needs is already the shared `SMCClient` singleton — read keys through `SMCClient.shared`, add no
`io_connect_t` of your own, and inherit its `stride == 80` availability gate. `floatKey(_:)` is the
`"flt "` probe below, already on the client.

Deliverable: an eighth `LoadSource` driven by die temperature, at the same unprivileged tier as every
other reader.

Resolve every symbol by name, not by line — the anchors this file used to carry rotted twice.

## Step 0 — DONE 2026-08-01. Premise confirmed, and the spec below changed because of it

Probed on this machine (Apple Silicon). **R11 is viable**: temperature keys read at the same
unprivileged SMC tier as fan RPM, no entitlement, no root. Four findings, the third of which
invalidates what this file used to specify:

1. **Discovery is enumeration, not a candidate list.** This file used to say there is no
   `FNum`-equivalent for temperature — true for temperature *specifically*, but the SMC publishes a
   general one: `#KEY` returns the total key count, and command **`8` (read-by-index)** walks the real
   table. This machine publishes **3385 keys**, of which **336** are `T`-prefixed, type `"flt "`, and
   read inside 0…125 °C. Enumerate; don't guess a per-chip list you can't distinguish "absent" from
   "didn't think of it".
2. **Everything is `"flt "` here**, so `SMCClient.floatKey` covers it as-is. `sp78` (signed 8.8 fixed
   point) is the Intel encoding — support it only if an Intel Mac ever matters.
3. **`max` across the raw key set is WRONG, and would have shipped a broken reader.** The five hottest
   keys (`Tf06`/`Tf16`/`Tf26`/`Tf36`/`Tf46`, reading 94–107 °C) are **frozen constants** — they did not
   move by even 0.5 °C across a 12s all-core load that moved 245 other sensors. They are limits or
   trip points, not readings. A naive max would pin the animation at `Tf26 = 106.73 °C` forever,
   *regardless of load* — and it would look plausible, because 107 °C is a believable die temperature.
   So: **max over a curated family, never over everything.** `Tp**` is the family to use — all 100
   `Tp**` keys moved under load, none were static.
4. **A static-vs-moving diff is the only way to tell these apart.** A single sample cannot: the
   constants sit in the plausible range and are the *hottest* things on the machine. Any future
   candidate key earns its place by moving under load, not by reading a sane number once.

Live families worth the menu, from that run: `Tp**` (P-core clusters, 55–74 °C under load — the
driver), `Te**`/`Tex*` (efficiency cores, 42–57 °C), `TCM*`/`TCDX` (fabric/interconnect). Ignore
`Tf**` entirely, and note `TVMX`/`TVMx`/`TVmS`/`TVms`/`TVxx` all read exactly 56.00 (thresholds), and
`Ta0*` sit at 8.60 (not a die reading).

The probe was `tmp/smc-temp-probe.swift` — scratch, so treat it as gone. Everything durable it found
is above; regenerating it is `#KEY` + cmd 8 + the 80-byte `SMCKeyData` layout (mind the three trailing
pad bytes in `SMCKeyInfoData`, or every read fails `kIOReturnBadArgument`).

## Step 1 — `ThermalLoadMonitor`

**Normalisation is a third category, not `ThroughputScaler`.** Temperature is bounded but is not a 0…1
fraction, so it needs a floor/ceiling map alongside "bounded percentage" and "unbounded rate":

```swift
static let thermalFloorCelsius: Double = 30      // below this → idle animation
static let thermalCeilingCelsius: Double = 100   // at/above → max
```

mapped as `clamp((c - floor) / (ceiling - floor), 0, 1)`. Document it in the class comment as a
deliberate approximation, in the voice `MemoryLoadMonitor`'s composite uses.

**Max across a CURATED sensor family, not average, and not max over every key** — the hottest die is
what throttling responds to, and averaging a P-core cluster against an idle GPU hides the event worth
visualising. This **inverts the fan precedent**, which averages deliberately, so write the reason into
the class comment or the next reader will "fix" it to match. Keep per-sensor readings for the menu, as
`perFan` does. Curated is the load-bearing word — see Step 0 #3: the raw maximum is a frozen 106.73 °C
constant. Drive on `Tp**`, and gate any key you add on the moving-under-load test, not on a plausible
single reading.

No plausible key → `isAvailable == false` → disabled menu row and a launch fallback to `.cpu`, exactly
like fan on a fanless Mac. Expect this on VMs.

Point read, no warm-up: `sampleUsage()` takes **no `elapsed:`** argument (like fan and battery, unlike
network/disk/swap).

## Step 2 — Wire it in

Per `AGENTS.md`, "adding a source = add a `LoadSource` case + its reader + branches in the three
helpers". Concretely:

1. `LoadSource` — add `case temperature = 7` (still free), plus `key` and `menuTitle`.
   **Name it "Temperature", not "Thermal".** `KeepAwakeSuspension.thermal` and the `throttleStatusItem`
   row already use "thermal" for `ProcessInfo.thermalState`; a "Thermal" load source next to a "Thermal
   state" line reads as the same thing and is not.
2. `sampleActiveSource(elapsed:)`, `activeSourceHasSample`, `activeSourceCurrentUsage` — three branches.
3. `refreshMenuMetrics` — source-conditional readout (`72 °C`, plus a per-sensor line each, mirroring
   the per-fan lines).
4. `allSourcesRowText` — the Other Sources row.
5. `compactLabelText(for:)` — the menu-bar label form (`72°`).
6. `startLoadMonitoring` / the availability probe, so an unavailable source disables its row.

## Acceptance criteria

- [ ] `swiftc -O -strict-concurrency=complete` is warning-clean.
- [ ] `--load-source temperature` drives the animation; values track a load spike (`yes > /dev/null` on
      all cores) within a few sample ticks.
- [ ] On a machine with no readable sensor, the row is disabled and launch falls back to `.cpu` without
      an error.
- [ ] `MENUBAR_LOAD_RUNNER_EXIT_AFTER=6 ./tmp/mblr-check --load-source temperature` exits 0.
- [ ] A §5 case in `tests/qa.sh` asserting the live readout. **It needs a new `deg` shape** — §5 has
      only `%` (`^TAG +[0-9]{1,3}%$`) and `rate`, and a `72°` label matches neither, so the obvious
      `temp:TMP:%` spec line fails. Add the third case; don't bend the label to fit the harness.

## Docs to touch

`AGENTS.md` (reader list in Architecture, the `--load-source` values, `ThroughputScaler`'s
bounded-vs-unbounded note — temperature is a third category), `README.md` (load-source table),
`menubar-load-runner` `print_help` (**three** places — both usage strings and the `--load-source` flag
description), `docs/cover.html` if it lists sources, `docs/ROADMAP.md` (close R11).
