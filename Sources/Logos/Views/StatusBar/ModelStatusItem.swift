import SwiftUI

/// #116: which model this window's session is running, and at what effort.
///
/// Placement is the user's 2026-08-04 ruling: **immediately left of the context counter**
/// ("在 token 還剩多少的左邊"), with **effort adjacent to the model** ("effort 在 model 旁邊").
/// The CLI version and git branch got their own segment further left — see
/// `SessionEnvironmentStatusItem`.
///
/// The name is rendered the way Claude Code renders it (`Opus 5 (1M)`), not as the raw id.
/// Both halves come from the transcript the context read already parses, so this segment
/// costs no additional filesystem work.
struct ModelStatusItem: View {
    @Environment(WindowUsageModel.self) private var usage

    var body: some View {
        if let name = usage.modelDisplayName {
            HStack(spacing: 5) {
                Image(systemName: "cpu")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(name)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let effort = usage.effort {
                    // Adjacent to the model per the ruling, but visually subordinate: the
                    // model is the identity, effort is a mode of it.
                    Text(effort)
                        .font(.caption2)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(.secondary.opacity(0.12), in: Capsule())
                        .foregroundStyle(.secondary)
                }
            }
            .help(helpText(name))
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityLabel(name))
            .accessibilityIdentifier("logos.statusbar.model")
        }
    }

    private func helpText(_ name: String) -> String {
        var text = "Model running in this window's claude session, read from its transcript."
        if usage.effort != nil {
            text += " The chip is the reasoning effort of the latest turn."
        }
        if usage.contextMax >= 1_000_000 {
            text += " (1M) marks the extended context window."
        }
        return text
    }

    private func accessibilityLabel(_ name: String) -> String {
        usage.effort.map { "Model \(name), effort \($0)" } ?? "Model \(name)"
    }
}

/// #116: the claude CLI version and the git branch it saw — **its own segment, positioned
/// further left** than the model, per the user's ruling ("版本的話，我覺得單獨分隔一個來放，
/// 版本左邊一點比較好").
///
/// Separate from `ModelStatusItem` on purpose: these describe the *environment* the session
/// runs in and change rarely, whereas the model and its effort describe the *current turn*.
/// Keeping them apart is what the ruling asked for and also stops a long branch name from
/// pushing the model off the bar.
struct SessionEnvironmentStatusItem: View {
    @Environment(WindowUsageModel.self) private var usage

    var body: some View {
        if usage.cliVersion != nil || usage.gitBranch != nil {
            HStack(spacing: 6) {
                if let version = usage.cliVersion {
                    HStack(spacing: 3) {
                        Image(systemName: "shippingbox")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(version)
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                if let branch = usage.gitBranch {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(branch)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
            .help("The claude CLI version that wrote this session's latest turn, and the git branch it saw for the project. Both come from the session transcript.")
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityIdentifier("logos.statusbar.sessionEnvironment")
        }
    }

    private var accessibilityLabel: String {
        var parts: [String] = []
        if let version = usage.cliVersion { parts.append("claude version \(version)") }
        if let branch = usage.gitBranch { parts.append("branch \(branch)") }
        return parts.joined(separator: ", ")
    }
}
