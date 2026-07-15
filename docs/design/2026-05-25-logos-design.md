# Logos — Design Document

| Field | Value |
|-------|-------|
| **Status** | First Draft |
| **Date** | 2026-05-25 |
| **Project type** | Native macOS app (Swift) |
| **Working name** | Logos (λόγος — word, reason, rational order) |
| **Audience** | Public product (Mac App Store + direct download) |
| **MVP timeline** | 4-6 months (with AI-assisted coding) |
| **Sister project** | `claude-code-logos` (plugin marketplace, shared brand) |
| **Predecessor** | `claude-code-watchdog` (bash supervisor pattern) |

> **This is a design draft — open questions in § 10 must be resolved before implementation. Do not start coding until the user reviews and the open questions are answered.**

---

## 1. One-line description

Native Mac app that hosts Claude Code with auto-recovery, multi-account, and zero render tearing.

## 2. Problem statement

Claude Code is powerful but **leaks pain at the seams**:

| Pain | Today's reality |
|------|------------------|
| Rate-limit blocks session | `API Error: Server is temporarily limiting requests` blocks until you manually type "keep going". If you stepped away → session is dead until you come back |
| Render tearing / flicker | Tool calls redraw terminal regions with ANSI escape codes; mid-redraw is visible as flicker. Inherent to all terminal emulators (Ghostty/Wave/iTerm/xterm.js all have it) |
| Trust prompts on first run | `Yes, I trust this folder` requires manual approval per folder |
| MCP permission prompts repeat | Each new MCP tool call asks permission, even after user said "always" |
| One terminal, one account | Switching accounts = `claude logout && claude login` — slow, fragile |
| Output not previewable inline | Claude writes a PDF or modifies a Swift file → you alt-tab to a viewer |
| VS Code terminal is shared real estate | xterm.js inside VS Code inherits all tearing + has no Claude-specific UI + can't be controlled externally |
| Cursor / Windsurf agent is their own AI | Doesn't host Claude Code — different product category |

**No existing tool solves all of these.** Each adjacent product fixes one or two:

| Tool | Fixes | Misses |
|------|-------|--------|
| Ghostty | Smooth native render | No Claude awareness, no auto-recovery |
| Wave Terminal | Block UI, durable SSH, AI sidebar | AI is Wave's own, not Claude Code; no auto-recovery |
| VS Code terminal | Editor integration | No auto-recovery, no Claude-specific UI, tearing |
| Cursor / Windsurf | Native AI integration | AI is theirs, not Claude Code |
| Claude Desktop | Native AI UI | Not Claude Code; chat product, not CLI host |
| claude-code-watchdog | Auto-recovery on rate-limit + trust prompts | tmux + bash, no UI |

## 3. Target audience

**Primary**: Claude Code power users on macOS who:
- Run Claude Code daily as part of work
- Are bothered by interruptions while stepped away
- Manage multiple Claude accounts (personal + work + Pro tier)
- Work with PDF / LaTeX / Markdown documents where live preview matters
- Already use VS Code/Cursor for code editing and want a dedicated Claude Code host (not a replacement IDE)

**Secondary**: Developers running Claude Code as a background agent (Telegram/Discord bots, automated workflows) who need reliable supervision — overlap with `claude-code-watchdog` users.

**Not target**: Casual Claude.ai chat users (different product); Linux/Windows users (initial release Mac only); teams needing collaborative Claude sessions (deferred).

## 4. Differentiation

The **headline promise**:

> "The Mac app where Claude Code never blocks on prompts you've pre-approved, and never flickers when it works."

Three pillars no competitor combines:

1. **Auto-recovery as first-class** — Built-in handling of rate-limit, trust, and MCP-permission prompts. Configurable rules. The watchdog pattern, but native.
2. **Zero render tearing** — Forked SwiftTerm with frame-rate renderer. The only Mac app where Claude Code's tool-call updates are visibly smooth.
3. **Designed for Claude Code, not for terminals** — Multi-account quick switch, PDF/file live preview synced to Claude's edits, status bar with cost/token/auto-handle state. None of these exist in general-purpose terminal emulators.

## 5. Product philosophy

