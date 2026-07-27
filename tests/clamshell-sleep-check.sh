#!/bin/bash
# Docked-clamshell sleep probe — measures whether this Mac idle-sleeps while docked, and whether
# Keep Awake can hold it. Run from the repo root:  tests/clamshell-sleep-check.sh
#
# Unlike tests/qa.sh this is NOT a pass/fail gate and is not part of any coverage tier: it measures
# host power-management behavior, which varies per machine and per macOS version, so there is no
# correct answer to assert. It is a diagnostic you read. Written for R12 Problem 3
# (docs/TODO-20260726-2100-r12-external-display-auto-arm.md) — does a docked Mac already stay awake
# on its own, making auto-arm-on-external-display decoration?
#
# WHY mark/report INSTEAD OF LIVE POLLING
#   The signal being measured IS the machine sleeping, which suspends any watcher. So: timestamp a
#   marker, let the machine do whatever it does, then mine `pmset -g log` after the fact. Nothing
#   needs to stay running, and reports can be read hours later.
#
# PREREQUISITE — a quiet machine
#   Any process holding a sleep assertion prevents idle sleep and makes every trial report "stayed
#   awake" for the wrong reason. Editors, terminals, audio playback, backups, downloads and
#   background agents all do this routinely. `preflight` enumerates holders and must exit 0 first.
#   It exempts exactly two roles: powerd's display-gated assertion (the mechanism under test) and
#   this app's own caffeinate, by the ' -w <pid>' signature AGENTS.md documents.
#
# SETUP (once)
#   tests/clamshell-sleep-check.sh baseline    # save pmset settings so restore can undo
#   tests/clamshell-sleep-check.sh fast        # sudo: AC displaysleep 2, sleep 1 (~3min/trial)
#   tests/clamshell-sleep-check.sh preflight   # must exit 0
#
# TRIALS — external display AND power connected for all three. For each: mark, do the physical
# action, leave the Mac completely untouched >=5 min, wake it, report.
#
#   1) control-lid-open
#        Lid OPEN, docked, idle. Expect display off at ~2min then Idle Sleep at ~3min.
#        Establishes the timers work and that the probe can detect sleep at all. If this trial
#        does not sleep, every later "stayed awake" is meaningless.
#
#   2) clamshell-no-keepawake            <-- the R12 question
#        Lid CLOSED, docked, Keep Awake OFF in the app's menu.
#        Sleeps -> a docked Mac does NOT stay awake on its own; R12 has real value.
#        Stays  -> it already stays awake; R12's system-sleep pitch is dead and only the display
#                  half of `caffeinate -di` remains (Problem 3 item 2) — a narrower, honest pitch.
#
#   3) clamshell-with-keepawake          <-- decides the item
#        Lid CLOSED, docked, Keep Awake ARMED (indefinite) in the app's menu.
#        Stays  -> the feature would work; proceed to Problems 1 and 2.
#        Sleeps -> caffeinate cannot hold a docked clamshell Mac awake, extending the roadmap's
#                  "Clamshell sleep can't be prevented" limit to the docked case. DECLINE R12: no
#                  wiring can deliver what it promises.
#
#   Trial 3 only means something if trial 2 slept. If 2 stayed awake, skip 3 and instead judge
#   whether the display-sleep half alone justifies a toggle.
#
# TEARDOWN (do not skip)
#   tests/clamshell-sleep-check.sh restore     # sudo: put pmset timers back
#
# ALSO CAPTURED (R12 Problem 2, free while the hardware is being handled)
#   `displays` prints CGDisplayIsBuiltin per screen next to the naive count>1 predicate. Run it
#   once docked with the lid open and once in clamshell (via ssh, or immediately after waking) to
#   confirm clamshell reports count==1 while hasExternalDisplay stays true — the TODO's
#   load-bearing detection claim, whose failure mode is silent.
#
# State and reports land in tmp/r12-state/ (gitignored). Durable findings belong in
# docs/ROADMAP.md R12 and the TODO — tmp/ is deletable at any moment.
#
# COMMANDS
#   preflight | displays | baseline | fast | restore | mark <label> | report <label> | --help
set -uo pipefail
cd "$(dirname "$0")/.."

mkdir -p tmp                 # tmp/ is gitignored; a fresh checkout (CI) won't have it
STATE_DIR=tmp/r12-state
BASELINE="$STATE_DIR/pmset-baseline.txt"
mkdir -p "$STATE_DIR"

note() { printf '%s\n' "$*"; }
hr()   { printf -- '------------------------------------------------------------\n'; }

# --- confounds -------------------------------------------------------------

