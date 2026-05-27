import Foundation

public struct Account: Identifiable, Hashable, Sendable, Codable {

    public let id: String  // stable account identifier, used as HOME directory name
    public let label: String  // user-visible name; editable
    public let createdAt: Date

    public init(id: String = UUID().uuidString, label: String, createdAt: Date = Date()) {
        self.id = id
        self.label = label.trimmingCharacters(in: .whitespaces)
        self.createdAt = createdAt
    }

    public var homeDirectoryPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.logos/accounts/\(id)"
    }

    public enum ValidationError: Error, Equatable {
        case emptyLabel
        case labelTooLong
        case duplicateLabel
    }

    /// Validate label only (duplicate-check requires AccountManager).
    public static func validate(label: String) throws -> String {
        let trimmed = label.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { throw ValidationError.emptyLabel }
        if trimmed.count > 30 { throw ValidationError.labelTooLong }
        return trimmed
    }
}
