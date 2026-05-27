import SwiftUI

struct AccountSwitcherSheet: View {
    @Environment(AccountManager.self) private var mgr
    @Environment(\.dismiss) private var dismiss

    @State private var showAddSheet = false
    @State private var newLabel = ""
    @State private var newCredentialsPath = ""
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
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 8)

            Divider()

            if mgr.accounts.isEmpty {
                VStack(spacing: 8) {
                    Text("No accounts yet")
                        .foregroundStyle(.secondary)
                    Text("Add your first account below.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(mgr.accounts) { acc in
                            AccountRow(
                                account: acc,
                                isActive: acc.id == mgr.activeAccountId,
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
                Label("Add account", systemImage: "plus.circle.fill")
                    .padding(.vertical, 4)
            }
            .padding(8)
        }
        .frame(width: 360, height: 360)
        .sheet(isPresented: $showAddSheet) {
            AddAccountForm(
                label: $newLabel,
                credentialsPath: $newCredentialsPath,
                error: $addError,
                onSave: { addAccount() },
                onCancel: { dismissAddSheet() }
            )
        }
    }

    private func addAccount() {
        addError = nil
        let credsURL = URL(fileURLWithPath: NSString(string: newCredentialsPath).expandingTildeInPath)
        guard let data = try? Data(contentsOf: credsURL) else {
            addError = "Could not read credentials file at that path."
            return
        }
        do {
            try mgr.add(label: newLabel, credentials: data)
            dismissAddSheet()
        } catch {
            addError = "\(error)"
        }
    }

    private func dismissAddSheet() {
        newLabel = ""
        newCredentialsPath = ""
        addError = nil
        showAddSheet = false
    }
}

private struct AddAccountForm: View {
    @Binding var label: String
    @Binding var credentialsPath: String
    @Binding var error: String?
    let onSave: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add account")
                .font(.title3)
                .fontWeight(.semibold)
            TextField("Label (e.g. work)", text: $label)
                .textFieldStyle(.roundedBorder)
            TextField("Path to .credentials.json", text: $credentialsPath)
                .textFieldStyle(.roundedBorder)
                .help("Run `claude login` in a terminal first, then point here to ~/.claude/.credentials.json")
            if let err = error {
                Text(err).foregroundStyle(.red).font(.caption)
            }
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Save", action: onSave)
                    .keyboardShortcut(.defaultAction)
                    .disabled(label.isEmpty || credentialsPath.isEmpty)
            }
        }
        .padding(16)
        .frame(width: 380)
    }
}
