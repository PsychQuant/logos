import Foundation
import os

/// Logging handles for the per-account gateway layer.
///
/// Shares the app-wide `app.getlogos.logos` subsystem so a single
/// `log show --predicate 'subsystem == "app.getlogos.logos"'` covers gateway
/// events alongside the rest of the app (the Track A smoke reads this trail).
public enum GatewayLog {

    public static let subsystem = "app.getlogos.logos"

    public static let pool = Logger(subsystem: subsystem, category: "gateway-pool")
    public static let process = Logger(subsystem: subsystem, category: "gateway-process")
    public static let resolver = Logger(subsystem: subsystem, category: "gateway-resolver")
}
