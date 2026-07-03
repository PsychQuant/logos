import SwiftUI
import MultiStatsCore

/// One account's row: identity header + usage/status section.
///
/// The row takes the persisted `@Observable` model (multi-field row → observe
/// the instance, per dataflow guidance) and hands each subview only the plain
/// values it reads, so a change to one account's `state` invalidates just that
/// row's usage section. The body is a single `VStack` (unary row) so `List` can
/// template it efficiently.
struct AccountRow: View {
    let account: AccountUsageModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            AccountHeader(
                label: account.label,
                email: account.email,
                tier: account.tier,
                isDefault: account.isDefault)
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

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(label).font(.headline)
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
                        UsageBar(
                            label: window.label,
                            percentRemaining: window.percentRemaining,
                            resetsAt: window.resetsAt)
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

/// A single remaining-quota bar for one usage window (session / weekly).
struct UsageBar: View {
    let label: String
    let percentRemaining: Double // 0–100
    let resetsAt: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label).font(.caption).fontWeight(.medium)
                Spacer()
                Text("\(Int(percentRemaining.rounded()))% 剩餘")
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            ProgressView(value: percentRemaining, total: 100)
                .tint(barColor)
            if let resetsAt {
                Text("重置於 \(resetsAt, format: .dateTime.month().day().hour().minute())")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    private var barColor: Color {
        switch percentRemaining {
        case ..<10: .red
        case ..<25: .orange
        default: .green
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
