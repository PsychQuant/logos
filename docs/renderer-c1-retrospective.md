# Phase C.1 Retrospective

> **Status**: Partial — captured during interrupted background agent run. Update this doc as more captures are collected and SwiftTerm internals are explored further during C.2.

## What we learned about SwiftTerm 1.13

- **Base class hierarchy**: `TerminalView` (`Sources/SwiftTerm/Mac/MacTerminalView.swift`) → `LocalProcessTerminalView` (`Sources/SwiftTerm/Mac/MacLocalTerminalView.swift`). Both are `NSView` subclasses; both `@MainActor`-isolated in Swift 6.
- **Byte entry point**: `feed(byteArray: ArraySlice<UInt8>)` on `TerminalView`. This is the override point used by sub-plan D's `TeedLocalProcessTerminalView` to intercept the stream.
- **PTY lifecycle**: `LocalProcessTerminalView.startProcess(executable:args:environment:execName:currentDirectory:)`. Returns synchronously; subprocess + PTY managed internally.
- **Color/font properties**: `nativeBackgroundColor`, `nativeForegroundColor` (NSColor), `font` (NSFont). Setting these propagates to internal `terminal.foregroundColor` / `terminal.backgroundColor` via `getTerminalColor()`.
- **Caret drawing**: `MacCaretView.swift` — uses `terminal.getAttributedValue(...)` for character composition.

## Tearing source — observations from baseline captures so far

The two captures recorded (`01-simple-streaming.ttyrec`, `02-edit-tool.ttyrec`) when replayed at `--speed 0.1` should reveal mid-state frames where Claude Code issues a region-clear escape sequence followed by reprint. **This validation pass is pending** — the background agent rate-limited before completing visual review.

Hypothesized tearing pattern (to verify in C.2 exploration):

```
1. Claude prints "⏺ Edit(file.swift)"
2. Claude issues ESC[2J (clear screen) OR ESC[<n>;<m>H (cursor move) + ESC[K (erase line)
3. Brief moment with cleared region visible to user → perceived as flicker
4. Claude reprints region with new content
```

`02-edit-tool.ttyrec` should contain this exact sequence. Frame-by-frame `xxd` inspection during C.2 will confirm.

## ttyrec format gotchas

- ttyrec header is **3 × little-endian Int32** (sec, usec, len). Confirmed by visual `xxd` against captured files.
- macOS `Process` does not provide raw PTY handle; `Recorder.swift` uses `openpty()` + `fork()` + `execvp()` from `Darwin` module directly. Works but is C-level interop.
- Replay timing: feeding chunks at recorded inter-chunk delays produces close-to-real-time playback. `--speed 0` (instant) for diffing; `--speed 1.0` for visual review.

## C.2 (frame-rate renderer) starting points

1. **Hook location**: SwiftTerm's `MacTerminalView.drawRect(_:)` is where actual NSView painting happens. The renderer rewrite should intercept here OR install a custom `CALayer` strategy and bypass `drawRect` entirely.
2. **Buffering decision**: Choose between (a) batching escape codes upstream of `feed(byteArray:)` (cleaner separation but loses some SwiftTerm parsing) or (b) batching at the cell-grid level after parsing (more invasive but reuses SwiftTerm's parser). Initial preference: **(b)** — reuse parser, customize commit timing.
3. **Frame timing primitive**: `CVDisplayLink` (60Hz vsync-synced) or `DispatchSourceTimer` (manual). Prefer `CVDisplayLink` for atomic frame swap with display refresh.
4. **First measurable target**: Replay `02-edit-tool.ttyrec` at `--speed 1.0` and assert "no mid-state frame longer than 16ms visible". Set this as the C.2 acceptance test.
5. **Risk**: SwiftTerm's existing draw path is line-based. Switching to `CALayer`-per-cell might be too coarse; per-line might be too fine. Need to prototype + measure in C.2's first task.

## Missing captures (organic collection)

Background agent recorded 2 of 5 captures before rate-limiting. Remaining work:
- `03-plan-mode.ttyrec` — record next time using `claude` plan mode
- `04-rate-limit.ttyrec` — best effort, may be impossible to reproduce on demand
- `05-permission.ttyrec` — record without `--dangerously-skip-permissions` flag
- `docs/renderer-baselines/*.png` — visual baselines (replay each capture, screenshot the SwiftTermReplay window)

Treat these as organic backlog; don't gate C.2 on completing the corpus.

## Lessons for the next phase

- **Pre-create the fork before agent starts**. Sub-plan C.1 Task 1 originally required manual GitHub action; pre-flight setup eliminated that block — agents could go straight to programmatic work.
- **Branch isolation prevents conflicts**. C.1 on `renderer-c1` branch, D on `main` — no overlap on Package.swift kept them parallel-safe.
- **Background agent + rate-limit = work loss**. Background subagents executing for 14+ minutes hit Anthropic's per-org rate limit. **For C.2 and beyond, prefer inline execution with explicit batching, OR run agents sequentially with cooldown between them.**
- **D's `--dangerously-skip-permissions` removal** is the same product line as C.1's renderer work — both serve the "Claude Code never blocks unexpectedly" promise.
