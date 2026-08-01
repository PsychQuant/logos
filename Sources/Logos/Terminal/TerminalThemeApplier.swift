import AppKit
import SwiftTerm

@MainActor
enum TerminalThemeApplier {

    static func apply(config: TerminalConfig, to view: TerminalView) {
        // Font
        if let font = NSFont(name: config.fontName, size: config.fontSize) {
            view.font = font
        } else {
            view.font = NSFont.monospacedSystemFont(ofSize: config.fontSize, weight: .regular)
        }

        // Colors (parse hex → NSColor)
        if let bg = NSColor(hex: config.backgroundColorHex) {
            view.nativeBackgroundColor = bg
        }
        if let fg = NSColor(hex: config.foregroundColorHex) {
            view.nativeForegroundColor = fg
        }
    }
}

/// Internal (not private): #109 added a second consumer — `TerminalPaneView`
/// paints its window-padding gutter with `config.backgroundColorHex` so the
/// inset area is indistinguishable from the terminal's own background.
extension NSColor {
    convenience init?(hex: String) {
        var hex = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        let r = CGFloat((value >> 16) & 0xff) / 255
        let g = CGFloat((value >> 8) & 0xff) / 255
        let b = CGFloat(value & 0xff) / 255
        self.init(srgbRed: r, green: g, blue: b, alpha: 1)
    }
}
