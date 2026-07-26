#!/bin/bash
# QA harness for MenuBar Load Runner — the executable form of docs/RUNBOOK-qa-release.md §1–6.
# Run from the repo root:  tests/qa.sh
#
# Coverage tiers (the boundary CI is built around — see README "Testing & CI"):
#   core      §1 build (warning-clean) · §2 CLI parse + version · §5 readers + adaptive scaler + semver.
#             Pure logic / CLI — never boots the GUI, so it is ALWAYS safe on any macOS (incl.
#             a headless CI runner). This is the required gate.
#   gui       §3 launch lifecycle · §3a Keep Awake battery conditions · §4 error paths. These boot
#             NSApplication + create an NSStatusItem, so they need an active WindowServer (GUI)
#             session. Fine on a logged-in Mac; best-effort on hosted runners (some are headless).
#   launcher  §6 launcher wrapper + singleton. Disruptive: calls `pkill MenuBarLoadRunner`,
#             so it STOPS any running instance (incl. a login-item one). Opt-in only.
#   §7        interactive menu spot-check — always manual, never scripted.
#
# Usage:
#   tests/qa.sh                 core + gui              (local default — unchanged behavior)
#   tests/qa.sh --core          core only              (headless / CI-safe subset)
#   tests/qa.sh --gui           build + gui only        (best-effort GUI job)
#   tests/qa.sh --launcher      core + gui + launcher   (disruptive)
#   tests/qa.sh --help
#
# Exits 0 only if every section that ran passes.
set -uo pipefail
cd "$(dirname "$0")/.."

RUN_NONGUI=1   # §2, §5
RUN_GUI=1      # §3, §4
RUN_LAUNCHER=0 # §6
for arg in "$@"; do
  case "$arg" in
    --core|--no-gui) RUN_GUI=0 ;;
    --gui)           RUN_NONGUI=0 ;;
    --launcher)      RUN_LAUNCHER=1 ;;
    -h|--help)
      awk 'NR==1{next} /^#/{sub(/^# ?/,"");print;next} {exit}' "$0"; exit 0 ;;
    *) echo "unknown flag: $arg (try --help)"; exit 2 ;;
  esac
done

mkdir -p tmp                 # tmp/ is gitignored; a fresh checkout (CI) won't have it
BIN=./tmp/mblr-check
GIF="$PWD/gifs/totoro.gif"
total_fail=0
section(){ printf '\n=== %s ===\n' "$1"; }
skip(){ printf '\n=== %s ===\n  SKIPPED (%s)\n' "$1" "$2"; }

# --- §1 Build (warning-clean) — always: the gate AND the prerequisite for §2/§3/§4 ---------
section "§1 build (warning-clean) [core]"
out=$(swiftc -O -strict-concurrency=complete MenuBarLoadRunner.swift -o "$BIN" 2>&1)
if [ -z "$out" ]; then echo "  PASS build warning-clean"; else echo "  FAIL build output:"; echo "$out"; total_fail=$((total_fail+1)); fi

# --- §2 CLI parse + version [core] -----------------------------------------
if [ "$RUN_NONGUI" = 1 ]; then
section "§2 CLI parse paths [core]"
pass=0; fail=0
chk(){ [ "$2" = "$3" ] && { echo "  PASS [$1] rc=$3"; pass=$((pass+1)); } || { echo "  FAIL [$1] want $2 got $3"; fail=$((fail+1)); }; }
$BIN --help >/dev/null 2>&1;                        chk "--help" 0 $?
$BIN --width 2 >/dev/null 2>&1;                     chk "--width removed (rejected)" 1 $?
$BIN --overlay-text X >/dev/null 2>&1;              chk "--overlay-text removed (rejected)" 1 $?
$BIN --speed-multiplier 0 >/dev/null 2>&1;          chk "--speed-multiplier 0" 1 $?
$BIN --speed-multiplier -2 >/dev/null 2>&1;         chk "--speed-multiplier neg" 1 $?
$BIN --label >/dev/null 2>&1;                       chk "--label no value" 1 $?
$BIN --load-source >/dev/null 2>&1;                 chk "--load-source no value" 1 $?
$BIN --show-all-sources --help >/dev/null 2>&1;     chk "--show-all-sources accepted" 0 $?
$BIN --no-update-check --help >/dev/null 2>&1;      chk "--no-update-check accepted" 0 $?
for f in --speed-multiplier --label --load-source --show-all-sources --no-update-check; do
  $BIN --help 2>&1 | grep -q -- "$f" && { echo "  PASS --help lists $f"; pass=$((pass+1)); } || { echo "  FAIL --help missing $f"; fail=$((fail+1)); }
