import SwiftUI

struct TerminalPanePlaceholder: View {
    var body: some View {
        VStack {
            Image(systemName: "apple.terminal")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text("Terminal — Claude Code")
                .font(.headline)
                .foregroundStyle(Color.green.opacity(0.8))
            Text("SwiftTerm integration in sub-plan B → renderer in sub-plan C")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }
}
