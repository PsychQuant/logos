import Foundation

public struct SettingsPersistence {

    public static let defaultDirectory: String = {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!.path
        return "\(appSupport)/Logos"
    }()

    public let directory: String

    public init(directory: String = SettingsPersistence.defaultDirectory) {
        self.directory = directory
    }

    public func save<T: Encodable>(_ value: T, to filename: String) throws {
        try FileManager.default.createDirectory(
            atPath: directory,
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        try data.write(to: URL(fileURLWithPath: "\(directory)/\(filename)"))
    }

    public func load<T: Decodable>(from filename: String) throws -> T? {
        let path = "\(directory)/\(filename)"
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try JSONDecoder().decode(T.self, from: data)
    }
}
