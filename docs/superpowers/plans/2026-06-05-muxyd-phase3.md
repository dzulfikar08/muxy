# Muxyd Phase 3: Polish + Packaging

## Tasks

### Task 1: Session persistence in daemon
- Daemon writes session registry to `~/.muxy/daemon/sessions.json` on state change
- On startup: read registry, attempt to verify sessions (check if child PID alive)
- Dead sessions pruned on startup

### Task 2: launchd plist
- Create `resources/app.muxy.daemon.plist` template
- Install script: `scripts/install-daemon.sh` to copy plist to `~/Library/LaunchAgents/`
- load/unload via launchctl

### Task 3: Bundle muxy-relay + muxyd into Mac app
- Update `scripts/build-release.sh` to also build MuxyRelay + MuxyDaemonExec
- Copy muxy-relay to `Muxy.app/Contents/MacOS/muxy-relay`
- Copy muxyd to `Muxy.app/Contents/MacOS/muxyd`
- Update GhosttyTerminalNSView.findRelayBinary to find muxy-relay in app bundle

### Task 4: Daemon auto-launch from Mac app
- On app launch, check if daemon is running (Unix socket exists and responsive)
- If not, launch muxyd from app bundle
- On app quit, don't kill daemon (sessions persist)

### Task 5: Final checks + push
