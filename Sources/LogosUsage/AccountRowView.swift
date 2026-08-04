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
    /// #111: how many open windows are currently using this account — 0 means no chip.
    ///
    /// A COUNT, not a flag. The account is per-window (#42) while 帳號用量 is a single
    /// window, so "使用中" is only meaningful as a cross-window aggregate; the user's
    /// 2026-08-04 ruling is to mark every in-use account with its window count, because
    /// the rate-limit-rotation case needs "which accounts am I burning at once" rather
    /// than one marker that jumps around.
    ///
    /// Replaces the pre-#111 `isActive`, which compared against
    /// `AccountManager.activeAccountId` — a value #42 demoted to a new-window seed that
    /// an in-window switch never writes, so the chip could never move.
    public let activeWindowCount: Int

    public init(account: AccountUsageModel, activeWindowCount: Int = 0) {
        self.account = account
        self.activeWindowCount = activeWindowCount
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            AccountHeader(
                label: account.label,
                email: account.email,
                tier: account.tier,
                isDefault: account.isDefault,
                activeWindowCount: activeWindowCount)
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
    /// #111: open windows currently using this account (0 = none, so no 使用中 chip).
    var activeWindowCount: Int = 0

    /// The 使用中 chip's text. A single window reads plainly; two or more carry the count,
    /// which is the whole reason this is an Int (#111).
    ///
    /// Returns `Text`, not `String` (#111 verify, codex MEDIUM): building a plain `String`
    /// first and handing it to `Text` takes the verbatim path, which no longer registers
    /// as a localizable resource — so word order, plural rules and number formatting would
    /// all become untranslatable. Keeping the literal inside `Text` preserves that.
    private var activeChipText: Text {
        activeWindowCount == 1 ? Text("使用中") : Text("使用中 ×\(activeWindowCount)")
    }

    /// Spoken form of the chip. `使用中 ×2` would otherwise be read as "使用中 乘 2" —
    /// a multiplication, not a window count (#111 diagnosis Residue).
    ///
    /// The count is spoken at EVERY positive value, including 1 (#111 verify, codex
    /// MEDIUM). The visual chip can drop it at 1 because there is no `×` to misread, but
    /// a VoiceOver user gets no other way to hear how many windows hold the account, and
    /// "why does one read differently" is a worse inconsistency than one extra word.
    private var activeChipAccessibilityLabel: Text {
        Text("使用中，\(activeWindowCount) 個視窗")
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(label)
                        .font(.headline)
                        .fontWeight(activeWindowCount > 0 ? .semibold : .regular)
                    if activeWindowCount > 0 {
                        activeChipText
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.18), in: Capsule())
                            .accessibilityLabel(activeChipAccessibilityLabel)
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
