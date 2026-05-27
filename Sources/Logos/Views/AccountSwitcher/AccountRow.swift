import SwiftUI

struct AccountRow: View {
    let account: Account
    let isActive: Bool
    let onSelect: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack {
            Image(systemName: isActive ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(isActive ? Color.accentColor : .secondary)
            Text(account.label)
                .font(.body)
                .fontWeight(isActive ? .semibold : .regular)
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
    }
}
