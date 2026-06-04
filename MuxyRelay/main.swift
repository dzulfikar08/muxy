import Foundation
import MuxyShared
import os

private let logger = Logger(subsystem: "app.muxy", category: "MuxyRelay")

let args = CommandLine.arguments.dropFirst()
guard let mode = args.first else {
    fputs("Usage: muxy-relay new [--shell SHELL] [--cwd DIR]\n", stderr)
    fputs("       muxy-relay attach <session-id>\n", stderr)
    exit(1)
}

let relay = RelayConnection()

func runNewMode(args: [String]) async throws {
    var shell = "/bin/zsh"
    var cwd = FileManager.default.currentDirectoryPath
    var env: [String: String] = [:]

    var i = args.dropFirst().makeIterator()
    while let arg = i.next() {
        switch arg {
        case "--shell": shell = i.next() ?? shell
        case "--cwd": cwd = i.next() ?? cwd
        case "--env":
            if let pair = i.next(), let eq = pair.firstIndex(of: "=") {
                let key = String(pair[..<eq])
                let value = String(pair[pair.index(after: eq)...])
                env[key] = value
            }
        default: break
        }
    }

    try await relay.connect()
    try await relay.authenticate()
    let sessionID = try await relay.createSession(shell: shell, cwd: cwd, env: env)
    _ = try await relay.attachSession(sessionID)

    if let data = sessionID.uuidString.data(using: .utf8) {
        data.withUnsafeBytes { ptr in
            _ = write(3, ptr.baseAddress, data.count)
        }
    }

    try await relayLoop(sessionID: sessionID)
}

func runAttachMode(args: [String]) async throws {
    guard let sessionIDStr = args.dropFirst().first,
          let sessionID = UUID(uuidString: sessionIDStr)
    else {
        fputs("Error: invalid session ID\n", stderr)
        exit(1)
    }

    try await relay.connect()
    try await relay.authenticate()
    _ = try await relay.attachSession(sessionID)

    try await relayLoop(sessionID: sessionID)
}

func relayLoop(sessionID: UUID) async throws {
    let stdinTask = Task {
        let stdin = FileHandle.standardInput
        while true {
            let data = stdin.availableData
            if data.isEmpty { break }
            relay.sendInput(sessionID: sessionID, bytes: data)
        }
        relay.detach(sessionID: sessionID)
    }

    var ws = winsize()
    _ = ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws)
    let cols = ws.ws_col == 0 ? UInt16(ProcessInfo.processInfo.environment["COLUMNS"].flatMap(UInt16.init) ?? 80) : ws.ws_col
    let rows = ws.ws_row == 0 ? UInt16(ProcessInfo.processInfo.environment["LINES"].flatMap(UInt16.init) ?? 24) : ws.ws_row
    relay.sendResize(sessionID: sessionID, cols: cols, rows: rows)

    let sigwinchSource = DispatchSource.makeSignalSource(signal: SIGWINCH, queue: .main)
    signal(SIGWINCH, SIG_IGN)
    sigwinchSource.setEventHandler {
        var localWs = winsize()
        _ = ioctl(STDOUT_FILENO, TIOCGWINSZ, &localWs)
        relay.sendResize(sessionID: sessionID, cols: localWs.ws_col, rows: localWs.ws_row)
    }
    sigwinchSource.resume()

    let stdout = FileHandle.standardOutput
    while let output = await relay.readOutput() {
        stdout.write(output)
    }

    stdinTask.cancel()
    sigwinchSource.cancel()
    relay.disconnect()
}

Task {
    do {
        switch mode {
        case "new": try await runNewMode(args: Array(args))
        case "attach": try await runAttachMode(args: Array(args))
        default:
            fputs("Unknown mode: \(mode)\n", stderr)
            exit(1)
        }
    } catch {
        fputs("Error: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
    exit(0)
}

RunLoop.main.run()
