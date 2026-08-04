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
        ///
        /// Never carries the `[1m]` context-beta suffix — claude writes the bare family id
        /// here (#95's note, re-confirmed empirically at #113). The window it selects has
        /// to come from elsewhere.
        let model: String?
        /// #116: reasoning effort of the latest assistant turn (`high` / `xhigh` / …).
        let effort: String?
        /// #116: the claude CLI version that wrote the turn (e.g. `2.1.220`).
        let version: String?
        /// #116: the git branch claude saw for the project at that turn.
        let gitBranch: String?

        init(
            contextTokens: Int,
            model: String?,
            effort: String? = nil,
            version: String? = nil,
            gitBranch: String? = nil
        ) {
            self.contextTokens = contextTokens
            self.model = model
            self.effort = effort
            self.version = version
            self.gitBranch = gitBranch
        }
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
            // #116: `effort` / `version` / `gitBranch` are TOP-LEVEL record keys, not
            // inside `message` — verified against a live transcript, where every assistant
            // record carrying a usage block also carried version and gitBranch (700/700)
            // and nearly all carried effort (698/700). Reading them here costs no extra I/O.
            latest = Usage(
                contextTokens: input + cacheRead + cacheCreate,
                model: message["model"] as? String,
                effort: obj["effort"] as? String,
                version: obj["version"] as? String,
                gitBranch: obj["gitBranch"] as? String
            )
        }
        return latest
    }

    /// #95: model family → BASE context window (before the 1M beta). Keyed by prefix like
    /// `pricing(forModel:)`, so point releases within a family resolve without a table edit. An
    /// unknown / nil family defaults to 200k (fail-open — never over-reports the window).
    static func baseWindow(forModel model: String?) -> Int {
        // opus / sonnet / haiku / fable all ship a 200k base window today; the 1M is a beta on top.
        return 200_000
    }

    /// #95: the account's SELECTED model, read from `<configDir>/settings.json`'s `model` field
    /// (e.g. `claude-opus-4-8[1m]`). This is where Claude Code persists the `[1m]` context-beta
    /// choice — the transcript's `usage.model` does NOT carry it. Lenient: absent file / malformed
    /// JSON / empty-or-missing `model` all return nil, same read-only discipline as the transcript
    /// read (#34 — no credentials, just the model string).
    static func selectedModel(inConfigDir configDir: String) -> String? {
        let url = URL(fileURLWithPath: configDir).appendingPathComponent("settings.json")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let model = obj["model"] as? String, !model.isEmpty
        else { return nil }
        return model
    }

    /// #95: does a model id carry the `[1m]`/`[1M]` context-beta suffix (e.g. `claude-opus-4-8[1m]`)?
    static func hasOneMillionSuffix(_ model: String?) -> Bool {
        model?.lowercased().hasSuffix("[1m]") ?? false
    }

    /// #95: strip a trailing `[…]` beta suffix to get the base family id (e.g.
    /// `claude-opus-4-8[1m]` → `claude-opus-4-8`), so a selected model can be matched against the
    /// session's transcript model.
    static func familyBase(_ model: String?) -> String? {
        guard let model, let bracket = model.firstIndex(of: "[") else { return model }
        return String(model[..<bracket])
    }

    /// #95: the session's context-window max, derived from the model rather than a hardcoded
    /// default. (1) `base` = `baseWindow(sessionModel)`; (2) if the account's SELECTED model carries
    /// the `[1m]` context-beta suffix AND its base id matches the session's model → 1M up front
    /// (before any tokens); (3) else if usage already exceeds `base` → 1M (fallback, so it
    /// self-corrects even without the settings signal); (4) else `base`.
    static func contextWindow(
        sessionModel: String?,
        selectedModel: String?,
        observedTokens: Int = 0,
        reportedWindow: Int? = nil
    ) -> Int {
        // (0) #113: the session told us. This OUTRANKS every inference below, because the
        // rest of this ladder is guesswork about a value the session actually knows.
        //
        // It also answers the complaint that opened the issue —「剛開始應賅就要先蒐集詢問一
        // 次吧」. Branch (3) below is a POST-HOC correction that cannot fire until 200k has
        // been spent, so a 1M session read wrong for its entire first 200k: not an edge case,
        // but every session's opening, and exactly when the number matters most.
        //
        // A non-positive report is no signal, not a value to display (the #110 rule).
        if let reportedWindow, reportedWindow > 0 { return reportedWindow }

        let base = baseWindow(forModel: sessionModel)
        // (2) The account's SELECTED model carries [1m] → a 1M session. When the session's model is
        // not known yet (fresh session, no transcript), trust the selection outright — that's the
        // up-front `0 / 1M`. Once the session model IS known, require a base-id match, so a
        // different family's saved default (`fable[1m]`) never turns an `opus` session into 1M.
        if hasOneMillionSuffix(selectedModel),
           sessionModel == nil || familyBase(selectedModel) == familyBase(sessionModel) {
            return 1_000_000
        }
        if observedTokens > base { return 1_000_000 }   // (3) fallback: usage proved a larger window
        return base                                      // (4)
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
