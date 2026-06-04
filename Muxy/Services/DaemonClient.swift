import Foundation
import MuxyShared
import Network
import os

private let logger = Logger(subsystem: "app.muxy", category: "DaemonClient")

enum DaemonClientError: Error, LocalizedError {
    case notConnected
    case invalidPort(UInt16)
    case authenticationFailed
    case unexpectedResponse(DaemonMessageType)
    case timeout

    var errorDescription: String? {
        switch self {
        case .notConnected:
            "Not connected to daemon"
        case let .invalidPort(port):
            "Invalid TCP port: \(port)"
        case .authenticationFailed:
            "Authentication failed"
        case let .unexpectedResponse(type):
            "Unexpected response type: 0x\(String(format: "%02X", type.rawValue))"
        case .timeout:
            "Operation timed out"
        }
    }
}

@MainActor
@Observable
final class DaemonClient {
    private(set) var isConnected = false
    private let transport = DaemonTransport()

    func connectUnixSocket() async throws {
        let socketPath = "\(NSHomeDirectory())/.muxy/daemon.sock"
        guard FileManager.default.fileExists(atPath: socketPath) else {
            throw DaemonClientError.notConnected
        }
        try await transport.connectUnixSocket(socketPath: socketPath)
        isConnected = true
        try await authenticateUnixSocket()
    }

    func connectTCP(host: String, port: UInt16) async throws {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw DaemonClientError.invalidPort(port)
        }
        try await transport.connectTCP(host: host, port: nwPort)
        isConnected = true
        try await authenticateTCP()
    }

    func createSession(shell: String, cwd: String, env: [String: String]) async throws -> UUID {
        let response = try await sendAndWait(
            message: .createSession(shell: shell, cwd: cwd, env: env),
            expectedType: .sessionCreated
        )
        guard case let .sessionCreated(sessionID) = response else {
            throw DaemonClientError.unexpectedResponse(response.messageType)
        }
        return sessionID
    }

    func attachSession(_ sessionID: UUID) async throws -> AsyncStream<Data> {
        let response = try await sendAndWait(
            message: .attachSession(sessionID: sessionID),
            expectedType: .attachAck
        )
        guard case .attachAck = response else {
            throw DaemonClientError.unexpectedResponse(response.messageType)
        }
        return AsyncStream { continuation in
            self.transport.registerPTYContinuation(continuation, for: sessionID)
            continuation.onTermination = { @Sendable _ in
                Task { @MainActor [weak self] in
                    self?.transport.removePTYContinuation(for: sessionID)
                    try? await self?.detachSession(sessionID)
                }
            }
        }
    }

    func detachSession(_ sessionID: UUID) async throws {
        let response = try await sendAndWait(
            message: .detach(sessionID: sessionID),
            expectedType: .detachAck
        )
        guard case .detachAck = response else {
            throw DaemonClientError.unexpectedResponse(response.messageType)
        }
        transport.removePTYContinuation(for: sessionID)
    }

    func sendInput(sessionID: UUID, bytes: Data) throws {
        guard isConnected else { throw DaemonClientError.notConnected }
        transport.sendFrame(message: .ptyInput(sessionID: sessionID, bytes: bytes))
    }

    func sendResize(sessionID: UUID, cols: UInt16, rows: UInt16) throws {
        guard isConnected else { throw DaemonClientError.notConnected }
        transport.sendFrame(message: .resize(sessionID: sessionID, cols: cols, rows: rows))
    }

    func listSessions() async throws -> [SessionInfo] {
        let response = try await sendAndWait(
            message: .listSessions,
            expectedType: .sessionList
        )
        guard case let .sessionList(sessions) = response else {
            throw DaemonClientError.unexpectedResponse(response.messageType)
        }
        return sessions
    }

    func killSession(_ sessionID: UUID) throws {
        guard isConnected else { throw DaemonClientError.notConnected }
        transport.sendFrame(message: .killSession(sessionID: sessionID))
    }

    func disconnect() {
        transport.disconnect()
        isConnected = false
    }

    private func sendAndWait(
        message: DaemonClientMessage,
        expectedType: DaemonMessageType
    ) async throws -> DaemonServerMessage {
        try await transport.sendAndWait(message: message, expectedType: expectedType)
    }

    private func authenticateUnixSocket() async throws {
        let deviceID = UUID()
        let token = Data("\(deviceID.uuidString)-local-\(getuid())".utf8)
        let response = try await sendAndWait(
            message: .authRequest(deviceID: deviceID, token: token),
            expectedType: .authResponse
        )
        guard case let .authResponse(success) = response, success else {
            throw DaemonClientError.authenticationFailed
        }
    }

    private func authenticateTCP() async throws {
        let deviceID = UUID()
        let token = Data("\(deviceID.uuidString)-remote".utf8)
        let response = try await sendAndWait(
            message: .authRequest(deviceID: deviceID, token: token),
            expectedType: .authResponse
        )
        guard case let .authResponse(success) = response, success else {
            throw DaemonClientError.authenticationFailed
        }
    }
}

