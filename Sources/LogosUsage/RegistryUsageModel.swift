import Foundation
import Observation
import LogosAccounts

/// Feeds the shared `AccountRegistry` into per-account usage models — the
/// Logos usage window's model. Consumer, not discoverer (design Decision 6):
/// no filesystem scan; the registry's list IS the window's list, so the window
/// always matches Settings → Accounts and discovery-vs-registry drift is
/// impossible in-app.
///
/// Registry accounts are convention accounts under the accounts root, never
/// the bare default `~/.claude` — so every Keychain lookup this model triggers
/// uses a hash-suffixed service name and the bare `Claude Code-credentials`
/// entry is structurally out of reach.
@MainActor
@Observable
public final class RegistryUsageModel {
    public private(set) var accounts: [AccountUsageModel] = []

    @ObservationIgnored private let registry: AccountRegistry
    /// Injected factory (account, registryLabel) → row model; the test seam
    /// for stub keychains/fetchers. The registry label wins over any
    /// identity-derived label.
    @ObservationIgnored private let makeModel: @MainActor (DiscoveredAccount, String) -> AccountUsageModel
    @ObservationIgnored private var hasCompletedFirstPass = false

    public init(
        registry: AccountRegistry,
        makeModel: @escaping @MainActor (DiscoveredAccount, String) -> AccountUsageModel = {
            AccountUsageModel(account: $0, labelOverride: $1)
        }
    ) {
        self.registry = registry
        self.makeModel = makeModel
    }

    /// Rebuilds the row models from the registry's current list. Cheap and
    /// idempotent — call on window open and after registry mutations.
    public func load() {
        accounts = registry.accounts.map { entry in
            let configDir = URL(fileURLWithPath: entry.configDirPath)
            let discovered = DiscoveredAccount(
                configDir: configDir,
                isDefault: false,
                identity: ConfigParser.identity(forConfigDir: configDir))
            return makeModel(discovered, entry.label)
        }
    }

    /// First pass serialized (authorization dialogs must not stack), later
    /// passes concurrent — same discipline as `AccountsModel`.
    public func refreshAll() async {
        await UsageRefresh.run(accounts, serialized: !hasCompletedFirstPass)
        hasCompletedFirstPass = true
    }
}
