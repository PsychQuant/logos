import SwiftUI
import LogoSwitch

struct AccountRow: View {
    let account: Account
    let isActive: Bool
    /// Whether this account currently reads as unauthenticated (#12/#31). A
    /// non-blocking indicator only — the user signs in the way they would in any
    /// terminal: switch to the account and run `/login` in the hosted claude
    /// (claude opens its own browser). Logos never drives the login itself.
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
                    .help("Needs login — switch to this account and run /login in the terminal; claude opens your browser to sign in.")
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
