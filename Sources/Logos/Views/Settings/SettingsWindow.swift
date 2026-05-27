import SwiftUI

struct SettingsWindow: View {
    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem { Label("General", systemImage: "gear") }

            TerminalSettingsTab()
                .tabItem { Label("Terminal", systemImage: "apple.terminal") }

            AutoHandleSettingsTab()
                .tabItem { Label("Auto-handle", systemImage: "bolt") }

            AccountsSettingsTab()
                .tabItem { Label("Accounts", systemImage: "person.2") }

            LivePreviewSettingsTab()
                .tabItem { Label("Live preview", systemImage: "doc.richtext") }

            AdvancedSettingsTab()
                .tabItem { Label("Advanced", systemImage: "wrench.adjustable") }
        }
    }
}
