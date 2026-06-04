import Foundation
import Testing
@testable import MuxyDaemon

@Suite("PTYSession", .serialized)
struct PTYSessionTests {
    @Test("create session and read output")
    func testCreateSessionOutputsData() async throws {
        let session = try PTYSession(
            id: UUID(),
            shell: "/bin/sleep",
            args: ["5"],
            cwd: "/tmp",
            env: [:],
            cols: 80,
            rows: 24
        )

        defer { session.kill() }

        try await Task.sleep(nanoseconds: 200_000_000)

        let readResult = try session.readOutput(maxBytes: 4096, timeoutMs: 200)
        #expect(readResult.isEmpty)

        try session.write(Data("hello\n".utf8))

        var output = Data()
        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline {
            let chunk = try session.readOutput(maxBytes: 4096, timeoutMs: 100)
            if !chunk.isEmpty {
                output.append(chunk)
            }
            if let result = String(data: output, encoding: .utf8),
               result.contains("hello")
            {
                break
            }
        }

        let result = String(data: output, encoding: .utf8) ?? ""
        #expect(result.contains("hello"))
    }

    @Test("write input echoes via cat")
    func testWriteInput() async throws {
        let session = try PTYSession(
            id: UUID(),
            shell: "/bin/cat",
            args: [],
            cwd: "/tmp",
            env: [:],
            cols: 80,
            rows: 24
        )

        defer { session.kill() }

        try await Task.sleep(nanoseconds: 200_000_000)
        try session.write(Data("test-input\n".utf8))

        var output = Data()
        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline {
            let chunk = try session.readOutput(maxBytes: 4096, timeoutMs: 100)
            if !chunk.isEmpty {
                output.append(chunk)
            }
            let result = String(data: output, encoding: .utf8) ?? ""
            if result.contains("test-input") {
                break
            }
        }

        let result = String(data: output, encoding: .utf8) ?? ""
        #expect(result.contains("test-input"))
    }

    @Test("resize does not throw")
    func testResize() throws {
        let session = try PTYSession(
            id: UUID(),
            shell: "/bin/sleep",
            args: ["10"],
            cwd: "/tmp",
            env: [:],
            cols: 80,
            rows: 24
        )

        defer { session.kill() }

        try session.resize(cols: 120, rows: 40)
        #expect(session.cols == 120)
        #expect(session.rows == 40)
    }

    @Test("session exits cleanly")
    func testSessionExits() async throws {
        let session = try PTYSession(
            id: UUID(),
            shell: "/bin/sleep",
            args: ["0.1"],
            cwd: "/tmp",
            env: [:],
            cols: 80,
            rows: 24
        )

        let exited = try await session.waitForExit(timeoutMs: 5000)
        #expect(exited)
        #expect(session.exitCode == 0)
    }
}
