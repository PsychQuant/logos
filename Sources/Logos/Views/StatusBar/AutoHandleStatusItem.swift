import SwiftUI

struct AutoHandleStatusItem: View {
    @Environment(AutoHandleEngine.self) private var engine

    var body: some View {
        Label(engine.currentStatus.label, systemImage: "bolt.fill")
            .font(.caption)
            .foregroundStyle(engine.currentStatus.color)
            .help("Auto-handle: \(engine.disabledRuleIDs.count) rules disabled")
    }
}
