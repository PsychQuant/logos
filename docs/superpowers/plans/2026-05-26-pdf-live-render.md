# Sub-plan G — PDF Live Render (LaTeX / Markdown / Custom Pipelines)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement task-by-task.

**Goal:** Replace `PDFPanePlaceholder` with a PDFKit-based live preview pane. When Claude edits `notes.tex`, `latexmk` rebuilds → PDF reloads in the right pane within ~1 second. Same flow works for `.md → pandoc → .pdf`, and any custom command via per-workspace `.logosconfig.yaml`.

**Why this matters:** This is the **LaTeX user's killer feature**. Today's workflow: edit .tex in Cursor → save → tab to Skim/Preview → cmd+R to reload → tab back. With G, all that disappears. Aimed at maintainer's own che-latex-mcp / pdf-to-latex-swift workflow + every academic / technical writer using Claude.

**Resolved design decisions:**
- **Renderer**: `PDFKit` (built-in, free, full-featured). No external PDF library needed.
- **File watcher**: `FSEvents` via low-level `FSEventStreamCreate` (no Swift wrapper needed; ~30 LoC of CoreFoundation interop).
- **Build command**: configurable per project via `.logosconfig.yaml`. Defaults:
  - `.tex` → `latexmk -pdf -interaction=nonstopmode -synctex=1 {source}`
  - `.md` → `pandoc -o {source-stem}.pdf {source}` (assumes pandoc with default LaTeX engine)
  - others → user must configure
- **Debounce**: 500ms after last change before triggering build. Prevents mid-save rebuilds.
- **Build failure**: show inline banner with last 5 lines of stderr + "Open log" button (opens `<source-stem>.log` in editor pane if exists).
- **Pane visibility**: PDF pane always visible. Shows empty state ("Open a .tex or .md to enable live preview") when nothing bound. (Resolves design § 10.4 → **always visible**.)

**Prerequisites:**
- ✅ Sub-plan A (PDFPanePlaceholder exists)
- ✅ Sub-plan F (WorkspaceModel — we need `activeTab` to know which file to bind to)
- ⚠️ Sub-plan F must ship first OR this plan must include a workspace stub for file selection. **Assumption: F ships first.**

**Tech Stack:** Swift 6, PDFKit, FSEvents (CoreFoundation interop), `Foundation.Process` for subprocess, `Yams` (SwiftPM) for YAML parsing

**What this sub-plan does NOT include:**
- In-app build of pandoc/latexmk/etc. — user must have these installed (we shell out)
- PDF annotation / search / text selection inside the PDF beyond PDFKit defaults
- Multiple simultaneous source-file → PDF bindings (one active source per window for v1)
- LaTeX error parsing into structured form — show raw last-N-lines for v1

---

## File Structure

```
logos/
├── Package.swift                                              MODIFY — add Yams
├── Sources/Logos/
│   ├── Models/
│   │   ├── PDFLivePreviewModel.swift                          NEW — @Observable
│   │   └── WorkspaceConfig.swift                              NEW — .logosconfig.yaml parsing
│   ├── Services/
│   │   ├── FileWatcher.swift                                  NEW — FSEvents wrapper
│   │   ├── BuildPipeline.swift                                NEW — Process runner with debounce
│   │   └── SourceToPDFResolver.swift                          NEW — extension → command map
│   ├── Views/
│   │   └── MainArea/
│   │       ├── PDFPanePlaceholder.swift                       DELETE
│   │       ├── PDFLiveRenderView.swift                        NEW — main pane view
│   │       ├── PDFViewerNSView.swift                          NEW — NSViewRepresentable around PDFView
│   │       ├── PDFEmptyStateView.swift                        NEW
│   │       └── PDFBuildErrorBanner.swift                      NEW
│   └── App/
│       └── MainScene.swift                                    MODIFY — inject PDFLivePreviewModel
├── Tests/LogosTests/
│   ├── PDFLivePreviewModelTests.swift                         NEW
│   ├── WorkspaceConfigTests.swift                             NEW
│   ├── SourceToPDFResolverTests.swift                         NEW
│   └── BuildPipelineTests.swift                               NEW
```

---

## Task 1: Add Yams (YAML parser) dependency

**Files:**
- Modify: `Package.swift`

- [ ] **Step 1: Add Yams**

