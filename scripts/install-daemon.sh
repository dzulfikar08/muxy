#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PLIST_NAME="app.muxy.daemon.plist"
LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
PLIST_SOURCE="$PROJECT_ROOT/resources/$PLIST_NAME"
PLIST_DEST="$LAUNCH_AGENTS_DIR/$PLIST_NAME"

DAEMON_PATH="${1:-}"

if [[ -z "$DAEMON_PATH" ]]; then
    DAEMON_PATH="$PROJECT_ROOT/.build/release/muxyd"
    if [[ ! -f "$DAEMON_PATH" ]]; then
        echo "Error: muxyd not found at $DAEMON_PATH"
        echo "Usage: $0 [path-to-muxyd]"
        exit 1
    fi
fi

DAEMON_PATH="$(cd "$(dirname "$DAEMON_PATH")" && pwd)/$(basename "$DAEMON_PATH")"

echo "==> Installing muxyd daemon"
echo "    Daemon: $DAEMON_PATH"

if [[ -f "$PLIST_DEST" ]]; then
    echo "==> Unloading existing daemon"
    launchctl unload "$PLIST_DEST" 2>/dev/null || true
fi

echo "==> Generating plist"
sed -e "s|__DAEMON_PATH__|$DAEMON_PATH|g" \
    -e "s|__HOME__|$HOME|g" \
    "$PLIST_SOURCE" > "$PLIST_DEST"

echo "==> Loading daemon"
launchctl load "$PLIST_DEST"

echo "==> Done. muxyd is running."
echo "    Logs: /tmp/muxyd.log"
echo "    Socket: $HOME/.muxy/daemon.sock"
echo ""
echo "To stop: launchctl unload $PLIST_DEST"
echo "To uninstall: rm $PLIST_DEST"