# Classified by ROLE, not by process name: hardcoding one known offender would miss coreaudiod
# during audio playback, sharingd for Handoff, a backup, a download, or the next tool that does
# the same thing.
cmd_preflight() {
  local blockers=0 line pid pname kind args
  note "== Sleep-assertion holders =="
  hr
  local found=0
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    found=1
    pid=${line#*pid }; pid=${pid%%(*}
    pname=${line#*(};  pname=${pname%%)*}
    kind=""
    case "$line" in *PreventUserIdleSystemSleep*)  kind="${kind}system " ;; esac
    case "$line" in *PreventUserIdleDisplaySleep*) kind="${kind}display " ;; esac
    case "$line" in *PreventSystemSleep*)          kind="${kind}system(forced) " ;; esac
    args=$(ps -o args= -p "$pid" 2>/dev/null)

    case "$line" in
      *"Prevent sleep while display is on"*)
        note "OK       pid=$pid ($pname) — powerd, display-gated"
        note "         this is the mechanism under test, not a confound" ;;
      *)
        case "$args" in
          *caffeinate*" -w "*)
            note "OK       pid=$pid ($pname) — app under test (-w signature)"
            note "         args: $args" ;;
          *)
            note "BLOCKER  pid=$pid ($pname) holds: ${kind:-unknown}"
            note "         args: ${args:-<exited>}"
            blockers=$((blockers+1)) ;;
        esac ;;
    esac
  done < <(pmset -g assertions 2>/dev/null \
             | awk '/Listed by owning process/,0' \
             | grep -E 'PreventUserIdleSystemSleep|PreventUserIdleDisplaySleep|PreventSystemSleep')
  [ "$found" -eq 0 ] && note "(no holders at all)"
  hr
  if [ "$blockers" -gt 0 ]; then
    note "BLOCKED: $blockers unrelated holder(s) will prevent idle sleep, so every"
    note "trial would report 'stayed awake' for the wrong reason."
    note "Quit or stop the processes listed above, then re-run preflight."
    note "Some respawn on a loop — if a pid returns, quit its parent, not it."
    return 1
  fi
  note "Clean: nothing but the app and powerd holds an assertion."
  return 0
}

# --- environment snapshot --------------------------------------------------

cmd_displays() {
  note "== Display topology (R12 Problem 2's predicate, on real hardware) =="
  local src="$STATE_DIR/displays.swift"
  cat > "$src" <<'SWIFT'
import AppKit
import CoreGraphics
let screens = NSScreen.screens
print("NSScreen.screens.count = \(screens.count)")
var externals = 0
for (i, s) in screens.enumerated() {
    let id = s.deviceDescription[.init("NSScreenNumber")] as? CGDirectDisplayID
    let builtin = id.map { CGDisplayIsBuiltin($0) != 0 }
    if builtin == false { externals += 1 }
    print("  [\(i)] id=\(id.map(String.init) ?? "nil") builtin=\(builtin.map(String.init) ?? "unknown") frame=\(s.frame)")
}
print("hasExternalDisplay (CGDisplayIsBuiltin==0) = \(externals > 0)")
print("count>1 predicate would say = \(screens.count > 1)")
SWIFT
  swift "$src" 2>&1 | sed 's/^/  /'
  hr
  note "== Power source =="
  pmset -g batt | sed 's/^/  /'
  hr
  note "== Effective timers =="
  pmset -g | grep -E '^ (sleep|displaysleep|disksleep|standby|hibernatemode)' | sed 's/^/  /'
}

cmd_baseline() {
  if [ -f "$BASELINE" ]; then
    note "Baseline already saved at $BASELINE (not overwriting)."
  else
    pmset -g custom > "$BASELINE"
    note "Saved baseline -> $BASELINE"
  fi
  sed 's/^/  /' "$BASELINE"
}

# --- timer shortening (needs sudo; always reversible) ----------------------

cmd_fast() {
  [ -f "$BASELINE" ] || { note "Run 'tests/clamshell-sleep-check.sh baseline' first."; return 1; }
  note "Shortening AC timers so each trial takes ~3min instead of ~11min."
  note "  displaysleep 2, sleep 1   (AC only; the battery block is untouched)"
  note "Reverse with: tests/clamshell-sleep-check.sh restore"
  sudo pmset -c displaysleep 2 sleep 1 || return 1
  pmset -g custom | awk '/AC Power/,0' | grep -E 'displaysleep|^ sleep' | sed 's/^/  /'
}

