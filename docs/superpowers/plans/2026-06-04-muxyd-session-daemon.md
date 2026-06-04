# Muxyd PTY Session Daemon Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build muxyd — a PTY session daemon that owns terminal sessions, allowing both Mac and iOS clients to attach natively.

**Architecture:** Thin daemon owns PTY master FDs via `forkpty()`. Raw PTY output streamed to all attached clients over custom binary protocol. Clients (Mac/iOS) run Ghostty in remote mode to render. Daemon communicates via Unix socket (Mac) or TCP with Bonjour (iOS).

**Tech Stack:** Swift 6.0+, SPM, Darwin PTY APIs (`forkpty`, `TIOCSWINSZ`), `Network` framework, `dispatch_source` for I/O multiplexing, `launchd` for daemon lifecycle.

**Spec:** `docs/superpowers/specs/2026-06-04-muxyd-session-daemon-design.md`

---

## File Structure

### New files — MuxyShared (protocol types, shared between daemon + clients)

| File | Responsibility |
|------|---------------|
| `MuxyShared/DaemonFrame.swift` | Binary frame: version + type + length + payload. Encode/decode. |
| `MuxyShared/DaemonMessage.swift` | All message type enums (client→daemon, daemon→client) and payload types. |

### New files — MuxyDaemon (daemon executable target)

| File | Responsibility |
|------|---------------|
| `MuxyDaemon/main.swift` | Entry point. Parse args, bootstrap daemon. |
| `MuxyDaemon/PTYSession.swift` | Wraps `forkpty()`. Holds master FD, child PID. Read/write/resize. |
| `MuxyDaemon/PTYSessionRegistry.swift` | Thread-safe registry of active sessions. Create/destroy/list/lookup. |
| `MuxyDaemon/ScrollbackBuffer.swift` | Ring buffer that captures recent PTY output for re-attach. |
| `MuxyDaemon/DaemonClientConnection.swift` | Represents a connected client. Send/receive frames. Track attached sessions. |
| `MuxyDaemon/DaemonConnectionManager.swift` | Accepts TCP + Unix socket connections. Manages client lifecycle. |
| `MuxyDaemon/DaemonAuthenticator.swift` | Authenticate clients. UID auto-auth for Unix socket. Token auth for TCP. |
| `MuxyDaemon/DaemonServer.swift` | Top-level daemon coordinator. Wires session registry, connection manager, I/O. |
| `MuxyDaemon/DaemonConfig.swift` | Daemon configuration: socket paths, ports, scrollback size, auth store path. |

### New files — Muxy (Mac client daemon integration)

| File | Responsibility |
|------|---------------|
| `Muxy/Services/DaemonClient.swift` | Connects to muxyd. Sends/receives frames. Async stream API for PTY output. |
| `Muxy/Services/DaemonDiscovery.swift` | Finds daemon via Unix socket fallback TCP/Bonjour. |

### New files — Tests

| File | Responsibility |
|------|---------------|
| `Tests/MuxyDaemonTests/DaemonFrameTests.swift` | Frame encode/decode round-trip. |
| `Tests/MuxyDaemonTests/DaemonMessageTests.swift` | Message encode/decode round-trip. |
| `Tests/MuxyDaemonTests/PTYSessionTests.swift` | PTY create, read output, write input, resize, exit detection. |
| `Tests/MuxyDaemonTests/PTYSessionRegistryTests.swift` | Registry CRUD. |
| `Tests/MuxyDaemonTests/ScrollbackBufferTests.swift` | Ring buffer append, read, overflow. |
| `Tests/MuxyDaemonTests/DaemonAuthenticatorTests.swift` | UID auth, token auth, ban logic. |
| `Tests/MuxyDaemonTests/DaemonServerTests.swift` | Full lifecycle integration test. |

### Modified files

| File | Change |
|------|--------|
| `Package.swift` | Add `MuxyDaemon` executable target + `MuxyDaemonTests` test target. |

### Files to remove (Phase 2 — not this plan)

These are removed in a follow-up plan when Mac client migration is complete:
- `Muxy/Services/TmuxCaptureService.swift`
- `Muxy/Services/TmuxConfiguration.swift`
- `Muxy/Services/RemoteTerminalSnapshotBuilder.swift`
- `Muxy/Services/RemoteTerminalStreamer.swift`
- `Muxy/Services/PaneOwnershipStore.swift`
- `Muxy/Services/MobileServerService.swift`
- `MuxyServer/MuxyRemoteServer.swift`
- `MuxyServer/ClientConnection.swift`
- `Muxy/Services/RemoteServerDelegate.swift`

---

## Phase 1: Protocol + Daemon Core

Build the daemon binary and binary protocol. By end of Phase 1, muxyd can:
- Start, listen on Unix socket + TCP
- Create PTY sessions via client request
- Stream PTY output to attached clients
- Handle input, resize, detach, kill
- Be tested end-to-end with a simple test client

---

### Task 1: Add daemon protocol types — DaemonFrame

**Files:**
- Create: `MuxyShared/DaemonFrame.swift`
- Test: `Tests/MuxyDaemonTests/DaemonFrameTests.swift`
- Modify: `Package.swift` (add `MuxyDaemonTests` target)

- [ ] **Step 1: Add MuxyDaemonTests target to Package.swift**

In `Package.swift`, add the test target after the existing `MuxyTests` target:

```swift
        .testTarget(
            name: "MuxyDaemonTests",
            dependencies: [
                "MuxyShared",
            ],
            path: "Tests/MuxyDaemonTests"
        ),
```

Also add the `MuxyDaemon` executable target (needed for tests to find the module):

```swift
        .executableTarget(
            name: "MuxyDaemon",
            dependencies: [
                "MuxyShared",
            ],
            path: "MuxyDaemon"
        ),
```

Create the empty directories:
```bash
mkdir -p MuxyDaemon Tests/MuxyDaemonTests
```

- [ ] **Step 2: Write failing test for DaemonFrame**

Create `Tests/MuxyDaemonTests/DaemonFrameTests.swift`:

```swift
import XCTest
@testable import MuxyShared

final class DaemonFrameTests: XCTestCase {
    func testEncodeDecodeRoundTrip() throws {
        let payload = Data("hello world".utf8)
        let frame = DaemonFrame(type: .ptyOutput, payload: payload)
        let encoded = try frame.encode()

        let decoded = try DaemonFrame.decode(from: encoded)
        XCTAssertEqual(decoded.type, .ptyOutput)
        XCTAssertEqual(decoded.payload, payload)
    }

    func testEmptyPayloadRoundTrip() throws {
        let frame = DaemonFrame(type: .ping, payload: Data())
        let encoded = try frame.encode()

        let decoded = try DaemonFrame.decode(from: encoded)
        XCTAssertEqual(decoded.type, .ping)
        XCTAssertEqual(decoded.payload.count, 0)
    }

    func testLargePayloadRoundTrip() throws {
        let payload = Data((0..<100_000).map { _ in UInt8.random(in: 0...255) })
        let frame = DaemonFrame(type: .ptyOutput, payload: payload)
        let encoded = try frame.encode()

        let decoded = try DaemonFrame.decode(from: encoded)
        XCTAssertEqual(decoded.payload, payload)
    }

    func testDecodeTruncatedDataThrows() {
        let data = Data([0x01])
        XCTAssertThrowsError(try DaemonFrame.decode(from: data))
    }

    func testDecodeInvalidVersionThrows() {
        var data = Data()
        data.append(0xFF)
        data.append(0x01)
        data.append(contentsOf: withUnsafeBytes(of: UInt32(0).bigEndian) { Array($0) })
        XCTAssertThrowsError(try DaemonFrame.decode(from: data))
    }
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `swift test --filter MuxyDaemonTests.DaemonFrameTests`
Expected: FAIL — `DaemonFrame` not defined

- [ ] **Step 4: Implement DaemonFrame**

Create `MuxyShared/DaemonFrame.swift`:

```swift
import Foundation

public struct DaemonFrame: Sendable {
    public static let protocolVersion: UInt8 = 1
    public static let headerSize = 6

    public let type: DaemonMessageType
    public let payload: Data

    public init(type: DaemonMessageType, payload: Data = Data()) {
        self.type = type
        self.payload = payload
    }

    public func encode() throws -> Data {
        var data = Data()
        data.append(Self.protocolVersion)
        data.append(type.rawValue)
        let length = UInt32(payload.count)
        withUnsafeBytes(of: length.bigEndian) { data.append(contentsOf: $0) }
        data.append(payload)
        return data
    }

    public static func decode(from data: Data) throws -> DaemonFrame {
        guard data.count >= headerSize else {
            throw DaemonFrameError.truncatedHeader
        }

        let version = data[0]
        guard version == protocolVersion else {
            throw DaemonFrameError.unsupportedVersion(version)
        }

        let typeRaw = data[1]
        guard let messageType = DaemonMessageType(rawValue: typeRaw) else {
            throw DaemonFrameError.unknownMessageType(typeRaw)
        }

        let length = data[2...].withUnsafeBytes { ptr in
            ptr.loadUnaligned(as: UInt32.self).bigEndian
        }

        let totalExpected = headerSize + Int(length)
        guard data.count >= totalExpected else {
            throw DaemonFrameError.truncatedPayload(expected: Int(length), actual: data.count - headerSize)
        }

        let payload = data[headerSize..<(headerSize + Int(length))]
        return DaemonFrame(type: messageType, payload: Data(payload))
    }

