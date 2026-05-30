## ADDED Requirements

### Requirement: Terminal enables the Metal renderer when available

When the terminal view is attached to a window on Metal-capable hardware, Logos SHALL enable the SwiftTerm fork's Metal renderer (via its public enable API with the per-row persistent buffering mode) so that terminal output is presented through the GPU vsync draw loop instead of the default CoreGraphics draw-immediately path. Enabling SHALL occur only after window attachment, because the renderer requires a window.

#### Scenario: Metal engaged after window attachment on capable hardware

- **WHEN** the terminal view becomes attached to a window on Metal-capable hardware
- **THEN** the terminal renderer reports that it is using the Metal renderer
- **AND** subsequent terminal output is drawn through the Metal path

#### Scenario: Metal is not enabled before window attachment

- **WHEN** the terminal view exists but is not yet attached to a window
- **THEN** the Metal renderer is not enabled yet
- **AND** no crash or blank occurs from a premature enable attempt

### Requirement: Terminal falls back to CoreGraphics when Metal is unavailable

When the Metal renderer cannot be used on the current hardware, Logos SHALL leave the terminal on the default CoreGraphics rendering path it uses today. Enabling Metal SHALL NOT crash, blank, or otherwise regress the terminal on unsupported hardware; the unavailability SHALL be handled internally (logged) rather than surfaced as a user-facing error.

#### Scenario: Unsupported hardware keeps today's CoreGraphics behavior

- **WHEN** the terminal view is on hardware where the Metal renderer cannot be used
- **THEN** the terminal renders via the CoreGraphics path
- **AND** the terminal does not crash or present a blank view as a result of the enable attempt

### Requirement: Metal adoption preserves byte intake and terminal interactions

Enabling the Metal renderer SHALL NOT change the PTY byte-intake contract or terminal interaction behavior. The auto-handle stream tee SHALL continue to observe the same byte stream and intercept the same prompts, and caret, text selection, view resize, and `SIGWINCH` propagation SHALL behave the same as on the CoreGraphics path.

#### Scenario: Auto-handle still fires on the Metal path

- **WHEN** Metal is active and a prompt the auto-handle engine recognizes (such as a permission prompt) is emitted by `claude`
- **THEN** the auto-handle engine intercepts and responds to it exactly as it does on the CoreGraphics path

#### Scenario: Resize still propagates on the Metal path

- **WHEN** Metal is active and the terminal view is resized
- **THEN** the terminal grid reflows and a `SIGWINCH` is delivered to the child process, the same as on the CoreGraphics path

### Requirement: A clear-then-reprint sequence presents without an intermediate blank frame

With the Metal renderer active, when a screen-clear and its following reprint arrive within one display-refresh window, the terminal SHALL present a single coalesced frame containing the reprinted content rather than presenting the intermediate cleared (blank) state. This is the behavior that removes the transient blank frame the CoreGraphics path exhibits during a Claude redraw.

#### Scenario: Clear and reprint within one frame window coalesce

- **WHEN** Metal is active and a clear chunk and its reprint chunk are processed within the same display-refresh (~16.67 ms) window
- **THEN** the renderer presents one frame showing the reprinted content
- **AND** the intermediate cleared state is not presented as its own frame

##### Example: CoreGraphics baseline vs Metal target

| Path | Transient blank frames per Edit-tool redraw cycle | Perceptible (>16 ms) blank clusters |
| ---- | -------------------------------------------------- | ----------------------------------- |
| CoreGraphics (today) | many (measured ~66-71 over 12 cycles) | ~13 |
| Metal (target) | none perceptible | 0 |
