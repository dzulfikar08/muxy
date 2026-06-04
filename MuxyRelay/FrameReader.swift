import Foundation
import Network
import MuxyShared
import os

final class FrameReader: @unchecked Sendable {
    private let connection: NWConnection
    private var buffer = Data()
    private let queue: DispatchQueue

    init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    func readFrame() async -> DaemonFrame? {
        await withCheckedContinuation { continuation in
            receiveNext { frame in
                continuation.resume(returning: frame)
            }
        }
    }

    private func receiveNext(completion: @escaping @Sendable (DaemonFrame?) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] content, _, isComplete, error in
            guard let self else {
                completion(nil)
                return
            }
            if error != nil {
                completion(nil)
                return
            }
            if let content {
                self.buffer.append(content)
            }
            if isComplete {
                completion(nil)
                return
            }
            if let frame = DaemonFrame.decodeStreaming(from: &self.buffer) {
                completion(frame)
            } else {
                self.receiveNext(completion: completion)
            }
        }
    }
}
