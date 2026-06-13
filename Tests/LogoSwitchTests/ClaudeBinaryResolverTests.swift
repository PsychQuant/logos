import Testing
import LogoSwitch

@Suite("ClaudeBinaryResolver", .serialized)
struct ClaudeBinaryResolverTests {

    // MARK: searchPath (moved from TerminalConfigTests, #33)

    @Test("searchPath finds claude on the hydrated PATH when the bare PATH misses it (#33)")
    func searchPathFindsClaudeOnHydratedPath() {
        let hydratedPath = "/usr/bin:/bin:/Users/x/.local/bin"
        let found = ClaudeBinaryResolver.searchPath(
            for: "claude",
            in: hydratedPath,
            isExecutable: { $0 == "/Users/x/.local/bin/claude" }
        )
        #expect(found == "/Users/x/.local/bin/claude")
    }

    @Test("searchPath honors PATH order — first match wins")
    func searchPathFirstMatchWins() {
        let found = ClaudeBinaryResolver.searchPath(
            for: "claude",
            in: "/a:/b",
            isExecutable: { $0 == "/a/claude" || $0 == "/b/claude" }
        )
        #expect(found == "/a/claude")
    }

    @Test("searchPath returns nil for nil/empty PATH or no executable match")
    func searchPathNilCases() {
        #expect(ClaudeBinaryResolver.searchPath(for: "claude", in: nil, isExecutable: { _ in true }) == nil)
        #expect(ClaudeBinaryResolver.searchPath(for: "claude", in: "", isExecutable: { _ in true }) == nil)
        #expect(ClaudeBinaryResolver.searchPath(for: "claude", in: "/a:/b", isExecutable: { _ in false }) == nil)
    }

    @Test("searchPath skips empty PATH components (leading/double colons)")
    func searchPathSkipsEmptyComponents() {
        let found = ClaudeBinaryResolver.searchPath(
            for: "claude",
            in: "::/a",
            isExecutable: { $0 == "/a/claude" }
        )
        #expect(found == "/a/claude")
    }

    // MARK: resolve() order (override → PATH → which → nil)

    @Test("resolve returns the override verbatim, short-circuiting PATH + which")
    func resolveOverrideWins() {
        let r = ClaudeBinaryResolver()
        let path = r.resolve(
            override: "/opt/homebrew/bin/claude",
            path: "/should/not/matter",
            isExecutable: { _ in true },          // would match, but override wins first
            which: { _ in "/never/used" }
        )
        #expect(path == "/opt/homebrew/bin/claude")
    }

    @Test("resolve searches the hydrated PATH before falling back to which")
    func resolvePrefersPathOverWhich() {
        let r = ClaudeBinaryResolver()
        let path = r.resolve(
            override: nil,
            path: "/usr/bin:/Users/x/.local/bin",
            isExecutable: { $0 == "/Users/x/.local/bin/claude" },
            which: { _ in "/usr/bin/which-fallback" }   // must NOT be used
        )
        #expect(path == "/Users/x/.local/bin/claude")
    }

    @Test("resolve falls back to which when PATH search misses (pre-#33 behavior)")
    func resolveFallsBackToWhich() {
        let r = ClaudeBinaryResolver()
        let path = r.resolve(
            override: nil,
            path: "/usr/bin:/bin",                 // no claude here
            isExecutable: { _ in false },
            which: { $0 == "claude" ? "/fallback/claude" : nil }
        )
        #expect(path == "/fallback/claude")
    }

    @Test("resolve returns nil when override, PATH, and which all miss")
    func resolveAllMiss() {
        let r = ClaudeBinaryResolver()
        let path = r.resolve(
            override: nil,
            path: nil,
            isExecutable: { _ in false },
            which: { _ in nil }
        )
        #expect(path == nil)
    }
}
