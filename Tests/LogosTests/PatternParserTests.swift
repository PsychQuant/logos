import Testing
@testable import Logos

@Suite("PatternParser", .serialized)
@MainActor
struct PatternParserTests {

    @Test("detects pattern in single chunk")
    func singleChunk() {
        let parser = PatternParser(maxBufferSize: 4096)
        let detected = parser.append("Some text trigger here")
        #expect(detected.contains("trigger here"))
    }

    @Test("detects pattern across chunk boundary")
    func acrossChunks() {
        let parser = PatternParser(maxBufferSize: 4096)
        _ = parser.append("Some text trig")
        let detected = parser.append("ger here")
        #expect(detected.contains("trigger here"))
    }

    @Test("trims buffer at max size")
    func trimsBuffer() {
        let parser = PatternParser(maxBufferSize: 100)
        for _ in 0..<200 {
            _ = parser.append("a")
        }
        #expect(parser.bufferSize <= 100)
    }

    @Test("strips ANSI escape sequences before pattern matching")
    func stripsAnsi() {
        let parser = PatternParser(maxBufferSize: 4096)
        // "\u{1B}[31m" is red color code
        let detected = parser.append("\u{1B}[31mtrigger\u{1B}[0m here")
        #expect(detected.contains("trigger"))
        #expect(!detected.contains("\u{1B}"))
    }
}
