import Foundation

public struct SessionInfo: Codable, Sendable, Equatable {
    let id: UUID
    let shell: String
    let cwd: String
    let cols: UInt16
    let rows: UInt16
    let attachedClients: Int
    let createdAt: Date
}

public enum DaemonMessageDecodeError: Error, Sendable, Equatable {
    case typeMismatch(expected: String, got: DaemonMessageType)
}

public enum DaemonClientMessage: Equatable, Sendable {
    case authRequest(deviceID: UUID, token: Data)
    case listSessions
    case createSession(shell: String, cwd: String, env: [String: String])
    case attachSession(sessionID: UUID)
    case detach(sessionID: UUID)
    case ptyInput(sessionID: UUID, bytes: Data)
    case resize(sessionID: UUID, cols: UInt16, rows: UInt16)
    case killSession(sessionID: UUID)
    case ping

    var messageType: DaemonMessageType {
        switch self {
        case .authRequest: .authRequest
        case .listSessions: .listSessions
        case .createSession: .createSession
        case .attachSession: .attachSession
        case .detach: .detach
        case .ptyInput: .ptyInput
        case .resize: .resize
        case .killSession: .killSession
        case .ping: .ping
        }
    }

    func encode() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .sortedKeys

        let payload: Encodable = switch self {
        case let .authRequest(deviceID, token):
            AuthRequestPayload(deviceID: deviceID, token: token.base64EncodedString())
        case .listSessions:
            EmptyPayload()
        case let .createSession(shell, cwd, env):
            CreateSessionPayload(shell: shell, cwd: cwd, env: env)
        case let .attachSession(sessionID):
            SessionIDPayload(sessionID: sessionID)
        case let .detach(sessionID):
            SessionIDPayload(sessionID: sessionID)
        case let .ptyInput(sessionID, bytes):
            PtyInputPayload(sessionID: sessionID, data: bytes.base64EncodedString())
        case let .resize(sessionID, cols, rows):
            ResizePayload(sessionID: sessionID, cols: cols, rows: rows)
        case let .killSession(sessionID):
            SessionIDPayload(sessionID: sessionID)
        case .ping:
            EmptyPayload()
        }

        return try encoder.encode(payload)
    }
}

public enum DaemonServerMessage: Equatable, Sendable {
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

    var messageType: DaemonMessageType {
        switch self {
        case .authResponse: .authResponse
        case .sessionList: .sessionList
        case .sessionCreated: .sessionCreated
        case .attachAck: .attachAck
        case .detachAck: .detachAck
        case .ptyOutput: .ptyOutput
        case .sessionExited: .sessionExited
        case .clientConnected: .clientConnected
        case .clientDisconnected: .clientDisconnected
        case .pong: .pong
        case .resizeRequired: .resizeRequired
        }
    }

    func encode() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .sortedKeys

        let payload: Encodable = switch self {
        case let .authResponse(success):
            AuthResponsePayload(success: success)
        case let .sessionList(sessions):
            SessionListPayload(sessions: sessions)
        case let .sessionCreated(sessionID):
            SessionIDPayload(sessionID: sessionID)
        case let .attachAck(sessionID, cols, rows):
            AttachAckPayload(sessionID: sessionID, cols: cols, rows: rows)
        case let .detachAck(sessionID):
            SessionIDPayload(sessionID: sessionID)
        case let .ptyOutput(sessionID, bytes):
            PtyOutputPayload(sessionID: sessionID, data: bytes.base64EncodedString())
        case let .sessionExited(sessionID, exitCode):
            SessionExitedPayload(sessionID: sessionID, exitCode: exitCode)
        case let .clientConnected(sessionID, clientID):
            ClientEventPayload(sessionID: sessionID, clientID: clientID)
        case let .clientDisconnected(sessionID, clientID):
            ClientEventPayload(sessionID: sessionID, clientID: clientID)
        case .pong:
            EmptyPayload()
        case let .resizeRequired(cols, rows):
            ResizeRequiredPayload(cols: cols, rows: rows)
        }

        return try encoder.encode(payload)
    }
}

