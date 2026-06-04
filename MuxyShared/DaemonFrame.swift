import Foundation

public enum DaemonMessageType: UInt8, Sendable, CaseIterable {
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

public enum DaemonFrameError: Error, LocalizedError, Sendable {
    case truncatedHeader
    case unsupportedVersion(UInt8)
    case unknownMessageType(UInt8)
    case truncatedPayload(expected: Int, actual: Int)

    public var errorDescription: String? {
        switch self {
        case .truncatedHeader:
            "Frame header is too short"
        case let .unsupportedVersion(version):
            "Unsupported protocol version: \(version)"
        case let .unknownMessageType(rawValue):
            "Unknown message type: 0x\(String(format: "%02X", rawValue))"
        case let .truncatedPayload(expected, actual):
            "Payload truncated: expected \(expected) bytes, got \(actual)"
        }
    }
}

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
        var length = UInt32(payload.count).bigEndian
        data.append(Data(bytes: &length, count: 4))
        data.append(payload)
        return data
    }

    private static func readPayloadLength(from data: Data, offset: Int = 0) -> UInt32 {
        data[offset...].withUnsafeBytes { ptr in
            ptr.loadUnaligned(as: UInt32.self).bigEndian
        }
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

        let payloadLength = readPayloadLength(from: data, offset: 2)
        let payloadEnd = headerSize + Int(payloadLength)

        guard data.count >= payloadEnd else {
            throw DaemonFrameError.truncatedPayload(
                expected: Int(payloadLength),
                actual: data.count - headerSize
            )
        }

        return DaemonFrame(type: messageType, payload: Data(data[headerSize ..< payloadEnd]))
    }

    public static func decodeStreaming(from buffer: inout Data) -> DaemonFrame? {
        guard buffer.count >= headerSize else { return nil }

        let payloadLength = readPayloadLength(from: buffer, offset: 2)
        let totalSize = headerSize + Int(payloadLength)

        guard buffer.count >= totalSize else { return nil }

        let version = buffer[0]
        guard version == protocolVersion else { return nil }

        let typeRaw = buffer[1]
        guard let messageType = DaemonMessageType(rawValue: typeRaw) else { return nil }

        let frameData = buffer[0 ..< totalSize]
        buffer.removeSubrange(0 ..< totalSize)

        return DaemonFrame(type: messageType, payload: Data(frameData[headerSize ..< totalSize]))
    }
}
