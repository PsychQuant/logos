import Foundation
import Observation
import LogosAccounts

/// Feeds the shared `AccountRegistry` into per-account usage models — the
/// Logos usage window's model. Consumer, not discoverer (design Decision 6):
/// no filesystem scan; the registry's list IS the window's list, so the window
/// always matches Settings → Accounts and discovery-vs-registry drift is
/// impossible in-app.
///
/// Isolated registry accounts are convention accounts under the accounts root,
/// so their Keychain lookup uses a hash-suffixed service name. The **one**
/// exception (#55) is the system-default ("Main") account (#54): it reuses the
/// system `~/.claude`, so its row is built `isDefault: true` and its lookup
/// READS the bare `Claude Code-credentials` entry — read-only, to display Main's
/// plan usage. The bare entry is never mutated here (account-credential-isolation
/// spec: the read-only usage target may read, never write/delete).
@MainActor
@Observable
public final class RegistryUsageModel {
    public private(set) var accounts: [AccountUsageModel] = []

    @ObservationIgnored private let registry: AccountRegistry
    /// Injected factory (account, registryLabel) → row model; the test seam
    /// for stub keychains/fetchers. The registry label wins over any
    /// identity-derived label.
    /// Factory (account, registryLabel, registryAccountId) → row model. #55 C3: the
    /// registry id is threaded so the usage window can highlight the active selection
    /// (the row's own id is a config-dir path, not the registry id).
    @ObservationIgnored private let makeModel: @MainActor (DiscoveredAccount, String, String) -> AccountUsageModel
    @ObservationIgnored private var hasCompletedFirstPass = false

    public init(
        registry: AccountRegistry,
        makeModel: @escaping @MainActor (DiscoveredAccount, String, String) -> AccountUsageModel = {
            AccountUsageModel(account: $0, labelOverride: $1, registryAccountId: $2)
        }
    ) {
        self.registry = registry
        self.makeModel = makeModel
    }

    /// Rebuilds the row models from the registry's current list. Cheap and
    /// idempotent — call on window open and after registry mutations.
    public func load() {
        accounts = registry.accounts.map { entry in
            // #55 C1: the system-default ("Main") account reuses ~/.claude — build its
            // row against the real config dir with isDefault:true so the keychain
            // lookup hits the bare `Claude Code-credentials` (isDefault gates the
            // service name). Isolated accounts keep their per-account dir + hash-suffix.
            let configDir = URL(fileURLWithPath: entry.usageConfigDir)
            let discovered = DiscoveredAccount(
                configDir: configDir,
                isDefault: entry.isSystemDefault,
                identity: ConfigParser.identity(forConfigDir: configDir))
            return makeModel(discovered, entry.label, entry.id)
        }
    }

    /// First pass serialized (authorization dialogs must not stack), later
    /// passes concurrent — same discipline as `AccountsModel`.
    public func refreshAll() async {
        await UsageRefresh.run(accounts, serialized: !hasCompletedFirstPass)
        hasCompletedFirstPass = true
    }
}
