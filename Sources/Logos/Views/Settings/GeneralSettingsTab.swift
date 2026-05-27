import SwiftUI

struct GeneralSettingsTab: View {
    @Environment(GeneralSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings

        Form {
            Section("Appearance") {
                Picker("Theme", selection: $settings.theme) {
                    ForEach(GeneralSettings.Theme.allCases) { theme in
                        Text(theme.displayName).tag(theme)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section("Launch") {
                Toggle("Restore last workspace on launch",
                       isOn: $settings.restoreLastWorkspaceOnLaunch)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 320)
    }
}
