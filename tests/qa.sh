#!/bin/bash
# QA harness for MenuBar Load Runner — the release gate. docs/ROADMAP.md § Verification debt maps each
# Run from the repo root:  tests/qa.sh
#
# Coverage tiers (the boundary CI is built around — see README "Testing & CI"):
#   core      §1 build (warning-clean) · §2 CLI parse + version. Never boots the GUI, so it is ALWAYS
#             safe on any macOS (incl. a headless CI runner). This is the required gate — and it is
#             deliberately THIN: every behavioral check here drives the real binary, and the real binary
#             needs a status item. The five `.swift` probes that used to pad this tier asserted against
#             re-ported copies of the app's logic and were deleted (see §5).
#   gui       §3 launch lifecycle · §3a Keep Awake battery conditions · §3b settings persistence ·
#             §3c label slot geometry · §3d other sleep assertions · §3e machine sleep-hold state ·
#             §3f Keep Awake launch arming · §3g freeze animation · §5 reader readouts · §4 error paths. These boot NSApplication + create an NSStatusItem, so
#             they need an active WindowServer (GUI) session. Fine on a logged-in Mac; best-effort on
#             hosted runners.
#   launcher  §6 launcher wrapper: singleton guard, `--precompile`, and the build's safety against a
#             live instance. Disruptive: calls `pkill MenuBarLoadRunner`, so it STOPS any running
#             instance (incl. a login-item one). Opt-in only.
#   manual    the menu walk + the eyes-only checks — docs/ROADMAP.md § Verification debt, never scripted.
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

RUN_NONGUI=1   # §2
RUN_GUI=1      # §3, §4, §5
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
# covered by §3f, not here.
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
# The launcher's OWN flags, against the launcher's own help — the app binary never sees these and its
# help correctly omits them, so the loop above can't cover them. Safe in the [core] tier: `--help` is
# handled before the singleton guard and before any compile, so this neither builds nor touches a
# running instance. `--precompile` earns a listing like any other: it is in the CHANGELOG's public-API
# surface, so an undocumented one is a semver-governed flag nobody can find.
for f in --foreground --no-detach --detach --extra --precompile; do
  ./menubar-load-runner --help 2>&1 | grep -q -- "$f" && { echo "  PASS launcher --help lists $f"; pass=$((pass+1)); } || { echo "  FAIL launcher --help missing $f"; fail=$((fail+1)); }
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
# window. §3f requires this of its own runs; §3 never did.
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
# temperature is absent wherever no SMC sensor answers (VMs), so allow the same fallback line.
run "load-source temperature"  "unavailable on this machine" $BIN --load-source temperature
run "load-source bogus"        "Unknown --load-source" $BIN --load-source bogus
run "force-unavail gpu->cpu"   "unavailable on this machine" env MENUBAR_LOAD_RUNNER_FORCE_UNAVAILABLE=gpu $BIN --load-source gpu
run "force-unavail fan->cpu"   "unavailable on this machine" env MENUBAR_LOAD_RUNNER_FORCE_UNAVAILABLE=fan $BIN --load-source fan
run "force-unavail battery"    "unavailable on this machine" env MENUBAR_LOAD_RUNNER_FORCE_UNAVAILABLE=battery $BIN --load-source battery
run "force-unavail temp->cpu"  "unavailable on this machine" env MENUBAR_LOAD_RUNNER_FORCE_UNAVAILABLE=temperature $BIN --load-source temperature
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
#
# ADJACENCY IS CONDITIONAL, and it took a false failure to learn why. macOS decides where a status item
# goes, there is no reorder API, and on a bar with no room left it does NOT keep a process's items
# together: on this developer's notched built-in display all six runs placed ours as
# icon=908 right=955 left=1117, with other apps' icons interleaved — while the roomy external display
# placed the same build correctly. So the section detects that case geometrically (group span vs the sum
# of the three widths: equal = one contiguous run; wider = foreign items inside the group) and reports
# NOTE instead of FAIL, because a bar that scattered the items cannot answer the question being asked.
# Width-constancy and icon-relative-stability — the v1.16.0 no-jitter promise — are asserted either way,
# and they held throughout the scattered runs. The cost is real: on a machine that always scatters,
# adjacency goes UNVERIFIED here, so re-run where the items land contiguously (a roomy external bar, or
# CI) before trusting it. A genuine ordering regression is still caught, since a contiguous-but-wrong
# order fails the check rather than skipping it. See ROADMAP known limits.
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
    # Did the bar keep our three items as ONE run? Span from the leftmost edge of the group to its
    # rightmost must equal the sum of the three widths; wider means foreign items sit inside the group,
    # so this bar never gave adjacency a chance. Independent of which side is live.
    lo = ix; if (lx < lo) lo = lx; if (rx < lo) lo = rx;
    hi = ix + iw; if (lx + lw > hi) hi = lx + lw; if (rx + rw > hi) hi = rx + rw;
    if (hi - lo != iw + lw + rw) { noncontig++; ng_icon = ix; ng_live = (want == "left") ? lx : rx }
    if (widths != "" && widths != live) bad_width++;
    widths = live;
    if (icon_off != "" && icon_off != ix - lx) bad_icon++;   # icon moved relative to the left slot
    icon_off = ix - lx;
    if (index($0, "label=\"") > 0) { t=$0; sub(/.*label="/, "", t); sub(/".*/, "", t); seen[t]=1 }
  }
  END { texts=0; for (t in seen) texts++;
        # $1 is the ADJACENCY verdict alone now — width and icon-shift have their own fields and their
        # own assertions, and folding them in here made one failure read as three.
        print (ticks >= 2 && !bad_adj) ? 1 : 0, ticks, texts,
              bad_adj+0, bad_width+0, bad_icon+0, widths, noncontig+0, ng_icon+0, ng_live+0 }' ; }