```swift
dependencies: [
    .package(url: "https://github.com/PsychQuant/SwiftTerm.git", branch: "logos-renderer-base"),
    .package(url: "https://github.com/raspu/Highlightr.git", from: "2.2.1"),
    .package(url: "https://github.com/jpsim/Yams.git", from: "5.0.0")
]
```

And target:

```swift
.executableTarget(
    name: "Logos",
    dependencies: [
        .product(name: "SwiftTerm", package: "SwiftTerm"),
        .product(name: "Highlightr", package: "Highlightr"),
        .product(name: "Yams", package: "Yams")
    ]
),
```

- [ ] **Step 2: Resolve + build + commit**

```bash
swift package update
swift build
git add Package.swift Package.resolved
git commit -m "feat(pdf): G-Task 1 — add Yams YAML parser dependency

jpsim/Yams 5.0+. Used to parse per-workspace .logosconfig.yaml
which specifies build commands + PDF preview mappings."
```

---

## Task 2: SourceToPDFResolver + tests

**Files:**
- Create: `Sources/Logos/Services/SourceToPDFResolver.swift`
- Test: `Tests/LogosTests/SourceToPDFResolverTests.swift`

**Purpose:** Given a source file path (e.g., `notes.tex`), return:
- The build command to run (`latexmk -pdf -interaction=nonstopmode -synctex=1 notes.tex`)
- The expected PDF output path (`notes.pdf`)

Defaults map extension → command. User can override via WorkspaceConfig (next task).

- [ ] **Step 1: Failing test**

```swift
import Testing
import Foundation
@testable import Logos

@Suite("SourceToPDFResolver", .serialized)
struct SourceToPDFResolverTests {

    @Test("tex default uses latexmk")
    func texDefault() {
        let r = SourceToPDFResolver()
        let result = r.resolve(sourcePath: "/work/notes.tex", config: nil)
        #expect(result?.command.starts(with: "latexmk") == true)
        #expect(result?.pdfPath == "/work/notes.pdf")
        #expect(result?.workingDirectory == "/work")
    }

    @Test("md default uses pandoc")
    func mdDefault() {
        let r = SourceToPDFResolver()
        let result = r.resolve(sourcePath: "/work/draft.md", config: nil)
        #expect(result?.command.contains("pandoc") == true)
        #expect(result?.pdfPath == "/work/draft.pdf")
    }

    @Test("unknown extension returns nil")
    func unknownExt() {
        let r = SourceToPDFResolver()
        let result = r.resolve(sourcePath: "/work/notes.txt", config: nil)
        #expect(result == nil)
    }

    @Test("config override wins over default")
    func configOverrides() {
        let cfg = WorkspaceConfig(builds: [
            .init(sourceGlob: "*.tex", command: "make notes.pdf", pdfPath: "notes.pdf")
        ])
        let r = SourceToPDFResolver()
        let result = r.resolve(sourcePath: "/work/notes.tex", config: cfg)
        #expect(result?.command == "make notes.pdf")
    }
}
```

- [ ] **Step 2: Implement** (WorkspaceConfig stub first since test references it; full WorkspaceConfig in Task 3)

```swift
import Foundation

public struct SourceToPDFResolution: Sendable {
    public let command: String
    public let pdfPath: String
    public let workingDirectory: String
}

public struct SourceToPDFResolver {

    public init() {}

    public func resolve(sourcePath: String, config: WorkspaceConfig?) -> SourceToPDFResolution? {
        let url = URL(fileURLWithPath: sourcePath)
        let stem = url.deletingPathExtension().lastPathComponent
        let dir = url.deletingLastPathComponent().path
        let ext = url.pathExtension.lowercased()

        // Config override first
        if let cfg = config,
           let match = cfg.matchingBuild(for: sourcePath) {
            return SourceToPDFResolution(
                command: match.command,
                pdfPath: "\(dir)/\(match.pdfPath)",
                workingDirectory: dir
            )
        }

        // Defaults
        switch ext {
        case "tex":
            return SourceToPDFResolution(
                command: "latexmk -pdf -interaction=nonstopmode -synctex=1 \(url.lastPathComponent)",
                pdfPath: "\(dir)/\(stem).pdf",
                workingDirectory: dir
            )
        case "md", "markdown":
            return SourceToPDFResolution(
                command: "pandoc -o \(stem).pdf \(url.lastPathComponent)",
                pdfPath: "\(dir)/\(stem).pdf",
                workingDirectory: dir
            )
        default:
            return nil
        }
    }
}
```

- [ ] **Step 3: Stub WorkspaceConfig to make test compile** (full implementation in Task 3)

