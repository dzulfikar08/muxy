import Foundation

final class ScrollbackBuffer: @unchecked Sendable {
    private let maxSize: Int
    private var buffer = Data()
    private let lock = NSLock()

    init(maxSize: Int) {
        self.maxSize = maxSize
    }

    func append(_ data: Data) {
        lock.withLock {
            buffer.append(data)
            if buffer.count > maxSize {
                buffer = Data(buffer[(buffer.count - maxSize)...])
            }
        }
    }

    func read() -> Data {
        lock.withLock { buffer }
    }

    func clear() {
        lock.withLock { buffer.removeAll(keepingCapacity: true) }
    }
}
