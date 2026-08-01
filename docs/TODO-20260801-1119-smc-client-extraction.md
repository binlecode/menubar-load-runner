# Extract the SMC plumbing into a shared `SMCClient`

**Priority** P4 · **Blocked by** nothing · **Enables** R11 (die temperature), and any later SMC reader.

Split out of R11's TODO on 2026-08-01: it is a refactor with its own hazards, it changes no behavior,
and it is the only structural change either item needs. Doing it alone keeps the temperature reader a
pure addition.

No user-visible effect. The fan source must read *identically* afterwards — that is the whole test.

Resolve every symbol by name, not by line: these anchors have rotted twice already (the file has grown
~1,500 lines since this plan was first written). Everything below lives in `FanLoadMonitor`.

## What moves

Into a new `@MainActor final class SMCClient`:

| Move | Symbols |
|---|---|
| Structs | `SMCBytes`, `SMCVersion`, `SMCPLimitData`, `SMCKeyInfoData`, `SMCKeyData` |
| Constants + key type | `selector`, `cmdReadKeyInfo`, `cmdReadBytes`, `typeFLT`, `KeyInfo` |
| Calls | `openSMC()`, `smcCall()`, `readKeyInfo()`, `readBytes()`, `readFloat()`, `fourCharCode()` |
| State | the `connection` / `availabilityChecked` caching and the `MemoryLayout<SMCKeyData>.stride == 80` guard in `ensureOpen()` |

`FanLoadMonitor` keeps only what is about fans: `FanReading`, `FanKeys`, `discoverFanKeys()`,
`discoverFloatKey()`, the `actual/max` normalisation, and the average-across-fans driver value.

## Catches

- **The three trailing pad bytes in `SMCKeyInfoData` are load-bearing.** Without them Swift packs
  `result` into the tail padding, the struct becomes 76 bytes, and the kernel call fails with
  `kIOReturnBadArgument`. Carry the comment across verbatim — this is what the
  `swift-c-struct-layout-smc` note records.
- **Share one `io_connect_t`, do not open two.** `SMCClient` must be a single instance both monitors
  hold. The file has no `IOServiceClose` and no `deinit` anywhere (still true at v1.19.3): the
  connection is process-lifetime by design, which is fine for one and sloppy for two.
- **Keep the `stride == 80` guard as the availability gate**, so a future toolchain layout change
  disables *every* SMC source rather than corrupting memory in any of them.
- **Preserve `hasSample` semantics** — `nil` on any read failure, never a fabricated `0`.

## Acceptance criteria

- [ ] `swiftc -O -strict-concurrency=complete` is warning-clean.
- [ ] `tests/qa.sh --core` and `--gui` stay green; §5's `fan:FAN:%` case in particular.
- [ ] Fan RPM and utilisation readings are unchanged — same menu lines, same per-fan rows.
- [ ] One `io_connect_t` exists no matter how many SMC-backed sources are sampling.

## Docs to touch

`AGENTS.md` — the `FanLoadMonitor` bullet describes the SMC layout and the stride guard as living in
that class; both move to `SMCClient`.
