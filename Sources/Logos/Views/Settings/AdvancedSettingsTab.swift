import SwiftUI

struct AdvancedSettingsTab: View {
    @Environment(AdvancedSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings

        Form {
            Section("Claude CLI") {
                TextField(
                    "Path override (leave empty for $PATH lookup)",
                    text: Binding(
                        get: { settings.claudePathOverride ?? "" },
                        set: { settings.claudePathOverride = $0 }
                    )
                )
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .help("If 'which claude' doesn't find the right binary, set its absolute path here. e.g. /opt/homebrew/bin/claude")

                if let path = settings.claudePathOverride {
                    Label(
                        FileManager.default.fileExists(atPath: path) ? "File exists" : "File NOT found at that path",
                        systemImage: FileManager.default.fileExists(atPath: path) ? "checkmark.circle" : "exclamationmark.triangle"
                    )
                    .font(.caption)
                    .foregroundStyle(FileManager.default.fileExists(atPath: path) ? Color.green : Color.red)
                }
            }

            Section("Permissions") {
                Toggle(
                    "Skip all permission prompts (dangerous mode)",
                    isOn: $settings.dangerouslySkipPermissions
                )
                .accessibilityIdentifier("logos.settings.dangerousToggle")  // #24 XCUITest query
                Label(
                    "Launches claude with --dangerously-skip-permissions: it runs tools, edits files, and executes commands without asking. Enable only in trusted directories.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(settings.dangerouslySkipPermissions ? Color.orange : Color.secondary)
                Text("Applies to new sessions / after restart.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Logging") {
                Picker("Log level", selection: $settings.logLevel) {
                    ForEach(AdvancedSettings.LogLevel.allCases) { l in
                        Text(l.displayName).tag(l)
                    }
                }
                Text("Logs at: ~/Library/Logs/Logos/")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .dialogFrame(.settings)
    }
}
