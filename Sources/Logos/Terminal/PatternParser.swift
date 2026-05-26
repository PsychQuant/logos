import Foundation

@MainActor
public final class PatternParser {

    private var buffer: String = ""
    private let maxBufferSize: Int

    public init(maxBufferSize: Int = 4096) {
        self.maxBufferSize = maxBufferSize
    }

    /// Append new PTY output. Returns the current buffer contents with ANSI
    /// stripped, for the AutoHandleEngine to scan against.
    public func append(_ chunk: String) -> String {
        buffer += chunk
        if buffer.count > maxBufferSize {
            // Drop the oldest portion; keep recent half so cross-chunk patterns survive.
            let dropCount = buffer.count - maxBufferSize
            buffer.removeFirst(dropCount)
        }
        return Self.stripAnsi(buffer)
    }

    public var bufferSize: Int { buffer.count }

    public func reset() {
        buffer = ""
    }

    /// Strip CSI/OSC/etc. escape sequences for plain-text pattern matching.
    /// Crude but sufficient for the rule patterns we use.
    static func stripAnsi(_ input: String) -> String {
        // CSI: ESC [ ... letter
        // OSC: ESC ] ... BEL or ST
        // Simple: ESC X (single char)
        guard let regex = try? NSRegularExpression(
            pattern: #"\x1B\[[0-9;?]*[a-zA-Z]|\x1B\][^\x07\x1B]*[\x07\x1B]|\x1B."#
        ) else {
            return input
        }
        let range = NSRange(input.startIndex..., in: input)
        return regex.stringByReplacingMatches(in: input, range: range, withTemplate: "")
    }
}
