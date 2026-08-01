import Foundation

/// Which account registry a launch binds to (#104).
enum AccountBootstrapMode: Equatable {
    /// The real shared `~/.logos/accounts` index (+ one-time legacy migration
    /// and the #50 startup GC of orphaned account dirs).
    case production
    /// A per-launch temp index + volatile UserDefaults suite; never reads,
    /// writes, or reaps the real account list.
    case volatile
}

/// Pure launch-time decision shared by `LogosApp.sharedRegistry` and
/// `LogosApp.makeAccountManager` so the two sites can never disagree.
///
/// Volatile triggers:
///   - `--ui-testing` (#27): the XCUITest-launched app must render seeded stub
///     accounts without touching the dev machine's real account list.
///   - app-hosted unit testing (#78 probe, volatile since #104): the Track B
///     test host runs under its own bundle id (`app.getlogos.logos.testhost`),
///     so `LSMultipleInstancesProhibited` no longer serializes it against a
///     live production Logos. Its startup GC (`reapOrphanedDirectories`) racing
///     a live instance mid-createAccount is exactly the #80 registry race that
///     key exists to prevent — so the test host must not bind the real
///     registry at all.
enum AccountBootstrap {
    static func mode(arguments: [String], isHostedUnitTesting: Bool) -> AccountBootstrapMode {
        arguments.contains("--ui-testing") || isHostedUnitTesting ? .volatile : .production
    }
}
