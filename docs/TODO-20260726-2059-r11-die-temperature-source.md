# R11 — Die-temperature load source

**Priority** P4 · **Depends on** `TODO-20260801-1119-smc-client-extraction.md` (Step 1 lived here until
2026-08-01; this file is now the feature only).

Deliverable: an eighth `LoadSource` driven by die temperature, at the same unprivileged tier as every
other reader.

Resolve every symbol by name, not by line — the anchors this file used to carry rotted twice.

## Step 0 — Probe first; the premise is unverified

"Not API-blocked, the SMC path already covers temperature keys" is reasonable but **has never been
tested on this machine**. Unlike fans there is no `FNum`-equivalent count key, and the Apple Silicon
key set is not the Intel one (`TC0P`/`TC0D`/`TC0E` are Intel; M-series uses `Tp01`…`Tp0D` for P-core
clusters, `Tg0x` for GPU, and the set varies by chip). So discovery is **probe-a-candidate-list**.

Write a throwaway probe in `tmp/` that opens the connection and walks a candidate list, keeping keys
that both:

1. return type `"flt "` with `dataSize == 4` from `readKeyInfo` (the `discoverFloatKey` test), and
2. read a plausible value on the first sample — `0 < °C < 125`. A present-but-garbage key is common.

The probe either hands Step 1 a concrete key list, or shows the item is unavailable on this hardware
and should be re-scoped. Do it before the extraction; it is the cheap half.

## Step 1 — `ThermalLoadMonitor`

**Normalisation is a third category, not `ThroughputScaler`.** Temperature is bounded but is not a 0…1
fraction, so it needs a floor/ceiling map alongside "bounded percentage" and "unbounded rate":

```swift
static let thermalFloorCelsius: Double = 30      // below this → idle animation
static let thermalCeilingCelsius: Double = 100   // at/above → max
```

mapped as `clamp((c - floor) / (ceiling - floor), 0, 1)`. Document it in the class comment as a
deliberate approximation, in the voice `MemoryLoadMonitor`'s composite uses.

**Max across sensors, not average** — the hottest die is what throttling responds to, and averaging a
P-core cluster against an idle GPU hides the event worth visualising. This **inverts the fan
precedent**, which averages deliberately, so write the reason into the class comment or the next reader
will "fix" it to match. Keep per-sensor readings for the menu, as `perFan` does.

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
