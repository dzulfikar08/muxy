import Foundation
import MuxyShared
import os

private let logger = Logger(subsystem: "app.muxy", category: "DaemonServer")

public final class DaemonServer: @unchecked Sendable {
    private let config: DaemonConfig
    private let sessionRegistry = PTYSessionRegistry()
    private let authenticator = DaemonAuthenticator()
    private var connectionManager: DaemonConnectionManager?
    private let queue = DispatchQueue(label: "app.muxy.server")

    public init(config: DaemonConfig) {
        self.config = config
    }

    public func start() throws {
        let manager = DaemonConnectionManager(config: config, server: self)
        self.connectionManager = manager
        try manager.start()
        logger.info("Daemon server started")
    }

    public func stop() {
        connectionManager?.stop()
        connectionManager = nil
        for session in sessionRegistry.allSessions() {
            session.kill()
        }
        logger.info("Daemon server stopped")
    }

    func handleFrame(_ frame: DaemonFrame, from clientID: UUID) {
        guard let client = connectionManager?.connection(for: clientID) else { return }

        do {
            let message = try client.decodeMessage(from: frame)
            dispatchMessage(message, from: client)
        } catch {
            logger.error("Failed to decode message from client \(clientID): \(error)")
        }
    }

    func handleClientDisconnected(_ clientID: UUID) {
        guard let client = connectionManager?.connection(for: clientID) else { return }

        let sessionIDs = client.attachedSessions
        client.detachFromAllSessions()

        for sessionID in sessionIDs {
            broadcastSessionEvent(.clientDisconnected(sessionID: sessionID, clientID: clientID), to: sessionID)
            recalcWindowSize(for: sessionID)
        }

        connectionManager?.removeConnection(clientID)
        logger.info("Client disconnected: \(clientID)")
    }

    private func dispatchMessage(_ message: DaemonClientMessage, from client: DaemonClientConnection) {
        switch message {
        case let .authRequest(deviceID, token):
            handleAuth(client: client, deviceID: deviceID, token: token)
        case .listSessions:
            handleListSessions(client: client)
        case let .createSession(shell, cwd, env):
            handleCreateSession(client: client, shell: shell, cwd: cwd, env: env)
        case let .attachSession(sessionID):
            handleAttachSession(client: client, sessionID: sessionID)
        case let .detach(sessionID):
            handleDetach(client: client, sessionID: sessionID)
        case let .ptyInput(sessionID, bytes):
            handlePTYInput(sessionID: sessionID, bytes: bytes)
        case let .resize(sessionID, cols, rows):
            handleResize(sessionID: sessionID, cols: cols, rows: rows, client: client)
        case let .killSession(sessionID):
            handleKillSession(client: client, sessionID: sessionID)
        case .ping:
            sendToClient(client, message: .pong)
        }
    }

    private func handleAuth(client: DaemonClientConnection, deviceID: UUID, token: Data) {
        let success: Bool
        if client.isUnixSocket {
            success = authenticator.authenticateUnixSocket(uid: getuid())
        } else {
            let result = authenticator.authenticateTCP(deviceID: deviceID, token: token)
            success = (result == .approved)
        }

        if success {
            client.markAuthenticated(deviceID: deviceID)
        }
        sendToClient(client, message: .authResponse(success: success))
    }

    private func handleListSessions(client: DaemonClientConnection) {
        let sessions = sessionRegistry.allSessions().map { session in
            let attachedCount = connectionManager.map { manager in
                manager.connectionsAttachedToSession(session.id).count
            } ?? 0
            return SessionInfo(
                id: session.id,
                shell: session.shell,
                cwd: session.cwd,
                cols: session.cols,
                rows: session.rows,
                attachedClients: attachedCount,
                createdAt: Date()
            )
        }
        sendToClient(client, message: .sessionList(sessions: sessions))
    }

    private func handleCreateSession(client: DaemonClientConnection, shell: String, cwd: String, env: [String: String]) {
        let sessionID = UUID()
        do {
            let session = try PTYSession(
                id: sessionID,
                shell: shell,
                cwd: cwd,
                env: env,
                cols: 80,
                rows: 24
            )
            sessionRegistry.add(session)
            startReadingSession(session)
            sendToClient(client, message: .sessionCreated(sessionID: sessionID))
            logger.info("Session created: \(sessionID) shell=\(shell)")
        } catch {
            logger.error("Failed to create session: \(error)")
        }
    }

