import SwiftUI
import LogoSwitch
import os

struct AccountSwitcherSheet: View {
    @Environment(AccountManager.self) private var mgr
    @Environment(\.dismiss) private var dismiss
    /// spec 2026-07-31: deleting an account must stop its gateway BEFORE the
    /// registry removal reaps the data directory — see `AccountRemoval`.
    @Environment(\.gatewayPool) private var gatewayPool

    /// #42: when non-nil, the switcher selects/highlights THIS window's per-window
    /// account (status-bar context). nil → it falls back to the global
    /// `AccountManager.activeAccountId` / `setActive` (the Settings→Accounts context),
    /// so the SAME sheet serves both — without reading a window-scoped environment the
    /// Settings scene doesn't have (#20).
    var selection: Binding<String?>?
    /// #42: when non-nil, each row gets an "open in new window" affordance routed here
    /// (status-bar context). nil in Settings.
    var onOpenInNewWindow: ((String) -> Void)?
    /// #75: the VoiceOver announcer seam. Injected so tests can count posts and
    /// assert the literal-repeat case (setting the SAME message announces every
    /// time — the #71 round-2 motivation). Defaults to the real announcement, so
    /// production behavior is byte-identical to the inline `.post()` it replaces.
    /// Every error setter routes through this — see the "Error surfacing" MARK.
    var announce: @MainActor (String) -> Void

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
    /// #74: last failed "Add system account" message. `addSystemDefaultAccount()`
    /// returns `.failed` on a registry persist failure (the account is NOT durably
    /// registered) — the call site used to discard it, leaving the tap a silent
    /// no-op. Surfaced here like `deleteError`, cleared at the entry of sibling
    /// actions so it never lingers.
    @State private var systemDefaultError: String?

    /// #75: explicit init — the synthesized memberwise init is `private` (the
    /// `@State` slots are `private`), so a hosted test can't reach it. This is also
    /// the seam through which `LogosHostedTests` injects a counting `announce`.
    init(
        selection: Binding<String?>? = nil,
        onOpenInNewWindow: ((String) -> Void)? = nil,
        announce: @escaping @MainActor (String) -> Void = { AccessibilityNotification.Announcement($0).post() }
    ) {
        self.selection = selection
        self.onOpenInNewWindow = onOpenInNewWindow
        self.announce = announce
    }

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
                // #87: a List (not the prior ScrollView + VStack) so the non-default
                // accounts are drag-reorderable via `.onMove` — the platform's standard
                // reorder affordance. On macOS a plain click still selects and a
                // press-drag reorders, so this never swallows AccountRow's single-tap
                // select, double-click rename, or the trash/open/pencil buttons.
                //
                // The Main (system-default) account is rendered as a PINNED row ABOVE
                // the movable ForEach. Being outside that ForEach is what enforces
                // "Main pinned to the top": `.onMove` destinations are clamped to the
                // ForEach's range, so nothing can be dropped above Main, and Main itself
                // is not in the movable set (belt-and-suspenders `.moveDisabled` too).
                // Row identity is `Account.id` (Identifiable) — stable across a move, so
                // per-row @State / focus survive a reorder (foreach.md).
                List {
                    if let main = mgr.mainAccount {
                        // #88: Main is pinned + `.moveDisabled` — it shows no grip, but
                        // reserves the SAME leading width (showsGrip: false) so every
                        // account label stays vertically aligned with the grip'd rows.
                        switcherRow(main, showsGrip: false)
                            .moveDisabled(true)
                    }
                    ForEach(mgr.reorderableAccounts) { acc in
                        // #88: reorderable rows get the visible 6-dot drag-handle hint.
                        switcherRow(acc, showsGrip: true)
                    }
                    .onMove { source, destination in
                        // `.onMove` offsets are relative to the reorderable ForEach, so
                        // map them onto that subset's id order and hand the result to the
                        // registry (which re-pins Main first). Main is never in this set.
                        var order = mgr.reorderableAccounts.map(\.id)
                        order.move(fromOffsets: source, toOffset: destination)
                        mgr.reorderAccounts(nonDefaultIDs: order)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)   // keep the sheet's background, not List's
            }

            if let err = renameError {
                SheetErrorLine(message: err, identifier: "logos.account.rename.error")  // #36 verify DA-7: queryable in a future UI test
            }
            if let err = deleteError {
                SheetErrorLine(message: err, identifier: "logos.account.delete.error")  // #60: parity with the rename affordance
            }
            if let err = systemDefaultError {
                SheetErrorLine(message: err, identifier: "logos.account.addSystemDefault.error")  // #74: surface the discarded .failed
            }

            Divider()