| Principle | Implication |
|-----------|-------------|
| **Solve every pain point** | Each interruption / friction in Claude Code gets a first-class native solution, not a workaround. The *order* of addressing is staged across v1.0/v1.1/v1.2 (see § 9), but no pain gets a half-fix — when shipped, it's solved properly. |
| **Native macOS quality** | Mac App Store grade. SwiftUI + AppKit. Notarized. Standard Mac keybinds and behaviors. |
| **No tearing — the moat** | Forked SwiftTerm with custom renderer. 3-4 months of focused work. This is the technical defensibility. |
| **Don't replace the code editor** | VS Code/Cursor stays for editing. Logos is the **Claude Code host**, not an IDE. |
| **Don't host Claude API directly** | We host the `claude` CLI as subprocess. The CLI is the source of truth for Claude Code behavior. Anthropic's updates flow through naturally. |
| **Brand under Logos** | Sister to `claude-code-logos` (plugins). Both share λόγος etymology. Both about making Claude Code work better. |

## 6. Layout

```
┌──┬────────────┬─────────────────┬──────────────────┐
│  │            │                 │                  │
│ A│ File       │ Editor / file   │ PDF live render  │
│ c│ explorer   │ viewer          │ (right pane)     │
│ y│ (fixed)    │ (top center)    │                  │
│  │            │ tabbed          │ file watcher →   │
│ b│            │ syntax-highlight│ auto-rebuild     │
│ a│            │                 │                  │
│ r│            │                 │                  │
│  │            ├─────────────────┴──────────────────┤
│  │            │                                    │
│  │            │ TERMINAL — Claude Code (bottom)    │
│  │            │ (fixed bottom panel)               │
│  │            │ forked SwiftTerm + custom renderer │
│  │            │                                    │
└──┴────────────┴────────────────────────────────────┘
   STATUS BAR: 👤 account · 💰 cost · ⚡ auto-handle · 📊 tokens · session
```

### 6.1 Region descriptions

| Region | Behavior |
|--------|----------|
| **Activity bar** (far left, 36px) | Icon column: Files / Search / Sessions / Settings / Account switcher. Click to focus / toggle the corresponding sidebar mode. |
| **Sidebar** (fixed left, ~160px default, resizable) | File explorer tree. Workspace-rooted. Click file → opens in editor pane. Cmd+Click filename in terminal output → highlights & opens here. |
| **Editor / file viewer** (top center, flex) | Tabbed read-only viewer. Syntax highlighting for code (TreeSitter or Highlightr — TBD). Markdown rendered. PDF opens in right pane instead. Editing intentionally **not supported** — open in VS Code via menu / shortcut. |
| **PDF live render** (top right, flex) | PDFKit-based viewer. FSEvents watches associated source file (.tex / .md / .py with matplotlib output). Auto-rebuilds and reloads PDF on source change. Empty state when no PDF active. **Open question: always visible vs conditional — see § 10.4.** |
| **Terminal panel** (bottom, fixed-ish, resizable) | Forked SwiftTerm rendering `claude` CLI. Full PTY support. Subject to renderer rewrite for zero tearing. Drag top edge to resize. |
| **Status bar** (bottom strip, 24px) | Persistent info row. See § 7.7 for content. |

### 6.2 Resize model

| Version | Capability |
|---------|------------|
| **v1.0** | Drag any pane boundary to resize. File explorer collapsible to 0 (auto-hides). Persist per-workspace. |
| **v1.1** | ⌘⏎ hotkey: terminal pane goes full-window, all other panes hide. Press again to restore. |
| **v1.2** | Named layout presets (e.g., "Claude focus", "Edit focus", "Reading"). ⌘1/2/3 to switch. Per-preset pane sizes. |

When terminal pane is resized, the app sends `SIGWINCH` to the `claude` subprocess so it knows new column count for future output. Past output stays as-rendered (terminal-emulator limitation).

## 7. Core features

### 7.1 Terminal panel (Claude Code host)

- Hosts `claude` CLI as PTY subprocess
- Built on **forked SwiftTerm** with rewritten renderer (see § 8.2 — the moat)
- Standard terminal: ANSI/VT100 support, scrollback, copy/paste, font config
- **Stream tee** at PTY level: one branch to renderer, one branch to pattern parser (for auto-recovery)
- Bidirectional: app can inject keystrokes back via PTY stdin (auto-recovery sends "keep going\n" etc.)

### 7.2 Auto-recovery system

The headline feature. Built on `claude-code-watchdog`'s pattern-detection logic, but native and configurable.

