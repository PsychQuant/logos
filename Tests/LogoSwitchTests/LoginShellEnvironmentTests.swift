import Testing
import Foundation
@testable import LogoSwitch

/// Tests for the login-shell environment resolver (PsychQuant/logos#33).
/// A Finder/Spotlight launch hands Logos the bare launchd environment (minimal
/// PATH, no claude), so Logos hydrates the user's real environment by running
/// `$SHELL -ilc` with a sentinel-delimited `/usr/bin/env -0` dump. These tests
/// cover the PARSER + fallback + caching with injected canned dumps — the real
/// shell spawn is deliberately not unit-tested (machine-dependent).
@Suite("LoginShellEnvironment", .serialized)
@MainActor
struct LoginShellEnvironmentTests {

    /// Build a realistic raw dump: profile noise, "BEGIN\n", null-terminated
    /// KEY=VALUE entries, "END\n", trailing noise.
    private func dump(entries: [String], noiseBefore: String = "profile says hi\n", noiseAfter: String = "bye\n") -> Data {
        var d = Data()
        d.append(Data(noiseBefore.utf8))
        d.append(Data("\(LoginShellEnvironment.beginSentinel)\n".utf8))
        for e in entries {
            d.append(Data(e.utf8))
            d.append(0)
        }
        d.append(Data("\(LoginShellEnvironment.endSentinel)\n".utf8))
        d.append(Data(noiseAfter.utf8))
        return d
    }

    @Test("parses a standard null-delimited dump between sentinels")
    func parsesStandardDump() {
        let raw = dump(entries: ["PATH=/usr/bin:/Users/x/.local/bin", "HOME=/Users/x", "SHELL=/bin/zsh"])
        let env = LoginShellEnvironment.parse(raw)
        #expect(env?["PATH"] == "/usr/bin:/Users/x/.local/bin")
        #expect(env?["HOME"] == "/Users/x")
        #expect(env?.count == 3)
    }

    @Test("splits on the FIRST '=' only — values containing '=' survive")
    func valueWithEquals() {
        let raw = dump(entries: ["LS_COLORS=di=34:ln=35"])
        #expect(LoginShellEnvironment.parse(raw)?["LS_COLORS"] == "di=34:ln=35")
    }

    @Test("values containing newlines survive (the reason for env -0)")
    func valueWithNewline() {
        let raw = dump(entries: ["MULTI=line one\nline two"])
        #expect(LoginShellEnvironment.parse(raw)?["MULTI"] == "line one\nline two")
    }

    @Test("profile noise outside the sentinels is ignored")
    func ignoresProfileNoise() {
        let raw = dump(
            entries: ["A=1"],
            noiseBefore: "Last login: today\nmotd nonsense\n",
            noiseAfter: "PROFILE_TRAP=should-not-appear\n"
        )
        let env = LoginShellEnvironment.parse(raw)
        #expect(env?["A"] == "1")
        #expect(env?["PROFILE_TRAP"] == nil)
    }

    @Test("missing sentinels → nil (caller falls back)")
    func missingSentinelsIsNil() {
        #expect(LoginShellEnvironment.parse(Data("no markers here".utf8)) == nil)
    }

    @Test("resolve falls back to the process environment when the dump fails")
    func resolveFallsBackOnDumpFailure() {
        LoginShellEnvironment._resetForTesting()
        defer { LoginShellEnvironment._resetForTesting() }
        LoginShellEnvironment.dumpProvider = { _, _ in nil }   // shell failed / timed out
        let fallback = ["PATH": "/bare", "SHELL": "/bin/zsh"]
        let env = LoginShellEnvironment.resolve(processEnvironment: fallback)
        #expect(env == fallback)
    }

    @Test("resolve caches — the shell dump runs at most once per launch")
    func resolveCaches() {
        LoginShellEnvironment._resetForTesting()
        defer { LoginShellEnvironment._resetForTesting() }
        nonisolated(unsafe) var calls = 0
        let raw = dump(entries: ["PATH=/hydrated"])
        LoginShellEnvironment.dumpProvider = { _, _ in calls += 1; return raw }
        _ = LoginShellEnvironment.resolve(processEnvironment: [:])
        let env = LoginShellEnvironment.resolve(processEnvironment: [:])
        #expect(calls == 1)
        #expect(env["PATH"] == "/hydrated")
    }

    @Test("uses $SHELL from the process env; falls back to /bin/zsh when unset")
    func shellSelection() {
        LoginShellEnvironment._resetForTesting()
        defer { LoginShellEnvironment._resetForTesting() }
        nonisolated(unsafe) var seenShell: String?
        LoginShellEnvironment.dumpProvider = { shell, _ in seenShell = shell; return nil }
        _ = LoginShellEnvironment.resolve(processEnvironment: ["SHELL": "/opt/fish"])
        #expect(seenShell == "/opt/fish")

        LoginShellEnvironment._resetForTesting()   // also restores the real provider —
        LoginShellEnvironment.dumpProvider = { shell, _ in seenShell = shell; return nil }   // re-inject
        _ = LoginShellEnvironment.resolve(processEnvironment: [:])   // no SHELL
        #expect(seenShell == "/bin/zsh")
    }

    @Test("an empty parsed dict falls back (garbage dump never yields an empty env)")
    func emptyParseFallsBack() {
        LoginShellEnvironment._resetForTesting()
        defer { LoginShellEnvironment._resetForTesting() }
        // Sentinels present but zero entries between them.
        LoginShellEnvironment.dumpProvider = { _, _ in self.dump(entries: []) }
        let fallback = ["PATH": "/bare"]
        #expect(LoginShellEnvironment.resolve(processEnvironment: fallback) == fallback)
    }
}
