import Foundation
import Observation
import SwiftUI
import LogosUsage

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

    // #46: default to Dark — Logos hosts a fixed-dark terminal, so a dark chrome is the
    // cohesive default (like iTerm / Warp / Ghostty). The Theme setting still lets a user
    // opt into Light / System; a saved override in general.json always wins over this.
    @ObservationIgnored private var _theme: Theme = .dark
    public var theme: Theme {
        get { _theme }
        set { _theme = newValue; save() }
    }

    @ObservationIgnored private var _restoreLastWorkspaceOnLaunch: Bool = true
    public var restoreLastWorkspaceOnLaunch: Bool {
        get { _restoreLastWorkspaceOnLaunch }
        set { _restoreLastWorkspaceOnLaunch = newValue; save() }
    }

    /// #112: how 帳號用量 orders its rows. Defaults to `.registry` — the pre-#112 behaviour,
    /// so the window looks unchanged until the user opts into the urgency ordering.
    ///
    /// Lives here rather than in a new app-level model on purpose: a new `@Observable` would
    /// have to be injected into BOTH the WindowGroup and the Settings scene, which is exactly
    /// the hand-maintained-two-lists drift #118 is about. Reusing this one adds no new
    /// injection site. It also inherits the `--ui-testing` directory redirect, so a UI-test
    /// run cannot write the real preference file.
    @ObservationIgnored private var _usageSortOrder: UsageSortOrder = .registry
    public var usageSortOrder: UsageSortOrder {
        get { _usageSortOrder }
        set { _usageSortOrder = newValue; save() }
    }

    public init(persistence: SettingsPersistence = SettingsPersistence()) {
        self.persistence = persistence
        if let dto: PersistedDTO = try? persistence.load(from: Self.filename) {
            _theme = dto.theme
            _restoreLastWorkspaceOnLaunch = dto.restoreLastWorkspaceOnLaunch
            // Optional in the DTO so a general.json written before #112 still decodes.
            _usageSortOrder = dto.usageSortOrder ?? .registry
        }
    }

    private func save() {
        let dto = PersistedDTO(
            theme: _theme,
            restoreLastWorkspaceOnLaunch: _restoreLastWorkspaceOnLaunch,
            usageSortOrder: _usageSortOrder
        )
        try? persistence.save(dto, to: Self.filename)
    }

    private struct PersistedDTO: Codable {
        let theme: Theme
        let restoreLastWorkspaceOnLaunch: Bool
        /// #112. Optional so a file written by an older build still decodes rather than
        /// throwing and silently resetting the user's theme back to the default.
        let usageSortOrder: UsageSortOrder?
    }
}
