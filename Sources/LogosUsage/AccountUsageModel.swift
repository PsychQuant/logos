import Foundation
import Observation
import os
import LogosAccounts

/// Observable per-account view model driving one row of the account list.
///
/// One instance is created per `DiscoveredAccount` and **persisted** by
/// `AccountsModel` (see dataflow guidance: multi-field rows observe a stored
/// `@Observable` instance rather than reaching back into a collection). Its
/// `state` machine is the only mutable UI surface; identity display fields are
/// snapshotted from the account at init and never change.
///
/// `@MainActor` because SwiftUI reads `state` during body evaluation on the
/// main actor; the one blocking call (the synchronous Keychain read) is hopped
/// off-main inside `refresh()`.
@MainActor
@Observable
public final class AccountUsageModel: Identifiable {
    /// The lifecycle of a single account's usage fetch. Distinct terminal
    /// states let the row show a precise message instead of a generic error.
    public enum LoadState: Equatable, Sendable {
        /// Not yet fetched.
        case idle
        /// A fetch is in flight.
        case loading
        /// Usage retrieved. `fetchedAt` stamps the row's "updated at" line.
        case loaded(PlanUsage, fetchedAt: Date)
        /// No credentials in the Keychain (never logged in, or access denied).
        case noCredentials
        /// Token is expired or the endpoint returned 401 — user must re-login.
        /// MultiStats deliberately never refreshes tokens itself.
        case needsLogin
        /// Any other failure (HTTP error, malformed body, transport). Carries a
        /// short human-readable reason.
        case failed(String)
    }

    public let id: String
    public let label: String
    public let email: String?
    public let tier: String?
    public let isDefault: Bool
    /// #55 C3: the launcher registry account id this row corresponds to (nil for
    /// discovery-built rows). The row's own `id` is the config-dir path, so this is
    /// what the usage window compares against `AccountManager.activeAccountId` to
    /// highlight the active selection.
    public let registryAccountId: String?

    public private(set) var state: LoadState = .idle

    /// Monotonic refresh counter (newest-wins ordering). Two `refresh()` calls
    /// on the SAME instance can interleave across their `await` suspension points;
    /// each captures its generation on entry and applies its terminal state only
    /// while still the newest, so a slow in-flight refresh can never overwrite a
    /// newer one. `@ObservationIgnored` — internal bookkeeping, not UI state.
    @ObservationIgnored private var refreshGeneration = 0

    private let account: DiscoveredAccount
    private let credentialsReader: KeychainCredentialsReader
    private let usageClient: UsageClient

    /// #93: diagnosability for the status-bar plan bar — `LogosUsage` was previously silent, so a
    /// blank / re-login plan segment left no `log show` trail. `nonisolated` so it stays reachable
    /// despite the Swift-6 rule that a static on a `@MainActor` type inherits `@MainActor`
    /// isolation (same note as `WindowUsageModel.log`). The account `id` is a config-dir path that
    /// can carry an account identifier, so it is always logged `.private`; the failure `reason` is a
    /// generic `describe()` string (HTTP code / transport) with no secrets, logged `.public`.
    nonisolated private static let log = Logger(subsystem: "app.getlogos.logos", category: "account-usage")

    /// - Parameter labelOverride: display label that wins over the
    ///   identity-derived one — the registry's user-chosen label when the row
    ///   is built from the shared registry.
    /// - Parameter registryAccountId: the launcher registry id (#55 C3); nil for
    ///   discovery-built rows.
    public init(
        account: DiscoveredAccount,
        labelOverride: String? = nil,
        registryAccountId: String? = nil,
        credentialsReader: KeychainCredentialsReader = KeychainCredentialsReader(),
        usageClient: UsageClient = UsageClient()
    ) {
        self.id = account.id
        self.label = labelOverride ?? account.label
        self.email = account.identity?.emailAddress
        self.tier = Self.tier(from: account.identity)
        self.isDefault = account.isDefault
        self.registryAccountId = registryAccountId
        self.account = account
        self.credentialsReader = credentialsReader
        self.usageClient = usageClient
    }

    /// Reads credentials and fetches usage, driving `state` through the
    /// lifecycle. Safe to call repeatedly (manual refresh).
    public func refresh() async {
        // Claim the newest generation before the first suspension. Every terminal
        // assignment below is gated on still owning it, so an older overlapping
        // refresh that resolves later is discarded rather than clobbering.
        refreshGeneration += 1
        let generation = refreshGeneration
        state = .loading

        // The Keychain lookup is synchronous and can block (first access shows a
        // system authorization dialog), so hop it off the main actor. Only the
        // credentials cross back — never logged, never persisted.
        let account = self.account
        let reader = self.credentialsReader
        guard let credentials = await Task.detached(priority: .userInitiated, operation: {
            reader.credentials(for: account)
        }).value else {
            if generation == refreshGeneration {
                state = .noCredentials
                Self.log.notice("usage: no credentials — account=\(self.id, privacy: .private)")
            }
            return
        }

        // Pre-flight the known expiry so an obviously dead token surfaces as a
        // re-login prompt without a doomed round-trip. Unknown expiry falls
        // through and lets the endpoint's 401 decide.
        if credentials.isExpired(asOf: Date()) {
            if generation == refreshGeneration {
                state = .needsLogin
                Self.log.notice("usage: stored token expired → needsLogin — account=\(self.id, privacy: .private)")
            }
            return
        }

        do {
            let usage = try await usageClient.fetchUsage(accessToken: credentials.accessToken)
            if generation == refreshGeneration {
                state = .loaded(usage, fetchedAt: Date())
                Self.log.info("usage: loaded \(usage.windows.count) window(s) — account=\(self.id, privacy: .private)")
            }
        } catch UsageError.unauthorized {
            if generation == refreshGeneration {
                state = .needsLogin
                Self.log.notice("usage: 401 unauthorized → needsLogin — account=\(self.id, privacy: .private)")
            }
        } catch {
            if generation == refreshGeneration {
                state = .failed(Self.describe(error))
                Self.log.error("usage: fetch failed — account=\(self.id, privacy: .private) reason=\(Self.describe(error), privacy: .public)")
            }
        }
    }

