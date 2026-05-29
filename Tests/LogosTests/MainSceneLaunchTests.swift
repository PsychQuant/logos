import Testing
import Foundation
@testable import Logos

@Suite("MainScene launch workspace resolution (#8)", .serialized)
struct MainSceneLaunchTests {

    // Treat "/" and anything under a few system roots as system, mirroring
    // WorkspaceLoader.isSystemPath at the granularity these tests need. The real
    // wiring injects WorkspaceLoader.isSystemPath(canonical(_)); here we inject a
    // deterministic stand-in so the resolver's precedence/guards are tested in
    // isolation (D4).
    private static let isSystem: @Sendable (String) -> Bool = { path in
        WorkspaceLoader.isSystemPath(WorkspaceLoader.canonical(path))
    }

    // MARK: parseWorkspaceArgument

    @Test("parses --workspace <path>")
    func parse_spaceForm() {
        #expect(MainScene.parseWorkspaceArgument(["Logos", "--workspace", "/Users/x/proj"]) == "/Users/x/proj")
    }

    @Test("parses --workspace=<path>")
    func parse_equalsForm() {
        #expect(MainScene.parseWorkspaceArgument(["Logos", "--workspace=/Users/x/proj"]) == "/Users/x/proj")
    }

    @Test("returns nil when no --workspace arg")
    func parse_none() {
        #expect(MainScene.parseWorkspaceArgument(["Logos"]) == nil)
        #expect(MainScene.parseWorkspaceArgument(["Logos", "/Users/x/positional"]) == nil) // no positional support
    }

    @Test("ignores macOS-injected GUI launch args")
    func parse_ignoresGUIArgs() {
        #expect(MainScene.parseWorkspaceArgument(["Logos", "-psn_0_123456", "-NSDocumentRevisionsDebugMode", "YES"]) == nil)
    }

    // MARK: resolveLaunchWorkspace precedence

    @Test("explicit --workspace arg wins over persisted")
    func resolve_argWinsOverPersisted() {
        let chosen = MainScene.resolveLaunchWorkspace(
            arguments: ["Logos", "--workspace", "/Users/x/arg"],
            persisted: "/Users/x/persisted",
            cwd: "/Users/x/cwd",
            isSystem: Self.isSystem
        )
        #expect(chosen == "/Users/x/arg")
    }

    @Test("a system --workspace arg is refused, falls through to persisted")
    func resolve_systemArgRefused() {
        let chosen = MainScene.resolveLaunchWorkspace(
            arguments: ["Logos", "--workspace", "/"],
            persisted: "/Users/x/persisted",
            cwd: "/Users/x/cwd",
            isSystem: Self.isSystem
        )
        #expect(chosen == "/Users/x/persisted")   // "/" refused, NOT re-introducing #2
    }

    @Test("persisted wins over cwd when no arg")
    func resolve_persistedWinsOverCwd() {
        let chosen = MainScene.resolveLaunchWorkspace(
            arguments: ["Logos"],
            persisted: "/Users/x/persisted",
            cwd: "/Users/x/cwd",
            isSystem: Self.isSystem
        )
        #expect(chosen == "/Users/x/persisted")
    }

    @Test("guarded cwd used only when no arg and no persisted")
    func resolve_cwdFallback() {
        let chosen = MainScene.resolveLaunchWorkspace(
            arguments: ["Logos"],
            persisted: nil,
            cwd: "/Users/x/cwd",
            isSystem: Self.isSystem
        )
        #expect(chosen == "/Users/x/cwd")
    }

    @Test("cwd = / is ignored (cannot re-introduce #2)")
    func resolve_cwdRootIgnored() {
        let chosen = MainScene.resolveLaunchWorkspace(
            arguments: ["Logos"],
            persisted: nil,
            cwd: "/",                       // GUI launch cwd
            isSystem: Self.isSystem
        )
        #expect(chosen == nil)              // welcome state, no walk of /
    }

    @Test("nothing resolves → nil (welcome)")
    func resolve_nothing() {
        let chosen = MainScene.resolveLaunchWorkspace(
            arguments: ["Logos"],
            persisted: nil,
            cwd: "/System",                 // system cwd refused too
            isSystem: Self.isSystem
        )
        #expect(chosen == nil)
    }
}
