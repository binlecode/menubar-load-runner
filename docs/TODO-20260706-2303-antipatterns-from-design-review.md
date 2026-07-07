# TODO: anti-patterns surfaced by the DESIGN-system.md grounding review

Source: full re-verification of `docs/DESIGN-system.md` against `MenuBarLoadRunner.swift`
(1241 lines) and `menubar-load-runner` (225 lines), using the §2.1/§2.2 architecture &
API-layer diagrams as a lens for modularity / DRY / API-boundary / shape.
Date: 2026-07-06.

Each item is grounded in specific symbols. Line numbers are **approximate anchors** (they drift
as the file grows) — `grep` the named symbol, don't trust the number. Ranked by value × ease:
quick wins first, structural bets last.

---

## 1. Delete dead method `currentPresetKind()`

**Status: DONE (2026-07-07).** Method removed; `enum PresetKind` retained (still used by
`PresetDescriptor.kind` and the `.custom` fallback). Warning-clean rebuild confirmed.

**Where**: `currentPresetKind()` (`~1105`).

**Issue**: Zero callers (confirmed by grep — the only occurrence is its own definition). It returns
`activePreset?.kind ?? .custom`; nothing reads it. It's a leftover from before the preset-registry
refactor consolidated kind lookups.

**Fix (impl-ready)**:
1. Delete the whole `private func currentPresetKind() -> PresetKind { ... }`.
2. Do **not** delete `enum PresetKind` — it's still used by `PresetDescriptor.kind` and the
   `.custom` fallback in other accessors.
3. Rebuild: `swiftc -O -strict-concurrency=complete MenuBarLoadRunner.swift -o tmp/mblr-check`
   (must stay warning-clean, and the compiler will confirm no caller broke).
4. Update DESIGN §16.1 (drop the "kept despite no callers" note) since the method is gone.

**Risk/cost**: Trivial, pure win. No behavior change.

---

## 2. Extract `isAutoSpeed` to kill the 4× repeated auto-speed test

**Status: DONE (2026-07-07).** Added `private var isAutoSpeed: Bool`; all four call sites
now read it (the `reevaluateSpeedForCurrentConditions` guard included).

**Where**: `config.speedMultiplierOverride == nil` appears in `showAbout` (`~528`),
`sampleSystemLoad` (`~594`), `refreshMenuMetrics` (`~629`), `reevaluateSpeedForCurrentConditions`
(`~893`).

**Issue**: The "are we in auto (CPU-driven) speed mode?" predicate is spelled out four times. If the
mode condition ever grows (e.g. a second override source), all four must change in lockstep.

**Fix (impl-ready)**:
1. Add one computed property near the other small accessors:
   ```swift
   private var isAutoSpeed: Bool { config.speedMultiplierOverride == nil }
   ```
2. Replace the four `config.speedMultiplierOverride == nil` occurrences with `isAutoSpeed`
   (the `reevaluateSpeedForCurrentConditions` guard becomes `guard isAutoSpeed, loadMonitor.hasSample else { return }`).
3. Rebuild + smoke-test: launch, confirm auto mode animates and `--speed-multiplier 1.2` still
   pins the speed and shows `(fixed)` in the menu.

**Risk/cost**: Trivial, no behavior change.

---

## 3. Deduplicate the overlay-clear effect

**Status: DONE (2026-07-07).** Added `private func applyOverlayCleared()`; both the
empty-input branch of `promptOverlayText` and `clearOverlayText` call it.

**Where**: `clearOverlayText()` (`~784`) and the empty-input branch of `promptOverlayText()`
(`~765`) are byte-for-byte identical: `requestedOverlayText = nil` + `updateRenderedFrames()` +
`renderCurrentFrame()` + `refreshOverlaySelectionState()`.

**Issue**: Same four-statement effect written twice; they can drift.

**Fix (impl-ready)**:
1. Add a private helper:
   ```swift
   private func applyOverlayCleared() {
       requestedOverlayText = nil
       updateRenderedFrames()
       renderCurrentFrame()
       refreshOverlaySelectionState()
   }
   ```
2. Replace both call sites with `applyOverlayCleared()`.
3. Smoke-test: set an overlay via the menu, then Clear → glyph disappears; open prompt, submit
   empty text → same result.

**Risk/cost**: Trivial, no behavior change.

---

## 4. Stop re-assigning `button.imageScaling` on every rendered frame

**Status: DONE (2026-07-07).** `imageScaling` moved into `applySizing()` (runs on every
mode-change path, before the first paint); `renderCurrentFrame` now only sets `button.image`.
The redundant launch-time assignment was removed. Highest mission-relevance of the quick wins —
this was on the animation hot path (`advanceFrames` → `renderCurrentFrame` every frame), and the
app's whole point is to be cheap.

**Where**: `renderCurrentFrame()` (`~997`, sets `imageScaling` at `~1000`), also set at launch
(`~365`). `applySizing()` (`~1075`) is the natural home — it already runs on every event that can
change the scaling mode.

