import Foundation

public struct OpenFileTab: Identifiable, Hashable, Sendable {
    public let path: String
    public init(path: String) { self.path = path }
    public var id: String { path }
    public var displayName: String { (path as NSString).lastPathComponent }
}