| Pattern detected | Default action | User-configurable |
|-----------------|----------------|-------------------|
| `Rate limit · Press "keep going" to retry` | Auto-type "keep going\n" after configurable backoff (default 3s, max 10 retries) | Backoff time, max retries, on/off |
| `Yes, I trust this folder` | Auto-approve for workspaces on user allowlist | Per-folder allow/deny rules |
| `Do you trust the files` | Same as above | Same |
| MCP tool permission prompt | Per-tool rule: always allow / always deny / always ask | Per-server, per-tool |
| Press Enter to continue | Auto-press after 2s (or configurable timeout) | Timeout, on/off |
| Custom regex | User-defined patterns + response | Power-user JSON config |

**Status bar shows "armed" state**: 🟢 auto-handle armed (all rules active) / 🟡 partial (some disabled) / 🔴 disabled. When a rule fires, brief toast notification.

### 7.3 Multi-account management

- **Storage**: OAuth tokens stored in macOS Keychain (one entry per account)
- **Switcher UI**: ⌘K opens account picker, or click status bar account name
- **Per-session binding**: each terminal session bound to one account; account shown in session label (⌘1 work / ⌘2 personal)
- **Mechanism**: swap `~/.claude/.credentials.json` per session via symlink, OR set `HOME` env var override per subprocess (TBD which is more robust)
- **Discovery**: app reads existing `~/.claude/.credentials.json` on first launch and imports as default account

### 7.4 File explorer

- Tree view of current workspace
- Standard navigation: arrow keys, Enter to open, Cmd+Click for tabs
- Hidden files toggle
- **Cmd+Click from terminal**: when Claude prints `src/foo.swift:42:30` in terminal output, Cmd+Click highlights `src/foo.swift` in tree and opens in editor

### 7.5 File viewer (editor pane)

- **Read-only by design** (see philosophy § 5)
- Tabbed (multiple files open simultaneously)
- Syntax highlighting: TreeSitter integration OR Highlightr — **TBD per § 10**
- Markdown rendered (not raw)
- PDFs route to PDF live-render pane instead
- "Open in external editor" menu action (default: macOS-registered editor for that file type; configurable to specific editor like VS Code / Cursor)

### 7.6 PDF live render

The LaTeX-workflow killer feature. Use case: edit `notes.tex` → Claude modifies it → PDF auto-rebuilds in right pane.

- **PDFKit-based viewer**
- **FSEvents file watcher** on associated source file
- **Build command**: configurable per project (`latexmk -pdf` / `pandoc` / `marp` / custom shell command in `.logosconfig`)
- **Smart pairing**: open `foo.tex` → app looks for `foo.pdf` and offers to bind; opens `foo.md` → similar for pandoc workflow
- **Empty state**: when no PDF active, pane shows "No PDF — open a .tex or bind a file" hint OR pane hides (see § 10.4)

### 7.7 Status bar

Persistent strip at window bottom. Items left-to-right:

| Item | Behavior |
|------|----------|
| 👤 Account name | Click → account switcher |
| 💰 Session cost | Running USD total for current session. Click → cost breakdown popover |
| ⚡ Auto-handle status | 🟢/🟡/🔴 + label. Click → rules config |
| 📊 Token usage | `12k / 200k` context. Click → context inspector |
| (spacer) | |
| Session label | `⌘1 work` etc. Click → session switcher |
| File encoding | UTF-8 |
| Workspace mode hint | LaTeX / Markdown / Generic (inferred from files) |

### 7.8 Multi-session

- ⌘N to spawn new session
- ⌘1/2/3 to switch
- Each session: own terminal, own account binding, own workspace cwd, own auto-handle rules
- Visible session list in activity bar (or sidebar mode, TBD)
- **Open question § 10.7**: session ↔ workspace relationship — 1:1, N:1, or N:N?

### 7.9 Settings UI

- Standard Mac Preferences window (`⌘,`)
- Tabs: General / Terminal / Auto-handle / Accounts / Live preview / Advanced
- Auto-handle rules editor (per-pattern toggle + advanced JSON for power users)

## 8. Architecture

### 8.1 Tech stack

