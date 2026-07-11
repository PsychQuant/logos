import Testing
import Foundation
@testable import Logos

/// #47: the pure parse core of the status-bar token/context usage reader.
@Suite("ClaudeUsageReader")
struct ClaudeUsageReaderTests {

    @Test("parse: latest assistant usage = input + cache_read + cache_creation")
    func parseLatest() {
        let transcript = """
        {"type":"user","message":{"role":"user","content":"hi"}}
        {"type":"assistant","message":{"model":"claude-opus-4-8","usage":{"input_tokens":100,"cache_read_input_tokens":50,"cache_creation_input_tokens":10,"output_tokens":5}}}
        {"type":"assistant","message":{"model":"claude-opus-4-8","usage":{"input_tokens":200,"cache_read_input_tokens":300,"cache_creation_input_tokens":0,"output_tokens":9}}}
        """
        let usage = ClaudeUsageReader.parse(transcriptContents: transcript)
        #expect(usage?.contextTokens == 500)   // 200 + 300 + 0 (the LAST assistant turn)
        #expect(usage?.model == "claude-opus-4-8")
    }

    @Test("parse: a partially-written trailing line is skipped, last VALID line wins")
    func parseTolerablePartialTail() {
        let transcript = """
        {"type":"assistant","message":{"model":"m","usage":{"input_tokens":10,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}
        {"type":"assistant","message":{"model":"m","usage":{"input_tok
        """
        let usage = ClaudeUsageReader.parse(transcriptContents: transcript)
        #expect(usage?.contextTokens == 10)   // partial tail ignored
    }

    @Test("parse: no assistant usage → nil")
    func parseNone() {
        #expect(ClaudeUsageReader.parse(transcriptContents: #"{"type":"user","message":{}}"#) == nil)
    }

    @Test("contextMax: 200k default; 1M once usage provably exceeds 200k")
    func contextMaxMap() {
        #expect(ClaudeUsageReader.contextMax(forModel: "claude-opus-4-8") == 200_000)
        #expect(ClaudeUsageReader.contextMax(forModel: nil, observedTokens: 250_000) == 1_000_000)
    }
}

/// #49 Part 2: id-addressed transcript resolution. When we spawn claude with an explicit
/// `--session-id <uuid>`, the status bar reads exactly `<uuid>.jsonl` under `projects/`
/// instead of guessing "newest mtime" — which mis-binds when several sessions share one
/// config dir. Newest-mtime is kept as the FALLBACK for the window before the file exists
/// and for sessions spawned without an id.
@Suite("ClaudeUsageReader.transcriptURL")
struct ClaudeUsageReaderTranscriptURLTests {

    /// Build a throwaway `<configDir>/projects/<proj>/` holding the named `.jsonl` files,
    /// each stamped with an explicit modification date so ordering is deterministic (a
    /// same-second write race would otherwise make "newest" ambiguous).
    private func makeTree(_ dated: [(name: String, mtime: TimeInterval)]) throws -> String {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("logos-usage-\(UUID().uuidString)")
        let proj = root.appendingPathComponent("projects/-Users-che-proj")
        try fm.createDirectory(at: proj, withIntermediateDirectories: true)
        for entry in dated {
            var url = proj.appendingPathComponent(entry.name)
            try Data("{}\n".utf8).write(to: url)
            var values = URLResourceValues()
            values.contentModificationDate = Date(timeIntervalSince1970: entry.mtime)
            try url.setResourceValues(values)
        }
        return root.path
    }

    @Test("an id-addressed file wins even when it is NOT the newest")
    func idAddressedBeatsNewest() throws {
        let dir = try makeTree([
            ("11111111-1111-1111-1111-111111111111.jsonl", 1_000),   // ours, older
            ("newer-other.jsonl", 2_000),                            // newer, someone else's
        ])
        let url = ClaudeUsageReader.transcriptURL(
            inConfigDir: dir, sessionId: "11111111-1111-1111-1111-111111111111")
        #expect(url?.lastPathComponent == "11111111-1111-1111-1111-111111111111.jsonl")
    }

    @Test("falls back to newest-mtime when the id file does not exist yet")
    func fallbackWhenIdAbsent() throws {
        let dir = try makeTree([
            ("a.jsonl", 1_000),
            ("b.jsonl", 2_000),   // newest
        ])
        let url = ClaudeUsageReader.transcriptURL(inConfigDir: dir, sessionId: "not-created-yet")
        #expect(url?.lastPathComponent == "b.jsonl")
    }

    @Test("falls back to newest-mtime when sessionId is nil")
    func fallbackWhenNilSessionId() throws {
        let dir = try makeTree([
            ("a.jsonl", 1_000),
            ("b.jsonl", 2_000),   // newest
        ])
        let url = ClaudeUsageReader.transcriptURL(inConfigDir: dir, sessionId: nil)
        #expect(url?.lastPathComponent == "b.jsonl")
    }
}

