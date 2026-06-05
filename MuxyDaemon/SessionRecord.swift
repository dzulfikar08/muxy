import Foundation

struct SessionRecord: Codable {
    let id: UUID
    let shell: String
    let cwd: String
    let env: [String: String]
    let cols: UInt16
    let rows: UInt16
    let childPID: pid_t
    let createdAt: Date
}