for want in left right; do
  out=$(slots "$want" | geom "$want")
  set -- $out
  if [ "${8:-0}" -gt 0 ]; then
    # Not a pass and not a fail: the bar scattered the items, so adjacency is unanswerable here.
    echo "  NOTE [adjacency unverifiable, $want of the icon: this bar placed the items non-contiguously" \
         "(icon=${9:-?} slot=${10:-?}, foreign items between) — re-run on a bar with room]"
  else
    gk "label slot is adjacent, $want of the icon (${2:-0} ticks, slot ${7:-?}pt)" "$1" "adj_fails=$4 raw=$out"
  fi
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
# not scriptable here — see ROADMAP § Verification debt), and thermal (no way to force a thermal state). `--keep-awake`
# is used precisely BECAUSE it is not an override gesture, so these assert the raw conditions.
#
# What these do NOT cover is how the pause LOOKS: the tone the track line and the label wear is asserted
# in §3e, which already has the LOG_AWAKE plumbing and the display-holder fixture that case needs.
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

# --- §3f Keep Awake launch arming + persistence [gui] ----------------------
# --keep-awake arms without a click, so the whole window contract is scriptable: what -t the child gets,
# which saved states come back, and which must not. Ported out of the manual walk 2026-07-31, where these
# lived as copy-paste prose and so were only ever run when someone remembered to paste them.
# FORCE_BATTERY pins a healthy charge on AC: without it a tester below 20% sees every case fail, because
# the battery condition is correctly releasing the child (that is §3a's subject, not this one).
section "§3f Keep Awake launch arming [gui — needs WindowServer]"
pass=0; fail=0
ST="$PWD/tmp/qa-arm-state.json"; ERR=./tmp/qa-arm-err.txt
ck(){ if [ "$2" = EMPTY ]; then [ -z "$3" ] && r=0 || r=1; else case "$3" in *"$2"*) r=0;; *) r=1;; esac; fi
  [ $r = 0 ] && { echo "  PASS [$1]"; pass=$((pass+1)); } || { echo "  FAIL [$1] want [$2] got [${3:-<empty>}]"; fail=$((fail+1)); }; }
# Launch, capture the caffeinate child bound to THIS app (by -w pid, never by name), wait for its exit.
arm(){ MENUBAR_LOAD_RUNNER_STATE_FILE="$ST" MENUBAR_LOAD_RUNNER_FORCE_BATTERY=100:ac \
         MENUBAR_LOAD_RUNNER_EXIT_AFTER=3 $BIN --no-update-check "$@" >/dev/null 2>"$ERR" & app=$!
       sleep 1.2; CHILD=$(ps -o args= -ax | grep '[c]affeinate' | grep -- "-w $app" || true); wait $app; }

rm -f "$ST"; arm --keep-awake 1m;     ck "1m arms -t 60"          "-t 60"   "$CHILD"
rm -f "$ST"; arm --keep-awake 1h30m;  ck "1h30m arms -t 5400"     "-t 5400" "$CHILD"
rm -f "$ST"; arm --keep-awake 99h;    ck "clamped to 24h"         "-t 86400" "$CHILD"
rm -f "$ST"; arm --keep-awake on;     ck "on = no -t"             "-di -w"  "$CHILD"
rm -f "$ST"; arm --keep-awake off;    ck "off = no child"         EMPTY     "$CHILD"
rm -f "$ST"; arm;                     ck "absent = no child"      EMPTY     "$CHILD"
rm -f "$ST"; arm --keep-awake banana; ck "bad value = no child"   EMPTY     "$CHILD"
                                      ck "bad value warns" "Unrecognized --keep-awake" "$(cat "$ERR")"
