#!/bin/bash
# Remove the MenuBar Load Runner login item — the exact inverse of install-login-item.sh:
# deregister the LaunchAgent, then delete its plist and log. No root, no residue
# (no receipts DB, no Background Task Management entry). Safe to run repeatedly.
set -euo pipefail

LABEL="ai.bera.menubarloadrunner"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="/tmp/$LABEL.log"
DOMAIN="gui/$(id -u)"

# bootout reverses bootstrap: stops the supervised process and removes the registration.
# (We never use `launchctl disable`, which would leave a persistent override behind.)
launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
rm -f "$PLIST"
rm -f "$LOG"

echo "Removed login item: $LABEL"
echo "  deregistered; plist + log deleted; nothing else was installed."
echo "Note: an instance you launched manually is not affected — stop it with: pkill -f 'MenuBarLoadRunner'"
