#!/bin/bash
# QA harness for MenuBar Load Runner — the executable form of docs/RUNBOOK-qa-release.md §1–6.
# Run from the repo root:  tests/qa.sh
#
# Coverage tiers (the boundary CI is built around — see README "Testing & CI"):
#   core      §1 build (warning-clean) · §2 CLI parse + version · §5 readers + adaptive scaler + semver.
#             Pure logic / CLI — never boots the GUI, so it is ALWAYS safe on any macOS (incl.
#             a headless CI runner). This is the required gate.
#   gui       §3 launch lifecycle · §3a Keep Awake battery conditions · §3b settings persistence ·
#             §3c label slot geometry · §3d other sleep assertions ·
#             §4 error paths. These boot NSApplication + create an NSStatusItem, so they need an active
#             WindowServer (GUI) session. Fine on a logged-in Mac; best-effort on hosted runners.
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
# --keep-awake parse forms. Only the shapes that can be asserted WITHOUT booting the GUI live here:
# a missing value is fatal (rc=1), and a valid value followed by --help short-circuits to usage. A
# *bad* value is deliberately non-fatal (it warns and launches with keep-awake off), so that case is
# covered by the launch tiers, not here — see RUNBOOK §3a.
$BIN --keep-awake >/dev/null 2>&1;                  chk "--keep-awake no value" 1 $?
$BIN --keep-awake off --help >/dev/null 2>&1;       chk "--keep-awake off accepted" 0 $?
$BIN --keep-awake 3s --help >/dev/null 2>&1;        chk "--keep-awake seconds form" 0 $?
$BIN --keep-awake 1h30m --help >/dev/null 2>&1;     chk "--keep-awake compound form" 0 $?
# --battery-threshold: only the fatal contract is assertable without booting. Every *value* — garbage
# and out-of-range included — is deliberately non-fatal (it clamps or falls back and launches, since
# this can be baked into a login item), so which value each form resolves to is asserted by behavior
# in §3a. A bare "rc=0, flag accepted" check here would restate that without observing anything.
$BIN --battery-threshold >/dev/null 2>&1;           chk "--battery-threshold no value" 1 $?
for f in --speed-multiplier --label --load-source --keep-awake --battery-threshold --show-all-sources --no-update-check; do
  $BIN --help 2>&1 | grep -q -- "$f" && { echo "  PASS --help lists $f"; pass=$((pass+1)); } || { echo "  FAIL --help missing $f"; fail=$((fail+1)); }
