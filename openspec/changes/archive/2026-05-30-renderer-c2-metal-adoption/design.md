## Context

Logos hosts the `claude` CLI in a SwiftTerm-based terminal. The terminal view (in Sources/Logos/Terminal/SwiftTermView.swift) wraps a tee'd LocalProcessTerminalView (Sources/Logos/Terminal/StreamTee.swift) that taps the PTY byte stream for the auto-handle engine and forwards to the renderer. The SwiftTerm dependency is the pinned PsychQuant fork (v1.13.0, branch logos-renderer-base).

The fork already ships a complete Metal renderer (MetalTerminalRenderer): a vsync MTKView draw loop, a color+grayscale glyph texture atlas, per-row persistent damage tracking, frame-semaphore double-buffering, and a ~16.67 ms (60 fps) damage-coalescing debounce that collapses multiple invalidations within one frame window into a single present. It is reached via the public `setUseMetal(true)` API plus a per-row persistent buffering mode. Logos never calls it, so it runs SwiftTerm's default CoreGraphics path, where a Claude clear+reprint lands as two separate invalidations/draws and the cleared (blank) state can be presented before the reprint = tearing.

The C.2 de-risk (committed groundwork: docs/renderer-baselines/cg-vs-metal-edit-tool.md, the SwiftTermReplay harness, the synthetic corpus) quantified the CoreGraphics problem at ~22 mid-state clusters / ~13 perceptible (>16 ms) per 12 clear/reprint cycles, and established that the harness cannot produce a trustworthy Metal number (sampling forces a synchronous draw that defeats the renderer's own coalescing). The prior from-scratch C.2 frame-loop plan (docs/superpowers/plans/2026-05-26-renderer-rewrite-c2-frame-loop.md) predates the discovery that the fork already provides this infrastructure and is therefore superseded.

## Goals / Non-Goals

**Goals:**

- Eliminate perceptible terminal render tearing on real Claude Edit-tool/plan/permission redraws by routing Logos through the fork's existing Metal renderer.
- Keep the auto-handle stream-tee and all terminal interactions (caret, selection, resize, SIGWINCH) working unchanged on the Metal path.
- Never regress below the current CoreGraphics behavior: fall back to CoreGraphics when Metal is unavailable.
- Reconcile the design doc's renderer section and open questions with the adopt-not-build reality.

**Non-Goals:**

- Building a from-scratch renderer / damage buffer / display-link loop (the superseded plan).
- Modifying the SwiftTerm fork's renderer internals (adoption is public-API only).
- A harness-measured Metal-vs-CoreGraphics number (the harness Metal sampling is unverified WIP; validation is interactive).
- The conditional mid-redraw coalescing heuristic (only if interactive validation shows the built-in coalescing is insufficient; tracked as a follow-up).

## Decisions

### D1: Adopt the fork's Metal renderer rather than hand-roll

Enable the fork's shipped Metal renderer via `setUseMetal(true)` + per-row persistent buffering. Rationale: the fork already provides vsync presentation, per-row damage tracking, double-buffering, and 16.67 ms coalescing — the exact frame-atomic-commit architecture the superseded plan set out to build. Hand-rolling reinvents it at weeks-to-months cost. Rejected alternatives: build-on-CoreGraphics (the 2026-05-26 plan) and a separate display-link renderer.

### D2: Supersede the 2026-05-26 from-scratch C.2 plan

The plan is marked superseded (not deleted — kept as historical context) and the design doc's renderer section is updated to record that C.2 is delivered by adoption. This prevents a future implementer from executing the stale plan and reinventing the fork's renderer.

### D3: Interactive validation is the acceptance gate, not a harness number

Because the replay harness cannot sample the Metal path without forcing a draw that defeats coalescing, the "did tearing go away" gate is a human observation on the running app against a real Edit-tool redraw, using the recorded CoreGraphics baseline (~22 clusters) as the documented "before". The harness remains useful only for the CoreGraphics baseline.

Real Metal engagement also cannot be asserted in a unit test: instantiating a SwiftTerm `TerminalView` (or attaching it to a window) in a `swift test` process segfaults — no full NSApplication / windowserver drawable context (confirmed by SIGSEGV during implementation). So the enable / skip / once / fallback DECISION is extracted into a pure `MetalAdoptionPolicy` that is unit-tested directly, while real engagement (`isUsingMetalRenderer == true`) is confirmed in the same interactive pass on the running app.

### D4: CoreGraphics fallback preserves "never worse than today"

Metal is enabled only when the renderer can actually use it on the current hardware; otherwise the terminal stays on the CoreGraphics path it uses today. Enabling Metal must never crash or blank the terminal on unsupported GPUs. This resolves the Intel-Mac / older-GPU concern: unsupported hardware silently keeps today's behavior.

### D5: Treat adopting the fork's Metal renderer as delivering the moat (resolves design doc 10.3)

The design doc's "no vanilla SwiftTerm interim ship" rule is satisfied: vanilla SwiftTerm means the upstream CoreGraphics path that tears; the fork's GPU renderer is the differentiated zero-tearing path and counts as the moat being delivered, not as an interim vanilla ship. The maintainer may override this product call, but absent an override the design proceeds on this basis. The design doc timeline (10.1) and renderer-expertise (10.2) notes are updated to reflect that the adoption phase is far smaller than the original from-scratch estimate.

### D6: Restore key focus on enable + an escape hatch (found during interactive validation)

Interactive validation (task 3.1) surfaced a regression: enabling Metal from `viewDidMoveToWindow` inserts the MTKView overlay and hides the native caret (the Metal renderer draws its own, gated on the terminal being first responder) before AppKit/SwiftUI settle key focus — so the terminal ended up not first responder, the Metal caret never rendered, and arrow-key navigation had no target. Fix: restore key focus to the terminal (`window?.makeFirstResponder(self)`) immediately after a successful enable. Additionally, because Metal is a new default that could misbehave on some hardware, a `LOGOS_DISABLE_METAL` environment escape hatch forces the proven CoreGraphics path so a user can never be locked out of a working terminal (audit discipline: a risky default needs a safe opt-out).

## Implementation Contract

**Behavior (observable):**
- With Metal active, a real Claude Edit-tool redraw (clear followed by reprint) no longer shows a perceptible transient blank frame; the terminal updates atomically per frame.
- The auto-handle engine still intercepts the same prompts (rate-limit, trust, permission) — byte intake is unchanged.
- On hardware where Metal cannot be used, the terminal renders exactly as it does today (CoreGraphics), with no crash and no blank.

**Interface / data shape:**
- The terminal view (`TeedLocalProcessTerminalView`, in Sources/Logos/Terminal/StreamTee.swift) enables the Metal renderer from `viewDidMoveToWindow`, selecting the per-row persistent buffering mode. The enable/skip/once/fallback branching lives in a pure `MetalAdoptionPolicy` (Sources/Logos/Terminal/MetalAdoptionPolicy.swift); the view supplies window state and the enable action. (This is where the work landed rather than SwiftTermView.swift — `viewDidMoveToWindow` is an NSView override, so the view subclass is the correct home.)
- Usability is determined by the fork's `setUseMetal(true)` throwing when no Metal device exists; on throw the view is left on the default CoreGraphics path.
- No change to the StreamTee byte-tap contract (`dataReceived(slice:)` → `onChunk`) or the auto-handle interface.

**Failure modes:**
- Metal unsupported/unavailable → CoreGraphics fallback (today's behavior), surfaced only as an internal log, not a user error.
- Metal enable attempted before window attachment → must be deferred until attached (the renderer requires a window); never a hard failure.

**Acceptance criteria:**
- `MetalAdoptionPolicy` unit tests (Tests/LogosTests/SwiftTermViewMetalTests.swift) confirm: the enable is attempted when window-attached, skipped before window attachment, attempted at most once across repeated window moves, and falls back (returns false, does not rethrow) when the enable throws.
- Real Metal engagement (`isUsingMetalRenderer == true`), the byte tap on the live Metal path, and caret/selection/resize/SIGWINCH are confirmed by manual interactive validation on the running app (the TerminalView cannot be instantiated in `swift test`), recorded in docs/renderer-baselines/, with a real Claude Edit-tool redraw showing no perceptible blank frame against the recorded ~22-cluster CoreGraphics baseline.
- The byte-intake path (`dataReceived(slice:)` → `onChunk`) is unchanged by this change (diff review), so auto-handle is structurally preserved.
- Full `swift test` stays green.

**Scope boundaries:**
- In scope: enabling Metal from the terminal view with a CoreGraphics fallback (via `MetalAdoptionPolicy`); the policy unit tests; auto-handle + interaction interactive confirmation; design-doc reconciliation; plan supersession; CHANGELOG.
- Out of scope: SwiftTerm fork renderer internals; the harness Metal measurement; the mid-redraw coalescing heuristic; any new terminal UI.

## Risks / Trade-offs

- [The 16.67 ms coalescing may not fully eliminate tearing on every real flow] -> interactive validation is the gate; if residual tearing remains, the mid-redraw coalescing heuristic becomes a scoped follow-up (explicitly out of scope here).
- [Metal path may differ subtly from CoreGraphics in caret/selection/resize rendering] -> covered by the interaction regression check before shipping; CoreGraphics fallback remains the safety net.
- [Older/Intel GPUs] -> the capability check + CoreGraphics fallback guarantees no regression on unsupported hardware (D4).
- [Fork-version coupling] -> the Metal API (setUseMetal, buffering mode) is the fork's public surface; pin remains v1.13.0; re-verify on fork bumps.
- [Product call on 10.3] -> D5 takes a documented position (adoption delivers the moat); the maintainer can override, which would re-open the from-scratch question.
