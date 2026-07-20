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

    /// Non-toggling show (#100): activate `tab` and make the sidebar visible,
    /// regardless of prior state. Used by the recovery paths (activity-bar click on
    /// an effectively-hidden sidebar, reveal-on-workspace-open) where `select`'s
    /// active-tab toggle would hide instead of show.
    public func reveal(_ tab: Tab) {
        active = tab
        isVisible = true
    }

    /// What a click on `tab` should do (#100). Pure so the view glue is testable.
    public enum ClickOutcome: Equatable, Sendable {
        /// The tab is effectively shown → collapse (toggle off).
        case toggleHide
        /// Hidden for either reason, or switching tabs → non-toggling reveal + width restore.
        case reveal
    }

    /// Single source of truth for "this tab reads as the open sidebar panel": the tab is
    /// active AND the sidebar actually renders. `isVisible` alone lies in the #100 broken
    /// state (width below threshold with the flag still true) — both the icon highlight
    /// and the click decision must use this effective form, or the icon stays lit while
    /// the sidebar is gone.
    public static func isShownAsActive(
        tab: Tab, active: Tab, isVisible: Bool, sidebarHiddenByWidth: Bool
    ) -> Bool {
        tab == active && isVisible && !sidebarHiddenByWidth
    }

    /// Click decision on effective visibility: an effectively-shown active tab toggles
    /// closed; everything else (hidden by flag, hidden by width, or a different tab)
    /// reveals. Pure — unit-tested across all combinations.
    public static func clickOutcome(
        tab: Tab, active: Tab, isVisible: Bool, sidebarHiddenByWidth: Bool
    ) -> ClickOutcome {
        isShownAsActive(tab: tab, active: active, isVisible: isVisible,
                        sidebarHiddenByWidth: sidebarHiddenByWidth)
            ? .toggleHide : .reveal
    }
}
