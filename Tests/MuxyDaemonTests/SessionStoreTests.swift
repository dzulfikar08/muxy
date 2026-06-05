import Foundation
import Testing
@testable import MuxyDaemon

@Suite("SessionStore")
struct SessionStoreTests {

    @Test("save and load round trip")
    func testSaveAndLoadRoundTrip() throws {
        let path = "/tmp/muxy-test-session-store-\(UUID().uuidString).json"
        defer { try? FileManager.default.removeItem(atPath: path) }

        let store = SessionStore(filePath: path)
        let records = [
            SessionRecord(
                id: UUID(),
                shell: "/bin/zsh",
                cwd: "/Users/test",
                env: ["TERM": "xterm-256color"],
                cols: 80,
                rows: 24,
                childPID: 12345,
                createdAt: Date()
            ),
            SessionRecord(
                id: UUID(),
                shell: "/bin/bash",
                cwd: "/tmp",
                env: ["LANG": "en_US.UTF-8"],
                cols: 120,
                rows: 40,
                childPID: 12346,
                createdAt: Date()
            )
        ]

        store.save(records)
        let loaded = store.load()

        #expect(loaded.count == 2)
        #expect(loaded[0].shell == "/bin/zsh")
        #expect(loaded[0].cwd == "/Users/test")
        #expect(loaded[0].cols == 80)
        #expect(loaded[0].childPID == 12345)
        #expect(loaded[1].shell == "/bin/bash")
        #expect(loaded[1].cwd == "/tmp")
        #expect(loaded[1].env["LANG"] == "en_US.UTF-8")
    }

    @Test("load returns empty when no file exists")
    func testLoadReturnsEmptyWhenNoFile() {
        let path = "/tmp/muxy-test-session-store-nonexistent-\(UUID().uuidString).json"
        let store = SessionStore(filePath: path)
        let loaded = store.load()

        #expect(loaded.isEmpty)
    }

    @Test("load returns empty when file contains invalid JSON")
    func testLoadReturnsEmptyForInvalidJSON() throws {
        let path = "/tmp/muxy-test-session-store-invalid-\(UUID().uuidString).json"
        defer { try? FileManager.default.removeItem(atPath: path) }

        try Data("not json".utf8).write(to: URL(fileURLWithPath: path))

        let store = SessionStore(filePath: path)
        let loaded = store.load()

        #expect(loaded.isEmpty)
    }

    @Test("save overwrites previous records")
    func testSaveOverwrites() throws {
        let path = "/tmp/muxy-test-session-store-overwrite-\(UUID().uuidString).json"
        defer { try? FileManager.default.removeItem(atPath: path) }

        let store = SessionStore(filePath: path)

        let first = [
            SessionRecord(
                id: UUID(),
                shell: "/bin/zsh",
                cwd: "/home",
                env: [:],
                cols: 80,
                rows: 24,
                childPID: 1,
                createdAt: Date()
            )
        ]
        store.save(first)
        #expect(store.load().count == 1)

        let second = [
            SessionRecord(
                id: UUID(),
                shell: "/bin/bash",
                cwd: "/tmp",
                env: [:],
                cols: 100,
                rows: 30,
                childPID: 2,
                createdAt: Date()
            ),
            SessionRecord(
                id: UUID(),
                shell: "/bin/sh",
                cwd: "/var",
                env: [:],
                cols: 120,
                rows: 50,
                childPID: 3,
                createdAt: Date()
            )
        ]
        store.save(second)
        let loaded = store.load()

        #expect(loaded.count == 2)
        #expect(loaded[0].shell == "/bin/bash")
        #expect(loaded[1].shell == "/bin/sh")
    }

    @Test("delete removes the file")
    func testDeleteRemovesFile() throws {
        let path = "/tmp/muxy-test-session-store-delete-\(UUID().uuidString).json"
        defer { try? FileManager.default.removeItem(atPath: path) }

        let store = SessionStore(filePath: path)

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
            )
        ]
        store.save(records)
        #expect(store.load().count == 1)

        store.delete()
        #expect(store.load().isEmpty)
    }
}
