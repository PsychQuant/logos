import SwiftUI
import LogosUsage

/// #93: the distinct display states of the plan-usage HUD segment, so every non-loaded state is
/// legible instead of collapsing into a bare "—". Pure mapping over `AccountUsageModel.LoadState`
/// (nil = no matching account row) so it unit-tests directly; the view is a thin adapter.
enum PlanUsageGlyph: Equatable {
    case bars           // loaded, ≥1 window → render the HUD bars
    case empty          // loaded, but the endpoint exposed no known windows
    case loading        // idle / fetch in flight
    case needsLogin     // token expired / 401 — Logos reads read-only, so re-login is the fix
    case noCredentials  // no Keychain entry (never logged in / access denied)
    case failed         // other fetch failure (HTTP / transport / malformed)
    case unknown        // no account row matched this window's account

    static func from(_ state: AccountUsageModel.LoadState?) -> PlanUsageGlyph {
        switch state {
        case .none: return .unknown
        case .idle, .loading: return .loading
        case let .loaded(usage, _): return usage.windows.isEmpty ? .empty : .bars
        case .noCredentials: return .noCredentials
        case .needsLogin: return .needsLogin
        case .failed: return .failed
        }
    }
}

/// #90/#93/#94: the plan-usage (rate-limit) HUD segment.
///
/// Shows THIS WINDOW's account's plan windows — the 5-hour session bar plus the weekly (`seven_day`)
/// bar (#94; both are already decoded by `UsageClient`) — as green→yellow→red `HUDProgressBar`s
/// when loaded, and a precise status indicator (讀取中 / 登入 / 未登入 / 用量錯誤) for every other
/// state (#93), never a bare "—" that hides which state it's in. Same plan budget the 帳號用量
/// window renders (`AccountUsageSection`), mirrored compactly for the one-line status bar.
///
/// Keyed to THIS WINDOW's account (`WindowAccountSelection.accountId`), consistent with the
/// account-label + context segments. Logos reads usage **read-only and never refreshes tokens**
/// (the RedLineScope guarantee), so an expired token surfaces here as a re-login hint rather than
/// silent blankness — the honest answer to "why is it blank / can we get the status".
/// Refresh is event-driven (appear + account switch) and coalesces with the usage window's own
/// refresh through the shared `RefreshCoalescer` (#51), so it never stacks a second keychain dialog.
struct PlanUsageStatusItem: View {
    @Environment(RegistryUsageModel.self) private var registryUsage
    @Environment(WindowAccountSelection.self) private var windowSelection

    /// This window's account's usage row (state + all windows), or nil while the window has no
    /// account / it isn't in the registry list yet.
    private var accountModel: AccountUsageModel? {
        guard let accountId = windowSelection.accountId else { return nil }
        return registryUsage.accounts.first { $0.registryAccountId == accountId }
    }

    /// The loaded windows (5h, weekly, …) in endpoint order, or empty for any non-loaded state.
    private var loadedWindows: [UsageWindow] {
        if case let .loaded(usage, _)? = accountModel?.state { return usage.windows }
        return []
    }

    var body: some View {
        content
            .help(helpText)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityIdentifier("logos.statusbar.planUsage")
            .task {
                // Consumer, not discoverer: populate the rows once (shared with the usage window),
                // then fetch. `refreshAll()` coalesces with any concurrent refresh — one fetch, one
                // keychain dialog (#51).
                if registryUsage.accounts.isEmpty { registryUsage.load() }
                await registryUsage.refreshAll()
            }
            .onChange(of: windowSelection.accountId) {
                // This window's account changed — re-fetch so the bars reflect that account. Event-
                // driven only; no periodic poll (the budget changes slowly, the endpoint is limited).
                Task { await registryUsage.refreshAll() }
            }
    }

    @ViewBuilder
    private var content: some View {
        switch PlanUsageGlyph.from(accountModel?.state) {
        case .bars:
            HStack(spacing: 8) {
                Image(systemName: "hourglass").font(.caption2).foregroundStyle(.secondary)
                ForEach(loadedWindows) { window in
                    HStack(spacing: 4) {
                        Text("\(Self.abbrev(window)) \(window.utilizationPercent)%")
                            .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        HUDProgressBar(fraction: window.utilizationFraction, width: 32)
                    }
                }
            }
        case .empty:
            segment("沒有用量視窗", "hourglass", .secondary)
        case .loading:
            HStack(spacing: 5) {
                Image(systemName: "hourglass").font(.caption2).foregroundStyle(.secondary)
                ProgressView().controlSize(.mini)
            }
        case .needsLogin:
            segment("登入", "exclamationmark.triangle.fill", .orange)
        case .noCredentials:
            segment("未登入", "key.slash", .orange)
        case .failed:
            segment("用量錯誤", "exclamationmark.octagon.fill", .red)
        case .unknown:
            segment("5h · —", "hourglass", .secondary)
        }
    }

    /// A compact icon + caption for the non-bar states.
    private func segment(_ text: String, _ systemImage: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage).font(.caption2)
            Text(text).font(.caption).monospacedDigit()
        }
        .foregroundStyle(color)
    }

    /// Abbreviated window label for the width-constrained status bar.
    private static func abbrev(_ window: UsageWindow) -> String {
        switch window.id {
        case "five_hour": return "5h"
        case "seven_day": return "7d"
        default:
            // #94: per-model weekly ids are "weekly_scoped:<model>" → show just the model name
            // (the full "每週（<model>）" label is in the tooltip + the 帳號用量 window).
            if window.id.hasPrefix("weekly_scoped:") {
                return String(window.id.dropFirst("weekly_scoped:".count))
            }
            return window.label
        }
    }

    private var helpText: String {
        switch PlanUsageGlyph.from(accountModel?.state) {
        case .bars, .empty, .unknown:
            return "This window's account's plan usage — 5-hour session + weekly windows, from the same source as the 帳號用量 window. Green under 70% used, yellow 70–90%, red above 90%. Refreshes on open and on account switch."
        case .loading:
            return "Fetching the account's plan usage…"
        case .needsLogin:
            return "The account's stored token is expired. Logos reads usage read-only and never refreshes tokens, so re-login to this account (in its terminal) to restore the usage readout."
        case .noCredentials:
            return "No credentials found for this account (not logged in, or Keychain access denied)."
        case .failed:
            return "The plan-usage fetch failed. See the unified log (subsystem app.getlogos.logos, category account-usage) for details."
        }
    }

    private var accessibilityLabel: String {
        switch PlanUsageGlyph.from(accountModel?.state) {
        case .bars:
            let parts = loadedWindows.map { "\(Self.abbrev($0)) \($0.utilizationPercent) percent" }
            return "Plan usage: " + parts.joined(separator: ", ")
        case .empty: return "Plan usage: no windows"
        case .loading: return "Plan usage: loading"
        case .needsLogin: return "Plan usage: needs login"
        case .noCredentials: return "Plan usage: no credentials"
        case .failed: return "Plan usage: fetch failed"
        case .unknown: return "Plan usage: unavailable"
        }
    }
}