**Issue**: `imageScaling` depends only on whether `requestedWidthSlots` is `nil` — which changes
only on a width or preset selection, never per frame. Yet `renderCurrentFrame` re-sets it on every
game-loop tick. A per-frame render should only set `button.image`.

**Fix (impl-ready)**:
1. Move the assignment
   ```swift
   button.imageScaling = requestedWidthSlots == nil ? .scaleProportionallyUpOrDown : .scaleAxesIndependently
   ```
   out of `renderCurrentFrame` and into `applySizing()` (which is called from
   `applicationDidFinishLaunching`, `switchToGif`, `selectWidthAuto`, `selectWidthSlot`, and the
   screen-parameters observer — i.e. every place the mode can change).
2. In `renderCurrentFrame`, keep only the guard + `button.image = renderedFrames[frameIndex]`.
3. The launch-time assignment at `~365` becomes redundant once `applySizing` runs during launch;
   safe to leave or remove — verify `applySizing` runs before first paint (it does, before
   `renderCurrentFrame` in `applicationDidFinishLaunching`).
4. Smoke-test: switch presets and toggle Width auto↔fixed; confirm scaling still adapts.

**Risk/cost**: Low. Behavior-preserving; removes one property write per frame.

---

## 5. Memoize `updateRenderedFrames()` against its inputs

**Status: PENDING.**

**Where**: `updateRenderedFrames()` (`~1010`). Callers: `applySizing` (tail), plus
`applicationDidFinishLaunching`, `switchToGif`, `clearOverlayText`, `promptOverlayText`, and the
screen-parameters observer.

**Issue**: It regenerates the **entire** `renderedFrames` array (an `NSImage(size:flipped:)`
closure-render per frame, plus `NSAttributedString` layout if an overlay is set) on every call, with
no memoization. Note it is **not** on the per-frame hot path — the game loop reads precomputed
`renderedFrames` via `renderCurrentFrame`. The waste is on *config-change* events, most notably a
`didChangeScreenParametersNotification` that fires without the menu-bar thickness actually changing:
it re-rasterizes every frame for no visible difference.

**Fix (impl-ready)**:
1. Compute a cheap cache key from the inputs that actually affect output:
   ```swift
   // stored: private var lastRenderKey: RenderKey?
   struct RenderKey: Equatable { let length: CGFloat; let thickness: CGFloat;
                                  let overlay: String?; let bold: Bool; let frameCount: Int }
   ```
   built from `statusItem.length`, `NSStatusBar.system.thickness`, `effectiveOverlayText()`,
   `requestedOverlayBold`, `frames.count`.
2. At the top of `updateRenderedFrames`, early-return if the new key equals `lastRenderKey` and
   `renderedFrames` is non-empty; otherwise regenerate and store the new key.
3. Invalidate (`lastRenderKey = nil`) in `loadFrames` on success, since a new GIF replaces `frames`
   without changing length/thickness/overlay.
4. Smoke-test: resize the menu bar / change displays and confirm the icon still re-fits; change
   width slots and overlay and confirm re-render still happens.

**Risk/cost**: Low-medium. Must get the invalidation right (esp. the `loadFrames` frame-source
change and the `frames.count`-only-changes edge). Modest payoff since it's not the hot path — do
after items 1–4.

---

## 6. Collapse the cross-language preset duplication

**Status: DONE (2026-07-07) — Option A.** Swift now owns keyword resolution: `Config` captures the
positional arg verbatim as `presetOrPath` (defaulting to `Config.defaultPreset = "horse-white"` when
absent) and `MenuBarLoadRunnerApp.init` resolves it against `allPresets` by `key`, then falls back to
matching by `path` for raw GIF paths. The launcher lost its 10 path vars, the keyword `case` switch, and
its default injection — it now forwards the positional arg unchanged. The singleton `pgrep` moved from
`"MenuBarLoadRunner.*\.gif"` to `"/MenuBarLoadRunner( |$)"` (matches the compiled binary path, not args;
excludes editors/`swiftc`/the interpreted fallback). **Simplification vs. the original plan:** the
`horse`→`horse-black` alias was dropped rather than reimplemented in Swift (per user direction — use
canonical names). Smoke-tested: every preset keyword, a raw path, no-arg default, unknown keyword,
singleton rejection, and `--extra` bypass. CLAUDE.md checklist + README updated.

Was the root cause of CLAUDE.md's "touch all of these together" preset checklist; adding a preset is now
a single-language (Swift `allPresets`) change plus docs.

**Where**: launcher path table + keyword→path `case` switch (`menubar-load-runner`, path vars
`~95-104`, switch `~135-174`); Swift `allPresets` `PresetDescriptor` registry (built in `init`,
DESIGN §8.1). The `gifs/<name>.gif` mapping and preset identity exist independently in both.

**Issue**: Adding/renaming a preset requires editing two languages that each re-encode the same
facts. The Swift side already has the authoritative table (`allPresets`, with `key` + `path`); the
launcher re-derives the same mapping only to resolve a keyword to an absolute path before exec.

