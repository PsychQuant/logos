import Foundation
import Observation
import SwiftUI

/// Status bar display state. Placeholders in sub-plan A;
/// future sub-plans wire real data:
///   - accountName ← sub-plan E (multi-account)
///   - sessionCost ← sub-plan D parsing claude output
///   - autoHandleStatus ← sub-plan D auto-handle decision engine
///   - tokensUsed / tokensMax ← sub-plan D parsing claude output
@Observable
@MainActor
public final class StatusBarViewModel {

    public enum AutoHandleStatus: String, CaseIterable, Sendable {
        case armed
        case partial
        case disabled

        public var label: String {
            switch self {
            case .armed: "auto-handle: armed"
            case .partial: "auto-handle: partial"
            case .disabled: "auto-handle: disabled"
            }
        }

        public var color: Color {
            switch self {
            case .armed: .green
            case .partial: .yellow
            case .disabled: .red
            }
        }
    }

    public var accountName: String = "personal"
    public var sessionCostUSD: Decimal = 0
    public var autoHandleStatus: AutoHandleStatus = .armed
    // #47: `tokensUsed` / `tokensMax` are now DEAD for the status bar — token/context usage
    // moved to the per-window `WindowUsageModel` (real data from the account's session
    // transcript). Kept only so `tokenUsageFormatted` still compiles; no view reads them.
    public var tokensUsed: Int = 0
    public var tokensMax: Int = 200_000

    public init() {}

    public var sessionCostFormatted: String {
        String(format: "$%.2f", NSDecimalNumber(decimal: sessionCostUSD).doubleValue)
    }

    public var tokenUsageFormatted: String {
        "\(formatK(tokensUsed)) / \(formatK(tokensMax))"
    }

    private func formatK(_ n: Int) -> String {
        if n < 1_000 { return "\(n)" }
        let k = n / 1_000
        return "\(k)k"
    }
}
