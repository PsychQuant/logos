import Foundation

public struct FileNode: Identifiable, Hashable, Sendable {

    public enum Kind: Sendable, Hashable {
        case directory
        case file
    }

    public let path: String
    public let kind: Kind
    public let children: [FileNode]?

    /// A directory that exists but is not expanded — either TCC-protected
    /// (would trigger a macOS consent dialog if descended) or unreadable
    /// (permission denied). Surfaced as an opaque leaf so the user sees it
    /// rather than it silently vanishing from the tree (Issue #13).
    public let isProtected: Bool

    public init(path: String, kind: Kind, children: [FileNode]? = nil, isProtected: Bool = false) {
        self.path = path
        self.kind = kind
        self.children = children
        self.isProtected = isProtected
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
