import Foundation
import Testing
@testable import Logos

/// Records the order in which the two removal steps ran. A lock rather than an
/// actor because one of the two steps (`removeFromRegistry`) is synchronous by
/// contract and so cannot await.
private final class StepRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _steps: [String] = []

    func record(_ step: String) {
        lock.lock()
        defer { lock.unlock() }
        _steps.append(step)
    }

    var steps: [String] {
        lock.lock()
        defer { lock.unlock() }
        return _steps
    }
}

@Suite @MainActor struct AccountRemovalTests {

    /// THE invariant. The gateway child writes rate-limit state into the account's
    /// own directory, and its writer creates that directory if missing. Removing
    /// first — which reaps the directory inline — would let a still-running child
    /// recreate the tree the reaper just deleted, resurrecting exactly the orphan
    /// directory #50 exists to prevent.
    @Test func stopsTheGatewayBeforeRemovingFromTheRegistry() async {
        let recorder = StepRecorder()

        let removed = await AccountRemoval.perform(
            accountID: "ACC-1",
            stopGateway: { _ in recorder.record("stop") },
            removeFromRegistry: { _ in
                recorder.record("remove")
                return true
            }
        )

        #expect(removed)
        #expect(recorder.steps == ["stop", "remove"])
    }

    @Test func propagatesTheRegistryResult() async {
        let failed = await AccountRemoval.perform(
            accountID: "ACC-1",
            stopGateway: { _ in },
            removeFromRegistry: { _ in false }
        )
        #expect(failed == false)
    }

    /// A rolled-back remove has already cost the account its gateway. That is the
    /// deliberate trade: stopping a gateway is recoverable (the next acquire starts
    /// a fresh one), whereas reaping a directory under a live writer is not.
    @Test func stopsTheGatewayEvenWhenTheRemoveFails() async {
        let recorder = StepRecorder()

        _ = await AccountRemoval.perform(
            accountID: "ACC-1",
            stopGateway: { id in recorder.record("stop:\(id)") },
            removeFromRegistry: { _ in false }
        )

        #expect(recorder.steps == ["stop:ACC-1"])
    }

    /// The account id must reach both steps unchanged — a mismatch would stop one
    /// account's gateway while removing another's.
    @Test func passesTheSameIdToBothSteps() async {
        let recorder = StepRecorder()

        _ = await AccountRemoval.perform(
            accountID: "ACC-XYZ",
            stopGateway: { id in recorder.record("stop:\(id)") },
            removeFromRegistry: { id in
                recorder.record("remove:\(id)")
                return true
            }
        )

        #expect(recorder.steps == ["stop:ACC-XYZ", "remove:ACC-XYZ"])
    }
}
