import Testing
@testable import Logos

/// #116: the status bar shows the model the way Claude Code itself does — `Opus 5 (1M)`,
/// not the raw `claude-opus-5[1m]` id.
///
/// A parser rather than a lookup table: point releases arrive constantly, and a table would
/// silently fall through to the raw id for every model released after the last table edit —
/// exactly the staleness that made `baseWindow(forModel:)` wrong (#113).
@Suite("ModelDisplayName")
struct ModelDisplayNameTests {

    @Test("a bare major version reads as the family plus that version")
    func bareMajor() {
        #expect(ModelDisplayName.of("claude-opus-5") == "Opus 5")
        #expect(ModelDisplayName.of("claude-fable-5") == "Fable 5")
    }

    @Test("a major.minor id reads with a dot")
    func majorMinor() {
        #expect(ModelDisplayName.of("claude-opus-4-8") == "Opus 4.8")
        #expect(ModelDisplayName.of("claude-sonnet-4-6") == "Sonnet 4.6")
        #expect(ModelDisplayName.of("claude-haiku-4-5") == "Haiku 4.5")
    }

    /// A dated snapshot id must not render as `Haiku 4.5.20251001`.
    @Test("a trailing date snapshot is dropped, not rendered as another version component")
    func dateSuffixDropped() {
        #expect(ModelDisplayName.of("claude-haiku-4-5-20251001") == "Haiku 4.5")
        #expect(ModelDisplayName.of("claude-opus-4-5-20251101") == "Opus 4.5")
    }

    /// The `[1m]` context-beta suffix is a SELECTOR, not part of the family id. It must not
    /// leak into the name — the window size is shown separately, from the real signal.
    @Test("a [1m] selector suffix is stripped from the family id")
    func contextBetaSuffixStripped() {
        #expect(ModelDisplayName.of("claude-opus-5[1m]") == "Opus 5")
        #expect(ModelDisplayName.of("claude-sonnet-5[1M]") == "Sonnet 5")
    }

    /// An id shape we have never seen must render AS ITSELF rather than as a guess or a
    /// blank. A wrong-but-plausible name is worse than an unfamiliar one — this is the
    /// clarity point left open on #116.
    @Test("an unrecognized id falls back to the raw id rather than guessing")
    func unknownFallsBackToRawID() {
        #expect(ModelDisplayName.of("some-future-model") == "some-future-model")
        #expect(ModelDisplayName.of("claude") == "claude")
    }

    @Test("nil or empty yields nil, so the segment can hide instead of showing a blank chip")
    func nilAndEmpty() {
        #expect(ModelDisplayName.of(nil) == nil)
        #expect(ModelDisplayName.of("") == nil)
    }

    /// The window size rides alongside the name, matching Claude Code's own `Opus 5 (1M)`.
    /// Only the 1M window is annotated — the base window is the unremarkable case.
    @Test("a 1M context window is annotated; the base window is not")
    func contextAnnotation() {
        #expect(ModelDisplayName.of("claude-opus-5", contextWindow: 1_000_000) == "Opus 5 (1M)")
        #expect(ModelDisplayName.of("claude-opus-5", contextWindow: 200_000) == "Opus 5")
        #expect(ModelDisplayName.of("claude-opus-5", contextWindow: 0) == "Opus 5")
    }

    /// The annotation must survive the fallback path too — an unknown id on a 1M window
    /// still tells the user which window they are spending.
    @Test("the 1M annotation applies to the raw-id fallback as well")
    func annotationOnFallback() {
        #expect(ModelDisplayName.of("mystery-model", contextWindow: 1_000_000) == "mystery-model (1M)")
    }
}
