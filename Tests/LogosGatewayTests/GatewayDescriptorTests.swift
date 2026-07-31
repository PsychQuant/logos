import Foundation
import Testing
@testable import LogosGateway

@Suite struct GatewayDescriptorTests {

    private func makeDescriptor(
        port: UInt16 = 51234,
        upstream: URL = GatewayDescriptor.defaultUpstream
    ) -> GatewayDescriptor {
        GatewayDescriptor(
            accountID: "ACC-1",
            command: ["/usr/bin/env", "python3", "/tmp/proxy.py"],
            port: port,
            stateDirectory: "/tmp/acc-1/hot-limit",
            upstream: upstream
        )
    }

    @Test func baseURLTargetsLoopbackOnTheAssignedPort() {
        #expect(makeDescriptor(port: 51234).baseURL.absoluteString == "http://127.0.0.1:51234")
    }

    /// The three knobs the proxy already reads. Getting a name wrong here means the
    /// child silently falls back to its defaults — port 8787 and the SHARED state
    /// file — which is precisely the bug this feature exists to fix.
    @Test func environmentCarriesPortUpstreamAndStateDir() {
        let env = makeDescriptor().environment
        #expect(env["RATE_LIMIT_PROXY_PORT"] == "51234")
        #expect(env["RATE_LIMIT_PROXY_UPSTREAM"] == "https://api.anthropic.com")
        #expect(env["CLAUDE_HOT_LIMIT_DATA"] == "/tmp/acc-1/hot-limit")
    }

    @Test func environmentCarriesACustomUpstream() {
        let env = makeDescriptor(upstream: URL(string: "https://gateway.example.com")!).environment
        #expect(env["RATE_LIMIT_PROXY_UPSTREAM"] == "https://gateway.example.com")
    }

    /// State lives INSIDE the account dir so AccountReaper cleans it up with the
    /// account and needs no change of its own.
    @Test func stateDirectoryNestsInsideTheAccountHome() {
        let path = GatewayDescriptor.stateDirectory(forAccountHome: "/Users/x/.logos/accounts/ACC-1")
        #expect(path == "/Users/x/.logos/accounts/ACC-1/hot-limit")
    }

    /// Two accounts must never share a state directory — a shared rate-state file
    /// is exactly the cross-account throttling this feature removes.
    @Test func distinctAccountHomesYieldDistinctStateDirectories() {
        let a = GatewayDescriptor.stateDirectory(forAccountHome: "/Users/x/.logos/accounts/ACC-A")
        let b = GatewayDescriptor.stateDirectory(forAccountHome: "/Users/x/.logos/accounts/ACC-B")
        #expect(a != b)
    }
}
