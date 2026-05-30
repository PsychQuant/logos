# Sub-plan C.2 — Frame-Rate Renderer Loop (The Moat, Phase 2)

> **⚠️ SUPERSEDED (2026-05-30) — do NOT execute this plan.**
> This plan predates the discovery that the pinned SwiftTerm fork (v1.13.0) **already ships a complete Metal renderer** (`MetalTerminalRenderer`: vsync `draw(in:)`, glyph atlas, per-row damage tracking, frame-semaphore double-buffering, ~16.67 ms damage coalescing). Logos simply never called `setUseMetal(true)`. Building the from-scratch CVDisplayLink + cell-grid damage buffer described below would reinvent that infrastructure. C.2 is now delivered by **adopting** the fork's renderer, tracked in the Spectra change `renderer-c2-metal-adoption` (openspec/changes/). The measured CoreGraphics tearing baseline that motivates it is in `docs/renderer-baselines/cg-vs-metal-edit-tool.md`. Kept below for historical context only.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans. **Do not attempt to compress this work into a single session** — phases of this sub-plan involve genuine systems programming risk. Stop and ask if uncertain.

> **Prerequisites:** Sub-plan C.1 complete (fork in place, capture/replay harness working, retrospective filled). Read `docs/renderer-c1-retrospective.md` first.

**Goal:** Eliminate visible mid-state frames during Claude Code's tool-call redraws by replacing SwiftTerm's draw-immediately render path with a frame-rate-driven (60Hz) atomic commit loop. After C.2 you should be able to replay `02-edit-tool.ttyrec` at `--speed 1.0` and see NO frame where the diff region is partially-cleared / partially-reprinted.

