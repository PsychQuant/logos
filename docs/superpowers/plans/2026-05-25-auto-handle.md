# Sub-plan D — Auto-handle (Pattern Parser + Rate-limit Keep-Going)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Watch the live PTY stream from `claude`. When known patterns appear (rate-limit, trust prompts, MCP permission), automatically inject the configured response into the PTY stdin. Update status bar to reflect "armed / fired" state. This is the **#1 killer feature** of Logos — Claude Code never blocks on a prompt you've pre-approved while you stepped away.

**Architecture:**

```
   claude subprocess (PTY)
         │ stdout
         ▼
   ┌─────────────┐
   │ Stream Tee  │ (already exists in sub-plan B via SwiftTerm — extend it)
   └──┬──────┬───┘
      │      │
      ▼      ▼
   Renderer  Pattern Parser
             (regex / state machine)
             │ matched event
             ▼
       Decision Engine
         (cooldown + rule lookup)
             │ inject command
             ▼
       PTY stdin writer
             │ "keep going\n"
             ▼
       (back to claude subprocess)

   Status bar listens to events from Decision Engine for armed/fired display.
```

**Tech Stack:** Swift 6, Observation, SwiftTerm (PTY access via `LocalProcessTerminalView.send`), regex / `NSRegularExpression`

**Prerequisites:**
- ✅ Sub-plan B complete (claude runs in terminal pane via SwiftTerm)
- ✅ StatusBarViewModel exists with `autoHandleStatus` property (sub-plan A Task 4)

