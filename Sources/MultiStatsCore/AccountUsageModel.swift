import Foundation
import Observation

/// Observable per-account view model driving one row of the account list.
///
/// One instance is created per discovered `Account` and **persisted** by
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

    public private(set) var state: LoadState = .idle

    private let account: Account
    private let credentialsReader: KeychainCredentialsReader
    private let usageClient: UsageClient

    public init(
        account: Account,
        credentialsReader: KeychainCredentialsReader = KeychainCredentialsReader(),
        usageClient: UsageClient = UsageClient()
    ) {
        self.id = account.id
        self.label = account.label
        self.email = account.identity?.emailAddress
        self.tier = Self.tier(from: account.identity)
        self.isDefault = account.isDefault
        self.account = account
        self.credentialsReader = credentialsReader
        self.usageClient = usageClient
    }

    /// Reads credentials and fetches usage, driving `state` through the
    /// lifecycle. Safe to call repeatedly (manual refresh).
    public func refresh() async {
        state = .loading

        // The Keychain lookup is synchronous and can block (first access shows a
        // system authorization dialog), so hop it off the main actor. Only the
        // credentials cross back — never logged, never persisted.
        let account = self.account
        let reader = self.credentialsReader
        guard let credentials = await Task.detached(priority: .userInitiated, operation: {
            reader.credentials(for: account)
        }).value else {
            state = .noCredentials
            return
        }

        // Pre-flight the known expiry so an obviously dead token surfaces as a
        // re-login prompt without a doomed round-trip. Unknown expiry falls
        // through and lets the endpoint's 401 decide.
        if credentials.isExpired(asOf: Date()) {
            state = .needsLogin
            return
        }

        do {
            let usage = try await usageClient.fetchUsage(accessToken: credentials.accessToken)
            state = .loaded(usage, fetchedAt: Date())
        } catch UsageError.unauthorized {
            state = .needsLogin
        } catch {
            state = .failed(Self.describe(error))
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

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home
    }

    /// Discovers accounts on disk and builds one persisted model each. Existing
    /// models are replaced (discovery is cheap and idempotent).
    public func load() {
        accounts = AccountDiscovery.discover(home: home).map { AccountUsageModel(account: $0) }
    }

    /// Refreshes every account's usage concurrently.
    public func refreshAll() async {
        await withTaskGroup(of: Void.self) { group in
            for account in accounts {
                group.addTask { await account.refresh() }
            }
        }
    }
}