```swift
// Temporary stub — Task 3 expands.
public struct WorkspaceConfig: Sendable {
    public struct Build: Sendable {
        public let sourceGlob: String
        public let command: String
        public let pdfPath: String
        public init(sourceGlob: String, command: String, pdfPath: String) {
            self.sourceGlob = sourceGlob
            self.command = command
            self.pdfPath = pdfPath
        }
    }
    public let builds: [Build]
    public init(builds: [Build]) { self.builds = builds }

    /// Returns first matching build for the given source path.
    /// Simple `*.ext` glob match for v1.
    public func matchingBuild(for sourcePath: String) -> Build? {
        let name = (sourcePath as NSString).lastPathComponent
        return builds.first { b in
            if b.sourceGlob.hasPrefix("*.") {
                return name.hasSuffix(String(b.sourceGlob.dropFirst(1)))
            }
            return name == b.sourceGlob
        }
    }
}
```

- [ ] **Step 4: Run tests + commit**

```bash
swift test --filter SourceToPDFResolverTests
git add Sources/Logos/Services/SourceToPDFResolver.swift \
        Sources/Logos/Models/WorkspaceConfig.swift \
        Tests/LogosTests/SourceToPDFResolverTests.swift
git commit -m "feat(pdf): G-Task 2 — SourceToPDFResolver with .tex/.md defaults + config override

latexmk -pdf for .tex (with synctex=1 for editor-PDF sync future).
pandoc -o for .md/.markdown. Returns command + expected PDF path +
working directory. Config-override path wired (WorkspaceConfig stub
for now; full parser in G-Task 3). 4 tests."
```

---

## Task 3: WorkspaceConfig YAML parser + tests

**Files:**
- Modify: `Sources/Logos/Models/WorkspaceConfig.swift` — flesh out stub
- Test: `Tests/LogosTests/WorkspaceConfigTests.swift`

**Purpose:** Parse `.logosconfig.yaml` at workspace root. Format:

```yaml
builds:
  - source: "*.tex"
    command: latexmk -pdf -interaction=nonstopmode {source}
    preview: "{stem}.pdf"
  - source: notes.md
    command: pandoc -t pdf -o notes.pdf notes.md
    preview: notes.pdf
```

Template variables `{source}` and `{stem}` get substituted at resolve time.

- [ ] **Step 1: Failing test**

```swift
import Testing
import Foundation
import Yams
@testable import Logos

@Suite("WorkspaceConfig", .serialized)
struct WorkspaceConfigTests {

    @Test("parses minimal config")
    func parsesMinimal() throws {
        let yaml = """
        builds:
          - source: "*.tex"
            command: latexmk -pdf {source}
            preview: "{stem}.pdf"
        """
        let cfg = try WorkspaceConfig.parse(yamlString: yaml)
        #expect(cfg.builds.count == 1)
        #expect(cfg.builds[0].sourceGlob == "*.tex")
    }

    @Test("substitutes {source} and {stem}")
    func substitution() throws {
        let yaml = """
        builds:
          - source: "*.tex"
            command: latexmk -pdf {source}
            preview: "{stem}.pdf"
        """
        let cfg = try WorkspaceConfig.parse(yamlString: yaml)
        let resolved = cfg.builds[0].resolved(forSourceFile: "notes.tex")
        #expect(resolved.command == "latexmk -pdf notes.tex")
        #expect(resolved.pdfPath == "notes.pdf")
    }

    @Test("missing file returns nil from load(at:)")
    func missingFile() {
        let cfg = try? WorkspaceConfig.load(workspaceRoot: "/nonexistent")
        #expect(cfg == nil)
    }

    @Test("loads from actual workspace root")
    func loadsFromFile() throws {
        let dir = NSTemporaryDirectory() + "logos-wc-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let yaml = """
        builds:
          - source: "*.md"
            command: pandoc {source}
            preview: out.pdf
        """
        try yaml.write(toFile: "\(dir)/.logosconfig.yaml", atomically: true, encoding: .utf8)

        let cfg = try WorkspaceConfig.load(workspaceRoot: dir)
        #expect(cfg?.builds.count == 1)
    }
}
```

- [ ] **Step 2: Flesh out `WorkspaceConfig.swift`**

