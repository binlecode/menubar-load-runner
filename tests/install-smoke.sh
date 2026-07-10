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

rm -rf "$ROOT"

say "fresh install into sandbox"
MENUBAR_LOAD_RUNNER_HOME="$ROOT/share/menubar-load-runner" BIN_DIR="$ROOT/bin" \
  MENUBAR_LOAD_RUNNER_REPO_URL="$REPO_URL" bash install.sh >/dev/null 2>&1
chk "$([ -L "$ROOT/bin/menubar-load-runner" ] && echo y)" y "launcher symlink created"
chk "$([ -x "$ROOT/share/menubar-load-runner/MenuBarLoadRunner" ] && echo y)" y "binary built"

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
sed -e 's#^PLIST=.*#PLIST="$INSTALL_DIR/nonexistent.plist"#' -e 's#if pkill -f#if true#' \
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