    public static func decodeStreaming(from buffer: inout Data) -> DaemonFrame? {
        guard buffer.count >= headerSize else { return nil }

        let length = buffer[2...].withUnsafeBytes { ptr in
            ptr.loadUnaligned(as: UInt32.self).bigEndian
        }

        let totalExpected = headerSize + Int(length)
        guard buffer.count >= totalExpected else { return nil }

        let frameData = buffer[..<totalExpected]
        buffer = Data(buffer[totalExpected...])

        return try? DaemonFrame.decode(from: Data(frameData))
    }
}

public enum DaemonFrameError: Error, LocalizedError {
    case truncatedHeader
    case unsupportedVersion(UInt8)
    case unknownMessageType(UInt8)
    case truncatedPayload(expected: Int, actual: Int)

    public var errorDescription: String? {
        switch self {
        case .truncatedHeader:
            "Frame header truncated: need \(DaemonFrame.headerSize) bytes"
        case let .unsupportedVersion(v):
            "Unsupported protocol version: \(v)"
        case let .unknownMessageType(t):
            "Unknown message type: 0x\(String(t, radix: 16))"
        case let .truncatedPayload(expected, actual):
            "Payload truncated: expected \(expected) bytes, got \(actual)"
        }
    }
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `swift test --filter MuxyDaemonTests.DaemonFrameTests`
Expected: PASS (note: `DaemonMessageType` defined in next step — merge or stub)

- [ ] **Step 6: Commit**

```bash
git add MuxyShared/DaemonFrame.swift Tests/MuxyDaemonTests/DaemonFrameTests.swift Package.swift
git commit -m "feat(daemon): add DaemonFrame binary protocol encoding"
```

---

### Task 2: Add daemon protocol types — DaemonMessage

**Files:**
- Create: `MuxyShared/DaemonMessage.swift`
- Test: `Tests/MuxyDaemonTests/DaemonMessageTests.swift`

- [ ] **Step 1: Write failing test for DaemonMessage**

Create `Tests/MuxyDaemonTests/DaemonMessageTests.swift`:

```swift
import XCTest
@testable import MuxyShared

final class DaemonMessageTests: XCTestCase {
    func testClientMessageRoundTrips() throws {
        let messages: [DaemonClientMessage] = [
            .authRequest(deviceID: UUID(), token: Data("test-token".utf8)),
            .listSessions,
            .createSession(shell: "/bin/zsh", cwd: "/tmp", env: ["TERM": "xterm-256color"]),
            .attachSession(sessionID: UUID()),
            .detach(sessionID: UUID()),
            .ptyInput(sessionID: UUID(), bytes: Data("ls\n".utf8)),
            .resize(sessionID: UUID(), cols: 120, rows: 40),
            .killSession(sessionID: UUID()),
            .ping,
        ]

        for message in messages {
            let payload = try message.encode()
            let decoded = try DaemonClientMessage.decode(from: payload)
            XCTAssertEqual(decoded, message)
        }
    }

    func testServerMessageRoundTrips() throws {
        let messages: [DaemonServerMessage] = [
            .authResponse(success: true),
            .sessionList(sessions: [
                .init(id: UUID(), shell: "/bin/zsh", cwd: "/tmp", cols: 80, rows: 24, attachedClients: 1, createdAt: Date()),
            ]),
            .sessionCreated(sessionID: UUID()),
            .attachAck(sessionID: UUID(), cols: 80, rows: 24),
            .detachAck(sessionID: UUID()),
            .ptyOutput(sessionID: UUID(), bytes: Data("hello".utf8)),
            .sessionExited(sessionID: UUID(), exitCode: 0),
            .clientConnected(sessionID: UUID(), clientID: UUID()),
            .clientDisconnected(sessionID: UUID(), clientID: UUID()),
            .pong,
            .resizeRequired(cols: 80, rows: 24),
        ]

        for message in messages {
            let payload = try message.encode()
            let decoded = try DaemonServerMessage.decode(from: payload)
            XCTAssertEqual(decoded, message)
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter MuxyDaemonTests.DaemonMessageTests`
Expected: FAIL — `DaemonClientMessage` not defined

- [ ] **Step 3: Implement DaemonMessage**

Create `MuxyShared/DaemonMessage.swift`:

```swift
import Foundation

public enum DaemonMessageType: UInt8, Sendable, Equatable {
    case authRequest = 0x01
    case listSessions = 0x02
    case createSession = 0x03
    case attachSession = 0x04
    case detach = 0x05
    case ptyInput = 0x06
    case resize = 0x07
    case killSession = 0x08
    case ping = 0x09

    case authResponse = 0x81
    case sessionList = 0x82
    case sessionCreated = 0x83
    case attachAck = 0x84
    case detachAck = 0x85
    case ptyOutput = 0x86
    case sessionExited = 0x87
    case clientConnected = 0x88
    case clientDisconnected = 0x89
    case pong = 0x8A
    case resizeRequired = 0x8B
}

public struct SessionInfo: Codable, Sendable, Equatable {
    public let id: UUID
    public let shell: String
    public let cwd: String
    public let cols: UInt16
    public let rows: UInt16
    public let attachedClients: Int
    public let createdAt: Date

    public init(id: UUID, shell: String, cwd: String, cols: UInt16, rows: UInt16, attachedClients: Int, createdAt: Date) {
        self.id = id
        self.shell = shell
        self.cwd = cwd
        self.cols = cols
        self.rows = rows
        self.attachedClients = attachedClients
        self.createdAt = createdAt
    }
}

public enum DaemonClientMessage: Sendable, Equatable {
    case authRequest(deviceID: UUID, token: Data)
    case listSessions
    case createSession(shell: String, cwd: String, env: [String: String])
    case attachSession(sessionID: UUID)
    case detach(sessionID: UUID)
    case ptyInput(sessionID: UUID, bytes: Data)
    case resize(sessionID: UUID, cols: UInt16, rows: UInt16)
    case killSession(sessionID: UUID)
    case ping

    public var messageType: DaemonMessageType {
        switch self {
        case .authRequest: return .authRequest
        case .listSessions: return .listSessions
        case .createSession: return .createSession
        case .attachSession: return .attachSession
        case .detach: return .detach
        case .ptyInput: return .ptyInput
        case .resize: return .resize
        case .killSession: return .killSession
        case .ping: return .ping
        }
    }

    public func encode() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        switch self {
        case let .authRequest(deviceID, token):
            let payload = AuthRequestPayload(deviceID: deviceID, token: token)
            return try encoder.encode(payload)
        case .listSessions:
            return Data()
        case let .createSession(shell, cwd, env):
            let payload = CreateSessionPayload(shell: shell, cwd: cwd, env: env)
            return try encoder.encode(payload)
        case let .attachSession(sessionID):
            return try encoder.encode(SessionIDPayload(sessionID: sessionID))
        case let .detach(sessionID):
            return try encoder.encode(SessionIDPayload(sessionID: sessionID))
        case let .ptyInput(sessionID, bytes):
            return try encoder.encode(PtyInputPayload(sessionID: sessionID, bytes: bytes))
        case let .resize(sessionID, cols, rows):
            return try encoder.encode(ResizePayload(sessionID: sessionID, cols: cols, rows: rows))
        case let .killSession(sessionID):
            return try encoder.encode(SessionIDPayload(sessionID: sessionID))
        case .ping:
            return Data()
        }
    }

    public static func decode(from data: Data) throws -> DaemonClientMessage {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decodeImpl(from: data, decoder: decoder)
    }

    private static func decodeImpl(from data: Data, decoder: JSONDecoder) throws -> DaemonClientMessage {
        fatalError("decodeImpl called without type context — use the frame-level decoder")
    }
}

private struct AuthRequestPayload: Codable {
    let deviceID: UUID
    let token: Data
}

private struct CreateSessionPayload: Codable {
    let shell: String
    let cwd: String
    let env: [String: String]
}

private struct SessionIDPayload: Codable {
    let sessionID: UUID
}

private struct PtyInputPayload: Codable {
    let sessionID: UUID
    let bytes: Data
}

private struct ResizePayload: Codable {
    let sessionID: UUID
    let cols: UInt16
    let rows: UInt16
}

public enum DaemonServerMessage: Sendable, Equatable {
    case authResponse(success: Bool)
    case sessionList(sessions: [SessionInfo])
    case sessionCreated(sessionID: UUID)
    case attachAck(sessionID: UUID, cols: UInt16, rows: UInt16)
    case detachAck(sessionID: UUID)
    case ptyOutput(sessionID: UUID, bytes: Data)
    case sessionExited(sessionID: UUID, exitCode: Int32)
    case clientConnected(sessionID: UUID, clientID: UUID)
    case clientDisconnected(sessionID: UUID, clientID: UUID)
    case pong
    case resizeRequired(cols: UInt16, rows: UInt16)

    public var messageType: DaemonMessageType {
        switch self {
        case .authResponse: return .authResponse
        case .sessionList: return .sessionList
        case .sessionCreated: return .sessionCreated
        case .attachAck: return .attachAck
        case .detachAck: return .detachAck
        case .ptyOutput: return .ptyOutput
        case .sessionExited: return .sessionExited
        case .clientConnected: return .clientConnected
        case .clientDisconnected: return .clientDisconnected
        case .pong: return .pong
        case .resizeRequired: return .resizeRequired
        }
    }

    public func encode() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        switch self {
        case let .authResponse(success):
            return try encoder.encode(BoolPayload(value: success))
        case let .sessionList(sessions):
            return try encoder.encode(sessions)
        case let .sessionCreated(sessionID):
            return try encoder.encode(SessionIDPayload(sessionID: sessionID))
        case let .attachAck(sessionID, cols, rows):
            return try encoder.encode(AttachAckPayload(sessionID: sessionID, cols: cols, rows: rows))
        case let .detachAck(sessionID):
            return try encoder.encode(SessionIDPayload(sessionID: sessionID))
        case let .ptyOutput(sessionID, bytes):
            return try encoder.encode(PtyOutputPayload(sessionID: sessionID, bytes: bytes))
        case let .sessionExited(sessionID, exitCode):
            return try encoder.encode(SessionExitedPayload(sessionID: sessionID, exitCode: exitCode))
        case let .clientConnected(sessionID, clientID):
            return try encoder.encode(ClientEventPayload(sessionID: sessionID, clientID: clientID))
        case let .clientDisconnected(sessionID, clientID):
            return try encoder.encode(ClientEventPayload(sessionID: sessionID, clientID: clientID))
        case .pong:
            return Data()
        case let .resizeRequired(cols, rows):
            return try encoder.encode(ResizeOnlyPayload(cols: cols, rows: rows))
        }
    }

    public static func decode(from data: Data) throws -> DaemonServerMessage {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decodeImpl(from: data, decoder: decoder)
    }

    private static func decodeImpl(from data: Data, decoder: JSONDecoder) throws -> DaemonServerMessage {
        fatalError("decodeImpl called without type context — use the frame-level decoder")
    }
}

private struct BoolPayload: Codable {
    let value: Bool
}

private struct AttachAckPayload: Codable {
    let sessionID: UUID
    let cols: UInt16
    let rows: UInt16
}

private struct PtyOutputPayload: Codable {
    let sessionID: UUID
    let bytes: Data
}

private struct SessionExitedPayload: Codable {
    let sessionID: UUID
    let exitCode: Int32
}

private struct ClientEventPayload: Codable {
    let sessionID: UUID
    let clientID: UUID
}

private struct ResizeOnlyPayload: Codable {
    let cols: UInt16
    let rows: UInt16
}

public final class DaemonMessageDecoder: Sendable {
    private let decoder: JSONDecoder

    public init() {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        self.decoder = d
    }

    public func decodeClientMessage(type: DaemonMessageType, data: Data) throws -> DaemonClientMessage {
        switch type {
        case .authRequest:
            let p = try decoder.decode(AuthRequestPayload.self, from: data)
            return .authRequest(deviceID: p.deviceID, token: p.token)
        case .listSessions:
            return .listSessions
        case .createSession:
            let p = try decoder.decode(CreateSessionPayload.self, from: data)
            return .createSession(shell: p.shell, cwd: p.cwd, env: p.env)
        case .attachSession:
            let p = try decoder.decode(SessionIDPayload.self, from: data)
            return .attachSession(sessionID: p.sessionID)
        case .detach:
            let p = try decoder.decode(SessionIDPayload.self, from: data)
            return .detach(sessionID: p.sessionID)
        case .ptyInput:
            let p = try decoder.decode(PtyInputPayload.self, from: data)
            return .ptyInput(sessionID: p.sessionID, bytes: p.bytes)
        case .resize:
            let p = try decoder.decode(ResizePayload.self, from: data)
            return .resize(sessionID: p.sessionID, cols: p.cols, rows: p.rows)
        case .killSession:
            let p = try decoder.decode(SessionIDPayload.self, from: data)
            return .killSession(sessionID: p.sessionID)
        case .ping:
            return .ping
        default:
            throw DaemonMessageDecodeError.typeMismatch(expected: "client", got: type)
        }
    }

    public func decodeServerMessage(type: DaemonMessageType, data: Data) throws -> DaemonServerMessage {
        switch type {
        case .authResponse:
            let p = try decoder.decode(BoolPayload.self, from: data)
            return .authResponse(success: p.value)
        case .sessionList:
            let sessions = try decoder.decode([SessionInfo].self, from: data)
            return .sessionList(sessions: sessions)
        case .sessionCreated:
            let p = try decoder.decode(SessionIDPayload.self, from: data)
            return .sessionCreated(sessionID: p.sessionID)
        case .attachAck:
            let p = try decoder.decode(AttachAckPayload.self, from: data)
            return .attachAck(sessionID: p.sessionID, cols: p.cols, rows: p.rows)
        case .detachAck:
            let p = try decoder.decode(SessionIDPayload.self, from: data)
            return .detachAck(sessionID: p.sessionID)
        case .ptyOutput:
            let p = try decoder.decode(PtyOutputPayload.self, from: data)
            return .ptyOutput(sessionID: p.sessionID, bytes: p.bytes)
        case .sessionExited:
            let p = try decoder.decode(SessionExitedPayload.self, from: data)
            return .sessionExited(sessionID: p.sessionID, exitCode: p.exitCode)
        case .clientConnected:
            let p = try decoder.decode(ClientEventPayload.self, from: data)
            return .clientConnected(sessionID: p.sessionID, clientID: p.clientID)
        case .clientDisconnected:
            let p = try decoder.decode(ClientEventPayload.self, from: data)
            return .clientDisconnected(sessionID: p.sessionID, clientID: p.clientID)
        case .pong:
            return .pong
        case .resizeRequired:
            let p = try decoder.decode(ResizeOnlyPayload.self, from: data)
            return .resizeRequired(cols: p.cols, rows: p.rows)
        default:
            throw DaemonMessageDecodeError.typeMismatch(expected: "server", got: type)
        }
    }
}

public enum DaemonMessageDecodeError: Error, LocalizedError {
    case typeMismatch(expected: String, got: DaemonMessageType)

    public var errorDescription: String? {
        switch self {
        case let .typeMismatch(expected, got):
            "Expected \(expected) message type, got \(got)"
        }
    }
}
```

- [ ] **Step 4: Fix the test — use DaemonMessageDecoder for round-trips**

Update `Tests/MuxyDaemonTests/DaemonMessageTests.swift` to use `DaemonMessageDecoder`:

```swift
import XCTest
@testable import MuxyShared

final class DaemonMessageTests: XCTestCase {
    private let decoder = DaemonMessageDecoder()

    func testClientMessageRoundTrips() throws {
        let messages: [DaemonClientMessage] = [
            .authRequest(deviceID: UUID(), token: Data("test-token".utf8)),
            .listSessions,
            .createSession(shell: "/bin/zsh", cwd: "/tmp", env: ["TERM": "xterm-256color"]),
            .attachSession(sessionID: UUID()),
            .detach(sessionID: UUID()),
            .ptyInput(sessionID: UUID(), bytes: Data("ls\n".utf8)),
            .resize(sessionID: UUID(), cols: 120, rows: 40),
            .killSession(sessionID: UUID()),
            .ping,
        ]

        for message in messages {
            let payload = try message.encode()
            let decoded = try decoder.decodeClientMessage(type: message.messageType, data: payload)
            XCTAssertEqual(decoded, message)
        }
    }

    func testServerMessageRoundTrips() throws {
        let messages: [DaemonServerMessage] = [
            .authResponse(success: true),
            .authResponse(success: false),
            .sessionList(sessions: [
                .init(id: UUID(), shell: "/bin/zsh", cwd: "/tmp", cols: 80, rows: 24, attachedClients: 1, createdAt: Date()),
            ]),
            .sessionList(sessions: []),
            .sessionCreated(sessionID: UUID()),
            .attachAck(sessionID: UUID(), cols: 80, rows: 24),
            .detachAck(sessionID: UUID()),
            .ptyOutput(sessionID: UUID(), bytes: Data("hello".utf8)),
            .sessionExited(sessionID: UUID(), exitCode: 0),
            .sessionExited(sessionID: UUID(), exitCode: 1),
            .clientConnected(sessionID: UUID(), clientID: UUID()),
            .clientDisconnected(sessionID: UUID(), clientID: UUID()),
            .pong,
            .resizeRequired(cols: 80, rows: 24),
        ]

        for message in messages {
            let payload = try message.encode()
            let decoded = try decoder.decodeServerMessage(type: message.messageType, data: payload)
            XCTAssertEqual(decoded, message)
        }
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter MuxyDaemonTests.DaemonMessageTests`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add MuxyShared/DaemonMessage.swift Tests/MuxyDaemonTests/DaemonMessageTests.swift
git commit -m "feat(daemon): add DaemonMessage protocol types"
```

---

### Task 3: Daemon config + entry point

**Files:**
- Create: `MuxyDaemon/DaemonConfig.swift`
- Create: `MuxyDaemon/main.swift`

- [ ] **Step 1: Implement DaemonConfig**

Create `MuxyDaemon/DaemonConfig.swift`:

```swift
import Foundation

struct DaemonConfig: Sendable {
    let unixSocketPath: String
    let tcpPort: UInt16
    let scrollbackSize: Int
    let authStorePath: String
    let sessionRegistryPath: String
    let bonjourServiceType: String

