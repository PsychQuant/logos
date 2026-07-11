import Foundation

/// Coalesces concurrent usage-refresh passes onto a single shared, **cancellation-
/// aware** Task, cancelling that pass only when its LAST live observer goes away.
///
/// Two forces pull against each other here (see #51 and #81):
///
/// - **Coalescing (#51):** overlapping `refreshAll()` callers must share ONE pass.
///   The first authorization pass reads each account's Keychain entry synchronously,
///   which can raise a macOS authorization dialog; two serialized passes running at
///   once interleave and re-stack those dialogs. So the pass runs in an unstructured
///   `Task` that no single caller owns — a structured child would let whichever
///   caller cancels first abort the pass for everyone else still awaiting it.
///
/// - **Cancellation (#81):** an unstructured `Task` does NOT inherit its creator's
///   cancellation. `URLSession.data(for:delegate:)` auto-cancels its transfer only
///   when ITS calling Task is cancelled, and the coalescing wrapper severed that
///   link — so closing the usage window (its SwiftUI `.task` cancelled) left the
///   in-flight usage fetches running to completion in the background. No wrong state,
///   just wasted network and CPU nobody is waiting on.
///
/// The reconciliation is reference counting. Every caller awaiting the shared pass
/// is an observer. A caller whose await is cancelled drops its slot; the shared pass
/// is cancelled only once the count reaches zero — the moment no observer is left
/// that still wants the result. One caller leaving never disturbs the others, so the
/// #51 coalescing guarantee holds while the #81 waste is eliminated.
///
/// `@MainActor` so the check-and-set that creates-or-joins a pass carries no
/// suspension between its read and write: on the serial main actor it is atomic
/// against other callers, no lock needed.
@MainActor
final class RefreshCoalescer {
    /// The single in-flight pass, if one is running.
    private var inFlight: Task<Void, Never>?
    /// Live observers of `inFlight`: callers currently awaiting it that have neither
    /// completed nor been cancelled. Reaching zero cancels the shared pass.
    private var observerCount = 0

    /// Runs `body` as the one shared pass, coalescing concurrent callers onto it.
    /// The FIRST caller's `body` becomes the pass; a coalescing caller's `body` is
    /// never invoked (it awaits the running pass instead).
    ///
    /// - Returns: `true` if the pass finished WITHOUT being cancelled, so the caller
    ///   can gate first-pass-complete bookkeeping on a clean finish — a cancelled
    ///   first pass must re-serialize next time rather than fan out (#51).
    @discardableResult
    func run(_ body: @escaping @MainActor () async -> Void) async -> Bool {
        // Create-or-join is synchronous up to the first `await` below, so on the
        // serial main actor it is atomic against other callers (#51 coalescing).
        let task: Task<Void, Never>
        if let inFlight {
            task = inFlight
        } else {
            task = Task { @MainActor in await body() }
            inFlight = task
        }
        observerCount += 1

        // Await the shared pass, but notice if THIS caller is cancelled (its window
        // closed). We do not cancel the shared task here — only drop an observer
        // slot; the last one to leave cancels the pass (#81).
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            // onCancel runs off the main actor; hop back to touch the counters.
            Task { @MainActor [weak self] in self?.observerLeft(task) }
        }

        // The pass has ended (completed or cancelled). The first caller to fall
        // through clears it so the next `run` starts fresh; the identity check
        // (`Task` is Equatable on the underlying task) makes a late cancellation or
        // an already-replaced pass a no-op.
        let finishedCleanly = !task.isCancelled
        if inFlight == task {
            inFlight = nil
            observerCount = 0
        }
        return finishedCleanly
    }

    /// One observer's await was cancelled. Drop its slot; when none remain, nobody
    /// still wants the result, so cancel the shared pass — that propagates into the
    /// per-account `URLSession` fetches and stops the wasted work (#81).
    private func observerLeft(_ task: Task<Void, Never>) {
        // Ignore a cancellation that lands after the pass already ended or was
        // replaced by a newer one — those observer slots no longer matter.
        guard inFlight == task, observerCount > 0 else { return }
        observerCount -= 1
        if observerCount == 0 {
            task.cancel()
        }
    }
}