done
$BIN foo bar >/dev/null 2>&1;                       chk "extra positional" 1 $?
VER=$(grep -Eo 'static let version = "[0-9]+\.[0-9]+\.[0-9]+"' MenuBarLoadRunner.swift | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+')
$BIN --help 2>&1 | grep -q "MenuBar Load Runner $VER" && { echo "  PASS --help shows $VER"; pass=$((pass+1)); } || { echo "  FAIL --help missing $VER"; fail=$((fail+1)); }
grep -q "## \[$VER\]" CHANGELOG.md && { echo "  PASS CHANGELOG has [$VER]"; pass=$((pass+1)); } || { echo "  FAIL CHANGELOG missing [$VER]"; fail=$((fail+1)); }
echo "  parse: passes=$pass fails=$fail"; total_fail=$((total_fail+fail))
else
skip "§2 CLI parse paths [core]" "core tier not selected (--gui)"
fi

# --- §3 Launch lifecycle [gui] ---------------------------------------------
if [ "$RUN_GUI" = 1 ]; then
section "§3 launch lifecycle [gui — needs WindowServer]"
pass=0; fail=0
# STATE_FILE is redirected for every launch: the app persists Keep Awake intent on termination, so
# without this each of these 21 runs writes the developer's real state file and would clobber an armed
# window. RUNBOOK §3a already required this of its own block; §3 never did.
run(){ desc="$1"; allow="$2"; shift 2
  err=$(MENUBAR_LOAD_RUNNER_STATE_FILE="$PWD/tmp/qa-lifecycle-state.json" \
        MENUBAR_LOAD_RUNNER_EXIT_AFTER=2 "$@" 2>&1 >/dev/null); rc=$?
  un=$(echo "$err" | grep -v 'MENUBAR_LOAD_RUNNER_EXIT_AFTER=' | { [ -n "$allow" ] && grep -v "$allow" || cat; } | grep -v '^$')
  [ "$rc" = 0 ] && [ -z "$un" ] && { echo "  PASS [$desc]"; pass=$((pass+1)); } || { echo "  FAIL [$desc] rc=$rc <<$un>>"; fail=$((fail+1)); }; }
run "default cpu/auto"         "" $BIN
run "load-source memory"       "" $BIN --load-source memory
run "load-source gpu"          "" $BIN --load-source gpu
run "load-source network"      "" $BIN --load-source network
run "load-source disk"         "" $BIN --load-source disk
# fan/battery may be absent (fanless / AC-only / desktop); allow the fallback line so the run passes there.
run "load-source fan"          "unavailable on this machine" $BIN --load-source fan
run "load-source battery"      "unavailable on this machine" $BIN --load-source battery
run "load-source bogus"        "Unknown --load-source" $BIN --load-source bogus
run "force-unavail gpu->cpu"   "unavailable on this machine" env MENUBAR_LOAD_RUNNER_FORCE_UNAVAILABLE=gpu $BIN --load-source gpu
run "force-unavail fan->cpu"   "unavailable on this machine" env MENUBAR_LOAD_RUNNER_FORCE_UNAVAILABLE=fan $BIN --load-source fan
run "force-unavail battery"    "unavailable on this machine" env MENUBAR_LOAD_RUNNER_FORCE_UNAVAILABLE=battery $BIN --load-source battery
run "fixed speed"              "" $BIN --speed-multiplier 1.5
run "label value + gpu"        "" $BIN --label value --load-source gpu
run "label custom text"        "" $BIN --label BUILD
run "show-all-sources (flag)"  "" $BIN --show-all-sources
run "show-all-sources (env)"   "" env MENUBAR_LOAD_RUNNER_SHOW_ALL=1 $BIN --load-source memory
run "no-update-check"          "" $BIN --no-update-check
run "wide preset + label"      "" $BIN totoro-group-white --label NET --load-source network
run "custom path + memory"     "" $BIN "$GIF" --load-source memory
run "env LOAD_SOURCE"          "" env MENUBAR_LOAD_RUNNER_LOAD_SOURCE=network $BIN
run "env PATH=<gif>"           "" env MENUBAR_LOAD_RUNNER_PATH="$GIF" $BIN --load-source disk
echo "  lifecycle: passes=$pass fails=$fail"; total_fail=$((total_fail+fail))

# --- §3a Keep Awake battery conditions [gui] -------------------------------
# Asserts whether `caffeinate` actually runs under each power state, which is the only way to catch a
# keep-awake that *looks* armed and holds nothing — the R1 bug. MENUBAR_LOAD_RUNNER_FORCE_BATTERY pins
# the power-source read, so this needs no real battery and works on a desktop or on AC.
#
# Two things this deliberately does NOT test: the override (only a menu click sets it, and menus are
# not scriptable here — see RUNBOOK §7), and thermal (no way to force a thermal state). `--keep-awake`
# is used precisely BECAUSE it is not an override gesture, so these assert the raw conditions.
section "§3a Keep Awake battery conditions [gui — needs WindowServer]"
pass=0; fail=0
ka(){ desc="$1"; force="$2"; expect="$3"          # expect: run | paused
  rm -f ./tmp/qa-ka-state.json
  MENUBAR_LOAD_RUNNER_STATE_FILE="$PWD/tmp/qa-ka-state.json" \
  MENUBAR_LOAD_RUNNER_FORCE_BATTERY="$force" \
  MENUBAR_LOAD_RUNNER_EXIT_AFTER=6 \
    $BIN --keep-awake 30m >/dev/null 2>&1 &
  kapid=$!
  sleep 3
  got=paused
  # Match the child by its `-w <pid>` signature, never by name: the developer's own running instance
  # legitimately holds a caffeinate, and matching on the name would see it and pass everything.
  pgrep -fl caffeinate 2>/dev/null | grep -q -- "-w $kapid" && got=run
  if [ "$got" = "$expect" ]; then echo "  PASS [$desc]"; pass=$((pass+1))
  else echo "  FAIL [$desc] force=$force expect=$expect got=$got"; fail=$((fail+1)); fi
  wait "$kapid" 2>/dev/null
  if pgrep -fl caffeinate 2>/dev/null | grep -q -- "-w $kapid"; then
    echo "  FAIL [$desc: leaked caffeinate for dead pid $kapid]"; fail=$((fail+1)); fi; }
ka "healthy charge -> holds"        50:battery run
ka "on AC at 15% -> holds"          15:ac      run
ka "low battery -> releases"        15:battery paused
ka "at 20% boundary -> releases"    20:battery paused
ka "critical floor -> releases"     4:battery  paused
rm -f ./tmp/qa-ka-state.json
echo "  keep-awake conditions: passes=$pass fails=$fail"; total_fail=$((total_fail+fail))

# --- §4 Error paths [gui] --------------------------------------------------
section "§4 error paths (fast, no modal) [gui — needs WindowServer]"
err=$(MENUBAR_LOAD_RUNNER_STATE_FILE="$PWD/tmp/qa-lifecycle-state.json" \
      MENUBAR_LOAD_RUNNER_EXIT_AFTER=5 $BIN /no/such/file.gif 2>&1 >/dev/null); rc=$?
{ [ "$rc" = 0 ] && echo "$err" | grep -q "GIF file not found"; } && echo "  PASS bad GIF" || { echo "  FAIL bad GIF (rc=$rc)"; total_fail=$((total_fail+1)); }
mv gifs/presets.json gifs/presets.json.bak
err=$(MENUBAR_LOAD_RUNNER_STATE_FILE="$PWD/tmp/qa-lifecycle-state.json" \
      MENUBAR_LOAD_RUNNER_EXIT_AFTER=5 $BIN 2>&1 >/dev/null); rc=$?
mv gifs/presets.json.bak gifs/presets.json
{ [ "$rc" = 0 ] && echo "$err" | grep -q "Could not load preset manifest"; } && echo "  PASS missing manifest" || { echo "  FAIL missing manifest (rc=$rc)"; total_fail=$((total_fail+1)); }
[ -f gifs/presets.json ] && echo "  PASS manifest restored" || { echo "  FAIL manifest NOT restored"; total_fail=$((total_fail+1)); }
else
skip "§3 launch lifecycle + §4 error paths [gui]" "GUI tier not selected (--core); needs a WindowServer session"
fi

# --- §5 Readers + scaler [core] --------------------------------------------
if [ "$RUN_NONGUI" = 1 ]; then
section "§5 reader correctness [core]"
swiftc tests/readers.swift -o tmp/readers 2>&1 && ./tmp/readers || total_fail=$((total_fail+1)); rm -f tmp/readers
section "§5 adaptive scaler [core]"
swiftc tests/scaler.swift -o tmp/scaler 2>&1 && ./tmp/scaler || total_fail=$((total_fail+1)); rm -f tmp/scaler
section "§5 semver + update-tag parse [core]"
swiftc tests/semver.swift -o tmp/semver 2>&1 && ./tmp/semver || total_fail=$((total_fail+1)); rm -f tmp/semver
else
skip "§5 readers + adaptive scaler [core]" "core tier not selected (--gui)"
fi

# --- §6 Launcher wrapper [launcher] (opt-in; disruptive) -------------------
if [ "$RUN_LAUNCHER" = 1 ]; then
  section "§6 launcher wrapper + singleton [launcher — stops running instances]"
  # Every pgrep/pkill here is `-U "$(id -u)"`-scoped to match the launcher's guard: the poll has to
  # observe the same process set the guard does, and a QA run must never signal another account's
  # instance on a machine with fast user switching.
  pkill -U "$(id -u)" -f 'MenuBarLoadRunner' 2>/dev/null; sleep 1
  MENUBAR_LOAD_RUNNER_EXIT_AFTER=3 ./menubar-load-runner --foreground --load-source memory 2>&1 | tail -1
  # Launch the "victim" instance with a generous self-exit window (a long QA run leaves the machine
  # busy, so a short EXIT_AFTER could fire before the singleton check completes), then poll up to ~10s
  # for it to finish AppKit init and register before the 2nd launch. pkill cleans up after.
  MENUBAR_LOAD_RUNNER_EXIT_AFTER=30 ./menubar-load-runner --load-source memory >/dev/null 2>&1
  for _ in $(seq 10); do pgrep -U "$(id -u)" -f "/MenuBarLoadRunner( |$)" >/dev/null && break; sleep 1; done
  # Capture into a var, then match without a pipe: under `set -o pipefail`, `… | grep -q` makes the
  # launcher take SIGPIPE (141) when grep closes the pipe after matching its first line, and pipefail
  # would report that as a false failure even though the singleton correctly printed "already running".
  out=$(./menubar-load-runner --load-source cpu 2>&1)
  case "$out" in
    *"already running"*) echo "  PASS singleton rejects 2nd" ;;
    *) echo "  FAIL singleton (got: $out)"; total_fail=$((total_fail+1)) ;;
  esac
  pkill -U "$(id -u)" -f 'MenuBarLoadRunner' 2>/dev/null
else
  skip "§6 launcher wrapper [launcher]" "disruptive — re-run with: tests/qa.sh --launcher"
fi

# --- Cleanup + verdict -----------------------------------------------------
rm -f "$BIN" ./tmp/qa-lifecycle-state.json ./tmp/qa-ka-state.json
printf '\n'
if [ "$total_fail" = 0 ]; then echo "QA: ALL PASS (§7 interactive spot-check still manual)"; exit 0
else echo "QA: $total_fail FAILING section(s)"; exit 1; fi
