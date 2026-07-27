# TODO — doc/code drift audit (roadmap check against v1.13.1)

Created 2026-07-26 20:12. Originating request: "check roadmap against latest code."

The roadmap's tracked items (R2–R12, declined, known limits, verification debt) all held up — every
symbol they name still exists and still means what the entry says. The drift was everywhere *else*:
four separate claims in `README.md` / `AGENTS.md` / a Swift class comment that the code had outgrown.

**The unifying cause, and the only real open item:** nothing checks that prose agrees with code.
`tests/qa.sh` §2 enforces exactly two version surfaces; the ones it doesn't enforce are the ones that
drifted. Every fix below is a symptom — item 5 is the item worth doing.

---

## Done (uncommitted as of this file's creation)

| # | Drift | Fix |
|---|---|---|
| 1 | `README.md:10` read `1.11.2` — two releases stale. Never caught because the release-hygiene checklist listed four version surfaces and README wasn't one of them. | Bumped to `1.13.1`; added the README line to `docs/ROADMAP.md` § Release hygiene (four → **five**), with the slip recorded so it isn't re-dropped. |
| 2 | `AGENTS.md` described "the other **three** load-source readers" and `LoadSource` as "`.cpu` default, `.memory` available". The enum has **seven** cases — `fan` and `battery` shipped with full monitors, `isAvailable` probes, and menu wiring. | Documented `FanLoadMonitor` + `BatteryLoadMonitor` as sub-bullets (SMC 80-byte-stride guard, `FNum == 0` → unavailable, `actual/max` vs min-anchored, IOKit Power Sources reuse). Corrected the selector bullet and the "adding a source" recipe, which undercounted the touch points. Also `~1200 lines` → `~4450`. |
| 3 | **Code/doc contradiction, self-contradictory within one file.** `FanLoadMonitor`'s class comment said the driver is the **max** across fans; the property comment 12 lines below said average, and `:1285` assigns `averageFraction` with an inline rationale for preferring average. `README.md:268` also said max. | Corrected both docs — the code is right. **Root cause:** the max→average change shipped in **v1.4.0** (see `CHANGELOG.md:441`) and neither doc was updated. Nine releases undetected. |
| 4 | Both `README.md` and `AGENTS.md` grouped **battery** with the direct percentage reads. It isn't one: discharge current is in **mA** (README said "amps") and it normalizes through `ThroughputScaler`. | Regrouped battery with the scaled sources in both files. Added an explicit note that the split is **bounded-vs-unbounded, not delta-vs-point-read** — battery is an instantaneous read that still scales — since that's the distinction the docs had blurred. |

Verified: `swiftc -O -strict-concurrency=complete` exits 0 warning-clean; `tests/qa.sh --core` all-pass.
Diff: 4 files, +41/−19 (one Swift comment, rest docs).

## Open

### 5. Extend `tests/qa.sh` §2 to cover all five version surfaces — P2

§2 already derives `VER` from `MenuBarLoadRunner.swift` (`tests/qa.sh:79`) and asserts it against **two**
surfaces:

- `--help` output — enforced
- `CHANGELOG.md` heading — enforced
- `README.md` "Current version" line — **not enforced** → drifted two releases
- `docs/cover.html` badge — **not enforced** (currently correct by luck)
- the git tag — not enforceable pre-release, and correctly out of scope for §2

The asymmetry is the whole story: the enforced surfaces never drifted, the unenforced one did. Two more
greps next to the existing `CHANGELOG` check close it, in the tier that already runs on every build.

**Catch:** don't assert the tag. `qa.sh` runs *before* the tag exists, so a tag check would fail every
pre-release run — that's why the existing check stops at CHANGELOG. Keep §2's scope to in-repo files.

Sketch, mirroring the existing check's shape:

```sh
grep -q "Current version: \*\*$VER\*\*" README.md \
  && { echo "  PASS README shows $VER"; pass=$((pass+1)); } \
  || { echo "  FAIL README missing $VER"; fail=$((fail+1)); }
grep -q ">v$VER<" docs/cover.html \
  && { echo "  PASS cover badge shows $VER"; pass=$((pass+1)); } \
  || { echo "  FAIL cover badge missing $VER"; fail=$((fail+1)); }
```

If this isn't done now, promote it to the roadmap as **R13** rather than leaving it here — this file
gets deleted on close, and the gap outlives it.

### 6. Decide whether prose-vs-code drift is worth any standing check beyond version strings — P4, design open

Items 2–4 were *semantic* drift (wrong reader count, wrong aggregation, wrong measurement domain).
Item 5 catches none of that — version strings are the only mechanically checkable claim. The honest
options: accept semantic drift as a review-time concern, or add a doc-review step to the release
runbook. **Settle before building anything:** a checker that greps prose for symbol names produces
false positives on every intentional rewording, which is how checks get disabled. Not obviously worth
it — a nine-release miss on one comment is the whole known cost so far. Recommend accepting the risk
and closing this item unless a second instance shows up.

## Checked — no action needed

- `docs/RUNBOOK-qa-release.md` already documents all **seven** readers (`:5`) and exercises
  fan/battery availability + fallback via `MENUBAR_LOAD_RUNNER_FORCE_UNAVAILABLE` (`:155`–`:161`).
  It did not drift; only `AGENTS.md` did.
- No `TODO`/`FIXME`/`XXX` markers in `MenuBarLoadRunner.swift`; `CHANGELOG.md [Unreleased]` empty; HEAD
  is one docs-only commit past v1.13.1. Nothing in flight is missing from the roadmap.
- Roadmap R5's stated catch is real and still live: `loadHistoryView.lowThreshold =
  Tuning.batteryLowThreshold` (`MenuBarLoadRunner.swift:3036`) genuinely couples the sleep policy to
  the battery sparkline's red band. Left as documented — it's R5's blocker, not this audit's.

## Closing this file

Per `AGENTS.md`: fold item 5's outcome into `docs/ROADMAP.md` (either done, or as R13), record item 6's
decision, then delete this file. The four fixes above are already durable in the tracked docs and need
no further record beyond the commit.
