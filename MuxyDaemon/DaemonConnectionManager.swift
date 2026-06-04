import Foundation
import MuxyShared
import Network
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
        unixListener = nil
        tcpListener?.cancel()
        tcpListener = nil
        let allConnections = queue.sync { connections.values.map(\.self) }
        for conn in allConnections {
            conn.stop()
        }
        queue.sync {
            connections.removeAll()
        }
    }

    func connection(for id: UUID) -> DaemonClientConnection? {
        queue.sync { connections[id] }
    }

    func removeConnection(_ id: UUID) {
        _ = queue.sync { connections.removeValue(forKey: id) }
    }

    func broadcastToSession(_ sessionID: UUID, frame: DaemonFrame) {
        let targets = queue.sync {
            connections.values.filter { $0.attachedSessions.contains(sessionID) }
        }
        for conn in targets {
            conn.sendFrame(frame)
        }
    }

    func connectedClientCount() -> Int {
        queue.sync { connections.count }
    }

    func connectionsAttachedToSession(_ sessionID: UUID) -> [DaemonClientConnection] {
        queue.sync {
            connections.values.filter { $0.attachedSessions.contains(sessionID) }
        }
    }

    private func startUnixListener() throws {
        let socketPath = config.unixSocketPath
        try? FileManager.default.removeItem(atPath: socketPath)

        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = NWEndpoint.unix(path: socketPath)

        unixListener = try NWListener(using: params)
        unixListener?.newConnectionHandler = { [weak self] connection in
            self?.handleNewConnection(connection, isUnix: true)
        }
        unixListener?.start(queue: queue)
        logger.info("Unix listener started on \(socketPath)")
    }

    private func startTCPListener() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true

        guard let port = NWEndpoint.Port(rawValue: config.tcpPort) else {
            throw DaemonConnectionError.invalidPort(config.tcpPort)
        }

        tcpListener = try NWListener(using: params, on: port)

        if !config.bonjourServiceType.isEmpty {
            tcpListener?.service = NWListener.Service(
                name: nil,
                type: config.bonjourServiceType,
                domain: nil
            )
        }

        tcpListener?.newConnectionHandler = { [weak self] connection in
            self?.handleNewConnection(connection, isUnix: false)
        }
        tcpListener?.start(queue: queue)
        logger.info("TCP listener started on port \(self.config.tcpPort)")
    }

    private func handleNewConnection(_ connection: NWConnection, isUnix: Bool) {
        let clientID = UUID()
        guard let server else { return }
        let client = DaemonClientConnection(
            id: clientID,
            connection: connection,
            isUnixSocket: isUnix,
            server: server,
            queue: queue
        )
        queue.sync {
            connections[clientID] = client
        }
        client.start()
        logger.info("Client connected: \(clientID) unix=\(isUnix)")
    }
}

enum DaemonConnectionError: Error, LocalizedError {
    case unixEndpointCreationFailed
    case invalidPort(UInt16)
    case listenerStartFailed(String)

    var errorDescription: String? {
        switch self {
        case .unixEndpointCreationFailed:
            "Failed to create Unix domain socket endpoint"
        case let .invalidPort(port):
            "Invalid TCP port: \(port)"
        case let .listenerStartFailed(detail):
            "Listener failed to start: \(detail)"
        }
    }
}
