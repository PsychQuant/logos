import Foundation
import Observation

@Observable
@MainActor
public final class AdvancedSettings {

    public enum LogLevel: String, CaseIterable, Codable, Identifiable, Sendable {
        case debug, info, warn, error
        public var id: String { rawValue }
        public var displayName: String { rawValue.capitalized }
    }

    @ObservationIgnored private let persistence: SettingsPersistence
    private static let filename = "advanced.json"

    @ObservationIgnored private var _claudePathOverride: String?
    public var claudePathOverride: String? {
        get { _claudePathOverride }
        set {
            let trimmed = newValue?.trimmingCharacters(in: .whitespaces)
            _claudePathOverride = (trimmed?.isEmpty == false) ? trimmed : nil
            save()
        }
    }

    @ObservationIgnored private var _logLevel: LogLevel = .info
    public var logLevel: LogLevel {
        get { _logLevel }
        set { _logLevel = newValue; save() }
    }

    public init(persistence: SettingsPersistence = SettingsPersistence()) {
        self.persistence = persistence
        if let dto: PersistedDTO = try? persistence.load(from: Self.filename) {
            _claudePathOverride = dto.claudePathOverride
            _logLevel = dto.logLevel
        }
    }

    private func save() {
        let dto = PersistedDTO(
            claudePathOverride: _claudePathOverride,
            logLevel: _logLevel
        )
        try? persistence.save(dto, to: Self.filename)
    }

    private struct PersistedDTO: Codable {
        let claudePathOverride: String?
        let logLevel: LogLevel
    }
}
