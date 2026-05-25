# Sub-plan B — SwiftTerm Integration + Claude Code Host

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement task-by-task.

**Goal:** Replace `TerminalPanePlaceholder` with a real terminal pane running the `claude` CLI as a PTY subprocess. Use upstream SwiftTerm (no renderer customization yet — that's sub-plan C). When done, sub-plan A's empty shell becomes a working Claude Code host: you launch Logos, type prompts, see Claude work. Tearing/flicker still inherits from upstream SwiftTerm — acceptable for this milestone.

**Architecture:** Add [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) as upstream SwiftPM dependency. Create `SwiftTermView` as `NSViewRepresentable` wrapping SwiftTerm's `LocalProcessTerminalView` (handles PTY + fork+exec for us). Configure subprocess to be `claude` (with `--dangerously-skip-permissions` flag for now — auto-handle in sub-plan D will replace that). Wire window resize → SIGWINCH propagation. Theme to match status bar (dark background, monospace font).

**Tech Stack:** Swift 6, SwiftUI, AppKit interop (`NSViewRepresentable`), SwiftTerm 1.2.x, `posix_spawn`/PTY (via SwiftTerm), macOS 15.

**Prerequisites (from sub-plan A):**
- ✅ Empty app shell with placeholder terminal pane (`TerminalPanePlaceholder`)
- ✅ Status bar, activity bar, file/PDF placeholders all working
- ✅ 18 unit tests passing

**Resolved/new design decisions for this sub-plan:**
- **Use upstream SwiftTerm, not a fork** (yet). Fork happens in sub-plan C when we need to modify the renderer. Why: avoids early forking overhead, reduces merge pain.
- **claude CLI discovery**: assume `claude` is in `$PATH`; if not found, show error banner in terminal pane.
- **claude args**: launch with `--dangerously-skip-permissions` for now (auto-handle in sub-plan D replaces this).
- **Terminal theme**: dark (#1e1e1e) background, light foreground, monospace font (`Menlo` 13pt) — matches macOS Terminal.app conventions.

**What this sub-plan does NOT include:**
- Renderer rewrite (zero tearing) → sub-plan C
- Auto-handle pattern parser → sub-plan D
- Multi-account credential injection → sub-plan E
- Configurable claude args / theme → sub-plan H (Settings UI)

---

## File Structure (delta from sub-plan A)

```
logos/
├── Package.swift                                          MODIFY — add SwiftTerm dep
├── Sources/Logos/
│   ├── Models/
│   │   ├── TerminalConfig.swift                           NEW — font, theme, claude path resolver
│   │   └── ClaudeProcessConfig.swift                      NEW — subprocess launch args
│   ├── Terminal/                                          NEW directory
│   │   ├── SwiftTermView.swift                            NEW — NSViewRepresentable wrapper
│   │   ├── ClaudeProcessHost.swift                        NEW — subprocess lifecycle controller
│   │   └── TerminalThemeApplier.swift                     NEW — apply colors/font to SwiftTerm
│   └── Views/MainArea/
│       └── TerminalPanePlaceholder.swift                  REPLACE → TerminalPaneView.swift
├── Tests/LogosTests/
│   ├── TerminalConfigTests.swift                          NEW
│   └── ClaudeProcessConfigTests.swift                     NEW
```

**Design principle:** All SwiftTerm interaction lives in `Sources/Logos/Terminal/`. This isolates the upstream dependency. When sub-plan C swaps upstream for forked SwiftTerm, only files in `Terminal/` change.

---

## Task 1: Add SwiftTerm SwiftPM dependency

**Files:**
- Modify: `Package.swift`

- [ ] **Step 1: Modify `Package.swift` to add SwiftTerm**

```swift
// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Logos",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "Logos", targets: ["Logos"])
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.2.0")
    ],
    targets: [
        .executableTarget(
            name: "Logos",
            dependencies: [
                .product(name: "SwiftTerm", package: "SwiftTerm")
            ]
        ),
        .testTarget(
            name: "LogosTests",
            dependencies: ["Logos"]
        )
    ]
)
```

- [ ] **Step 2: Resolve dependency**

Run: `swift package resolve`
Expected: `Package.resolved` updated with SwiftTerm 1.2.x checked out.

- [ ] **Step 3: Build to verify dependency wires**

Run: `swift build`
Expected: SUCCESS (no source code uses SwiftTerm yet — just compiles existing code with new dep available).

- [ ] **Step 4: Commit**

```bash
git add Package.swift Package.resolved
git commit -m "feat(terminal): add SwiftTerm 1.2 as upstream SwiftPM dependency

migueldeicaza/SwiftTerm — only mature native macOS terminal emulator
library. Used as-is in sub-plan B; fork + renderer customization
deferred to sub-plan C."
```

---

## Task 2: TerminalConfig model + tests

**Files:**
- Create: `Sources/Logos/Models/TerminalConfig.swift`
- Test: `Tests/LogosTests/TerminalConfigTests.swift`

**Purpose:** Hold font name, font size, background/foreground colors, claude binary path. Defaults baked in; later sub-plans (H Settings) make these user-configurable.

- [ ] **Step 1: Write failing test**

```swift
import Testing
@testable import Logos

@Suite("TerminalConfig", .serialized)
@MainActor
struct TerminalConfigTests {

    @Test("default font is Menlo 13pt")
    func defaultFont() {
        let c = TerminalConfig()
        #expect(c.fontName == "Menlo")
        #expect(c.fontSize == 13)
    }

    @Test("default background is dark")
    func defaultBackground() {
        let c = TerminalConfig()
        #expect(c.backgroundColorHex == "#1e1e1e")
    }

    @Test("claude path resolves via which")
    func claudePathResolves() {
        let c = TerminalConfig()
        // System-dependent: pass if returns non-nil OR is "claude" (fallback)
        #expect(c.resolvedClaudePath != nil)
    }

    @Test("custom claude path overrides which")
    func customClaudePath() {
        let c = TerminalConfig(claudePathOverride: "/opt/homebrew/bin/claude")
        #expect(c.resolvedClaudePath == "/opt/homebrew/bin/claude")
    }
}
```

- [ ] **Step 2: Implement `TerminalConfig.swift`**

```swift
import Foundation
import Observation

@Observable
@MainActor
public final class TerminalConfig {

    public var fontName: String = "Menlo"
    public var fontSize: CGFloat = 13
    public var backgroundColorHex: String = "#1e1e1e"
    public var foregroundColorHex: String = "#d4d4d4"

    /// Optional override. If nil, resolves via `which claude`.
    @ObservationIgnored public let claudePathOverride: String?

    public init(claudePathOverride: String? = nil) {
        self.claudePathOverride = claudePathOverride
    }

    /// Path to claude binary. Returns override if set, else `which claude` result,
    /// else nil (caller should show "claude not found" error).
    public var resolvedClaudePath: String? {
        if let override = claudePathOverride {
            return override
        }
        return Self.runWhich("claude")
    }

    private static func runWhich(_ binary: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = [binary]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let path = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return path?.isEmpty == false ? path : nil
        } catch {
            return nil
        }
    }
}
```

- [ ] **Step 3: Run test**

Run: `swift test --filter TerminalConfigTests`
Expected: 4 tests pass (last one assumes `claude` is in PATH; if not, test framework will tell you and you adjust env).

- [ ] **Step 4: Commit**

```bash
git add Sources/Logos/Models/TerminalConfig.swift Tests/LogosTests/TerminalConfigTests.swift
git commit -m "feat(terminal): TerminalConfig with font/theme/claude-path resolver

Menlo 13pt dark theme (#1e1e1e bg, #d4d4d4 fg) by default.
Claude binary path resolves via 'which claude' with optional override.
4 tests passing."
```

---

## Task 3: ClaudeProcessConfig model + tests

**Files:**
- Create: `Sources/Logos/Models/ClaudeProcessConfig.swift`
- Test: `Tests/LogosTests/ClaudeProcessConfigTests.swift`

**Purpose:** Construct the argv + env vars for spawning claude. Encapsulated so tests can verify args without spawning.

- [ ] **Step 1: Write failing test**

```swift
import Testing
@testable import Logos

@Suite("ClaudeProcessConfig", .serialized)
@MainActor
struct ClaudeProcessConfigTests {

    @Test("default args includes dangerously-skip-permissions")
    func defaultArgs() {
        let cfg = ClaudeProcessConfig(executablePath: "/usr/local/bin/claude")
        #expect(cfg.arguments.contains("--dangerously-skip-permissions"))
    }

    @Test("environment inherits PATH and HOME")
    func envInheritance() {
        let cfg = ClaudeProcessConfig(executablePath: "/usr/local/bin/claude")
        #expect(cfg.environment["PATH"] != nil)
        #expect(cfg.environment["HOME"] != nil)
    }

    @Test("env sets TERM=xterm-256color")
    func envSetsTerm() {
        let cfg = ClaudeProcessConfig(executablePath: "/usr/local/bin/claude")
        #expect(cfg.environment["TERM"] == "xterm-256color")
    }

    @Test("executable path used as argv[0]")
    func argv0() {
        let cfg = ClaudeProcessConfig(executablePath: "/opt/homebrew/bin/claude")
        #expect(cfg.executablePath == "/opt/homebrew/bin/claude")
    }

    @Test("custom args override defaults")
    func customArgs() {
        let cfg = ClaudeProcessConfig(
            executablePath: "/usr/local/bin/claude",
            extraArgs: ["--help"]
        )
        #expect(cfg.arguments.contains("--help"))
    }
}
```

- [ ] **Step 2: Implement**

```swift
import Foundation

public struct ClaudeProcessConfig: Sendable {

    public let executablePath: String
    public let arguments: [String]
    public let environment: [String: String]
    public let workingDirectory: String?

    public init(
        executablePath: String,
        extraArgs: [String] = [],
        workingDirectory: String? = nil
    ) {
        self.executablePath = executablePath

        // Default args. Auto-handle in sub-plan D will revisit these.
        let defaultArgs = ["--dangerously-skip-permissions"]
        self.arguments = defaultArgs + extraArgs

        self.workingDirectory = workingDirectory

        // Inherit user environment, force TERM for proper rendering
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["LC_ALL"] = env["LC_ALL"] ?? "en_US.UTF-8"
        self.environment = env
    }
}
```

- [ ] **Step 3: Run test**

Run: `swift test --filter ClaudeProcessConfigTests`
Expected: 5 tests pass.

- [ ] **Step 4: Commit**

```bash
git add Sources/Logos/Models/ClaudeProcessConfig.swift Tests/LogosTests/ClaudeProcessConfigTests.swift
git commit -m "feat(terminal): ClaudeProcessConfig with default argv + env

--dangerously-skip-permissions baked in (auto-handle revisits in sub-plan D).
TERM=xterm-256color forced for proper rendering.
PATH/HOME inherited from launching shell. 5 tests passing."
```

---

## Task 4: SwiftTermView (NSViewRepresentable wrapper)

**Files:**
- Create: `Sources/Logos/Terminal/SwiftTermView.swift`

**Purpose:** Bridge SwiftTerm's `LocalProcessTerminalView` (AppKit `NSView` subclass) into SwiftUI. Apply theme/font. Expose `startProcess(_:)` callback so caller controls subprocess lifecycle.

- [ ] **Step 1: Create `SwiftTermView.swift`**

```swift
import SwiftUI
import AppKit
import SwiftTerm

/// SwiftUI wrapper around SwiftTerm's LocalProcessTerminalView.
/// Owns the NSView; configures theme + font; spawns subprocess on appear.
struct SwiftTermView: NSViewRepresentable {

    let config: TerminalConfig
    let processConfig: ClaudeProcessConfig

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let view = LocalProcessTerminalView(frame: .zero)
        TerminalThemeApplier.apply(config: config, to: view)
        return view
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {
        // Re-apply theme if config changes
        TerminalThemeApplier.apply(config: config, to: nsView)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(processConfig: processConfig)
    }

    /// Called by SwiftUI when the view becomes part of the hierarchy;
    /// we start the subprocess here via the coordinator.
    final class Coordinator {
        let processConfig: ClaudeProcessConfig
        weak var view: LocalProcessTerminalView?
        private var hasStarted = false

        init(processConfig: ClaudeProcessConfig) {
            self.processConfig = processConfig
        }

        func startIfNeeded(_ view: LocalProcessTerminalView) {
            guard !hasStarted else { return }
            hasStarted = true
            self.view = view
            view.startProcess(
                executable: processConfig.executablePath,
                args: processConfig.arguments,
                environment: processConfig.environment.map { "\($0.key)=\($0.value)" },
                execName: nil
            )
        }
    }
}
```

- [ ] **Step 2: Build — verify SwiftTerm imports resolve**

Run: `swift build`
Expected: SUCCESS — file compiles. The view isn't used yet (Task 6 wires it in).

- [ ] **Step 3: Commit**

```bash
git add Sources/Logos/Terminal/SwiftTermView.swift
git commit -m "feat(terminal): SwiftTermView NSViewRepresentable wrapper

Bridges SwiftTerm.LocalProcessTerminalView into SwiftUI. Coordinator
owns subprocess start (idempotent via hasStarted flag). Theme re-applies
on updateNSView so future TerminalConfig changes propagate."
```

---

## Task 5: TerminalThemeApplier

**Files:**
- Create: `Sources/Logos/Terminal/TerminalThemeApplier.swift`

**Purpose:** Apply font + colors from `TerminalConfig` to a SwiftTerm `TerminalView`. Isolated so we can test config changes don't recreate the view.

- [ ] **Step 1: Create**

```swift
import AppKit
import SwiftTerm

enum TerminalThemeApplier {

    static func apply(config: TerminalConfig, to view: TerminalView) {
        // Font
        if let font = NSFont(name: config.fontName, size: config.fontSize) {
            view.font = font
        } else {
            view.font = NSFont.monospacedSystemFont(ofSize: config.fontSize, weight: .regular)
        }

        // Colors (parse hex → NSColor)
        if let bg = NSColor(hex: config.backgroundColorHex) {
            view.nativeBackgroundColor = bg
        }
        if let fg = NSColor(hex: config.foregroundColorHex) {
            view.nativeForegroundColor = fg
        }
    }
}

private extension NSColor {
    convenience init?(hex: String) {
        var hex = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        let r = CGFloat((value >> 16) & 0xff) / 255
        let g = CGFloat((value >> 8) & 0xff) / 255
        let b = CGFloat(value & 0xff) / 255
        self.init(srgbRed: r, green: g, blue: b, alpha: 1)
    }
}
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: SUCCESS.

- [ ] **Step 3: Commit**

```bash
git add Sources/Logos/Terminal/TerminalThemeApplier.swift
git commit -m "feat(terminal): TerminalThemeApplier — font + hex color → SwiftTerm

Parses #rrggbb hex into NSColor (srgb). Falls back to system monospace
if config font name not found. Isolated from SwiftTermView so theme
changes can be tested independently."
```

---

## Task 6: Replace TerminalPanePlaceholder

**Files:**
- Delete: `Sources/Logos/Views/MainArea/TerminalPanePlaceholder.swift`
- Create: `Sources/Logos/Views/MainArea/TerminalPaneView.swift`
- Modify: `Sources/Logos/Views/MainArea/MainAreaView.swift`
- Modify: `Sources/Logos/App/MainScene.swift` — inject TerminalConfig

- [ ] **Step 1: Update `MainScene.swift` to provide TerminalConfig**

```swift
import SwiftUI

struct MainScene: Scene {

    @State private var layout = WindowLayoutState()
    @State private var activityBar = ActivityBarSelection()
    @State private var statusBar = StatusBarViewModel()
    @State private var terminalConfig = TerminalConfig()

    var body: some Scene {
        WindowGroup("Logos") {
            MainView()
                .environment(layout)
                .environment(activityBar)
                .environment(statusBar)
                .environment(terminalConfig)
                .frame(
                    minWidth: 900,
                    idealWidth: 1400,
                    minHeight: 600,
                    idealHeight: 900
                )
        }
        .windowResizability(.contentSize)
    }
}
```

- [ ] **Step 2: Delete `TerminalPanePlaceholder.swift`**

```bash
rm /Users/che/Developer/logos/Sources/Logos/Views/MainArea/TerminalPanePlaceholder.swift
```

- [ ] **Step 3: Create `TerminalPaneView.swift`**

```swift
import SwiftUI

struct TerminalPaneView: View {
    @Environment(TerminalConfig.self) private var config

    var body: some View {
        Group {
            if let claudePath = config.resolvedClaudePath {
                let processConfig = ClaudeProcessConfig(executablePath: claudePath)
                SwiftTermView(config: config, processConfig: processConfig)
                    .background(Color.black)
            } else {
                ClaudeNotFoundBanner()
            }
        }
    }
}

private struct ClaudeNotFoundBanner: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40))
                .foregroundStyle(.yellow)
            Text("claude CLI not found")
                .font(.headline)
            Text("Install Claude Code and ensure 'claude' is in your $PATH.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Link(
                "Install instructions →",
                destination: URL(string: "https://docs.claude.com/en/docs/claude-code/")!
            )
            .font(.caption)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.9))
    }
}
```

- [ ] **Step 4: Update `MainAreaView.swift` — replace `TerminalPanePlaceholder()` with `TerminalPaneView()`**

In `Sources/Logos/Views/MainArea/MainAreaView.swift`:

```swift
// Find this line:
TerminalPanePlaceholder()
    .frame(maxWidth: .infinity, maxHeight: .infinity)

