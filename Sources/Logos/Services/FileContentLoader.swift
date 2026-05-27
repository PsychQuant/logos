import Foundation

public struct FileContentLoader {

    public enum Error: Swift.Error, Equatable {
        case tooLarge(actualBytes: Int, maxBytes: Int)
        case notUtf8
    }

    public static let defaultMaxBytes: Int = 5 * 1024 * 1024  // 5MB

    public let maxBytes: Int

    public init(maxBytes: Int = FileContentLoader.defaultMaxBytes) {
        self.maxBytes = maxBytes
    }

    public func load(path: String) throws -> String {
        let url = URL(fileURLWithPath: path)
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        let size = (attrs[.size] as? Int) ?? 0
        if size > maxBytes {
            throw Error.tooLarge(actualBytes: size, maxBytes: maxBytes)
        }
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) else {
            throw Error.notUtf8
        }
        return text
    }
}
