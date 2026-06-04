import Foundation
import Network
import MuxyShared
import os

final class FrameWriter: @unchecked Sendable {
    private let connection: NWConnection
    private let queue: DispatchQueue

    init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    func send(_ frame: DaemonFrame) {
        guard let data = try? frame.encode() else { return }
        connection.send(content: data, completion: .contentProcessed { error in
            if let error {
                Logger(subsystem: "app.muxy", category: "FrameWriter").error("Send error: \(error)")
            }
        })
    }

    func sendMessage(_ message: DaemonClientMessage) {
        guard let payload = try? message.encode() else { return }
        let frame = DaemonFrame(type: message.messageType, payload: payload)
        send(frame)
    }
}
