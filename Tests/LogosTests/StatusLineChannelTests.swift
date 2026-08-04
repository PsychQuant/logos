import Testing
import Foundation
@testable import Logos

/// #113: the only authoritative source for a session's context window.
///
/// Enumerating every subcommand of the CLI confirmed there is no read-only way to ask a
/// session how big its window is — `claude config` / `models` / `status` do not exist, and
/// `claude agents --json` (the one command that lists other sessions from outside)
/// deliberately carries no model or context field. The number exists only as data the
/// running session PUSHES to a `statusLine` command, as `context_window.context_window_size`
/// — 200000 or 1000000.
///
/// Installing that command means writing to a claude settings file, so these tests pin the
/// boundary as hard as the parsing: what gets written, what must never be overwritten, and
/// which directories are off limits.
@Suite("StatusLineChannel", .serialized)
struct StatusLineChannelTests {

    private func tempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("logos-113-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func settings(in dir: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("settings.json")),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj
    }

    private func write(_ json: String, to dir: URL) throws {
        try json.write(
            to: dir.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)
    }

    // MARK: - Installing

    @Test("installing into a config dir with no settings file creates one carrying the command")
    func installsIntoEmptyDir() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(StatusLineChannel.install(inConfigDir: dir.path) == .installed)

        let line = settings(in: dir)?["statusLine"] as? [String: Any]
        #expect(line?["type"] as? String == "command")
        #expect((line?["command"] as? String)?.isEmpty == false)
    }

    @Test("installing preserves every unrelated key already in the file")
    func preservesOtherKeys() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write(#"{"theme":"dark","enabledPlugins":["a","b"]}"#, to: dir)

        #expect(StatusLineChannel.install(inConfigDir: dir.path) == .installed)

        let obj = settings(in: dir)
        #expect(obj?["theme"] as? String == "dark")
        #expect((obj?["enabledPlugins"] as? [String])?.count == 2)
        #expect(obj?["statusLine"] != nil)
    }

    /// THE boundary. A statusLine the user configured for themselves is theirs; silently
    /// replacing it would break their terminal to serve our readout. We decline instead.
    @Test("a statusLine the user already configured is never overwritten")
    func neverOverwritesForeignStatusLine() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write(#"{"statusLine":{"type":"command","command":"/usr/local/bin/my-own-bar"}}"#, to: dir)

        #expect(StatusLineChannel.install(inConfigDir: dir.path) == .declinedForeignStatusLine)

        let line = settings(in: dir)?["statusLine"] as? [String: Any]
        #expect(line?["command"] as? String == "/usr/local/bin/my-own-bar", "user's command was clobbered")
    }

    /// Re-installing must be a no-op rather than rewriting the file on every window open.
    @Test("re-installing our own command is idempotent")
    func reinstallIsIdempotent() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(StatusLineChannel.install(inConfigDir: dir.path) == .installed)
        #expect(StatusLineChannel.install(inConfigDir: dir.path) == .alreadyInstalled)
    }

    /// A malformed settings.json must not be destroyed by our write.
    @Test("a settings file that is not JSON is left untouched")
    func declinesOnUnparseableSettings() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write("{ this is not json", to: dir)

        #expect(StatusLineChannel.install(inConfigDir: dir.path) == .declinedUnreadableSettings)

        let raw = try String(contentsOf: dir.appendingPathComponent("settings.json"), encoding: .utf8)
        #expect(raw == "{ this is not json", "a malformed file must survive verbatim")
    }

    // MARK: - Uninstalling

    @Test("uninstalling removes only our command and leaves the rest of the file")
    func uninstallRemovesOnlyOurs() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write(#"{"theme":"dark"}"#, to: dir)
        _ = StatusLineChannel.install(inConfigDir: dir.path)

        StatusLineChannel.uninstall(inConfigDir: dir.path)

        let obj = settings(in: dir)
        #expect(obj?["statusLine"] == nil, "our command should be gone")
        #expect(obj?["theme"] as? String == "dark", "unrelated settings must survive")
    }

    @Test("uninstalling leaves a statusLine we did not install alone")
    func uninstallSparesForeign() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write(#"{"statusLine":{"type":"command","command":"/usr/local/bin/my-own-bar"}}"#, to: dir)

        StatusLineChannel.uninstall(inConfigDir: dir.path)

        let line = settings(in: dir)?["statusLine"] as? [String: Any]
        #expect(line?["command"] as? String == "/usr/local/bin/my-own-bar")
    }

    // MARK: - Reading what the session pushed

    @Test("the pushed context window size is read back")
    func readsPushedWindow() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let payload = #"{"context_window":{"context_window_size":1000000,"used_percentage":12.5}}"#
        try payload.write(
            to: URL(fileURLWithPath: StatusLineChannel.reportPath(inConfigDir: dir.path)),
            atomically: true, encoding: .utf8)

        #expect(StatusLineChannel.reportedContextWindow(inConfigDir: dir.path) == 1_000_000)
    }

    @Test("a missing, empty, malformed or zero report reads as no signal")
    func absentOrJunkReportIsNoSignal() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = URL(fileURLWithPath: StatusLineChannel.reportPath(inConfigDir: dir.path))

        #expect(StatusLineChannel.reportedContextWindow(inConfigDir: dir.path) == nil, "missing")

        for junk in ["", "not json", "{}", #"{"context_window":{}}"#, #"{"context_window":{"context_window_size":0}}"#] {
            try junk.write(to: path, atomically: true, encoding: .utf8)
            #expect(
                StatusLineChannel.reportedContextWindow(inConfigDir: dir.path) == nil,
                "junk payload \(junk.prefix(20)) should read as no signal")
        }
    }
}

