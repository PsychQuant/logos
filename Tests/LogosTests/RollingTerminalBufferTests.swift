import Testing
import Foundation
@testable import Logos

/// Tests for the bounded, reset-immune detector buffer (PsychQuant/logos#30 Item 1).
/// The auto-handle `PatternParser` is `reset()` whenever a rule fires, so a 401 /
/// OAuth signal split across two PTY chunks with a reset between them would be lost.
/// `RollingTerminalBuffer` is the shared, reset-immune window both passive detectors
/// scan — these lock its retention + cross-chunk-contiguity invariants.
@Suite("RollingTerminalBuffer", .serialized)
@MainActor
struct RollingTerminalBufferTests {

    @Test("empty buffer has empty contents")
    func startsEmpty() {
        let buf = RollingTerminalBuffer()
        #expect(buf.contents.isEmpty)
    }

    @Test("appended text appears in contents, ANSI-stripped")
    func appendStrips() {
        var buf = RollingTerminalBuffer()
        buf.append("\u{1B}[31mError 401\u{1B}[0m")
        #expect(buf.contents == "Error 401")
    }

    @Test("a signal split across two appends is contiguous in contents")
    func splitAppendContiguous() {
        var buf = RollingTerminalBuffer()
        buf.append("Please run /login")
        #expect(buf.contents.contains("401") == false)
        buf.append(" · API Error: 401")
        // Both halves co-exist in the window — the property Item 1 depends on.
        #expect(buf.contents.contains("Please run /login"))
        #expect(buf.contents.contains("401"))
    }

    @Test("keeps only the last `capacity` raw chars, dropping the oldest")
    func capDropsOldest() {
        var buf = RollingTerminalBuffer()
        buf.append(String(repeating: "A", count: RollingTerminalBuffer.capacity))
        buf.append("TAIL401")
        // Oldest chars dropped to honor the cap; the freshest signal is retained.
        #expect(buf.contents.count <= RollingTerminalBuffer.capacity)
        #expect(buf.contents.hasSuffix("TAIL401"))
    }

    @Test("an ANSI escape spanning a chunk boundary is stripped, not left partial")
    func crossChunkEscapeStripped() {
        var buf = RollingTerminalBuffer()
        // ESC arrives in chunk 1, the rest of the CSI sequence in chunk 2 —
        // storing raw + stripping on read (not per-chunk) handles this.
        buf.append("OK\u{1B}")
        buf.append("[0m DONE")
        #expect(buf.contents == "OK DONE")
    }
}