rm -f "$ST"; MENUBAR_LOAD_RUNNER_KEEP_AWAKE=45m arm; ck "env arms" "-t 2700" "$CHILD"
rm -f "$ST"; MENUBAR_LOAD_RUNNER_KEEP_AWAKE=45m arm --keep-awake 10m; ck "flag beats env" "-t 600" "$CHILD"
# Round trip: the REMAINDER resumes, never a fresh 1800 (a length would extend the window every relaunch).
rm -f "$ST"; arm --keep-awake 30m;    ck "arming writes state" '"enabled" : true' "$(cat "$ST")"
arm; secs=$(echo "$CHILD" | sed -n 's/.*-t \([0-9]*\).*/\1/p')
[ -n "$secs" ] && [ "$secs" -gt 1700 ] && [ "$secs" -lt 1800 ] \
  && { echo "  PASS [resumes remainder (-t $secs, not 1800)]"; pass=$((pass+1)); } \
  || { echo "  FAIL [resumes remainder] got '${secs:-none}', want 1700<x<1800"; fail=$((fail+1)); }
arm --keep-awake off;                 ck "explicit off suppresses saved window" EMPTY "$CHILD"
arm --keep-awake 5m;                  ck "flag beats saved window" "-t 300" "$CHILD"
# Saved states that must NOT come back.
printf '{"version":1,"keepAwake":{"enabled":true,"deadline":"2020-01-01T00:00:00Z","tint":2}}' > "$ST"
arm; ck "elapsed window not restored"   EMPTY "$CHILD"
printf '{"version":1,"keepAwake":{"enabled":true,"tint":1}}' > "$ST"
arm; ck "saved indefinite not restored" EMPTY "$CHILD"   # by design: no stopping condition
printf 'x' > "$ST"
arm; ck "corrupt file: no child"        EMPTY "$CHILD"
     ck "corrupt file: silent" EMPTY "$(grep -v MENUBAR_LOAD_RUNNER_EXIT_AFTER "$ERR")"
# Natural expiry must mark the window SPENT, or it would resume forever.
rm -f "$ST"
MENUBAR_LOAD_RUNNER_STATE_FILE="$ST" MENUBAR_LOAD_RUNNER_EXIT_AFTER=7 $BIN --no-update-check \
  --keep-awake 3s >/dev/null 2>&1 & app=$!; sleep 4
ck "window released itself" EMPTY "$(ps -o args= -ax | grep '[c]affeinate' | grep -- "-w $app" || true)"
wait $app; ck "expiry persisted enabled:false" '"enabled" : false' "$(cat "$ST")"
arm; ck "spent window not resumed" EMPTY "$CHILD"
# An unwritable state location must not cost the user the feature.
mkdir -p tmp/qa-ro && chmod 500 tmp/qa-ro
MENUBAR_LOAD_RUNNER_STATE_FILE="$PWD/tmp/qa-ro/s.json" MENUBAR_LOAD_RUNNER_EXIT_AFTER=3 $BIN \
  --no-update-check --keep-awake 5m >/dev/null 2>&1 & app=$!; sleep 1.2
ck "read-only state dir still arms" "-t 300" "$(ps -o args= -ax | grep '[c]affeinate' | grep -- "-w $app" || true)"
wait $app; ck "read-only state dir exits 0" 0 "$?"
chmod 700 tmp/qa-ro; rm -rf tmp/qa-ro
rm -f "$ST" "$ERR"
echo "  keep-awake arming: passes=$pass fails=$fail"; total_fail=$((total_fail+fail))

# --- §3b Settings persistence [gui] ----------------------------------------
# The label mode is the first value in state.json's `settings` block, so these cover the whole contract:
# a mode survives a relaunch, an explicit flag still wins, and a bad block degrades to defaults instead
# of breaking startup. Each case asserts the mode the app REWRITES on termination — a failed restore
# shows up as "off" being written back, which is observable, whereas the absence of the menu-bar slot is
# not (menus aren't scriptable here — ROADMAP § Verification debt).
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
# Freeze Animation (R17) is the third settings value and the second with no flag at all (menu-only,
# like the side). What must hold is the round-trip: a seeded true survives the termination rewrite,
# and a file without the key degrades to false rather than erroring (Optional-field degradation).
# What the freeze DOES is §3g's subject, not this one's.
fz(){ desc="$1"; expect="$2"; shift 2
  MENUBAR_LOAD_RUNNER_STATE_FILE="$SF" MENUBAR_LOAD_RUNNER_EXIT_AFTER=2 "$@" >/dev/null 2>&1; rc=$?
  got=$(sed -n 's/.*"freezeAnimation" *: *\([a-z]*\).*/\1/p' "$SF" 2>/dev/null)
  if [ "$rc" = 0 ] && [ "$got" = "$expect" ]; then echo "  PASS [$desc]"; pass=$((pass+1))
  else echo "  FAIL [$desc] rc=$rc expect=$expect got=${got:-<none>}"; fail=$((fail+1)); fi; }
printf '{"version":1,"settings":{"freezeAnimation":true}}' > "$SF"
fz "seeded freeze survives the rewrite"  true  $BIN
printf '{"version":1,"settings":{"labelMode":"off"}}' > "$SF"
fz "absent key round-trips to false"     false $BIN
rm -f "$SF"
echo "  settings persistence: passes=$pass fails=$fail"; total_fail=$((total_fail+fail))