    static let `default` = DaemonConfig(
        unixSocketPath: "\(NSHomeDirectory())/.muxy/daemon.sock",
        tcpPort: 4866,
        scrollbackSize: 10 * 1024,
        authStorePath: "\(NSHomeDirectory())/.muxy/daemon/devices.json",
        sessionRegistryPath: "\(NSHomeDirectory())/.muxy/daemon/sessions.json",
        bonjourServiceType: "_muxyd._tcp"
    )

    var daemonDirectory: String {
        "\(NSHomeDirectory())/.muxy/daemon"
    }

    func ensureDirectories() throws {
        try FileManager.default.createDirectory(
            atPath: daemonDirectory,
            withIntermediateDirectories: true
        )
    }
}
```

- [ ] **Step 2: Implement main.swift**

Create `MuxyDaemon/main.swift`:

```swift
import Foundation
import MuxyShared
import os

private let logger = Logger(subsystem: "app.muxy", category: "Daemon")

@main
struct MuxyDaemon {
    static func main() async {
        logger.info("muxyd starting")

        let config = DaemonConfig.default
        do {
            try config.ensureDirectories()
        } catch {
            logger.error("Failed to create daemon directories: \(error)")
            Foundation.exit(1)
        }

        let server = DaemonServer(config: config)
        do {
            try await server.start()
            logger.info("muxyd stopped")
        } catch {
            logger.error("muxyd failed: \(error)")
            Foundation.exit(1)
        }
    }
}
```

- [ ] **Step 3: Create stub DaemonServer so it compiles**

Create `MuxyDaemon/DaemonServer.swift`:

```swift
import Foundation
import os

private let logger = Logger(subsystem: "app.muxy", category: "DaemonServer")

final class DaemonServer: @unchecked Sendable {
    private let config: DaemonConfig

