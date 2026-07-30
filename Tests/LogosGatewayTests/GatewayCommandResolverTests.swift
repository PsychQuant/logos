import Foundation
import Testing
@testable import LogosGateway

@Suite struct GatewayCommandResolverTests {

    /// The load-bearing case. Both versions exist on the maintainer's machine,
    /// and a lexicographic max picks "1.9.0" — silently running an older proxy.
    @Test func picksHighestSemverNotLexicographic() {
        #expect(GatewayCommandResolver.highestVersion(in: ["1.9.0", "1.19.0"]) == "1.19.0")
        #expect(GatewayCommandResolver.highestVersion(in: ["1.19.0", "1.9.0"]) == "1.19.0")
        #expect(GatewayCommandResolver.highestVersion(in: ["2.0.0", "10.0.0"]) == "10.0.0")
    }

    @Test func ignoresNonNumericDirectoryNames() {
        #expect(GatewayCommandResolver.highestVersion(in: [".DS_Store", "unknown", "1.2.3"]) == "1.2.3")
        #expect(GatewayCommandResolver.highestVersion(in: ["unknown"]) == nil)
        #expect(GatewayCommandResolver.highestVersion(in: []) == nil)
    }

    @Test func resolvesArgvWhenScriptExists() throws {
        let home = FileManager.default.temporaryDirectory
            .appending(path: "gw-resolve-\(UUID().uuidString)")
        let versionDir = home.appending(
            path: ".claude/plugins/cache/claude-hot-limit/claude-hot-limit/1.19.0/proxy"
        )
        try FileManager.default.createDirectory(at: versionDir, withIntermediateDirectories: true)
        let script = versionDir.appending(path: "rate-limit-proxy.py")
        try Data("print('x')".utf8).write(to: script)
        defer { try? FileManager.default.removeItem(at: home) }

        let argv = GatewayCommandResolver.resolve(home: home)
        #expect(argv == ["/usr/bin/env", "python3", script.path])
    }

    /// A newer version directory that does NOT carry the script must not shadow an
    /// older one that does — otherwise a half-installed plugin yields no gateway at
    /// all rather than the working older proxy.
    @Test func fallsBackWhenTheNewestVersionLacksTheScript() throws {
        let home = FileManager.default.temporaryDirectory
            .appending(path: "gw-partial-\(UUID().uuidString)")
        let root = home.appending(
            path: ".claude/plugins/cache/claude-hot-limit/claude-hot-limit"
        )
        // 1.19.0 exists but is empty; 1.9.0 has the script.
        try FileManager.default.createDirectory(
            at: root.appending(path: "1.19.0"), withIntermediateDirectories: true)
        let goodDir = root.appending(path: "1.9.0/proxy")
        try FileManager.default.createDirectory(at: goodDir, withIntermediateDirectories: true)
        let script = goodDir.appending(path: "rate-limit-proxy.py")
        try Data("print('x')".utf8).write(to: script)
        defer { try? FileManager.default.removeItem(at: home) }

        #expect(GatewayCommandResolver.resolve(home: home) == ["/usr/bin/env", "python3", script.path])
    }

    @Test func returnsNilWhenPluginAbsent() {
        let home = FileManager.default.temporaryDirectory
            .appending(path: "gw-absent-\(UUID().uuidString)")
        #expect(GatewayCommandResolver.resolve(home: home) == nil)
    }
}