# --- §3d Other sleep assertions [gui] --------------------------------------
# The read side of sleep (R13): which OTHER processes hold a sleep assertion. Asserted through
# MENUBAR_LOAD_RUNNER_LOG_ASSERTIONS=1, which prints the FILTERED, post-hysteresis list each tick — the
# LOG_SLOTS trick, and for the same reason: it needs no TCC grant, while the rows themselves are only
# reachable via menu-dump (Accessibility) or a screenshot (Screen Recording). What the rows LOOK like
# stays a click-step (ROADMAP § Verification debt); what the app decided is asserted here.
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
     "$(echo "$out" | grep -q '\[mblr-assert-probe: PreventUserIdleSystemSleep x1\]' && echo 1 || echo 0)" \
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

# --- §3e Machine sleep-hold state [gui] ------------------------------------
# R16: whether the app reports that THIS MAC is held awake, by anyone — not just by its own child. The
# whole point is the case the app used to read `Off` through: a bare `caffeinate` in a terminal. Asserted
# through MENUBAR_LOAD_RUNNER_LOG_AWAKE=1, which prints the derived state AND the row text verbatim, so
# the rendering (attribution, "may still sleep", the clock time) is covered here and not by eyeball.
#
# Two things are environment-sensitive and report NOTE rather than a false FAIL, the §3c precedent: this
# machine's own holders are not ours to control, so "nothing holds sleep" and "only idle is held" can
# both be unreachable while an unrelated process holds a display assertion.
section "§3e machine sleep-hold state [gui — needs WindowServer]"
pass=0; fail=0
PROBE=./tmp/mblr-assert-probe
AW="$PWD/tmp/qa-awake-state.json"
mk(){ [ "$2" = 1 ] && { echo "  PASS [$1]"; pass=$((pass+1)); } || { echo "  FAIL [$1] $3"; fail=$((fail+1)); }; }
awake(){ rm -f "$AW"
  MENUBAR_LOAD_RUNNER_LOG_AWAKE=1 MENUBAR_LOAD_RUNNER_STATE_FILE="$AW" \
    MENUBAR_LOAD_RUNNER_EXIT_AFTER="$1" $BIN "${@:2}" 2>&1 | grep '^AWAKE'; }
if ! swiftc -O tests/hold-assertion.swift -o "$PROBE" 2>&1; then
  mk "assertion fixture builds" 0 "swiftc failed"