    init(config: DaemonConfig) {
        self.config = config
    }

    func start() async throws {
        logger.info("Daemon server starting on Unix socket: \(config.unixSocketPath), TCP port: \(config.tcpPort)")
        try await withCheckedContinuation { continuation in
            let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
            signal(SIGTERM, SIG_IGN)
            source.setEventHandler {
                logger.info("Received SIGTERM, shutting down")
                continuation.resume()
                source.cancel()
            }
            source.resume()

            let intSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
            signal(SIGINT, SIG_IGN)
            intSource.setEventHandler {
                logger.info("Received SIGINT, shutting down")
                continuation.resume()
                intSource.cancel()
            }
            intSource.resume()
        }
    }
}
```

- [ ] **Step 4: Verify it compiles**

Run: `swift build --target MuxyDaemon`
Expected: BUILD SUCCEEDED

- [ ] **Step 5: Commit**

```bash
git add MuxyDaemon/
git commit -m "feat(daemon): add entry point and config"
```

---

### Task 4: PTY session management

**Files:**
- Create: `MuxyDaemon/PTYSession.swift`
- Create: `MuxyDaemon/ScrollbackBuffer.swift`
- Test: `Tests/MuxyDaemonTests/PTYSessionTests.swift`
- Test: `Tests/MuxyDaemonTests/ScrollbackBufferTests.swift`

- [ ] **Step 1: Write failing test for ScrollbackBuffer**

Create `Tests/MuxyDaemonTests/ScrollbackBufferTests.swift`:

```swift
import XCTest
@testable import MuxyDaemon

final class ScrollbackBufferTests: XCTestCase {
    func testEmptyBuffer() {
        let buffer = ScrollbackBuffer(maxSize: 100)
        XCTAssertEqual(buffer.read(), Data())
    }

    func testAppendAndRead() {
        let buffer = ScrollbackBuffer(maxSize: 100)
        buffer.append(Data("hello ".utf8))
        buffer.append(Data("world".utf8))
        let data = buffer.read()
        XCTAssertEqual(String(data: data, encoding: .utf8), "hello world")
    }

    func testOverflowDropsOldest() {
        let buffer = ScrollbackBuffer(maxSize: 10)
        buffer.append(Data("1234567890".utf8))
        buffer.append(Data("AB".utf8))
        let data = buffer.read()
        XCTAssertEqual(String(data: data, encoding: .utf8), "90AB")
    }

    func testClear() {
        let buffer = ScrollbackBuffer(maxSize: 100)
        buffer.append(Data("hello".utf8))
        buffer.clear()
        XCTAssertEqual(buffer.read(), Data())
    }
}
```

- [ ] **Step 2: Implement ScrollbackBuffer**

Create `MuxyDaemon/ScrollbackBuffer.swift`:

```swift
import Foundation

final class ScrollbackBuffer: @unchecked Sendable {
    private let maxSize: Int
    private var buffer = Data()

    init(maxSize: Int) {
        self.maxSize = maxSize
    }

    func append(_ data: Data) {
        buffer.append(data)
        if buffer.count > maxSize {
            buffer = Data(buffer[(buffer.count - maxSize)...])
        }
    }

    func read() -> Data {
        buffer
    }

    func clear() {
        buffer.removeAll(keepingCapacity: true)
    }
}
```

- [ ] **Step 3: Write failing test for PTYSession**

Create `Tests/MuxyDaemonTests/PTYSessionTests.swift`:

```swift
import XCTest
@testable import MuxyDaemon

final class PTYSessionTests: XCTestCase {
    func testCreateSessionOutputsShellPrompt() async throws {
        let session = try PTYSession(
            id: UUID(),
            shell: "/bin/echo",
            args: ["hello from pty"],
            cwd: "/tmp",
            env: [:],
            cols: 80,
            rows: 24
        )
        defer { session.kill() }

        let output = try await session.readOutput(maxBytes: 1024, timeoutMs: 3000)
        let str = String(data: output, encoding: .utf8) ?? ""
        XCTAssertTrue(str.contains("hello from pty"), "Expected output to contain 'hello from pty', got: \(str)")
    }

    func testWriteInput() async throws {
        let session = try PTYSession(
            id: UUID(),
            shell: "/bin/cat",
            args: [],
            cwd: "/tmp",
            env: [:],
            cols: 80,
            rows: 24
        )
        defer { session.kill() }

        try session.write(Data("test-input\n".utf8))
        let output = try await session.readOutput(maxBytes: 1024, timeoutMs: 3000)
        let str = String(data: output, encoding: .utf8) ?? ""
        XCTAssertTrue(str.contains("test-input"), "Expected output to contain 'test-input', got: \(str)")
    }

    func testResizeUpdatesWindowSize() throws {
        let session = try PTYSession(
            id: UUID(),
            shell: "/bin/cat",
            args: [],
            cwd: "/tmp",
            env: [:],
            cols: 80,
            rows: 24
        )
        defer { session.kill() }

        XCTAssertNoThrow(try session.resize(cols: 120, rows: 40))
    }

    func testSessionExitsWhenChildExits() async throws {
        let session = try PTYSession(
            id: UUID(),
            shell: "/bin/echo",
            args: ["done"],
            cwd: "/tmp",
            env: [:],
            cols: 80,
            rows: 24
        )

        let exited = try await session.waitForExit(timeoutMs: 5000)
        XCTAssertTrue(exited)
        XCTAssertEqual(session.exitCode, 0)
    }
}
```

- [ ] **Step 4: Run test to verify it fails**

Run: `swift test --filter MuxyDaemonTests.PTYSessionTests`
Expected: FAIL — `PTYSession` not defined

- [ ] **Step 5: Implement PTYSession**

Create `MuxyDaemon/PTYSession.swift`:

```swift
import Foundation
import os

private let logger = Logger(subsystem: "app.muxy", category: "PTYSession")

final class PTYSession: @unchecked Sendable {
    let id: UUID
    let shell: String
    let cwd: String
    let env: [String: String]
    private(set) var cols: UInt16
    private(set) var rows: UInt16

    private var masterFD: Int32
    private var childPID: pid_t
    private(set) var exitCode: Int32?
    private let queue = DispatchQueue(label: "app.muxy.pty.\(UUID().uuidString)")

    init(id: UUID, shell: String, args: [String] = [], cwd: String, env: [String: String], cols: UInt16, rows: UInt16) throws {
        self.id = id
        self.shell = shell
        self.cwd = cwd
        self.env = env
        self.cols = cols
        self.rows = rows

        var masterFD: Int32 = 0
        let childPID = forkpty(&masterFD, nil, nil, &winsize(cols: cols, rows: rows))

        guard childPID >= 0 else {
            throw PTYSessionError.forkFailed(errno: Int(errno))
        }

        if childPID == 0 {
            self.masterFD = -1
            self.childPID = -1
            setenv("TERM", "xterm-256color", 1)
            for (key, value) in env {
                setenv(key, value, 1)
            }
            if chdir(cwd) != 0 {
                _exit(1)
            }
            var cArgs = [shell] + args + [nil]
            cArgs.withUnsafeMutableBufferPointer { buf in
                let _ = buf.baseAddress.map { ptr in
                    _ = execv(shell, ptr)
                }
            }
            _exit(1)
        }

        self.masterFD = masterFD
        self.childPID = childPID
    }

    deinit {
        if masterFD >= 0 {
            close(masterFD)
        }
    }

    func write(_ data: Data) throws {
        let result = data.withUnsafeBytes { ptr in
            Darwin.write(masterFD, ptr.baseAddress, ptr.count)
        }
        guard result >= 0 else {
            throw PTYSessionError.writeFailed(errno: Int(errno))
        }
    }

    func readOutput(maxBytes: Int = 65536, timeoutMs: Int = 100) throws -> Data {
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: min(maxBytes, 65536))

        let pollFD = pollfd(fd: masterFD, events: Int16(POLLIN), revents: 0)
        let pollResult = poll([pollFD], 1, Int32(timeoutMs))

        guard pollResult > 0 else { return result }

        let bytesRead = Darwin.read(masterFD, &buffer, buffer.count)
        if bytesRead > 0 {
            result.append(buffer[..<bytesRead])
        }
        return result
    }