```swift
import Foundation
import Yams

public struct WorkspaceConfig: Sendable, Codable {

    public struct Build: Sendable, Codable {
        public let sourceGlob: String     // YAML key: source
        public let command: String
        public let pdfPath: String        // YAML key: preview

        enum CodingKeys: String, CodingKey {
            case sourceGlob = "source"
            case command
            case pdfPath = "preview"
        }

        public init(sourceGlob: String, command: String, pdfPath: String) {
            self.sourceGlob = sourceGlob
            self.command = command
            self.pdfPath = pdfPath
        }

        public struct Resolved: Sendable {
            public let command: String
            public let pdfPath: String
        }

        public func resolved(forSourceFile sourceFileName: String) -> Resolved {
            let stem = (sourceFileName as NSString).deletingPathExtension
            let cmdSub = command
                .replacingOccurrences(of: "{source}", with: sourceFileName)
                .replacingOccurrences(of: "{stem}", with: stem)
            let pdfSub = pdfPath
                .replacingOccurrences(of: "{source}", with: sourceFileName)
                .replacingOccurrences(of: "{stem}", with: stem)
            return Resolved(command: cmdSub, pdfPath: pdfSub)
        }
    }

    public let builds: [Build]

    public init(builds: [Build]) {
        self.builds = builds
    }

    public func matchingBuild(for sourcePath: String) -> Build? {
        let name = (sourcePath as NSString).lastPathComponent
        return builds.first { b in
            if b.sourceGlob.hasPrefix("*.") {
                return name.hasSuffix(String(b.sourceGlob.dropFirst(1)))
            }
            return name == b.sourceGlob
        }
    }

    public static func parse(yamlString: String) throws -> WorkspaceConfig {
        let decoder = YAMLDecoder()
        return try decoder.decode(WorkspaceConfig.self, from: yamlString)
    }

    public static func load(workspaceRoot: String) throws -> WorkspaceConfig? {
        let path = "\(workspaceRoot)/.logosconfig.yaml"
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let yamlText = try String(contentsOfFile: path, encoding: .utf8)
        return try parse(yamlString: yamlText)
    }
}
```

- [ ] **Step 3: Update SourceToPDFResolver to use resolved templates** — modify the config-override branch:

```swift
if let cfg = config, let match = cfg.matchingBuild(for: sourcePath) {
    let resolved = match.resolved(forSourceFile: url.lastPathComponent)
    return SourceToPDFResolution(
        command: resolved.command,
        pdfPath: "\(dir)/\(resolved.pdfPath)",
        workingDirectory: dir
    )
}
```

- [ ] **Step 4: Run + commit**

```bash
swift test --filter WorkspaceConfigTests
swift test --filter SourceToPDFResolverTests
git add -A
git commit -m "feat(pdf): G-Task 3 — WorkspaceConfig YAML parser with {source} {stem} templates

.logosconfig.yaml schema: builds[] of {source, command, preview}.
Glob matching: *.ext or exact filename. Template substitution for
{source} (filename incl ext) and {stem} (filename without ext).
Yams decoder. 4 tests including real-file load."
```

---

## Task 4: FileWatcher (FSEvents wrapper) + tests

**Files:**
- Create: `Sources/Logos/Services/FileWatcher.swift`
- Test: `Tests/LogosTests/FileWatcherTests.swift`

**Purpose:** Watch a single file path. Fire callback when content changes. Debounce 500ms (configurable) to avoid mid-write triggers.

FSEvents notes: FSEventStreamCreate works on directories. To watch a single file, watch its parent directory and filter by path inside the callback. Debounce via `DispatchSourceTimer`.

- [ ] **Step 1: Failing test**

Tests use a real temp file + observe that writing to it triggers the callback (within debounce + tolerance).

```swift
import Testing
import Foundation
@testable import Logos

@Suite("FileWatcher", .serialized)
@MainActor
struct FileWatcherTests {

    @Test("fires callback on file write")
    func firesOnWrite() async throws {
        let dir = NSTemporaryDirectory() + "logos-fw-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let path = "\(dir)/watched.txt"
        try "v1".write(toFile: path, atomically: true, encoding: .utf8)

        var fireCount = 0
        let watcher = FileWatcher(path: path, debounce: 0.05) {
            fireCount += 1
        }
        watcher.start()

        // Wait a tick, then write
        try await Task.sleep(nanoseconds: 100_000_000)
        try "v2".write(toFile: path, atomically: true, encoding: .utf8)
        try await Task.sleep(nanoseconds: 300_000_000)

        watcher.stop()
        #expect(fireCount >= 1)
    }

    @Test("debounce coalesces rapid writes")
    func debounceCoalesces() async throws {
        let dir = NSTemporaryDirectory() + "logos-fw-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = "\(dir)/watched.txt"
        try "x".write(toFile: path, atomically: true, encoding: .utf8)

        var fireCount = 0
        let watcher = FileWatcher(path: path, debounce: 0.2) {
            fireCount += 1
        }
        watcher.start()

        // Burst of writes
        try await Task.sleep(nanoseconds: 100_000_000)
        for v in 0..<5 {
            try "v\(v)".write(toFile: path, atomically: true, encoding: .utf8)
            try await Task.sleep(nanoseconds: 30_000_000)  // < debounce
        }
        try await Task.sleep(nanoseconds: 500_000_000)  // wait past debounce

        watcher.stop()
        // With 200ms debounce + writes every 30ms, all 5 should coalesce to ~1 fire
        #expect(fireCount <= 2)
    }
}
```

