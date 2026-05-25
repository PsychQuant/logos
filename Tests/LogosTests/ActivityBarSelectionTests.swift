import Testing
@testable import Logos

@Suite("ActivityBarSelection", .serialized)
@MainActor
struct ActivityBarSelectionTests {

    @Test("default selection is files")
    func defaultIsFiles() {
        let s = ActivityBarSelection()
        #expect(s.active == .files)
        #expect(s.isVisible == true)
    }

    @Test("clicking different tab switches selection and stays visible")
    func switchTab() {
        let s = ActivityBarSelection()
        s.select(.search)
        #expect(s.active == .search)
        #expect(s.isVisible == true)
    }

    @Test("clicking active tab toggles visibility off")
    func toggleHide() {
        let s = ActivityBarSelection()
        s.select(.files)  // already files
        #expect(s.isVisible == false)
    }

    @Test("clicking active tab again toggles visibility on")
    func toggleShow() {
        let s = ActivityBarSelection()
        s.select(.files)  // hides
        s.select(.files)  // shows again
        #expect(s.isVisible == true)
    }

    @Test("five tabs defined")
    func tabCount() {
        #expect(ActivityBarSelection.Tab.allCases.count == 5)
    }
}