// Replace with:
TerminalPaneView()
    .frame(maxWidth: .infinity, maxHeight: .infinity)
```

- [ ] **Step 5: Build**

Run: `swift build`
Expected: SUCCESS.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat(terminal): replace TerminalPanePlaceholder with TerminalPaneView

- TerminalPaneView checks resolvedClaudePath; if found, spawns SwiftTermView
  with ClaudeProcessConfig; if not, shows ClaudeNotFoundBanner with link
  to install docs.
- MainScene injects new @State TerminalConfig into environment.
- TerminalPanePlaceholder.swift deleted (no longer referenced).
- MainAreaView swapped to use new view.

Sub-plan A's empty terminal pane is now live: claude CLI runs inside."
```

---

## Task 7: SwiftUI coordinator wiring (start subprocess on appear)

**Files:**
- Modify: `Sources/Logos/Terminal/SwiftTermView.swift`

**Purpose:** The Coordinator's `startIfNeeded` needs to be called when the NSView is mounted. The cleanest spot is `makeNSView` itself, but we need a reference to the coordinator from there.

- [ ] **Step 1: Update `SwiftTermView.swift` to start subprocess in `makeNSView`**

Replace the `makeNSView` function body:

```swift
func makeNSView(context: Context) -> LocalProcessTerminalView {
    let view = LocalProcessTerminalView(frame: .zero)
    TerminalThemeApplier.apply(config: config, to: view)
    context.coordinator.startIfNeeded(view)
    return view
}
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: SUCCESS.

- [ ] **Step 3: Smoke test — launch + verify claude is running**

```bash
# Rebuild .app bundle (same as sub-plan A Task 11)
swift build -c release
rm -rf .build/Logos.app
mkdir -p .build/Logos.app/Contents/MacOS
cp .build/release/Logos .build/Logos.app/Contents/MacOS/Logos
cp Info.plist .build/Logos.app/Contents/Info.plist
echo "APPL????" > .build/Logos.app/Contents/PkgInfo
codesign --force --deep --sign - .build/Logos.app
open .build/Logos.app

