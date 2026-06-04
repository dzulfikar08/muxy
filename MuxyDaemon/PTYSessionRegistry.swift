import Foundation

final class PTYSessionRegistry: @unchecked Sendable {
    private var sessions: [UUID: PTYSession] = [:]
    private let queue = DispatchQueue(label: "app.muxy.sessionRegistry")

    func add(_ session: PTYSession) {
        queue.sync { sessions[session.id] = session }
    }

    func remove(_ id: UUID) {
        _ = queue.sync { sessions.removeValue(forKey: id) }
    }

    func session(for id: UUID) -> PTYSession? {
        queue.sync { sessions[id] }
    }

    func allSessions() -> [PTYSession] {
        queue.sync { Array(sessions.values) }
    }

    func count() -> Int {
        queue.sync { sessions.count }
    }
}
