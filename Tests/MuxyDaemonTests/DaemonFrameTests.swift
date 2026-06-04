import Foundation
import Testing

@testable import MuxyShared

@Suite("DaemonFrame")
struct DaemonFrameTests {

    @Test("encode decode round trip preserves type and payload")
    func encodeDecodeRoundTrip() throws {
        let payload = Data("hello world".utf8)
        let frame = DaemonFrame(type: .authRequest, payload: payload)
        let encoded = try frame.encode()
        let decoded = try DaemonFrame.decode(from: encoded)
        #expect(decoded.type == .authRequest)
        #expect(decoded.payload == payload)
    }

    @Test("empty payload round trip")
    func emptyPayloadRoundTrip() throws {
        let frame = DaemonFrame(type: .ping)
        let encoded = try frame.encode()
        let decoded = try DaemonFrame.decode(from: encoded)
        #expect(decoded.type == .ping)
        #expect(decoded.payload.isEmpty)
    }

    @Test("large payload round trip with 100KB random bytes")
    func largePayloadRoundTrip() throws {
        var rng = SystemRandomNumberGenerator()
        var bytes = [UInt8](repeating: 0, count: 100_000)
        for i in bytes.indices {
            bytes[i] = UInt8.random(in: UInt8.min...UInt8.max, using: &rng)
        }
        let payload = Data(bytes)
        let frame = DaemonFrame(type: .ptyOutput, payload: payload)
        let encoded = try frame.encode()
        let decoded = try DaemonFrame.decode(from: encoded)
        #expect(decoded.type == .ptyOutput)
        #expect(decoded.payload == payload)
    }

    @Test("decode truncated data throws")
    @available(*, deprecated, message: "testing error path")
    func decodeTruncatedDataThrows() throws {
        let frame = DaemonFrame(type: .ptyInput, payload: Data("data".utf8))
        let encoded = try frame.encode()
        let truncated = encoded.dropLast(3)
        #expect(throws: DaemonFrameError.self) {
            try DaemonFrame.decode(from: Data(truncated))
        }
    }

    @Test("decode invalid version throws")
    @available(*, deprecated, message: "testing error path")
    func decodeInvalidVersionThrows() throws {
        let frame = DaemonFrame(type: .ping)
        var encoded = try frame.encode()
        encoded[0] = 99
        #expect(throws: DaemonFrameError.self) {
            try DaemonFrame.decode(from: encoded)
        }
    }
}
