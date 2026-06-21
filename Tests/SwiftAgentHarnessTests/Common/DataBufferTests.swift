import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("DataBuffer bounded retention")
struct DataBufferTests {
    @Test("under cap retains all bytes")
    func underCap() {
        let buffer = DataBuffer(maxBytes: 1024)
        buffer.append(Data(repeating: 0x41, count: 100))
        #expect(buffer.totalBytes == 100)
        #expect(buffer.contents.count == 100)
        #expect(buffer.droppedBytes == 0)
        #expect(!buffer.isTruncated)
    }

    @Test("over cap drops prefix and tracks total")
    func overCap() {
        let buffer = DataBuffer(maxBytes: 100)
        buffer.append(Data(repeating: 0x41, count: 80))
        buffer.append(Data(repeating: 0x42, count: 80))
        #expect(buffer.totalBytes == 160)
        #expect(buffer.contents.count == 100)
        #expect(buffer.droppedBytes == 60)
        #expect(buffer.isTruncated)
        #expect(buffer.contents.suffix(80).allSatisfy { $0 == 0x42 })
    }

    @Test("slice returns delta from logical offset")
    func sliceDelta() {
        let buffer = DataBuffer(maxBytes: 10)
        buffer.append(Data("0123456789".utf8))
        buffer.append(Data("abcdefghij".utf8))
        #expect(buffer.totalBytes == 20)
        let delta = buffer.slice(fromLogicalOffset: 15)
        #expect(String(decoding: delta, as: UTF8.self) == "fghij")
    }

    @Test("slice skips dropped bytes before offset")
    func sliceSkipsDropped() {
        let buffer = DataBuffer(maxBytes: 10)
        buffer.append(Data(repeating: 0x58, count: 20))
        let fromDropped = buffer.slice(fromLogicalOffset: 5)
        #expect(fromDropped.count == 10)
        let tail = buffer.slice(fromLogicalOffset: 15)
        #expect(tail.count == 5)
    }
}

@Suite("BashProcessRegistry poll delta")
struct BashProcessRegistryPollDeltaTests {
    @Test("pollDelta advances surfaced bytes against logical total")
    func pollDelta() {
        let buffer = DataBuffer(maxBytes: 10)
        buffer.append(Data(repeating: 0x41, count: 15))
        var surfaced = 0
        let first = BashProcessRegistry.pollDelta(buffer: buffer, surfacedBytes: &surfaced)
        #expect(first.data.count == 10)
        #expect(surfaced == 15)
        #expect(first.truncated)
        let second = BashProcessRegistry.pollDelta(buffer: buffer, surfacedBytes: &surfaced)
        #expect(second.data.isEmpty)
    }
}