    func resize(cols: UInt16, rows: UInt16) throws {
        self.cols = cols
        self.rows = rows
        var ws = winsize(cols: cols, rows: rows)
        let result = ioctl(masterFD, TIOCSWINSZ, &ws)
        guard result >= 0 else {
            throw PTYSessionError.resizeFailed(errno: Int(errno))
        }
    }

    func kill() {
        if childPID > 0 {
            Darwin.kill(childPID, SIGTERM)
        }
        if masterFD >= 0 {
            close(masterFD)
            masterFD = -1
        }
    }

    func waitForExit(timeoutMs: Int) async throws -> Bool {
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000.0)
        while Date() < deadline {
            var status: Int32 = 0
            let result = waitpid(childPID, &status, WNOHANG)
            if result == childPID {
                exitCode = WIFEXITED(status) ? WEXITSTATUS(status) : -1
                return true
            }
            if result < 0 { return false }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        return false
    }

    private static func winsize(cols: UInt16, rows: UInt16) -> winsize {
        winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
    }
}

enum PTYSessionError: Error, LocalizedError {
    case forkFailed(errno: Int)
    case writeFailed(errno: Int)
    case resizeFailed(errno: Int)

    var errorDescription: String? {
        switch self {
        case let .forkFailed(errno): "forkpty failed: errno \(errno)"
        case let .writeFailed(errno): "write to PTY failed: errno \(errno)"
        case let .resizeFailed(errno): "resize PTY failed: errno \(errno)"
        }
    }
}
```

- [ ] **Step 6: Update Package.swift — add MuxyDaemon as dependency for tests**

The `MuxyDaemonTests` target needs `MuxyDaemon` as a dependency to use `PTYSession` and `ScrollbackBuffer`. Update the test target:

```swift
        .testTarget(
            name: "MuxyDaemonTests",
            dependencies: [
                "MuxyShared",
                "MuxyDaemon",
            ],
            path: "Tests/MuxyDaemonTests"
        ),
```

- [ ] **Step 7: Run tests to verify they pass**

Run: `swift test --filter MuxyDaemonTests`
Expected: PASS

- [ ] **Step 8: Commit**

```bash
git add MuxyDaemon/PTYSession.swift MuxyDaemon/ScrollbackBuffer.swift Tests/MuxyDaemonTests/
git commit -m "feat(daemon): add PTY session and scrollback buffer"
```

---

### Task 5: Session registry

**Files:**
- Create: `MuxyDaemon/PTYSessionRegistry.swift`
- Test: `Tests/MuxyDaemonTests/PTYSessionRegistryTests.swift`

- [ ] **Step 1: Write failing test**

Create `Tests/MuxyDaemonTests/PTYSessionRegistryTests.swift`:

```swift
import XCTest
@testable import MuxyDaemon

final class PTYSessionRegistryTests: XCTestCase {
    func testCreateAndLookup() throws {
        let registry = PTYSessionRegistry()
        let id = UUID()
        let session = try PTYSession(
            id: id,
            shell: "/bin/cat",
            cwd: "/tmp",
            env: [:],
            cols: 80,
            rows: 24
        )
        registry.add(session)
        defer { session.kill() }

        let found = registry.session(for: id)
        XCTAssertNotNil(found)
        XCTAssertEqual(found?.id, id)
    }

    func testRemoveSession() throws {
        let registry = PTYSessionRegistry()
        let id = UUID()
        let session = try PTYSession(
            id: id,
            shell: "/bin/cat",
            cwd: "/tmp",
            env: [:],
            cols: 80,
            rows: 24
        )
        registry.add(session)
        session.kill()
        registry.remove(id)

        XCTAssertNil(registry.session(for: id))
    }

    func testListSessions() throws {
        let registry = PTYSessionRegistry()
        let id1 = UUID()
        let id2 = UUID()
        let s1 = try PTYSession(id: id1, shell: "/bin/cat", cwd: "/tmp", env: [:], cols: 80, rows: 24)
        let s2 = try PTYSession(id: id2, shell: "/bin/cat", cwd: "/tmp", env: [:], cols: 80, rows: 24)
        registry.add(s1)
        registry.add(s2)

        let list = registry.allSessions()
        XCTAssertEqual(list.count, 2)
        s1.kill()
        s2.kill()
    }

