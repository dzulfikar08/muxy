# Muxyd Phase 2: Mac Client Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task.

**Goal:** Replace tmux with muxy-relay as Ghostty's command, remove old remote server code, wire session management through the daemon.

**Architecture:** muxy-relay is a small CLI that Ghostty runs as its "shell command." The relay connects to muxyd daemon via Unix socket, creates/attaches a PTY session, and bidirectionally relays bytes. Ghostty is unaware of the daemon — it just sees a normal PTY with stdin/stdout.

**Tech Stack:** Swift 6.0+, SPM, Foundation, Network framework, MuxyShared protocol types.

---

## File Structure

### New files

| File | Responsibility |
|------|---------------|
| `MuxyRelay/main.swift` | Entry point. Parse args, run relay. |
| `MuxyRelay/RelayConnection.swift` | Connects to daemon, sends/receives frames, bidirectional relay. |
| `MuxyRelay/FrameReader.swift` | Reads frames from NWConnection into buffer, decodes streaming. |
| `MuxyRelay/FrameWriter.swift` | Encodes and sends frames to NWConnection. |
| `MuxyShared/RelayArgs.swift` | Shared argument parsing types for relay CLI args. |

### Modified files

| File | Change |
|------|--------|
| `Package.swift` | Add MuxyRelay executable target. |
| `Muxy/Views/Terminal/GhosttyTerminalNSView.swift` | Replace tmux command with muxy-relay. Remove all tmux methods. |
| `Muxy/Views/Terminal/TerminalPane.swift` | Remove PaneOwnershipStore references. Remove RemoteControlledPlaceholder. |
| `Muxy/Views/Terminal/TerminalViewRegistry.swift` | Remove tmux surface eviction code. |

### Deleted files

| File | Why |
|------|-----|
| `Muxy/Services/PaneOwnershipStore.swift` | Daemon manages attachments. |
| `Muxy/Services/RemoteTerminalStreamer.swift` | Replaced by direct daemon streaming. |
| `Muxy/Services/RemoteTerminalSnapshotBuilder.swift` | No more snapshot-based streaming. |
| `Muxy/Services/MobileServerService.swift` | Daemon handles connections. |
| `Muxy/Services/RemoteServerDelegate.swift` | Daemon handles connections. |
| `MuxyServer/ClientConnection.swift` | Daemon handles connections. |
| `MuxyServer/MuxyRemoteServer.swift` | Daemon handles connections. |

---

## Tasks

### Task 1: Create muxy-relay executable target

**Files:**
- Create: `MuxyRelay/main.swift`
- Modify: `Package.swift`

- [ ] Create `MuxyRelay/` directory and `main.swift` with placeholder
- [ ] Add `.executableTarget(name: "MuxyRelay", dependencies: ["MuxyShared"], path: "MuxyRelay")` to Package.swift
- [ ] Verify `swift build --target MuxyRelay` compiles
- [ ] Commit

### Task 2: Implement FrameReader + FrameWriter

**Files:**
- Create: `MuxyRelay/FrameReader.swift`
- Create: `MuxyRelay/FrameWriter.swift`

FrameReader: wraps NWConnection receive loop into an AsyncSequence of DaemonFrame.
FrameWriter: wraps NWConnection send for DaemonFrame.

- [ ] Implement FrameReader with AsyncStream<DaemonFrame>
- [ ] Implement FrameWriter with simple send(DaemonFrame) 
- [ ] Verify compiles
- [ ] Commit

### Task 3: Implement RelayConnection

**Files:**
- Create: `MuxyRelay/RelayConnection.swift`

Connects to daemon, handles auth, creates/attaches session, runs bidirectional relay:
- stdin (from Ghostty) → PTYInput messages to daemon
- PTYOutput messages from daemon → stdout (to Ghostty)
- SIGWINCH → Resize messages to daemon

- [ ] Implement RelayConnection with NWConnection
- [ ] Handle auth (auto for Unix socket)
- [ ] Handle create/attach session
- [ ] Wire stdin→daemon and daemon→stdout relay
- [ ] Handle SIGWINCH for resize
- [ ] Verify compiles
- [ ] Commit

### Task 4: Complete main.swift relay logic

**Files:**
- Modify: `MuxyRelay/main.swift`

