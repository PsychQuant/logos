import Foundation
import Observation

@Observable
@MainActor
public final class AutoHandleEngine {

    @ObservationIgnored private let rules: [AutoHandleRule]
    @ObservationIgnored private var lastFiredAt: [String: Date] = [:]
    @ObservationIgnored private var fireHistory: [String: [Date]] = [:]
    @ObservationIgnored private let persistence: SettingsPersistence?
    private static let filename = "autohandle.json"

    public private(set) var disabledRuleIDs: Set<String> = []
    public private(set) var lastFiredRule: AutoHandleRule?

    public init(
        rules: [AutoHandleRule] = AutoHandleRule.defaultRuleset,
        persistence: SettingsPersistence? = SettingsPersistence()
    ) {
        self.rules = rules
        self.persistence = persistence
        if let p = persistence,
           let dto: PersistedDTO = try? p.load(from: Self.filename) {
            self.disabledRuleIDs = Set(dto.disabledRuleIDs)
        }
    }

    /// Process a new chunk of PTY output. Returns bytes to inject back
    /// into the PTY stdin (or nil if no rule fires).
    public func processChunk(_ text: String) -> [UInt8]? {
        let now = Date()
        for rule in rules where !disabledRuleIDs.contains(rule.id) {
            guard rule.matches(text) else { continue }
            // Cooldown check
            if let last = lastFiredAt[rule.id], now.timeIntervalSince(last) < rule.cooldown {
                continue
            }
            // Record fire
            lastFiredAt[rule.id] = now
            fireHistory[rule.id, default: []].append(now)
            // Prune fire history older than 30s
            fireHistory[rule.id] = fireHistory[rule.id]?.filter { now.timeIntervalSince($0) < 30 }
            // Runaway check: 3+ fires within 30s → transient disable (NOT persisted)
            if (fireHistory[rule.id]?.count ?? 0) >= 3 {
                disabledRuleIDs.insert(rule.id)
                // Intentionally no save here — runaway disables reset on relaunch
            }
            lastFiredRule = rule
            return rule.responseBytes
        }
        return nil
    }

    /// User-initiated disable. Persists across launches.
    public func disableRule(id: String) {
        disabledRuleIDs.insert(id)
        saveUserToggleState()
    }

    /// User-initiated enable. Persists across launches.
    public func enableRule(id: String) {
        disabledRuleIDs.remove(id)
        saveUserToggleState()
    }

    public var rulesCount: Int { rules.count }

    /// Derived: armed if all rules active; partial if some disabled; disabled if all disabled.
    public var currentStatus: StatusBarViewModel.AutoHandleStatus {
        if disabledRuleIDs.isEmpty {
            return .armed
        } else if disabledRuleIDs.count == rules.count {
            return .disabled
        } else {
            return .partial
        }
    }

    private func saveUserToggleState() {
        let dto = PersistedDTO(disabledRuleIDs: Array(disabledRuleIDs).sorted())
        try? persistence?.save(dto, to: Self.filename)
    }

    private struct PersistedDTO: Codable {
        let disabledRuleIDs: [String]
    }
}
