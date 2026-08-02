#!/bin/bash
# Install/uninstall smoke test — exercises install.sh and uninstall.sh end-to-end inside a throwaway
# sandbox under tmp/, cloning from the LOCAL repo (committed HEAD). It never touches your real
# ~/.local, ~/Library/LaunchAgents, or any running instance: the LaunchAgent-removal and pkill steps
# in uninstall.sh are neutralized in the sandbox copy (they act on global state, not the sandbox).
# Run from the repo root:  tests/install-smoke.sh   (exits 0 on success)
set -uo pipefail
cd "$(dirname "$0")/.."

ROOT="$PWD/tmp/install-smoke"
REPO_URL="file://$PWD"
fail=0
say(){ printf '\n=== %s ===\n' "$1"; }
chk(){ [ "$1" = "$2" ] && echo "  PASS $3" || { echo "  FAIL $3 (got '$1' want '$2')"; fail=$((fail+1)); }; }

# Backstop: nothing this test starts may outlive it. The sandbox gets deleted, so a survivor loses
# gifs/presets.json underneath itself and throws a modal startup error at the developer — which a
# failing test must not do on top of failing. `-f "$ROOT"` scopes every signal to this sandbox's own
# processes, so it can never reach the real instance (the same rule the neutralized pkill below
# follows). On EXIT, so an early failure can't skip it.
trap 'pkill -U "$(id -u)" -f "$ROOT" 2>/dev/null' EXIT

rm -rf "$ROOT"

say "fresh install into sandbox"
MENUBAR_LOAD_RUNNER_HOME="$ROOT/share/menubar-load-runner" BIN_DIR="$ROOT/bin" \
  MENUBAR_LOAD_RUNNER_REPO_URL="$REPO_URL" bash install.sh >/dev/null 2>&1
chk "$([ -L "$ROOT/bin/menubar-load-runner" ] && echo y)" y "launcher symlink created"
chk "$([ -x "$ROOT/share/menubar-load-runner/MenuBarLoadRunner" ] && echo y)" y "binary built"
# Installing BUILDS; it must never START the app — the only launch install.sh offers is the opt-in
# login item, and this run answers no to that prompt. Worth asserting because "binary built" alone
# can't tell a precompile from a full launch that happened to leave a binary behind: seen for real
# when install.sh's build step began calling a launcher flag that the cloned (committed) launcher
# didn't have yet, so it was forwarded as an app argument and started an instance out of the sandbox.
#
# Then KILL what it found, which is not optional tidiness. The uninstall step below deletes the
# sandbox, and a surviving instance loses gifs/presets.json out from under itself and throws a modal
# startup error at whoever is sitting there — a test that fails should not also leave a dialog on the
# developer's screen. Every pattern here is scoped to $ROOT, so it can only match this sandbox's own
# processes, never the developer's live instance.
sleep 1
chk "$(pgrep -U "$(id -u)" -f "$ROOT" >/dev/null && echo y || echo n)" n "install started no instance"
pkill -U "$(id -u)" -f "$ROOT" 2>/dev/null && echo "  (killed the sandbox instance it started)"

say "re-run install (update path, not clone)"
out=$(MENUBAR_LOAD_RUNNER_HOME="$ROOT/share/menubar-load-runner" BIN_DIR="$ROOT/bin" \
  MENUBAR_LOAD_RUNNER_REPO_URL="$REPO_URL" bash install.sh 2>&1)
echo "$out" | grep -q "Updating existing install" && echo "  PASS took update path" || { echo "  FAIL did not update in place"; fail=$((fail+1)); }

say "installed launcher runs"
"$ROOT/share/menubar-load-runner/menubar-load-runner" --help >/dev/null 2>&1
chk "$?" 0 "launcher --help rc=0"

# Sandbox uninstall: neutralize the two global-state steps (real plist + real pkill) so the smoke
# test only exercises the sandbox-scoped symlink + dir removal.
say "uninstall (sandboxed: global steps neutralized)"
# The pkill neutralizer matches the whole `if pkill …` line, not a `pkill -f` substring: the real
# line carries a `-U "$(id -u)"` scope flag, and a substring pattern would silently stop matching
# the next time its flags change — letting the smoke test kill the developer's live instance.
sed -e 's#^PLIST=.*#PLIST="$INSTALL_DIR/nonexistent.plist"#' -e 's#^if pkill .*#if true; then#' \
  uninstall.sh > "$ROOT/uninstall-sandbox.sh"
MENUBAR_LOAD_RUNNER_HOME="$ROOT/share/menubar-load-runner" BIN_DIR="$ROOT/bin" \
  bash "$ROOT/uninstall-sandbox.sh" --yes >/dev/null 2>&1
chk "$([ -L "$ROOT/bin/menubar-load-runner" ] && echo present || echo gone)" gone "symlink removed"
chk "$([ -d "$ROOT/share/menubar-load-runner" ] && echo present || echo gone)" gone "install dir removed"

say "uninstall refuses a non-checkout dir"
mkdir -p "$ROOT/share/menubar-load-runner"; echo x > "$ROOT/share/menubar-load-runner/not-a-repo.txt"
MENUBAR_LOAD_RUNNER_HOME="$ROOT/share/menubar-load-runner" BIN_DIR="$ROOT/bin" \
  bash "$ROOT/uninstall-sandbox.sh" --yes >/dev/null 2>&1
chk "$([ -d "$ROOT/share/menubar-load-runner" ] && echo present || echo gone)" present "left non-checkout dir intact"

rm -rf "$ROOT"
printf '\n'
[ "$fail" = 0 ] && { echo "install-smoke: ALL PASS"; exit 0; } || { echo "install-smoke: $fail FAIL"; exit 1; }