final class DaemonTransport: @unchecked Sendable {
    private let messageDecoder = DaemonMessageDecoder()
    private let queue = DispatchQueue(label: "app.muxy.daemonClient.transport")
    private var connection: NWConnection?
    private var readBuffer = Data()
    private var pendingContinuations: [DaemonMessageType: CheckedContinuation<DaemonServerMessage, Error>] = [:]
    private var ptyContinuations: [UUID: AsyncStream<Data>.Continuation] = [:]
    func connectUnixSocket(socketPath: String) async throws {
        let endpoint = NWEndpoint.unix(path: socketPath)
        let connection = NWConnection(to: endpoint, using: .tcp)
        self.connection = connection
        try await startConnection(connection)
    }

    func connectTCP(host: String, port: NWEndpoint.Port) async throws {
        let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
        self.connection = connection
        try await startConnection(connection)
    }

    func sendAndWait(
        message: DaemonClientMessage,
        expectedType: DaemonMessageType
    ) async throws -> DaemonServerMessage {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: DaemonClientError.notConnected)
                    return
                }
                self.pendingContinuations[expectedType] = continuation
                self.sendFrame(message: message)
            }
            queue.asyncAfter(deadline: .now() + 10) { [weak self] in
                let removed = self?.queue.sync {
                    self?.pendingContinuations.removeValue(forKey: expectedType)
                }
                removed?.resume(throwing: DaemonClientError.timeout)
            }
        }
    }

    func sendFrame(message: DaemonClientMessage) {
        queue.async { [weak self] in
            self?.sendFrameSync(message: message)
        }
    }

    func registerPTYContinuation(_ continuation: AsyncStream<Data>.Continuation, for sessionID: UUID) {
        queue.async {
            self.ptyContinuations[sessionID] = continuation
        }
    }

    func removePTYContinuation(for sessionID: UUID) {
        queue.async {
            self.ptyContinuations.removeValue(forKey: sessionID)
        }
    }

    func disconnect() {
        queue.sync {
            for (_, continuation) in ptyContinuations {
                continuation.finish()
            }
            ptyContinuations.removeAll()
            for (_, continuation) in pendingContinuations {
                continuation.resume(throwing: DaemonClientError.notConnected)
            }
            pendingContinuations.removeAll()
            connection?.cancel()
            connection = nil
            readBuffer.removeAll()
        }
    }

    private func startConnection(_ connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { [weak self] state in
                self?.queue.async {
                    switch state {
                    case .ready:
                        self?.startReading()
                        continuation.resume()
                    case let .failed(error):
                        continuation.resume(throwing: error)
                    default:
                        break
                    }
                }
            }
            connection.start(queue: queue)
        }
    }

    private func startReading() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            self?.queue.async {
                guard let self else { return }
                if let data, !data.isEmpty {
                    self.readBuffer.append(data)
                    self.processBuffer()
                }
                if isComplete || error != nil {
                    if let error {
                        logger.error("Connection read error: \(String(describing: error))")
                    }
                    return
                }
                self.startReading()
            }
        }
    }

    private func processBuffer() {
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
        case let .authResponse(success):
            if let continuation = pendingContinuations.removeValue(forKey: .authResponse) {
                if success {
                    continuation.resume(returning: message)
                } else {
                    continuation.resume(throwing: DaemonClientError.authenticationFailed)
                }
            }
        case .ptyOutput:
            if case let .ptyOutput(sessionID, bytes) = message {
                ptyContinuations[sessionID]?.yield(bytes)
            }
        case .sessionExited:
            if case let .sessionExited(sessionID, exitCode) = message {
                logger.info("Session \(sessionID) exited with code \(exitCode)")
                ptyContinuations[sessionID]?.finish()
                ptyContinuations.removeValue(forKey: sessionID)
            }
        case .resizeRequired:
            break
        default:
            pendingContinuations.removeValue(forKey: message.messageType)?.resume(returning: message)
        }
    }

    private func sendFrameSync(message: DaemonClientMessage) {
        guard let connection else { return }
        do {
            let payload = try message.encode()
            let frame = DaemonFrame(type: message.messageType, payload: payload)
            let data = try frame.encode()
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    logger.error("Failed to send frame: \(error)")
                }
            })
        } catch {
            logger.error("Failed to encode message: \(error)")
        }
    }
}
