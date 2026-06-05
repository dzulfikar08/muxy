import Foundation
import os

private let logger = Logger(subsystem: "app.muxy", category: "SessionStore")

public final class SessionStore: @unchecked Sendable {
    private let filePath: String
    private let queue = DispatchQueue(label: "app.muxy.sessionStore")

    public init(filePath: String) {
        self.filePath = filePath
    }

    func save(_ records: [SessionRecord]) {
        queue.sync {
            do {
                let data = try JSONEncoder().encode(records)
                try data.write(to: URL(fileURLWithPath: filePath), options: .atomic)
            } catch {
                logger.error("Failed to save session records: \(error)")
            }
        }
    }

    func load() -> [SessionRecord] {
        queue.sync {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: filePath)) else {
                return []
            }
            return (try? JSONDecoder().decode([SessionRecord].self, from: data)) ?? []
        }
    }

    func delete() {
        queue.sync {
            try? FileManager.default.removeItem(atPath: filePath)
        }
    }
}
