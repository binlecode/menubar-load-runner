#!/bin/bash
# MenuBar Load Runner — one-line installer.
#
#   curl -fsSL https://raw.githubusercontent.com/binlecode/menubar-load-runner/main/install.sh | bash
#
# This app is source-based: the launcher compiles MenuBarLoadRunner.swift on demand and reads
# gifs/ + presets.json relative to the source, so the whole repo lives at a permanent path. This
# script clones (or updates) it into ~/.local/share/menubar-load-runner, precompiles the binary,
# symlinks the launcher onto your PATH at ~/.local/bin/menubar-load-runner, then optionally sets
# up start-at-login via the per-user LaunchAgent.
#
# Env overrides: MENUBAR_LOAD_RUNNER_HOME (install dir), BIN_DIR (symlink dir),
#                MENUBAR_LOAD_RUNNER_REPO_URL (clone source).
# Flags: --login (set up start-at-login without prompting), -h/--help.
#
# The whole body runs from main() invoked on the LAST line, so a truncated `curl | bash` download
# (network drop mid-stream) can't execute a partial install — bash won't call an undefined/partial
# main. Keep `main "$@"` as the final statement.
set -euo pipefail

REPO="binlecode/menubar-load-runner"
REPO_URL="${MENUBAR_LOAD_RUNNER_REPO_URL:-https://github.com/$REPO.git}"
INSTALL_DIR="${MENUBAR_LOAD_RUNNER_HOME:-$HOME/.local/share/menubar-load-runner}"
BIN_DIR="${BIN_DIR:-$HOME/.local/bin}"
LAUNCHER_NAME="menubar-load-runner"

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m ✓ \033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m ! \033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<EOF
MenuBar Load Runner installer

Usage: install.sh [--login]
  --login      set up start-at-login without prompting (default: ask if interactive)
  -h, --help   show this help

Installs to \$MENUBAR_LOAD_RUNNER_HOME (default ~/.local/share/menubar-load-runner) and
symlinks the launcher into \$BIN_DIR (default ~/.local/bin).
EOF
  exit 0
}

main() {
  local DO_LOGIN="prompt"   # prompt | yes

  while [ $# -gt 0 ]; do
    case "$1" in
      --login)   DO_LOGIN="yes" ;;
      -h|--help) usage ;;
      *)         die "unknown argument: $1 (see --help)" ;;
    esac
    shift
  done

  # --- Preflight -------------------------------------------------------------
  info "MenuBar Load Runner installer"

  [ "$(uname -s)" = "Darwin" ] || die "this is a macOS-only menu bar app (found $(uname -s))"

  if ! command -v git >/dev/null 2>&1 || ! command -v swiftc >/dev/null 2>&1; then
    warn "git and swiftc are required (both ship with the Xcode Command Line Tools)."
    die "install them with:  xcode-select --install"
  fi
  ok "macOS $(sw_vers -productVersion 2>/dev/null || true), $(swiftc --version 2>/dev/null | head -1)"

  # --- Fetch / update --------------------------------------------------------
  if [ -d "$INSTALL_DIR/.git" ]; then
    info "Updating existing install at $INSTALL_DIR"
    git -C "$INSTALL_DIR" pull --quiet --ff-only
  else
    [ -e "$INSTALL_DIR" ] && die "$INSTALL_DIR exists but is not a git checkout; move it aside and retry"
    info "Cloning $REPO_URL"
    mkdir -p "$(dirname "$INSTALL_DIR")"
    git clone --quiet "$REPO_URL" "$INSTALL_DIR"
  fi
  ok "Source at $INSTALL_DIR ($(git -C "$INSTALL_DIR" describe --tags --always 2>/dev/null || echo unknown))"

  # --- Build -----------------------------------------------------------------
  info "Compiling (swiftc -O)…"
  if swiftc -O -strict-concurrency=complete "$INSTALL_DIR/MenuBarLoadRunner.swift" \
       -o "$INSTALL_DIR/MenuBarLoadRunner" 2>/dev/null; then
    ok "Built $INSTALL_DIR/MenuBarLoadRunner"
  else
    warn "precompile failed; the launcher will compile on first run instead"
  fi

  # --- Link onto PATH --------------------------------------------------------
  mkdir -p "$BIN_DIR"
  ln -sf "$INSTALL_DIR/$LAUNCHER_NAME" "$BIN_DIR/$LAUNCHER_NAME"
  ok "Linked $BIN_DIR/$LAUNCHER_NAME -> $INSTALL_DIR/$LAUNCHER_NAME"

  # --- Start at login (optional) ---------------------------------------------
  # Prompt only when a terminal is actually openable; a piped `curl | bash` in a headless
  # context has no usable tty, so it safely skips (the `{ : < /dev/tty; }` tests openability,
  # not mere existence, and swallows the "Device not configured" error).
  if [ "$DO_LOGIN" = "prompt" ] && { : < /dev/tty; } 2>/dev/null; then
    printf '\n'
    read -r -p "Start MenuBar Load Runner now and at every login? [y/N] " reply < /dev/tty || reply=""
    case "$reply" in [Yy]*) DO_LOGIN="yes" ;; esac
  fi
  if [ "$DO_LOGIN" = "yes" ]; then
    info "Setting up start-at-login LaunchAgent…"
    "$INSTALL_DIR/scripts/install-login-item.sh"
  else
    info "Skipping start-at-login (enable later: $INSTALL_DIR/scripts/install-login-item.sh)"
  fi

  # --- Done ------------------------------------------------------------------
  printf '\n'
  ok "Installed."
  case ":$PATH:" in
    *":$BIN_DIR:"*) info "Run it:  $LAUNCHER_NAME" ;;
    *)
      warn "$BIN_DIR is not on your PATH. Add it, then reopen your shell:"
      # shellcheck disable=SC2016  # $PATH is intentionally literal — it goes into the user's .zshrc
      printf '    echo '\''export PATH="%s:$PATH"'\'' >> ~/.zshrc\n' "$BIN_DIR"
      info "Or run it directly:  $INSTALL_DIR/$LAUNCHER_NAME"
      ;;
  esac
}

main "$@"
