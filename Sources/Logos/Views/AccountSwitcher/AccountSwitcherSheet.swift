import SwiftUI
import LogoSwitch

struct AccountSwitcherSheet: View {
    @Environment(AccountManager.self) private var mgr
    @Environment(\.dismiss) private var dismiss

    /// #42: when non-nil, the switcher selects/highlights THIS window's per-window
    /// account (status-bar context). nil → it falls back to the global
    /// `AccountManager.activeAccountId` / `setActive` (the Settings→Accounts context),
    /// so the SAME sheet serves both — without reading a window-scoped environment the
    /// Settings scene doesn't have (#20).
    var selection: Binding<String?>? = nil
    /// #42: when non-nil, each row gets an "open in new window" affordance routed here
    /// (status-bar context). nil in Settings.
    var onOpenInNewWindow: ((String) -> Void)? = nil

    @State private var showAddSheet = false
    @State private var newLabel = ""
    @State private var addError: String?

    /// Inline-rename state (#36): which row is being edited + the last failed
    /// rename's message. The sheet owns this so `AccountRow` stays presentational.
    @State private var editingAccountId: String?
    @State private var renameError: String?
    /// #60: last failed delete's message. #57 made `remove()` return `Bool` (a failed
    /// registry persist rolls back, the account stays alive) — this surfaces that
    /// failure instead of leaving the tap looking like a no-op. Cleared at the entry
    /// of the next user action so it never lingers across interactions.
    @State private var deleteError: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Accounts")
                    .font(.title3)
                    .fontWeight(.semibold)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("logos.account.done")  // #24 XCUITest query
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 8)

            Divider()

            if mgr.accounts.isEmpty {
                VStack(spacing: 8) {
                    Text("No accounts yet")
                        .foregroundStyle(.secondary)
                    Text("Add an account below, then sign in — claude opens your browser to log in.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)
                }
                .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(mgr.accounts) { acc in
                            AccountRow(
                                account: acc,
                                isActive: acc.id == activeSelectionId,
                                needsReauth: mgr.needsReauth(acc),
                                isEditing: acc.id == editingAccountId,
                                onSelect: { selectAccount(acc.id) },
                                onBeginRename: { beginRename(acc.id) },
                                onCommitRename: { commitRename(acc.id, to: $0) },
                                onCancelRename: { cancelRename(acc.id) },
                                onDelete: { delete(acc.id) },
                                onOpenInNewWindow: onOpenInNewWindow.map { cb in { cb(acc.id) } }
                            )
                            Divider()
                        }
                    }
                }
            }

            if let err = renameError {
                SheetErrorLine(message: err, identifier: "logos.account.rename.error")  // #36 verify DA-7: queryable in a future UI test
            }
            if let err = deleteError {
                SheetErrorLine(message: err, identifier: "logos.account.delete.error")  // #60: parity with the rename affordance
            }

            Divider()

            Button(action: { deleteError = nil; renameError = nil; showAddSheet = true }) {
                Label("Add account", systemImage: "plus.circle.fill")
                    .padding(.vertical, 4)
            }
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .accessibilityIdentifier("logos.account.add")
            .help("Create a new labeled account. Each account gets its own isolated claude config; sign in with `claude auth login`.")

            // #54: reuse the login you already have in Terminal (~/.claude) as a
            // "main" account — no separate sign-in. Offered only while none exists
            // (`addSystemDefaultAccount` is dedup-guarded regardless).
            if !mgr.accounts.contains(where: \.isSystemDefault) {
                Button {
                    deleteError = nil
                    renameError = nil
                    mgr.addSystemDefaultAccount()
                } label: {
                    Label("Add system account", systemImage: "person.crop.circle.badge.checkmark")
                        .padding(.vertical, 4)
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
                .accessibilityIdentifier("logos.account.addSystemDefault")
                .help("Reuse the login you already have in Terminal (~/.claude). No new sign-in — this account shares your system claude login.")
            } else {
                Color.clear.frame(height: 8)
            }
        }
        .dialogFrame(.switcher)
        .sheet(isPresented: $showAddSheet) {
            AddAccountForm(
                label: $newLabel,
                error: $addError,
                onSave: { addAccount() },
                onCancel: { dismissAddSheet() }
            )
        }
    }

    /// Create a new EMPTY account (#34 launcher model). The user signs it in via
    /// `claude auth login` (claude opens its own browser) — Logos never captures
    /// or stores a token.
    private func addAccount() {
        addError = nil
        do {
            try mgr.createAccount(label: newLabel)
            dismissAddSheet()
        } catch Account.ValidationError.emptyLabel {
            addError = "Enter a label for the account."
        } catch Account.ValidationError.labelTooLong {
            addError = "Label is too long (max 30 characters)."
        } catch Account.ValidationError.duplicateLabel {
            addError = "An account with that label already exists."
        } catch {
            addError = "\(error)"
        }
    }

    private func dismissAddSheet() {
        newLabel = ""
        addError = nil
        showAddSheet = false
    }

    // MARK: - Selection (#42: per-window or global)

    /// The currently-highlighted account id: the per-window selection in a window
    /// context, else the global new-window default.
    private var activeSelectionId: String? {
        selection?.wrappedValue ?? mgr.activeAccountId
    }

    /// Select an account: set the per-window selection (window context), else the global
    /// default via `setActive` (Settings context). A window-local switch never writes
    /// the global default — the #42 window-local decision.
    private func selectAccount(_ id: String) {
        deleteError = nil   // #60: a new action clears any stale delete error
        if let selection {
            selection.wrappedValue = id
        } else {
            mgr.setActive(id)
        }
    }

    // MARK: - Inline rename (#36)

    private func beginRename(_ accountId: String) {
        renameError = nil
        deleteError = nil   // #60
        editingAccountId = accountId
    }

    /// Cancel — but ONLY if `accountId` is still the row being edited. The guard
    /// makes the callback account-scoped (#36 verify, codex + logic + devil's
    /// advocate): a stale focus-loss/Esc callback from a row that just lost
    /// editing (switched to another row, deleted, or fired after a successful
    /// commit set `editingAccountId = nil`) becomes a deterministic no-op instead
    /// of clobbering the current editing row. Removes the "relies on undocumented
    /// SwiftUI batching" race the reviewers flagged.
    private func cancelRename(_ accountId: String) {
        guard editingAccountId == accountId else { return }
        renameError = nil
        // #60 verify (round-2 DA): deliberately does NOT clear `deleteError`. A single
        // click on the trash button of the row being edited synthesizes THIS callback
        // (via AccountRow's focus-loss `.onChange`) alongside `delete()`'s own action.
        // If it ran after delete()'s failure branch set `deleteError`, it would silently
        // erase the just-set failure message — resurrecting #60's original silent no-op
        // through a different door, regardless of the (unverifiable) SwiftUI/AppKit
        // action-vs-focus-resign ordering. cancelRename tears down RENAME state only; the
        // mutual-exclusivity invariant is upheld by the two error SETTERS (`delete`,
        // `commitRename`), which each clear BOTH captions before setting one. In the
        // deliberate-cancel path `deleteError` is already nil (beginRename cleared it), so
        // not clearing it here is a no-op there.
        // #68: "rename state" includes `editingAccountId` — so when a trash-click on
        // the row being edited DOES resign focus, this teardown fires and the row
        // exits edit mode even if the delete then fails (delete()'s failure branch
        // deliberately leaves the id set, so this guard passes on either side of it).
        // Accepted: the failed delete's guaranteed signal is the surviving
        // `deleteError` caption, not edit-mode retention — see delete()'s doc comment.
        // #67's E2E asserts the caption; edit-mode behavior is recorded there as an
        // observation.
        editingAccountId = nil
    }

    /// Delete an account. #60: `remove()` returns `false` when the registry persist
    /// fails and rolls back (the account stays alive) — surface that instead of a
    /// silent no-op. Hard guarantee (#68): the failure CAPTION is shown, and it
    /// survives both orderings of the trash-click's synthesized `cancelRename`
    /// (which never clears `deleteError` — see that method). Edit-mode retention on
    /// failure is NOT structurally guaranteed: this failure branch leaves
    /// `editingAccountId` alone, but a trash-click that resigns the row's TextField
    /// focus synthesizes `cancelRename`, whose account-scoped guard then passes
    /// (either before delete() runs, or after — the failure branch keeps the id set)
    /// and tears edit mode down. Whether the click resigns focus is AppKit behavior,
    /// not this code. Only the success path's teardown below is structural (#36
    /// verify, logic reviewer, still holds there).
    private func delete(_ accountId: String) {
        // #60 verify (6-AI round 1): clear BOTH captions at entry, not just
        // `deleteError`. Delete is a user action, so it clears the sibling's stale
        // error too — the mutual-exclusivity invariant this change claims. Without
        // the unconditional `renameError = nil`, a failed delete while a row shows a
        // lingering rename error left both captions stacked; the cross-row path
        // (rename row A fails → delete row B fails) is unconditionally reachable
        // because the trash button is never gated on edit state.
        deleteError = nil
        renameError = nil
        guard mgr.remove(accountId: accountId) else {
            // #69: English like every sibling message — this was the sheet's only
            // Chinese string. Localization proper (typed pipeline) stays recorded
            // debt on #69 until i18n actually lands.
            deleteError = "Couldn't remove the account — the change didn't save. Try again."
            return
        }
        if editingAccountId == accountId {
            editingAccountId = nil
        }
    }

    /// Commit a rename. On a validation error, KEEP the row in edit mode and show
    /// the message (mirrors the add form) — no silent revert. Pure local label
    /// metadata: the account id / config dir / credentials are untouched (#34).
    /// Account-scoped guard (#36 verify): ignore a stale commit from a row that is
    /// no longer the active edit target.
    private func commitRename(_ accountId: String, to newLabel: String) {
        guard editingAccountId == accountId else { return }
        renameError = nil
        deleteError = nil   // #60
        do {
            try mgr.rename(accountId: accountId, to: newLabel)
            editingAccountId = nil
        } catch Account.ValidationError.emptyLabel {
            renameError = "Enter a label for the account."
        } catch Account.ValidationError.labelTooLong {
            renameError = "Label is too long (max 30 characters)."
        } catch Account.ValidationError.duplicateLabel {
            renameError = "An account with that label already exists."
        } catch {
            renameError = "\(error)"
        }
    }
}

/// #60: the sheet's bottom error caption, shared by the rename and delete
/// affordances (a red `.caption` with a queryable accessibility id). Presentational
/// (plain values, no environment) so it snapshots directly — `internal`, not
/// `private`, so `LogosHostedTests` can construct it via `@testable import`.
struct SheetErrorLine: View {
    let message: String
    let identifier: String

    var body: some View {
        Text(message)
            .foregroundStyle(.red)
            .font(.caption)
            .lineLimit(2)
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier(identifier)
    }
}

private struct AddAccountForm: View {
    @Binding var label: String
    @Binding var error: String?
    let onSave: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add account")
                .font(.title3)
                .fontWeight(.semibold)
            Text("Creates a new account with its own isolated claude config. After adding, sign in — claude opens your browser to authenticate.")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Label (e.g. work, personal)", text: $label)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("logos.account.add.label")
            if let err = error {
                Text(err)
                    .foregroundStyle(.red)
                    .font(.caption)
                    .lineLimit(3)
            }
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Add", action: onSave)
                    .keyboardShortcut(.defaultAction)
                    .disabled(label.isEmpty)
            }
        }
        .padding(16)
        .frame(width: 400)
    }
}
