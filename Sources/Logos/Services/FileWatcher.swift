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

    // No deinit cleanup: Swift 6 strict concurrency disallows access to
    // non-Sendable FSEventStreamRef from nonisolated deinit. Callers
    // (PDFLivePreviewModel) MUST call .stop() explicitly on unbind.
}
