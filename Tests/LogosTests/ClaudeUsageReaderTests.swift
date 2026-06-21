import Testing
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
