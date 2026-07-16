#!/bin/bash
# MenuBar Load Runner — uninstaller. Reverses install.sh.
#
#   ~/.local/share/menubar-load-runner/uninstall.sh
#
# Removes, in order: the start-at-login LaunchAgent (if enabled), any running instance, the
# launcher symlink on your PATH, and the cloned install directory. It only removes things it
# recognizes as ours (a symlink pointing into the install dir; a dir that is our git checkout),
# so it won't clobber an unrelated file of the same name.
#
# Env overrides (match install.sh): MENUBAR_LOAD_RUNNER_HOME (install dir), BIN_DIR (symlink dir).
# Flags: --yes (don't prompt before deleting the install dir), -h/--help.
set -euo pipefail

INSTALL_DIR="${MENUBAR_LOAD_RUNNER_HOME:-$HOME/.local/share/menubar-load-runner}"
BIN_DIR="${BIN_DIR:-$HOME/.local/bin}"
LAUNCHER_NAME="menubar-load-runner"
LABEL="ai.bera.menubarloadrunner"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

ASSUME_YES="no"

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m ✓ \033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m ! \033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<EOF
MenuBar Load Runner uninstaller

Usage: uninstall.sh [--yes]
  --yes        remove the install dir without asking
  -h, --help   show this help

Removes the LaunchAgent (if any), the PATH symlink in \$BIN_DIR, and the install dir
(\$MENUBAR_LOAD_RUNNER_HOME, default ~/.local/share/menubar-load-runner).
EOF
  exit 0
}

while [ $# -gt 0 ]; do
  case "$1" in
    --yes)     ASSUME_YES="yes" ;;
    -h|--help) usage ;;
    *)         die "unknown argument: $1 (see --help)" ;;
  esac
  shift
done

info "MenuBar Load Runner uninstaller"

# --- 1. Start-at-login LaunchAgent ----------------------------------------
if [ -e "$PLIST" ]; then
  info "Removing start-at-login LaunchAgent…"
  if [ -x "$INSTALL_DIR/scripts/uninstall-login-item.sh" ]; then
    "$INSTALL_DIR/scripts/uninstall-login-item.sh" || warn "login-item uninstall reported an error"
  else
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    rm -f "$PLIST" "/tmp/$LABEL.log"
    ok "Removed $PLIST"
  fi
fi

# --- 2. Stop any running instance -----------------------------------------
if pkill -f "/MenuBarLoadRunner( |$)" 2>/dev/null; then
  ok "Stopped running instance"
fi

# --- 3. PATH symlink -------------------------------------------------------
link="$BIN_DIR/$LAUNCHER_NAME"
if [ -L "$link" ]; then
  case "$(readlink "$link")" in
    "$INSTALL_DIR"/*) rm -f "$link"; ok "Removed symlink $link" ;;
    *) warn "Left $link (does not point into $INSTALL_DIR)" ;;
  esac
elif [ -e "$link" ]; then
  warn "Left $link (not a symlink — not created by the installer)"
fi

# --- 4. Install directory --------------------------------------------------
if [ -d "$INSTALL_DIR/.git" ]; then
  # Deleting is destructive, so default to KEEP unless consent is explicit: --yes, or an
  # interactive y/N answer. A non-interactive run without --yes (piped/automation, no tty) leaves
  # the dir in place rather than silently `rm -rf`-ing it — pass --yes to delete unattended.
  remove="no"
  if [ "$ASSUME_YES" = "yes" ]; then
    remove="yes"
  elif { : < /dev/tty; } 2>/dev/null; then
    read -r -p "Delete the install dir $INSTALL_DIR? [y/N] " reply < /dev/tty || reply=""
    case "$reply" in [Yy]*) remove="yes" ;; esac
  else
    warn "No terminal and --yes not given; leaving $INSTALL_DIR (re-run with --yes to delete)"
  fi
  if [ "$remove" = "yes" ]; then
    rm -rf "$INSTALL_DIR"
    ok "Removed $INSTALL_DIR"
  else
    info "Left $INSTALL_DIR in place"
  fi
elif [ -e "$INSTALL_DIR" ]; then
  warn "Left $INSTALL_DIR (not our git checkout — remove it manually if you're sure)"
else
  info "No install dir at $INSTALL_DIR"
fi

printf '\n'
ok "Uninstalled."