    /// Picks the most specific rate-limit tier the config exposes for display.
    static func tier(from identity: AccountIdentity?) -> String? {
        identity?.userRateLimitTier
            ?? identity?.seatTier
            ?? identity?.organizationRateLimitTier
    }

    /// Maps a fetch error to a short zh-Hant reason for the failed state.
    static func describe(_ error: Error) -> String {
        switch error {
        case UsageError.http(let code): return "伺服器錯誤（HTTP \(code)）"
        case UsageError.malformed: return "回應格式無法解析"
        case UsageError.transport: return "連線失敗"
        case UsageError.unauthorized: return "憑證已過期，請重新登入"
        default: return "未知錯誤"
        }
    }
}

/// Top-level model: discovers accounts and owns the persisted per-account
/// models. `ContentView` holds one via `@State`.
@MainActor
@Observable
public final class AccountsModel {
    public private(set) var accounts: [AccountUsageModel] = []

    private let home: URL
    /// Read-only registry used to overlay user-chosen labels onto discovered
    /// convention accounts ("registry labels applied when the shared index
    /// file exists"). nil → derived labels only. NEVER mutated here — the
    /// standalone viewer performs no registry writes.
    @ObservationIgnored private let labelRegistry: AccountRegistry?
    /// Injected per-account model factory (account, registryLabel?) — the seam
    /// that lets tests route stub keychains/fetchers per account while
    /// discovery stays real.
    @ObservationIgnored private let makeModel: @MainActor (DiscoveredAccount, String?) -> AccountUsageModel

    public init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        labelRegistry: AccountRegistry? = nil,
        makeModel: @escaping @MainActor (DiscoveredAccount, String?) -> AccountUsageModel = {
            AccountUsageModel(account: $0, labelOverride: $1)
        }
    ) {
        self.home = home
        self.labelRegistry = labelRegistry
        self.makeModel = makeModel
    }

    /// Discovers accounts on disk and builds one persisted model each. Existing
    /// models are replaced (discovery is cheap and idempotent). A convention
    /// account whose directory name matches a registry id takes the registry's
    /// label; the default account never does (it is not a registry entry).
    public func load() {
        let labelsById = Dictionary(
            (labelRegistry?.accounts ?? []).map { ($0.id, $0.label) },
            uniquingKeysWith: { first, _ in first })
        // #55 C2: the discovered default (`~/.claude`) row is the launcher's
        // system-default ("Main") account — surface its registry label so the viewer
        // shows it under the launcher identity, not a derived/nil label. nil when the
        // registry has no system-default entry (backward-compatible).
        let systemDefaultLabel = labelRegistry?.accounts.first(where: { $0.isSystemDefault })?.label
        accounts = AccountDiscovery.discover(home: home).map { discovered in
            let dirName = discovered.configDir.deletingLastPathComponent().lastPathComponent
            let label = discovered.isDefault ? systemDefaultLabel : labelsById[dirName]
            return makeModel(discovered, label)
        }
    }

    /// Once the first full pass has completed, later refreshes fan out
    /// concurrently. Session-volatile by design: authorization is per-launch
    /// state, so a fresh process serializes once again.
    @ObservationIgnored private var hasCompletedFirstPass = false

    /// Coalesces overlapping `refreshAll()` callers onto one shared pass and
    /// cancels that pass when its last observer goes away — two serialized first
    /// passes would interleave and re-stack the per-account authorization dialogs
    /// the serialization exists to prevent (#51), while a window-close must not
    /// leave the in-flight fetches running unwatched (#81).
    @ObservationIgnored private let refreshCoalescer = RefreshCoalescer()

    /// Refreshes every account's usage — first pass serialized, later passes
    /// concurrent (see `UsageRefresh`). Concurrent invocations coalesce onto the
    /// one in-flight pass; if every caller's window closes, the pass is cancelled
    /// rather than run to completion in the background (#81).
    public func refreshAll() async {
        let accounts = self.accounts
        let serialized = !hasCompletedFirstPass
        let finishedCleanly = await refreshCoalescer.run {
            await UsageRefresh.run(accounts, serialized: serialized)
        }
        // Only a pass that ran to completion counts as the first pass; a cancelled
        // first pass must re-serialize next time so it never stacks dialogs (#51).
        if finishedCleanly { hasCompletedFirstPass = true }
    }
}

/// Shared refresh discipline for every multi-account usage surface
/// ("First authorization pass serializes Keychain reads"): the FIRST pass
/// after launch runs accounts one at a time — each refresh performs a
/// synchronous Keychain read that can raise a macOS authorization dialog, and
/// a concurrent first pass stacks N dialogs at once. Later passes (items
/// already authorized) fan out concurrently.
@MainActor
enum UsageRefresh {
    static func run(_ accounts: [AccountUsageModel], serialized: Bool) async {
        if serialized {
            for account in accounts {
                await account.refresh()
            }
        } else {
            await withTaskGroup(of: Void.self) { group in
                for account in accounts {
                    group.addTask { await account.refresh() }
                }
            }
        }
    }
}