- [ ] **Step 2: Implement** (CoreFoundation interop)

```swift
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

        let context = UnsafeMutablePointer<FSEventStreamContext>.allocate(capacity: 1)
        context.initialize(to: FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        ))

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
            context,
            pathsToWatch,
            UInt64(kFSEventStreamEventIdSinceNow),
            0.1,  // latency
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
        // Schedule (or reschedule) debounce timer
        debounceTimer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue.main)
        t.schedule(deadline: .now() + debounce)
        t.setEventHandler { [weak self] in
            self?.callback()
        }
        t.resume()
        debounceTimer = t
    }

    deinit {
        if let s = stream {
            FSEventStreamStop(s)
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
        }
    }
}
```

- [ ] **Step 3: Run + commit**

```bash
swift test --filter FileWatcherTests
git add Sources/Logos/Services/FileWatcher.swift Tests/LogosTests/FileWatcherTests.swift
git commit -m "feat(pdf): G-Task 4 — FileWatcher FSEvents + debounce + 2 tests

Watches parent directory of target path via FSEventStreamCreate
(kFSEventStreamCreateFlagFileEvents). Callback fires on any file
event in parent dir; we don't filter to target path because
debouncing into a single 'something changed' signal is sufficient.

DispatchSourceTimer for debounce coalescing. Tests verify single
write fires once, rapid burst fires <= 2."
```

---

## Task 5: BuildPipeline + tests

**Files:**
- Create: `Sources/Logos/Services/BuildPipeline.swift`
- Test: `Tests/LogosTests/BuildPipelineTests.swift`

**Purpose:** Run a shell command in a working directory. Capture stdout + stderr. Report exit code. Run async with cancellation (in case file changes again before build finishes — kill in-flight build).

- [ ] **Step 1: Failing test using `echo` + `false` for deterministic exit codes**

```swift
import Testing
import Foundation
@testable import Logos

@Suite("BuildPipeline", .serialized)
@MainActor
struct BuildPipelineTests {

    @Test("runs success command")
    func runSuccess() async throws {
        let pipeline = BuildPipeline()
        let result = try await pipeline.run(
            command: "echo hello",
            workingDirectory: "/tmp"
        )
        #expect(result.exitCode == 0)
        #expect(result.stdout.contains("hello"))
    }

    @Test("captures stderr")
    func capturesStderr() async throws {
        let pipeline = BuildPipeline()
        let result = try await pipeline.run(
            command: "echo error >&2; exit 1",
            workingDirectory: "/tmp"
        )
        #expect(result.exitCode == 1)
        #expect(result.stderr.contains("error"))
    }

    @Test("cancellation kills in-flight")
    func cancellation() async throws {
        let pipeline = BuildPipeline()
        let task = Task {
            try await pipeline.run(
                command: "sleep 10",
                workingDirectory: "/tmp"
            )
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        let result = try? await task.value
        // Either nil from cancellation OR exitCode != 0 from SIGTERM
        if let r = result {
            #expect(r.exitCode != 0)
        }
    }
}
```

- [ ] **Step 2: Implement**

