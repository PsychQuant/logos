# Sub-plan C — Renderer Rewrite (Roadmap) + Phase C.1 Detail

> **This is a multi-phase initiative.** Sub-plan C spans **6 phases over 3-4 months focused**. This document contains: (1) a roadmap-level overview of all 6 phases, and (2) an executable detailed plan for **Phase C.1 only** (fork + replay harness). Subsequent phases (C.2-C.6) get their own detailed plans after C.1's lessons land.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement Phase C.1 task-by-task. **Do not attempt C.2-C.6 from this document — those need their own plan files.**

**Overall Goal:** Eliminate render tearing/flicker in Claude Code's terminal output by replacing SwiftTerm's streaming renderer with a frame-rate, damage-tracking, coalesced renderer. This is **the moat** — the technical differentiator no competitor will replicate.

**Why this is hard:** Terminal emulators are stream-based: each ANSI escape code is processed and rendered immediately. Claude Code's tool calls + plan mode + streaming token output all use cursor positioning + region clears + reprints, which the human eye perceives as flicker mid-redraw. Eliminating this means: (a) buffering escape codes into frame batches; (b) cell-level diffing so only changed regions repaint; (c) detecting Claude's redraw patterns so we hold commits until the redraw is complete.

**Tech Stack:** Swift 6, SwiftUI/AppKit, Core Animation (CALayer), forked SwiftTerm

---

## Roadmap — 6 Phases

| Phase | Duration | What | Deliverable |
|-------|----------|------|-------------|
| **C.1** | 3-4 weeks | Fork SwiftTerm; build capture/replay harness | Standalone tool that records claude PTY stream + replays it into a SwiftTerm view (no app context). Baseline behavior captured for regression testing. **This document covers C.1 in detail.** |
| **C.2** | 4-6 weeks | Frame-rate render loop (60Hz, atomic frame swap) | Renderer batches escape codes within a 16ms frame, swaps atomically. May not yet eliminate flicker fully but reduces it. Measurable: frame-rate consistency. |
| **C.3** | 3-4 weeks | Cell-level damage tracking | Only re-render cells that actually changed (vs. full grid every frame). Reduces CPU/GPU load. Sets up for atomic visual commits. |
| **C.4** | 2-3 weeks | Smart redraw coalescing | Heuristics detect "Claude is in the middle of a multi-step redraw" (e.g., consecutive cursor positioning + clear + reprint within X ms). Hold frame commit until idle. **This is what actually eliminates perceived flicker.** |
| **C.5** | continuous | Claude Code compatibility testing | Replay harness from C.1 + new baseline + every Claude Code interaction pattern (tool calls, plan mode, streaming, permissions, errors). Regression catch. |
| **C.6** | 2-3 weeks | Performance tuning | 10k+ scrollback without dropped frames. Profile + optimize hot paths. Test on Intel Macs (still supported on macOS 15? confirm during this phase). |

**Total**: 14-22 weeks. Realistic target: **4 months focused** with vibe-coding leverage on boilerplate, slower on algorithm design.

---

## Phase C.1 — Detailed Plan

### Goal

After C.1 you have:
1. A forked SwiftTerm repo at `github.com/<user>/SwiftTerm` (or similar) with a `logos-renderer-base` branch tracking upstream
2. Logos's `Package.swift` pointing to your fork
3. A standalone CLI/test harness `swiftterm-replay` that:
   - Records claude PTY output to a `.ttyrec`-format file (or similar)
   - Replays a captured file into a `LocalProcessTerminalView` at recorded timing OR at any speed
4. A captured corpus of representative Claude Code interactions:
   - Simple text streaming response
   - Tool call (Edit) approve flow
   - Plan mode approve flow
   - Rate-limit prompt
   - Permission prompt
   - Streaming token output
5. Visual baseline screenshots/recordings of what the current upstream SwiftTerm looks like rendering each capture (so we can compare against renderer changes later)

After C.1 you have NOT touched the SwiftTerm renderer internals. C.2 starts that work.

### Architecture

