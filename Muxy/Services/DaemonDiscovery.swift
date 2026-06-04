import Foundation
import Network
import os

private let logger = Logger(subsystem: "app.muxy", category: "DaemonDiscovery")

struct DiscoveredDaemon: Equatable {
    let name: String
    let host: String
    let port: UInt16
}

@MainActor
@Observable
final class DaemonDiscovery {
    private var browser: NWBrowser?
    let socketPath: String

    private(set) var discoveredDaemons: [DiscoveredDaemon] = []

    var isLocalDaemonRunning: Bool {
        FileManager.default.fileExists(atPath: socketPath)
    }

    init(socketPath: String = "\(NSHomeDirectory())/.muxy/daemon.sock") {
        self.socketPath = socketPath
    }

    func startBrowsing() {
        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        let descriptor = NWBrowser.Descriptor.bonjour(type: "_muxyd._tcp", domain: "local")
        let browser = NWBrowser(for: descriptor, using: parameters)
        browser.stateUpdateHandler = { (state: NWBrowser.State) in
            switch state {
            case .ready:
                logger.info("Bonjour browsing started")
            case let .failed(error):
                logger.error("Bonjour browsing failed: \(error)")
            default:
                break
            }
        }
        browser.browseResultsChangedHandler = { [weak self] (results: Set<NWBrowser.Result>, _) in
            Task { @MainActor in
                self?.discoveredDaemons = results.compactMap { result in
                    Self.extractDaemonInfo(from: result)
                }
            }
        }
        let mainQueue = DispatchQueue.main
        browser.start(queue: mainQueue)
        self.browser = browser
    }

    func stopBrowsing() {
        browser?.cancel()
        browser = nil
    }

    private static func extractDaemonInfo(from result: NWBrowser.Result) -> DiscoveredDaemon? {
        guard case let .service(name, type, domain, _) = result.endpoint else { return nil }
        let host = name.isEmpty ? "\(type).\(domain)" : name
        return DiscoveredDaemon(name: name, host: host, port: 4866)
    }
}
