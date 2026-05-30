# C.2 Metal adoption — interactive validation (task 3.1)

Date: 2026-05-30
Change: `renderer-c2-metal-adoption`
Build: `make run` (release), Apple Silicon, macOS Aqua session.

This is the acceptance gate for the C.2 moat (design decision D3): the harness
cannot produce a trustworthy Metal number (sampling forces a draw that defeats
the renderer's coalescing), so tearing removal is judged by human observation on
the running app against the recorded CoreGraphics baseline.

## Result: PASS

| Check | Observed |
| ----- | -------- |
| Metal engaged | YES — the Metal-drawn caret renders (caret is drawn by `MetalTerminalRenderer`, not AppKit, so its presence confirms the GPU vsync path is live). `Logos: terminal Metal renderer engaged` logged. |
| Edit-tool redraw tearing | NONE — a real Claude clear→reprint redraw is smooth, with no perceptible transient blank frame, vs the CoreGraphics baseline of ~22 mid-state clusters / ~13 perceptible (>16 ms) per 12 cycles. |
| Keyboard navigation | WORKS — arrow up/down navigation works in a live `claude` session. |
| Caret | WORKS — the cursor is visible and tracks. |

## Regression found and fixed during validation

The first interactive run revealed a regression: with Metal on, terminal keyboard
up/down navigation did not work and the caret did not show. Root cause: enabling
Metal from `viewDidMoveToWindow` inserts the MTKView overlay and hides the native
caret (the Metal renderer draws its own, gated on `terminalView.isFirstResponder`)
*before* AppKit/SwiftUI settle key focus on the terminal, so the terminal ended up
not first responder — no Metal caret, and arrow keys had no target.

Fix: after a successful Metal enable, restore key focus to the terminal
(`window?.makeFirstResponder(self)` in `TeedLocalProcessTerminalView`). Re-validated:
caret renders, up/down works, redraw flicker-free.

## Escape hatch

`LOGOS_DISABLE_METAL` (any value) forces the proven CoreGraphics path, so a future
Metal regression on some hardware/session can never lock a user out of a working
terminal. `open` does not pass shell env to the app; launch the binary directly to
use it: `LOGOS_DISABLE_METAL=1 .build/Logos.app/Contents/MacOS/Logos`.