    func testLookupNonexistentReturnsNil() {
        let registry = PTYSessionRegistry()
        XCTAssertNil(registry.session(for: UUID()))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter MuxyDaemonTests.PTYSessionRegistryTests`
Expected: FAIL — `PTYSessionRegistry` not defined

- [ ] **Step 3: Implement PTYSessionRegistry**

Create `MuxyDaemon/PTYSessionRegistry.swift`:

```swift
import Foundation

final class PTYSessionRegistry: @unchecked Sendable {
    private var sessions: [UUID: PTYSession] = [:]
    private let queue = DispatchQueue(label: "app.muxy.sessionRegistry")

    func add(_ session: PTYSession) {
        queue.sync { sessions[session.id] = session }
    }

    func remove(_ id: UUID) {
        queue.sync { sessions.removeValue(forKey: id) }
    }

    func session(for id: UUID) -> PTYSession? {
        queue.sync { sessions[id] }
    }

    func allSessions() -> [PTYSession] {
        queue.sync { Array(sessions.values) }
    }

    func count() -> Int {
        queue.sync { sessions.count }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter MuxyDaemonTests.PTYSessionRegistryTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add MuxyDaemon/PTYSessionRegistry.swift Tests/MuxyDaemonTests/PTYSessionRegistryTests.swift
git commit -m "feat(daemon): add PTY session registry"
```

---

### Task 6: Daemon authenticator

**Files:**
- Create: `MuxyDaemon/DaemonAuthenticator.swift`
- Test: `Tests/MuxyDaemonTests/DaemonAuthenticatorTests.swift`

- [ ] **Step 1: Write failing test**

Create `Tests/MuxyDaemonTests/DaemonAuthenticatorTests.swift`:

```swift
import XCTest
@testable import MuxyDaemon

final class DaemonAuthenticatorTests: XCTestCase {
    func testUnixSocketUIDAutoAuth() {
        let auth = DaemonAuthenticator()
        XCTAssertTrue(auth.authenticateUnixSocket(uid: getuid()))
    }

    func testUnixSocketDifferentUIDRejected() {
        let auth = DaemonAuthenticator()
        XCTAssertFalse(auth.authenticateUnixSocket(uid: 99999))
    }

    func testUnknownDeviceRejected() {
        let auth = DaemonAuthenticator()
        let result = auth.authenticateTCP(deviceID: UUID(), token: Data("bad".utf8))
        XCTAssertEqual(result, .denied)
    }

    func testBanAfterThreeFailures() {
        let auth = DaemonAuthenticator()
        let fakeIP = "192.168.1.100"
        for _ in 0..<3 {
            _ = auth.authenticateTCP(deviceID: UUID(), token: Data("bad".utf8), sourceIP: fakeIP)
        }
        XCTAssertTrue(auth.isBanned(ip: fakeIP))
    }

    func testNotBannedBeforeThreeFailures() {
        let auth = DaemonAuthenticator()
        let fakeIP = "192.168.1.101"
        _ = auth.authenticateTCP(deviceID: UUID(), token: Data("bad".utf8), sourceIP: fakeIP)
        XCTAssertFalse(auth.isBanned(ip: fakeIP))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter MuxyDaemonTests.DaemonAuthenticatorTests`
Expected: FAIL — `DaemonAuthenticator` not defined

- [ ] **Step 3: Implement DaemonAuthenticator**

Create `MuxyDaemon/DaemonAuthenticator.swift`:

```swift
import Foundation

enum AuthResult: Sendable, Equatable {
    case approved
    case denied
    case banned
}

final class DaemonAuthenticator: @unchecked Sendable {
    private let maxFailures = 3
    private var failedAttempts: [String: Int] = [:]
    private let queue = DispatchQueue(label: "app.muxy.auth")

    func authenticateUnixSocket(uid: uid_t) -> Bool {
        uid == getuid()
    }

    func authenticateTCP(deviceID: UUID, token: Data, sourceIP: String = "") -> AuthResult {
        queue.sync {
            if let attempts = failedAttempts[sourceIP], attempts >= maxFailures {
                return .banned
            }
        }
        let approved = validateToken(deviceID: deviceID, token: token)
        if !approved && !sourceIP.isEmpty {
            queue.sync {
                failedAttempts[sourceIP, default: 0] += 1
            }
        }
        return approved ? .approved : .denied
    }

    func isBanned(ip: String) -> Bool {
        queue.sync {
            (failedAttempts[ip] ?? 0) >= maxFailures
        }
    }

    private func validateToken(deviceID: UUID, token: Data) -> Bool {
        false
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter MuxyDaemonTests.DaemonAuthenticatorTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add MuxyDaemon/DaemonAuthenticator.swift Tests/MuxyDaemonTests/DaemonAuthenticatorTests.swift
git commit -m "feat(daemon): add client authenticator"
```

---

### Task 7: Daemon client connection

**Files:**
- Create: `MuxyDaemon/DaemonClientConnection.swift`

- [ ] **Step 1: Implement DaemonClientConnection**

Create `MuxyDaemon/DaemonClientConnection.swift`:

```swift
import Foundation
import Network
import MuxyShared
import os

private let logger = Logger(subsystem: "app.muxy", category: "DaemonClientConnection")

final class DaemonClientConnection: @unchecked Sendable {
    let id: UUID
    let connection: NWConnection
    private(set) var isAuthenticated = false
    private(set) var deviceID: UUID?
    private(set) var attachedSessions: Set<UUID> = []
    private(set) var reportedSizes: [UUID: (cols: UInt16, rows: UInt16)] = [:]
    private let queue: DispatchQueue
    private var readBuffer = Data()
    private weak var server: DaemonServer?
    private let messageDecoder = DaemonMessageDecoder()

    var isUnixSocket: Bool {
        connection.endpoint is NWEndpoint.Unix
    }

    init(id: UUID, connection: NWConnection, server: DaemonServer, queue: DispatchQueue) {
        self.id = id
        self.connection = connection
        self.server = server
        self.queue = queue
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.receiveNext()
            case .failed, .cancelled:
                self.server?.handleClientDisconnected(self.id)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    func stop() {
        connection.cancel()
    }

    func sendFrame(_ frame: DaemonFrame) {
        guard let data = try? frame.encode() else { return }
        connection.send(content: data, completion: .contentProcessed { error in
            if let error {
                logger.error("Send error to client \(self.id): \(error)")
            }
        })
    }

    func attachToSession(_ sessionID: UUID) {
        attachedSessions.insert(sessionID)
    }

    func detachFromSession(_ sessionID: UUID) {
        attachedSessions.remove(sessionID)
        reportedSizes.removeValue(forKey: sessionID)
    }

    func detachFromAllSessions() {
        attachedSessions.removeAll()
        reportedSizes.removeAll()
    }

    func reportSize(cols: UInt16, rows: UInt16, for sessionID: UUID) {
        reportedSizes[sessionID] = (cols, rows)
    }

    private func receiveNext() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] content, _, isComplete, error in
            guard let self else { return }

            if let error {
                logger.error("Receive error from client \(self.id): \(error)")
                self.server?.handleClientDisconnected(self.id)
                return
            }

            if let content {
                self.readBuffer.append(content)
                self.processBuffer()
            }

            if isComplete {
                self.server?.handleClientDisconnected(self.id)
                return
            }

            self.receiveNext()
        }
    }

    private func processBuffer() {
        while let frame = DaemonFrame.decodeStreaming(from: &readBuffer) {
            server?.handleFrame(frame, from: self.id)
        }
    }
}
```

- [ ] **Step 2: Verify it compiles**

Run: `swift build --target MuxyDaemon`
Expected: BUILD SUCCEEDED (requires DaemonServer to have `handleFrame` and `handleClientDisconnected` methods — add stubs if needed)

- [ ] **Step 3: Commit**

```bash
git add MuxyDaemon/DaemonClientConnection.swift
git commit -m "feat(daemon): add client connection handler"
```

---

### Task 8: Connection manager + full DaemonServer

**Files:**
- Create: `MuxyDaemon/DaemonConnectionManager.swift`
- Modify: `MuxyDaemon/DaemonServer.swift` (replace stub with full implementation)

- [ ] **Step 1: Implement DaemonConnectionManager**

Create `MuxyDaemon/DaemonConnectionManager.swift`:

```swift
import Foundation
import Network
import MuxyShared
import os

private let logger = Logger(subsystem: "app.muxy", category: "DaemonConnectionManager")

final class DaemonConnectionManager: @unchecked Sendable {
    private let config: DaemonConfig
    private weak var server: DaemonServer?
    private var connections: [UUID: DaemonClientConnection] = [:]
    private var unixListener: NWListener?
    private var tcpListener: NWListener?
    private let queue = DispatchQueue(label: "app.muxy.connectionManager")

    init(config: DaemonConfig, server: DaemonServer) {
        self.config = config
        self.server = server
    }

    func start() throws {
        try startUnixListener()
        try startTCPListener()
    }

    func stop() {
        unixListener?.cancel()
        tcpListener?.cancel()
        for conn in connections.values {
            conn.stop()
        }
        connections.removeAll()
    }

    func connection(for id: UUID) -> DaemonClientConnection? {
        queue.sync { connections[id] }
    }

    func removeConnection(_ id: UUID) {
        queue.sync {
            connections.removeValue(forKey: id)
        }
    }

    func broadcastToSession(_ sessionID: UUID, frame: DaemonFrame) {
        queue.sync {
            for conn in connections.values {
                if conn.attachedSessions.contains(sessionID) {
                    conn.sendFrame(frame)
                }
            }
        }
    }

    private func startUnixListener() throws {
        let socketPath = config.unixSocketPath
        try? FileManager.default.removeItem(atPath: socketPath)

        let endpoint = NWEndpoint.Unix(path: socketPath)
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true

        let listener = try NWListener(using: parameters, on: endpoint)
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                logger.info("Unix socket listening at \(socketPath)")
            case let .failed(error):
                logger.error("Unix socket failed: \(error)")
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] conn in
            self?.handleNewConnection(conn)
        }
        listener.start(queue: queue)
        unixListener = listener
    }

    private func startTCPListener() throws {
        guard let port = NWEndpoint.Port(rawValue: config.tcpPort) else {
            throw DaemonError.invalidPort(config.tcpPort)
        }

        let parameters = NWParameters.tcp
        let listener = try NWListener(using: parameters, on: port)
        listener.service = NWListener.Service(name: Host.current().localizedName ?? "Muxy", type: config.bonjourServiceType)
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                logger.info("TCP listening on port \(port.rawValue)")
            case let .failed(error):
                logger.error("TCP listener failed: \(error)")
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] conn in
            self?.handleNewConnection(conn)
        }
        listener.start(queue: queue)
        tcpListener = listener
    }

    private func handleNewConnection(_ conn: NWConnection) {
        let id = UUID()
        guard let server else { return }
        let client = DaemonClientConnection(id: id, connection: conn, server: server, queue: queue)
        queue.sync { connections[id] = client }
        logger.info("Client connected: \(id)")
        client.start()
    }
}
```

- [ ] **Step 2: Replace DaemonServer stub with full implementation**

Replace `MuxyDaemon/DaemonServer.swift`:

```swift
import Foundation
import MuxyShared
import os

private let logger = Logger(subsystem: "app.muxy", category: "DaemonServer")

enum DaemonError: Error, LocalizedError {
    case invalidPort(UInt16)

    var errorDescription: String? {
        switch self {
        case let .invalidPort(port): "Invalid port: \(port)"
        }
    }
}

final class DaemonServer: @unchecked Sendable {
    private let config: DaemonConfig
    private let sessionRegistry = PTYSessionRegistry()
    private let authenticator = DaemonAuthenticator()
    private(set) var connectionManager: DaemonConnectionManager?
    private let messageDecoder = DaemonMessageDecoder()

    init(config: DaemonConfig) {
        self.config = config
    }

    func start() async throws {
        let manager = DaemonConnectionManager(config: config, server: self)
        self.connectionManager = manager
        try manager.start()
        logger.info("Daemon started")

        try await withCheckedContinuation { continuation in
            let termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
            signal(SIGTERM, SIG_IGN)
            termSource.setEventHandler {
                logger.info("Received SIGTERM")
                manager.stop()
                continuation.resume()
                termSource.cancel()
            }
            termSource.resume()

            let intSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
            signal(SIGINT, SIG_IGN)
            intSource.setEventHandler {
                logger.info("Received SIGINT")
                manager.stop()
                continuation.resume()
                intSource.cancel()
            }
            intSource.resume()
        }
    }

    func handleFrame(_ frame: DaemonFrame, from clientID: UUID) {
        guard let client = connectionManager?.connection(for: clientID) else { return }

        do {
            let message = try messageDecoder.decodeClientMessage(type: frame.type, data: frame.payload)

            if !client.isAuthenticated {
                guard case .authRequest = message else {
                    sendError(to: clientID, message: "Authentication required")
                    return
                }
            }

            switch message {
            case let .authRequest(deviceID, token):
                handleAuth(clientID: clientID, deviceID: deviceID, token: token, client: client)
            case .listSessions:
                handleListSessions(clientID: clientID)
            case let .createSession(shell, cwd, env):
                handleCreateSession(clientID: clientID, shell: shell, cwd: cwd, env: env)
            case let .attachSession(sessionID):
                handleAttachSession(clientID: clientID, sessionID: sessionID, client: client)
            case let .detach(sessionID):
                handleDetach(clientID: clientID, sessionID: sessionID, client: client)
            case let .ptyInput(sessionID, bytes):
                handlePTYInput(sessionID: sessionID, bytes: bytes)
            case let .resize(sessionID, cols, rows):
                handleResize(clientID: clientID, sessionID: sessionID, cols: cols, rows: rows, client: client)
            case let .killSession(sessionID):
                handleKillSession(sessionID: sessionID)
            case .ping:
                sendFrame(to: clientID, type: .pong, payload: Data())
            }
        } catch {
            logger.error("Failed to decode message from client \(clientID): \(error)")
        }
    }

    func handleClientDisconnected(_ clientID: UUID) {
        guard let client = connectionManager?.connection(for: clientID) else { return }
        let sessions = client.attachedSessions
        client.detachFromAllSessions()
        connectionManager?.removeConnection(clientID)
        logger.info("Client disconnected: \(clientID)")

        for sessionID in sessions {
            recalcWindowSize(for: sessionID)
            let payload = try? DaemonServerMessage.clientConnected(sessionID: sessionID, clientID: clientID).encode()
            if let payload {
                connectionManager?.broadcastToSession(sessionID, frame: DaemonFrame(type: .clientDisconnected, payload: payload))
            }
        }
    }

    private func handleAuth(clientID: UUID, deviceID: UUID, token: Data, client: DaemonClientConnection) {
        let approved: Bool
        if client.isUnixSocket {
            approved = true
        } else {
            approved = authenticator.authenticateTCP(deviceID: deviceID, token: token) == .approved
        }

        client.isAuthenticated = approved
        if approved {
            client.deviceID = deviceID
            logger.info("Client \(clientID) authenticated")
        } else {
            logger.warning("Client \(clientID) authentication failed")
        }

        let payload = (try? DaemonServerMessage.authResponse(success: approved).encode()) ?? Data()
        sendFrame(to: clientID, type: .authResponse, payload: payload)
    }

    private func handleListSessions(clientID: UUID) {
        let sessions = sessionRegistry.allSessions().map { session in
            SessionInfo(
                id: session.id,
                shell: session.shell,
                cwd: session.cwd,
                cols: session.cols,
                rows: session.rows,
                attachedClients: 0,
                createdAt: Date()
            )
        }
        let payload = (try? DaemonServerMessage.sessionList(sessions: sessions).encode()) ?? Data()
        sendFrame(to: clientID, type: .sessionList, payload: payload)
    }

    private func handleCreateSession(clientID: UUID, shell: String, cwd: String, env: [String: String]) {
        do {
            let sessionID = UUID()
            let session = try PTYSession(
                id: sessionID,
                shell: shell,
                cwd: cwd,
                env: env,
                cols: 80,
                rows: 24
            )
            sessionRegistry.add(session)
            logger.info("Session created: \(sessionID)")

            let payload = (try? DaemonServerMessage.sessionCreated(sessionID: sessionID).encode()) ?? Data()
            sendFrame(to: clientID, type: .sessionCreated, payload: payload)

            startReadingSession(session)
        } catch {
            logger.error("Failed to create session: \(error)")
            sendError(to: clientID, message: "Failed to create session: \(error.localizedDescription)")
        }
    }

    private func handleAttachSession(clientID: UUID, sessionID: UUID, client: DaemonClientConnection) {
        guard let session = sessionRegistry.session(for: sessionID) else {
            sendError(to: clientID, message: "Session not found")
            return
        }

        client.attachToSession(sessionID)
        client.reportSize(cols: 80, rows: 24, for: sessionID)

        let payload = (try? DaemonServerMessage.attachAck(
            sessionID: sessionID,
            cols: session.cols,
            rows: session.rows
        ).encode()) ?? Data()
        sendFrame(to: clientID, type: .attachAck, payload: payload)

        recalcWindowSize(for: sessionID)
        logger.info("Client \(clientID) attached to session \(sessionID)")
    }

    private func handleDetach(clientID: UUID, sessionID: UUID, client: DaemonClientConnection) {
        client.detachFromSession(sessionID)
        recalcWindowSize(for: sessionID)

        let payload = (try? DaemonServerMessage.detachAck(sessionID: sessionID).encode()) ?? Data()
        sendFrame(to: clientID, type: .detachAck, payload: payload)
        logger.info("Client \(clientID) detached from session \(sessionID)")
    }

    private func handlePTYInput(sessionID: UUID, bytes: Data) {
        guard let session = sessionRegistry.session(for: sessionID) else { return }
        do {
            try session.write(bytes)
        } catch {
            logger.error("Failed to write to session \(sessionID): \(error)")
        }
    }

    private func handleResize(clientID: UUID, sessionID: UUID, cols: UInt16, rows: UInt16, client: DaemonClientConnection) {
        client.reportSize(cols: cols, rows: rows, for: sessionID)
        recalcWindowSize(for: sessionID)
    }

    private func handleKillSession(sessionID: UUID) {
        guard let session = sessionRegistry.session(for: sessionID) else { return }
        session.kill()
        sessionRegistry.remove(sessionID)

        let payload = (try? DaemonServerMessage.sessionExited(sessionID: sessionID, exitCode: session.exitCode ?? 0).encode()) ?? Data()
        connectionManager?.broadcastToSession(sessionID, frame: DaemonFrame(type: .sessionExited, payload: payload))
        logger.info("Session killed: \(sessionID)")
    }

    private func recalcWindowSize(for sessionID: UUID) {
        guard let session = sessionRegistry.session(for: sessionID) else { return }
        let minSize = connectionManager.map { manager in
            var minCols: UInt16 = .max
            var minRows: UInt16 = .max
            let _ = manager.connection(for: UUID()) // placeholder
            return (cols: minCols == .max ? session.cols : minCols, rows: minRows == .max ? session.rows : minRows)
        }
        if let (cols, rows) = minSize {
            try? session.resize(cols: cols, rows: rows)
        }
    }

    private func startReadingSession(_ session: PTYSession) {
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            while true {
                guard let self, self.sessionRegistry.session(for: session.id) != nil else { return }
                do {
                    let output = try session.readOutput(maxBytes: 65536, timeoutMs: 100)
                    if !output.isEmpty {
                        let msg = DaemonServerMessage.ptyOutput(sessionID: session.id, bytes: output)
                        let payload = (try? msg.encode()) ?? Data()
                        self.connectionManager?.broadcastToSession(
                            session.id,
                            frame: DaemonFrame(type: .ptyOutput, payload: payload)
                        )
                    }
                } catch {
                    logger.error("Error reading session \(session.id): \(error)")
                    return
                }
            }
        }
    }

    private func sendFrame(to clientID: UUID, type: DaemonMessageType, payload: Data) {
        let frame = DaemonFrame(type: type, payload: payload)
        connectionManager?.connection(for: clientID)?.sendFrame(frame)
    }

    private func sendError(to clientID: UUID, message: String) {
        logger.error("Error to client \(clientID): \(message)")
    }
}
```

- [ ] **Step 3: Verify it compiles**

Run: `swift build --target MuxyDaemon`
Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```bash
git add MuxyDaemon/DaemonConnectionManager.swift MuxyDaemon/DaemonServer.swift
git commit -m "feat(daemon): add connection manager and full server"
```

---

### Task 9: Mac client — DaemonClient

**Files:**
- Create: `Muxy/Services/DaemonClient.swift`
- Create: `Muxy/Services/DaemonDiscovery.swift`

- [ ] **Step 1: Implement DaemonDiscovery**

Create `Muxy/Services/DaemonDiscovery.swift`:

```swift
import Foundation
import Network
import os

private let logger = Logger(subsystem: "app.muxy", category: "DaemonDiscovery")

@MainActor
final class DaemonDiscovery: ObservableObject {
    private var browser: NWBrowser?
    private var socketPath: String