```swift
import Foundation

public actor BuildPipeline {

    public struct Result: Sendable {
        public let exitCode: Int32
        public let stdout: String
        public let stderr: String
    }

    public init() {}

    public func run(command: String, workingDirectory: String) async throws -> Result {
        try await withTaskCancellationHandler {
            try await runImpl(command: command, workingDirectory: workingDirectory)
        } onCancel: {
            // Cancellation handled inside runImpl via terminate
        }
    }

    private func runImpl(command: String, workingDirectory: String) async throws -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command]
        process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Result, Error>) in
            process.terminationHandler = { proc in
                let outData = (try? stdoutPipe.fileHandleForReading.readToEnd()) ?? Data()
                let errData = (try? stderrPipe.fileHandleForReading.readToEnd()) ?? Data()
                cont.resume(returning: Result(
                    exitCode: proc.terminationStatus,
                    stdout: String(data: outData, encoding: .utf8) ?? "",
                    stderr: String(data: errData, encoding: .utf8) ?? ""
                ))
            }
            do {
                try process.run()
                // Hook cancellation: when parent Task cancels, terminate
                Task {
                    while !Task.isCancelled, process.isRunning {
                        try? await Task.sleep(nanoseconds: 50_000_000)
                    }
                    if process.isRunning { process.terminate() }
                }
            } catch {
                cont.resume(throwing: error)
            }
        }
    }
}
```

- [ ] **Step 3: Run + commit**

```bash
swift test --filter BuildPipelineTests
git add Sources/Logos/Services/BuildPipeline.swift Tests/LogosTests/BuildPipelineTests.swift
git commit -m "feat(pdf): G-Task 5 — BuildPipeline actor with shell exec + cancellation + 3 tests

zsh -c <command> in working directory. Captures stdout/stderr/exit
separately. Task cancellation triggers process.terminate() (SIGTERM).

Actor isolation: serializes builds if multiple invocations race
(latest debounced file change wins after prior cancels)."
```

---

## Task 6: PDFLivePreviewModel + tests

**Files:**
- Create: `Sources/Logos/Models/PDFLivePreviewModel.swift`
- Test: `Tests/LogosTests/PDFLivePreviewModelTests.swift`

**Purpose:** @Observable orchestrator: source path → watcher → pipeline → PDF URL state.

States:
- `.idle` — no source bound
- `.building` — build running
- `.success(pdfURL)` — last build succeeded; URL ready for PDFView
- `.failure(stderr)` — last build failed; show banner with stderr tail

- [ ] **Step 1: Failing test** (uses BuildPipeline directly, no FileWatcher — testing orchestration logic)

```swift
import Testing
import Foundation
@testable import Logos

@Suite("PDFLivePreviewModel", .serialized)
@MainActor
struct PDFLivePreviewModelTests {

    @Test("starts idle")
    func startsIdle() {
        let m = PDFLivePreviewModel()
        if case .idle = m.state { return }
        Issue.record("Expected .idle, got \(m.state)")
    }

    @Test("binding sets source")
    func binding() {
        let m = PDFLivePreviewModel()
        m.bind(sourcePath: "/tmp/notes.tex", config: nil)
        #expect(m.activeSourcePath == "/tmp/notes.tex")
    }

    @Test("unsupported extension goes to idle with reason")
    func unsupportedExt() {
        let m = PDFLivePreviewModel()
        m.bind(sourcePath: "/tmp/notes.txt", config: nil)
        if case .idle(let reason) = m.state {
            #expect(reason?.contains("supported") == true || reason?.contains("recognized") == true)
        } else {
            Issue.record("Expected .idle with reason")
        }
    }

    @Test("clears binding returns to idle")
    func unbind() {
        let m = PDFLivePreviewModel()
        m.bind(sourcePath: "/tmp/notes.tex", config: nil)
        m.unbind()
        #expect(m.activeSourcePath == nil)
        if case .idle = m.state { return }
        Issue.record("Expected .idle after unbind")
    }
}
```

- [ ] **Step 2: Implement**

```swift
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
        inFlightTask = Task { [pipeline] in
            do {
                let result = try await pipeline.run(
                    command: resolution.command,
                    workingDirectory: resolution.workingDirectory
                )
                guard !Task.isCancelled else { return }
                if result.exitCode == 0 {
                    self.state = .success(
                        pdfURL: URL(fileURLWithPath: resolution.pdfPath),
                        builtAt: Date()
                    )
                } else {
                    let tail = result.stderr.split(separator: "\n").suffix(5).joined(separator: "\n")
                    self.state = .failure(stderrTail: String(tail))
                }
            } catch {
                if !Task.isCancelled {
                    self.state = .failure(stderrTail: "\(error)")
                }
            }
        }
    }
}
```

- [ ] **Step 3: Run + commit**

