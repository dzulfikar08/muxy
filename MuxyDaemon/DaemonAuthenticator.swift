import Foundation

enum AuthResult: Sendable, Equatable {
    case approved
    case denied
    case banned
}

final class DaemonAuthenticator: @unchecked Sendable {
    private let maxFailures = 3
    private var failedAttempts: [String: Int] = [:]
    private let queue = DispatchQueue(label: "app.muxy.auth")

    func authenticateUnixSocket(uid: uid_t) -> Bool {
        uid == getuid()
    }

    func authenticateTCP(deviceID: UUID, token: Data, sourceIP: String = "") -> AuthResult {
        let preCheck: AuthResult? = queue.sync {
            if let attempts = failedAttempts[sourceIP], attempts >= maxFailures {
                return .banned
            }
            return nil
        }
        if let preCheck {
            return preCheck
        }
        let approved = validateToken(deviceID: deviceID, token: token)
        if !approved && !sourceIP.isEmpty {
            queue.sync {
                failedAttempts[sourceIP, default: 0] += 1
            }
        }
        return approved ? .approved : .denied
    }

    func isBanned(ip: String) -> Bool {
        queue.sync {
            (failedAttempts[ip] ?? 0) >= maxFailures
        }
    }

    private func validateToken(deviceID: UUID, token: Data) -> Bool {
        false
    }
}
