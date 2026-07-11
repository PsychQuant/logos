import Observation
import Foundation
import os

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

    @ObservationIgnored private var configDir: String?
    @ObservationIgnored private var watcher: FileWatcher?

    /// #49 Part 2: the id of the claude session this window spawned (via `--session-id`),
    /// or nil before the terminal reports one / for a session started without an id. The
    /// reader binds to `<sessionId>.jsonl` directly when set, and falls back to newest-mtime
    /// when nil — so several sessions sharing one config dir never cross-read each other.
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
    }

    /// Off-main read + parse seam. Given the account's config dir and the bound session id
    /// (nil → newest-mtime fallback), returns the parsed snapshot (or `nil` when there is no
    /// transcript / no usage yet). The production default hops the blocking filesystem read
    /// off the main actor; tests inject a controllable reader to make the newest-wins
    /// ordering deterministic.
    typealias Reader = @Sendable (String, String?) async -> Snapshot?

    @ObservationIgnored private let read: Reader

    init(read: @escaping Reader = WindowUsageModel.defaultRead) {
        self.read = read
    }

    /// #83: nonisolated so `defaultRead`'s detached read can log from off the main actor. A
    /// `Logger` is `Sendable`, and the CI-strict rule that a static on a `@MainActor` type
    /// inherits `@MainActor` isolation would otherwise make it main-actor-only (see the
    /// `swift6-mainactor-static-inheritance-ci-skew` note) — `nonisolated` keeps it reachable
    /// from the detached task.
    nonisolated private static let log = Logger(subsystem: "app.getlogos.logos", category: "window-usage")

    /// Production reader: resolve the session's transcript (id-addressed when a session id is
    /// bound, else newest-mtime) and parse it entirely off the main actor (FS enumerate +
    /// full-file read + per-line JSON parse). Read-only over claude's own transcript tree —
    /// never credentials / keychain (#34).
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
                contextMax: ClaudeUsageReader.contextMax(forModel: usage.model, observedTokens: usage.contextTokens),
                sessionCostUSD: cost.usd,
                hasUnpricedModel: cost.hasUnpricedModel
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
        // bound session id so the fallback read never targets its transcript. The terminal
        // re-binds via setSessionId once the new session spawns.
        self.sessionId = nil
        // #47 verify (Codex F1): reset to defaults on EVERY switch so a target account with
        // no transcript / no usage yet never lingers on the PREVIOUS account's tokens.
        contextTokens = 0
        contextMax = 200_000
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
        let w = FileWatcher(path: sentinel, debounce: 0.5) { [weak self] in self?.refresh() }
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
