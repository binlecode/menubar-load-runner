#!/bin/bash
# QA harness for MenuBar Load Runner — the executable form of docs/RUNBOOK-qa-release.md §1–6.
# Run from the repo root:  tests/qa.sh
#
# Default: §1 build, §2 CLI parse + version surface, §3 launch lifecycle, §4 error paths,
#          §5 reader correctness + adaptive scaler. These are non-disruptive (they use the raw
#          tmp/mblr-check binary under MENUBAR_LOAD_RUNNER_EXIT_AFTER, which self-terminates).
# --launcher : ALSO run §6 (launcher wrapper + singleton). This calls `pkill MenuBarLoadRunner`,
#              so it STOPS any running instance (incl. a login-item one) — off by default.
#
# Exits 0 only if every section passes. §7 (interactive menu spot-check) stays manual.
set -uo pipefail
cd "$(dirname "$0")/.."

RUN_LAUNCHER=0
[ "${1:-}" = "--launcher" ] && RUN_LAUNCHER=1

BIN=./tmp/mblr-check
GIF="$PWD/gifs/totoro.gif"
total_fail=0
section(){ printf '\n=== %s ===\n' "$1"; }

# --- §1 Build (warning-clean) ---------------------------------------------
section "§1 build (warning-clean)"
out=$(swiftc -O -strict-concurrency=complete MenuBarLoadRunner.swift -o "$BIN" 2>&1)
if [ -z "$out" ]; then echo "  PASS build warning-clean"; else echo "  FAIL build output:"; echo "$out"; total_fail=$((total_fail+1)); fi