    private func handleAttachSession(client: DaemonClientConnection, sessionID: UUID) {
        guard let session = sessionRegistry.session(for: sessionID) else {
            logger.warning("Attach failed: session \(sessionID) not found")
            return
        }

        client.attachToSession(sessionID)
        client.reportSize(cols: session.cols, rows: session.rows, for: sessionID)

        sendToClient(
            client,
            message: .attachAck(sessionID: sessionID, cols: session.cols, rows: session.rows)
        )

        broadcastSessionEvent(.clientConnected(sessionID: sessionID, clientID: client.id), to: sessionID, excludeClient: client.id)
        recalcWindowSize(for: sessionID)
        logger.info("Client \(client.id) attached to session \(sessionID)")
    }

    private func handleDetach(client: DaemonClientConnection, sessionID: UUID) {
        client.detachFromSession(sessionID)
        sendToClient(client, message: .detachAck(sessionID: sessionID))
        broadcastSessionEvent(.clientDisconnected(sessionID: sessionID, clientID: client.id), to: sessionID)
        recalcWindowSize(for: sessionID)
        logger.info("Client \(client.id) detached from session \(sessionID)")
    }

    private func handlePTYInput(sessionID: UUID, bytes: Data) {
        guard let session = sessionRegistry.session(for: sessionID) else { return }
        do {
            try session.write(bytes)
        } catch {
            logger.error("Failed to write to session \(sessionID): \(error)")
        }
    }

    private func handleResize(sessionID: UUID, cols: UInt16, rows: UInt16, client: DaemonClientConnection) {
        client.reportSize(cols: cols, rows: rows, for: sessionID)
        recalcWindowSize(for: sessionID)
    }

    private func handleKillSession(client: DaemonClientConnection, sessionID: UUID) {
        guard let session = sessionRegistry.session(for: sessionID) else { return }

        session.kill()
        sessionRegistry.remove(sessionID)

        broadcastSessionEvent(.sessionExited(sessionID: sessionID, exitCode: -1), to: sessionID)
        logger.info("Session killed: \(sessionID)")
    }

    private func sendToClient(_ client: DaemonClientConnection, message: DaemonServerMessage) {
        guard let payload = try? message.encode() else {
            logger.error("Failed to encode server message type 0x\(String(format: "%02X", message.messageType.rawValue))")
            return
        }
        client.sendFrame(DaemonFrame(type: message.messageType, payload: payload))
    }

    private func broadcastSessionEvent(_ message: DaemonServerMessage, to sessionID: UUID, excludeClient excludedID: UUID? = nil) {
        guard let payload = try? message.encode() else { return }
        let frame = DaemonFrame(type: message.messageType, payload: payload)
        connectionManager?.broadcastToSession(sessionID, frame: frame)
    }

    private func recalcWindowSize(for sessionID: UUID) {
        guard let session = sessionRegistry.session(for: sessionID) else { return }
        guard let manager = connectionManager else { return }

        var minCols = UInt16.max
        var minRows = UInt16.max

        let attachedConnections = manager.connectionsAttachedToSession(sessionID)
        for conn in attachedConnections {
            if let size = conn.reportedSizes[sessionID] {
                minCols = min(minCols, size.cols)
                minRows = min(minRows, size.rows)
            }
        }

        guard minCols != UInt16.max, minRows != UInt16.max else { return }
        if session.cols == minCols, session.rows == minRows { return }

        do {
            try session.resize(cols: minCols, rows: minRows)
            let msg = DaemonServerMessage.resizeRequired(cols: minCols, rows: minRows)
            if let payload = try? msg.encode() {
                manager.broadcastToSession(
                    sessionID,
                    frame: DaemonFrame(type: .resizeRequired, payload: payload)
                )
            }
        } catch {
            logger.error("Failed to resize session \(sessionID): \(error)")
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
}
