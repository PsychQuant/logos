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
        guard let configDir else {
            contextTokens = 0
            contextMax = 200_000
            return
        }
        refresh()
        // FileWatcher watches the PARENT of the given path, recursively (FSEvents) — so a
        // path inside `projects/` makes it observe every session file under it; `refresh()`
        // re-resolves the newest transcript each fire, so a brand-new session is picked up too.
        let sentinel = configDir + "/projects/.logos-usage-watch"
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
        if n < 1_000 { return "\(n)" }
        return "\(n / 1_000)k"
    }
}
