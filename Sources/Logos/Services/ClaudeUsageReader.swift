import Foundation

/// Reads real token / context-window usage from a claude session transcript JSONL (#47).
///
/// The parse core is **pure** (String in, value out) so the token math is the `swift test`
/// unit gate without touching the filesystem; the FS helper that finds the active transcript
/// is kept separate. **Read-only** — it only parses claude's own transcript files; it never
/// reads, writes, or touches credentials / keychain (the #34 launcher red line).
enum ClaudeUsageReader {

    struct Usage: Equatable {
        /// Context-window tokens consumed on the latest turn = input + cache(read + creation).
        let contextTokens: Int
        /// Model id of the latest assistant turn (e.g. `claude-opus-4-8`), if present.
        let model: String?
    }

    /// Parse a transcript's full contents → the **latest** assistant turn's usage.
    ///
    /// Iterates lines and **skips any that fail to JSON-parse**, which tolerates a partially
    /// written trailing line (claude appends to this file concurrently while it runs).
    /// Returns `nil` if no `assistant` record carrying a `usage` block is found.
    static func parse(transcriptContents: String) -> Usage? {
        var latest: Usage?
        for line in transcriptContents.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  obj["type"] as? String == "assistant",
                  let message = obj["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any]
            else { continue }
            let input = usage["input_tokens"] as? Int ?? 0
            let cacheRead = usage["cache_read_input_tokens"] as? Int ?? 0
            let cacheCreate = usage["cache_creation_input_tokens"] as? Int ?? 0
            latest = Usage(
                contextTokens: input + cacheRead + cacheCreate,
                model: message["model"] as? String
            )
        }
        return latest
    }

    /// The context-window max for a session. **Data-driven first**: if usage already exceeds
    /// 200k, this is provably a >200k-context (1M) session → 1M. Otherwise default 200k.
    /// (The model id alone — e.g. `claude-opus-4-8` — does NOT encode the 1M-context beta, so
    /// a 1M session reads 200k here until it actually crosses 200k; the *used* count always
    /// stays correct. See #47 Risks.)
    static func contextMax(forModel model: String?, observedTokens: Int = 0) -> Int {
        if observedTokens > 200_000 { return 1_000_000 }
        return 200_000
    }

    /// Most-recently-modified `.jsonl` transcript under `<configDir>/projects/` — the MVP
    /// heuristic for "the active session" (no session-UUID handshake with claude). `nil` if
    /// none exists yet. FS access — kept out of the pure core.
    static func activeTranscriptURL(inConfigDir configDir: String) -> URL? {
        let projects = URL(fileURLWithPath: configDir).appendingPathComponent("projects")
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: projects,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return nil }
        var newest: (url: URL, date: Date)?
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            let mod = (try? url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? .distantPast
            if newest == nil || mod > newest!.date { newest = (url, mod) }
        }
        return newest?.url
    }
}
