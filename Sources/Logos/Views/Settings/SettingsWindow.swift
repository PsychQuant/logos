import SwiftUI

struct SettingsWindow: View {

    enum Tab: String, CaseIterable, Identifiable {
        case general = "General"
        case terminal = "Terminal"
        case autoHandle = "Auto-handle"
        case accounts = "Accounts"
        case livePreview = "Live preview"
        case advanced = "Advanced"

        var id: String { rawValue }

        var systemImage: String {
            switch self {
            case .general: "gear"
            case .terminal: "apple.terminal"
            case .autoHandle: "bolt"
            case .accounts: "person.2"
            case .livePreview: "doc.richtext"
            case .advanced: "wrench.adjustable"
            }
        }
    }

    @State private var selectedTab: Tab = .general

    var body: some View {
        TabView(selection: $selectedTab) {
            ForEach(Tab.allCases) { tab in
                VStack {
                    Image(systemName: tab.systemImage)
                        .font(.system(size: 40))
                        .foregroundStyle(.tertiary)
                    Text(tab.rawValue)
                        .font(.title2)
                    Text("Settings UI in sub-plan H")
                        .foregroundStyle(.secondary)
                }
                .frame(width: 480, height: 320)
                .tabItem {
                    Label(tab.rawValue, systemImage: tab.systemImage)
                }
                .tag(tab)
            }
        }
        .frame(width: 480, height: 360)
    }
}