else
  # 1. A foreign DISPLAY holder reads as held awake. Environment-independent: whatever else this machine
  # is doing, our fixture holds a display assertion, so held-by-someone-else is the only right answer.
  "$PROBE" 7 --display --timeout 90 & probe_pid=$!
  out=$(awake 6)
  last=$(echo "$out" | tail -1)
  # `tint=foreign` rides along here rather than in a case of its own: the tone is what the track line and
  # the label actually wear, and this is already the run that produces a foreign hold.
  mk "a foreign display hold reads as held awake, in the foreign tone" \
     "$(echo "$last" | grep -q 'hold=foreign .*display=1 .*tint=foreign' && echo 1 || echo 0)" "got: $last"
  # 2. Attribution and the release time. Both are about the owner the row NAMES, and the row names one
  # holder — display-holders first, then alphabetical. So these two cases only mean something when our
  # fixture is the one named: a browser playing video holds a display assertion too and sorts first
  # (seen live: `Mac held awake — Brave Browser and 3 others`), which is the row being CORRECT about a
  # machine we don't control. NOTE rather than a false FAIL, the §3c precedent.
  if ! echo "$last" | grep -q 'row="Mac held awake — mblr-assert-probe'; then
    echo "  NOTE [attribution + release time unverifiable: another display holder on this machine sorts"\
         "ahead of the fixture, so the row names it instead — correct behavior, wrong conditions here]"
    echo "       last: $last"
  else
    mk "the row names the holder it is reporting" 1 ""
    mk "a timed foreign hold reports when it releases" \
       "$(echo "$last" | grep -q 'row=.*· until ' && echo 1 || echo 0)" "got: $last"
    # That clock time must be STABLE across ticks — the guard on the stale-AssertTimeoutTimeLeft trap:
    # TimeLeft is the remainder as of AssertTimeoutUpdateTime, NOT from now, so reading it as time-from-now
    # slides the deadline forward 2s every tick and the hold never appears to end.
    # Match the digits only, NOT the AM/PM: macOS separates them with U+202F NARROW NO-BREAK SPACE
    # (verified by hexdump — `e2 80 af`, not 0x20), so a pattern with a plain space matches nothing and
    # this case fails for a reason that has nothing to do with the app. Anything else scripting these rows
    # wants to know the same thing.
    untils=$(echo "$out" | grep -o 'until [0-9:]*' | sort -u | wc -l | tr -d ' ')
    ticks=$(echo "$out" | grep -c 'until ')
    mk "the release time does not slide forward each tick ($ticks ticks, $untils distinct)" \
       "$([ "${ticks:-0}" -ge 2 ] && [ "${untils:-9}" = 1 ] && echo 1 || echo 0)" "raw:\n$out"
  fi
  wait $probe_pid 2>/dev/null

  # 3. It clears when the holder goes away — the retention window bounds this, same as §3d case 4.
  out=$(awake 5)
  mk "the holder clears from the row once it is gone" \
     "$(echo "$out" | tail -1 | grep -q 'mblr-assert-probe' && echo 0 || echo 1)" \
     "got: $(echo "$out" | tail -1)"

  # 4. Idle-only is NOT held awake. The honest reading, and the reason the display/idle split exists: an
  # idle assertion doesn't survive the display sleeping, because the system follows it down — the same
  # fact that makes this app spawn `-di`. Unreachable if anything else on this machine holds the display.
  "$PROBE" 7 --timeout 90 & probe_pid=$!
  out=$(awake 6)
  wait $probe_pid 2>/dev/null
  if echo "$out" | tail -1 | grep -q 'display=1'; then
    echo "  NOTE [idle-only reading unverifiable: something else on this machine holds a display" \
         "assertion, so the Mac genuinely IS held awake and 'may still sleep' cannot be the answer]"
    echo "       last: $(echo "$out" | tail -1)"
  else
    mk "an idle-only hold says the Mac may still sleep, not that it is held" \
       "$(echo "$out" | tail -1 | grep -q 'hold=partial .*row="Idle sleep held' && echo 1 || echo 0)" \
       "got: $(echo "$out" | tail -1)"
  fi

  # 5. Our OWN window: attributed to this app, with the countdown, and it must DECREMENT — a frozen
  # countdown is the failure this row shares with the one above it.
  out=$(awake 7 --keep-awake 30m)
  mk "our own hold is attributed to this app, in the full tone" \
     "$(echo "$out" | tail -1 | grep -qE 'hold=(own|both) .*tint=own row="Mac held awake — this app · ' && echo 1 || echo 0)" \
     "got: $(echo "$out" | tail -1)"
  counts=$(echo "$out" | grep -o 'this app · [0-9:]*' | sort -u | wc -l | tr -d ' ')
  mk "its countdown decrements across ticks ($counts distinct readings)" \
     "$([ "${counts:-0}" -ge 2 ] && echo 1 || echo 0)" "raw:\n$out"

  # 6. Nothing holding — the row is an answer, not an empty state. Reachable only on a quiet machine.
  out=$(awake 5)
  if echo "$out" | tail -1 | grep -qE 'display=1|idle=1'; then
    echo "  NOTE [the unheld reading is unverifiable on this machine: an unrelated process holds a" \
         "sleep assertion throughout, which is signal, not noise]"
    echo "       last: $(echo "$out" | tail -1)"
  else
    mk "with nothing holding sleep the row says so, and wears no tone" \
       "$(echo "$out" | tail -1 | grep -q 'hold=none .*tint=none row="Nothing holding sleep"' && echo 1 || echo 0)" \
       "got: $(echo "$out" | tail -1)"
  fi

  # 7. R7 — a PAUSED hold. Cases 1, 5 and 6 above cover the foreign, full and no-tone readings for free;
  # this is the one with no picture of its own, because a suspend kills the child and so used to render
  # exactly like Off — and with the label off by default that 2pt line is a default user's only ambient
  # indicator. Assigned with export/unset, not as a prefix: a prefix on a shell *function* leaks into
  # every case after it (see §3a).
  export MENUBAR_LOAD_RUNNER_FORCE_BATTERY=15:battery
  last=$(awake 5 --keep-awake 30m | tail -1)
  if echo "$last" | grep -q 'tint=foreign'; then
    echo "  NOTE [the paused tone is unverifiable here: another process holds the display, so the Mac IS"\
         "held and the foreign tone correctly outranks our pause — see the next case]"
    echo "       last: $last"
  else
    mk "an armed-but-suspended hold shows the paused tone, not nothing" \
       "$(echo "$last" | grep -q 'paused=1 tint=paused' && echo 1 || echo 0)" "got: $last"
  fi
  # That precedence, asserted rather than assumed: with the fixture holding the display, the same paused
  # hold reads foreign, because this surface reports the machine before it reports us.
  "$PROBE" 7 --display --timeout 90 & probe_pid=$!
  last=$(awake 5 --keep-awake 30m | tail -1)
  wait $probe_pid 2>/dev/null
  unset MENUBAR_LOAD_RUNNER_FORCE_BATTERY
  mk "a foreign display hold outranks our pause" \
     "$(echo "$last" | grep -q 'paused=1 tint=foreign' && echo 1 || echo 0)" "got: $last"
