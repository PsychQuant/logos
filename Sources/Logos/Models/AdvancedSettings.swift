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

    @ObservationIgnored private var _dangerouslySkipPermissions: Bool = false
    /// Launch claude with `--dangerously-skip-permissions` (PsychQuant/logos#19).
    /// Opt-in fallback that bypasses ALL permission prompts — default OFF.
    public var dangerouslySkipPermissions: Bool {
        get { _dangerouslySkipPermissions }
        set { _dangerouslySkipPermissions = newValue; save() }
    }

    /// Extra args fed into `ClaudeProcessConfig.extraArgs` at spawn. Single
    /// source of the dangerous-mode flag literal (#19).
    public var claudeExtraArgs: [String] {
        dangerouslySkipPermissions ? ["--dangerously-skip-permissions"] : []
    }

    public init(persistence: SettingsPersistence = SettingsPersistence()) {
        self.persistence = persistence
        if let dto: PersistedDTO = try? persistence.load(from: Self.filename) {
            _claudePathOverride = dto.claudePathOverride
            _logLevel = dto.logLevel
            _dangerouslySkipPermissions = dto.dangerouslySkipPermissions ?? false
        }
    }

    private func save() {
        let dto = PersistedDTO(
            claudePathOverride: _claudePathOverride,
            logLevel: _logLevel,
            dangerouslySkipPermissions: _dangerouslySkipPermissions
        )
        try? persistence.save(dto, to: Self.filename)
    }

    private struct PersistedDTO: Codable {
        let claudePathOverride: String?
        let logLevel: LogLevel
        // Optional so a legacy advanced.json (predating this field) still decodes —
        // a non-optional Bool would fail the decode and reset ALL settings (#19).
        let dangerouslySkipPermissions: Bool?
    }
}