            Button(action: { deleteError = nil; renameError = nil; systemDefaultError = nil; showAddSheet = true }) {
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
                    systemDefaultError = nil
                    // #74: the .failed result used to be discarded — a persist
                    // failure left the tap a silent no-op. Route it through the
                    // setter into the sheet's error affordance. The detail is
                    // already logged .private at AccountManager.swift:157, so the
                    // caption stays a friendly sentence (no raw payload).
                    if case .failed = mgr.addSystemDefaultAccount() {
                        setSystemDefaultError("Couldn't add the system account — the change didn't save. Try again.")
                    }
                } label: {
                    Label("Add system account", systemImage: "person.crop.circle.badge.checkmark")
                        .padding(.vertical, 4)
                }
                .padding(.horizontal, 8)
                // #86: symmetric vertical padding so an even gap opens between this
                // and "Add account" above — the parent VStack has spacing: 0, and
                // "Add account" sets only `.top`, so a `.bottom`-only here left the
                // two buttons flush against each other.
                .padding(.vertical, 8)
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

    /// #87: one switcher row — the shared `AccountRow` (unchanged look) wrapped with a
    /// trailing `Divider` and the list-row modifiers that preserve the pre-List
    /// appearance: zero row insets so AccountRow's own padding governs, and List's
    /// native separators hidden in favor of the explicit `Divider` that matched the old
    /// ScrollView + VStack layout. Used for BOTH the pinned Main row and each
    /// reorderable row so they render identically. A small `@ViewBuilder` helper (not a
    /// separate `View` type) because it just forwards the sheet's eight per-row closures
    /// into `AccountRow` — which is itself the row's real, narrow-input invalidation
    /// boundary.
    ///
    /// #88: `showsGrip` prepends a leading 6-dot drag-handle grip as a
    /// draggability HINT on the reorderable rows (`true`). Main passes `false`: it
    /// still lays out the SAME grip view (kept invisible via `.opacity`) so it
    /// reserves an identical leading width and every account label stays aligned —
    /// Main just doesn't draw a handle it can't use (`.moveDisabled`). The grip is
    /// purely decorative: the row stays whole-row press-draggable through the List's
    /// `.onMove` (#87); the grip carries no gesture and is `.allowsHitTesting(false)`
    /// so a press-drag that starts on it falls through to the List row and still
    /// reorders. `AccountRow` itself is untouched — the grip is a switcher-context
    /// wrapper affordance, not part of the presentational row.
    @ViewBuilder
    private func switcherRow(_ acc: Account, showsGrip: Bool) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                DragHandleGrip()
                    .padding(.leading, 10)
                    .padding(.trailing, 2)
                    .opacity(showsGrip ? 1 : 0)   // Main reserves the width, draws nothing
                    .allowsHitTesting(false)       // pass press-drag through to the List row
                    .accessibilityHidden(true)     // decorative — keep it out of VoiceOver
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
            }
            Divider()
        }
        .listRowInsets(EdgeInsets())
        .listRowSeparator(.hidden)
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
            setAddError("Enter a label for the account.")
        } catch Account.ValidationError.labelTooLong {
            setAddError("Label is too long (max 30 characters).")
        } catch Account.ValidationError.duplicateLabel {
            setAddError("An account with that label already exists.")
        } catch {
            // #70: never surface a raw error description — this branch is reachable
            // with FileManager/registry-persist errors whose text can embed
            // filesystem paths. Friendly caption; detail to the unified log at
            // explicitly-private privacy (paths stay redacted, #22 D3).
            Log.account.error("account create failed: \(String(describing: error), privacy: .private)")
            setAddError("Couldn't create the account — the change didn't save. Try again.")
        }
    }

    // MARK: - Error surfacing (#71 round 2)

    /// #71 round 2: every user-facing error is SET through one of these four
    /// helpers, which announce imperatively via the `announce` seam (#75). The
    /// view-side hooks (`onAppear`/`onChange` on `SheetErrorLine`) were removed
    /// because a repeat of the SAME message coalesces to a no-op render and both
    /// hooks stay silent — the identical-retry failure was inaudible (verify round
    /// 1). An unconditional announce at the mutation site covers first occurrence,
    /// changed message, and literal repeat alike. Keep new error writes going
    /// through these helpers, not direct `@State` assignment — enforced by
    /// `AnnounceAtSetterGuardTests` (#75 option 2). `internal` (not `private`) so
    /// `LogosHostedTests` can drive the seam (#75 option 3) — same rationale as
    /// `SheetErrorLine`/`AddAccountForm`.
    func setAddError(_ message: String) {
        addError = message
        announce(message)
    }

    func setRenameError(_ message: String) {
        renameError = message
        announce(message)
    }

    func setDeleteError(_ message: String) {
        deleteError = message
        announce(message)
    }

    func setSystemDefaultError(_ message: String) {
        systemDefaultError = message
        announce(message)
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
        systemDefaultError = nil   // #74: mirror deleteError's clearing sites
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
        systemDefaultError = nil   // #74
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
        // #74 (verify DA): the same exception covers `systemDefaultError` — an
        // "Add system account" click while a row is mid-rename synthesizes THIS
        // callback via the same focus-loss path, so clearing that caption here could
        // erase a just-set failure message on the wrong side of the ordering. Do NOT
        // "complete" the mirror-deleteError clearing pattern in this method: it
        // tears down rename state ONLY, and touches no failure caption.
        // `AnnounceAtSetterGuardTests.cancelRenameKeepsFailureCaptions` pins this.
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
        systemDefaultError = nil   // #74: a delete is a user action — clear the sibling caption too

        // spec 2026-07-31: the gateway writes into the account directory that
        // `remove` reaps inline, so it must be stopped first — `AccountRemoval`
        // owns that ordering and is tested for it.
        Task {
            let removed = await AccountRemoval.perform(
                accountID: accountId,
                stopGateway: { await gatewayPool.shutdown(accountID: $0) },
                removeFromRegistry: { mgr.remove(accountId: $0) }
            )
            guard removed else {
                // #69: English like every sibling message — this was the sheet's only
                // Chinese string. Localization proper (typed pipeline) stays recorded
                // debt on #69 until i18n actually lands.
                setDeleteError("Couldn't remove the account — the change didn't save. Try again.")
                return
            }
            if editingAccountId == accountId {
                editingAccountId = nil
            }
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
        systemDefaultError = nil   // #74
        do {
            try mgr.rename(accountId: accountId, to: newLabel)
            editingAccountId = nil
        } catch Account.ValidationError.emptyLabel {
            setRenameError("Enter a label for the account.")
        } catch Account.ValidationError.labelTooLong {
            setRenameError("Label is too long (max 30 characters).")
        } catch Account.ValidationError.duplicateLabel {
            setRenameError("An account with that label already exists.")
        } catch {
            // #70: same as addAccount() — registry.rename's persist failure lands
            // here; log the detail, show a sentence.
            Log.account.error("account rename failed: \(String(describing: error), privacy: .private)")
            setRenameError("Couldn't rename the account — the change didn't save. Try again.")
        }
    }
}