fi
rm -f "$PROBE" "$AW"
echo "  machine sleep-hold state: passes=$pass fails=$fail"; total_fail=$((total_fail+fail))

# --- §3g Freeze animation [gui] ---------------------------------------------
# R17: the frozen icon (game loop stopped, current frame held) and the label handoff, asserted through
# MENUBAR_LOAD_RUNNER_LOG_ANIMATION=1 and driven via the state file — the Settings toggle itself is a
# menu click no agent can perform (ROADMAP § Verification debt, the §3b precedent). The Reduce Motion TRIGGER is
# deliberately untested: the pref is the machine's, not the test's, and a FORCE hook would change a
# decision (mocking with extra steps). Everything downstream of the observer is exactly what these
# cases cover via the manual freeze; the notification→reading wiring is eyes-only, recorded as
# verification debt in docs/ROADMAP.md.
section "§3g freeze animation [gui — needs WindowServer]"
pass=0; fail=0
FZ="$PWD/tmp/qa-freeze-state.json"
fk(){ [ "$2" = 1 ] && { echo "  PASS [$1]"; pass=$((pass+1)); } || { echo "  FAIL [$1] $3"; fail=$((fail+1)); }; }

# 1+2. Frozen launch: the driver never starts, the reason is named, ONE frame holds across every tick —
# and the label slot carries the live reading despite no --label flag (the handoff: speed IS the
# readout, so a frozen icon with no label would be a load indicator gone silent).
printf '{"version":1,"settings":{"freezeAnimation":true}}' > "$FZ"
out=$(MENUBAR_LOAD_RUNNER_STATE_FILE="$FZ" MENUBAR_LOAD_RUNNER_LOG_ANIMATION=1 \
      MENUBAR_LOAD_RUNNER_LOG_SLOTS=1 MENUBAR_LOAD_RUNNER_EXIT_AFTER=8 $BIN 2>&1)
anim=$(echo "$out" | grep '^ANIM')
fk "frozen launch never starts the driver" \
   "$([ -n "$anim" ] && ! echo "$anim" | grep -vq 'running=0 freeze=manual' && echo 1 || echo 0)" \
   "raw:\n$anim"
frames=$(echo "$anim" | sed -n 's/.*frame=\([0-9]*\).*/\1/p' | sort -u | wc -l | tr -d ' ')
fk "the frame cursor holds one value across all ticks" \
   "$([ "${frames:-0}" = 1 ] && echo 1 || echo 0)" "distinct frames=$frames"
fk "every tick reports the label handoff engaged" \
   "$([ -n "$anim" ] && ! echo "$anim" | grep -vq 'labelHandoff=1' && echo 1 || echo 0)" "raw:\n$anim"
lbl=$(echo "$out" | grep '^SLOTS' | tail -1 | sed -n 's/.*label="\(.*\)".*/\1/p')
fk "the slot carries a live reading with no --label flag" \
   "$([ -n "$lbl" ] && echo 1 || echo 0)" "slot label empty"

# 3. An explicit label mode is respected, never overridden: same freeze, --label "hi" → no handoff.
out=$(MENUBAR_LOAD_RUNNER_STATE_FILE="$FZ" MENUBAR_LOAD_RUNNER_LOG_ANIMATION=1 \
      MENUBAR_LOAD_RUNNER_LOG_SLOTS=1 MENUBAR_LOAD_RUNNER_EXIT_AFTER=5 $BIN --label "hi" 2>&1)
fk "custom label is respected while frozen (no handoff)" \
   "$(echo "$out" | grep '^ANIM' | tail -1 | grep -q 'labelHandoff=0' \
      && echo "$out" | grep '^SLOTS' | tail -1 | grep -q 'label="hi"' && echo 1 || echo 0)" \
   "got: $(echo "$out" | grep -E '^(ANIM|SLOTS)' | tail -2)"

# 4. Running baseline — gated on the machine's own Reduce Motion, which inverts it BY DESIGN: that
# setting is the user's, not the test's to control (the §3c/§3e shape — NOTE, never a false FAIL).
rm -f "$FZ"
if [ "$(defaults read com.apple.universalaccess reduceMotion 2>/dev/null || echo 0)" = 1 ]; then
  echo "  NOTE [running baseline unverifiable: this machine has Reduce Motion ON, so an unfrozen run"
  echo "       correctly freezes anyway — the frozen cases above still hold]"
else
  anim=$(MENUBAR_LOAD_RUNNER_STATE_FILE="$FZ" MENUBAR_LOAD_RUNNER_LOG_ANIMATION=1 \
         MENUBAR_LOAD_RUNNER_EXIT_AFTER=8 $BIN 2>&1 | grep '^ANIM')
  frames=$(echo "$anim" | sed -n 's/.*frame=\([0-9]*\).*/\1/p' | sort -u | wc -l | tr -d ' ')
  fk "unfrozen baseline runs and the frame advances" \
     "$([ -n "$anim" ] && ! echo "$anim" | grep -vq 'running=1 freeze=none' \
        && [ "${frames:-0}" -ge 2 ] && echo 1 || echo 0)" \
     "distinct frames=$frames raw:\n$anim"
