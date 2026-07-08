#!/bin/bash
# Install MenuBar Load Runner as a per-user login item via a LaunchAgent.
#
# Personal-use auto-start: no root, no packaging, no .app bundle. The entire
# footprint is one plist in ~/Library/LaunchAgents/, fully reversed by
# scripts/uninstall-login-item.sh.
#
# Any extra args are baked into the login item (preset keyword, --load-source, etc.):
#   ./scripts/install-login-item.sh
#   ./scripts/install-login-item.sh dog-black --load-source memory
set -euo pipefail

LABEL="ai.bera.menubarloadrunner"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="/tmp/$LABEL.log"
DOMAIN="gui/$(id -u)"

# Resolve this script's real directory (following symlinks) -> repo root -> launcher.
src="${BASH_SOURCE[0]}"
while [ -h "$src" ]; do
  dir="$(cd -P "$(dirname "$src")" && pwd)"
  src="$(readlink "$src")"
  [[ "$src" != /* ]] && src="$dir/$src"
done
SCRIPT_DIR="$(cd -P "$(dirname "$src")" && pwd)"
REPO_DIR="$(cd -P "$SCRIPT_DIR/.." && pwd)"
LAUNCHER="$REPO_DIR/menubar-load-runner"

[ -x "$LAUNCHER" ] || { echo "error: launcher not found or not executable: $LAUNCHER" >&2; exit 1; }

# Best-effort pre-build so login start doesn't depend on swiftc being on launchd's PATH.
if command -v swiftc >/dev/null 2>&1; then
  echo "Pre-building binary…"
  swiftc -O -strict-concurrency=complete "$REPO_DIR/MenuBarLoadRunner.swift" -o "$REPO_DIR/MenuBarLoadRunner" \
    || echo "warn: pre-build failed; login start will fall back to on-demand compile" >&2
fi

# ProgramArguments: launcher, then --no-detach so launchd supervises the real process
# (the launcher's default detach-and-exit would look like the job finished), then passthrough args.
xml_escape(){ local s="$1"; s="${s//&/&amp;}"; s="${s//</&lt;}"; s="${s//>/&gt;}"; printf '%s' "$s"; }
prog=""
for a in "$LAUNCHER" "--no-detach" "$@"; do
  prog+="    <string>$(xml_escape "$a")</string>"$'\n'
done

mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${LABEL}</string>
    <key>ProgramArguments</key>
    <array>
${prog}    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin</string>
    </dict>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${LOG}</string>
    <key>StandardErrorPath</key>
    <string>${LOG}</string>
</dict>
</plist>
PLIST_EOF
# NOTE: no KeepAlive on purpose — choosing Exit from the menu quits it until next login.

# Idempotent (re)load: bootout first so a re-install doesn't hit "service already loaded".
launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
launchctl bootstrap "$DOMAIN" "$PLIST"
launchctl kickstart -k "$DOMAIN/$LABEL" 2>/dev/null || true   # start now, no logout needed

echo "Installed login item: $LABEL"
echo "  plist:   $PLIST"
echo "  command: $LAUNCHER --no-detach $*"
echo "  log:     $LOG"
echo "Uninstall: $SCRIPT_DIR/uninstall-login-item.sh"