# Wait then check: is claude process running as child of Logos?
sleep 5
ps -ef | grep -i "claude\|Logos" | grep -v grep
```

Expected: see `Logos` and `claude` processes; claude should be child of Logos. Visually: bottom terminal panel shows claude's welcome banner / `>` prompt.

- [ ] **Step 4: Commit**

```bash
git add Sources/Logos/Terminal/SwiftTermView.swift
git commit -m "feat(terminal): start claude subprocess in makeNSView via coordinator

Coordinator.startIfNeeded gates with hasStarted flag to prevent
double-spawn on view recreate. Tested: claude runs as child of Logos
process on app launch."
```

---

## Task 8: Visual smoke test — type into claude, get a response

**Files:** none (manual interaction)

- [ ] **Step 1: Launch app**

```bash
open /Users/che/Developer/logos/.build/Logos.app
```

- [ ] **Step 2: Interact with claude in terminal pane**

Click into the terminal area. Type:

```
hello claude
```

Press Enter.

Expected: claude responds in the terminal pane. Tearing/flicker will be visible during tool calls or streaming — that's acceptable (fixed in sub-plan C).

Verify:
- [ ] Typed text appears in terminal
- [ ] Enter sends to claude
- [ ] Claude's response renders (with whatever flicker is normal)
- [ ] Window resize doesn't crash the terminal pane

- [ ] **Step 3: Screenshot for milestone**

```bash
# Capture Logos window by CGWindowID
WIN_ID=$(echo 'import Cocoa
let wins = (CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]]) ?? []
for w in wins {
    if (w["kCGWindowOwnerName"] as? String) == "Logos" {
        if let n = w["kCGWindowNumber"] { print(n); exit(0) }
    }
}' | swift -)
screencapture -l $WIN_ID -o /Users/che/Developer/logos/docs/screenshots/claude-running.png
```

- [ ] **Step 4: Commit screenshot + finalize sub-plan B**

```bash
git add docs/screenshots/claude-running.png
git commit -m "docs(terminal): screenshot of claude running inside Logos terminal pane

