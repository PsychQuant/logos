import Testing
import Foundation
@testable import Logos

/// #78: the in-process-unit-test detection probe that gates the host app's
/// production side-effects — the real `--dangerously-skip-permissions` claude
/// spawn (`SwiftTermView.Coordinator.startIfNeeded`) and the GPU Metal
/// engagement (`TeedLocalProcessTerminalView.enableMetalIfAvailableOnce`) — when
/// `LogosHostedTests` injects its bundle into a fully-launching `Logos.app`.
///
/// The probe keys off `XCTestConfigurationFilePath`, which XCTest sets in the
/// host process env for an app-hosted `bundle.unit-test` ONLY — never in the
/// separate, clean process the XCUITest runner launches (that path
/// self-identifies via the `--ui-testing` argument, an orthogonal signal). These
/// assert against injected env dicts so the verdict is deterministic and
/// independent of whether the ambient `swift test` process itself carries the
/// variable — the reason the probe is env-injectable in the first place.
@Suite("HostedTestEnvironment")
struct HostedTestEnvironmentTests {

    @Test("true when XCTestConfigurationFilePath is present")
    func trueWhenConfigPathPresent() {
        #expect(HostedTestEnvironment.isHostedUnitTesting(
            environment: ["XCTestConfigurationFilePath": "/tmp/abc.xctestconfiguration"]
        ) == true)
    }

    @Test("false on a clean env — nothing to gate")
    func falseWhenConfigPathAbsent() {
        #expect(HostedTestEnvironment.isHostedUnitTesting(environment: [:]) == false)
    }

    @Test("false for the XCUITest-launched app: --ui-testing without the config path is not gated")
    func falseForUITestingLaunch() {
        // The XCUITest-driven app carries `--ui-testing` (a launch argument, not an
        // env var) and legitimately renders + spawns; absent `XCTestConfigurationFilePath`
        // it must stay ungated, proving the two signals never conflate.
        #expect(HostedTestEnvironment.isHostedUnitTesting(
            environment: ["LOGOS_DISABLE_METAL": "1"]
        ) == false)
    }
}
