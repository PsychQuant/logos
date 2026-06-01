import SwiftUI

struct AccountSwitcherSheet: View {
    @Environment(AccountManager.self) private var mgr
    @Environment(\.dismiss) private var dismiss

    @State private var showAddSheet = false
    @State private var newLabel = ""
    @State private var addError: String?

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
                    Text("Run `claude login` in a terminal, then 'Capture current login' below.")
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
                                isActive: acc.id == mgr.activeAccountId,
                                needsReauth: mgr.needsReauth(acc),
                                onSelect: { mgr.setActive(acc.id) },
                                onDelete: { try? mgr.remove(accountId: acc.id) }
                            )
                            Divider()
                        }
                    }
                }
            }

            Divider()

            Button(action: { showAddSheet = true }) {
                Label("Capture current login as new account", systemImage: "plus.circle.fill")
                    .padding(.vertical, 4)
            }
            .padding(8)
            .help("Reads claude's current login from macOS Keychain and saves it as a labeled Logos account.")
        }
        .frame(width: 380, height: 380)
        .sheet(isPresented: $showAddSheet) {
            CaptureAccountForm(
                label: $newLabel,
                error: $addError,
                onSave: { captureAccount() },
                onCancel: { dismissAddSheet() }
            )
        }
    }

    private func captureAccount() {
        addError = nil
        do {
            try mgr.addByCapturingCurrent(label: newLabel)
            dismissAddSheet()
        } catch AccountManager.AddByCaptureError.noSystemCredentials {
            addError = "No claude login found in macOS Keychain. Run `claude login` in a terminal first."
        } catch {
            addError = "\(error)"
        }
    }

    private func dismissAddSheet() {
        newLabel = ""
        addError = nil
        showAddSheet = false
    }
}

private struct CaptureAccountForm: View {
    @Binding var label: String
    @Binding var error: String?
    let onSave: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Capture current claude login")
                .font(.title3)
                .fontWeight(.semibold)
            Text("Logos will read the system Keychain entry for `Claude Code-credentials` and store it under the label below.")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Label (e.g. work, personal)", text: $label)
                .textFieldStyle(.roundedBorder)
            if let err = error {
                Text(err)
                    .foregroundStyle(.red)
                    .font(.caption)
                    .lineLimit(3)
            }
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Capture", action: onSave)
                    .keyboardShortcut(.defaultAction)
                    .disabled(label.isEmpty)
            }
        }
        .padding(16)
        .frame(width: 400)
    }
}