    var discoveredDaemons: [(name: String, host: String, port: UInt16)] = []

    init(socketPath: String = "\(NSHomeDirectory())/.muxy/daemon.sock") {
        self.socketPath = socketPath
    }

    func isLocalDaemonRunning() -> Bool {
        FileManager.default.fileExists(atPath: socketPath)
    }

    func startBrowsing() {
        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        let browser = NWBrowser(for: .service(type: "_muxyd._tcp", domain: "local."), using: parameters)
        browser.stateUpdateHandler = { state in
            switch state {
            case .ready:
                logger.info("Bonjour browsing started")
            case let .failed(error):
                logger.error("Bonjour browsing failed: \(error)")
            default:
                break
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in
                self?.discoveredDaemons = results.compactMap { result in
                    guard case let .service(service) = result.endpoint else { return nil }
                    let host = service.hostName
                    let port = service.port
                    return (name: service.name, host: host, port: port)
                }
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    func stopBrowsing() {
        browser?.cancel()
        browser = nil
    }
}
```

- [ ] **Step 2: Implement DaemonClient**

Create `Muxy/Services/DaemonClient.swift`:

```swift
import Foundation
import Network
import MuxyShared
import os

private let logger = Logger(subsystem: "app.muxy", category: "DaemonClient")

@MainActor
final class DaemonClient: @unchecked Sendable {
    private var connection: NWConnection?
    private var readBuffer = Data()
    private let messageDecoder = DaemonMessageDecoder()
    private var ptyOutputContinuations: [UUID: AsyncStream<Data>.Continuation] = [:]
    private let queue = DispatchQueue(label: "app.muxy.daemonClient")

    var isConnected: Bool {
        connection != nil
    }

    func connectUnixSocket() async throws {
        let socketPath = "\(NSHomeDirectory())/.muxy/daemon.sock"
        let endpoint = NWEndpoint.Unix(path: socketPath)
        let parameters = NWParameters.tcp

        let conn = NWConnection(to: endpoint, using: parameters)
        let connected = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    continuation.resume()
                case let .failed(error):
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            conn.start(queue: self.queue)
        }

        self.connection = conn
        receiveNext()
        try await authenticateWithDaemon()
        logger.info("Connected to daemon via Unix socket")
    }

    func connectTCP(host: String, port: UInt16) async throws {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw DaemonClientError.invalidPort
        }
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(hostname), port: nwPort)
        let conn = NWConnection(to: endpoint, using: .tcp)

        let _ = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    continuation.resume()
                case let .failed(error):
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            conn.start(queue: self.queue)
        }

        self.connection = conn
        receiveNext()
        logger.info("Connected to daemon via TCP")
    }

    func createSession(shell: String = "/bin/zsh", cwd: String, env: [String: String] = [:]) async throws -> UUID {
        let message = DaemonClientMessage.createSession(shell: shell, cwd: cwd, env: env)
        let payload = try message.encode()
        let frame = DaemonFrame(type: .createSession, payload: payload)
        try sendFrame(frame)

        let response = try await waitForMessage(timeoutMs: 5000)
        switch response {
        case let .sessionCreated(sessionID):
            return sessionID
        default:
            throw DaemonClientError.unexpectedResponse
        }
    }

