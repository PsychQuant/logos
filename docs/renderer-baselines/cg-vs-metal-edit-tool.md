# C.2 Renderer De-Risk: CoreGraphics vs Metal mid-state frame measurement

Date: 2026-05-30
Harness: `Tools/SwiftTermReplay` (`swiftterm-replay replay`) + `FrameSampler` @ 8 ms sampling
SwiftTerm: `PsychQuant/SwiftTerm` @ branch `logos-renderer-base` (pinned fork that already
ships `MetalTerminalRenderer`)
Corpus: `Tools/SwiftTermReplay/Sources/SwiftTermReplay/Captures/03-edit-tool-synthetic.ttyrec`

This is a **measurement-only** exercise. Nothing under `Sources/Logos/` was changed and the
shipped app still runs the default CoreGraphics path. Metal is enabled **only** inside the
replay tool, via `swiftterm-replay replay --metal`.

## TL;DR

| Renderer | Mid-state blank frames | Mid-state clusters | Clusters > 16 ms | Max inter-frame change | Valid? |
|----------|------------------------|--------------------|------------------|------------------------|--------|
| CoreGraphics (default) | ~66-71 | 22 | 13-14 | 0.372 | YES |
| Metal (`perRowPersistent`) | — | — | — | — | **NO — see Status update** |

The CoreGraphics number is real and reproducible. There is **no valid Metal number** — see
the Status update below for why, and the decision to validate Metal interactively rather than
extend the harness further.

## Status update (2026-05-30): harness Metal measurement abandoned, Metal validated interactively

This de-risk had two rounds. Round 1 established the CoreGraphics baseline (below) and found
that `FrameSampler`'s `NSView.cacheDisplay` cannot read back the Metal renderer's GPU drawable
(the "blindspot" section below). Round 2 then **implemented** a GPU texture readback in
`FrameSampler` (`enableMetalCapture()` flips the MTKView's `framebufferOnly = false`; `sampleMetal()`
reads `currentDrawable.texture` via `getBytes`) — so the code below the blindspot section is now
partly superseded: the harness *can* read Metal pixels.

BUT round 2 surfaced a deeper methodology problem that makes the harness the wrong tool here:
the shipped Metal renderer coalesces damage on a **~16.67 ms (60 fps) debounce**
(`queueMetalDisplay` schedules one `setNeedsDisplay`, `pendingMetalDisplay` blocks stacking).
To sample it, `sampleMetal()` drives a **synchronous** `mtk.draw()` — which *bypasses that
debounce* and forces a present per 8 ms sample, defeating the very coalescing that determines
whether Metal avoids the transient blank frame. Sampling it this way would measure an artifact,
not the renderer's real presentation behavior.

**Decision (this commit):** stop extending the harness for the Metal number. The harness
(`--metal` flag, texture readback in `FrameSampler.sampleMetal`) is left in place as WIP/unverified
groundwork — it builds, but its Metal numbers are NOT trustworthy and must not be quoted. The
adopt-Metal-vs-hand-roll question is settled by (a) the CoreGraphics baseline below quantifying
the problem and (b) the architectural finding that the existing Metal renderer already coalesces
clear+reprint within a frame — and is **confirmed interactively** on the real app (turn on Metal,
watch a real Edit-tool redraw), tracked in the `renderer-c2-metal-adoption` Spectra change.

## What "mid-state blank frame" means

The CoreGraphics path draws immediately on each terminal invalidation. The Edit-tool repaint
arrives as separate PTY chunks: an ANSI clear (`ESC[H` + `ESC[2J`) lands and is presented as
one frame, and the reprint of the changed content lands and is presented as a *separate*
frame. Between the two, the screen is transiently blank. A **mid-state blank frame** is a
sampled frame whose foreground coverage has dropped toward the background (cleared) while
both an earlier and a later frame are filled — the transient blank "valley" that the eye
perceives as tearing/flicker.

`FrameSampler.analyze()` reports:

- **Mid-state blank frames** — count of individual sampled frames sitting in a blank valley.
- **Mid-state clusters** — runs of consecutive frames whose inter-frame pixel diff exceeds the
  change threshold (0.2). Each clear-then-reprint cycle produces clusters at its boundaries.
- **Clusters > 16 ms** — clusters lasting longer than one 60 Hz refresh (visually perceptible).
- **Max inter-frame change ratio** — largest single-step pixel change over a fixed 32x24 grid.

## The corpus is synthetic — why and why it is representative

`02-edit-tool.ttyrec` (the only prior capture) is 4 PTY chunks of claude *shutdown* noise
(mode resets, `ESC]0;` title) with no screen draw, so it produces 0 of everything — an invalid
baseline (see `02-edit-tool-upstream.txt`).

`03-edit-tool-synthetic.ttyrec` is a **hand-authored** ttyrec that emits the canonical
clear+reprint ANSI pattern in *separate chunks with a deliberate ~50 ms inter-chunk gap*:

1. Initial paint: full-screen solid background block (`ESC[42m` + spaces).
2. Repeat 12x:
   - chunk A: `ESC[H` `ESC[2J` (region cleared -> blank).
   - ~50 ms gap (wide enough for the 8 ms sampler to land inside the blank window).
   - chunk B: reprint of a full-screen solid block in a *different* background colour.

