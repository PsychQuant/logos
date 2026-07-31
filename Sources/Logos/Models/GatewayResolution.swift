import Foundation

public enum GatewayResolutionError: Error, Equatable {
    case unavailable(String)
}

/// Outcome of trying to obtain an account's gateway, plus the failure policy that
/// decides what a failure means.
public enum GatewayResolution: Sendable, Equatable {

    /// Spawn claude. `nil` means spawn it direct, with no gateway — which is the
    /// correct, non-failure outcome for the system-default account and when the
    /// feature is switched off.
    case resolved(URL?)

    /// Do not spawn claude. Show the reason.
    case blocked(reason: String)

    public static func success(_ url: URL?) -> GatewayResolution { .resolved(url) }

    /// Calibrated to whether the account has a custom upstream, because the two
    /// cases fail differently.
    ///
    /// With the default upstream the gateway only adds pacing and observability, so
    /// falling back to a direct connection is a degradation — worth a warning, not
    /// worth bricking the account.
    ///
    /// With a custom upstream, falling back would route traffic to
    /// `api.anthropic.com` when the operator directed it elsewhere. That is a
    /// routing-policy violation, not a degradation, so it fails closed.
    public static func classify(
        hasCustomUpstream: Bool,
        error: GatewayResolutionError
    ) -> GatewayResolution {
        let detail: String
        switch error {
        case .unavailable(let text): detail = text
        }

        return hasCustomUpstream
            ? .blocked(reason: "Gateway unavailable and this account has a custom upstream: \(detail)")
            : .resolved(nil)
    }
}
