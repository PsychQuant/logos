import Testing
import Foundation
@testable import Logos
import LogoSwitch

/// #42: per-window account binding. `WindowAccountResolver` is the pure, SwiftUI-free
/// core — a value-in/value-out helper (mirroring `MainScene.resolveLaunchWorkspace`)
/// so the seeding precedence + graceful-degrade behavior is the `swift test` unit gate,
/// not a Track-B-only concern.
@Suite("WindowAccountResolver")
struct WindowAccountResolverTests {

    private func acc(_ id: String, _ label: String) -> Account {
        Account(id: id, label: label, createdAt: Date(timeIntervalSince1970: 0))
    }

    private var two: [Account] { [acc("1", "work"), acc("2", "personal")] }

    // MARK: seed precedence — presented → default → first → nil

    @Test("seed: a live presented value wins")
    func seedPresented() {
        #expect(WindowAccountResolver.seed(presented: "2", default: "1", accounts: two) == "2")
    }

    @Test("seed: an unknown presented value falls back to the default")
    func seedPresentedUnknown() {
        #expect(WindowAccountResolver.seed(presented: "ghost", default: "1", accounts: two) == "1")
    }

    @Test("seed: an unknown default falls back to the first account")
    func seedDefaultUnknown() {
        #expect(WindowAccountResolver.seed(presented: nil, default: "ghost", accounts: two) == "1")
    }

    @Test("seed: no accounts yields nil")
    func seedEmpty() {
        #expect(WindowAccountResolver.seed(presented: "1", default: "1", accounts: []) == nil)
    }

    // MARK: resolve — live id → account; nil / deleted id → nil (graceful degrade)

    @Test("resolve: a live id returns the matching account")
    func resolveLive() {
        #expect(WindowAccountResolver.resolve(selected: "2", accounts: two)?.label == "personal")
    }

    @Test("resolve: a nil selection returns nil")
    func resolveNil() {
        #expect(WindowAccountResolver.resolve(selected: nil, accounts: two) == nil)
    }

    @Test("resolve: a since-deleted id returns nil (no phantom config dir)")
    func resolveDeleted() {
        #expect(WindowAccountResolver.resolve(selected: "ghost", accounts: two) == nil)
    }

    // MARK: reseededId — #42 verify DA-1/M1 + DA-2/M2 (no stranded window)

    @Test("reseededId: keeps a still-live current selection")
    func reseedKeepsLive() {
        #expect(WindowAccountResolver.reseededId(current: "2", default: "1", accounts: two) == "2")
    }

    @Test("reseededId: a deleted current account re-seeds to the default")
    func reseedDeletedToDefault() {
        // "2" was deleted, only "1" remains, default "1" is live → "1"
        let oneLeft = [acc("1", "work")]
        #expect(WindowAccountResolver.reseededId(current: "2", default: "1", accounts: oneLeft) == "1")
    }

    @Test("reseededId: an empty-at-launch window seeds to first once accounts appear")
    func reseedEmptyToFirst() {
        #expect(WindowAccountResolver.reseededId(current: nil, default: nil, accounts: two) == "1")
    }

    @Test("reseededId: no accounts stays nil")
    func reseedNoAccounts() {
        #expect(WindowAccountResolver.reseededId(current: "1", default: "1", accounts: []) == nil)
    }
}