| Layer | Choice | Rationale |
|-------|--------|-----------|
| Language | Swift 6 | Maintainer expertise (15+ Swift MCP projects); strict concurrency model fits PTY/subprocess work |
| UI framework | SwiftUI primary, AppKit interop | SwiftUI for new UI; AppKit where SwiftUI lacks (e.g., advanced NSWindow features, NSOutlineView for file tree if needed) |
| Package manager | SwiftPM | Matches sister projects; no Xcode project file required |
| Min macOS | 14+ (TBD) | Modern SwiftUI APIs; covers ~90% of likely users |
| Terminal | **Forked SwiftTerm** | MIT license, only mature native option. Renderer rewritten — see § 8.2 |
| PDF | PDFKit | Built-in, free, full-featured |
| File watch | FSEvents | Built-in, low-overhead |
| Syntax highlight | TBD: TreeSitter (Swift bindings) vs Highlightr (NSAttributedString-based) | § 10 |
| Credential storage | Keychain Services | Standard, secure |
| Distribution | Mac App Store + direct download (.dmg) | Notarization pipeline already exists per `~/.claude/CLAUDE.md` (`che-mcps-notary` keychain profile) |

### 8.2 Terminal rendering — THE moat

> **UPDATE (2026-05-30) — C.2 delivered by ADOPTION, not from-scratch rewrite.** The pinned SwiftTerm fork (v1.13.0) already ships a complete Metal renderer (vsync `draw(in:)`, glyph atlas, per-row damage tracking, frame-semaphore double-buffering, ~16.67 ms damage coalescing). The "3-4 month renderer rewrite" phase table below is therefore superseded: the moat is delivered by turning that renderer on (`setUseMetal(true)`) with a CoreGraphics fallback, tracked in the Spectra change `renderer-c2-metal-adoption`. The measured CoreGraphics tearing baseline (~22 mid-state clusters per 12 redraw cycles) is in `docs/renderer-baselines/cg-vs-metal-edit-tool.md`. The from-scratch plan (`docs/superpowers/plans/2026-05-26-renderer-rewrite-c2-frame-loop.md`) is marked superseded. Only the conditional "mid-redraw coalescing" heuristic (phase 4 below) might remain, and only if interactive validation shows the fork's built-in coalescing is insufficient.

**The decision**: Fork SwiftTerm and rewrite the renderer to eliminate tearing entirely (Path A++++).

**Why hard mode**:
- Tearing is the most visible Claude Code pain on every terminal emulator
- Solving it = differentiation no competitor will replicate (4+ months of focused work)
- Solving it half-way (overlays for some interactions) = leaves the moat shallow

**Phases**:

| Phase | Work | Duration |
|-------|------|----------|
| 1 | Fork SwiftTerm; build test harness that replays captured Claude Code stream | 3-4 weeks |
| 2 | Frame-rate render loop (60Hz, atomic frame swap) | 4-6 weeks |
| 3 | Damage tracking (cell-level diff; only re-render changed cells) | 3-4 weeks |
| 4 | Smart redraw coalescing (detect "Claude is mid-redraw" via heuristics; hold commit until done) | 2-3 weeks |
| 5 | Claude Code compatibility testing (every tool / streaming / edge case) | continuous |
| 6 | Performance tuning (10k+ scrollback, no dropped frames) | 2-3 weeks |
| **Total** | **renderer rewrite** | **3-4 months focused** |

**Target**: Claude Code tool-call redraws not perceived as flicker by human eye. ~30fps + damage tracking is sufficient (we don't need to match Ghostty's 60fps Metal pipeline).

**Risk**: This is systems programming, not boilerplate SwiftUI. AI-assisted coding helps with implementation but not design. Maintainer must develop or have terminal-emulator depth. See § 10.2.

### 8.3 Subprocess hosting & stream tee

```
┌──────────────────┐
│  claude CLI       │  ← subprocess (PTY)
└────────┬─────────┘
         │ stdout (PTY)
         ▼
┌──────────────────┐
│  Stream Tee       │  ← splits stream
└──┬───────────┬───┘
   │           │
   ▼           ▼
┌──────────┐  ┌─────────────────────┐
│ Renderer │  │  Pattern Parser      │
│ (custom  │  │  (regex / state     │
│  Swift   │  │   machine on text)  │
│  Term)   │  └──────┬──────────────┘
└──────────┘         │ detected pattern
                     ▼
              ┌────────────────────┐
              │  Auto-handle       │
              │  decision engine   │
              └──────┬─────────────┘
                     │ "keep going\n"
                     ▼
              ┌────────────────────┐
              │ PTY stdin writer   │ → back to claude
              └────────────────────┘
```

Status bar listens to events from pattern parser & auto-handle (e.g., "rule fired") to update UI.

