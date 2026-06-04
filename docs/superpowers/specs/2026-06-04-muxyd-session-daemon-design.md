# Muxyd: PTY Session Daemon Design

Date: 2026-06-04
Branch: feat/muxyd-session-daemon
Status: Draft

## Problem

Mobile connects to Mac via TCP request/response protocol (`MuxyRemoteServer`). Mobile receives ANSI snapshots from tmux capture, sends keystrokes as API calls. Not native — snapshot-based rendering, proxy model, latency.

Goal: Muxy behaves like tmux internally. Both Mac and iOS apps attach to shared PTY sessions and render natively.

## Decision Record

| Decision | Choice | Reason |
|----------|--------|--------|
| Session server | Dedicated daemon (`muxyd`) via launchd | Sessions survive Mac app quit |
| Render engine | Ghostty on both Mac and iOS | Consistent rendering, leverages existing integration |
| Wire protocol | Custom binary over TCP | Full control, optimized for terminal streaming |
| First scope | Mac + iOS together | Validate cross-platform from day one |
| Existing tmux | Replace completely | Remove TmuxCaptureService, muxyd replaces tmux |
| Network scope | Local network only | Bonjour discovery, no cloud infra needed |
| Architecture | Thin daemon, smart clients | Simplest daemon, clients handle rendering via Ghostty |

## 1. Process Architecture

```
┌─────────────┐     TCP/custom      ┌─────────────┐     TCP/custom     ┌──────────┐
│  Muxy Mac   │◄──────────────────►│   muxyd     │◄──────────────────►│ Muxy iOS │
│  (client)   │                     │  (daemon)   │                    │ (client) │
│             │                     │             │                    │          │
│ Ghostty     │                     │ PTY master  │                    │ Ghostty  │
│ renderer    │                     │ FD table    │                    │ renderer │
│             │                     │ Session mgr │                    │          │
└─────────────┘                     └─────────────┘                    └──────────┘
```

**`muxyd` (daemon)**
- Launched by `launchd` on user login
- Manages PTY sessions: fork, hold master FD, track window size
- Multiplexes raw PTY output to all attached clients
- Routes client input to correct PTY
- Authenticates clients via existing pairing mechanism
- Single binary, no UI, no SwiftUI dependency
- State stored in `~/.muxy/daemon/` (session registry, auth tokens)

**Mac client (existing Muxy app)**
- No longer forks PTY directly
- Connects to `muxyd` on launch
- Receives raw PTY bytes, feeds to Ghostty renderer
- Sends user input to daemon
- Retains all current UI: tabs, splits, sidebar, editor, VCS

**iOS client**
- Connects to `muxyd` via Bonjour-discovered endpoint
- Same protocol as Mac client
- Ghostty (compiled for iOS) renders terminal output
- Native feel: renders live PTY stream, not snapshots

**Lifecycle:**
- `muxyd` auto-starts at login (launchd `KeepAlive`)
- Sessions persist across Mac app quit/restart
- Mac app quit = detach (like `tmux detach`), not session kill
- iOS backgrounded = detach, re-open = re-attach
- Daemon idle with no sessions = stays alive, low memory

## 2. Daemon — PTY Session Manager

**Session model:**

```
Session
├── id: UUID
├── masterFD: FileHandle
├── childPID: pid_t
├── shell: String (e.g. /bin/zsh)
├── cwd: String
├── env: [String: String]
├── windowSize: (cols: UInt16, rows: UInt16)
├── attachedClients: Set<ClientID>
└── createdAt: Date
```

**PTY lifecycle:**

1. **Create** — `forkpty()` → child execs shell, parent holds master FD
2. **Attach** — client registers interest in session, starts receiving PTY output
3. **Input** — client sends bytes → daemon writes to master FD
4. **Resize** — client reports terminal size → daemon picks min across clients, sends `TIOCSWINSZ`
5. **Detach** — client disconnects from session, session keeps running
6. **Kill** — explicit kill request or child process exits → close master FD, notify remaining clients

**Window size strategy:**
- Each attached client reports its (cols, rows)
- Daemon tracks minimum cols × minimum rows across all clients
- Sets PTY size to minimum — ensures no client gets garbled output
- Larger clients see blank padding (handled by their Ghostty renderer)
- When client detaches, recalculate and resize PTY

