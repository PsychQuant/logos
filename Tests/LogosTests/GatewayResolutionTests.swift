import Foundation
import Testing
@testable import Logos

@Suite struct GatewayResolutionTests {

    /// Default upstream: the gateway only adds pacing and observability, so losing
    /// it degrades telemetry but must not brick the account.
    @Test nonisolated func failsOpenOnDefaultUpstream() {
        let resolution = GatewayResolution.classify(
            hasCustomUpstream: false,
            error: .unavailable("plugin not installed")
        )
        #expect(resolution == .resolved(nil))
    }

    /// Custom upstream: falling back to api.anthropic.com would send traffic
    /// somewhere the operator did not direct it. Refuse instead.
    @Test nonisolated func failsClosedOnCustomUpstream() {
        let resolution = GatewayResolution.classify(
            hasCustomUpstream: true,
            error: .unavailable("plugin not installed")
        )
        guard case .blocked(let reason) = resolution else {
            Issue.record("expected blocked, got \(resolution)")
            return
        }
        #expect(reason.contains("plugin not installed"))
    }

    @Test nonisolated func successPassesTheURLThrough() {
        let url = URL(string: "http://127.0.0.1:51234")!
        #expect(GatewayResolution.success(url) == .resolved(url))
    }

    /// A successful resolution with no gateway (system-default, or the feature
    /// switched off) is NOT a failure and must never render as blocked.
    @Test nonisolated func successWithNoGatewayIsResolvedNotBlocked() {
        #expect(GatewayResolution.success(nil) == .resolved(nil))
    }

    /// The banner distinguishes "running unmetered" from "refused to start", so the
    /// two outcomes must be distinguishable by the view.
    @Test nonisolated func blockedAndResolvedAreDistinguishable() {
        let blocked = GatewayResolution.classify(
            hasCustomUpstream: true, error: .unavailable("boom"))
        let open = GatewayResolution.classify(
            hasCustomUpstream: false, error: .unavailable("boom"))
        #expect(blocked != open)
    }
}
