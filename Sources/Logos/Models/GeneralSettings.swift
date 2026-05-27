import Foundation
import Observation
import SwiftUI

@Observable
@MainActor
public final class GeneralSettings {

    public enum Theme: String, CaseIterable, Codable, Identifiable, Sendable {
        case system, light, dark
        public var id: String { rawValue }
        public var displayName: String {
            switch self {
            case .system: return "System"
            case .light: return "Light"
            case .dark: return "Dark"
            }
        }
        public var colorScheme: ColorScheme? {
            switch self {
            case .system: return nil
            case .light: return .light
            case .dark: return .dark
            }
        }
    }

    @ObservationIgnored private let persistence: SettingsPersistence
    private static let filename = "general.json"

    @ObservationIgnored private var _theme: Theme = .system
    public var theme: Theme {
        get { _theme }
        set { _theme = newValue; save() }
    }

    @ObservationIgnored private var _restoreLastWorkspaceOnLaunch: Bool = true
    public var restoreLastWorkspaceOnLaunch: Bool {
        get { _restoreLastWorkspaceOnLaunch }
        set { _restoreLastWorkspaceOnLaunch = newValue; save() }
    }

    public init(persistence: SettingsPersistence = SettingsPersistence()) {
        self.persistence = persistence
        if let dto: PersistedDTO = try? persistence.load(from: Self.filename) {
            _theme = dto.theme
            _restoreLastWorkspaceOnLaunch = dto.restoreLastWorkspaceOnLaunch
        }
    }

    private func save() {
        let dto = PersistedDTO(
            theme: _theme,
            restoreLastWorkspaceOnLaunch: _restoreLastWorkspaceOnLaunch
        )
        try? persistence.save(dto, to: Self.filename)
    }

    private struct PersistedDTO: Codable {
        let theme: Theme
        let restoreLastWorkspaceOnLaunch: Bool
    }
}
