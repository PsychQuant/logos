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
        .frame(width: 460, height: 320)
    }
}
