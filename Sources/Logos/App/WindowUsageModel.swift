import Observation
import Foundation

/// Per-window live token / context-window usage for the status bar (#47).
///
/// Each window (value-based `WindowGroup`, #42) shows its OWN account's claude session usage,
/// so this is window-scoped — `WindowRoot` owns one and points it at the window's account
/// config dir. It file-watches that account's session transcript and recomputes on append via
/// the pure `ClaudeUsageReader`. Read-only over claude's transcript; never touches credentials
/// (#34). Cost is intentionally NOT here — deferred to #48.
@Observable
@MainActor
final class WindowUsageModel {
    var contextTokens: Int = 0
    var contextMax: Int = 200_000

    @ObservationIgnored private var configDir: String?
    @ObservationIgnored private var watcher: FileWatcher?

    /// Display string `<used> / <max>` with k-compaction (mirrors the old StatusBarViewModel format).
    var formatted: String { "\(formatK(contextTokens)) / \(formatK(contextMax))" }

    /// Point this model at an account's config dir (or `nil` to clear, e.g. no active account).
    /// Re-resolvable — call again when the window's account changes. Idempotent teardown of any
    /// prior watcher.
    func track(configDir: String?) {
        watcher?.stop()
        watcher = nil
        self.configDir = configDir
        // #47 verify (Codex F1): reset to defaults on EVERY switch so a target account with
        // no transcript / no usage yet never lingers on the PREVIOUS account's tokens.
        contextTokens = 0
        contextMax = 200_000
        guard let configDir else { return }
        refresh()
        // #47 verify (Codex F5): watch the account's `.claude` dir itself — it always exists
        // (materialized before spawn), unlike `projects/` which claude creates lazily on the
        // first session. FSEvents is recursive, so this still catches `projects/**/*.jsonl`
        // appends AND the first-ever transcript; `refresh()` re-resolves the newest each fire.
        // FileWatcher only WATCHES the parent of the given path — it never creates the
        // sentinel, so the #34 read-only contract holds.
        let sentinel = configDir + "/.logos-usage-watch"
        let w = FileWatcher(path: sentinel, debounce: 0.5) { [weak self] in self?.refresh() }
        w.start()
        watcher = w
    }

    private func refresh() {
        guard let configDir,
              let url = ClaudeUsageReader.activeTranscriptURL(inConfigDir: configDir),
              let contents = try? String(contentsOf: url, encoding: .utf8),
              let usage = ClaudeUsageReader.parse(transcriptContents: contents)
        else { return }
        contextTokens = usage.contextTokens
        contextMax = ClaudeUsageReader.contextMax(forModel: usage.model, observedTokens: usage.contextTokens)
    }

    private func formatK(_ n: Int) -> String {
        if n >= 1_000_000 { return "\(n / 1_000_000)M" }   // #47 verify (Codex): 1M not 1000k
        if n < 1_000 { return "\(n)" }
        return "\(n / 1_000)k"
    }
}
