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
                // Purely visual active indicator (#72). The active state is carried
                // to VoiceOver by the label Text's accessibilityValue below, so the
                // circle is decorative — hide it to avoid a redundant announcement.
                .accessibilityHidden(true)

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
                    // #72: carry active state to VoiceOver as a value (e.g. "work,
                    // active") rather than a combined/relabeled element. The element's
                    // accessibility LABEL stays equal to `account.label`. needsReauth is
                    // announced by its own labeled warning image below, so it stays out
                    // of here.
                    .accessibilityValue(isActive ? "active" : "")
                    // #77: expose select/rename to VoiceOver on the account-label
                    // element — NOT the row HStack, whose `.contentShape` +
                    // `.onTapGesture`s stay pointer-only. Adding a button trait to the
                    // container would first require combining it into ONE a11y element,
                    // flattening the trash / open-in-window / pencil buttons (losing
                    // independent VoiceOver access AND breaking the label-based Track-B
                    // queries, #79). Activate = select; "Rename" joins the VoiceOver
                    // actions rotor. `.isButton` promotes this element's XCUIElementType
                    // from .staticText to .button, so Track B queries the account label
                    // via `buttons[label]` (was `staticTexts[label]` pre-#77).
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { onSelect() }
                    .accessibilityAction(named: "Rename") { onBeginRename() }
                // #54: distinguish the main account that reuses the system
                // ~/.claude login from isolated per-account configs.
                if account.isSystemDefault {
                    Text("system")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(.quaternary))
                        .help("Reuses your Terminal login (~/.claude) — no separate sign-in.")
                        .accessibilityLabel("System account")
                }
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
                .accessibilityLabel("Open in new window")  // #72: icon-only; .help() is a tooltip, not a VO label
                .accessibilityIdentifier("logos.account.openInNewWindow")  // #42 XCUITest query
            }
            // #37/#27: enter rename via an affordance, gated on `--ui-testing`.
            // XCUITest cannot synthesize the SwiftUI `.onTapGesture(count: 2)` below
            // (element-, coordinate-, active-row-, and two-`click()` synthesis all
            // leave the count:2 recognizer unfired). A genuine hardware double-click
            // DOES enter rename and does NOT switch the active account — verified
            // out-of-band (real double-click, screenshot-confirmed), so the gesture
            // is sound; only the synthesized path is un-drivable. This affordance
            // lets the UI test reach rename state, mirroring the
            // `logos.terminal.uitestTerminate` seam (#27). Inert in production (the
            // arg never appears → not built, so snapshots stay byte-identical). Its
            // per-account VoiceOver label makes it row-targetable even though the
            // row's `.accessibilityIdentifier("logos.account.row")` propagates onto
            // every child control's identifier (the #24 row id shadows child ids).
            if !isEditing, CommandLine.arguments.contains("--ui-testing") {
                Button(action: onBeginRename) {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.plain)
                .opacity(0.6)
                .accessibilityLabel("Begin rename \(account.label)")
                .accessibilityIdentifier("logos.account.beginRename")  // shadowed by the row id; query by the per-account label
            }
            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
            .opacity(0.6)
            .accessibilityLabel("Delete account")  // #72: icon-only trash button needs a VO label
            // NOTE: this id is SHADOWED at runtime by the row HStack's
            // `.accessibilityIdentifier("logos.account.row")` (#24) — SwiftUI
            // propagates a container identifier onto its child a11y elements, so
            // every control in the row reports `logos.account.row`. XCUITest must
            // query this button by its VoiceOver LABEL ("Delete account"), not this
            // id. This is the RATIFIED, permanent convention (#79, option a): rather
            // than relocate the row id onto a non-propagating leaf (option b, an
            // accessibility-tree restructure for marginal benefit), the shadowed child
            // ids are kept purely as intent/VO-tooling markers and every row control
            // is queried by its label. The shadowing is a pre-existing latent defect
            // (predates #72; also affects `logos.account.openInNewWindow` /
            // `logos.account.beginRename`), harmless because no query relies on it.
            .accessibilityIdentifier("logos.account.delete")  // #67 (shadowed — see NOTE; query by label)
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
