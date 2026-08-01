import Testing
@testable import Logos

/// #104: the account-bootstrap mode decision. Two launch-time signals decide
/// whether the app touches the REAL `~/.logos/accounts` registry (+ its
/// startup GC) or a per-launch volatile one:
///
///   - `--ui-testing` (XCUITest app, #27) — already volatile pre-#104
///   - app-hosted unit testing (#78 probe) — NEW in #104: the test host now has
///     its own bundle id (`app.getlogos.logos.testhost`), so LaunchServices no
///     longer serializes it against a live production Logos. Without registry
///     isolation, its `reapOrphanedDirectories()` startup GC could race a live
///     instance mid-createAccount — the exact #80 race
///     `LSMultipleInstancesProhibited` was added to prevent.
///
/// The decision is a pure function so both call sites (`sharedRegistry`,
/// `makeAccountManager`) derive from ONE input instead of re-testing the
/// signals independently.
@Suite("AccountBootstrap")
struct AccountBootstrapTests {

    @Test("production launch (no signals) uses the real registry")
    func productionMode() {
        #expect(AccountBootstrap.mode(
            arguments: ["/Applications/Logos.app/Contents/MacOS/Logos"],
            isHostedUnitTesting: false) == .production)
    }

    @Test("--ui-testing launches volatile (the pre-existing #27 path)")
    func uiTestingIsVolatile() {
        #expect(AccountBootstrap.mode(
            arguments: ["Logos", "--ui-testing", "--seed-accounts", "A,B"],
            isHostedUnitTesting: false) == .volatile)
    }

    @Test("app-hosted unit testing launches volatile (#104 — never reap the real registry from a test host)")
    func hostedUnitTestingIsVolatile() {
        #expect(AccountBootstrap.mode(
            arguments: ["Logos"],
            isHostedUnitTesting: true) == .volatile)
    }

    @Test("both signals together stay volatile")
    func bothSignalsVolatile() {
        #expect(AccountBootstrap.mode(
            arguments: ["Logos", "--ui-testing"],
            isHostedUnitTesting: true) == .volatile)
    }

    @Test("a workspace argument alone never flips the mode")
    func unrelatedArgsStayProduction() {
        #expect(AccountBootstrap.mode(
            arguments: ["Logos", "--workspace", "/tmp/proj"],
            isHostedUnitTesting: false) == .production)
    }
}
