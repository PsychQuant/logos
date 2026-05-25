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
