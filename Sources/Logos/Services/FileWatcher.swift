import Foundation
import CoreServices

@MainActor
public final class FileWatcher {

    private let watchPath: String
    private let debounce: TimeInterval
    private let callback: () -> Void

    private var stream: FSEventStreamRef?
    private var debounceTimer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "app.getlogos.logos.filewatcher")

    public init(path: String, debounce: TimeInterval = 0.5, callback: @escaping () -> Void) {
        self.watchPath = path
        self.debounce = debounce
        self.callback = callback
    }

    public func start() {
        let parentDir = (watchPath as NSString).deletingLastPathComponent
        let pathsToWatch: CFArray = [parentDir] as CFArray

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let callbackC: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let me = Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue()
            DispatchQueue.main.async {
                me.handleFSEvent()
            }
        }

        stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callbackC,
            &context,
            pathsToWatch,
            UInt64(kFSEventStreamEventIdSinceNow),
            0.1,
            UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        )
        guard let s = stream else { return }
        FSEventStreamSetDispatchQueue(s, queue)
        FSEventStreamStart(s)
    }

    public func stop() {
        if let s = stream {
            FSEventStreamStop(s)
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
            stream = nil
        }
        debounceTimer?.cancel()
        debounceTimer = nil
    }

    private func handleFSEvent() {
        debounceTimer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue.main)
        t.schedule(deadline: .now() + debounce)
        t.setEventHandler { [weak self] in
            self?.callback()
        }
        t.resume()
        debounceTimer = t
    }

    /// #91: self-cleaning backstop. The FSEventStream holds `passUnretained(self)`, so a running
    /// stream on a deallocated watcher derefs freed memory on the next event (use-after-free).
    /// A plain nonisolated `deinit` can't touch the non-Sendable `FSEventStreamRef`, but
    /// `isolated deinit` (SE-0371, Swift 6.1+) runs on this `@MainActor` type's actor, so `stop()`
    /// — which invalidates + releases the stream — is reachable. `stop()` is idempotent, so an
    /// owner that already called it on unbind/teardown (`PDFLivePreviewModel.unbind`,
    /// `WindowUsageModel`) is unaffected; this guarantees cleanup even when they don't.
    isolated deinit {
        stop()
    }
}
