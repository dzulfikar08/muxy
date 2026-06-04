import Foundation
import MuxyShared
import Network
import os

private let logger = Logger(subsystem: "app.muxy", category: "DaemonClientConnection")

final class DaemonClientConnection: @unchecked Sendable {
    let id: UUID
    let connection: NWConnection
    let isUnixSocket: Bool
    private(set) var isAuthenticated = false
    private(set) var deviceID: UUID?
    private(set) var attachedSessions: Set<UUID> = []
    private(set) var reportedSizes: [UUID: (cols: UInt16, rows: UInt16)] = [:]
    private let queue: DispatchQueue
    private var readBuffer = Data()
    private weak var server: DaemonServer?
    private let messageDecoder = DaemonMessageDecoder()

    init(id: UUID, connection: NWConnection, isUnixSocket: Bool, server: DaemonServer, queue: DispatchQueue) {
        self.id = id
        self.connection = connection
        self.isUnixSocket = isUnixSocket
        self.server = server
        self.queue = queue
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.receiveNext()
            case .failed,
                 .cancelled:
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
        guard let data = try? frame.encode() else {
            logger.error("Failed to encode frame for client \(self.id)")
            return
        }
        connection.send(content: data, completion: .contentProcessed { error in
            if let error {
                logger.error("Send error to client \(self.id): \(error)")
            }
        })
    }

    func markAuthenticated(deviceID: UUID) {
        isAuthenticated = true
        self.deviceID = deviceID
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

    func decodeMessage(from frame: DaemonFrame) throws -> DaemonClientMessage {
        try messageDecoder.decodeClientMessage(type: frame.type, data: frame.payload)
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
            server?.handleFrame(frame, from: id)
        }
    }
}