```bash
swift test --filter PDFLivePreviewModelTests
git add Sources/Logos/Models/PDFLivePreviewModel.swift Tests/LogosTests/PDFLivePreviewModelTests.swift
git commit -m "feat(pdf): G-Task 6 — PDFLivePreviewModel @Observable orchestrator + 4 tests

State machine: idle / building / success(URL, builtAt) / failure(stderr).
bind(sourcePath:config:) starts FileWatcher + initial build. Subsequent
file changes debounce → triggerBuild() cancels in-flight + starts new.

Workspace config injected at bind time. unbind() cleans watcher +
in-flight task."
```

---

## Task 7: PDF viewer SwiftUI views

**Files:**
- Delete: `Sources/Logos/Views/MainArea/PDFPanePlaceholder.swift`
- Create: `Sources/Logos/Views/MainArea/PDFViewerNSView.swift`
- Create: `Sources/Logos/Views/MainArea/PDFLiveRenderView.swift`
- Create: `Sources/Logos/Views/MainArea/PDFEmptyStateView.swift`
- Create: `Sources/Logos/Views/MainArea/PDFBuildErrorBanner.swift`
- Modify: `Sources/Logos/Views/MainArea/TopPanesView.swift` — use new view

- [ ] **Step 1: `PDFViewerNSView.swift`**

```swift
import SwiftUI
import PDFKit

struct PDFViewerNSView: NSViewRepresentable {
    let url: URL
    let builtAt: Date  // forces re-render on rebuild

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.backgroundColor = NSColor.windowBackgroundColor
        load(into: view)
        return view
    }

    func updateNSView(_ nsView: PDFView, context: Context) {
        load(into: nsView)
    }

    private func load(into view: PDFView) {
        if let doc = PDFDocument(url: url) {
            // Preserve current page if same doc
            let prevPage = view.currentPage?.label
            view.document = doc
            if let prev = prevPage, let page = doc.page(at: Int(prev) ?? 0 - 1) {
                view.go(to: page)
            }
        }
    }
}
```

- [ ] **Step 2: `PDFEmptyStateView.swift`**

```swift
import SwiftUI

struct PDFEmptyStateView: View {
    let reason: String?

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.richtext")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text("No live preview")
                .font(.headline)
                .foregroundStyle(.secondary)
            if let r = reason {
                Text(r)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            } else {
                Text("Open a .tex or .md file in the editor to enable live preview.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.windowBackgroundColor))
    }
}
```

- [ ] **Step 3: `PDFBuildErrorBanner.swift`**

```swift
import SwiftUI

struct PDFBuildErrorBanner: View {
    let stderrTail: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.octagon.fill")
                .font(.system(size: 40))
                .foregroundStyle(.red)
            Text("Build failed")
                .font(.headline)
            ScrollView {
                Text(stderrTail.isEmpty ? "(no stderr output)" : stderrTail)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Color(NSColor.controlBackgroundColor))
                    .cornerRadius(4)
            }
            .frame(maxHeight: 180)
            .padding(.horizontal, 24)
            Text("Edit the source to retry.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.windowBackgroundColor))
    }
}
```

- [ ] **Step 4: `PDFLiveRenderView.swift`**

```swift
import SwiftUI

struct PDFLiveRenderView: View {
    @Environment(PDFLivePreviewModel.self) private var model
    @Environment(WorkspaceModel.self) private var workspace

    var body: some View {
        ZStack {
            switch model.state {
            case .idle(let reason):
                PDFEmptyStateView(reason: reason)
            case .building(let cmd):
                buildingOverlay(commandPreview: cmd)
            case .success(let url, let builtAt):
                PDFViewerNSView(url: url, builtAt: builtAt)
            case .failure(let stderr):
                PDFBuildErrorBanner(stderrTail: stderr)
            }
        }
        .onChange(of: workspace.activeTab) { _, newTab in
            if let path = newTab?.path {
                Task {
                    let cfg = workspace.rootNode.flatMap { try? WorkspaceConfig.load(workspaceRoot: $0.path) }
                    model.bind(sourcePath: path, config: cfg)
                }
            } else {
                model.unbind()
            }
        }
    }

    private func buildingOverlay(commandPreview: String) -> some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Building…")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text(commandPreview)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(2)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.windowBackgroundColor))
    }
}
```

- [ ] **Step 5: Delete placeholder + update `TopPanesView.swift`**

```bash
rm Sources/Logos/Views/MainArea/PDFPanePlaceholder.swift
```

In `TopPanesView.swift`, swap `PDFPanePlaceholder()` → `PDFLiveRenderView()`.