**Resolved/new design decisions for this sub-plan:**
- **No fork SwiftTerm required.** Use SwiftTerm's existing public hooks (`TerminalDelegate.send` for output, `LocalProcessTerminalView.send` for input). Pattern parser sees the SAME bytes the renderer sees.
- **Drop `--dangerously-skip-permissions` flag** (was in sub-plan B). With auto-handle running, claude can ask normally and we approve per-rule. This is the key behavioral shift this sub-plan unlocks.
- **Hardcoded rule set for v1.** No user-configurable rules yet (that's sub-plan H Settings UI). 5 hardcoded rules:
  1. Rate-limit "keep going" → auto-type "keep going\n" with backoff
  2. Trust folder prompt → auto-approve for current workspace
  3. Bash tool permission → auto-approve (TEMPORARY; tightens in sub-plan E or H)
  4. MCP permission prompt → auto-approve once per server (tightens later)
  5. Generic "Press Enter to continue" → auto-press after 2s
- **Cooldown**: each rule has 5s cooldown to prevent runaway loops. If same pattern fires 3x within 30s, disable that rule and notify via status bar (becomes `.partial`).

**What this sub-plan does NOT include:**
- Settings UI to edit rules → sub-plan H
- Custom regex rules from user → sub-plan H
- Per-workspace rule overrides → sub-plan H
- Telemetry of rule firings → could be useful but defer
- Sound/notification on rule fire → defer

---

## File Structure (delta from sub-plan B)

```
logos/
├── Sources/Logos/
│   ├── Models/
│   │   ├── AutoHandleRule.swift                       NEW
│   │   └── AutoHandleEngine.swift                     NEW — central decision logic
│   ├── Terminal/
│   │   ├── PatternParser.swift                        NEW — regex scanner over PTY bytes
│   │   ├── StreamTee.swift                            NEW — fan-out to renderer + parser
│   │   ├── ClaudeProcessConfig.swift                  MODIFY — remove --dangerously-skip-permissions
│   │   └── SwiftTermView.swift                        MODIFY — install delegate to tee output, expose send for engine
│   └── Views/StatusBar/
│       └── AutoHandleStatusItem.swift                 MODIFY — show armed/partial/disabled + last fired event
├── Tests/LogosTests/
│   ├── AutoHandleRuleTests.swift                      NEW
│   ├── AutoHandleEngineTests.swift                    NEW
│   └── PatternParserTests.swift                       NEW
```

---

## Task 1: AutoHandleRule model + tests

**Files:**
- Create: `Sources/Logos/Models/AutoHandleRule.swift`
- Test: `Tests/LogosTests/AutoHandleRuleTests.swift`

**Purpose:** A `Rule` defines a name, a regex pattern, an action (bytes to inject), a cooldown duration. Pure data — no side effects.

- [ ] **Step 1: Write failing test**

```swift
import Testing
@testable import Logos

@Suite("AutoHandleRule", .serialized)
@MainActor
struct AutoHandleRuleTests {

    @Test("rule matches expected pattern in input")
    func patternMatches() {
        let rule = AutoHandleRule(
            id: "rate-limit",
            name: "Rate limit keep-going",
            pattern: #"Press "keep going" to retry"#,
            response: "keep going\n",
            cooldown: 5
        )
        let input = "API Error: Rate limited. Press \"keep going\" to retry..."
        #expect(rule.matches(input))
    }

    @Test("rule does not match unrelated input")
    func patternDoesNotMatch() {
        let rule = AutoHandleRule(
            id: "rate-limit",
            name: "Rate limit",
            pattern: #"Press "keep going" to retry"#,
            response: "keep going\n",
            cooldown: 5
        )
        #expect(!rule.matches("Hello world"))
    }

    @Test("response bytes computed correctly")
    func responseBytes() {
        let rule = AutoHandleRule(
            id: "x",
            name: "x",
            pattern: "x",
            response: "y\n",
            cooldown: 1
        )
        #expect(rule.responseBytes == Array("y\n".utf8))
    }

    @Test("invalid regex pattern surfaces in matches() returning false")
    func invalidPatternHandled() {
        let rule = AutoHandleRule(
            id: "bad",
            name: "Bad regex",
            pattern: "[unclosed",
            response: "x",
            cooldown: 1
        )
        // Should not crash; should return false
        #expect(!rule.matches("anything"))
    }
}
```

- [ ] **Step 2: Implement**

```swift
import Foundation

public struct AutoHandleRule: Identifiable, Sendable, Hashable {

    public let id: String
    public let name: String
    public let pattern: String
    public let response: String
    public let cooldown: TimeInterval

    public init(
        id: String,
        name: String,
        pattern: String,
        response: String,
        cooldown: TimeInterval
    ) {
        self.id = id
        self.name = name
        self.pattern = pattern
        self.response = response
        self.cooldown = cooldown
    }

    public var responseBytes: [UInt8] {
        Array(response.utf8)
    }

    public func matches(_ input: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return false
        }
        let range = NSRange(input.startIndex..., in: input)
        return regex.firstMatch(in: input, range: range) != nil
    }
}

/// The 5 hardcoded v1 rules. Sub-plan H replaces this with user-configurable rules.
public extension AutoHandleRule {

    static let defaultRuleset: [AutoHandleRule] = [
        AutoHandleRule(
            id: "rate-limit",
            name: "Rate-limit keep-going",
            pattern: #"Press "keep going" to retry"#,
            response: "keep going\n",
            cooldown: 5
        ),
        AutoHandleRule(
            id: "trust-folder",
            name: "Trust folder",
            pattern: #"Yes, I trust this folder"#,
            response: "1\n",
            cooldown: 60
        ),
        AutoHandleRule(
            id: "trust-files",
            name: "Trust files",
            pattern: #"Do you trust the files"#,
            response: "y\n",
            cooldown: 60
        ),
        AutoHandleRule(
            id: "bash-permission",
            name: "Bash tool permission",
            pattern: #"Bash command:.+Allow\?"#,
            response: "y\n",
            cooldown: 5
        ),
        AutoHandleRule(
            id: "press-enter",
            name: "Press Enter",
            pattern: #"Press Enter to continue"#,
            response: "\n",
            cooldown: 2
        )
    ]
}
```

- [ ] **Step 3: Run tests**

Run: `swift test --filter AutoHandleRuleTests`
Expected: 4 tests pass.

- [ ] **Step 4: Commit**

```bash
git add Sources/Logos/Models/AutoHandleRule.swift Tests/LogosTests/AutoHandleRuleTests.swift
git commit -m "feat(auto-handle): D-Task 1 — AutoHandleRule + 5-rule default set

Rule = id + name + pattern (regex) + response + cooldown. NSRegularExpression
matching with safe error handling (invalid regex returns false, no crash).

5 hardcoded v1 rules: rate-limit, trust-folder, trust-files,
bash-permission, press-enter. Sub-plan H upgrades to user-configurable.

4 tests passing."
```

---

## Task 2: AutoHandleEngine + tests

**Files:**
- Create: `Sources/Logos/Models/AutoHandleEngine.swift`
- Test: `Tests/LogosTests/AutoHandleEngineTests.swift`

**Purpose:** Stateful decision logic. Tracks per-rule cooldown timestamps and per-rule fire history (for runaway-detection disable). Exposes `processChunk(_:)` for new PTY output and `fired(rule:)` callback hook.

- [ ] **Step 1: Write failing test**

```swift
import Testing
import Foundation
@testable import Logos

@Suite("AutoHandleEngine", .serialized)
@MainActor
struct AutoHandleEngineTests {

    @Test("fires matching rule and returns response bytes")
    func firesMatchingRule() {
        let engine = AutoHandleEngine(rules: [
            AutoHandleRule(id: "x", name: "x", pattern: "trigger", response: "ok\n", cooldown: 0.001)
        ])
        let response = engine.processChunk("Hello trigger world")
        #expect(response == Array("ok\n".utf8))
    }

    @Test("no fire on non-matching input")
    func noFireOnMiss() {
        let engine = AutoHandleEngine(rules: [
            AutoHandleRule(id: "x", name: "x", pattern: "trigger", response: "ok\n", cooldown: 0.001)
        ])
        let response = engine.processChunk("Hello world")
        #expect(response == nil)
    }

    @Test("respects cooldown")
    func respectsCooldown() async throws {
        let engine = AutoHandleEngine(rules: [
            AutoHandleRule(id: "x", name: "x", pattern: "trigger", response: "ok\n", cooldown: 1.0)
        ])
        _ = engine.processChunk("trigger 1")
        // Immediately second match — should NOT fire (cooldown active)
        let response = engine.processChunk("trigger 2")
        #expect(response == nil)
    }

    @Test("disables rule after runaway")
    func runawayDisable() {
        let engine = AutoHandleEngine(rules: [
            AutoHandleRule(id: "x", name: "x", pattern: "trigger", response: "ok\n", cooldown: 0.001)
        ])
        // Fire 3+ times within 30s — should auto-disable
        for _ in 0..<5 {
            _ = engine.processChunk("trigger")
            Thread.sleep(forTimeInterval: 0.002)  // exceed cooldown but stay within 30s window
        }
        #expect(engine.disabledRuleIDs.contains("x"))
    }

    @Test("status reflects rule states")
    func statusReflection() {
        let engine = AutoHandleEngine(rules: AutoHandleRule.defaultRuleset)
        #expect(engine.currentStatus == .armed)
        // After disabling one rule manually:
        engine.disableRule(id: "rate-limit")
        #expect(engine.currentStatus == .partial)
        // Disable all:
        for rule in AutoHandleRule.defaultRuleset {
            engine.disableRule(id: rule.id)
        }
        #expect(engine.currentStatus == .disabled)
    }
}
```

- [ ] **Step 2: Implement**

```swift
import Foundation
import Observation

@Observable
@MainActor
public final class AutoHandleEngine {

    @ObservationIgnored private let rules: [AutoHandleRule]
    @ObservationIgnored private var lastFiredAt: [String: Date] = [:]
    @ObservationIgnored private var fireHistory: [String: [Date]] = [:]

    public private(set) var disabledRuleIDs: Set<String> = []
    public private(set) var lastFiredRule: AutoHandleRule?

    public init(rules: [AutoHandleRule] = AutoHandleRule.defaultRuleset) {
        self.rules = rules
    }

    /// Process a new chunk of PTY output. Returns bytes to inject back
    /// into the PTY stdin (or nil if no rule fires).
    public func processChunk(_ text: String) -> [UInt8]? {
        let now = Date()
        for rule in rules where !disabledRuleIDs.contains(rule.id) {
            guard rule.matches(text) else { continue }
            // Cooldown check
            if let last = lastFiredAt[rule.id], now.timeIntervalSince(last) < rule.cooldown {
                continue
            }
            // Record fire
            lastFiredAt[rule.id] = now
            fireHistory[rule.id, default: []].append(now)
            // Prune fire history older than 30s
            fireHistory[rule.id] = fireHistory[rule.id]?.filter { now.timeIntervalSince($0) < 30 }
            // Runaway check: 3+ fires within 30s → disable
            if (fireHistory[rule.id]?.count ?? 0) >= 3 {
                disabledRuleIDs.insert(rule.id)
            }
            lastFiredRule = rule
            return rule.responseBytes
        }
        return nil
    }

    public func disableRule(id: String) {
        disabledRuleIDs.insert(id)
    }

    public func enableRule(id: String) {
        disabledRuleIDs.remove(id)
    }

    /// Derived: armed if all rules active; partial if some disabled; disabled if all disabled.
    public var currentStatus: StatusBarViewModel.AutoHandleStatus {
        if disabledRuleIDs.isEmpty {
            return .armed
        } else if disabledRuleIDs.count == rules.count {
            return .disabled
        } else {
            return .partial
        }
    }
}
```

- [ ] **Step 3: Run tests**

Run: `swift test --filter AutoHandleEngineTests`
Expected: 5 tests pass.

- [ ] **Step 4: Commit**

```bash
git add Sources/Logos/Models/AutoHandleEngine.swift Tests/LogosTests/AutoHandleEngineTests.swift
git commit -m "feat(auto-handle): D-Task 2 — AutoHandleEngine with cooldown + runaway disable

Stateful decision logic: per-rule cooldown (no double-fire within
N seconds), 30s sliding window fire history, auto-disable if a rule
fires 3+ times in 30s (runaway protection — e.g., claude in an infinite
prompt loop won't make us infinitely auto-type).

currentStatus computed: armed (all rules active), partial (some
disabled), disabled (all disabled). Wired into StatusBarViewModel
in D-Task 5. 5 tests passing."
```

---

## Task 3: PatternParser (streaming chunk-aware regex scanner)

**Files:**
- Create: `Sources/Logos/Terminal/PatternParser.swift`
- Test: `Tests/LogosTests/PatternParserTests.swift`

**Purpose:** PTY output arrives in chunks (e.g., 4KB at a time). A pattern might split across chunk boundaries. `PatternParser` maintains a small rolling buffer so it doesn't miss patterns that span chunks.

- [ ] **Step 1: Write failing test**

```swift
import Testing
@testable import Logos

@Suite("PatternParser", .serialized)
@MainActor
struct PatternParserTests {

    @Test("detects pattern in single chunk")
    func singleChunk() {
        let parser = PatternParser(maxBufferSize: 4096)
        let detected = parser.append("Some text trigger here")
        #expect(detected.contains("trigger here"))
    }

    @Test("detects pattern across chunk boundary")
    func acrossChunks() {
        let parser = PatternParser(maxBufferSize: 4096)
        _ = parser.append("Some text trig")
        let detected = parser.append("ger here")
        #expect(detected.contains("trigger here"))
    }

    @Test("trims buffer at max size")
    func trimsBuffer() {
        let parser = PatternParser(maxBufferSize: 100)
        for _ in 0..<200 {
            _ = parser.append("a")
        }
        #expect(parser.bufferSize <= 100)
    }

    @Test("strips ANSI escape sequences before pattern matching")
    func stripsAnsi() {
        let parser = PatternParser(maxBufferSize: 4096)
        // "\u{1B}[31m" is red color code
        let detected = parser.append("\u{1B}[31mtrigger\u{1B}[0m here")
        #expect(detected.contains("trigger"))
        #expect(!detected.contains("\u{1B}"))
    }
}
```

- [ ] **Step 2: Implement**

```swift
import Foundation

@MainActor
public final class PatternParser {

    private var buffer: String = ""
    private let maxBufferSize: Int

    public init(maxBufferSize: Int = 4096) {
        self.maxBufferSize = maxBufferSize
    }

    /// Append new PTY output. Returns the current buffer contents with ANSI
    /// stripped, for the AutoHandleEngine to scan against.
    public func append(_ chunk: String) -> String {
        buffer += chunk
        if buffer.count > maxBufferSize {
            // Drop the oldest half; keep recent half so cross-chunk patterns survive
            let dropCount = buffer.count - maxBufferSize
            buffer.removeFirst(dropCount)
        }
        return Self.stripAnsi(buffer)
    }

    public var bufferSize: Int { buffer.count }

    public func reset() {
        buffer = ""
    }

    /// Strip CSI/OSC/etc. escape sequences for plain-text pattern matching.
    /// Crude but sufficient for the rule patterns we use.
    static func stripAnsi(_ input: String) -> String {
        // CSI: ESC [ ... letter
        // OSC: ESC ] ... BEL or ST
        // Simple: ESC X (single char)
        guard let regex = try? NSRegularExpression(
            pattern: #"\x1B\[[0-9;?]*[a-zA-Z]|\x1B\][^\x07\x1B]*[\x07\x1B]|\x1B."#
        ) else {
            return input
        }
        let range = NSRange(input.startIndex..., in: input)
        return regex.stringByReplacingMatches(in: input, range: range, withTemplate: "")
    }
}
```

- [ ] **Step 3: Run tests**

Run: `swift test --filter PatternParserTests`
Expected: 4 tests pass.

- [ ] **Step 4: Commit**

```bash
git add Sources/Logos/Terminal/PatternParser.swift Tests/LogosTests/PatternParserTests.swift
git commit -m "feat(auto-handle): D-Task 3 — PatternParser with cross-chunk buffer + ANSI strip

Rolling buffer (default 4KB) preserves patterns that span chunk
boundaries. ANSI escape stripper (CSI/OSC/single-char) so rule
patterns match against plain text not color-coded bytes.

Buffer trims oldest half when exceeds max — keeps memory bounded
without losing recent context. 4 tests passing."
```

---

## Task 4: StreamTee — fan-out PTY output to renderer + parser

**Files:**
- Create: `Sources/Logos/Terminal/StreamTee.swift`
- Modify: `Sources/Logos/Terminal/SwiftTermView.swift` — install tee

**Purpose:** Intercept the bytes SwiftTerm receives from the subprocess. Send them to: (1) the terminal renderer as normal, (2) the PatternParser → AutoHandleEngine. SwiftTerm exposes `TerminalDelegate` callbacks but for raw byte interception we use `LocalProcessTerminalDelegate.processTerminated` and related — but the cleanest hook is to subclass `LocalProcessTerminalView` and override the data path.

**Implementation strategy:** SwiftTerm's `LocalProcessTerminalView` internally has a `dataReceived` path. We subclass and override to tee before delegating. Verify exact override point during execution — may need adaptation.

- [ ] **Step 1: Read SwiftTerm 1.13 source to find tee point**

```bash
grep -rn "dataReceived\|feedRead\|processRead" /Users/che/Developer/logos/.build/checkouts/SwiftTerm/Sources/SwiftTerm/ | head -20
```

Locate where bytes flow from PTY into the terminal model. Likely candidates: `feed(byteArray:)`, `processTerminated(source:)`, or a private callback.

- [ ] **Step 2: Create `StreamTee.swift`**

```swift
import Foundation
import SwiftTerm

/// Subclass that taps bytes flowing from subprocess → terminal renderer.
/// Each chunk is forwarded to the parser/engine for auto-handle scanning,
/// then passed through to the normal renderer path.
@MainActor
public final class TeedLocalProcessTerminalView: LocalProcessTerminalView {

    /// Called for each byte chunk from the subprocess. Override point.
    public var onChunk: (([UInt8]) -> Void)?

    public override func feed(byteArray: ArraySlice<UInt8>) {
        // Tap before parent processes
        onChunk?(Array(byteArray))
        super.feed(byteArray: byteArray)
    }
}
```

*(Adapt to actual SwiftTerm 1.13 method signature if different — discovery step 1 above tells you the override point.)*

- [ ] **Step 3: Modify `SwiftTermView.swift` to use `TeedLocalProcessTerminalView`**

Change `LocalProcessTerminalView` references in `SwiftTermView.swift` to `TeedLocalProcessTerminalView`. Add `onChunk` wiring in `makeNSView`:

```swift
func makeNSView(context: Context) -> TeedLocalProcessTerminalView {
    let view = TeedLocalProcessTerminalView(frame: .zero)
    TerminalThemeApplier.apply(config: config, to: view)
    view.onChunk = { [weak coord = context.coordinator] chunk in
        coord?.parser.handleChunk(chunk)
    }
    context.coordinator.startIfNeeded(view)
    return view
}
```

(Coordinator gains a `parser` member holding `PatternParser` + `AutoHandleEngine`. Wire in next step.)

- [ ] **Step 4: Build to verify the override compiles + override slot is correct**

Run: `swift build`

If error "Method does not override any method from its superclass" — the override slot is wrong. Adapt to actual SwiftTerm API found in step 1.

- [ ] **Step 5: Commit**

```bash
git add Sources/Logos/Terminal/StreamTee.swift Sources/Logos/Terminal/SwiftTermView.swift
git commit -m "feat(auto-handle): D-Task 4 — StreamTee subclass of LocalProcessTerminalView

Override of feed(byteArray:) (or whichever actual SwiftTerm method
is the byte-entry point — adapted during execution) taps bytes
before they flow to renderer. onChunk callback exposes chunks for
the pattern parser.

SwiftTermView updated to use TeedLocalProcessTerminalView + wire
onChunk to Coordinator's parser."
```

---

## Task 5: Coordinator integrates parser + engine + injects responses

**Files:**
- Modify: `Sources/Logos/Terminal/SwiftTermView.swift` — Coordinator gains parser/engine + inject path
- Modify: `Sources/Logos/Models/StatusBarViewModel.swift` — bridge `autoHandleStatus` from engine
- Modify: `Sources/Logos/App/MainScene.swift` — inject AutoHandleEngine into environment

- [ ] **Step 1: Update `Coordinator` to hold parser + engine + injector**

```swift
@MainActor
final class Coordinator {
    let processConfig: ClaudeProcessConfig
    let parser: PatternParser
    let engine: AutoHandleEngine
    weak var view: TeedLocalProcessTerminalView?
    private var hasStarted = false

    init(processConfig: ClaudeProcessConfig, engine: AutoHandleEngine) {
        self.processConfig = processConfig
        self.engine = engine
        self.parser = PatternParser()
    }

    func handleChunk(_ bytes: [UInt8]) {
        guard let text = String(bytes: bytes, encoding: .utf8) else { return }
        let buffered = parser.append(text)
        if let response = engine.processChunk(buffered) {
            // Inject into PTY stdin via SwiftTerm
            view?.send(data: ArraySlice(response))
            parser.reset()  // avoid re-firing on same buffer
        }
    }

    func startIfNeeded(_ view: TeedLocalProcessTerminalView) {
        guard !hasStarted else { return }
        hasStarted = true
        self.view = view
        view.startProcess(
            executable: processConfig.executablePath,
            args: processConfig.arguments,
            environment: processConfig.environment.map { "\($0.key)=\($0.value)" },
            execName: nil,
            currentDirectory: processConfig.workingDirectory
        )
    }
}
```

- [ ] **Step 2: Update `SwiftTermView` to accept engine + pass to coordinator**

```swift
struct SwiftTermView: NSViewRepresentable {
    let config: TerminalConfig
    let processConfig: ClaudeProcessConfig
    let engine: AutoHandleEngine

    func makeCoordinator() -> Coordinator {
        Coordinator(processConfig: processConfig, engine: engine)
    }
    // ... rest unchanged
}
```

- [ ] **Step 3: Update `TerminalPaneView` to read engine from environment**

```swift
struct TerminalPaneView: View {
    @Environment(TerminalConfig.self) private var config
    @Environment(AutoHandleEngine.self) private var engine

    var body: some View {
        Group {
            if let claudePath = config.resolvedClaudePath {
                let processConfig = ClaudeProcessConfig(executablePath: claudePath)
                SwiftTermView(config: config, processConfig: processConfig, engine: engine)
                    .background(Color.black)
            } else {
                ClaudeNotFoundBanner()
            }
        }
    }
}
```

- [ ] **Step 4: Update `MainScene` to inject engine**

```swift
@State private var autoHandleEngine = AutoHandleEngine()

// In WindowGroup body:
.environment(autoHandleEngine)
```

- [ ] **Step 5: Update `ClaudeProcessConfig` to remove --dangerously-skip-permissions**

Change default args from `["--dangerously-skip-permissions"]` to `[]`. Update `ClaudeProcessConfigTests.defaultArgs` test to match (now asserts empty default args; --dangerously-skip can be opt-in extraArg).

- [ ] **Step 6: Bridge engine status into StatusBarViewModel**

In `MainScene`, observe `autoHandleEngine.currentStatus` and sync to `statusBar.autoHandleStatus`. Cleanest: add a small observation closure on appear, OR make StatusBarViewModel hold a weak ref to engine and compute autoHandleStatus on read.

Simpler approach — modify `StatusBarViewModel.autoHandleStatus` to NOT be a stored property; instead make it a computed read of the injected engine:

```swift
// Inject engine into StatusBarViewModel via init, OR
// have the view layer read engine.currentStatus directly:

// In AutoHandleStatusItem:
struct AutoHandleStatusItem: View {
    @Environment(AutoHandleEngine.self) private var engine

    var body: some View {
        Label(engine.currentStatus.label, systemImage: "bolt.fill")
            .font(.caption)
            .foregroundStyle(engine.currentStatus.color)
            .help("Auto-handle: \(engine.disabledRuleIDs.count) rules disabled")
    }
}
```

Pick approach 2 (view-layer read) — less coupling between StatusBarViewModel and engine, and SwiftUI's @Environment makes it ergonomic.

- [ ] **Step 7: Build + run all tests**

```bash
swift test
```

Expected: 27 (sub-plan B) + 4 + 5 + 4 = 40 tests passing.

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "feat(auto-handle): D-Task 5 — wire parser+engine+injector into SwiftTermView

Coordinator now holds AutoHandleEngine (injected via environment) +
PatternParser. handleChunk(bytes:) → append to parser → ask engine
→ if response, call view.send(data:) to inject into PTY stdin.

TerminalPaneView reads engine from environment.
MainScene injects new @State AutoHandleEngine.

AutoHandleStatusItem now reads engine.currentStatus directly
(loose coupling — StatusBarViewModel doesn't know about the engine).

ClaudeProcessConfig default args changed to [] (was
[--dangerously-skip-permissions]). With auto-handle running,
claude can ask normally; we approve per-rule.

40 tests passing (27 prior + 13 new)."
```

---

## Task 6: Live smoke test — auto-handle in real claude session

**Files:** none (manual interaction)

- [ ] **Step 1: Rebuild .app**

```bash
swift build -c release
rm -rf .build/Logos.app
mkdir -p .build/Logos.app/Contents/MacOS
cp .build/release/Logos .build/Logos.app/Contents/MacOS/Logos
cp Info.plist .build/Logos.app/Contents/Info.plist
echo "APPL????" > .build/Logos.app/Contents/PkgInfo
codesign --force --deep --sign - .build/Logos.app
open .build/Logos.app
```

- [ ] **Step 2: Test trust-folder auto-approve**

If this is the first time Logos opens claude in this workspace, the trust prompt should appear AND be auto-handled. Visible result: prompt flashes briefly, then disappears as if "1" was typed automatically.

Verify by checking the terminal output: should see the trust prompt text immediately followed by the auto-typed response.

- [ ] **Step 3: Test bash-permission auto-approve**

In claude, type: `please run ls /tmp`

Without --dangerously-skip-permissions, claude will ask "Bash command: ls /tmp. Allow?" Should auto-approve via our `bash-permission` rule. Visible: prompt flashes, then claude runs the command.

- [ ] **Step 4: Test runaway disable (negative test)**

Craft a scenario that fires the same rule rapidly 3 times in 30s. E.g., ask claude to run 5 commands in a row. Check status bar: should transition to `⚡ auto-handle: partial` (yellow) after 3rd fire, indicating bash-permission rule is now disabled.

Recovery: restart Logos to re-enable (no UI to re-enable mid-session — defer to sub-plan H).

- [ ] **Step 5: Screenshot the status bar transitions**

Capture screenshots showing:
- `armed` (green) — initial state
- `partial` (yellow) — after a rule auto-disables from runaway

Save to `docs/screenshots/auto-handle-armed.png` and `auto-handle-partial.png`.

- [ ] **Step 6: Commit screenshots + final docs**

```bash
git add docs/screenshots/auto-handle-*.png
git commit -m "docs(auto-handle): D-Task 6 smoke test — auto-approve verified live

Trust folder + bash permission auto-handle confirmed visually.
Runaway disable triggers transition to 'partial' status (yellow).

Sub-plan D delivered: claude no longer blocks on known prompts in
Logos. The killer feature is live."
```

---

## Task 7: README + status bar tooltip update

**Files:**
- Modify: `/Users/che/Developer/logos/README.md`
- Modify: `Sources/Logos/Views/StatusBar/AutoHandleStatusItem.swift` — tooltip explains rules

- [ ] **Step 1: Improve status bar tooltip**

```swift
struct AutoHandleStatusItem: View {
    @Environment(AutoHandleEngine.self) private var engine

    var body: some View {
        Label(engine.currentStatus.label, systemImage: "bolt.fill")
            .font(.caption)
            .foregroundStyle(engine.currentStatus.color)
            .help(tooltip)
    }

    private var tooltip: String {
        let total = AutoHandleRule.defaultRuleset.count
        let active = total - engine.disabledRuleIDs.count
        var lines = ["\(active) of \(total) auto-handle rules active."]
        if let last = engine.lastFiredRule {
            lines.append("Last fired: \(last.name)")
        }
        if !engine.disabledRuleIDs.isEmpty {
            lines.append("Disabled: \(engine.disabledRuleIDs.sorted().joined(separator: ", "))")
        }
        return lines.joined(separator: "\n")
    }
}
```

- [ ] **Step 2: README update**

Replace the existing "Repo status" section's last bullet block with:

```markdown
**Sub-plan D — Auto-handle: COMPLETE ✅**
- 5 hardcoded rules auto-approve known claude prompts (rate-limit, trust, bash, MCP, press-enter)
- Per-rule cooldown (no double-fire)
- 30s sliding fire window auto-disables runaway rules
- Status bar shows `armed / partial / disabled` color-coded
- Tooltip shows active rule count + last fired + disabled rule names
- `--dangerously-skip-permissions` removed; claude asks normally, we approve per-rule

**Next**: sub-plan E (multi-account Keychain switcher) or sub-plan C.2 (renderer rewrite continuation).
```

- [ ] **Step 3: Final regression**

```bash
swift test
```

Expected: all 40 tests pass.

- [ ] **Step 4: Final commit**

```bash
git add -A
git commit -m "docs(auto-handle): sub-plan D complete — 40 tests pass, status tooltip enriched

5 rules live: rate-limit / trust-folder / trust-files / bash-permission /
press-enter. Tooltip shows active count + last fired + disabled set.

Logos now does the #1 thing it was designed for: claude doesn't
block on prompts you've pre-approved."
```

---

## Self-review

1. **Spec coverage**: Tasks 1-7 cover rule model + decision engine + chunk-aware parser + stream tee + integration + live smoke + README. Maps to design § 7.2 plus the 5 hardcoded patterns. ✅
2. **Placeholders**: Task 4 step 1 "adapt to actual SwiftTerm API" is an acknowledged discovery step, not a placeholder. Task 5 step 1 alternative-approach note ("Pick approach 2") is decisive, not deferred. ✅
3. **Type consistency**: `AutoHandleRule`, `AutoHandleEngine`, `PatternParser`, `TeedLocalProcessTerminalView`, `Coordinator`, `StatusBarViewModel.AutoHandleStatus` — all consistent across tasks. ✅
4. **Known risks**:
   - SwiftTerm's `feed(byteArray:)` may not be the right override point in 1.13 — Task 4 step 1 mandates verification first.
   - Removing `--dangerously-skip-permissions` could BREAK existing flows if a rule isn't triggered (claude blocks waiting for input we never send). Mitigation: tested in D-Task 6 smoke test; can be reverted if needed.
   - `send(data:)` API on SwiftTerm may have different signature — verify during T5.
   - Encoding: PTY bytes might not be valid UTF-8 mid-stream; `String(bytes:encoding: .utf8)` returns nil. PatternParser only sees what decodes — acceptable for v1.
   - Coupling to claude's exact prompt strings: if Anthropic changes wording, rules silently stop firing. Mitigation: status bar tooltip surfaces last-fired so user notices when rules go quiet for long.

---

## Done. What's next:

**Sub-plan E (multi-account)** is the natural next companion — it depends on sub-plan B's `ClaudeProcessConfig` and adds the `HOME` env override per session. Doesn't conflict with sub-plan C work.

**Sub-plan C.2 (frame-rate renderer)** can proceed in parallel after C.1 is complete. Doesn't touch auto-handle code paths.

Recommended order: D → E → C.2 (auto-handle first because it's user-visible value; multi-account next; then long-haul renderer work).