CLI entry point:
- Parse args: `muxy-relay new [--shell /bin/zsh] [--cwd /path] [--env KEY=VAL]` or `muxy-relay attach <session-id>`
- For `new`: connect to daemon, create session, attach, relay
- For `attach`: connect to daemon, attach to existing session, relay
- On exit: detach from session

- [ ] Implement arg parsing
- [ ] Wire RelayConnection
- [ ] Test: run `muxy-relay new --shell /bin/cat`, type input, see echo
- [ ] Commit

### Task 5: Modify GhosttyTerminalNSView — replace tmux with relay

**Files:**
- Modify: `Muxy/Views/Terminal/GhosttyTerminalNSView.swift`

Remove all tmux-related code:
- Remove `findTmuxBinary()`, `ensureTmuxConfig()`, `tmuxSessionName()`, `tmuxSocketName`, `tmuxSessionPrefix`, `tmuxAvailable()`
- Remove `surfaceEvictionEnabled()` — replaced by relay
- Remove `cachedTmuxSessionName`
- Remove `sendTmuxSnapshot()`, `sendAsyncTmuxSnapshot()` if present
- In `initializeSurface()`, replace tmux command path with relay command:
  ```swift
  let relayBinary = Bundle.main.path(forAuxiliaryExecutable: "muxy-relay") ?? "muxy-relay"
  let relayCommand: String
  if let command { ... }
  // Build: muxy-relay new --shell /bin/zsh --cwd /path --env KEY=VAL
  ```
- For restored sessions: `muxy-relay attach <session-id>`

- [ ] Remove tmux code
- [ ] Add relay command construction
- [ ] Verify builds
- [ ] Commit

### Task 6: Simplify TerminalPane — remove PaneOwnershipStore

**Files:**
- Modify: `Muxy/Views/Terminal/TerminalPane.swift`

- Remove `@Bindable private var ownership = PaneOwnershipStore.shared`
- Remove `remoteOwnerName` computed property
- Remove `RemoteControlledPlaceholder` struct
- Remove opacity/hitTesting based on remote ownership
- Terminal always visible — no more "takeover" concept

- [ ] Remove ownership-related code
- [ ] Verify builds
- [ ] Commit

### Task 7: Simplify TerminalViewRegistry — remove surface eviction

**Files:**
- Modify: `Muxy/Views/Terminal/TerminalViewRegistry.swift`

- Remove `evictAllExceptWorkspace` method (was tmux-specific)
- Remove eviction work items
- Simplify to just view creation/removal

- [ ] Remove eviction code
- [ ] Verify builds
- [ ] Commit

### Task 8: Delete old remote server files

**Files:**
- Delete: `Muxy/Services/PaneOwnershipStore.swift`
- Delete: `Muxy/Services/RemoteTerminalStreamer.swift`
- Delete: `Muxy/Services/RemoteTerminalSnapshotBuilder.swift`
- Delete: `Muxy/Services/MobileServerService.swift`
- Delete: `Muxy/Services/RemoteServerDelegate.swift`
- Delete: `MuxyServer/ClientConnection.swift`
- Delete: `MuxyServer/MuxyRemoteServer.swift`

Also remove from Package.swift:
- `MuxyServer` target (or keep as stub if other code depends on MuxyShared re-exports)
- Remove `MuxyServer` dependency from `Muxy` target

Check for any other references to deleted types and fix compilation errors.

- [ ] Delete files
- [ ] Update Package.swift
- [ ] Fix compilation errors from removed types
- [ ] Verify builds
- [ ] Commit

### Task 9: Update tests and settings

**Files:**
- Modify: `Muxy/Views/Settings/TerminalSettingsView.swift` — remove tmux-related settings UI
- Modify: `Muxy/Services/TerminalCommandTrackingInputGate.swift` — remove tmux from process name check
- Delete/Update: Any tests referencing deleted types (TmuxCaptureServiceTests, MuxyRemoteServerRoutingTests, etc.)
- Run `scripts/checks.sh --fix`

- [ ] Fix settings UI
- [ ] Fix test files
- [ ] Run checks
- [ ] Commit

### Task 10: Final build + test + push

- [ ] `swift build` passes
- [ ] `swift test --filter MuxyDaemonTests` passes
- [ ] `swiftlint lint --strict` clean
- [ ] `swiftformat --lint .` clean
- [ ] Push to `feat/muxyd-session-daemon`
