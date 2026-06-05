#!/bin/bash
set -euo pipefail

PLIST_NAME="app.muxy.daemon.plist"
PLIST_DEST="$HOME/Library/LaunchAgents/$PLIST_NAME"

if [[ -f "$PLIST_DEST" ]]; then
    echo "==> Stopping daemon"
    launchctl unload "$PLIST_DEST" 2>/dev/null || true
    echo "==> Removing plist"
    rm "$PLIST_DEST"
    echo "==> Daemon uninstalled"
else
    echo "Daemon not installed"
fi