done
$BIN foo bar >/dev/null 2>&1;                       chk "extra positional" 1 $?
# Version consistency. AppInfo.version is the source of truth; every *in-repo* surface that names the
# version must agree with it, or a release ships a stale one silently — which is exactly how README sat
# at 1.11.2 through two releases while the CHANGELOG (checked here since v1.x) stayed correct. The git
# tag is the fifth surface and is deliberately NOT checked: qa.sh runs *before* the tag exists, so
# asserting it would fail every pre-release run. See docs/ROADMAP.md § Release hygiene.
VER=$(grep -Eo 'static let version = "[0-9]+\.[0-9]+\.[0-9]+"' MenuBarLoadRunner.swift | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+')
vchk(){ grep -q "$2" "$3" && { echo "  PASS $1 shows $VER"; pass=$((pass+1)); } || { echo "  FAIL $1 missing $VER ($3)"; fail=$((fail+1)); }; }
$BIN --help 2>&1 | grep -q "MenuBar Load Runner $VER" && { echo "  PASS --help shows $VER"; pass=$((pass+1)); } || { echo "  FAIL --help missing $VER"; fail=$((fail+1)); }
vchk "CHANGELOG"   "## \[$VER\]"                     CHANGELOG.md
vchk "README"      "Current version: \*\*$VER\*\*"   README.md
vchk "cover badge" ">v$VER<"                         docs/cover.html
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

# --- §3c Label slot geometry [gui] -----------------------------------------
# The one thing about the adjacent label that nothing else can observe: WHERE its slot sits, and whether
# it stays put. There is no API to ask a status item its slot order, a screenshot needs Screen Recording
# (and would have to catch a few points of drift), and menu-dump needs Accessibility — so
# MENUBAR_LOAD_RUNNER_LOG_SLOTS=1 has the app print its own items' screen frames each tick instead,
# which needs no TCC grant because a process may always inspect its own windows.
#
# Assertions are on RELATIVE geometry, deliberately: an unrelated menu-bar change (another app's icon
# appearing, a display change) shifts the whole group at once — observed mid-run during development —
# and absolute x would read that as jitter. Adjacency and constant width are what the design promises.
section "§3c label slot geometry [gui — needs WindowServer]"
pass=0; fail=0
SG="$PWD/tmp/qa-slots-state.json"
gk(){ [ "$2" = 1 ] && { echo "  PASS [$1]"; pass=$((pass+1)); } || { echo "  FAIL [$1] $3"; fail=$((fail+1)); }; }
slots(){ # $1 = side; prints the SLOTS lines from a short run with the label on
  printf '{"version":1,"settings":{"labelMode":"value","labelSide":"%s"}}' "$1" > "$SG"
  MENUBAR_LOAD_RUNNER_LOG_SLOTS=1 MENUBAR_LOAD_RUNNER_STATE_FILE="$SG" \
    MENUBAR_LOAD_RUNNER_EXIT_AFTER=7 $BIN --load-source cpu 2>&1 | grep '^SLOTS'
}
# awk over the captured lines: field 1 = icon x/w, then left, then right. Skips the pre-placement tick
# (every x = 0 before the window is positioned) and reports the distinct values it saw.
geom(){ awk -v want="$1" '
  { n=split($0, f, /[][]/); icon=f[2]; left=f[4]; right=f[6];
    split(icon, i, /[ =]/); split(left, l, /[ =]/); split(right, r, /[ =]/);
    ix=i[2]+0; iw=i[4]+0; lx=l[2]+0; lw=l[4]+0; rx=r[2]+0; rw=r[4]+0;
    if (ix == 0) next;                      # window not placed yet
    ticks++;
    adj = (want == "left") ? (lx + lw == ix) : (ix + iw == rx);
    live = (want == "left") ? lw : rw;
    if (!adj) bad_adj++;
    if (widths != "" && widths != live) bad_width++;
    widths = live;
    if (icon_off != "" && icon_off != ix - lx) bad_icon++;   # icon moved relative to the left slot
    icon_off = ix - lx;
    if (index($0, "label=\"") > 0) { t=$0; sub(/.*label="/, "", t); sub(/".*/, "", t); seen[t]=1 }
  }
  END { texts=0; for (t in seen) texts++;
        print (ticks >= 2 && !bad_adj && !bad_width && !bad_icon) ? 1 : 0, ticks, texts,
              bad_adj+0, bad_width+0, bad_icon+0, widths }' ; }
for want in left right; do
  out=$(slots "$want" | geom "$want")
  set -- $out
  gk "label slot is adjacent, $want of the icon (${2:-0} ticks, slot ${7:-?}pt)" "$1" "adj_fails=$4 raw=$out"
  gk "slot width constant while the value changes ($want, ${3:-0} distinct readings)" \
     "$([ "${5:-1}" = 0 ] && [ "${3:-0}" -ge 1 ] && echo 1 || echo 0)" "width_changes=$5 raw=$out"
  gk "icon does not move relative to the slot ($want)" \
     "$([ "${6:-1}" = 0 ] && echo 1 || echo 0)" "icon_shifts=$6 raw=$out"
done
rm -f "$SG"
echo "  slot geometry: passes=$pass fails=$fail"; total_fail=$((total_fail+fail))

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
ka(){ desc="$1"; force="$2"; expect="$3"; shift 3  # expect: run | paused; rest = extra app args
  rm -f ./tmp/qa-ka-state.json
  MENUBAR_LOAD_RUNNER_STATE_FILE="$PWD/tmp/qa-ka-state.json" \
  MENUBAR_LOAD_RUNNER_FORCE_BATTERY="$force" \
  MENUBAR_LOAD_RUNNER_EXIT_AFTER=6 \
    $BIN --keep-awake 30m "$@" >/dev/null 2>&1 &
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
# --battery-threshold relocates the release point (R5). Each case is chosen so the DEFAULT 20% would
# give the opposite answer — otherwise it would pass whether or not the flag is wired up at all.
ka "threshold 10 -> 15% holds"      15:battery run    --battery-threshold 10
ka "threshold 30 -> 25% releases"   25:battery paused --battery-threshold 30
ka "threshold 30% (sign form)"      25:battery paused --battery-threshold 30%
ka "threshold off -> 15% holds"     15:battery run    --battery-threshold off
ka "threshold off -> 4% releases"   4:battery  paused --battery-threshold off
# The threshold is a BATTERY policy: on AC even a 100% threshold must not release, because the
# onBattery guard is checked before the band. Getting this wrong would pause keep-awake on a plugged-in
# Mac at any charge.
ka "threshold 100 on AC -> holds"   50:ac      run    --battery-threshold 100
ka "threshold 100 on battery"       95:battery paused --battery-threshold 100
# A decimal is refused as ambiguous, not read as a fraction. 0.50 is chosen so a wrong reading is
# visible: taken as 50% it would release at 30% charge; correctly refused it falls back to 20% and
# holds. (0.20 can't test this — a misread would coincide with the default.)
ka "decimal refused -> default"     30:battery run    --battery-threshold 0.50
# 6% is the only charge that separates a clamped 2 (-> 6%, releases) from an unclamped one (2%, would
# hold), and it sits above the 5% floor so the floor isn't what's being observed.
ka "threshold 2 clamps up to 6%"    6:battery  paused --battery-threshold 2
ka "garbage -> default, releases"   15:battery paused --battery-threshold banana
# Env var, and the empty-value-is-absent rule (an empty env must not read as a value). Assigned
# explicitly rather than as a `VAR=x ka …` prefix: an assignment prefixed onto a shell *function*
# leaks into the shell afterwards, which would silently apply to every case below it.
export MENUBAR_LOAD_RUNNER_BATTERY_THRESHOLD=10
ka "env threshold 10 -> 15% holds"  15:battery run
export MENUBAR_LOAD_RUNNER_BATTERY_THRESHOLD=
ka "empty env -> default, releases" 15:battery paused
# Flag beats env. Set to opposite sides of the charge so only one answer can be right.
export MENUBAR_LOAD_RUNNER_BATTERY_THRESHOLD=10
ka "flag beats env"                 25:battery paused --battery-threshold 30
unset MENUBAR_LOAD_RUNNER_BATTERY_THRESHOLD
rm -f ./tmp/qa-ka-state.json
echo "  keep-awake conditions: passes=$pass fails=$fail"; total_fail=$((total_fail+fail))

# --- §3b Settings persistence [gui] ----------------------------------------
# The label mode is the first value in state.json's `settings` block, so these cover the whole contract:
# a mode survives a relaunch, an explicit flag still wins, and a bad block degrades to defaults instead
# of breaking startup. Each case asserts the mode the app REWRITES on termination — a failed restore
# shows up as "off" being written back, which is observable, whereas the absence of the menu-bar slot is
# not (menus aren't scriptable here — RUNBOOK §7).
section "§3b settings persistence [gui — needs WindowServer]"
pass=0; fail=0
SF="$PWD/tmp/qa-settings-state.json"
sp(){ desc="$1"; expect="$2"; shift 2
  MENUBAR_LOAD_RUNNER_STATE_FILE="$SF" MENUBAR_LOAD_RUNNER_EXIT_AFTER=2 "$@" >/dev/null 2>&1; rc=$?
  got=$(sed -n 's/.*"labelMode" *: *"\([a-z]*\)".*/\1/p' "$SF" 2>/dev/null)
  if [ "$rc" = 0 ] && [ "$got" = "$expect" ]; then echo "  PASS [$desc]"; pass=$((pass+1))
  else echo "  FAIL [$desc] rc=$rc expect=$expect got=${got:-<none>}"; fail=$((fail+1)); fi; }
rm -f "$SF"
sp "explicit --label value persists"  value  $BIN --label value
sp "restored on relaunch, no flag"    value  $BIN
sp "explicit off suppresses saved"    off    $BIN --label off
sp "custom text persists"             custom $BIN --label "build box"
sp "custom text restored"             custom $BIN
grep -q '"labelCustomText" : "build box"' "$SF" \
  && { echo "  PASS [custom payload round-trips verbatim]"; pass=$((pass+1)); } \
  || { echo "  FAIL [custom payload round-trips verbatim]"; fail=$((fail+1)); }
# Empty env is ABSENT, not an explicit off — it must not clobber a saved mode.
sp "empty env != explicit off"        custom env MENUBAR_LOAD_RUNNER_LABEL= $BIN
# A hand-edited mode nobody recognizes restores nothing (→ launch default), and the keep-awake block
# must survive the settings write that follows: one writer composes both blocks from live state, and a
# regression there would silently drop whichever block its caller didn't own.
printf '{"version":1,"settings":{"labelMode":"vaule"},"keepAwake":{"tint":3,"enabled":false}}' > "$SF"
sp "unknown mode -> launch default"   off    $BIN
grep -q '"tint" : 3' "$SF" \
  && { echo "  PASS [keepAwake block survives a settings write]"; pass=$((pass+1)); } \
  || { echo "  FAIL [keepAwake block survives a settings write]"; fail=$((fail+1)); }
# The label's SIDE is the first setting with no flag at all (menu-only, like the Keep Awake tint), so
# "an explicit flag wins" has no analogue — what has to hold instead is that a launch cannot quietly
# reset it. A run with no arguments must write back the side it read, and an unrecognized one must
# degrade to the left default rather than to an empty/absent field.
side(){ desc="$1"; expect="$2"; shift 2
  MENUBAR_LOAD_RUNNER_STATE_FILE="$SF" MENUBAR_LOAD_RUNNER_EXIT_AFTER=2 "$@" >/dev/null 2>&1; rc=$?
  got=$(sed -n 's/.*"labelSide" *: *"\([a-z]*\)".*/\1/p' "$SF" 2>/dev/null)
  if [ "$rc" = 0 ] && [ "$got" = "$expect" ]; then echo "  PASS [$desc]"; pass=$((pass+1))
  else echo "  FAIL [$desc] rc=$rc expect=$expect got=${got:-<none>}"; fail=$((fail+1)); fi; }
rm -f "$SF"
side "side defaults to left"          left  $BIN
printf '{"version":1,"settings":{"labelMode":"value","labelSide":"right"}}' > "$SF"
side "saved side survives a relaunch" right $BIN
side "not reset by a --label"         right $BIN --label off
printf '{"version":1,"settings":{"labelSide":"middle"}}' > "$SF"
side "unknown side -> left default"   left  $BIN
# The battery release threshold is the second settings value, and the first whose unit differs between
# surfaces: the CLI takes whole percents, the file stores the charge fraction. Same three-part contract
# as the label — survives a relaunch, an explicit flag still wins, a bad value degrades — asserted on
# the fraction the app REWRITES at termination, so a broken restore surfaces as the 0.2 default coming
# back. §3a already proves the value drives the actual sleep policy; this proves it round-trips.
bt(){ desc="$1"; expect="$2"; shift 2
  MENUBAR_LOAD_RUNNER_STATE_FILE="$SF" MENUBAR_LOAD_RUNNER_EXIT_AFTER=2 "$@" >/dev/null 2>&1; rc=$?
  got=$(sed -n 's/.*"batteryThreshold" *: *\([0-9.]*\).*/\1/p' "$SF" 2>/dev/null)
  if [ "$rc" = 0 ] && [ "$got" = "$expect" ]; then echo "  PASS [$desc]"; pass=$((pass+1))
  else echo "  FAIL [$desc] rc=$rc expect=$expect got=${got:-<none>}"; fail=$((fail+1)); fi; }
rm -f "$SF"
bt "threshold 10 persists as 0.1"     0.1 $BIN --battery-threshold 10
bt "restored on relaunch, no flag"    0.1 $BIN
bt "explicit flag still wins"         0.3 $BIN --battery-threshold 30
# `off` is a VALUE (0), not a mode, so it has to survive the relaunch that would otherwise reinstate
# the 20% default — the one case where a dropped restore is a policy change, not a cosmetic one.
bt "off persists as 0"                0   $BIN --battery-threshold off
bt "off restored, not re-defaulted"   0   $BIN
bt "empty env != a value"             0   env MENUBAR_LOAD_RUNNER_BATTERY_THRESHOLD= $BIN
# The state file is one more untrusted entry point, not a back door past the bounds: an out-of-range
# value is clamped on the way in exactly as the CLI's is (999 -> 100%).
printf '{"version":1,"settings":{"batteryThreshold":999}}' > "$SF"
bt "out-of-range file value clamped"  1   $BIN
# A value of the wrong TYPE fails the decode of the whole file (the Optional fields absorb missing keys,
# not garbage), which must degrade to launch defaults rather than to a startup error — and the single
# writer must still emit BOTH blocks afterwards. Asserted on the block's presence, not on tint 3
# round-tripping: nothing was readable, so what survives is the writer's contract, not the old values.
printf '{"version":1,"settings":{"batteryThreshold":"twenty"},"keepAwake":{"tint":3,"enabled":false}}' > "$SF"
bt "garbage type -> launch default"   0.2 $BIN
grep -q '"keepAwake"' "$SF" \
  && { echo "  PASS [both blocks written after an unreadable file]"; pass=$((pass+1)); } \
  || { echo "  FAIL [both blocks written after an unreadable file]"; fail=$((fail+1)); }
rm -f "$SF"
echo "  settings persistence: passes=$pass fails=$fail"; total_fail=$((total_fail+fail))

# --- §3d Other sleep assertions [gui] --------------------------------------
# The read side of sleep (R13): which OTHER processes hold a sleep assertion. Asserted through
# MENUBAR_LOAD_RUNNER_LOG_ASSERTIONS=1, which prints the FILTERED, post-hysteresis list each tick — the
# LOG_SLOTS trick, and for the same reason: it needs no TCC grant, while the rows themselves are only
# reachable via menu-dump (Accessibility) or a screenshot (Screen Recording). What the rows LOOK like
# stays a §7 click-step; what the app decided is asserted here.
#
# tests/hold-assertion.swift is the fixture: it holds a real assertion under a unique process name, so
# detection and the retention window don't depend on whether this machine happens to have a stray
# caffeinate. No injection hook exists and none should be added — a real holder is one binary away.
section "§3d other sleep assertions [gui — needs WindowServer]"
pass=0; fail=0
PROBE=./tmp/mblr-assert-probe
AS="$PWD/tmp/qa-assert-state.json"    # every launch here is state-redirected: case 3 arms a window
ak(){ [ "$2" = 1 ] && { echo "  PASS [$1]"; pass=$((pass+1)); } || { echo "  FAIL [$1] $3"; fail=$((fail+1)); }; }
if ! swiftc -O tests/hold-assertion.swift -o "$PROBE" 2>&1; then
  ak "assertion fixture builds" 0 "swiftc failed"
else
  # 1+2. A real foreign holder is listed, and the structural noise never is. powerd holds
  # PreventUserIdleSystemSleep ("Prevent sleep while display is on") throughout — the display is on, or
  # this tier wouldn't be running — so "no powerd line" is a live negative, not a vacuous one.
  "$PROBE" 6 & probe_pid=$!
  out=$(MENUBAR_LOAD_RUNNER_LOG_ASSERTIONS=1 MENUBAR_LOAD_RUNNER_STATE_FILE="$AS" \
        MENUBAR_LOAD_RUNNER_EXIT_AFTER=6 $BIN 2>&1 | grep '^ASSERTIONS')
  wait $probe_pid 2>/dev/null
  ak "a real foreign holder is listed by owner + type" \
     "$(echo "$out" | grep -qc . >/dev/null && echo "$out" | grep -q 'mblr-assert-probe x1 PreventUserIdleSystemSleep' && echo 1 || echo 0)" \
     "got: $(echo "$out" | tail -1)"
  ak "structural noise filtered (no powerd, no UserIsActive)" \
     "$(echo "$out" | grep -qE 'powerd|UserIsActive' && echo 0 || echo 1)" \
     "got: $(echo "$out" | grep -E 'powerd|UserIsActive' | head -1)"

  # 3. Our OWN caffeinate is excluded — asserted on `own=N`, the count of assertions the app dropped for
  # being its own. Necessary because "not listed" and "listed but there are none" print identically, and
  # comparing against a count taken from outside is a RACE on any machine with a renewal loop: the foreign
  # total drifts mid-run, which is exactly how this case first failed. `caffeinate -di` holds TWO
  # assertions (display + idle), so an armed window is own=2. Regresses silently if ignoringPIDs is
  # dropped: the app would list its own window as a second, mysterious holder right under the countdown
  # row that already reports it. The state file is removed first — a *saved* bounded window restores on
  # launch, so a stale file arms the unarmed case and both readings come out the same.
  own(){ rm -f "$AS"
    MENUBAR_LOAD_RUNNER_LOG_ASSERTIONS=1 MENUBAR_LOAD_RUNNER_STATE_FILE="$AS" \
      MENUBAR_LOAD_RUNNER_EXIT_AFTER=5 $BIN "$@" 2>&1 | grep '^ASSERTIONS' | tail -1; }
  out=$(own --keep-awake 30m)
  ak "an armed window's own caffeinate is excluded (own=2, -di holds two)" \
     "$(echo "$out" | grep -q ' own=2 ' && echo 1 || echo 0)" "got: $out"
  out=$(own)
  ak "nothing excluded when this app holds no assertion (own=0)" \
     "$(echo "$out" | grep -q ' own=0 ' && echo 1 || echo 0)" "got: $out"

  # 4. Hysteresis: a holder retained across a gap, and bounded. Both halves matter — a renewal loop
  # (`caffeinate -i -t 300` on repeat) gaps between assertions and would otherwise blink, while a
  # retention that never expires would leave a finished job listed forever. The fixture holds for 2s and
  # the run is long enough to see it clear (retention is 8s).
  "$PROBE" 2 & probe_pid=$!
  out=$(MENUBAR_LOAD_RUNNER_LOG_ASSERTIONS=1 MENUBAR_LOAD_RUNNER_STATE_FILE="$AS" \
        MENUBAR_LOAD_RUNNER_EXIT_AFTER=15 $BIN 2>&1 | grep '^ASSERTIONS')
  wait $probe_pid 2>/dev/null
  seen=$(echo "$out" | grep -c 'mblr-assert-probe')
  ak "retained across a renewal gap (listed in $seen ticks after a 2s hold)" \
     "$([ "${seen:-0}" -ge 3 ] && echo 1 || echo 0)" "raw:\n$out"
  ak "retention is bounded — the holder clears once it is gone" \
     "$(echo "$out" | tail -1 | grep -q 'mblr-assert-probe' && echo 0 || echo 1)" \
     "last: $(echo "$out" | tail -1)"
fi
rm -f "$PROBE" "$AS"
echo "  other sleep assertions: passes=$pass fails=$fail"; total_fail=$((total_fail+fail))

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
section "§5 menu-bar label width [core]"
swiftc tests/label.swift -o tmp/label 2>&1 && ./tmp/label || total_fail=$((total_fail+1)); rm -f tmp/label
section "§5 semver + update-tag parse [core]"
swiftc tests/semver.swift -o tmp/semver 2>&1 && ./tmp/semver || total_fail=$((total_fail+1)); rm -f tmp/semver
section "§5 restart-after-update [core]"
swiftc tests/restart.swift -o tmp/restart 2>&1 && ./tmp/restart || total_fail=$((total_fail+1)); rm -f tmp/restart
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
rm -f "$BIN" ./tmp/qa-lifecycle-state.json ./tmp/qa-ka-state.json ./tmp/qa-settings-state.json
printf '\n'
if [ "$total_fail" = 0 ]; then echo "QA: ALL PASS (§7 interactive spot-check still manual)"; exit 0
else echo "QA: $total_fail FAILING section(s)"; exit 1; fi
