import Foundation
import Network
import MuxyShared
import os

private let logger = Logger(subsystem: "app.muxy", category: "RelayConnection")

final class RelayConnection: @unchecked Sendable {
    private let socketPath: String
    private var connection: NWConnection?
    private var reader: FrameReader?
    private var writer: FrameWriter?
    private let messageDecoder = DaemonMessageDecoder()
    private let queue = DispatchQueue(label: "app.muxy.relay")

    init(socketPath: String = "\(NSHomeDirectory())/.muxy/daemon.sock") {
        self.socketPath = socketPath
    }

    func connect() async throws {
        let parameters = NWParameters.tcp
        let conn = NWConnection(to: NWEndpoint.unix(path: socketPath), using: parameters)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    continuation.resume()
                case let .failed(error):
                    continuation.resume(throwing: error)
                case .cancelled:
                    continuation.resume(throwing: RelayError.connectionFailed)
                default:
                    break
                }
            }
            conn.start(queue: self.queue)
        }

        self.connection = conn
        self.reader = FrameReader(connection: conn, queue: queue)
        self.writer = FrameWriter(connection: conn, queue: queue)
    }

    func authenticate() async throws {
        let deviceID = UUID()
        let token = Data()
        writer?.sendMessage(.authRequest(deviceID: deviceID, token: token))

        guard let frame = await reader?.readFrame(),
              frame.type == .authResponse,
              let message = try? messageDecoder.decodeServerMessage(type: .authResponse, data: frame.payload),
              case let .authResponse(success) = message,
              success
        else {
            throw RelayError.authenticationFailed
        }
    }

    func createSession(shell: String, cwd: String, env: [String: String]) async throws -> UUID {
        writer?.sendMessage(.createSession(shell: shell, cwd: cwd, env: env))

        guard let frame = await reader?.readFrame(),
              frame.type == .sessionCreated,
              let message = try? messageDecoder.decodeServerMessage(type: .sessionCreated, data: frame.payload),
              case let .sessionCreated(sessionID) = message
        else {
            throw RelayError.unexpectedResponse
        }
        return sessionID
    }

    func attachSession(_ sessionID: UUID) async throws -> UInt16 {
        writer?.sendMessage(.attachSession(sessionID: sessionID))

        guard let frame = await reader?.readFrame(),
              frame.type == .attachAck,
              let message = try? messageDecoder.decodeServerMessage(type: .attachAck, data: frame.payload),
              case let .attachAck(_, cols, _) = message
        else {
            throw RelayError.unexpectedResponse
        }
        return cols
    }

    func sendResize(sessionID: UUID, cols: UInt16, rows: UInt16) {
        writer?.sendMessage(.resize(sessionID: sessionID, cols: cols, rows: rows))
    }

    func sendInput(sessionID: UUID, bytes: Data) {
        writer?.sendMessage(.ptyInput(sessionID: sessionID, bytes: bytes))
    }

    func readOutput() async -> Data? {
        guard let frame = await reader?.readFrame() else { return nil }

        switch frame.type {
        case .ptyOutput:
            if let message = try? messageDecoder.decodeServerMessage(type: .ptyOutput, data: frame.payload),
               case let .ptyOutput(_, bytes) = message {
                return bytes
            }
        case .sessionExited:
            return nil
        default:
            break
        }
        return nil
    }

    func detach(sessionID: UUID) {
        writer?.sendMessage(.detach(sessionID: sessionID))
    }

    func disconnect() {
        connection?.cancel()
    }
}

enum RelayError: Error, LocalizedError {
    case authenticationFailed
    case unexpectedResponse
    case connectionFailed

    var errorDescription: String? {
        switch self {
        case .authenticationFailed: "Authentication failed"
        case .unexpectedResponse: "Unexpected response from daemon"
        case .connectionFailed: "Failed to connect to daemon"
        }
    }
}
