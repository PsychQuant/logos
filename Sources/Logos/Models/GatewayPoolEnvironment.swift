import SwiftUI
import LogosGateway

/// Injects the app-wide `GatewayPool` into the view tree.
///
/// A plain `EnvironmentKey` rather than `@Environment(GatewayPool.self)` because
/// that form requires `Observable` conformance, and the pool is an `actor` — its
/// state is deliberately not observable from the main actor. Views only ever call
/// `acquire` / `release` on it, never read its contents to render.
/// The process-wide gateway pool.
///
/// One instance so every pane, and the terminate handler, act on the same set of
/// children. A pane that renders without explicit injection therefore still shares
/// this pool rather than silently spawning its own gateways.
enum SharedGatewayPool {
    static let shared = GatewayPool()
}

private struct GatewayPoolKey: EnvironmentKey {
    static let defaultValue = SharedGatewayPool.shared
}

extension EnvironmentValues {
    var gatewayPool: GatewayPool {
        get { self[GatewayPoolKey.self] }
        set { self[GatewayPoolKey.self] = newValue }
    }
}