**Architecture decision (from C.1 retrospective starting point #2):** Buffer at the **cell-grid level after parsing**, NOT at the byte stream upstream of `feed(byteArray:)`. This means:
- SwiftTerm's existing ANSI parser keeps doing its work (it's mature; we don't rewrite it)
- We intercept the **invalidation** path — when SwiftTerm marks cells dirty, we batch dirty markings into a frame-coalesced commit
- The actual `drawRect`/`setNeedsDisplay` call gets driven by a `CVDisplayLink` at display refresh rate
- Within a frame: collect all cell mutations, commit at vsync

**The first measurable acceptance test** (from C.1 retrospective #4):
> Replay `02-edit-tool.ttyrec` at `--speed 1.0` through forked-SwiftTerm-with-C.2-renderer and assert: no observable mid-state frame longer than 16ms (one display refresh).

**Tech Stack:** Swift 6, AppKit, Core Animation (`CVDisplayLink`, `CALayer`), forked SwiftTerm (modifying renderer internals on a derivative branch off `logos-renderer-base`)

---

## Architecture (sketch)

```
   PTY bytes
      │
      ▼
   ┌──────────────────────┐
   │ SwiftTerm Terminal   │  (unchanged — keep mature ANSI parser)
   │   model state +      │
   │   cell grid          │
   └──────┬───────────────┘
          │ marks cells dirty
          ▼
   ┌──────────────────────┐
   │ NEW: Damage Buffer    │  ← C.2 introduces this layer
   │   accumulates dirty   │     between SwiftTerm and the
   │   cells per frame     │     existing draw path
   └──────┬───────────────┘
          │ at next vsync
          ▼
   ┌──────────────────────┐
   │ CVDisplayLink @ 60Hz │  ← drives frame commits
   └──────┬───────────────┘
          │ flush damage
          ▼
   ┌──────────────────────┐
   │ Atomic CALayer       │  ← single draw per frame, not per ANSI seq
   │   composite + display│
   └──────────────────────┘
```

Key insight: SwiftTerm currently does `setNeedsDisplay(rect:)` for every dirty cell range as it parses. macOS coalesces some of this naturally via CoreAnimation, but **the moment of clearing** (the visible "blank frame") happens between parsing the clear ANSI and parsing the reprint that follows — those are SEPARATE `setNeedsDisplay` calls. We need to hold the visible state stable until BOTH are processed.

---

## Decomposition: 5 sub-phases inside C.2

| Phase | Weeks | What | First measurable signal |
|-------|-------|------|-------------------------|
| **C.2.0** | 0.5 | Establish baseline metric — write a screencap-based test that quantifies "mid-state frames" in `02-edit-tool.ttyrec` replay through upstream SwiftTerm | Concrete number: "upstream renders N mid-state frames > 16ms in this capture" |
| **C.2.1** | 1.5 | Introduce `DamageBuffer` layer in forked SwiftTerm (no behavioral change yet — pure pass-through). All dirty-cell calls route through it, but it flushes immediately. Verify replay produces identical visual output. | Replay test still passes with identical screenshots (regression baseline) |
| **C.2.2** | 1.5 | Introduce `CVDisplayLink` timer. `DamageBuffer.flush()` only fires from the timer at vsync, not synchronously. **First behavior change** — expect minor visual differences. | New metric run on `02-edit-tool.ttyrec`: mid-state frame count drops |
| **C.2.3** | 1 | Atomic frame swap — buffer the next cell grid in a back-buffer; swap pointer on flush. Ensures mid-render state never visible. | Replay corpus screenshots: no torn frames detected |
| **C.2.4** | 0.5 | Performance check — replay `01-simple-streaming.ttyrec` at speed 5x; verify no dropped frames | All 5 captures replay smoothly at 5x speed |

**Total**: 5 weeks focused. Allow 6-8 weeks calendar with iteration buffer.

This sub-plan covers **C.2.0 through C.2.2** in detail. C.2.3 + C.2.4 will be planned after C.2.2's lessons. The "stop early and re-plan" gate at C.2.2 is intentional — we'll know more after the first behavior change lands.

---

## Phase C.2.0 Detailed Plan

### Task 0.1: Mid-state-frame quantifier script

**Files:**
- Create: `Tools/SwiftTermReplay/Sources/SwiftTermReplay/FrameSampler.swift`
- Modify: `Tools/SwiftTermReplay/Sources/SwiftTermReplay/Replayer.swift` — `--sample-frames` flag

**Purpose:** Replay a capture and periodically (every 8ms = 120Hz oversampling) screenshot the window. Diff successive frames; count frames where >20% of pixels changed mid-flight (heuristic: "active redraw moment"). Output: a count of "active" frames + their cluster duration. Mid-state frames longer than 16ms are visually perceptible.

**Why this is needed:** Without an automated metric, we'll subjectively eyeball "is it less flickery"? That's not measurable progress. C.2.0 buys us the metric so C.2.1+ have a regression target.

- [ ] **Step 1: Create `FrameSampler.swift`** that takes a `TerminalView` reference and captures CGImages on a timer.

```swift
import AppKit
import CoreGraphics

@MainActor
final class FrameSampler {
    private var samples: [(timestamp: TimeInterval, image: CGImage)] = []
    private var timer: Timer?
    private weak var view: NSView?
    private let startTime = Date()

    init(view: NSView) { self.view = view }

    func start(intervalSeconds: TimeInterval = 0.008) {
        timer = Timer.scheduledTimer(withTimeInterval: intervalSeconds, repeats: true) { [weak self] _ in
            guard let self, let view = self.view else { return }
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            if let cgImage = rep.cgImage {
                self.samples.append((Date().timeIntervalSince(self.startTime), cgImage))
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Returns (totalFrames, midStateClusterDurations).
    /// A "mid-state cluster" is a run of consecutive frames where each
    /// differs from its predecessor by > pixelChangeThreshold.
    func analyze(pixelChangeThreshold: Double = 0.2) -> (total: Int, midStateClusters: [TimeInterval]) {
        guard samples.count >= 2 else { return (samples.count, []) }
        var clusters: [TimeInterval] = []
        var clusterStart: TimeInterval?
        var prevImage = samples[0].image
        for i in 1..<samples.count {
            let curr = samples[i].image
            let changed = Self.pixelChangeRatio(prevImage, curr)
            if changed > pixelChangeThreshold {
                if clusterStart == nil {
                    clusterStart = samples[i-1].timestamp
                }
            } else if let start = clusterStart {
                let end = samples[i].timestamp
                clusters.append(end - start)
                clusterStart = nil
            }
            prevImage = curr
        }
        return (samples.count, clusters)
    }

    /// Crude pixel-change ratio: sample N points, count how many differ.
    private static func pixelChangeRatio(_ a: CGImage, _ b: CGImage) -> Double {
        guard a.width == b.width, a.height == b.height else { return 1.0 }
        let samplePoints = 200
        var diffs = 0
        // Implementation: pixel-sample at 200 random points; count >threshold diffs.
        // (Full implementation in code; sketch here for plan readability.)
        // ... return Double(diffs) / Double(samplePoints)
        return 0  // PLACEHOLDER — fill in during execution
    }
}
```

**This step has a placeholder** because `pixelChangeRatio` is genuine algorithmic work that needs experimentation. Do the simplest version first (sample N pixels, hash them, compare hashes; if hashes differ → "changed"); refine if false positive rate is too high.

- [ ] **Step 2: Wire `--sample-frames` into `Replayer.swift`**

```swift
@Option(name: .long, help: "Sample frames every N ms during replay and print mid-state cluster analysis at exit")
var sampleFrames: Double?

// In run(): after creating view, if sampleFrames set, attach FrameSampler.
```

- [ ] **Step 3: Run baseline measurement on `02-edit-tool.ttyrec` through upstream SwiftTerm**

```bash
cd Tools/SwiftTermReplay
swift run swiftterm-replay replay \
  --input Sources/SwiftTermReplay/Captures/02-edit-tool.ttyrec \
  --speed 1.0 \
  --sample-frames 8
```

Record output. Should look like:
```
Total samples: 850
Mid-state clusters (> 16ms): 12
Longest cluster: 84ms
```

Save this baseline somewhere durable (e.g., `docs/renderer-baselines/02-edit-tool-upstream.txt`).

- [ ] **Step 4: Commit baseline**

```bash
git add -A
git commit -m "feat(renderer): C.2.0 — FrameSampler + baseline mid-state-frame metric

Tools/SwiftTermReplay/FrameSampler.swift captures bitmap snapshots
during replay at configurable interval (default 8ms). analyze()
returns count of frames + mid-state cluster durations.

Baseline measurement on 02-edit-tool.ttyrec through upstream SwiftTerm
documented at docs/renderer-baselines/02-edit-tool-upstream.txt. C.2.1+
will be measured against this baseline."
```

---

## Phase C.2.1 Detailed Plan

### Task 1.1: Branch off fork

**Files:**
- Work in `/Users/che/Developer/swiftterm-fork/` (cloned in C.1)

- [ ] **Step 1: Create branch off logos-renderer-base**

```bash
cd /Users/che/Developer/swiftterm-fork
git checkout logos-renderer-base
git pull
git checkout -b logos-renderer-frame-loop
git push -u origin logos-renderer-frame-loop
```

### Task 1.2: Locate dirty-cell invalidation in SwiftTerm

**Files:** `swiftterm-fork/Sources/SwiftTerm/Mac/MacTerminalView.swift`

- [ ] **Step 1: Read `MacTerminalView.swift` and identify where `setNeedsDisplay` / `setNeedsDisplay(_:NSRect)` is called from the terminal model side**

Look for usages of `terminal.refresh` callback, or direct `setNeedsDisplay` in response to cell changes.

Document findings in this plan as a comment for the next executor.

- [ ] **Step 2: Identify the SINGLE point where each cell-update flows through**

If multiple, refactor to a single point (small refactor, no behavior change). Commit per refactor.

### Task 1.3: Introduce `DamageBuffer` pass-through

**Files:** Create `swiftterm-fork/Sources/SwiftTerm/Mac/DamageBuffer.swift`

- [ ] **Step 1: Write DamageBuffer class** that wraps `(NSRect) -> Void` (the original setNeedsDisplay call):

```swift
@MainActor
final class DamageBuffer {
    private let commit: (NSRect) -> Void
    init(commit: @escaping (NSRect) -> Void) { self.commit = commit }

    /// Pass-through in C.2.1; coalesces in C.2.2.
    func markDirty(_ rect: NSRect) {
        commit(rect)
    }

    /// No-op in C.2.1; flushes accumulated rects in C.2.2.
    func flush() {}
}
```

- [ ] **Step 2: Route MacTerminalView dirty-cell calls through DamageBuffer instance**

The terminal view holds a `damageBuffer: DamageBuffer` initialized with a closure that calls `setNeedsDisplay(_:)`. All previously-direct `setNeedsDisplay` calls become `damageBuffer.markDirty(rect)`.

- [ ] **Step 3: Replay regression test**

Run C.2.0's measurement script again:
```bash
swift run swiftterm-replay replay --input Captures/02-edit-tool.ttyrec --sample-frames 8
```

Expected: mid-state cluster counts IDENTICAL to baseline (within sampling noise). DamageBuffer is pure pass-through; behavior unchanged.

If counts diverge significantly: there's an indirect cell-update path you missed. Find and route through DamageBuffer.

- [ ] **Step 4: Commit + push fork**

```bash
cd /Users/che/Developer/swiftterm-fork
git add -A
git commit -m "feat(renderer): C.2.1 — introduce DamageBuffer pass-through layer

All cell-dirty notifications now route through DamageBuffer instance
on MacTerminalView. Currently pass-through: markDirty() calls commit
closure immediately (= original setNeedsDisplay). flush() is a no-op.

Verified via replay corpus: identical mid-state-cluster metric to
upstream baseline. Sets up for C.2.2 timer-driven flush."
git push
```

Open a PR to PsychQuant/SwiftTerm `logos-renderer-base`:

```bash
gh pr create \
  -R PsychQuant/SwiftTerm \
  --base logos-renderer-base \
  --head logos-renderer-frame-loop \
  --title "C.2.1: DamageBuffer pass-through" \
  --body "Routes all cell-dirty notifications through new DamageBuffer class. Pure pass-through (no behavior change). Sets up C.2.2 timer-driven flushing."
```

Do NOT merge yet — leave open until C.2.2 done.

---

## Phase C.2.2 Detailed Plan

### Task 2.1: CVDisplayLink driving flush

**Files:** `swiftterm-fork/Sources/SwiftTerm/Mac/MacTerminalView.swift` + DamageBuffer.swift

- [ ] **Step 1: Add CVDisplayLink to MacTerminalView**

```swift
private var displayLink: CVDisplayLink?

private func startDisplayLink() {
    CVDisplayLinkCreateWithActiveCGDisplays(&displayLink)
    guard let link = displayLink else { return }
    CVDisplayLinkSetOutputCallback(link, { (_, _, _, _, _, userInfo) -> CVReturn in
        let view = Unmanaged<MacTerminalView>.fromOpaque(userInfo!).takeUnretainedValue()
        DispatchQueue.main.async {
            view.damageBuffer.flush()
        }
        return kCVReturnSuccess
    }, Unmanaged.passUnretained(self).toOpaque())
    CVDisplayLinkStart(link)
}

private func stopDisplayLink() {
    if let link = displayLink {
        CVDisplayLinkStop(link)
    }
    displayLink = nil
}
```

Wire to view lifecycle: `viewDidMoveToWindow` starts, `viewDidMoveToWindow(nil)` or `removeFromSuperview` stops.

- [ ] **Step 2: Modify DamageBuffer to coalesce**

```swift
@MainActor
final class DamageBuffer {
    private let commit: (NSRect) -> Void
    private var accumulated: NSRect = .zero
    private var hasPending = false

    init(commit: @escaping (NSRect) -> Void) { self.commit = commit }

    func markDirty(_ rect: NSRect) {
        if hasPending {
            accumulated = accumulated.union(rect)
        } else {
            accumulated = rect
            hasPending = true
        }
    }

    func flush() {
        guard hasPending else { return }
        commit(accumulated)
        accumulated = .zero
        hasPending = false
    }
}
```

- [ ] **Step 3: Replay metric — should now show improvement**

```bash
cd /Users/che/Developer/logos/Tools/SwiftTermReplay
swift run swiftterm-replay replay --input Captures/02-edit-tool.ttyrec --sample-frames 8
```

Expected: mid-state cluster count DROPS vs C.2.1 baseline. Document:
```
Total samples: 850
Mid-state clusters (> 16ms): 4   ← was 12 in upstream
Longest cluster: 28ms             ← was 84ms
```

If numbers don't drop: CVDisplayLink isn't actually delaying commits — maybe SwiftUI/AppKit is short-circuiting via runloop priority. Investigate.

- [ ] **Step 4: Side-by-side comparison screenshot**

Replay capture with sampling, save screencap of "worst" mid-state frame from both runs (upstream + C.2.2). Put in `docs/renderer-baselines/02-edit-tool-c22-comparison.png`.

- [ ] **Step 5: Commit + push**

```bash
cd /Users/che/Developer/swiftterm-fork
git add -A
git commit -m "feat(renderer): C.2.2 — CVDisplayLink-driven flush + rect coalescing

CVDisplayLink running at display refresh rate (typically 60Hz) calls
damageBuffer.flush() on main thread. DamageBuffer.markDirty now
accumulates rects via union(); flush commits the union as a single
setNeedsDisplay call.

First behavior change — replay metric on 02-edit-tool.ttyrec shows
mid-state cluster count drops from <baseline> to <new>. See
docs/renderer-baselines/02-edit-tool-c22-comparison.png."
git push
```

Update existing PR with description noting C.2.2 lands on same branch.

---

## Phase C.2.3+ — STOP HERE, RE-PLAN

After C.2.2 ships, the team should:

1. **Re-run the metric** on ALL captures (01-simple-streaming, 02-edit-tool, 03-plan-mode if collected, 05-permission if collected)
2. **Document remaining gaps** — what's still visibly flickery? E.g., "streaming token output is now smooth, but plan-mode checklist expand still tears"
3. **Decide if C.2.3 (atomic frame swap with back-buffer) is needed** — sometimes coalescing alone is sufficient; the back-buffer work is large.
4. **Write the C.2.3 plan based on actual C.2.2 lessons**, similar to how C.2 was written based on C.1's retrospective

Do not bypass this gate by writing the C.2.3 plan now — too speculative.

---

## Self-review

1. **Spec coverage**: C.2.0 baseline + C.2.1 pass-through + C.2.2 timer-driven flush. C.2.3+ explicitly deferred. ✅
2. **Placeholders**: `FrameSampler.pixelChangeRatio` is a `// PLACEHOLDER — fill in during execution`. **This is acknowledged in the task** as algorithmic work — not a quiet TBD. ✅ The expectation: implementer chooses simplest viable algorithm and refines.
3. **Type consistency**: `DamageBuffer`, `FrameSampler`, `CVDisplayLink` consistent across phases. ✅
4. **Known risks** (these are SERIOUS and worth surfacing):
   - **CVDisplayLink may not give us what we want**: SwiftUI/AppKit's own coalescing runs on the runloop. The display link only matters if our flushes happen to land between AppKit's natural draw passes. If AppKit is already coalescing aggressively, our DamageBuffer adds no value. Risk: C.2.2's "improvement" is zero. **This is why C.2.0's baseline metric exists — we'll know immediately if we're not improving.**
   - **`setNeedsDisplay` doesn't synchronously draw**: macOS still chooses when to draw. We can call `setNeedsDisplay(_:)` 100 times in one millisecond; macOS draws once at next refresh. So our "improvement" might already be happening at the OS level, just not surfaced as a metric. Need to dig into Core Animation behavior here.
   - **The actual fix might require bypassing `drawRect`**: Worst case, the real solution is replacing SwiftTerm's draw pipeline with a custom `CALayer` per cell (or per line) where layer.contents are pre-rendered glyphs. This is C.2.3 / C.3 territory and a much larger change than C.2.2.
   - **macOS Tahoe (26) changed render pipeline?**: Unknown if our forked work breaks on next macOS major. Test on whatever the user is on (macOS 15+).
   - **Forked-SwiftTerm maintenance burden**: Each upstream change to MacTerminalView needs to be cherry-picked or rebased. Document the cherry-pick workflow when first upstream update arrives.

---

## After C.2 done (probably 2026-08 or later):

- Sub-plan C.3 (atomic frame swap with back-buffer) — write after C.2.2 lessons land
- Sub-plan C.4 (smart redraw coalescing — detect "Claude is mid-redraw" patterns)
- These get progressively harder. Plan each only after the previous ships.
