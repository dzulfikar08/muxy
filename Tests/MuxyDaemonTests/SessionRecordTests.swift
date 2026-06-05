import Foundation
import Testing
@testable import MuxyDaemon

@Suite("SessionRecord")
struct SessionRecordTests {

    @Test("encode and decode round trip")
    func testEncodeDecodeRoundTrip() throws {
        let record = SessionRecord(
            id: UUID(),
            shell: "/bin/zsh",
            cwd: "/Users/test",
            env: ["TERM": "xterm-256color", "HOME": "/Users/test"],
            cols: 80,
            rows: 24,
            childPID: 12345,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        let data = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(SessionRecord.self, from: data)

        #expect(decoded.id == record.id)
        #expect(decoded.shell == record.shell)
        #expect(decoded.cwd == record.cwd)
        #expect(decoded.env == record.env)
        #expect(decoded.cols == record.cols)
        #expect(decoded.rows == record.rows)
        #expect(decoded.childPID == record.childPID)
        #expect(decoded.createdAt == record.createdAt)
    }

    @Test("decode array of records")
    func testDecodeArrayOfRecords() throws {
        let records = [
            SessionRecord(
                id: UUID(),
                shell: "/bin/zsh",
                cwd: "/home",
                env: [:],
                cols: 80,
                rows: 24,
                childPID: 1,
                createdAt: Date()
            ),
            SessionRecord(
                id: UUID(),
                shell: "/bin/bash",
                cwd: "/tmp",
                env: ["X": "Y"],
                cols: 120,
                rows: 40,
                childPID: 2,
                createdAt: Date()
            )
        ]

        let data = try JSONEncoder().encode(records)
        let decoded = try JSONDecoder().decode([SessionRecord].self, from: data)

        #expect(decoded.count == 2)
        #expect(decoded[0].childPID == 1)
        #expect(decoded[1].childPID == 2)
    }
}