cmd_restore() {
  [ -f "$BASELINE" ] || { note "No baseline to restore from."; return 1; }
  local ac_disp ac_sleep bat_disp bat_sleep
  ac_disp=$(awk '/AC Power/,0' "$BASELINE"            | awk '$1=="displaysleep"{print $2}')
  ac_sleep=$(awk '/AC Power/,0' "$BASELINE"           | awk '$1=="sleep"{print $2}')
  bat_disp=$(awk '/Battery Power/,/AC Power/' "$BASELINE"  | awk '$1=="displaysleep"{print $2}')
  bat_sleep=$(awk '/Battery Power/,/AC Power/' "$BASELINE" | awk '$1=="sleep"{print $2}')
  for v in "$ac_disp" "$ac_sleep" "$bat_disp" "$bat_sleep"; do
    case "$v" in ''|*[!0-9]*) note "Baseline looks malformed; refusing to write. Inspect $BASELINE"; return 1 ;; esac
  done
  note "Restoring: AC displaysleep=$ac_disp sleep=$ac_sleep | Batt displaysleep=$bat_disp sleep=$bat_sleep"
  sudo pmset -c displaysleep "$ac_disp" sleep "$ac_sleep" || return 1
  sudo pmset -b displaysleep "$bat_disp" sleep "$bat_sleep" || return 1
  note "Restored. Verify:"
  pmset -g custom | sed 's/^/  /'
}

# --- the trials ------------------------------------------------------------

cmd_mark() {
  local label="${1:-}"
  [ -z "$label" ] && { note "usage: tests/clamshell-sleep-check.sh mark <trial-label>"; return 1; }
  local ts; ts=$(date '+%Y-%m-%d %H:%M:%S')
  printf '%s\n' "$ts" > "$STATE_DIR/mark-$label"
  {
    printf '# trial: %s\n# marked: %s\n# screens/power at mark:\n' "$label" "$ts"
    cmd_displays
    printf '# assertions at mark:\n'
    pmset -g assertions 2>/dev/null | awk '/Listed by owning process/,0'
  } > "$STATE_DIR/context-$label.txt" 2>&1
  hr
  note "MARKED '$label' at $ts"
  note "Context -> $STATE_DIR/context-$label.txt"
  note ""
  note "Now do the trial's physical action, then leave the Mac completely alone"
  note "(no key, no trackpad, no mouse) for at least 5 minutes. Afterwards wake"
  note "it and run:  tests/clamshell-sleep-check.sh report $label"
}

# pmset log lines lead with 'YYYY-MM-DD HH:MM:SS -ZZZZ', so a lexical compare against the mark is
# safe and needs no date math.
since_mark() {
  local mark="$1"
  pmset -g log 2>/dev/null | awk -v m="$mark" '
    /^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}/ {
      if (substr($0,1,19) >= m) print
    }'
}

cmd_report() {
  local label="${1:-}"
  [ -z "$label" ] && { note "usage: tests/clamshell-sleep-check.sh report <trial-label>"; return 1; }
  local markfile="$STATE_DIR/mark-$label"
  [ -f "$markfile" ] || { note "No mark for '$label'. Run 'mark $label' first."; return 1; }
  local mark; mark=$(cat "$markfile")
  local out="$STATE_DIR/report-$label.txt"
  {
    note "== Trial report: $label =="
    note "marked at: $mark"
    note "now:       $(date '+%Y-%m-%d %H:%M:%S')"
    hr
    note "== Sleep / Wake / Display events since the mark =="
    since_mark "$mark" | grep -E 'Sleep|Wake|Display' \
      || note "(none — the Mac stayed fully awake)"
    hr
    note "== HOW TO READ IT =="
    note "  'Clamshell Sleep'   -> lid close slept it despite the dock"
    note "  'Idle Sleep'        -> the idle timer slept it"
    note "  display off, then NO Sleep line"
    note "                      -> display slept, SYSTEM STAYED AWAKE"
    note "  nothing at all      -> neither slept; check the assertion list below"
    hr
    note "== Assertion churn since the mark (who held what) =="
    since_mark "$mark" | grep -E 'Assertions' | tail -30 || note "(none)"
  } | tee "$out"
  hr
  note "Saved -> $out"
}

case "${1:-}" in
  preflight) shift; cmd_preflight "$@" ;;
  displays)  shift; cmd_displays  "$@" ;;
  baseline)  shift; cmd_baseline  "$@" ;;
  fast)      shift; cmd_fast      "$@" ;;
  restore)   shift; cmd_restore   "$@" ;;
  mark)      shift; cmd_mark      "$@" ;;
  report)    shift; cmd_report    "$@" ;;
  ''|-h|--help|help)
    awk 'NR==1{next} /^#/{sub(/^# ?/,"");print;next} {exit}' "$0" ;;
  *) note "unknown: $1 (try --help)"; exit 2 ;;
esac
