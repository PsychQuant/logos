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

    @Test("reveal sets active tab and visibility without ever toggling (#100)")
    func revealNeverToggles() {
        let s = ActivityBarSelection()
        s.select(.files)          // toggle off (hidden)
        s.reveal(.files)          // reveal — must SHOW, not toggle
        #expect(s.isVisible == true)
        #expect(s.active == .files)
        s.reveal(.files)          // reveal again — still visible (non-toggling)
        #expect(s.isVisible == true)
        s.reveal(.search)         // reveal a different tab — switches + stays visible
        #expect(s.active == .search)
        #expect(s.isVisible == true)
    }

    @Test("clickOutcome: toggle only when effectively shown; reveal otherwise (#100)")
    func clickOutcomeMatrix() {
        typealias S = ActivityBarSelection
        // Active tab, flag visible, width healthy → the only toggle-hide case.
        #expect(S.clickOutcome(tab: .files, active: .files, isVisible: true, sidebarHiddenByWidth: false) == .toggleHide)
        // The #100 broken state (flag true, width sub-threshold): FIRST click must reveal, not toggle.
        #expect(S.clickOutcome(tab: .files, active: .files, isVisible: true, sidebarHiddenByWidth: true) == .reveal)
        // Hidden by flag (either width state) → reveal.
        #expect(S.clickOutcome(tab: .files, active: .files, isVisible: false, sidebarHiddenByWidth: false) == .reveal)
        #expect(S.clickOutcome(tab: .files, active: .files, isVisible: false, sidebarHiddenByWidth: true) == .reveal)
        // A different tab always reveals, regardless of visibility state.
        #expect(S.clickOutcome(tab: .search, active: .files, isVisible: true, sidebarHiddenByWidth: false) == .reveal)
        #expect(S.clickOutcome(tab: .search, active: .files, isVisible: false, sidebarHiddenByWidth: true) == .reveal)
    }

    @Test("isShownAsActive uses effective visibility, not the raw flag (#100 verify C1)")
    func isShownAsActiveEffective() {
        typealias S = ActivityBarSelection
        #expect(S.isShownAsActive(tab: .files, active: .files, isVisible: true, sidebarHiddenByWidth: false) == true)
        // Drag-collapsed: flag still true but sidebar gone — the icon must NOT read as active.
        #expect(S.isShownAsActive(tab: .files, active: .files, isVisible: true, sidebarHiddenByWidth: true) == false)
        #expect(S.isShownAsActive(tab: .files, active: .files, isVisible: false, sidebarHiddenByWidth: false) == false)
        #expect(S.isShownAsActive(tab: .search, active: .files, isVisible: true, sidebarHiddenByWidth: false) == false)
    }

    @Test("three browsable tabs defined")
    func tabCount() {
        // Settings became an action button and account moved to the status bar,
        // so only the browsable panels remain (#85).
        #expect(ActivityBarSelection.Tab.allCases.count == 3)
    }
}
