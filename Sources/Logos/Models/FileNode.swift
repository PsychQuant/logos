import Foundation

public struct FileNode: Identifiable, Hashable, Sendable {

    public enum Kind: Sendable, Hashable {
        case directory
        case file
    }

    public let path: String
    public let kind: Kind
    public let children: [FileNode]?

    public init(path: String, kind: Kind, children: [FileNode]? = nil) {
        self.path = path
        self.kind = kind
        self.children = children
    }

    public var id: String { path }

    public var displayName: String {
        (path as NSString).lastPathComponent
    }

    public var fileExtension: String {
        (path as NSString).pathExtension.lowercased()
    }

    public var isHidden: Bool {
        displayName.hasPrefix(".")
    }
}