### 8.4 Multi-account mechanism

Two candidate implementations (decide during prototype):

**Option α: Symlink swap of `~/.claude/.credentials.json`**
- Per account: real credentials file at `~/.logos/accounts/<name>/.credentials.json`
- App swaps symlink at `~/.claude/.credentials.json` before spawning `claude` subprocess
- Pros: works with any `claude` version, no env-var magic
- Cons: race condition if two sessions spawn simultaneously; affects ALL claude processes on machine (including those outside Logos)

**Option β: `HOME` env override per subprocess**
- Each session subprocess runs with `HOME=~/.logos/accounts/<name>/`
- `claude` reads its credentials from that HOME
- Pros: isolated per-process, no global state
- Cons: `claude` might write other state to HOME (cache, config) — needs full per-account HOME tree

Tentative pick: **β** (cleaner isolation). Validate during prototype.

### 8.5 PDF live preview pipeline

```
User opens file.tex in editor pane
  ↓
App reads .logosconfig.yaml (or guesses):
  build: latexmk -pdf -interaction=nonstopmode file.tex
  preview: file.pdf
  ↓
FSEvents watches file.tex
  ↓
On change:
  - Debounce 500ms (avoid mid-edit rebuilds)
  - Run build command
  - On success: reload file.pdf in PDFKit view
  - On failure: show error inline in PDF pane
```

### 8.6 Settings & persistence

- App settings: `~/Library/Application Support/Logos/settings.json`
- Per-workspace settings: `<workspace>/.logosconfig.yaml`
- Per-account data: `~/.logos/accounts/<name>/` (HOME tree per option β)
- Window state: standard macOS state restoration (`NSWindow` autosave)

## 9. MVP scope (TENTATIVE)

**These cuts assume answers to § 10 open questions; treat as draft.**

### v1.0 (target: month 4-6)
- Forked SwiftTerm + renderer rewrite (zero tearing) — the moat
- Three-column + bottom terminal layout
- Drag-resize all panes (file-explorer collapsible)
- File explorer (read-only tree)
- File viewer (read-only, syntax highlight, markdown render)
- PDF live render (LaTeX/markdown builds)
- Auto-handle: rate-limit ("keep going") + trust prompts
- Multi-account: storage + switcher (option β)
- Status bar (account, cost, auto-handle, tokens, session label)
- Single-session per window
- macOS 14+ direct download (.dmg, notarized)

### v1.1 (target: month 6-8)
- ⌘⏎ terminal fullscreen toggle
- Auto-handle: MCP permission rules (per-tool)
- Multi-session (⌘N / ⌘1/2/3 within one window)
- Cmd+Click file path in terminal → highlights in tree
- Mac App Store release

### v1.2 (target: month 8-10)
- Named layout presets (⌘1/2/3 layout modes)
- Auto-handle: rule configuration UI (currently power-user JSON)
- TreeSitter integration for syntax highlight (if not picked v1.0)
- Custom regex rules in auto-handle

### Deferred (vNext / never)
- Code editing in viewer (intentional non-goal — see § 11)
- Cross-platform (Linux/Windows)
- Remote / SSH Claude session (separate product if built)
- Session sync across machines
- Collaborative sessions

## 10. Open questions (BLOCK implementation)

Each numbered question needs explicit user answer before writing-plans phase.

### Decision questions