```
┌──────────────────────────────────────────────────────┐
│  capture mode                                        │
│  ┌──────────┐    PTY  ┌──────────┐                  │
│  │ claude   │ ─────►  │ tee      │                  │
│  │ subproc  │         │ recorder │ → frames.ttyrec  │
│  └──────────┘         └──────────┘                  │
│                                                      │
│  replay mode                                         │
│  ┌──────────────┐                                    │
│  │frames.ttyrec │ ───► LocalProcessTerminalView      │
│  │              │      (or a fake-PTY adapter)       │
│  └──────────────┘                                    │
└──────────────────────────────────────────────────────┘
```

### Resolved design decisions for C.1

- **Fork host**: User's personal GitHub account (will need confirmation during execution)
- **Fork branch strategy**: Long-lived `logos-renderer-base` branch off upstream `main`. C.2+ work happens on subsequent branches (`logos-renderer-frame-loop`, etc.) merged into `logos-renderer-base`.
- **Capture format**: `ttyrec` (industry standard for terminal recording). Header per frame: 3×int (sec, usec, len). Payload: raw bytes from PTY.
- **Capture tool**: standalone Swift CLI in `logos` repo, NOT in SwiftTerm fork (keeps fork minimal — fork only contains library code that's eventually published).
- **Replay tool**: same CLI, different mode flag (`--record` vs `--replay`).
- **Replay rendering**: feed bytes into `TerminalView.feed(byteArray:)` directly (SwiftTerm's public API), no real PTY needed.

### File structure (delta from sub-plan B)

```
logos/                                                NO CHANGE to existing app
├── Package.swift                                     MODIFY — point dep at fork
├── Tools/                                            NEW directory
│   └── SwiftTermReplay/
│       ├── Package.swift                             NEW — standalone tool
│       └── Sources/SwiftTermReplay/
│           ├── main.swift                            NEW — CLI entry
│           ├── Recorder.swift                        NEW — PTY tee + ttyrec writer
│           ├── Replayer.swift                        NEW — read ttyrec + feed into view
│           └── Captures/                             NEW directory
│               └── README.md                         (describes captured scenarios)
└── docs/
    └── renderer-baselines/                           NEW — screenshots/recordings of upstream behavior
        ├── 01-simple-streaming.png
        ├── 02-edit-tool.png
        ├── 03-plan-mode.png
        ├── 04-rate-limit.png
        └── 05-permission.png

<user-github>/SwiftTerm (NEW FORK)
├── (upstream content unchanged on logos-renderer-base branch)
└── README.md                                         MODIFY — note Logos fork purpose
```

---

## Tasks

### Task 1: Fork SwiftTerm — **ALREADY DONE 2026-05-26** ✅

> Fork created at `https://github.com/PsychQuant/SwiftTerm` with `logos-renderer-base` branch tracking upstream `main`. Done via `gh repo fork + gh api git/refs` during pre-flight setup. Skip steps 1-5 below; jump to Task 2.

**Original task definition (for reference):**

**This task originally required manual GitHub action by the user.**

**Files:** none (GitHub UI)

- [ ] **Step 1: User forks `migueldeicaza/SwiftTerm`**

In GitHub UI: navigate to `https://github.com/migueldeicaza/SwiftTerm`, click "Fork", choose user's personal account.

- [ ] **Step 2: User clones fork locally**

```bash
cd /Users/che/Developer/
git clone git@github.com:<user>/SwiftTerm.git swiftterm-fork
cd swiftterm-fork
git remote add upstream https://github.com/migueldeicaza/SwiftTerm.git
git fetch upstream
```

- [ ] **Step 3: User creates `logos-renderer-base` branch tracking upstream main**

```bash
cd /Users/che/Developer/swiftterm-fork
git checkout -b logos-renderer-base main
git push -u origin logos-renderer-base
```

- [ ] **Step 4: User updates fork README**

Add a note at the top of `README.md` in the fork:

```markdown
> **Note:** This is a fork maintained for the [Logos](https://github.com/<user>/logos) project. The `logos-renderer-base` branch tracks upstream changes. Renderer modifications happen on derivative branches like `logos-renderer-frame-loop` and merge back here.
>
> For the original library, see [migueldeicaza/SwiftTerm](https://github.com/migueldeicaza/SwiftTerm).
```

Commit + push.

- [ ] **Step 5: Confirmation**

Verify with: `gh repo view <user>/SwiftTerm --json defaultBranchRef,url`
Expected: shows fork URL, default branch is whatever upstream had.

---

### Task 2: Switch Logos to use forked SwiftTerm

**Files:**
- Modify: `Package.swift`

- [ ] **Step 1: Update `Package.swift`**

Replace `migueldeicaza/SwiftTerm.git` URL with user's fork URL:

```swift
dependencies: [
    // OLD: .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.2.0")
    .package(url: "https://github.com/PsychQuant/SwiftTerm.git", branch: "logos-renderer-base")
]
```

Replace `<user>` with actual GitHub username determined in Task 1.

- [ ] **Step 2: Resolve + build**

```bash
swift package update
swift build
```

Expected: SUCCESS. Behavior should be identical to before (we're tracking upstream — no renderer changes yet).

- [ ] **Step 3: Smoke test — Logos still hosts claude**

```bash
swift build -c release
# Rebundle as in sub-plan B
# Launch — verify claude still spawns
```

Expected: indistinguishable from sub-plan B end state.

- [ ] **Step 4: Commit**

```bash
git add Package.swift Package.resolved
git commit -m "feat(renderer): switch SwiftTerm dependency to logos fork

Tracks logos-renderer-base branch. Behavior identical to upstream
until C.2 begins renderer modifications. Fork URL:
https://github.com/PsychQuant/SwiftTerm"
```

---

### Task 3: Initialize SwiftTermReplay tool

**Files:**
- Create: `Tools/SwiftTermReplay/Package.swift`
- Create: `Tools/SwiftTermReplay/Sources/SwiftTermReplay/main.swift`

**Purpose:** Standalone Swift Package executable, separate from main Logos app. Lives in `Tools/` so it's clearly a dev tool not shipped in the app bundle.

- [ ] **Step 1: Create `Tools/SwiftTermReplay/Package.swift`**

```swift
// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "SwiftTermReplay",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "swiftterm-replay", targets: ["SwiftTermReplay"])
    ],
    dependencies: [
        // Same fork as main app
        .package(url: "https://github.com/PsychQuant/SwiftTerm.git", branch: "logos-renderer-base"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.0.0")
    ],
    targets: [
        .executableTarget(
            name: "SwiftTermReplay",
            dependencies: [
                .product(name: "SwiftTerm", package: "SwiftTerm"),
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ]
        )
    ]
)
```

- [ ] **Step 2: Create minimal `main.swift`**

```swift
import ArgumentParser
import Foundation

@main
struct SwiftTermReplay: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "swiftterm-replay",
        abstract: "Record + replay PTY streams through SwiftTerm for renderer testing.",
        subcommands: [Record.self, Replay.self]
    )
}
```

- [ ] **Step 3: Verify tool builds**

```bash
cd Tools/SwiftTermReplay
swift build
swift run swiftterm-replay --help
```

Expected: prints help with subcommands `record` and `replay` listed (though both undefined yet — see Task 4-5).

- [ ] **Step 4: Commit**

```bash
cd /Users/che/Developer/logos
git add Tools/
git commit -m "feat(renderer): initialize SwiftTermReplay dev tool

Standalone Swift Package executable for recording + replaying PTY
streams into SwiftTerm. Lives in Tools/ — not bundled into Logos app.

CLI skeleton with ArgumentParser; Record + Replay subcommands stubbed
out, implementations in next tasks."
```

---

### Task 4: Record subcommand — PTY tee to ttyrec file

**Files:**
- Create: `Tools/SwiftTermReplay/Sources/SwiftTermReplay/Recorder.swift`

**Purpose:** Spawn `claude` (or any command) with a PTY. Tee its stdout to: (a) the user's terminal so they can interact normally, (b) a ttyrec file with timestamps so we can replay.

**ttyrec format**:
- 3 × little-endian int32: seconds, microseconds, length
- Then `length` bytes of raw payload
- Repeat for each chunk

- [ ] **Step 1: Create `Recorder.swift`**

```swift
import ArgumentParser
import Foundation
import Darwin

extension SwiftTermReplay {

    struct Record: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Run a command in a PTY and record stdout to a ttyrec file."
        )

        @Option(name: .shortAndLong, help: "Output ttyrec file path")
        var output: String = "capture.ttyrec"

        @Argument(parsing: .remaining, help: "Command + args (e.g. 'claude' or 'bash -c \"ls\"')")
        var command: [String]

        mutating func run() throws {
            guard !command.isEmpty else {
                throw ValidationError("Must provide a command to record.")
            }

            let outputURL = URL(fileURLWithPath: output)
            guard FileManager.default.createFile(atPath: outputURL.path, contents: nil) else {
                throw ValidationError("Cannot create \(output)")
            }
            let fileHandle = try FileHandle(forWritingTo: outputURL)
            defer { try? fileHandle.close() }

            // Open PTY
            var amaster: Int32 = -1
            var aslave: Int32 = -1
            guard openpty(&amaster, &aslave, nil, nil, nil) == 0 else {
                throw ValidationError("openpty failed: \(String(cString: strerror(errno)))")
            }

            // Fork + exec child
            let pid = fork()
            if pid == 0 {
                // Child
                close(amaster)
                setsid()
                _ = ioctl(aslave, UInt(TIOCSCTTY), 0)
                dup2(aslave, 0)
                dup2(aslave, 1)
                dup2(aslave, 2)
                close(aslave)

                let argv: [UnsafeMutablePointer<CChar>?] = command.map {
                    strdup($0)
                } + [nil]
                execvp(command[0], argv)
                perror("execvp")
                exit(1)
            }

            // Parent: read amaster, write to file + stdout
            close(aslave)
            let startTime = Date()
            let bufferSize = 4096
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
            defer { buffer.deallocate() }

            print("Recording \(command.joined(separator: " ")) → \(output) (Ctrl-C to stop)")

            while true {
                let n = read(amaster, buffer, bufferSize)
                if n <= 0 { break }

                let elapsed = Date().timeIntervalSince(startTime)
                let sec = Int32(elapsed)
                let usec = Int32((elapsed - Double(sec)) * 1_000_000)
                let len = Int32(n)

                // Write ttyrec header (little-endian)
                var header = [sec, usec, len]
                let headerData = Data(bytes: &header, count: 12)
                try fileHandle.write(contentsOf: headerData)

                // Write payload
                let payload = Data(bytes: buffer, count: n)
                try fileHandle.write(contentsOf: payload)

                // Also pipe to stdout so user sees what's happening
                FileHandle.standardOutput.write(payload)
            }

            print("\nRecording complete: \(output)")
        }
    }
}
```

- [ ] **Step 2: Update `main.swift` to register Record subcommand**

The `subcommands: [Record.self, Replay.self]` line in main.swift already lists them; this task just makes the type exist.

- [ ] **Step 3: Build + test record with simple command**

```bash
cd Tools/SwiftTermReplay
swift build
swift run swiftterm-replay record --output /tmp/test-ls.ttyrec ls -la /tmp
file /tmp/test-ls.ttyrec
xxd /tmp/test-ls.ttyrec | head -10
```

Expected: file exists, first 12 bytes are little-endian (sec, usec, len), then ASCII output from `ls`.

- [ ] **Step 4: Record claude session**

```bash
swift run swiftterm-replay record --output /tmp/claude-session.ttyrec claude
# Type something, wait for response, Ctrl-C to stop
ls -lh /tmp/claude-session.ttyrec
```

Expected: file size > 0, captures the claude interaction.

- [ ] **Step 5: Commit**

```bash
cd /Users/che/Developer/logos
git add Tools/
git commit -m "feat(renderer): SwiftTermReplay record — PTY tee to ttyrec

Uses openpty + fork/execvp to spawn child in PTY. Tees stdout to:
(a) ttyrec file with sec/usec/len headers, (b) parent's stdout
for user visibility. Captures claude session as raw bytes for later
replay through renderer."
```

---

### Task 5: Replay subcommand — ttyrec → SwiftTerm view

**Files:**
- Create: `Tools/SwiftTermReplay/Sources/SwiftTermReplay/Replayer.swift`

**Purpose:** Open an NSApplication window with a `LocalProcessTerminalView` (or just `TerminalView`), feed it the bytes from a ttyrec file at recorded timing OR at a configurable speed multiplier.

- [ ] **Step 1: Create `Replayer.swift`**

```swift
import ArgumentParser
import Foundation
import AppKit
import SwiftTerm

extension SwiftTermReplay {

    struct Replay: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Replay a ttyrec file through a SwiftTerm view."
        )

        @Option(name: .shortAndLong, help: "Input ttyrec file")
        var input: String

        @Option(name: .shortAndLong, help: "Speed multiplier (1.0 = real-time, 0 = instant)")
        var speed: Double = 1.0

        mutating func run() throws {
            let inputURL = URL(fileURLWithPath: input)
            guard FileManager.default.fileExists(atPath: inputURL.path) else {
                throw ValidationError("Input file not found: \(input)")
            }

            // Read entire file (small enough for now; stream for >100MB later)
            let data = try Data(contentsOf: inputURL)
            let chunks = try Self.parseTtyrec(data: data)
            print("Loaded \(chunks.count) chunks from \(input)")

            // Set up minimal NSApp window with SwiftTerm
            let app = NSApplication.shared
            app.setActivationPolicy(.regular)

            let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 1000, height: 700))
            let window = NSWindow(
                contentRect: view.frame,
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "SwiftTermReplay: \(inputURL.lastPathComponent)"
            window.contentView = view
            window.makeKeyAndOrderFront(nil)
            app.activate(ignoringOtherApps: true)

            // Schedule chunk feeds
            DispatchQueue.global().async {
                var lastTime: Double = 0
                for chunk in chunks {
                    let delay = (chunk.timestamp - lastTime) / max(speed, 0.001)
                    if speed > 0 {
                        Thread.sleep(forTimeInterval: delay)
                    }
                    DispatchQueue.main.async {
                        view.feed(byteArray: ArraySlice(chunk.payload))
                    }
                    lastTime = chunk.timestamp
                }
                print("Replay complete.")
            }

            app.run()
        }

        struct Chunk {
            let timestamp: Double  // sec + usec/1e6
            let payload: [UInt8]
        }

        static func parseTtyrec(data: Data) throws -> [Chunk] {
            var chunks: [Chunk] = []
            var index = 0
            while index + 12 <= data.count {
                let sec = data.subdata(in: index..<(index+4)).withUnsafeBytes {
                    $0.load(as: Int32.self)
                }
                let usec = data.subdata(in: (index+4)..<(index+8)).withUnsafeBytes {
                    $0.load(as: Int32.self)
                }
                let len = Int(data.subdata(in: (index+8)..<(index+12)).withUnsafeBytes {
                    $0.load(as: Int32.self)
                })
                index += 12
                guard index + len <= data.count else {
                    throw ValidationError("Truncated ttyrec at offset \(index)")
                }
                let payload = Array(data.subdata(in: index..<(index+len)))
                let timestamp = Double(sec) + Double(usec) / 1_000_000
                chunks.append(Chunk(timestamp: timestamp, payload: payload))
                index += len
            }
            return chunks
        }
    }
}
```

- [ ] **Step 2: Build + test replay**

```bash
cd Tools/SwiftTermReplay
swift build
swift run swiftterm-replay replay --input /tmp/test-ls.ttyrec --speed 1.0
```

Expected: a small window opens, shows the `ls` output as if you ran it in a terminal. Window stays open until closed.

```bash
swift run swiftterm-replay replay --input /tmp/claude-session.ttyrec --speed 1.0
```

Expected: claude session plays back at real speed. Tearing/flicker matches what you saw in the original session (this is the BASELINE for C.2+ comparison).

- [ ] **Step 3: Commit**

```bash
cd /Users/che/Developer/logos
git add Tools/
git commit -m "feat(renderer): SwiftTermReplay replay — ttyrec → SwiftTerm view

NSApp host with TerminalView. Parses ttyrec format (3xInt32 headers
+ payload chunks). Feeds bytes via view.feed(byteArray:) at recorded
timing scaled by --speed multiplier (1.0=real, 0=instant).

Now we can: (a) record any claude scenario once, (b) replay it
deterministically through renderer changes in C.2+. Provides regression
visibility we lack from one-shot live runs."
```

---

### Task 6: Capture baseline corpus

**Files:**
- Create: `Tools/SwiftTermReplay/Sources/SwiftTermReplay/Captures/README.md`
- Create: `Tools/SwiftTermReplay/Sources/SwiftTermReplay/Captures/01-simple-streaming.ttyrec`
- Create: `Tools/SwiftTermReplay/Sources/SwiftTermReplay/Captures/02-edit-tool.ttyrec`
- Create: `Tools/SwiftTermReplay/Sources/SwiftTermReplay/Captures/03-plan-mode.ttyrec`
- Create: `Tools/SwiftTermReplay/Sources/SwiftTermReplay/Captures/04-rate-limit.ttyrec` (if user can reproduce — see step 4)
- Create: `Tools/SwiftTermReplay/Sources/SwiftTermReplay/Captures/05-permission.ttyrec`

**Purpose:** Reproducible test scenarios. Each captures a representative Claude Code interaction so future renderer changes can be regression-tested.

- [ ] **Step 1: Capture simple streaming response**

```bash
cd /Users/che/Developer/logos/Tools/SwiftTermReplay
swift run swiftterm-replay record \
  --output Sources/SwiftTermReplay/Captures/01-simple-streaming.ttyrec \
  claude
```

In claude: type `count from 1 to 50, one per line` → wait for full response → `/exit` to quit (Ctrl-C if /exit doesn't trigger).

- [ ] **Step 2: Capture Edit tool flow**

```bash
swift run swiftterm-replay record \
  --output Sources/SwiftTermReplay/Captures/02-edit-tool.ttyrec \
  claude
```

In claude: ensure you're in a directory with a file like `test.txt`. Type `please add a line "hello world" to test.txt`. Let claude propose the edit. Approve. Exit.

- [ ] **Step 3: Capture plan mode**

```bash
swift run swiftterm-replay record \
  --output Sources/SwiftTermReplay/Captures/03-plan-mode.ttyrec \
  claude --permission-mode plan
```

(Or however your claude version enters plan mode — adjust flag.)
In claude: ask for a 3-step plan. Approve. Exit.

- [ ] **Step 4: Capture rate limit (BEST EFFORT)**

This is the hardest to reproduce on demand. Options:
- (a) Run a long-running automated task that intentionally hits the limit
- (b) Mock: hand-craft a ttyrec with the exact rate-limit ANSI sequences (requires reverse-engineering the bytes)
- (c) Skip for now and capture if you happen to hit one organically

If skipping, leave a placeholder `04-rate-limit.ttyrec.MISSING` file noting the gap.

- [ ] **Step 5: Capture permission prompt**

Run claude WITHOUT `--dangerously-skip-permissions` so it asks for permission on a Bash tool call:

```bash
swift run swiftterm-replay record \
  --output Sources/SwiftTermReplay/Captures/05-permission.ttyrec \
  claude
```

In claude: ask it to run `ls /tmp`. When it asks "Allow?" — capture both responses (yes once, then deny once for variety). Exit.

- [ ] **Step 6: Write captures README**

In `Tools/SwiftTermReplay/Sources/SwiftTermReplay/Captures/README.md`:

```markdown
# Capture Corpus

Each `.ttyrec` is a representative Claude Code interaction recorded with `swiftterm-replay record`. Used as a stable replay corpus for renderer regression testing.

| File | Scenario | Notes |
|------|----------|-------|
| `01-simple-streaming.ttyrec` | Long streaming response (count 1-50) | Tests token streaming render |
| `02-edit-tool.ttyrec` | Edit tool propose + approve | Tests tool call diff render |
| `03-plan-mode.ttyrec` | Plan mode 3-step plan + approve | Tests plan checklist render |
| `04-rate-limit.ttyrec` | Rate-limit "keep going" prompt | If MISSING, see C.5 for synthetic generation |
| `05-permission.ttyrec` | MCP / Bash permission prompt | Tests inline approve UI |

## Re-recording

If Claude Code's output format changes (Anthropic updates), re-record:
```bash
cd Tools/SwiftTermReplay
swift run swiftterm-replay record --output Sources/SwiftTermReplay/Captures/<scenario>.ttyrec claude
```

## Using for regression

Each renderer phase (C.2+) should replay all captures and visually compare against baselines in `/docs/renderer-baselines/`.
```

- [ ] **Step 7: Take baseline screenshots**

For each capture, replay it through upstream SwiftTerm (unchanged) and screenshot:

```bash
for cap in 01-simple-streaming 02-edit-tool 03-plan-mode 05-permission; do
    swift run swiftterm-replay replay --input Sources/SwiftTermReplay/Captures/$cap.ttyrec --speed 0
    # Manually screenshot the window — save to docs/renderer-baselines/<cap>.png
    # Close window before next iteration
done
```

(This step is partially manual — screencap timing depends on user attention. Document as "best-effort baseline" in the README; perfect frame-by-frame baseline comes in C.5.)

- [ ] **Step 8: Commit baselines**

```bash
git add Tools/SwiftTermReplay/Sources/SwiftTermReplay/Captures/ docs/renderer-baselines/
git commit -m "feat(renderer): baseline capture corpus + upstream-renderer screenshots

5 .ttyrec captures of representative claude interactions:
streaming, Edit tool, plan mode, rate-limit (if reproduced),
permission prompt. Screenshots of upstream SwiftTerm rendering
each serve as visual baseline for C.2+ regression."
```

---

### Task 7: Phase C.1 retrospective doc

**Files:**
- Create: `docs/renderer-c1-retrospective.md`

**Purpose:** Capture what we learned about SwiftTerm internals + ttyrec format + replay timing during C.1. This document seeds C.2's plan-writing.

- [ ] **Step 1: Write retrospective**

```markdown
# Phase C.1 Retrospective

## What we learned about SwiftTerm

- `TerminalView` (base class) vs `LocalProcessTerminalView` (PTY-wired subclass)
  - For replay, we use `TerminalView` directly + `feed(byteArray:)`
- Renderer entry points: ... (fill in based on grep findings during C.1)
- ANSI parser is in `SwiftTerm/Sources/SwiftTerm/Terminal/Terminal.swift`
- Per-cell rendering happens in `MacTerminalView.swift drawRect` ... (verify during exec)

## Tearing source confirmed

(Document specific frame sequences from captures that exhibit tearing. e.g.
"Edit tool diff causes 3 visible mid-state frames between ANSI clear-region
and final reprint — confirmed via replay at --speed 0.1")

## ttyrec format gotchas

(Document any edge cases hit during capture/replay implementation)

## C.2 starting points

Based on the above, C.2 (frame-rate renderer) should:
- Hook into ... (specific SwiftTerm internal)
- Use ... pattern
- Avoid ... pitfall

(Concrete — not "TBD". Filled out by the developer who completed C.1.)
```

- [ ] **Step 2: Commit**

```bash
git add docs/renderer-c1-retrospective.md
git commit -m "docs(renderer): C.1 retrospective — learnings for C.2 plan-writing

SwiftTerm internals map, tearing source confirmation per capture,
ttyrec format gotchas, concrete C.2 starting points."
```

---

## Phase C.1 Done. What's next:

After C.1 you have a stable foundation to start C.2 (frame-rate renderer). Before invoking writing-plans for C.2:

1. **Read the retrospective.** C.2's plan should specifically address what C.1 learned about SwiftTerm internals.
2. **Pick ONE concrete tearing source** from C.1 captures to target first. Don't try to fix all tearing at once.
3. **Define C.2's success criterion** measurably: e.g., "replay capture `02-edit-tool.ttyrec` at speed 1.0 with no visible mid-state frames longer than 16ms."

Then run writing-plans on C.2.

---

## Self-review (for the writer)

1. **Spec coverage**: Tasks 1-7 cover fork + tool init + record + replay + baseline corpus + retrospective. ✅
2. **Placeholders**: Task 6 step 4 "if user can reproduce" rate-limit acknowledged as best-effort with clear fallback. Task 7 has placeholders explicitly meant to be filled during execution — those are correct (they document what we learn, not what we predict). ✅
3. **Type consistency**: `Recorder.Record`, `Replayer.Replay`, `SwiftTermReplay` consistent. ✅
4. **Known risks**:
   - User must have GitHub account for fork (assumed). If not, fork to PsychQuant org instead.
   - SwiftTerm's `feed(byteArray:)` signature might differ in 1.13 — verify during Task 5 execution; adapt if needed.
   - ttyrec on macOS using `openpty` + `fork` is unusual in Swift; if Process abstraction is preferred, swap implementation in Task 4.
   - Capturing claude rate-limit on demand may not be possible — fallback in step 4 acknowledged.