/// #48: session cost = notional API-equivalent (what these tokens would cost on the
/// pay-per-use API, ccusage parity). Unlike `parse` (latest turn's context occupancy), cost
/// SUMS every assistant turn's tokens per model, then applies a per-model price with DISTINCT
/// cache-write and cache-read multipliers (never the input rate, never summed). A model with
/// no price entry is flagged, not silently priced at $0.
@Suite("ClaudeUsageReader.sessionCost")
struct ClaudeUsageReaderCostTests {

    @Test("accumulate: sums every assistant turn's tokens per model")
    func accumulateSumsAllTurnsPerModel() {
        let transcript = """
        {"type":"user","message":{"role":"user"}}
        {"type":"assistant","message":{"model":"claude-opus-4-8","usage":{"input_tokens":100,"output_tokens":10,"cache_creation_input_tokens":5,"cache_read_input_tokens":1}}}
        {"type":"assistant","message":{"model":"claude-opus-4-8","usage":{"input_tokens":200,"output_tokens":20,"cache_creation_input_tokens":0,"cache_read_input_tokens":9}}}
        """
        let totals = ClaudeUsageReader.accumulateTokens(transcriptContents: transcript)
        #expect(totals["claude-opus-4-8"] == ClaudeUsageReader.TokenTotals(
            input: 300, output: 30, cacheCreation: 5, cacheRead: 10))
    }

    @Test("cost: cache-write and cache-read priced at DISTINCT multipliers, not the input rate")
    func costAppliesDistinctCacheMultipliers() {
        // One opus turn with exactly 1M of each class so each rate surfaces as itself:
        // input 15 + output 75 + cacheWrite 18.75 + cacheRead 1.50 = 110.25.
        // If cache were (wrongly) priced at the input rate the sum would be 120.00; if
        // read used the write rate it would be 127.50 — so 110.25 pins all four rates.
        let transcript = """
        {"type":"assistant","message":{"model":"claude-opus-4-8","usage":{"input_tokens":1000000,"output_tokens":1000000,"cache_creation_input_tokens":1000000,"cache_read_input_tokens":1000000}}}
        """
        let cost = ClaudeUsageReader.sessionCost(transcriptContents: transcript)
        #expect(cost.usd == Decimal(string: "110.25"))
        #expect(cost.hasUnpricedModel == false)
    }

    @Test("cost: sums across multiple priced models")
    func costSumsAcrossModels() {
        // opus: 1M input → 15.00 ; sonnet: 1M output → 15.00 ; total 30.00
        let transcript = """
        {"type":"assistant","message":{"model":"claude-opus-4-8","usage":{"input_tokens":1000000,"output_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}
        {"type":"assistant","message":{"model":"claude-sonnet-4-6","usage":{"input_tokens":0,"output_tokens":1000000,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}
        """
        let cost = ClaudeUsageReader.sessionCost(transcriptContents: transcript)
        #expect(cost.usd == Decimal(string: "30.00"))
        #expect(cost.hasUnpricedModel == false)
    }

    @Test("cost: an unknown model id is flagged, never silently priced at $0 or the input rate")
    func costFlagsUnknownModelInsteadOfSilentZero() {
        // A priced opus turn plus a novel/unpriced model. The unpriced tokens contribute
        // nothing to the figure (there is no rate to apply) but MUST raise the sentinel so the
        // status bar can mark the total a lower bound rather than under-report silently.
        let transcript = """
        {"type":"assistant","message":{"model":"claude-opus-4-8","usage":{"input_tokens":1000000,"output_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}
        {"type":"assistant","message":{"model":"claude-northstar-9","usage":{"input_tokens":1000000,"output_tokens":1000000,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}
        """
        let cost = ClaudeUsageReader.sessionCost(transcriptContents: transcript)
        #expect(cost.usd == Decimal(string: "15.00"))   // only the opus turn is priced
        #expect(cost.hasUnpricedModel == true)
    }

    @Test("cost: an assistant turn carrying usage but no model id is flagged unpriced")
    func costFlagsMissingModelId() {
        let transcript = """
        {"type":"assistant","message":{"usage":{"input_tokens":1000000,"output_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}
        """
        let cost = ClaudeUsageReader.sessionCost(transcriptContents: transcript)
        #expect(cost.usd == Decimal(string: "0"))
        #expect(cost.hasUnpricedModel == true)
    }

    @Test("cost: no assistant usage → zero cost, nothing flagged")
    func costEmptyTranscript() {
        let cost = ClaudeUsageReader.sessionCost(transcriptContents: #"{"type":"user","message":{}}"#)
        #expect(cost.usd == Decimal(string: "0"))
        #expect(cost.hasUnpricedModel == false)
    }
}