fi
rm -f "$FZ"
echo "  freeze animation: passes=$pass fails=$fail"; total_fail=$((total_fail+fail))

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

# --- §5 Reader readouts [gui] ----------------------------------------------
# What each reader actually PUTS ON THE BAR, read back off the live status item via LOG_SLOTS. This
# replaced five standalone `.swift` probes (readers/scaler/label/semver/restart) that each re-ported the
# app's logic into a copy and asserted against the copy — every one of them carried "keep in sync with the
# real type; a mismatch = the port drifted", which is the failure mode backwards: the port passes while
# the app is broken. Deleted 2026-07-30. What no longer has a check at all is recorded as verification
# debt in docs/ROADMAP.md rather than left to look covered.
#
# Two invariants per source, both only observable against the real item:
#   - the readout has that source's SHAPE and a value in range (the reader ran and produced sense),
#   - the reserved slot width does NOT move as the value changes — the no-jitter promise. §3c asserts this
#     for CPU (a percent); the rate-shaped sources (NET/DISK) have their own wider templates, and a
#     template that doesn't fit its own readings is invisible to a percent-only check.
if [ "$RUN_GUI" = 1 ]; then
section "§5 reader readouts on the live item [gui — needs WindowServer]"
pass=0; fail=0
RO="$PWD/tmp/qa-readout-state.json"
rk(){ [ "$2" = 1 ] && { echo "  PASS [$1]"; pass=$((pass+1)); } || { echo "  FAIL [$1] $3"; fail=$((fail+1)); }; }
# `warming up` is legitimate for a counter-delta source on its first tick, so each shape allows the
# placeholder; what must never appear is a different source's shape or an out-of-range number.
for spec in "cpu:CPU:%" "memory:MEM:%" "gpu:GPU:%" "network:NET:rate" "disk:DSK:rate" "fan:FAN:%" "battery:BAT:%" "temperature:TMP:deg"; do
  src=${spec%%:*}; rest=${spec#*:}; tag=${rest%%:*}; shape=${rest##*:}
  out=$(MENUBAR_LOAD_RUNNER_LOG_SLOTS=1 MENUBAR_LOAD_RUNNER_STATE_FILE="$RO" \
        MENUBAR_LOAD_RUNNER_EXIT_AFTER=9 $BIN --label value --load-source "$src" 2>&1 | grep '^SLOTS')
  rm -f "$RO"
  # A source this machine lacks falls back to CPU and says so on stderr — not a failure (§3 covers it).
  if [ -z "$out" ] || ! echo "$out" | grep -q "label=\"$tag"; then
    echo "  NOTE [$src unavailable on this machine — reader disabled, launch fell back to cpu]"
    continue
  fi
  # Normalize U+2007 FIGURE SPACE to a plain space before matching: the app pads every number with it
  # (it is exactly a digit wide, which is what makes the reserved width hold), so a pattern written with
  # ASCII spaces matches nothing against the real readout. Same class of trap as the U+202F in §3e.
  labels=$(echo "$out" | sed -E 's/.*label="([^"]*)".*/\1/' | sed $'s/\xe2\x80\x87/ /g' | grep -v '…' | sort -u)
  case "$shape" in
    %)    bad=$(echo "$labels" | grep -vE "^$tag +[0-9]{1,3}%$") ;;
    # The arrow/letter is followed by its own padding ("NET ↓  0.1 ↑  0.0"), and alternation beats a
    # bracket expression here — a multibyte char inside [] is not portable in POSIX ERE.
    rate) bad=$(echo "$labels" | grep -vE "^$tag +(↓|R) *[0-9.]+ +(↑|W) *[0-9.]+$") ;;
    # Degrees Celsius, a third shape — neither a percent nor a rate, so `%` above rejects it. The
    # reader drops any sensor outside 1…125 °C, which is what makes 1-3 digits a true bound here.
    deg)  bad=$(echo "$labels" | grep -vE "^$tag +[0-9]{1,3}°$") ;;
  esac
  rk "$src readout has $tag's shape and an in-range value" \
     "$([ -z "$bad" ] && [ -n "$labels" ] && echo 1 || echo 0)" "unexpected: $(echo "$bad" | head -2)"
  # Widths across every tick of this run: one distinct value, or the slot is tracking its text.
  widths=$(echo "$out" | sed -E 's/.*(left|right)\[x=[0-9.]+ w=([0-9.]+)\].*/\2/' | sort -u | wc -l | tr -d ' ')
  readings=$(echo "$labels" | wc -l | tr -d ' ')
  rk "$src slot width is reserved, not auto-sized ($readings distinct readings)" \
     "$([ "${widths:-9}" = 1 ] && echo 1 || echo 0)" "widths seen: $(echo "$out" | sed -E 's/.*w=([0-9.]+)\].*/\1/' | sort -u | tr '\n' ' ')"
