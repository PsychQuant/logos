import Foundation
import SwiftTerm

/// Subclass that taps bytes flowing from subprocess → terminal renderer.
/// Each chunk is forwarded to the parser/engine for auto-handle scanning,
/// then passed through to the normal renderer path.
///
/// **Adaptation note (vs. plan):** Plan suggested overriding
/// `feed(byteArray:)`. In SwiftTerm 1.13.0 that method is declared `public`
/// (not `open`) on `AppleTerminalView`, so we cannot override it. The
/// correct override slot is `dataReceived(slice:)` on
/// `LocalProcessTerminalView`, which is the `LocalProcessDelegate` entry
/// point that internally calls `feed(byteArray:)`. Tapping here gives us
/// every byte the renderer would have seen, before `feed()` runs.
@MainActor
public final class TeedLocalProcessTerminalView: LocalProcessTerminalView {

    /// Called for each byte chunk from the subprocess. Override point.
    public var onChunk: (([UInt8]) -> Void)?

    public override func dataReceived(slice: ArraySlice<UInt8>) {
        // Tap before parent processes
        onChunk?(Array(slice))
        super.dataReceived(slice: slice)
    }
}
