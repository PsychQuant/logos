import Observation
import Foundation
import os

/// #91: the subset of `FileWatcher` this model drives — a `@MainActor` seam so a test can
/// inject a spy and assert the watcher is stopped on teardown/deinit (mirrors the existing
/// `read: Reader` injection). The real `FileWatcher` already satisfies it.
@MainActor
protocol UsageWatching: AnyObject {
    func start()
    func stop()
}

extension FileWatcher: UsageWatching {}

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

    /// #48: notional API-equivalent session cost (what this session's tokens would cost on the
    /// metered API, ccusage parity) — NOT necessarily the user's subscription bill. Summed over
    /// every assistant turn from the same transcript the context read uses.
    var sessionCostUSD: Decimal = 0
    /// #48: true when the session used a model with no price entry, so `sessionCostUSD` is a
    /// lower bound. `sessionCostFormatted` appends a visible "+?" marker rather than silently
    /// under-reporting.
    var hasUnpricedModel: Bool = false

    /// #116: identity of the latest assistant turn, for the status bar's model segment.
    /// All read out of the SAME transcript pass the context read already does.
    var modelID: String?
    var effort: String?
    var cliVersion: String?
    var gitBranch: String?

    /// #116: the model as Claude Code itself renders it — `Opus 5 (1M)`. Nil before the
    /// first assistant turn, so the segment hides rather than showing an empty chip.
    ///
    /// The `(1M)` half rides on `contextMax`, which today only reaches 1M through the
    /// observed-tokens fallback — so on a 1M session it appears late. #113 replaces that
    /// with the authoritative signal and this line then reads correctly from the start.
    var modelDisplayName: String? { ModelDisplayName.of(modelID, contextWindow: contextMax) }

    @ObservationIgnored private var configDir: String?
    @ObservationIgnored private var watcher: UsageWatching?

    /// #49 Part 2: the id of the claude session this window spawned (via `--session-id`),
    /// or nil before the terminal reports one / for a session started without an id. The
    /// reader binds to `<sessionId>.jsonl` directly when set; when nil (or before that file
    /// exists) the read resolves to no transcript, so the status bar shows empty rather than a
    /// FOREIGN session's tokens (#89 — the newest-mtime fallback that cross-read them is gone).
    @ObservationIgnored private var sessionId: String?

    /// #49 Part 1: monotonic refresh counter for newest-wins ordering. A refresh reads +
    /// parses OFF the main actor, so two `refresh()` calls (e.g. a slow read for account A
    /// racing a switch to B) can resolve out of order. Each captures its generation on
    /// entry and applies its result only while still the newest AND while `configDir` is
    /// still the one it read — so a stale read can never clobber a just-switched account.
    @ObservationIgnored private var refreshGeneration = 0

    /// #49 Part 1: the most recent in-flight refresh. `private(set)` so tests can await it
    /// deterministically (there is no production reader of this).
    @ObservationIgnored private(set) var inFlightRefresh: Task<Void, Never>?

    /// The parsed usage a refresh applies on the main actor. Value type so it crosses the
    /// off-main → main hop safely.
    struct Snapshot: Equatable, Sendable {
        var contextTokens: Int
        var contextMax: Int
        /// #48: cost fields default so existing `Snapshot(contextTokens:contextMax:)` call sites
        /// (and any pre-#48 reader) keep compiling; a real read fills them in.
        var sessionCostUSD: Decimal = 0
        var hasUnpricedModel: Bool = false
        /// #116: same defaulting rationale as the cost fields — existing call sites keep
        /// compiling and a real read fills them in.
        var modelID: String? = nil
        var effort: String? = nil
        var cliVersion: String? = nil
        var gitBranch: String? = nil
    }

    /// Off-main read + parse seam. Given the account's config dir and the bound session id
    /// (nil → no transcript, so an empty status bar rather than a foreign read; #89), returns
    /// the parsed snapshot (or `nil` when there is no transcript / no usage yet). The production
    /// default hops the blocking filesystem read off the main actor; tests inject a controllable
    /// reader to make the newest-wins ordering deterministic.
    typealias Reader = @Sendable (String, String?) async -> Snapshot?

    @ObservationIgnored private let read: Reader

    /// #91: builds the `FileWatcher` for an account dir. Injected so a test can substitute a spy
    /// and assert `stop()` fires on teardown/deinit; defaults to a real `FileWatcher`.
    typealias MakeWatcher = @MainActor (_ path: String, _ debounce: TimeInterval, _ onChange: @escaping () -> Void) -> UsageWatching

    @ObservationIgnored private let makeWatcher: MakeWatcher

    init(read: @escaping Reader = WindowUsageModel.defaultRead,
         makeWatcher: @escaping MakeWatcher = { FileWatcher(path: $0, debounce: $1, callback: $2) }) {
        self.read = read
        self.makeWatcher = makeWatcher
    }

    /// #91: backstop teardown. `WindowRoot.onDisappear` stops the watcher promptly on window
    /// close, but if it never fires (SwiftUI teardown ordering, or any non-window owner) the
    /// `FileWatcher`'s FSEventStream would keep firing into a freed watcher — it derefs an
    /// UNRETAINED `self` (`passUnretained`), a use-after-free. `isolated deinit` (SE-0371, Swift
    /// 6.1+) runs on the main actor, so this `@MainActor` model CAN stop the `@MainActor` watcher
    /// on dealloc — the blocker the old `FileWatcher` / `WindowRoot` comments described is gone.
    isolated deinit {
        watcher?.stop()
    }

    /// #83: nonisolated so `defaultRead`'s detached read can log from off the main actor. A
    /// `Logger` is `Sendable`, and the CI-strict rule that a static on a `@MainActor` type
    /// inherits `@MainActor` isolation would otherwise make it main-actor-only (see the
    /// `swift6-mainactor-static-inheritance-ci-skew` note) — `nonisolated` keeps it reachable
    /// from the detached task.
    nonisolated private static let log = Logger(subsystem: "app.getlogos.logos", category: "window-usage")

    /// Production reader: resolve the session's transcript (id-addressed when a session id is
    /// bound, else no transcript → nil; #89) and parse it entirely off the main actor (FS
    /// enumerate + full-file read + per-line JSON parse). Read-only over claude's own transcript
    /// tree — never credentials / keychain (#34).
    nonisolated static let defaultRead: Reader = { configDir, sessionId in
        await Task.detached(priority: .userInitiated) {
            guard let url = ClaudeUsageReader.transcriptURL(inConfigDir: configDir, sessionId: sessionId)
            else { return nil as Snapshot? }
            // #83: a plain `try?` collapsed "transcript not written yet" (benign, the common case
            // on every fresh window) with a genuine I/O fault (permission denied, disk error) into
            // one silent `nil`, so a real failure froze the status-bar usage with no `log show`
            // trail. Split them: file-absent stays silent, any OTHER error is logged. The contract
            // is unchanged — every failure still returns `nil`, so the caller retains last-known-good.
            let contents: String
            do {
                contents = try String(contentsOf: url, encoding: .utf8)
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                return nil as Snapshot?   // not written yet — expected, not a fault
            } catch {
                // The transcript path can carry an account identifier, and `localizedDescription`
                // embeds the file name, so the interpolated error is `.private` (#22 / #34).
                WindowUsageModel.log.error("transcript read failed: \(error.localizedDescription, privacy: .private)")
                return nil as Snapshot?
            }
            guard let usage = ClaudeUsageReader.parse(transcriptContents: contents)
            else { return nil as Snapshot? }
            // #48: cost is summed over the SAME transcript contents already in hand, so the read
            // stays one FS hit — context is the latest turn's occupancy, cost is every turn.
            let cost = ClaudeUsageReader.sessionCost(transcriptContents: contents)
            return Snapshot(
                contextTokens: usage.contextTokens,
                // #95: derive the window from the model, not a hardcoded default. The transcript's
                // `usage.model` gives the family; the account's settings.json (read off-main here)
                // carries the `[1m]` beta the transcript omits.
                contextMax: ClaudeUsageReader.contextWindow(
                    sessionModel: usage.model,
                    selectedModel: ClaudeUsageReader.selectedModel(inConfigDir: configDir),
                    observedTokens: usage.contextTokens),
                sessionCostUSD: cost.usd,
                hasUnpricedModel: cost.hasUnpricedModel,
                modelID: usage.model,
                effort: usage.effort,
                cliVersion: usage.version,
                gitBranch: usage.gitBranch
            )
        }.value
    }

    /// Display string `<used> / <max>` with k-compaction (mirrors the old StatusBarViewModel format).
    var formatted: String { "\(formatK(contextTokens)) / \(formatK(contextMax))" }

    /// #48: `$X.XX` cost, with a trailing "+?" when a model had no price (the figure is then a
    /// lower bound). Mirrors the old `StatusBarViewModel.sessionCostFormatted` for `$0.00`.
    var sessionCostFormatted: String {
        let base = String(format: "$%.2f", NSDecimalNumber(decimal: sessionCostUSD).doubleValue)
        return hasUnpricedModel ? base + "+?" : base
    }

    /// Point this model at an account's config dir (or `nil` to clear, e.g. no active account).
    /// Re-resolvable — call again when the window's account changes. Idempotent teardown of any
    /// prior watcher.
    func track(configDir: String?) {
        watcher?.stop()
        watcher = nil
        self.configDir = configDir
        // #49 Part 2: a switch will spawn a NEW claude session; clear the previous account's
        // bound session id so the next read resolves to no transcript (#89 — empty, not the old
        // account's numbers) until the terminal re-binds via setSessionId for the new session.
        self.sessionId = nil
        // #47 verify (Codex F1): reset to defaults on EVERY switch so a target account with
        // no transcript / no usage yet never lingers on the PREVIOUS account's tokens.
        contextTokens = 0
        // #95: seed the window from the account's SELECTED model (settings.json `[1m]`) so a fresh
        // 1M account reads 0 / 1M up front, not the hardcoded 200k. settings.json is tiny so this
        // read stays on the main actor; a nil configDir (clearing) uses the plain default.
        contextMax = configDir.map {
            ClaudeUsageReader.contextWindow(
                sessionModel: nil, selectedModel: ClaudeUsageReader.selectedModel(inConfigDir: $0))
        } ?? 200_000
        // #48: same reset-on-switch contract for cost — never linger on the previous session's $.
        sessionCostUSD = 0
        hasUnpricedModel = false
        guard let configDir else { return }
        refresh()
        // #47 verify (Codex F5): watch the account's `.claude` dir itself — it always exists
        // (materialized before spawn), unlike `projects/` which claude creates lazily on the
        // first session. FSEvents is recursive, so this still catches `projects/**/*.jsonl`
        // appends AND the first-ever transcript; `refresh()` re-resolves the newest each fire.
        // FileWatcher only WATCHES the parent of the given path — it never creates the
        // sentinel, so the #34 read-only contract holds.
        let sentinel = configDir + "/.logos-usage-watch"
        let w = makeWatcher(sentinel, 0.5) { [weak self] in self?.refresh() }
        w.start()
        watcher = w
    }

    /// #49 Part 2: bind this window's usage to the exact claude session the terminal just
    /// spawned (reported via `--session-id`). The reader then reads `<sessionId>.jsonl`
    /// directly instead of guessing newest-mtime. Re-resolvable — safe to call again if the
    /// window re-spawns claude with a new id.
    func setSessionId(_ sessionId: String) {
        self.sessionId = sessionId
        guard configDir != nil else { return }
        refresh()
    }

    private func refresh() {
        guard let configDir else { return }
        // Claim the newest generation before the off-main hop. Every terminal assignment
        // below is gated on still owning it, so an older overlapping refresh discarded.
        refreshGeneration += 1
        let generation = refreshGeneration
        let sessionId = self.sessionId
        let read = self.read
        inFlightRefresh = Task { [weak self] in
            let snapshot = await read(configDir, sessionId)
            guard let self else { return }
            // Stale guard: apply only while still the newest refresh AND while the LIVE
            // configDir + sessionId are still the ones this read targeted — comparing the
            // live values at assign time (not just the dispatch-time capture) so a
            // just-switched account or re-bound session is never clobbered by a slow read
            // for the previous one.
            guard generation == self.refreshGeneration,
                  self.configDir == configDir,
                  self.sessionId == sessionId else { return }
            guard let snapshot else { return }
            self.contextTokens = snapshot.contextTokens
            self.contextMax = snapshot.contextMax
            self.modelID = snapshot.modelID
            self.effort = snapshot.effort
            self.cliVersion = snapshot.cliVersion
            self.gitBranch = snapshot.gitBranch
            self.sessionCostUSD = snapshot.sessionCostUSD
            self.hasUnpricedModel = snapshot.hasUnpricedModel
        }
    }

    private func formatK(_ n: Int) -> String {
        if n >= 1_000_000 { return "\(n / 1_000_000)M" }   // #47 verify (Codex): 1M not 1000k
        if n < 1_000 { return "\(n)" }
        return "\(n / 1_000)k"
    }
}
