import SwiftUI

struct AccountRow: View {
    let account: Account
    let isActive: Bool
    /// Whether this account has no credential yet for its own config dir (#12).
    /// Surfaced as a non-blocking indicator that directs the user to `claude login`.
    let needsReauth: Bool
    let onSelect: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack {
            Image(systemName: isActive ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(isActive ? Color.accentColor : .secondary)
            Text(account.label)
                .font(.body)
                .fontWeight(isActive ? .semibold : .regular)
            if needsReauth {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help("Needs login — run `claude login` in this account's terminal session to authenticate it.")
                    .accessibilityLabel("Needs login")
            }
            Spacer()
            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
            .opacity(0.6)
        }
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .accessibilityIdentifier("logos.account.row")  // #24 XCUITest query (all rows share; tap a non-active one)
    }
}
