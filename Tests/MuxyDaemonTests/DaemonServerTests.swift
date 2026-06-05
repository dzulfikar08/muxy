import Foundation
import Testing
@testable import MuxyDaemon

@Suite("DaemonServer")
struct DaemonServerTests {

    @Test("server starts and stops cleanly")
    func testServerStartsAndStops() async throws {
        let config = DaemonConfig(
            unixSocketPath: "/tmp/muxy-test-\(UUID().uuidString).sock",
            tcpPort: 0,
            scrollbackSize: 1024,
            authStorePath: "/tmp/muxy-test-devices.json",
            sessionRegistryPath: "/tmp/muxy-test-sessions.json",
            bonjourServiceType: "_test._tcp"
        )

        let server = DaemonServer(config: config)
        try server.start()
        try await Task.sleep(nanoseconds: 500_000_000)
        server.stop()
    }

    @Test("server persists sessions to disk on start and stop")
    func testServerPersistsSessions() async throws {
        let sessionPath = "/tmp/muxy-test-sessions-\(UUID().uuidString).json"
        defer { try? FileManager.default.removeItem(atPath: sessionPath) }

        let config = DaemonConfig(
            unixSocketPath: "/tmp/muxy-test-\(UUID().uuidString).sock",
            tcpPort: 0,
            scrollbackSize: 1024,
            authStorePath: "/tmp/muxy-test-devices-\(UUID().uuidString).json",
            sessionRegistryPath: sessionPath,
            bonjourServiceType: "_test._tcp"
        )

        let store = SessionStore(filePath: sessionPath)
        let server = DaemonServer(config: config, sessionStore: store)
        try server.start()
        server.stop()

        let records = store.load()
        #expect(records.isEmpty)
    }

    @Test("restore prunes dead sessions from previous run")
    func testRestorePrunesDeadSessions() async throws {
        let sessionPath = "/tmp/muxy-test-sessions-restore-\(UUID().uuidString).json"
        defer { try? FileManager.default.removeItem(atPath: sessionPath) }

        let store = SessionStore(filePath: sessionPath)

        let records = [
            SessionRecord(
                id: UUID(),
                shell: "/bin/zsh",
                cwd: "/home",
                env: [:],
                cols: 80,
                rows: 24,
                childPID: 99_999_999,
                createdAt: Date()
            )
        ]
        store.save(records)

        let config = DaemonConfig(
            unixSocketPath: "/tmp/muxy-test-\(UUID().uuidString).sock",
            tcpPort: 0,
            scrollbackSize: 1024,
            authStorePath: "/tmp/muxy-test-devices-\(UUID().uuidString).json",
            sessionRegistryPath: sessionPath,
            bonjourServiceType: "_test._tcp"
        )

        let server = DaemonServer(config: config, sessionStore: store)
        try server.start()
        server.stop()

        let remaining = store.load()
        #expect(remaining.isEmpty)
    }
}
