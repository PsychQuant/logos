import Testing
import Foundation
@testable import Logos

/// #116: the status bar's model / effort / version / branch all ride on the SAME transcript
/// pass the context read already does. These pin the parse, so a later refactor cannot drop
/// a field and leave the segments silently blank.
@Suite("ClaudeUsageReader identity fields")
struct ClaudeUsageReaderIdentityTests {

    /// The three fields are TOP-LEVEL record keys, not inside `message` — the mistake that
    /// would be easy to make when adding them next to `model`.
    private let transcript = """
    {"type":"assistant","version":"2.1.220","gitBranch":"main","effort":"xhigh","message":{"model":"claude-opus-5","usage":{"input_tokens":10,"cache_read_input_tokens":5,"cache_creation_input_tokens":2}}}
    """

    @Test("the latest turn's model, effort, version and branch are all parsed")
    func parsesIdentity() throws {
        let usage = try #require(ClaudeUsageReader.parse(transcriptContents: transcript))
        #expect(usage.contextTokens == 17)
        #expect(usage.model == "claude-opus-5")
        #expect(usage.effort == "xhigh")
        #expect(usage.version == "2.1.220")
        #expect(usage.gitBranch == "main")
    }

    /// Not every assistant turn carries `effort` (observed 698 of 700 on a live transcript),
    /// so a missing field must read as nil rather than sinking the whole parse.
    @Test("a turn without effort still parses everything else")
    func missingEffortIsTolerated() throws {
        let line = """
        {"type":"assistant","version":"2.1.220","gitBranch":"main","message":{"model":"claude-opus-5","usage":{"input_tokens":3}}}
        """
        let usage = try #require(ClaudeUsageReader.parse(transcriptContents: line))
        #expect(usage.effort == nil)
        #expect(usage.model == "claude-opus-5")
        #expect(usage.version == "2.1.220")
    }

    /// The LATEST turn wins, same as the token count — a mid-session model or effort switch
    /// must be reflected, not pinned to whatever the session opened with.
    @Test("a later turn's identity supersedes an earlier one")
    func latestTurnWins() throws {
        let two = """
        {"type":"assistant","effort":"high","message":{"model":"claude-sonnet-5","usage":{"input_tokens":1}}}
        {"type":"assistant","effort":"max","message":{"model":"claude-opus-5","usage":{"input_tokens":2}}}
        """
        let usage = try #require(ClaudeUsageReader.parse(transcriptContents: two))
        #expect(usage.model == "claude-opus-5")
        #expect(usage.effort == "max")
    }
}
