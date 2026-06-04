import Foundation
import Testing
@testable import MuxyDaemon

@Suite("PTYSessionRegistry")
struct PTYSessionRegistryTests {

    @Test("create and lookup session by ID")
    func testCreateAndLookup() throws {
        let registry = PTYSessionRegistry()
        let id = UUID()
        let session = try PTYSession(
            id: id,
            shell: "/bin/sleep",
            args: ["10"],
            cwd: "/tmp",
            env: [:],
            cols: 80,
            rows: 24
        )
        defer { session.kill() }

        registry.add(session)
        let found = registry.session(for: id)

        #expect(found?.id == id)
    }

    @Test("remove session and verify nil lookup")
    func testRemoveSession() throws {
        let registry = PTYSessionRegistry()
        let id = UUID()
        let session = try PTYSession(
            id: id,
            shell: "/bin/sleep",
            args: ["10"],
            cwd: "/tmp",
            env: [:],
            cols: 80,
            rows: 24
        )
        defer { session.kill() }

        registry.add(session)
        registry.remove(id)
        let found = registry.session(for: id)

        #expect(found == nil)
    }

    @Test("list all sessions")
    func testListSessions() throws {
        let registry = PTYSessionRegistry()
        let session1 = try PTYSession(
            id: UUID(),
            shell: "/bin/sleep",
            args: ["10"],
            cwd: "/tmp",
            env: [:],
            cols: 80,
            rows: 24
        )
        defer { session1.kill() }

        let session2 = try PTYSession(
            id: UUID(),
            shell: "/bin/sleep",
            args: ["10"],
            cwd: "/tmp",
            env: [:],
            cols: 80,
            rows: 24
        )
        defer { session2.kill() }

        registry.add(session1)
        registry.add(session2)

        #expect(registry.allSessions().count == 2)
    }

    @Test("lookup nonexistent UUID returns nil")
    func testLookupNonexistentReturnsNil() {
        let registry = PTYSessionRegistry()
        let found = registry.session(for: UUID())

        #expect(found == nil)
    }
}