# --- §2 CLI parse + version -----------------------------------------------
section "§2 CLI parse paths"
pass=0; fail=0
chk(){ [ "$2" = "$3" ] && { echo "  PASS [$1] rc=$3"; pass=$((pass+1)); } || { echo "  FAIL [$1] want $2 got $3"; fail=$((fail+1)); }; }
$BIN --help >/dev/null 2>&1;                        chk "--help" 0 $?
$BIN --width 2 >/dev/null 2>&1;                     chk "--width removed (rejected)" 1 $?
$BIN --speed-multiplier 0 >/dev/null 2>&1;          chk "--speed-multiplier 0" 1 $?
$BIN --speed-multiplier -2 >/dev/null 2>&1;         chk "--speed-multiplier neg" 1 $?
$BIN --overlay-text "" >/dev/null 2>&1;             chk "--overlay-text empty" 1 $?
$BIN --overlay-text THIRTEENCHARS >/dev/null 2>&1;  chk "--overlay-text >12" 1 $?
$BIN --load-source >/dev/null 2>&1;                 chk "--load-source no value" 1 $?
$BIN foo bar >/dev/null 2>&1;                       chk "extra positional" 1 $?
VER=$(grep -Eo 'static let version = "[0-9]+\.[0-9]+\.[0-9]+"' MenuBarLoadRunner.swift | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+')
$BIN --help 2>&1 | grep -q "MenuBar Load Runner $VER" && { echo "  PASS --help shows $VER"; pass=$((pass+1)); } || { echo "  FAIL --help missing $VER"; fail=$((fail+1)); }
grep -q "## \[$VER\]" CHANGELOG.md && { echo "  PASS CHANGELOG has [$VER]"; pass=$((pass+1)); } || { echo "  FAIL CHANGELOG missing [$VER]"; fail=$((fail+1)); }
echo "  parse: passes=$pass fails=$fail"; total_fail=$((total_fail+fail))

# --- §3 Launch lifecycle ---------------------------------------------------
section "§3 launch lifecycle"
pass=0; fail=0
run(){ desc="$1"; allow="$2"; shift 2
  err=$(MENUBAR_LOAD_RUNNER_EXIT_AFTER=2 "$@" 2>&1 >/dev/null); rc=$?
  un=$(echo "$err" | grep -v 'MENUBAR_LOAD_RUNNER_EXIT_AFTER=' | { [ -n "$allow" ] && grep -v "$allow" || cat; } | grep -v '^$')
  [ "$rc" = 0 ] && [ -z "$un" ] && { echo "  PASS [$desc]"; pass=$((pass+1)); } || { echo "  FAIL [$desc] rc=$rc <<$un>>"; fail=$((fail+1)); }; }
run "default cpu/auto"         "" $BIN
run "load-source memory"       "" $BIN --load-source memory
run "load-source gpu"          "" $BIN --load-source gpu
run "load-source network"      "" $BIN --load-source network
run "load-source disk"         "" $BIN --load-source disk
run "load-source bogus"        "Unknown --load-source" $BIN --load-source bogus
run "force-unavail gpu->cpu"   "unavailable on this machine" env MENUBAR_LOAD_RUNNER_FORCE_UNAVAILABLE=gpu $BIN --load-source gpu
run "fixed speed"              "" $BIN --speed-multiplier 1.5
run "overlay + gpu"            "" $BIN --overlay-text GPU --load-source gpu
run "wide preset + overlay"    "" $BIN totoro-group-white --overlay-text NET --load-source network
run "custom path + memory"     "" $BIN "$GIF" --load-source memory
run "env LOAD_SOURCE"          "" env MENUBAR_LOAD_RUNNER_LOAD_SOURCE=network $BIN
run "env PATH=<gif>"           "" env MENUBAR_LOAD_RUNNER_PATH="$GIF" $BIN --load-source disk
echo "  lifecycle: passes=$pass fails=$fail"; total_fail=$((total_fail+fail))

# --- §4 Error paths --------------------------------------------------------
section "§4 error paths (fast, no modal)"
err=$(MENUBAR_LOAD_RUNNER_EXIT_AFTER=5 $BIN /no/such/file.gif 2>&1 >/dev/null); rc=$?
{ [ "$rc" = 0 ] && echo "$err" | grep -q "GIF file not found"; } && echo "  PASS bad GIF" || { echo "  FAIL bad GIF (rc=$rc)"; total_fail=$((total_fail+1)); }
mv gifs/presets.json gifs/presets.json.bak
err=$(MENUBAR_LOAD_RUNNER_EXIT_AFTER=5 $BIN 2>&1 >/dev/null); rc=$?
mv gifs/presets.json.bak gifs/presets.json
{ [ "$rc" = 0 ] && echo "$err" | grep -q "Could not load preset manifest"; } && echo "  PASS missing manifest" || { echo "  FAIL missing manifest (rc=$rc)"; total_fail=$((total_fail+1)); }
[ -f gifs/presets.json ] && echo "  PASS manifest restored" || { echo "  FAIL manifest NOT restored"; total_fail=$((total_fail+1)); }

# --- §5 Readers + scaler ---------------------------------------------------
section "§5 reader correctness"
swiftc tests/readers.swift -o tmp/readers 2>&1 && ./tmp/readers || total_fail=$((total_fail+1)); rm -f tmp/readers
section "§5 adaptive scaler"
swiftc tests/scaler.swift -o tmp/scaler 2>&1 && ./tmp/scaler || total_fail=$((total_fail+1)); rm -f tmp/scaler

# --- §6 Launcher wrapper (opt-in; disruptive) ------------------------------
if [ "$RUN_LAUNCHER" = 1 ]; then
  section "§6 launcher wrapper + singleton (stops running instances)"
  pkill -f 'MenuBarLoadRunner' 2>/dev/null; sleep 1
  MENUBAR_LOAD_RUNNER_EXIT_AFTER=3 ./menubar-load-runner --foreground --load-source memory 2>&1 | tail -1
  MENUBAR_LOAD_RUNNER_EXIT_AFTER=8 ./menubar-load-runner --load-source memory >/dev/null 2>&1; sleep 1
  ./menubar-load-runner --load-source cpu 2>&1 | grep -qi 'already running' && echo "  PASS singleton rejects 2nd" || { echo "  FAIL singleton"; total_fail=$((total_fail+1)); }
  pkill -f 'MenuBarLoadRunner' 2>/dev/null
else
  section "§6 launcher wrapper"
  echo "  SKIPPED (disruptive) — re-run with: tests/qa.sh --launcher"
fi

# --- Cleanup + verdict -----------------------------------------------------
rm -f "$BIN"
printf '\n'
if [ "$total_fail" = 0 ]; then echo "QA: ALL PASS (§7 interactive spot-check still manual)"; exit 0
else echo "QA: $total_fail FAILING section(s)"; exit 1; fi
