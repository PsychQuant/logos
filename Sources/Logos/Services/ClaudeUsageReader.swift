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

    // MARK: - #48: session cost (notional API-equivalent, ccusage parity)

    /// Cumulative token counts for one model across an ENTIRE session. Cost sums every
    /// assistant turn (unlike `parse`, which reports only the latest turn's context occupancy),
    /// so the four classes are tracked separately — cache-write and cache-read are priced at
    /// different rates and must not be collapsed into `input`.
    struct TokenTotals: Equatable {
        var input: Int = 0
        var output: Int = 0
        var cacheCreation: Int = 0
        var cacheRead: Int = 0
    }

    /// The map key for assistant turns whose record carries no model id — their tokens are still
    /// counted (so the cost figure never silently drops them) but resolve to no price, raising
    /// the unpriced sentinel. A real claude model id is never empty, so this can't collide.
    static let unknownModelKey = ""

    /// Accumulate per-model token totals across EVERY assistant turn. Skips malformed lines with
    /// the same tolerance as `parse` (a concurrently-appended partial tail is ignored).
    static func accumulateTokens(transcriptContents: String) -> [String: TokenTotals] {
        var totals: [String: TokenTotals] = [:]
        for line in transcriptContents.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  obj["type"] as? String == "assistant",
                  let message = obj["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any]
            else { continue }
            let model = message["model"] as? String ?? unknownModelKey
            var t = totals[model] ?? TokenTotals()
            t.input += usage["input_tokens"] as? Int ?? 0
            t.output += usage["output_tokens"] as? Int ?? 0
            t.cacheCreation += usage["cache_creation_input_tokens"] as? Int ?? 0
            t.cacheRead += usage["cache_read_input_tokens"] as? Int ?? 0
            totals[model] = t
        }
        return totals
    }

    /// Per-1M-token USD rates for a model. Cache write and cache read are DISTINCT rates
    /// (write ~= 1.25x input, read ~= 0.1x input) — never the input rate, never summed together.
    /// Using `Decimal` keeps the money math exact.
    ///
    /// NOTE (pending user confirmation at verify, #48): these rates are the published
    /// pay-per-use Anthropic list prices by model FAMILY. They yield a *notional API-equivalent*
    /// figure (what these tokens would cost on the metered API) for ccusage parity — NOT
    /// necessarily the user's actual subscription bill.
    struct ModelPricing: Equatable {
        let input: Decimal
        let output: Decimal
        let cacheWrite: Decimal
        let cacheRead: Decimal
    }

    /// Resolve a model id to its price by family prefix, so point releases within a family
    /// (`claude-opus-4-8`, `claude-opus-4-7`, ...) all price without a table edit. An id in no
    /// known family (a novel/preview model, or the empty `unknownModelKey`) returns `nil` — the
    /// caller flags it rather than silently pricing it at $0 or the input rate.
    static func pricing(forModel model: String) -> ModelPricing? {
        if model.hasPrefix("claude-opus-") {
            return ModelPricing(input: 15, output: 75, cacheWrite: Decimal(string: "18.75")!, cacheRead: Decimal(string: "1.50")!)
        }
        if model.hasPrefix("claude-sonnet-") {
            return ModelPricing(input: 3, output: 15, cacheWrite: Decimal(string: "3.75")!, cacheRead: Decimal(string: "0.30")!)
        }
        if model.hasPrefix("claude-haiku-") {
            return ModelPricing(input: 1, output: 5, cacheWrite: Decimal(string: "1.25")!, cacheRead: Decimal(string: "0.10")!)
        }
        return nil
    }

    /// The computed session cost plus whether any turn used an unpriced model.
    struct SessionCost: Equatable {
        /// Notional API-equivalent cost in USD (ccusage parity). A LOWER BOUND when
        /// `hasUnpricedModel` is true, since unpriced turns contribute nothing.
        let usd: Decimal
        /// True if any assistant turn used a model with no price entry (novel/preview model, or a
        /// record with no model id). Surfaced with a visible marker rather than under-reported.
        let hasUnpricedModel: Bool
    }

    /// Sum the notional API-equivalent cost over all models in the transcript. Unpriced models
    /// contribute $0 to the figure but raise `hasUnpricedModel` (visible sentinel, not silent).
    static func sessionCost(transcriptContents: String) -> SessionCost {
        let totals = accumulateTokens(transcriptContents: transcriptContents)
        let perMillion: Decimal = 1_000_000
        var usd: Decimal = 0
        var hasUnpriced = false
        for (model, t) in totals {
            guard let price = pricing(forModel: model) else {
                if t.input + t.output + t.cacheCreation + t.cacheRead > 0 { hasUnpriced = true }
                continue
            }
            usd += Decimal(t.input) * price.input / perMillion
                + Decimal(t.output) * price.output / perMillion
                + Decimal(t.cacheCreation) * price.cacheWrite / perMillion
                + Decimal(t.cacheRead) * price.cacheRead / perMillion
        }
        return SessionCost(usd: usd, hasUnpricedModel: hasUnpriced)
    }

    /// The transcript to read for a window's session (#49 Part 2, tightened in #89). Bind only
    /// to the exact `<sessionId>.jsonl` claude wrote for the id we spawned it with — a reliable
    /// binding even when several sessions share one config dir. Returns `nil` when there is no
    /// bound session id, and `nil` (via `sessionTranscriptURL`) until claude has materialized the
    /// id-addressed file — the fresh-session window before its first write. Read-only; never
    /// touches credentials (#34).
    ///
    /// #89: there is deliberately NO newest-mtime fallback. The pre-#49 MVP heuristic
    /// (`activeTranscriptURL`, newest-mtime = a FOREIGN session's transcript) was the root of the
    /// stale-usage bug — a window with no bound session, or one whose transcript isn't written
    /// yet, would read the PREVIOUS session's `.jsonl` and show its tokens/cost. Resolving to
    /// `nil` instead makes the status bar show empty/zero, which is strictly better than a
    /// foreign session's numbers. This drops the rare caller-supplied-own-`--session-id` case
    /// (`onSessionSpawned(nil)`) from a best-effort read to empty — accepted, for the same reason.
    static func transcriptURL(inConfigDir configDir: String, sessionId: String?) -> URL? {
        guard let sessionId else { return nil }
        return sessionTranscriptURL(inConfigDir: configDir, sessionId: sessionId)
    }

    /// Recursively locate `<sessionId>.jsonl` under `<configDir>/projects/` — the exact file
    /// claude writes for a session started with `--session-id`. It lives one level down under
    /// a URL-encoded-cwd folder whose name we cannot predict, so this searches the tree by
    /// file name rather than joining a fixed path. `nil` until claude first materializes it.
    static func sessionTranscriptURL(inConfigDir configDir: String, sessionId: String) -> URL? {
        let projects = URL(fileURLWithPath: configDir).appendingPathComponent("projects")
        let fm = FileManager.default
        let target = sessionId + ".jsonl"
        guard let enumerator = fm.enumerator(at: projects, includingPropertiesForKeys: nil)
        else { return nil }
        for case let url as URL in enumerator where url.lastPathComponent == target {
            return url
        }
        return nil
    }
}
