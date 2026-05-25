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

    public enum Tab: String, CaseIterable, Identifiable, Sendable {
        case files
        case search
        case sessions
        case settings
        case account

        public var id: String { rawValue }

        public var systemImage: String {
            switch self {
            case .files: "folder"
            case .search: "magnifyingglass"
            case .sessions: "rectangle.stack"
            case .settings: "gearshape"
            case .account: "person.crop.circle"
            }
        }

        public var label: String {
            switch self {
            case .files: "Files"
            case .search: "Search"
            case .sessions: "Sessions"
            case .settings: "Settings"
            case .account: "Account"
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