/// #88: the leading drag-handle grip — a compact 2×3 matrix of six small filled
/// circles, the macOS convention for "this row is draggable." There is no clean SF
/// Symbol for a 2×3 dot grip, so it's drawn with a `Grid` of `Circle`s in the
/// subtle `.tertiary` style. Purely decorative and hint-only: the row's actual
/// draggability is the List's `.onMove` (#87), not this view — it carries no
/// gesture and its use site adds `.allowsHitTesting(false)` so a press-drag that
/// starts on the handle passes through to the List row and still reorders. `private`
/// (file-scope) because nothing outside this file — including tests — constructs it;
/// the grip is visual-only (Track-B), so it has no `swift test` assertion.
private struct DragHandleGrip: View {
    var body: some View {
        Grid(horizontalSpacing: 3, verticalSpacing: 3) {
            GridRow { dot; dot }
            GridRow { dot; dot }
            GridRow { dot; dot }
        }
        .foregroundStyle(.tertiary)
    }

    private var dot: some View {
        Circle().frame(width: 2.5, height: 2.5)
    }
}

/// #60: the error caption shared by the rename, delete (#60) and add (#71)
/// affordances (a red `.caption` with a queryable accessibility id). Presentational
/// (plain values, no environment, no side effects) so it snapshots directly —
/// `internal`, not `private`, so `LogosHostedTests` can construct it via
/// `@testable import`.
/// #71 round 2: the VoiceOver announcement is NOT posted here. Every error setter
/// runs `error = nil` → `error = <message>` inside one synchronous action closure;
/// when the message is unchanged SwiftUI coalesces that into a no-op render, so
/// view-lifecycle hooks (`onAppear`/`onChange`) structurally cannot cover the
/// identical-retry case (verify round 1, agents:logic + codex, DA-confirmed).
/// Announcements are posted imperatively by the sheet's error setters instead —
/// see `AccountSwitcherSheet`'s "Error surfacing" MARK.
/// `horizontalPadding` defaults to the sheet's edge inset; already-padded
/// containers (AddAccountForm) pass 0 to stay aligned with their fields.
struct SheetErrorLine: View {
    let message: String
    let identifier: String
    var horizontalPadding: CGFloat = 16

    var body: some View {
        Text(message)
            .foregroundStyle(.red)
            .font(.caption)
            .lineLimit(2)
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier(identifier)
    }
}

/// #71: `internal` (not `private`) so `LogosHostedTests` can construct it for the
/// form-with-error snapshot — same pattern as `SheetErrorLine` (#60).
struct AddAccountForm: View {
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
                // #71: unified with the rename/delete affordances — queryable id,
                // announced to VoiceOver, consistent styling. padding 0: the form's
                // VStack already provides the 16pt inset.
                SheetErrorLine(
                    message: err,
                    identifier: "logos.account.add.error",
                    horizontalPadding: 0
                )
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
