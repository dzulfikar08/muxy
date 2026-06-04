import Foundation

public struct DaemonConfig: Sendable {
    public let unixSocketPath: String
    public let tcpPort: UInt16
    public let scrollbackSize: Int
    public let authStorePath: String
    public let sessionRegistryPath: String
    public let bonjourServiceType: String

    public static let `default` = DaemonConfig(
        unixSocketPath: "\(NSHomeDirectory())/.muxy/daemon.sock",
        tcpPort: 4866,
        scrollbackSize: 10 * 1024,
        authStorePath: "\(NSHomeDirectory())/.muxy/daemon/devices.json",
        sessionRegistryPath: "\(NSHomeDirectory())/.muxy/daemon/sessions.json",
        bonjourServiceType: "_muxyd._tcp"
    )

    public var daemonDirectory: String {
        "\(NSHomeDirectory())/.muxy/daemon"
    }

    public func ensureDirectories() throws {
        try FileManager.default.createDirectory(
            atPath: daemonDirectory,
            withIntermediateDirectories: true
        )
    }
}
