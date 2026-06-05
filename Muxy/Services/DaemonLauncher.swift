import Foundation
import os

private let logger = Logger(subsystem: "app.muxy", category: "DaemonLauncher")

@MainActor
final class DaemonLauncher {
    static let shared = DaemonLauncher()

    private var daemonProcess: Process?

    private init() {}

    var socketPath: String {
        "\(NSHomeDirectory())/.muxy/daemon.sock"
    }

    func isDaemonRunning() -> Bool {
        FileManager.default.fileExists(atPath: socketPath)
    }

    func launchIfNeeded() {
        guard !isDaemonRunning() else {
            logger.info("Daemon already running")
            return
        }
        launch()
    }

    private func launch() {
        guard let daemonURL = Bundle.main.url(forAuxiliaryExecutable: "muxyd") else {
            logger.error("muxyd not found in app bundle")
            return
        }

        let process = Process()
        process.executableURL = daemonURL
        process.arguments = []

        do {
            try process.run()
            daemonProcess = process
            logger.info("Launched muxyd from app bundle")
        } catch {
            logger.error("Failed to launch muxyd: \(error)")
        }
    }

    func stopDaemon() {
        daemonProcess?.terminate()
        daemonProcess = nil
        logger.info("Stopped muxyd")
    }
}
