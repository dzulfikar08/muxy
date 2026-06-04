import Foundation
import MuxyDaemon
import os

let logger = Logger(subsystem: "app.muxy", category: "Daemon")

func waitForShutdownSignal() async {
    await withCheckedContinuation { continuation in
        let termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        signal(SIGTERM, SIG_IGN)
        termSource.setEventHandler {
            logger.info("Received SIGTERM, shutting down")
            continuation.resume()
            termSource.cancel()
        }
        termSource.resume()

        let intSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        signal(SIGINT, SIG_IGN)
        intSource.setEventHandler {
            logger.info("Received SIGINT, shutting down")
            continuation.resume()
            intSource.cancel()
        }
        intSource.resume()
    }
}

logger.info("muxyd starting")

let config = DaemonConfig.default
do {
    try config.ensureDirectories()
} catch {
    logger.error("Failed to create daemon directories: \(error)")
    Foundation.exit(1)
}

Task {
    await waitForShutdownSignal()
    logger.info("muxyd stopped")
    Foundation.exit(0)
}

RunLoop.main.run()