**Fix (impl-ready)** — pick one; option A is the smaller, recommended step:

*Option A — make Swift resolve preset keywords, shrink the launcher to a pass-through.*
1. In `Config.parse()`, when the positional arg is not an existing file path, treat it as a preset
   **key** and resolve it against a shared key→relative-path list (the same data `allPresets` uses).
   To keep `Config` free of `#filePath` logic, either (a) resolve to an absolute path in `Config`
   using `#filePath`'s dir like `MenuBarLoadRunnerApp.init` already does, or (b) let `Config` carry
   the raw key and have `init` map key→descriptor via `allPresets.first { $0.key == arg }`.
2. Delete the launcher's 10 path vars and the keyword `case` switch; forward `$@` unchanged (still
   handle `--foreground/--detach/--extra/--help` launcher-side).
3. **Update the singleton `pgrep`**: it currently matches `"MenuBarLoadRunner.*\.gif"`. If the
   launcher no longer rewrites the keyword to a `.gif` path, the process args may be a bare keyword —
   change the pattern to match the binary name alone (e.g. `pgrep -f "MenuBarLoadRunner"` excluding
   the launcher/grep), and re-verify `--extra` still bypasses it.
4. Keep the launcher's default (`horse-white`) as a literal keyword, not a path.
5. Update CLAUDE.md's "Adding a new built-in preset" checklist (launcher step collapses to nothing)
   and README preset list.

*Option B — generate the launcher table from a single manifest.* Add `gifs/presets.tsv`
(key⇥relativePath); have the launcher read it for keyword resolution and Swift read it in `init`
instead of the inline literals. Heavier (adds a parsed data file to both sides) but keeps the
current two-process arg contract untouched (no `pgrep` change).

**Risk/cost**: Medium. Option A touches the launcher↔binary arg contract and the singleton check —
smoke-test every preset keyword, a raw `/path/to.gif`, the no-arg default, and the singleton/`--extra`
behavior before/after. Do as its own commit.

---

## 7. (Optional) Extract cohesive clusters out of the `MenuBarLoadRunnerApp` hub

**Status: PENDING — deliberately optional / large.**

**Where**: `MenuBarLoadRunnerApp` (`~244`–end): ~985 lines, 44 methods + init, spanning six
concerns (app lifecycle, menu construction+refresh, auto-speed policy, game loop, GIF-decode
pipeline, sizing). Only `CPULoadMonitor` is currently extracted.

**Issue**: One class owns everything. The external API is still tiny (Appendix A), so this is
internal cohesion, not surface sprawl — but the file is hard to navigate and the concerns are
independently testable clusters (DESIGN §2.2 already draws them as separate boxes).

**Fix (impl-ready) — incremental, one type per commit, in this order (least entangled first):**
1. **`GifDecoder`** (pure, no AppKit state): move `loadFrames`, `trimTransparentPadding`,
   `frameDuration` into a `struct GifDecoder` returning `(frames, aspects, durations)` or `nil`.
   App calls `GifDecoder.decode(path:)` and assigns the three arrays. No shared mutable state → the
   cleanest first extraction.
2. **`FrameRenderer`**: move `updateRenderedFrames`/`effectiveOverlayText` (+ the memoization from
   item 5) into a type taking `(rawFrames, aspects, size, overlay, bold)` → `[NSImage]`. `renderCurrentFrame`
   stays in the app (it touches `statusItem.button`).
3. **`SpeedController`** (optional): move `speedMultiplier(forUsage:)`, `isUnderPowerPressure`,
   `constrainedSpeedCeilingFraction` usage, and the hysteresis decision into a small value type; the
   app feeds it smoothed usage + pressure state and gets back a multiplier.
4. Keep lifecycle, menu, and game-loop *driver* in the app (they're inherently `@MainActor` /
   AppKit-bound).
5. After each extraction: rebuild warning-clean under `-strict-concurrency=complete` and smoke-test
   the app end-to-end; update the corresponding DESIGN section.

**Risk/cost**: Medium-high cumulatively; low per step if done one type at a time. No behavior change
intended. Only worth doing if the file's size becomes a real friction — otherwise the current
single-file shape is a legitimate choice for an app this size.

---

## Not carried over (already resolved during the review)

- **Help/preset text duplication** across launcher `print_help` and Swift `Config.printUsage()`:
  partly inherent to the two-process design (launcher-only flags must be documented launcher-side).
  Largely subsumed by item 6 — if Swift owns preset keywords, the launcher help's preset list can be
  the only launcher-side copy. Not tracked separately.
- **The DESIGN doc's own drifting line numbers**: already addressed by the review — the doc now
  anchors on greppable symbol names and marks line numbers approximate.
- **Three `refresh*SelectionState()` methods sharing a shape**: intentionally left — they mutate
  different menu items with genuinely different logic; a forced abstraction would obscure more than
  it saves. Noted for awareness only, not scheduled.