- [ ] **Step 6: Build + commit**

```bash
swift build
git add -A
git commit -m "feat(pdf): G-Task 7 — PDF viewer views (PDFViewerNSView, empty/building/error states)

PDFViewerNSView wraps PDFKit.PDFView (singlePageContinuous vertical).
builtAt parameter forces re-render on rebuild.

PDFLiveRenderView observes workspace.activeTab change → model.bind()
or unbind(). Renders one of 4 states (idle/building/success/failure)
with explanatory UI for each.

PDFPanePlaceholder.swift deleted."
```

---

## Task 8: MainScene wires PDFLivePreviewModel + live smoke

**Files:**
- Modify: `Sources/Logos/App/MainScene.swift`

- [ ] **Step 1: Inject into environment**

```swift
@State private var pdfPreview = PDFLivePreviewModel()

// In WindowGroup body:
.environment(pdfPreview)
```

- [ ] **Step 2: Live smoke**

```bash
swift build -c release
# Re-bundle as in B-Task 8
open .build/Logos.app
```

In a workspace with a .tex file:
- Sidebar shows the .tex
- Click it → opens in editor pane (CodeViewer from sub-plan F)
- PDF pane shows "Building…" briefly
- Within ~3 seconds (latexmk first run is slow), PDF appears
- Edit the .tex via Claude → PDF rebuilds within ~1 second of save

For .md file:
- Same flow but with pandoc

For workspace with `.logosconfig.yaml` override:
- Custom command runs instead of default

Save screenshot of working PDF preview to `docs/screenshots/pdf-live-preview.png`.

- [ ] **Step 3: Commit**

```bash
git add -A
git commit -m "feat(pdf): G-Task 8 — MainScene injects PDFLivePreviewModel + live smoke

Live PDF preview confirmed visually with a .tex workspace. latexmk
builds within seconds; FileWatcher triggers rebuild on Claude edits.
Failure banner shows last 5 lines of stderr.

docs/screenshots/pdf-live-preview.png captures successful render."
```

---

## Task 9: README + regression

- [ ] **Step 1: README update**

Add to status block:

```markdown
**Sub-plan G — PDF live render: COMPLETE ✅**
- PDFKit viewer in right pane, auto-binds to active editor tab
- FSEvents file watcher + 500ms debounce → BuildPipeline (zsh -c)
- Defaults: .tex → latexmk -pdf, .md → pandoc -o
- Per-workspace .logosconfig.yaml override with {source}/{stem} templates
- Build failure → inline banner with stderr tail
- State machine: idle / building / success / failure
```

- [ ] **Step 2: Final regression**

```bash
swift test
```

Cumulative ~88 tests.

- [ ] **Step 3: Push**

```bash
git add -A && git commit -m "docs(pdf): sub-plan G complete — live PDF preview, ~88 tests pass"
git push
```

---

## Self-review

1. **Spec coverage**: 9 tasks cover dep + resolver + config parser + watcher + pipeline + model + 4 views + scene wiring + smoke + README. Maps to design § 7.6 + § 8.5. ✅
2. **Placeholders**: None. WorkspaceConfig.matchingBuild glob is explicitly "v1 simple star-extension" — not a hidden TBD. ✅
3. **Type consistency**: `SourceToPDFResolution`, `WorkspaceConfig.Build.Resolved`, `PDFLivePreviewModel.State` consistent. ✅
4. **Known risks**:
   - `latexmk` / `pandoc` not installed → command fails → user sees error banner with "command not found". Acceptable UX for v1; sub-plan H Settings can add a "check tools" diagnostic.
   - First `latexmk` build can take 10-30 seconds (downloading packages, doing 2-3 passes). UI shows "Building…" the whole time — fine, no progress bar needed.
   - PDFView pagination state can be lost on rebuild (PDFKit recreates internal state when document set). `load(into:)` tries to preserve currentPage but it's heuristic. Defer perfect sync to vNext.
   - `FileWatcher` watches parent directory — fires on sibling file changes too. Debounce filters most noise but excess builds may happen. Mitigation: filter event paths by exact match (not done in v1 for simplicity).
   - `synctex=1` flag in latexmk default → sets up forward/inverse search but we don't use synctex output yet (vNext feature for Cmd+Click in PDF → jump to source line).
   - `BuildPipeline` uses `/bin/zsh -c`. If user has unusual zsh config that prints to stderr, our stderr capture will be noisy. Acceptable.
