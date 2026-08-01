import Testing
import AppKit
@testable import Logos

/// #109: the hex parser gains a second consumer (the terminal gutter background
/// in `TerminalPaneView` must match `TerminalConfig.backgroundColorHex`), so it
/// graduates from a private extension to an internal one — and gets the unit
/// coverage it never had.
@Suite("NSColor hex parsing")
struct NSColorHexTests {

    private func rgb(_ c: NSColor) -> (CGFloat, CGFloat, CGFloat) {
        let s = c.usingColorSpace(.sRGB)!
        return (s.redComponent, s.greenComponent, s.blueComponent)
    }

    @Test("parses #RRGGBB")
    func hashForm() throws {
        let c = try #require(NSColor(hex: "#1e1e1e"))
        let (r, g, b) = rgb(c)
        #expect(abs(r - 30.0/255) < 0.001 && r == g && g == b)
    }

    @Test("parses bare RRGGBB without #")
    func bareForm() throws {
        let c = try #require(NSColor(hex: "d4d4d4"))
        #expect(abs(rgb(c).0 - 212.0/255) < 0.001)
    }

    @Test("trims surrounding whitespace")
    func whitespace() {
        #expect(NSColor(hex: "  #1e1e1e  ") != nil)
    }

    @Test("rejects short, long, empty, and non-hex input")
    func rejects() {
        #expect(NSColor(hex: "#fff") == nil)
        #expect(NSColor(hex: "#1e1e1e1e") == nil)
        #expect(NSColor(hex: "") == nil)
        #expect(NSColor(hex: "#zzzzzz") == nil)
    }
}
