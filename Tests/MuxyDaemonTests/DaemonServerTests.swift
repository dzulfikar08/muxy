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
}
