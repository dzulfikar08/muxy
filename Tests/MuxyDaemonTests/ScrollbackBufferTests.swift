import Foundation
import Testing
@testable import MuxyDaemon

@Suite("ScrollbackBuffer")
struct ScrollbackBufferTests {
    @Test("empty buffer returns empty data")
    func testEmpty() {
        let buffer = ScrollbackBuffer(maxSize: 100)
        #expect(buffer.read().isEmpty)
    }

    @Test("append and read returns all data")
    func testAppendAndRead() {
        let buffer = ScrollbackBuffer(maxSize: 100)
        buffer.append(Data("hello ".utf8))
        buffer.append(Data("world".utf8))
        let result = String(data: buffer.read(), encoding: .utf8)
        #expect(result == "hello world")
    }

    @Test("overflow drops oldest data")
    func testOverflowDropsOldest() {
        let buffer = ScrollbackBuffer(maxSize: 10)
        buffer.append(Data("1234567890".utf8))
        buffer.append(Data("AB".utf8))
        let result = String(data: buffer.read(), encoding: .utf8)
        #expect(result == "34567890AB")
    }

    @Test("clear empties the buffer")
    func testClear() {
        let buffer = ScrollbackBuffer(maxSize: 100)
        buffer.append(Data("some data".utf8))
        buffer.clear()
        #expect(buffer.read().isEmpty)
    }
}
