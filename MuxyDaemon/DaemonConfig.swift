import Foundation

struct DaemonConfig: Sendable {
    let unixSocketPath: String
    let tcpPort: UInt16
    let scrollbackSize: Int
    let authStorePath: String
    let sessionRegistryPath: String
    let bonjourServiceType: String

    static let `default` = DaemonConfig(
        unixSocketPath: "\(NSHomeDirectory())/.muxy/daemon.sock",
        tcpPort: 4866,
        scrollbackSize: 10 * 1024,
        authStorePath: "\(NSHomeDirectory())/.muxy/daemon/devices.json",
        sessionRegistryPath: "\(NSHomeDirectory())/.muxy/daemon/sessions.json",
        bonjourServiceType: "_muxyd._tcp"
    )

    var daemonDirectory: String {
        "\(NSHomeDirectory())/.muxy/daemon"
    }

    func ensureDirectories() throws {
        try FileManager.default.createDirectory(
            atPath: daemonDirectory,
            withIntermediateDirectories: true
        )
    }
}
