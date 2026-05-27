import Foundation
import Observation

@Observable
@MainActor
public final class PDFLivePreviewModel {

    public enum State: Sendable {
        case idle(reason: String?)
        case building(commandPreview: String)
        case success(pdfURL: URL, builtAt: Date)
        case failure(stderrTail: String)
    }

    @ObservationIgnored private let resolver: SourceToPDFResolver
    @ObservationIgnored private let pipeline: BuildPipeline
    @ObservationIgnored private var watcher: FileWatcher?
    @ObservationIgnored private var inFlightTask: Task<Void, Never>?

    public private(set) var activeSourcePath: String?
    public private(set) var state: State = .idle(reason: nil)
    public var workspaceConfig: WorkspaceConfig?

    public init(
        resolver: SourceToPDFResolver = SourceToPDFResolver(),
        pipeline: BuildPipeline = BuildPipeline()
    ) {
        self.resolver = resolver
        self.pipeline = pipeline
    }

    public func bind(sourcePath: String, config: WorkspaceConfig?) {
        self.workspaceConfig = config
        guard resolver.resolve(sourcePath: sourcePath, config: config) != nil else {
            state = .idle(reason: "File extension not supported (no build recipe)")
            return
        }
        activeSourcePath = sourcePath
        watcher?.stop()
        watcher = FileWatcher(path: sourcePath, debounce: 0.5) { [weak self] in
            self?.triggerBuild()
        }
        watcher?.start()
        // Initial build
        triggerBuild()
    }

    public func unbind() {
        watcher?.stop()
        watcher = nil
        inFlightTask?.cancel()
        inFlightTask = nil
        activeSourcePath = nil
        state = .idle(reason: nil)
    }

    public func triggerBuild() {
        guard let source = activeSourcePath,
              let resolution = resolver.resolve(sourcePath: source, config: workspaceConfig) else {
            return
        }
        inFlightTask?.cancel()
        state = .building(commandPreview: resolution.command)
        inFlightTask = Task { [pipeline, weak self] in
            do {
                let result = try await pipeline.run(
                    command: resolution.command,
                    workingDirectory: resolution.workingDirectory
                )
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self else { return }
                    if result.exitCode == 0 {
                        self.state = .success(
                            pdfURL: URL(fileURLWithPath: resolution.pdfPath),
                            builtAt: Date()
                        )
                    } else {
                        let tail = result.stderr.split(separator: "\n").suffix(5).joined(separator: "\n")
                        self.state = .failure(stderrTail: String(tail))
                    }
                }
            } catch {
                if !Task.isCancelled {
                    await MainActor.run {
                        self?.state = .failure(stderrTail: "\(error)")
                    }
                }
            }
        }
    }
}
