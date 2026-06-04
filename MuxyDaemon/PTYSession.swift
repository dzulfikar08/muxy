import Foundation
import os

private let logger = Logger(subsystem: "app.muxy", category: "PTYSession")

private func makeWinsize(cols: UInt16, rows: UInt16) -> Darwin.winsize {
    Darwin.winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
}

private func isExited(_ status: Int32) -> Bool {
    (status & 0x7F) == 0
}

private func exitStatus(_ status: Int32) -> Int32 {
    (status >> 8) & 0xFF
}

final class PTYSession: @unchecked Sendable {
    let id: UUID
    let shell: String
    let cwd: String
    let env: [String: String]
    private(set) var cols: UInt16
    private(set) var rows: UInt16
    private(set) var exitCode: Int32?

    private var masterFD: Int32
    private var childPID: pid_t

    init(id: UUID, shell: String, args: [String] = [], cwd: String, env: [String: String], cols: UInt16, rows: UInt16) throws {
        self.id = id
        self.shell = shell
        self.cwd = cwd
        self.env = env
        self.cols = cols
        self.rows = rows

        var masterFD: Int32 = 0
        var ws = makeWinsize(cols: cols, rows: rows)
        let childPID = forkpty(&masterFD, nil, nil, &ws)

        guard childPID >= 0 else {
            throw PTYSessionError.forkFailed(errno: Int(errno))
        }

        if childPID == 0 {
            setenv("TERM", "xterm-256color", 1)
            for (key, value) in env {
                setenv(key, value, 1)
            }
            if chdir(cwd) != 0 {
                _exit(1)
            }
            let allArgs = [shell] + args
            let argvPointers = allArgs.map { arg -> UnsafeMutablePointer<CChar>? in
                strdup(arg)
            }
            var argv = argvPointers + [nil]

            argv.withUnsafeMutableBufferPointer { argvBuf in
                guard let argvBase = argvBuf.baseAddress else { return }
                shell.withCString { shellCStr in
                    _ = execv(shellCStr, argvBase)
                }
            }
            _exit(1)
        }

        self.masterFD = masterFD
        self.childPID = childPID
    }

    deinit {
        if masterFD >= 0 { close(masterFD) }
    }

    func write(_ data: Data) throws {
        let result = data.withUnsafeBytes { ptr in
            Darwin.write(masterFD, ptr.baseAddress, ptr.count)
        }
        guard result >= 0 else {
            throw PTYSessionError.writeFailed(errno: Int(errno))
        }
    }

    func readOutput(maxBytes: Int = 65536, timeoutMs: Int = 100) throws -> Data {
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: min(maxBytes, 65536))

        var pollFD = pollfd(fd: masterFD, events: Int16(POLLIN), revents: 0)
        let pollResult = poll(&pollFD, 1, Int32(timeoutMs))
        guard pollResult > 0 else { return result }

        let bytesRead = Darwin.read(masterFD, &buffer, buffer.count)
        if bytesRead > 0 {
            result.append(contentsOf: buffer[..<bytesRead])
        }
        return result
    }

    func resize(cols: UInt16, rows: UInt16) throws {
        self.cols = cols
        self.rows = rows
        var ws = makeWinsize(cols: cols, rows: rows)
        let result = ioctl(masterFD, TIOCSWINSZ, &ws)
        guard result >= 0 else {
            throw PTYSessionError.resizeFailed(errno: Int(errno))
        }
    }

    func kill() {
        if childPID > 0 { Darwin.kill(childPID, SIGTERM) }
        if masterFD >= 0 {
            close(masterFD)
            masterFD = -1
        }
    }

    func waitForExit(timeoutMs: Int) async throws -> Bool {
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000.0)
        while Date() < deadline {
            var status: Int32 = 0
            let result = waitpid(childPID, &status, WNOHANG)
            if result == childPID {
                exitCode = isExited(status) ? exitStatus(status) : -1
                return true
            }
            if result < 0 { return false }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        return false
    }
}

enum PTYSessionError: Error, LocalizedError {
    case forkFailed(errno: Int)
    case writeFailed(errno: Int)
    case resizeFailed(errno: Int)

    var errorDescription: String? {
        switch self {
        case let .forkFailed(errno): "forkpty failed: errno \(errno)"
        case let .writeFailed(errno): "write to PTY failed: errno \(errno)"
        case let .resizeFailed(errno): "resize PTY failed: errno \(errno)"
        }
    }
}
