## Summary

Eliminate terminal render tearing by adopting the Metal renderer that the pinned SwiftTerm fork already ships (Logos currently never turns it on), superseding the stale from-scratch C.2 frame-loop plan.

## Motivation

Claude Code repaints regions as a separate ANSI clear (`ESC[H` / `ESC[2J` / `ESC[K`) chunk followed by a reprint chunk. On SwiftTerm's default CoreGraphics path each lands as its own invalidation and draw, so AppKit can present the cleared (blank) state before the reprint arrives — the transient blank frame the eye perceives as tearing/flicker. This is now quantified: the de-risk baseline measured ~22 mid-state clusters, ~13 perceptible (>16 ms), ~66-71 transient blank frames per 12 clear/reprint cycles on the CoreGraphics path (recorded in docs/renderer-baselines/cg-vs-metal-edit-tool.md).

The C.1 SwiftTerm fork (pinned v1.13.0) already ships a complete GPU renderer (a vsync MTKView draw loop, a glyph texture atlas, per-row persistent damage tracking, frame-semaphore double-buffering, and crucially a ~16.67 ms / 60 fps damage-coalescing debounce that collapses a clear+reprint landing in the same frame window into a single present). Logos simply never calls `setUseMetal(true)`, so it runs the CoreGraphics draw-immediately path. The moat feature is therefore mostly already built — just switched off.

Consequently the prior 2026-05-26 C.2 plan, which proposed building a hand-rolled damage buffer and display-link frame loop on the CoreGraphics path, is invalidated: it would reinvent infrastructure the fork already provides. This change supersedes that plan.

## Proposed Solution

Turn on the fork's existing Metal renderer in Logos and confirm it removes the tearing:

1. Enable Metal in the terminal host: call `setUseMetal(true)` on the `TerminalView` after the view is attached to a window (the renderer requires window attachment), with the per-row persistent buffering mode selected.
2. Verify the stream-tee byte intake (auto-handle) and the terminal's caret, selection, resize, and `SIGWINCH` behavior all continue to work on the Metal path (Metal presentation runs parallel to byte parsing, so intake should be unaffected — this must be confirmed, not assumed).
3. Validate the tearing fix INTERACTIVELY on the real app against a real Claude Edit-tool redraw. The replay-harness Metal number is methodologically blocked (sampling forces a synchronous draw that defeats the renderer's own coalescing), so the acceptance gate is a human observation on the running app plus the recorded CoreGraphics baseline as the "before" reference — not a harness number.
4. Provide a CoreGraphics fallback when the Metal renderer cannot be used (unsupported GPU / older hardware), so enabling Metal never makes the terminal worse than today.

## Non-Goals

- Building a from-scratch renderer, damage buffer, or display-link frame loop (the superseded 2026-05-26 plan). The fork's renderer is adopted via its public API, not reinvented.
- Editing the SwiftTerm fork's renderer internals. Adoption uses only the public `setUseMetal` / buffering-mode API; any renderer-internals change is a separate effort, justified only if interactive validation shows residual tearing.
- Producing a harness-measured Metal-vs-CoreGraphics number. The FrameSampler Metal readback is unverified WIP groundwork; the comparison is made interactively.
- Building the conditional "Claude is mid-redraw" coalescing heuristic. It is only warranted if interactive validation shows the renderer's built-in 16.67 ms coalescing is insufficient on real Edit-tool flows; that remains a tracked follow-up, not part of this change.

## Alternatives Considered

- Hand-roll a frame-loop renderer on the CoreGraphics path (the 2026-05-26 plan): rejected. It reinvents the fork's existing GPU damage-tracking and double-buffering, costing weeks-to-months of systems work for capability the fork already provides.
- Window capture (Screen Recording API) to obtain a harness Metal number: rejected. It requires a Screen Recording TCC grant and still only measures on-screen presentation timing, which interactive validation on the real app covers more directly.

## Impact

- Affected specs: new capability renderer-metal-adoption
- Affected code:
  - Modified:
    - Sources/Logos/Terminal/SwiftTermView.swift
    - docs/design/2026-05-25-logos-design.md
    - docs/superpowers/plans/2026-05-26-renderer-rewrite-c2-frame-loop.md
    - CHANGELOG.md
  - New:
    - Tests/LogosTests/SwiftTermViewMetalTests.swift
  - Removed:
    - (none)