Sub-plan B milestone delivered: real claude CLI hosted in app shell.
Tearing/flicker still inherited from upstream SwiftTerm; renderer
rewrite in sub-plan C will eliminate it."
```

---

## Task 9: Update README + final regression check

**Files:**
- Modify: `/Users/che/Developer/logos/README.md`

- [ ] **Step 1: Run all tests one more time**

Run: `swift test`
Expected: all tests pass (sub-plan A's 18 + sub-plan B's 9 = 27).

- [ ] **Step 2: Update README "Repo status" section**

Replace the existing status block with:

```markdown
## Repo status

**Sub-plan A — App shell foundation: COMPLETE ✅**
**Sub-plan B — SwiftTerm + claude subprocess: COMPLETE ✅**

- Launchable native macOS app with VS Code-like layout
- Real claude CLI running inside terminal pane (upstream SwiftTerm)
- Drag-resize between all panes with persistence
- Multi-tab Settings stub (⌘,)
- 27 unit tests passing
- Tearing/flicker still inherited from upstream SwiftTerm — fixed in sub-plan C

Screenshots:
- [Shell foundation](docs/screenshots/shell-foundation.png) (sub-plan A)
- [Claude running](docs/screenshots/claude-running.png) (sub-plan B)

**Next**: sub-plan C — fork SwiftTerm, rewrite renderer for zero tearing.

