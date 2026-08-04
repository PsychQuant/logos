import SwiftUI

/// One account's row: identity header + usage/status section.
///
/// The row takes the persisted `@Observable` model (multi-field row → observe
/// the instance, per dataflow guidance) and hands each subview only the plain
/// values it reads, so a change to one account's `state` invalidates just that
/// row's usage section. The body is a single `VStack` (unary row) so `List` can
/// template it efficiently.
public struct UsageAccountRow: View {
    public let account: AccountUsageModel
    /// #55 C3: this row is the launcher's active/seed selection.
    public let isActive: Bool

    public init(account: AccountUsageModel, isActive: Bool = false) {
        self.account = account
        self.isActive = isActive
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            AccountHeader(
                label: account.label,
                email: account.email,
                tier: account.tier,
                isDefault: account.isDefault,
                isActive: isActive)
            AccountUsageSection(state: account.state)
        }
        .padding(.vertical, 4)
    }
}

/// Account name, optional email, default badge, and rate-limit tier chip.
struct AccountHeader: View {
    let label: String
    let email: String?
    let tier: String?
    let isDefault: Bool
    /// #55 C3: launcher active-selection highlight (mirrors the switcher's AccountRow).
    var isActive: Bool = false

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(label)
                        .font(.headline)
                        .fontWeight(isActive ? .semibold : .regular)
                    if isActive {
                        Text("使用中")
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.18), in: Capsule())
                    }
                    if isDefault {
                        Text("預設")
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.tint.opacity(0.15), in: Capsule())
                    }
                }
                if let email, email != label {
                    Text(email).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let tier {
                Text(tier)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(.secondary.opacity(0.12), in: Capsule())
            }
        }
    }
}

/// Renders the current fetch state: progress, the usage bars, or a precise
/// status message per terminal state.
struct AccountUsageSection: View {
    let state: AccountUsageModel.LoadState

    var body: some View {
        switch state {
        case .idle, .loading:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("讀取中…").font(.caption).foregroundStyle(.secondary)
            }
        case let .loaded(usage, fetchedAt):
            if usage.windows.isEmpty {
                Text("目前沒有可顯示的用量視窗")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(usage.windows) { window in
                        UsageBar(window: window)
                    }
                    Text("更新於 \(fetchedAt, format: .dateTime.hour().minute().second())")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
        case .noCredentials:
            StatusLine(
                text: "找不到憑證（未登入，或 Keychain 存取被拒）",
                systemImage: "key.slash", color: .orange)
        case .needsLogin:
            StatusLine(
                text: "憑證已過期，請重新登入該帳號",
                systemImage: "exclamationmark.triangle", color: .orange)
        case let .failed(message):
            StatusLine(text: message, systemImage: "xmark.octagon", color: .red)
        }
    }
}

/// A single consumed-quota bar for one usage window (session / weekly).
///
/// #110: consumed-oriented, matching claude.ai's own "N% used" plan-usage rows
/// and the status bar's `HUDProgressBar` — the fill grows as quota is spent and
/// the colour comes from the shared `UsageLevel` bands. It used to render the
/// remaining side with its own inverted thresholds, so the same account read as
/// a nearly-full red bar in the status bar and a nearly-empty red bar here.
/// Takes the whole `UsageWindow` rather than pre-split numbers: the label, the
/// fill, and the colour band are then three projections of ONE clamped value, so
/// a row showing "130% 已用" beside a bar pinned at full — or a label that traps
/// on a non-finite reading — is unrepresentable (#110 verify, codex MEDIUM ×2).
struct UsageBar: View {
    let window: UsageWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(window.label).font(.caption).fontWeight(.medium)
                Spacer()
                Text("\(window.utilizationPercent)% 已用")
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            ProgressView(value: window.utilizationFraction, total: 1)
                .tint(UsageLevel(fraction: window.utilizationFraction).color)
            if let resetsAt = window.resetsAt {
                Text("重置於 \(resetsAt, format: .dateTime.month().day().hour().minute())")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }
}

/// Icon + message line used for every non-loaded terminal state.
struct StatusLine: View {
    let text: String
    let systemImage: String
    let color: Color

    var body: some View {
        Label {
            Text(text).font(.caption)
        } icon: {
            Image(systemName: systemImage).foregroundStyle(color)
        }
    }
}