It is synthetic because it is the most controllable way to reproduce the exact tearing
trigger on demand: a real claude Edit-tool session interleaves the same clear/reprint ANSI but
buries it among diffs, prompts, and spinner repaints that are hard to reproduce
deterministically. Solid background blocks (rather than sparse glyphs) give an unambiguous
high-contrast coverage signal: a filled frame is ~37% grid coverage, a cleared frame is ~0%.
The pattern (separate-chunk `ESC[2J` then separate-chunk reprint) is exactly what the C.2
grounding identified as the CoreGraphics tearing source.

## Metal sampling blindspot (the central de-risk finding)

`FrameSampler` captures frames via `NSView.cacheDisplay(in:to:)` on the parent `TerminalView`.

- **CoreGraphics path**: `TerminalView` draws directly into its own layer. `cacheDisplay`
  reads it back correctly — the dumped PNGs show real terminal content, and the coverage trace
  oscillates 0.37 (filled) -> 0.00 (blank for ~6 frames ≈ 48 ms) -> 0.37, exactly the tearing
  pattern.
- **Metal path**: `setUseMetal(true)` creates a child `MTKView` subview
  (`framebufferOnly = true`, `isPaused = true`, `enableSetNeedsDisplay = true`) that renders on
  the GPU. `isUsingMetalRenderer` returns `true` and content is visibly drawn, but
  `cacheDisplay` on the parent `NSView` **cannot** read back the MTKView's GPU drawable. Every
  sampled Metal frame comes back fully black: coverage 0.00 across all 151 frames, max change
  ratio 0.000. Dumped Metal PNGs are blank.

So the harness, as written, can measure the CoreGraphics path headless-but-in-an-Aqua-session,
but **cannot** measure the Metal path. This is the most important finding for C.2: the existing
metric infrastructure must be extended before any Metal-vs-CG comparison is meaningful.

## Exact commands used

Run from `Tools/SwiftTermReplay/`:

```bash
swift build

# CoreGraphics (default) — produces the valid baseline number
swift run swiftterm-replay replay \
  --input Sources/SwiftTermReplay/Captures/03-edit-tool-synthetic.ttyrec \
  --speed 1.0 --sample-frames 8

# Metal — runs, but mid-state numbers are NOT valid (sampling blindspot)
swift run swiftterm-replay replay \
  --input Sources/SwiftTermReplay/Captures/03-edit-tool-synthetic.ttyrec \
  --speed 1.0 --sample-frames 8 --metal

# Optional: dump sampled frames to PNGs to verify the capture path saw real pixels
swift run swiftterm-replay replay \
  --input Sources/SwiftTermReplay/Captures/03-edit-tool-synthetic.ttyrec \
  --speed 1.0 --sample-frames 8 --dump-frames /tmp/cg-frames

# Optional: per-frame foreground-coverage trace to stderr
FRAMESAMPLER_TRACE=1 swift run swiftterm-replay replay \
  --input Sources/SwiftTermReplay/Captures/03-edit-tool-synthetic.ttyrec \
  --speed 1.0 --sample-frames 8
```

Notes:
- `--speed 1.0` keeps the real ~50 ms inter-chunk gaps so the 8 ms sampler can land inside the
  blank window. `--speed 0` (instant) collapses the gaps and is NOT suitable for this metric.
- Requires a GUI (Aqua) login session. It ran fine over an interactive session
  (`launchctl managername` == `Aqua`); it will NOT work over a plain SSH/headless session with
  no window server.

## Measurement (CoreGraphics, 3 runs)

```
run1: total=178  mid-state-blank=71  clusters=22  >16ms=13  max-change=0.372  longest=31ms
run2: total=177  mid-state-blank=71  clusters=22  >16ms=14  max-change=0.372  longest=28ms
run3: total=173  mid-state-blank=66  clusters=22  >16ms=13  max-change=0.372  longest=42ms
```

Structural counts (clusters, >16 ms, max-change) are stable; raw blank-frame count varies
±a few frames with sampler-timing jitter. **Baseline: ~22 mid-state clusters, ~13 perceptible
(>16 ms), ~66-71 transient blank frames per 12 clear/reprint cycles on the CoreGraphics path.**

## Measurement (Metal) — blocked, with the runnable command for the human

The Metal path could not be measured because of the GPU-drawable read-back blindspot above.
To obtain a real Metal number, the `FrameSampler` must capture the GPU drawable directly
rather than via `cacheDisplay`. The two viable approaches:

1. Read back the MTKView drawable: set the renderer's MTKView `framebufferOnly = false` and, on
   each sample, copy `metalView.currentDrawable?.texture` to a CPU buffer via
   `texture.getBytes(...)` (or a blit to a shared/managed texture). Requires either a small
   patch in the harness that holds a reference to the MTKView subview, or a SwiftTerm API to
   expose the current frame as a `CGImage`.
2. Window capture: sample with `CGWindowListCreateImage` / `SCScreenshotManager` against the
   replay window instead of `cacheDisplay`. Captures whatever is on screen (CG or Metal)
   uniformly, at the cost of a Screen Recording TCC grant.

Until one of those lands, run the CoreGraphics baseline (above) for the regression number, and
treat the Metal comparison as TODO.

## Files

- Corpus: `Tools/SwiftTermReplay/Sources/SwiftTermReplay/Captures/03-edit-tool-synthetic.ttyrec`
- Metric: `Tools/SwiftTermReplay/Sources/SwiftTermReplay/FrameSampler.swift`
- CLI `--metal` flag: `Tools/SwiftTermReplay/Sources/SwiftTermReplay/Replayer.swift`