done
echo "  reader readouts: passes=$pass fails=$fail"; total_fail=$((total_fail+fail))
else
skip "§5 reader readouts [gui]" "GUI tier not selected (--core); needs a WindowServer session"
fi

# --- §6 Launcher wrapper [launcher] (opt-in; disruptive) -------------------
if [ "$RUN_LAUNCHER" = 1 ]; then
  section "§6 launcher wrapper + singleton [launcher — stops running instances]"
  # Every pgrep/pkill here is `-U "$(id -u)"`-scoped to match the launcher's guard: the poll has to
  # observe the same process set the guard does, and a QA run must never signal another account's
  # instance on a machine with fast user switching.
  pkill -U "$(id -u)" -f 'MenuBarLoadRunner' 2>/dev/null; sleep 1
  MENUBAR_LOAD_RUNNER_EXIT_AFTER=3 ./menubar-load-runner --foreground --load-source memory 2>&1 | tail -1

  # --precompile is the in-app updater's build step: it must produce the binary and start NOTHING.
  # (The whole point is that it runs before the app quits, so the restart doesn't pay for the compile.)
  touch MenuBarLoadRunner.swift
  ./menubar-load-runner --precompile
  { [ MenuBarLoadRunner -nt MenuBarLoadRunner.swift ] \
    && ! pgrep -U "$(id -u)" -f "/MenuBarLoadRunner( |$)" >/dev/null; } \
    && echo "  PASS --precompile builds and launches nothing" \
    || { echo "  FAIL --precompile (binary stale, or it started an instance)"; total_fail=$((total_fail+1)); }

  # Launch the "victim" instance with a generous self-exit window (a long QA run leaves the machine
  # busy, and the rebuild below adds a compile, so a short EXIT_AFTER could fire before the checks
  # complete), then poll up to ~10s for it to finish AppKit init and register. pkill cleans up after.
  MENUBAR_LOAD_RUNNER_EXIT_AFTER=90 ./menubar-load-runner --load-source memory >/dev/null 2>&1
  for _ in $(seq 10); do pgrep -U "$(id -u)" -f "/MenuBarLoadRunner( |$)" >/dev/null && break; sleep 1; done
  victim=$(pgrep -U "$(id -u)" -f "/MenuBarLoadRunner( |$)" | head -1)

  # The guard runs BEFORE the compile, so a rejected launch costs a pgrep and leaves the binary alone.
  # Asserted on the binary's mtime with the source deliberately stale: a guard that ran second would
  # rebuild here, which is how a second swiftc used to be able to race the one already in flight.
  touch MenuBarLoadRunner.swift
  before=$(stat -f %m MenuBarLoadRunner)
  # Capture into a var, then match without a pipe: under `set -o pipefail`, `… | grep -q` makes the
  # launcher take SIGPIPE (141) when grep closes the pipe after matching its first line, and pipefail
  # would report that as a false failure even though the singleton correctly printed "already running".
  out=$(./menubar-load-runner --load-source cpu 2>&1)
  case "$out" in
    *"already running"*) echo "  PASS singleton rejects 2nd" ;;
    *) echo "  FAIL singleton (got: $out)"; total_fail=$((total_fail+1)) ;;
  esac
  [ "$(stat -f %m MenuBarLoadRunner)" = "$before" ] \
    && echo "  PASS rejected launch did not compile" \
    || { echo "  FAIL rejected launch rebuilt the binary (guard runs after the compile)"; total_fail=$((total_fail+1)); }

  # …and the rebuild that the updater performs while an instance is live must not disturb it. The
  # build is renamed into place rather than written over the binary, so the running process keeps its
  # own inode; an in-place overwrite is what kills the victim here. (Also leaves the tree built.)
  ./menubar-load-runner --precompile
  { [ -n "$victim" ] && kill -0 "$victim" 2>/dev/null; } \
    && echo "  PASS live instance survives a rebuild (pid $victim)" \
    || { echo "  FAIL live instance died during --precompile (pid ${victim:-none})"; total_fail=$((total_fail+1)); }

  pkill -U "$(id -u)" -f 'MenuBarLoadRunner' 2>/dev/null
else
  skip "§6 launcher wrapper [launcher]" "disruptive — re-run with: tests/qa.sh --launcher"
fi

# --- Cleanup + verdict -----------------------------------------------------
rm -f "$BIN" ./tmp/qa-lifecycle-state.json ./tmp/qa-ka-state.json ./tmp/qa-settings-state.json
printf '\n'
if [ "$total_fail" = 0 ]; then echo "QA: ALL PASS (ROADMAP click-only checks still to do)"; exit 0
else echo "QA: $total_fail FAILING section(s)"; exit 1; fi
