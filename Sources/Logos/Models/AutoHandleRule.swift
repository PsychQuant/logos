import Foundation

public struct AutoHandleRule: Identifiable, Sendable, Hashable {

    public let id: String
    public let name: String
    public let pattern: String
    public let response: String
    public let cooldown: TimeInterval

    public init(
        id: String,
        name: String,
        pattern: String,
        response: String,
        cooldown: TimeInterval
    ) {
        self.id = id
        self.name = name
        self.pattern = pattern
        self.response = response
        self.cooldown = cooldown
    }

    public var responseBytes: [UInt8] {
        Array(response.utf8)
    }

    public func matches(_ input: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return false
        }
        let range = NSRange(input.startIndex..., in: input)
        return regex.firstMatch(in: input, range: range) != nil
    }
}

/// The 5 hardcoded v1 rules. Sub-plan H replaces this with user-configurable rules.
public extension AutoHandleRule {

    static let defaultRuleset: [AutoHandleRule] = [
        AutoHandleRule(
            id: "rate-limit",
            name: "Rate-limit keep-going",
            pattern: #"Press "keep going" to retry"#,
            response: "keep going\n",
            cooldown: 5
        ),
        AutoHandleRule(
            id: "trust-folder",
            name: "Trust folder",
            pattern: #"Yes, I trust this folder"#,
            response: "1\n",
            cooldown: 60
        ),
        AutoHandleRule(
            id: "trust-files",
            name: "Trust files",
            pattern: #"Do you trust the files"#,
            response: "y\n",
            cooldown: 60
        ),
        AutoHandleRule(
            id: "bash-permission",
            name: "Bash tool permission",
            pattern: #"Bash command:.+Allow\?"#,
            response: "y\n",
            cooldown: 5
        ),
        AutoHandleRule(
            id: "press-enter",
            name: "Press Enter",
            pattern: #"Press Enter to continue"#,
            response: "\n",
            cooldown: 2
        )
    ]
}