| # | Question | Why it blocks |
|---|----------|---------------|
| 10.1 | ~~**Timeline acceptance**: 4-6 months MVP~~ → **REVISED 2026-05-30**: the renderer "moat" is largely pre-built in the fork (see § 8.2 update), so the 3-4 month renderer line item collapses to adoption + interactive validation; MVP timeline is materially shorter | Determines roadmap aggressiveness |
| 10.2 | ~~**Renderer rewrite expertise**~~ → **LOWERED 2026-05-30**: adopting the fork's existing Metal renderer needs far less terminal-emulator depth than a from-scratch rewrite; deep expertise is only needed if the conditional mid-redraw coalescing heuristic proves necessary | Determines phase 1 ramp + risk profile |
| 10.3 | ~~**No vanilla SwiftTerm interim ship** — confirmed?~~ → **RESOLVED 2026-05-30** (via `renderer-c2-metal-adoption` D5): adopting the fork's GPU Metal renderer IS the differentiated zero-tearing moat, not a vanilla interim ship (vanilla = the upstream CoreGraphics path that tears) | Affects launch narrative |
| 10.4 | **PDF pane**: always visible with empty state, OR conditional (only when PDF bound)? | Layout invariant |
| 10.5 | ~~**Activity bar**: confirm inclusion~~ → **RESOLVED 2026-05-25**: Keep activity bar with icons Files / Search / Sessions / Settings / Account | Layout invariant |
| 10.6 | ~~**Status bar items**~~ → **RESOLVED 2026-05-25**: All 4 items confirmed for v1.0 (Account, Cost, Auto-handle status, Token usage) | Layout invariant |
| 10.7 | **Session ↔ workspace**: 1:1 (each session = one workspace), N:1 (multiple sessions same workspace), or N:N? | Multi-session model |
| 10.8 | **Syntax highlighter**: TreeSitter (heavier, real parsing) vs Highlightr (lighter, regex-based)? | Dependency choice |
| 10.9 | **Auto-handle rule UI in v1.0**: simple on/off toggle, OR per-rule editor? | Settings scope cut |
| 10.10 | ~~**Min macOS**~~ → **RESOLVED 2026-05-25**: macOS 15 (Sequoia) | Compatibility floor |
| 10.14 | ~~**License**~~ → **RESOLVED 2026-05-25**: MIT (matches sister projects) | Affects contribution model |
| 10.15 | ~~**Bundle ID**~~ → **RESOLVED 2026-05-25**: `app.getlogos.logos` | App Store identity |

### Validation needed (parallel to design)

| # | Question | Action |
|---|----------|--------|
| 10.11 | "Logos" trademark clear in USPTO / EUIPO / TIPO (class 9 software)? | Maintainer searches |
| 10.12 | Domain availability: `logos.app` / `getlogos.com` / `logosapp.com`? | `whois` checks |
| 10.13 | Mac App Store name availability for "Logos"? | App Store Connect search |

## 11. Non-goals

What Logos is explicitly **NOT**:

