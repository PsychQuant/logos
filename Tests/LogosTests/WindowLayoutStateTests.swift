import Testing
import Foundation
@testable import Logos

/// In-memory replacement for UserDefaults so each test starts clean.
/// Plan adaptation #1: avoid UserDefaults.standard pollution between tests.
@MainActor
final class InMemoryLayoutDefaults: LayoutDefaultsStorage {
    private var store: [String: Any] = [:]
    func object(forKey key: String) -> Any? { store[key] }
    func set(_ value: Any?, forKey key: String) { store[key] = value }
}

@Suite("WindowLayoutState", .serialized)
@MainActor
struct WindowLayoutStateTests {

    @Test("default sidebar width is 200")
    func defaultSidebarWidth() {
        let state = WindowLayoutState(defaults: InMemoryLayoutDefaults())
        #expect(state.sidebarWidth == 200)
    }

    @Test("sidebar hidden when width below threshold")
    func sidebarHiddenBelowThreshold() {
        let state = WindowLayoutState(defaults: InMemoryLayoutDefaults())
        state.sidebarWidth = 30  // below 40 threshold
        #expect(state.isSidebarHidden == true)
    }

    @Test("sidebar visible when width above threshold")
    func sidebarVisibleAboveThreshold() {
        let state = WindowLayoutState(defaults: InMemoryLayoutDefaults())
        state.sidebarWidth = 100
        #expect(state.isSidebarHidden == false)
    }

    // MARK: - revealSidebar (#100)

    @Test("reveal restores default width when persisted width was sub-threshold at init")
    func revealHealsBadPersistedWidth() {
        let defaults = InMemoryLayoutDefaults()
        defaults.set(CGFloat(32.27), forKey: "logos.layout.sidebarWidth")   // the #100 broken state
        let state = WindowLayoutState(defaults: defaults)
        #expect(state.isSidebarHidden == true)
        state.revealSidebar()
        #expect(state.isSidebarHidden == false)
        #expect(state.sidebarWidth == WindowLayoutState.sidebarDefaultWidth)
    }

    @Test("reveal restores the last visible width after a drag-collapse")
    func revealRestoresLastVisibleWidth() {
        let state = WindowLayoutState(defaults: InMemoryLayoutDefaults())
        state.sidebarWidth = 300      // user's chosen width
        state.sidebarWidth = 10       // drag-collapse below threshold
        #expect(state.isSidebarHidden == true)
        state.revealSidebar()
        #expect(state.sidebarWidth == 300)
    }

    @Test("reveal is a no-op when the sidebar is already visible")
    func revealNoopWhenVisible() {
        let state = WindowLayoutState(defaults: InMemoryLayoutDefaults())
        state.sidebarWidth = 250
        state.revealSidebar()
        #expect(state.sidebarWidth == 250)
    }

    @Test("sub-threshold widths never update the remembered last-visible width")
    func subThresholdDoesNotPolluteLastVisible() {
        let state = WindowLayoutState(defaults: InMemoryLayoutDefaults())
        state.sidebarWidth = 300
        state.sidebarWidth = 30
        state.sidebarWidth = 5        // multiple sub-threshold writes
        state.revealSidebar()
        #expect(state.sidebarWidth == 300)   // 30/5 must not have become the restore target
    }

    @Test("reveal persists the restored width")
    func revealPersistsRestoredWidth() {
        let defaults = InMemoryLayoutDefaults()
        defaults.set(CGFloat(20), forKey: "logos.layout.sidebarWidth")
        let state = WindowLayoutState(defaults: defaults)
        state.revealSidebar()
        #expect((defaults.object(forKey: "logos.layout.sidebarWidth") as? CGFloat) == WindowLayoutState.sidebarDefaultWidth)
    }

    @Test("default top area height fraction is 0.6")
    func defaultTopAreaHeightFraction() {
        let state = WindowLayoutState(defaults: InMemoryLayoutDefaults())
        #expect(state.topAreaHeightFraction == 0.6)
    }

    @Test("default PDF pane width fraction is 0.5")
    func defaultPDFPaneWidthFraction() {
        let state = WindowLayoutState(defaults: InMemoryLayoutDefaults())
        #expect(state.pdfPaneWidthFraction == 0.5)
    }

    @Test("clamping: sidebar cannot exceed max")
    func sidebarClampMax() {
        let state = WindowLayoutState(defaults: InMemoryLayoutDefaults())
        state.sidebarWidth = 5000
        #expect(state.sidebarWidth <= 500)
    }

    @Test("clamping: top area fraction stays in 0.2 ... 0.8")
    func topAreaFractionClamp() {
        let state = WindowLayoutState(defaults: InMemoryLayoutDefaults())
        state.topAreaHeightFraction = 0.05
        #expect(state.topAreaHeightFraction >= 0.2)
        state.topAreaHeightFraction = 0.95
        #expect(state.topAreaHeightFraction <= 0.8)
    }
}
