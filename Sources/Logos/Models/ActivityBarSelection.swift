import Foundation
import Observation

/// Activity bar tab selection + sidebar visibility.
///
/// Click semantics:
///   - Click inactive tab → switch to it, sidebar becomes visible
///   - Click active tab → toggle sidebar visibility
@Observable
@MainActor
public final class ActivityBarSelection {

    /// Only browsable sidebar panels are tabs. Settings is an action (opens the
    /// Settings window) and account switching lives in the status bar, so
    /// neither is a `Tab` — see `ActivityBarView`.
    public enum Tab: String, CaseIterable, Identifiable, Sendable {
        case files
        case search
        case sessions

        public var id: String { rawValue }

        public var systemImage: String {
            switch self {
            case .files: "folder"
            case .search: "magnifyingglass"
            case .sessions: "rectangle.stack"
            }
        }

        public var label: String {
            switch self {
            case .files: "Files"
            case .search: "Search"
            case .sessions: "Sessions"
            }
        }
    }

    public private(set) var active: Tab = .files
    public private(set) var isVisible: Bool = true

    public init() {}

    public func select(_ tab: Tab) {
        if tab == active {
            isVisible.toggle()
        } else {
            active = tab
            isVisible = true
        }
    }
}