- ❌ **A code editor**. No LSP, IntelliSense, debugger, refactoring. Use VS Code/Cursor for editing.
- ❌ **A general terminal emulator**. Optimized for `claude` CLI. Running `vim` / `htop` / `ssh` is supported (it's still a terminal) but those workflows are not the design target.
- ❌ **A Claude API chat client**. Does not implement Anthropic's API client. Hosts `claude` CLI as subprocess; CLI is the only client.
- ❌ **Cross-platform**. macOS only. No Linux, no Windows, no web. Native Swift means single-platform by design.
- ❌ **A session sync service**. Sessions are local. No cloud. (If user wants remote Claude Code observation, that's a different product — see § 13 reference to claude-code-watchdog).
- ❌ **A collaborative tool**. One user per window. No multiplayer.
- ❌ **A replacement for `claude-code-watchdog`**. Watchdog supervises background bots in tmux. Logos is for interactive workstations. Some pattern-detection logic ports between them but they target different scenarios.
- ❌ **A runner of VS Code `launch` / `tasks` configs or an extension host** (#97). A `.code-workspace` file may carry `launch` (debugger configs), `tasks` (task-runner definitions), and `extensions.recommendations`, and a folder may carry `.vscode/extensions.json`. Logos deliberately **ignores** all of them: it has no debugger, no task runner, and no extension host, so honoring them would be meaningless. `CodeWorkspaceReader` reads only `folders`; `.vscode/settings.json` honors only the keys explicitly wired (currently `files.exclude`, #97 Slice 1). This is a drawn boundary, not an omission — the VS Code keys that DO map onto a Logos concept are tracked slice-by-slice in #97; these two never will.

## 12. Naming

| Field | Value |
|-------|-------|
| Working name | `Logos` |
| Etymology | Greek λόγος — word, reason, rational order, principle |
| Why it fits | Claude generates words, performs reasoning, executes logic. λόγος unifies all three. |
| Brand pattern | One-word Latin/Greek (matches Logic, Aperture, Final Cut, Linear, Notion) |
| Sister project | `claude-code-logos` (plugin marketplace) — shared brand, philosophy |
| Trademark risk | **Moderate** — `Logos` is heavily used (Logos Bible Software is largest established mark). Generic Greek word — full trademark monopoly unlikely, but defensive search needed |
| SEO risk | **High** — "logos" lowercase = brand logos (the design concept); first-page Google dominated by logo-design content. Mitigate by using `Logos App` / `Get Logos` for marketing copy + `logos.app` domain |
| Pronunciation | "LOH-goss" (Greek) or "LOW-goes" (English, sounds like "logos" plural of logo). Disambiguate on website. |

**Decision deferred**: confirm working name post-validation (§ 10.11-13). Alternative candidates if Logos blocked: Helm, Anvil, Glass, Quay, Pane.

## 13. References

| Reference | Relationship |
|-----------|--------------|
| [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) | Base terminal library to fork |
| [Ghostty](https://ghostty.org) | Smooth-renderer reference (not a dependency, just inspiration for what "smooth" looks like) |
| [`claude-code-watchdog`](https://github.com/.../claude-code-watchdog) | Predecessor; pattern-detection logic ports forward into auto-handle |
| [`claude-code-logos`](https://github.com/.../claude-code-logos) | Sister project, shared brand |
| [Wave Terminal](https://www.waveterm.dev) | Adjacent product (AI-integrated terminal) — different category (general AI sidebar, not Claude Code host) |
| [Claude Code docs](https://docs.claude.com/en/docs/claude-code/) | Source of truth for `claude` CLI behavior to host |

## 14. Implementation roadmap (high-level)

| Phase | Months | Work |
|-------|--------|------|
| **0. Validation** | week 0 | Trademark / domain checks (§ 10.11-13). Answer open questions (§ 10.1-10). User reviews & approves design doc. |
| **1. Foundation** | 1-2 | SwiftTerm fork + research. App shell (window, layout structure). PTY subprocess hosting. Status bar skeleton. Pattern-parser prototype. |
| **2. Renderer rewrite** | 2-4 | Frame-rate loop. Damage tracking. Smart coalescing. Compatibility tests against Claude Code streams. |
| **3. Core features** | 4-5 | File explorer + viewer. PDF live render (PDFKit + FSEvents). Auto-handle: rate-limit + trust. Multi-account (option β). |
| **4. Polish + ship** | 5-6 | Resize UX. Settings UI. Notarization (existing `che-mcps-notary` pipeline). Beta testers. v1.0 direct-download launch. |
| **5. v1.1** | 6-8 | Fullscreen toggle. MCP permission rules. Multi-session. Cmd+Click integration. Mac App Store submission. |
| **6. v1.2+** | 8-10 | Layout presets. Auto-handle UI. TreeSitter. Custom regex rules. |

---

## Appendix A — Design discussion summary

This design emerged from a brainstorming session on 2026-05-25 with the following arc:

1. Started: "what's the right architecture for a Claude-Code-specific tool?"
2. Considered: WaveTerm — rejected (it's general AI-integrated terminal, not Claude Code host)
3. Considered: native vs Electron — chose Swift native
4. Considered: 4 product framings (native UI / remote observatory / multi-session / observability) — AI recommended Remote Observatory framing
5. User rejected remote-observatory direction (concern that running Claude on multiple remote machines could trigger Anthropic anti-abuse signals); reframed to "VS Code replacement for hosting Claude Code locally with auto-recovery"
6. Scope expanded: file viewer + PDF live render + multi-account added
7. Tension surfaced: tearing fix requires path B (native render) or path C (overlay hybrid) — terminal-based can't solve it
8. Resolution: user chose **path A++++** (fork SwiftTerm + rewrite renderer) — accept hard-mode timeline for the moat
9. Layout iterated: settled on VS Code-like 3-column + bottom terminal
10. Named: working name `Logos` (sister to existing `claude-code-logos`)
11. User directive: "stop asking, write everything down"

This document captures decisions through step 11. Step 12 is user review.

## Appendix B — What to do next

For maintainer:
1. Read this doc end-to-end
2. Answer § 10 open questions (block #10.1-10.10 are decision questions; #10.11-13 are validation)
3. Approve or request changes
4. Run `spectra init` in this repo to set up `openspec/` structure
5. Break this design into Spectra changes (suggested first changes: `terminal-foundation`, `renderer-rewrite-phase-1`, `auto-handle-rate-limit`, `multi-account-mvp`)
6. Then invoke `writing-plans` skill for first concrete implementation plan

For the AI agent picking this up later:
- Do **not** start coding before § 10 answered
- Do **not** ship a vanilla SwiftTerm interim (see § 5 philosophy + § 10.3)
- Do **not** add features outside § 9 v1.0 scope without explicit approval
