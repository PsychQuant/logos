import SwiftUI

struct AutoHandleSettingsTab: View {
    @Environment(AutoHandleEngine.self) private var engine

    var body: some View {
        Form {
            Section {
                ForEach(AutoHandleRule.defaultRuleset) { rule in
                    RuleRow(rule: rule, engine: engine)
                }
            } header: {
                Text("Rules")
            } footer: {
                Text("Toggling here persists across launches. Runaway protection (3 fires in 30s → auto-disable) is transient and resets on next launch.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 540, height: 380)
    }
}

private struct RuleRow: View {
    let rule: AutoHandleRule
    let engine: AutoHandleEngine

    var isEnabled: Binding<Bool> {
        Binding(
            get: { !engine.disabledRuleIDs.contains(rule.id) },
            set: { newValue in
                if newValue { engine.enableRule(id: rule.id) }
                else { engine.disableRule(id: rule.id) }
            }
        )
    }

    var body: some View {
        Toggle(isOn: isEnabled) {
            VStack(alignment: .leading, spacing: 2) {
                Text(rule.name).font(.body)
                Text("pattern: \(rule.pattern)")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Text("response: \(rule.response.replacingOccurrences(of: "\n", with: "↵"))  ·  cooldown: \(Int(rule.cooldown))s")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.switch)
    }
}
