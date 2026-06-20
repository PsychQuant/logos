import SwiftUI
import LogoSwitch

struct AccountRow: View {
    let account: Account
    let isActive: Bool
    /// Whether this account currently reads as unauthenticated (#12/#31). A
    /// non-blocking indicator only — sign in by running `/login` in the hosted
    /// claude for the active account; Logos never drives the login itself.
    let needsReauth: Bool
    /// Whether this row is in inline-rename mode (#36). The parent owns which row
    /// is editing; the row renders a focused `TextField` when true.
    let isEditing: Bool
    let onSelect: () -> Void
    let onBeginRename: () -> Void
    let onCommitRename: (String) -> Void
    let onCancelRename: () -> Void
    let onDelete: () -> Void
    /// #42: when non-nil, the row shows an "open in new window" affordance that opens a
    /// new window bound to THIS account. nil in the Settings→Accounts context (global
    /// account management, where "this window's account" has no meaning). Defaulted so
    /// existing call sites (snapshot tests, Settings) need no change.
    var onOpenInNewWindow: (() -> Void)? = nil

    @State private var draft: String = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        HStack {
            Image(systemName: isActive ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(isActive ? Color.accentColor : .secondary)

            if isEditing {
                TextField("Account name", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .font(.body)
                    .focused($fieldFocused)
                    .onSubmit { onCommitRename(draft) }          // Return → save
                    .onExitCommand { onCancelRename() }          // Esc → cancel
                    .accessibilityIdentifier("logos.account.rename.field")
            } else {
                Text(account.label)
                    .font(.body)
                    .fontWeight(isActive ? .semibold : .regular)
                if needsReauth {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .help("Needs login — switch to this account and run /login in the terminal; claude opens your browser to sign in.")
                        .accessibilityLabel("Needs login")
                }
            }

            Spacer()
            if !isEditing, let onOpenInNewWindow {
                Button(action: onOpenInNewWindow) {
                    Image(systemName: "macwindow.badge.plus")
                }
                .buttonStyle(.plain)
                .opacity(0.6)
                .help("Open this account in a new window")
                .accessibilityIdentifier("logos.account.openInNewWindow")  // #42 XCUITest query
            }
            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
            .opacity(0.6)
        }
        .contentShape(Rectangle())
        // Double-click → rename (#36). Declared BEFORE the single-tap select so
        // SwiftUI disambiguates the two; the small select-latency is acceptable.
        // Guarded by !isEditing so a double-tap on the field doesn't re-seed it.
        .onTapGesture(count: 2) { if !isEditing { onBeginRename() } }
        .onTapGesture { if !isEditing { onSelect() } }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .accessibilityIdentifier("logos.account.row")  // #24 XCUITest query (all rows share; tap a non-active one)
        // Seed the draft + focus when this row enters edit mode.
        .onChange(of: isEditing) { _, editing in
            if editing {
                draft = account.label
                fieldFocused = true
            }
        }
        // Clicking away (focus loss) cancels — Return is the explicit save. Guarded
        // by isEditing so a post-commit field removal doesn't re-fire cancel.
        .onChange(of: fieldFocused) { _, focused in
            if !focused && isEditing { onCancelRename() }
        }
    }
}