/// #113: the authoritative signal must OUTRANK every inference, and its absence must leave
/// the existing ladder exactly as it was — the pre-#113 tests below are unchanged behaviour.
@Suite("ClaudeUsageReader.contextWindow with the authoritative signal")
struct ContextWindowAuthoritativeTests {

    @Test("a reported window wins over the base, with no tokens spent yet")
    func reportedWindowWinsUpFront() {
        #expect(ClaudeUsageReader.contextWindow(
            sessionModel: "claude-opus-5", selectedModel: nil,
            observedTokens: 0, reportedWindow: 1_000_000) == 1_000_000)
    }

    /// The whole point of the issue: 「剛開始應賅就要先蒐集詢問一次吧」. The observed-tokens
    /// fallback only self-corrects AFTER 200k has been spent, so a 1M session read wrong for
    /// its entire first 200k. A reported window fixes it from the first turn.
    @Test("a reported window also wins over a base the old ladder would have chosen")
    func reportedBeatsTheStaleLadder() {
        let old = ClaudeUsageReader.contextWindow(
            sessionModel: "claude-opus-5", selectedModel: nil, observedTokens: 97_000)
        #expect(old == 200_000, "the pre-#113 ladder still reads 200k for this session")

        #expect(ClaudeUsageReader.contextWindow(
            sessionModel: "claude-opus-5", selectedModel: nil,
            observedTokens: 97_000, reportedWindow: 1_000_000) == 1_000_000)
    }

    /// A session that genuinely IS on the base window must not be inflated.
    @Test("a reported base window is honoured rather than assumed to be 1M")
    func reportedBaseIsHonoured() {
        #expect(ClaudeUsageReader.contextWindow(
            sessionModel: "claude-opus-5", selectedModel: nil,
            observedTokens: 0, reportedWindow: 200_000) == 200_000)
    }

    /// No signal → the ladder behaves exactly as before, including the [1m] settings read
    /// and the observed-tokens self-correction. This is the Main-account path.
    @Test("with no reported window the pre-#113 ladder is unchanged")
    func ladderUnchangedWithoutSignal() {
        #expect(ClaudeUsageReader.contextWindow(
            sessionModel: "claude-opus-4-8", selectedModel: "claude-opus-4-8[1m]",
            observedTokens: 0, reportedWindow: nil) == 1_000_000)
        #expect(ClaudeUsageReader.contextWindow(
            sessionModel: "claude-opus-4-8", selectedModel: "claude-opus-4-8",
            observedTokens: 0, reportedWindow: nil) == 200_000)
        #expect(ClaudeUsageReader.contextWindow(
            sessionModel: nil, selectedModel: nil,
            observedTokens: 250_000, reportedWindow: nil) == 1_000_000)
    }

    @Test("a nonsensical reported window is ignored rather than displayed")
    func nonsensicalReportIgnored() {
        #expect(ClaudeUsageReader.contextWindow(
            sessionModel: "claude-opus-5", selectedModel: nil,
            observedTokens: 0, reportedWindow: 0) == 200_000)
        #expect(ClaudeUsageReader.contextWindow(
            sessionModel: "claude-opus-5", selectedModel: nil,
            observedTokens: 0, reportedWindow: -5) == 200_000)
    }
}