public final class DaemonMessageDecoder: Sendable {
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    func decodeClientMessage(type: DaemonMessageType, data: Data) throws -> DaemonClientMessage {
        switch type {
        case .authRequest:
            let payload = try decoder.decode(AuthRequestPayload.self, from: data)
            guard let tokenData = Data(base64Encoded: payload.token) else {
                throw DaemonMessageDecodeError.typeMismatch(expected: "authRequest", got: type)
            }
            return .authRequest(deviceID: payload.deviceID, token: tokenData)
        case .listSessions:
            return .listSessions
        case .createSession:
            let payload = try decoder.decode(CreateSessionPayload.self, from: data)
            return .createSession(shell: payload.shell, cwd: payload.cwd, env: payload.env)
        case .attachSession:
            let payload = try decoder.decode(SessionIDPayload.self, from: data)
            return .attachSession(sessionID: payload.sessionID)
        case .detach:
            let payload = try decoder.decode(SessionIDPayload.self, from: data)
            return .detach(sessionID: payload.sessionID)
        case .ptyInput:
            let payload = try decoder.decode(PtyInputPayload.self, from: data)
            guard let bytes = Data(base64Encoded: payload.data) else {
                throw DaemonMessageDecodeError.typeMismatch(expected: "ptyInput", got: type)
            }
            return .ptyInput(sessionID: payload.sessionID, bytes: bytes)
        case .resize:
            let payload = try decoder.decode(ResizePayload.self, from: data)
            return .resize(sessionID: payload.sessionID, cols: payload.cols, rows: payload.rows)
        case .killSession:
            let payload = try decoder.decode(SessionIDPayload.self, from: data)
            return .killSession(sessionID: payload.sessionID)
        case .ping:
            return .ping
        default:
            throw DaemonMessageDecodeError.typeMismatch(expected: "client message", got: type)
        }
    }

    func decodeServerMessage(type: DaemonMessageType, data: Data) throws -> DaemonServerMessage {
        switch type {
        case .authResponse:
            let payload = try decoder.decode(AuthResponsePayload.self, from: data)
            return .authResponse(success: payload.success)
        case .sessionList:
            let payload = try decoder.decode(SessionListPayload.self, from: data)
            return .sessionList(sessions: payload.sessions)
        case .sessionCreated:
            let payload = try decoder.decode(SessionIDPayload.self, from: data)
            return .sessionCreated(sessionID: payload.sessionID)
        case .attachAck:
            let payload = try decoder.decode(AttachAckPayload.self, from: data)
            return .attachAck(sessionID: payload.sessionID, cols: payload.cols, rows: payload.rows)
        case .detachAck:
            let payload = try decoder.decode(SessionIDPayload.self, from: data)
            return .detachAck(sessionID: payload.sessionID)
        case .ptyOutput:
            let payload = try decoder.decode(PtyOutputPayload.self, from: data)
            guard let bytes = Data(base64Encoded: payload.data) else {
                throw DaemonMessageDecodeError.typeMismatch(expected: "ptyOutput", got: type)
            }
            return .ptyOutput(sessionID: payload.sessionID, bytes: bytes)
        case .sessionExited:
            let payload = try decoder.decode(SessionExitedPayload.self, from: data)
            return .sessionExited(sessionID: payload.sessionID, exitCode: payload.exitCode)
        case .clientConnected:
            let payload = try decoder.decode(ClientEventPayload.self, from: data)
            return .clientConnected(sessionID: payload.sessionID, clientID: payload.clientID)
        case .clientDisconnected:
            let payload = try decoder.decode(ClientEventPayload.self, from: data)
            return .clientDisconnected(sessionID: payload.sessionID, clientID: payload.clientID)
        case .pong:
            return .pong
        case .resizeRequired:
            let payload = try decoder.decode(ResizeRequiredPayload.self, from: data)
            return .resizeRequired(cols: payload.cols, rows: payload.rows)
        default:
            throw DaemonMessageDecodeError.typeMismatch(expected: "server message", got: type)
        }
    }
}

private struct EmptyPayload: Codable {}

private struct AuthRequestPayload: Codable {
    let deviceID: UUID
    let token: String
}

private struct AuthResponsePayload: Codable {
    let success: Bool
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
    let data: String
}

private struct PtyOutputPayload: Codable {
    let sessionID: UUID
    let data: String
}

private struct ResizePayload: Codable {
    let sessionID: UUID
    let cols: UInt16
    let rows: UInt16
}

private struct SessionListPayload: Codable {
    let sessions: [SessionInfo]
}

private struct AttachAckPayload: Codable {
    let sessionID: UUID
    let cols: UInt16
    let rows: UInt16
}

private struct SessionExitedPayload: Codable {
    let sessionID: UUID
    let exitCode: Int32
}

private struct ClientEventPayload: Codable {
    let sessionID: UUID
    let clientID: UUID
}

private struct ResizeRequiredPayload: Codable {
    let cols: UInt16
    let rows: UInt16
}
