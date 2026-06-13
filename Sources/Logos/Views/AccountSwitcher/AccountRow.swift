import SwiftUI
import LogoSwitch

struct AccountRow: View {
    let account: Account
    let isActive: Bool
    /// Whether this account has no credential yet for its own config dir (#12) —
    /// surfaced as a "Sign in" affordance that runs `claude auth login`.
    let needsReauth: Bool
    /// A `claude auth login` is in flight for this account (#34).
    let isSigningIn: Bool
    let onSelect: () -> Void
    let onSignIn: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack {
            Image(systemName: isActive ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(isActive ? Color.accentColor : .secondary)
            Text(account.label)
                .font(.body)
                .fontWeight(isActive ? .semibold : .regular)
            Spacer()
            if isSigningIn {
                ProgressView().controlSize(.small)
            } else if needsReauth {
                // Click → claude opens your browser to sign in (claude auth login).
                // Logos never touches the token (#34).
                Button("Sign in", action: onSignIn)
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .help("Opens your browser to sign in to this account with claude (claude auth login).")
                    .accessibilityIdentifier("logos.account.signin")
            }
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