**I/O multiplexing:**
- `kqueue` / `dispatch_source` on master FDs
- PTY output → broadcast to all attached client connections
- Client input → write to session's master FD
- Backpressure: if client TCP buffer full, drop that client (can't block PTY)

**Session persistence:**
- Daemon writes session registry to `~/.muxy/daemon/sessions.json` on state change
- On daemon restart: re-read registry, attempt to re-open master FDs (best-effort — child processes may have exited)

**Authentication:**
- Reuse existing `ApprovedDevicesStore` + pairing flow from `MobilePairingService`
- Mac app auto-authenticates via Unix socket (same user, same machine)
- iOS authenticates via existing device pairing mechanism

## 3. Wire Protocol

Binary protocol over TCP. Low-latency terminal streaming.

**Frame format:**

```
┌──────────┬──────────┬──────────┬───────────────┐
│ Version  │   Type   │  Length  │    Payload     │
│ 1 byte   │  1 byte  │ 4 bytes  │  N bytes      │
└──────────┴──────────┴──────────┴───────────────┘
```

- **Version**: protocol version (currently `1`)
- **Type**: message type
- **Length**: payload length (UInt32 big-endian)
- **Payload**: type-specific, flat binary

**Connection lifecycle:**

```
Client                          Daemon
  │                               │
  │──── Connect (TCP) ───────────►│
  │──── AuthRequest ─────────────►│
  │◄─── AuthResponse ────────────│
  │──── ListSessions ────────────►│
  │◄─── SessionList ─────────────│
  │──── AttachSession ───────────►│
  │◄─── AttachAck ───────────────│
  │◄─── PTYOutput (stream) ──────│  ← continuous
  │──── PTYInput ────────────────►│  ← on keystroke
  │──── Resize ─────────────────►│
  │──── Detach ──────────────────►│
  │◄─── DetachAck ───────────────│
```

**Client → daemon messages:**

| Type | Name | Payload | Description |
|------|------|---------|-------------|
| 0x01 | AuthRequest | deviceID + token | Authenticate client |
| 0x02 | ListSessions | empty | Get active sessions |
| 0x03 | CreateSession | shell, cwd, env | Create new PTY session |
| 0x04 | AttachSession | sessionID | Attach to session |
| 0x05 | Detach | sessionID | Detach from session |
| 0x06 | PTYInput | raw bytes | Send to PTY |
| 0x07 | Resize | cols, rows | Report terminal size |
| 0x08 | KillSession | sessionID | Kill session |
| 0x09 | Ping | empty | Keepalive |

**Daemon → client messages:**

| Type | Name | Payload | Description |
|------|------|---------|-------------|
| 0x81 | AuthResponse | success/failure | Auth result |
| 0x82 | SessionList | session array | Active sessions |
| 0x83 | SessionCreated | sessionID | New session confirmed |
| 0x84 | AttachAck | sessionID + initial size | Attach confirmed |
| 0x85 | DetachAck | sessionID | Detach confirmed |
| 0x86 | PTYOutput | raw bytes | PTY output stream |
| 0x87 | SessionExited | sessionID + exit code | Session terminated |
| 0x88 | ClientConnected | sessionID + clientID | Another client attached |
| 0x89 | ClientDisconnected | sessionID + clientID | Another client detached |
| 0x8A | Pong | empty | Keepalive response |
| 0x8B | ResizeRequired | cols, rows | Daemon requests client resize |

**PTYOutput optimization:**
- Raw PTY output bytes sent as-is (ANSI escape sequences)
- Optional zlib compression per-frame (negotiated during auth)
- No delta encoding — each frame is complete bytes since last frame

**Unix socket fast path (Mac → daemon):**
- Mac client connects via Unix domain socket at `~/.muxy/daemon.sock`
- Same protocol, zero network overhead
- Auto-authenticated by UID — no device pairing needed
- Fallback to TCP if Unix socket unavailable

## 4. Mac Client Integration

**Ghostty remote mode:**
- Mac app connects to `muxyd` → receives `PTYOutput` frames → feeds bytes into Ghostty surface
- User keystrokes captured by Ghostty surface → sent as `PTYInput` to daemon
- **Open question**: Need to verify Ghostty's API for "remote PTY" mode (external byte stream input). If Ghostty doesn't support this natively, we may need a thin shim that creates a pseudo-PTY pair: daemon bytes → slave PTY → Ghostty reads from master PTY as usual.

**Session lifecycle from Mac client:**

1. **App launch** → connect to `muxyd` via Unix socket
2. **Create tab** → send `CreateSession` to daemon → receive `SessionCreated` → `AttachSession`
3. **Tab renders** → `PTYOutput` bytes fed to Ghostty surface
4. **User types** → captured by Ghostty surface → sent as `PTYInput` to daemon
5. **Close tab** → send `Detach` + `KillSession` to daemon
6. **App quit** → send `Detach` for all sessions (sessions survive)

**Removed components:**

| Component | Why removed |
|-----------|-------------|
| `TmuxCaptureService` | tmux replaced by muxyd |
| `TmuxConfiguration` | same |
| `TmuxControlModeProcess` | same |
| `RemoteTerminalSnapshotBuilder` | no more snapshot-based streaming |
| `RemoteTerminalStreamer` | replaced by direct PTY stream |
| `PaneOwnershipStore` | daemon manages attachments, no "takeover" concept |
| `takeOverPane` / `releasePane` in `RemoteServerDelegate` | both clients attach natively |
| `MuxyRemoteServer` (TCP server) | daemon handles connections now |
| `MobileServerService` | daemon handles connections now |

**Modified components:**

| Component | Change |
|-----------|--------|
| `GhosttyTerminalNSView` | Accept external byte stream instead of forking PTY |
| `TerminalPane` | Create/attach/detach via daemon instead of direct PTY |
| `AppState` | Session management via daemon client, not in-process |
| `TerminalSessionStore` | Persist session IDs (daemon-managed), not PTY state |
| `MobilePairingService` | Becomes daemon pairing (same flow, different endpoint) |
| `GhosttyService` | Initialize for remote rendering mode |

**New components:**

| Component | Purpose |
|-----------|---------|
| `DaemonClient` | Connects to muxyd, sends/receives protocol messages |
| `PTYOutputStream` | Async stream of raw bytes from daemon |
| `DaemonDiscovery` | Finds daemon via Unix socket / Bonjour |

**Startup flow:**

```
App launches
  → DaemonClient.connect(unixSocket)
  → Auth (auto via UID)
  → ListSessions → restore previous tabs
  → For each restored session: Attach
  → Ghostty surfaces start rendering
```

## 5. iOS Client

**Architecture:**

```
┌────────────────────────────┐
│         Muxy iOS           │
│                            │
│  ┌──────────────────────┐  │
│  │   DaemonClient       │  │
│  │  (TCP + Bonjour)     │  │
│  └──────────┬───────────┘  │
│             │              │
│  ┌──────────▼───────────┐  │
│  │   Ghostty (iOS)      │  │
│  │   Terminal renderer  │  │
│  └──────────────────────┘  │
│                            │
│  SwiftUI views:            │
│  - Session list            │
│  - Terminal view           │
│  - Keyboard accessories    │
│  - Split panes             │
└────────────────────────────┘
```

**iOS app responsibilities:**
- Discover daemon via Bonjour on local network
- Authenticate via existing device pairing flow
- List + attach to daemon sessions
- Render PTY output via Ghostty (iOS build)
- Send input (keyboard, special keys, paste)
- Report terminal size changes (rotation, split keyboard)

**Key screens:**

1. **Discovery/pairing** — scan Bonjour, show available daemons, pair device
2. **Session list** — show active sessions on selected daemon, create new, attach
3. **Terminal** — full-screen Ghostty renderer, connected to attached session
4. **Keyboard accessory** — special keys (Ctrl, Alt, Tab, Esc, arrows, Fn) as touch bar

**iOS-specific concerns:**

- **Backgrounding** — iOS suspends TCP connections. On background: send `Detach`. On foreground: re-`Attach`.
- **Reconnection** — network drops → exponential backoff reconnect → re-attach last session
- **Rotation** — send `Resize` on orientation change
- **Scrollback** — daemon sends current screen + scrollback on attach
- **Input** — software keyboard + hardware keyboard support

**Ghostty on iOS:**
- Compile `libghostty` for iOS (arm64)
- Wrap in SwiftUI via `UIViewRepresentable`
- Feed PTY output bytes into Ghostty's input API (same remote mode as Mac)
- Capture key events from iOS responder chain → forward to daemon

**Daemon → iOS on attach:**
1. Client sends `AttachSession(sessionID)`
2. Daemon responds with `AttachAck` containing current window size
3. Daemon sends current screen content as first `PTYOutput` frame. **Open question**: PTY doesn't store its own screen buffer — options: (a) daemon maintains a minimal scrollback buffer since last output, (b) client requests `tput reset` equivalent on attach, (c) accept that re-attach starts from current cursor position only. Recommended: option (a) with configurable buffer size (default 10KB).
4. Subsequent `PTYOutput` frames are incremental
5. iOS Ghostty renders from byte 1 — no loading state

## 6. Error Handling & Edge Cases

**Daemon crash:**
- `launchd` auto-restarts `muxyd` (`KeepAlive = true`)
- Child processes may survive briefly — daemon attempts to reattach or reaps
- Sessions lost on crash — clients get `SessionExited`, show "session lost" UI
- Client apps stay running — show session list (now empty)

**Client crash/disconnect:**
- Daemon detects TCP disconnect / Unix socket close
- Detaches client from all sessions automatically
- Recalculates window sizes for remaining clients
- Other clients get `ClientDisconnected` event

**Network failure (iOS):**
- TCP connection drops → iOS enters reconnect loop (1s, 2s, 4s, 8s, max 30s backoff)
- Reconnect → re-auth → re-attach last session
- During disconnect: terminal frozen, "reconnecting" indicator
- Session killed while disconnected: show "session ended" on reconnect

**Window size contention:**
- Two clients: Mac at 120×40, iOS at 80×25 → PTY sized to 80×25 (minimum)
- Daemon sends `ResizeRequired(80, 25)` to Mac
- iOS detaches → daemon resizes PTY to 120×40

**Backpressure:**
- Per-client write buffer in daemon
- Buffer exceeds 1MB → drop client, send `SessionExited(reason: bufferOverflow)`
- Client must reconnect + re-attach

**Authentication failure:**
- Unauthenticated client → connection closed after 5s timeout
- 3 failed auth attempts from same IP → 30s ban

**Shell exit:**
- Child process exits → daemon detects via `kqueue`
- Send `SessionExited(exitCode)` to all attached clients
- Clean up master FD, remove session

**Multiple daemons:**
- Each daemon advertises via Bonjour with hostname: `muxy-macbook._tcp`
- iOS shows list of available daemons
- Mac app connects to local daemon (Unix socket)

**Orphan sessions:**
- Session with no attached clients persists
- Configurable idle timeout (default: never)
- Optional: `maxIdleTime` setting to auto-kill idle sessions

## 7. Testing Strategy

**Daemon tests (unit):**
- PTY session create/destroy lifecycle
- Multiple clients attach to same session — output fanned out correctly
- Client disconnect — other clients unaffected, PTY keeps running
- Window size calculation: min across clients, resize on detach
- Protocol parsing: frame encode/decode round-trip for all message types
- Auth: valid token accepted, invalid rejected, ban after 3 failures
- Backpressure: slow client dropped, fast client unaffected
- Shell exit: `SessionExited` sent to all clients, session removed

**Daemon tests (integration):**
- Full lifecycle: create → attach → input → output → detach → reattach → kill
- Two clients attached simultaneously — both receive same output
- Client A detaches, client B keeps receiving output
- Daemon restart — sessions list empty (crash = sessions lost)

**Mac client tests (unit):**
- `DaemonClient` — mock daemon connection, verify protocol message encoding
- Session restore on app launch — mock `ListSessions` response, verify tabs recreated
- App quit sends `Detach` for all sessions, no `KillSession`

**Mac client tests (integration):**
- Launch daemon, create session, verify Ghostty surface receives bytes
- Close tab → verify session still exists on daemon
- Reopen tab → re-attach, verify content restored

**iOS client tests (unit):**
- `DaemonClient` — protocol handling
- Bonjour discovery — mock `NetServiceBrowser` results
- Background/foreground lifecycle — verify `Detach` on background, `Attach` on foreground
- Reconnect logic — mock connection failures, verify backoff

**iOS client tests (UI):**
- Terminal rendering — feed known ANSI sequences, verify correct display
- Keyboard input — verify keystrokes encoded correctly to PTY input bytes
- Rotation — verify `Resize` sent, terminal reflows

**Shared test infrastructure:**
- Protocol types in `MuxyShared` — both platforms test encode/decode
- Mock daemon server for client tests
- Reuse existing test patterns from `MuxyTests/`

**Coverage gates:**
- Daemon: PTY lifecycle, protocol, auth, window sizing
- Client: daemon client, session management
- Integration: full round-trip Mac → daemon → Mac
- Ghostty remote mode: manual test