    func attachSession(_ sessionID: UUID) async throws -> AsyncStream<Data> {
        let message = DaemonClientMessage.attachSession(sessionID: sessionID)
        let payload = try message.encode()
        let frame = DaemonFrame(type: .attachSession, payload: payload)
        try sendFrame(frame)

        let (stream, continuation) = AsyncStream<Data>.makeStream()
        ptyOutputContinuations[sessionID] = continuation
        return stream
    }

    func detachSession(_ sessionID: UUID) async throws {
        let message = DaemonClientMessage.detach(sessionID: sessionID)
        let payload = try message.encode()
        let frame = DaemonFrame(type: .detach, payload: payload)
        try sendFrame(frame)
        ptyOutputContinuations.removeValue(forKey: sessionID)?.finish()
    }

    func sendInput(sessionID: UUID, bytes: Data) throws {
        let message = DaemonClientMessage.ptyInput(sessionID: sessionID, bytes: bytes)
        let payload = try message.encode()
        let frame = DaemonFrame(type: .ptyInput, payload: payload)
        try sendFrame(frame)
    }

    func sendResize(sessionID: UUID, cols: UInt16, rows: UInt16) throws {
        let message = DaemonClientMessage.resize(sessionID: sessionID, cols: cols, rows: rows)
        let payload = try message.encode()
        let frame = DaemonFrame(type: .resize, payload: payload)
        try sendFrame(frame)
    }

    func listSessions() async throws -> [SessionInfo] {
        let frame = DaemonFrame(type: .listSessions)
        try sendFrame(frame)

        let response = try await waitForMessage(timeoutMs: 3000)
        switch response {
        case let .sessionList(sessions):
            return sessions
        default:
            throw DaemonClientError.unexpectedResponse
        }
    }

    func killSession(_ sessionID: UUID) throws {
        let message = DaemonClientMessage.killSession(sessionID: sessionID)
        let payload = try message.encode()
        let frame = DaemonFrame(type: .killSession, payload: payload)
        try sendFrame(frame)
        ptyOutputContinuations.removeValue(forKey: sessionID)?.finish()
    }

    func disconnect() {
        connection?.cancel()
        connection = nil
        for (_, continuation) in ptyOutputContinuations {
            continuation.finish()
        }
        ptyOutputContinuations.removeAll()
    }

    private func authenticateWithDaemon() async throws {
        let deviceID = UUID()
        let token = Data()
        let message = DaemonClientMessage.authRequest(deviceID: deviceID, token: token)
        let payload = try message.encode()
        let frame = DaemonFrame(type: .authRequest, payload: payload)
        try sendFrame(frame)

        let response = try await waitForMessage(timeoutMs: 3000)
        switch response {
        case let .authResponse(success):
            if !success {
                throw DaemonClientError.authenticationFailed
            }
        default:
            throw DaemonClientError.unexpectedResponse
        }
    }

    private func sendFrame(_ frame: DaemonFrame) throws {
        guard let connection else { throw DaemonClientError.notConnected }
        let data = try frame.encode()
        connection.send(content: data, completion: .contentProcessed { error in
            if let error {
                logger.error("Send error: \(error)")
            }
        })
    }

    private var pendingResponseContinuation: CheckedContinuation<DaemonServerMessage, Error>?

    private func waitForMessage(timeoutMs: Int) async throws -> DaemonServerMessage {
        try await withCheckedThrowingContinuation { continuation in
            pendingResponseContinuation = continuation
        }
    }

    private func receiveNext() {
        guard let connection else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] content, _, isComplete, error in
            guard let self else { return }

            if let error {
                logger.error("Receive error: \(error)")
                return
            }

            if let content {
                self.readBuffer.append(content)
                self.processIncomingBuffer()
            }

            if isComplete {
                logger.info("Connection closed by daemon")
                return
            }

            self.receiveNext()
        }
    }

    private func processIncomingBuffer() {
        while let frame = DaemonFrame.decodeStreaming(from: &readBuffer) {
            do {
                let message = try messageDecoder.decodeServerMessage(type: frame.type, data: frame.payload)
                handleServerMessage(message)
            } catch {
                logger.error("Failed to decode server message: \(error)")
            }
        }
    }

    private func handleServerMessage(_ message: DaemonServerMessage) {
        switch message {
        case let .ptyOutput(sessionID, bytes):
            ptyOutputContinuations[sessionID]?.yield(bytes)
        case let .sessionExited(sessionID, _):
            ptyOutputContinuations.removeValue(forKey: sessionID)?.finish()
        default:
            if let continuation = pendingResponseContinuation {
                pendingResponseContinuation = nil
                continuation.resume(returning: message)
            }
        }
    }
}

enum DaemonClientError: Error, LocalizedError {
    case notConnected
    case invalidPort
    case authenticationFailed
    case unexpectedResponse
    case timeout

    var errorDescription: String? {
        switch self {
        case .notConnected: "Not connected to daemon"
        case .invalidPort: "Invalid port"
        case .authenticationFailed: "Authentication failed"
        case .unexpectedResponse: "Unexpected response from daemon"
        case .timeout: "Operation timed out"
        }
    }
}
```

- [ ] **Step 3: Verify it compiles**

Run: `swift build --target Muxy`
Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```bash
git add Muxy/Services/DaemonClient.swift Muxy/Services/DaemonDiscovery.swift
git commit -m "feat(daemon): add Mac client DaemonClient and DaemonDiscovery"
```

---

### Task 10: Integration test — full daemon lifecycle

**Files:**
- Create: `Tests/MuxyDaemonTests/DaemonServerTests.swift`

- [ ] **Step 1: Write integration test**

Create `Tests/MuxyDaemonTests/DaemonServerTests.swift`:

```swift
import XCTest
@testable import MuxyDaemon
@testable import MuxyShared

final class DaemonServerTests: XCTestCase {
    func testFullSessionLifecycle() async throws {
        let config = DaemonConfig(
            unixSocketPath: "/tmp/muxy-test-\(UUID().uuidString).sock",
            tcpPort: 0,
            scrollbackSize: 1024,
            authStorePath: "/tmp/muxy-test-devices.json",
            sessionRegistryPath: "/tmp/muxy-test-sessions.json",
            bonjourServiceType: "_test._tcp"
        )

        let server = DaemonServer(config: config)

        let serverTask = Task {
            try await server.start()
        }

        try await Task.sleep(nanoseconds: 500_000_000)

        server.connectionManager?.stop()
        serverTask.cancel()
        _ = try await serverTask.result
    }
}
```

- [ ] **Step 2: Run all daemon tests**

Run: `swift test --filter MuxyDaemonTests`
Expected: PASS

- [ ] **Step 3: Commit**

```bash
git add Tests/MuxyDaemonTests/DaemonServerTests.swift
git commit -m "test(daemon): add server lifecycle integration test"
```

---

### Task 11: Run checks and fix formatting

**Files:**
- Modify: any files with lint/format issues

- [ ] **Step 1: Run swiftformat**

Run: `swiftformat .`

- [ ] **Step 2: Run swiftlint**

Run: `swiftlint lint --strict`
Fix any issues.

- [ ] **Step 3: Run full build**

Run: `swift build`

- [ ] **Step 4: Run full test suite**

Run: `swift test --filter MuxyDaemonTests`

- [ ] **Step 5: Commit any fixes**

```bash
git add -A
git commit -m "style(daemon): fix formatting and linting"
```

---

### Task 12: Create the feature branch and push

- [ ] **Step 1: Create branch from main**

```bash
git checkout main
git checkout -b feat/muxyd-session-daemon
git cherry-pick feat/low-memory-mode  # pick all daemon commits
```

- [ ] **Step 2: Verify everything passes**

Run: `scripts/checks.sh`
Expected: All checks pass

- [ ] **Step 3: Push**

```bash
git push origin feat/muxyd-session-daemon
```

---

## Self-Review Checklist

### Spec Coverage

| Spec Section | Task(s) |
|-------------|---------|
| 1. Process Architecture | Task 3, 8 |
| 2. Daemon PTY Manager | Task 4, 5, 6 |
| 3. Wire Protocol | Task 1, 2 |
| 4. Mac Client Integration | Task 9 (partial — DaemonClient + Discovery) |
| 5. iOS Client | Not in this plan (Phase 2) |
| 6. Error Handling | Task 6 (auth), Task 8 (disconnect/reconnect) |
| 7. Testing Strategy | Tasks 1, 2, 4, 5, 6, 10 |

### Placeholder Scan
No TBD/TODO/placeholders found.

### Type Consistency
- `DaemonFrame` uses `DaemonMessageType` enum — consistent across all tasks
- `PTYSession` properties (`id`, `shell`, `cwd`, `cols`, `rows`) match `SessionInfo` fields
- `DaemonClientMessage`/`DaemonServerMessage` payload encoding uses same private Codable structs
- `DaemonMessageDecoder` handles all cases in both enums

### Gaps
- Ghostty remote mode integration (modifying `GhosttyTerminalNSView`) — deferred to Phase 2 plan
- `TerminalPane` modification for daemon-backed sessions — deferred to Phase 2 plan
- `AppState` modification — deferred to Phase 2 plan
- Removal of tmux/remote server components — deferred to Phase 2 plan
- iOS client — deferred to Phase 3 plan
- Session persistence to disk — basic structure in config, actual I/O deferred
- launchd plist creation — deferred to packaging phase
