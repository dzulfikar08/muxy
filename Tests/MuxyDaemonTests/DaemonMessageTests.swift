import Foundation
import Testing
@testable import MuxyShared

private func wholeSecondDate(timeIntervalSince1970: TimeInterval = 1_700_000_000) -> Date {
    Date(timeIntervalSince1970: timeIntervalSince1970)
}

@Suite("DaemonMessage")
struct DaemonMessageTests {
    private let decoder = DaemonMessageDecoder()

    @Test("client message round trips")
    func testClientMessageRoundTrips() throws {
        let messages: [DaemonClientMessage] = [
            .authRequest(deviceID: UUID(), token: Data("secret-token".utf8)),
            .listSessions,
            .createSession(shell: "/bin/zsh", cwd: "/home/user", env: ["TERM": "xterm-256color", "LANG": "en_US.UTF-8"]),
            .attachSession(sessionID: UUID()),
            .detach(sessionID: UUID()),
            .ptyInput(sessionID: UUID(), bytes: Data("ls -la\r".utf8)),
            .resize(sessionID: UUID(), cols: 120, rows: 40),
            .killSession(sessionID: UUID()),
            .ping,
        ]

        for message in messages {
            let data = try message.encode()
            let decoded = try decoder.decodeClientMessage(type: message.messageType, data: data)
            #expect(decoded == message)
        }
    }

    @Test("server message round trips")
    func testServerMessageRoundTrips() throws {
        let sessionID = UUID()
        let clientID = UUID()
        let sessions: [SessionInfo] = [
            .init(id: UUID(), shell: "/bin/zsh", cwd: "/home/user", cols: 80, rows: 24, attachedClients: 1, createdAt: wholeSecondDate()),
            .init(id: UUID(), shell: "/bin/bash", cwd: "/tmp", cols: 120, rows: 40, attachedClients: 0, createdAt: wholeSecondDate(timeIntervalSince1970: 1_700_000_100)),
        ]

        let messages: [DaemonServerMessage] = [
            .authResponse(success: true),
            .authResponse(success: false),
            .sessionList(sessions: sessions),
            .sessionCreated(sessionID: sessionID),
            .attachAck(sessionID: sessionID, cols: 120, rows: 40),
            .detachAck(sessionID: sessionID),
            .ptyOutput(sessionID: sessionID, bytes: Data("total 42\r\n".utf8)),
            .sessionExited(sessionID: sessionID, exitCode: 0),
            .sessionExited(sessionID: sessionID, exitCode: -1),
            .clientConnected(sessionID: sessionID, clientID: clientID),
            .clientDisconnected(sessionID: sessionID, clientID: clientID),
            .pong,
            .resizeRequired(cols: 200, rows: 60),
        ]

        for message in messages {
            let data = try message.encode()
            let decoded = try decoder.decodeServerMessage(type: message.messageType, data: data)
            #expect(decoded == message)
        }
    }
}