Design doc: [`docs/design/2026-05-25-logos-design.md`](docs/design/2026-05-25-logos-design.md)
All plans: [`docs/superpowers/plans/`](docs/superpowers/plans/)
```

- [ ] **Step 3: Final commit**

```bash
git add README.md
git commit -m "docs: sub-plan B complete — terminal pane hosts real claude CLI

27 tests passing. Visual: claude welcome banner visible in bottom
panel. Tearing remains (sub-plan C territory)."
```

---

## Self-review checklist (post-write, pre-execute)

Before invoking executing-plans, run through:

1. **Spec coverage**: Tasks 1-9 cover SwiftTerm dep + theme + subprocess + UI replacement + smoke test. ✅
2. **Placeholder scan**: No "TBD"/"TODO"/"fill later" — every step has concrete code. ✅
3. **Type consistency**: `TerminalConfig`, `ClaudeProcessConfig`, `SwiftTermView`, `TerminalThemeApplier`, `TerminalPaneView` referenced consistently across tasks. ✅
4. **Known risks**:
   - SwiftTerm `LocalProcessTerminalView` API surface may differ from this plan if upstream version drifts — verify against tagged 1.2.x docs.
   - `view.nativeBackgroundColor` / `view.nativeForegroundColor` property names assumed — check SwiftTerm headers if compile errors.
   - `startProcess` signature assumed (`executable`, `args`, `environment`, `execName`) — verify in SwiftTerm.
   - If claude is not in PATH (e.g., installed via npm in user-local), `which claude` fails — banner shows. Workaround: user sets `claudePathOverride` (Settings UI in sub-plan H).

---

## Done. Next steps after sub-plan B:

- **Sub-plan C** (renderer rewrite): fork SwiftTerm, eliminate tearing. This is the "moat" work — 3-4 months focused. Plan to be written before starting.
- **Sub-plan D** (auto-handle): pattern parser + decision engine + PTY stdin writer. Replaces `--dangerously-skip-permissions` with smart rules. Can be built in parallel with C.
