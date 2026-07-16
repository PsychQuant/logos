# Logos

> Native macOS app that hosts Claude Code with auto-recovery, multi-account, and zero render tearing.

**Status**: Sub-plans A + B + D complete ✅ — real `claude` CLI runs in native Mac terminal pane, with 5-rule auto-handle intercepting permission/rate-limit/trust prompts.

![Logos with auto-handle armed](docs/screenshots/auto-handle-live.png)

See [design doc](docs/design/2026-05-25-logos-design.md), [sub-plan A](docs/superpowers/plans/2026-05-25-app-shell-foundation.md), [sub-plan B](docs/superpowers/plans/2026-05-25-swiftterm-claude-host.md), [sub-plan D](docs/superpowers/plans/2026-05-25-auto-handle.md), [sub-plan C.1](docs/superpowers/plans/2026-05-25-renderer-rewrite-c1-fork-harness.md) (partial — see [PR #1](https://github.com/PsychQuant/logos/pull/1)).

**Working name**: `Logos` (λόγος — word, reason, rational order). Trademark validation pending.

## Why this exists

Claude Code is powerful but **leaks pain** at the seams:
- Stuck on `Press "keep going" to retry` when rate-limited and you stepped away
- Render flickering as tool calls redraw the terminal
- One terminal, one account — switching accounts is `claude logout && claude login`
- PDF / file output requires alt-tabbing to a separate viewer
- VS Code terminal is shared real-estate with everything else; xterm.js inherits all of the above

Existing solutions (Ghostty, Wave, Warp, VS Code terminal, Cursor agent) each fix **one** of these. None are designed **for Claude Code specifically**. Logos is.

## Architecture in one paragraph

VS Code-like shell (activity bar + file explorer + main area with PDF live-render + bottom terminal panel + status bar). The terminal panel hosts the `claude` CLI as a subprocess via a forked SwiftTerm with a rewritten frame-rate renderer (zero tearing). A stream-tee parses the PTY output to trigger auto-recovery (rate-limit retry, trust-prompt approval, MCP permission rules) and updates the status bar (account, cost, tokens, auto-handle armed/fired). Multi-account via Keychain Services with quick switcher. File explorer + viewer are read-only — editing stays in your real IDE.

## What this is NOT

- ❌ A code editor (no LSP, no IntelliSense — use VS Code/Cursor)
- ❌ A general terminal emulator (designed for `claude`, not for `vim` / `htop`)
- ❌ A Claude API chat client (hosts the CLI, not the API)
- ❌ Cross-platform (macOS only, native Swift)

## Sister project

[`claude-code-logos`](https://github.com/...../claude-code-logos) — plugin marketplace under the same Logos brand. Different repo, same philosophy: science-backed improvements to Claude Code.

## Repo status

**Sub-plan A — App shell foundation: COMPLETE ✅**
**Sub-plan B — SwiftTerm + claude subprocess: COMPLETE ✅**
**Sub-plan C.1 — SwiftTerm fork + capture/replay harness: COMPLETE ✅** (merged)
**Sub-plan D — Auto-handle: COMPLETE ✅**
**Sub-plan E + E.2 — Multi-account: COMPLETE ✅** (real Keychain swap working — see [retrospective](docs/sub-plan-e-retrospective.md) for E.2 architecture)
**Sub-plan F — File explorer + viewer: COMPLETE ✅** (Highlightr code viewer, Markdown render, file tree sidebar, ⌘O Open Workspace)
**Sub-plan G — PDF live render: COMPLETE ✅** (PDFKit + FSEvents watcher + BuildPipeline + WorkspaceConfig YAML)
**Sub-plan H — Settings UI: COMPLETE ✅** (6 tabs wired: General/Terminal/Auto-handle/Accounts/Live preview/Advanced; persistence to `~/Library/Application Support/Logos/*.json`)

- Launchable native macOS app with VS Code-like layout (activity bar + sidebar + main area top/bottom + status bar)
- **Real `claude` CLI runs as PTY subprocess in terminal pane** (SwiftTerm 1.13, theme `Menlo 13pt` dark `#1e1e1e` / `#d4d4d4`)
- **5-rule auto-handle**: rate-limit "keep going", trust folder, trust files, Bash permission, Press Enter — all auto-approved per-rule with 5s cooldown + runaway-disable (3 fires in 30s → rule auto-disables, status bar turns yellow)
- `--dangerously-skip-permissions` removed; claude asks normally, `AutoHandleEngine` answers per-rule
- **Multi-account with per-account credential isolation** (⌘K opens switcher sheet). Each account spawns `claude` with its own `CLAUDE_CONFIG_DIR` / `CLAUDE_SECURESTORAGE_CONFIG_DIR` (`~/.logos/accounts/<id>/.claude`), so claude stores that account's credentials in its **own** per-directory Keychain item (`Claude Code-credentials-<hash>`). Switching accounts is pure local state — Logos never writes the shared system Keychain entry, which eliminates the macOS 26 "找不到鑰匙圈" reset-dialog risk ([#12](https://github.com/PsychQuant/logos/issues/12), follow-up to [#3](https://github.com/PsychQuant/logos/issues/3)). Accounts without a per-directory credential are surfaced as "needs login" in the switcher; authenticate by running `claude login` under that account. A one-time, non-destructive migration marks existing accounts needs-reauth and leaves the bare `Claude Code-credentials` entry untouched so plain-terminal `claude` keeps working.
- Drag-resize between all panes with persistence (UserDefaults)
- Multi-tab Settings stub (⌘,)
- **113 unit tests passing** in 24 suites (covers all models + services across A/B/D/E/F/G/H)
- **File explorer**: multi-root workspace tree in sidebar — one collapsible section per root folder (DisclosureGroup recursive), so a VS Code multi-root `.code-workspace` renders all its folders in file order ([#96](https://github.com/PsychQuant/logos/issues/96)); hidden-files toggle, honors `files.exclude` from both a `.code-workspace`'s workspace-level `settings` and each folder's `.vscode/settings.json` — merged the VS Code way (folder overrides workspace per key, including un-hiding via `false`) — so the tree hides the same entries VS Code hides ([#97](https://github.com/PsychQuant/logos/issues/97)), `⌘O` opens NSOpenPanel for a workspace switch (accepts either a plain directory or a `.code-workspace` file), last-opened workspace auto-loaded on relaunch via UserDefaults (`logos.lastWorkspacePath`); welcome empty state on first launch. Loader has `maxDepth=10` / `maxFiles=50_000` safety limits and refuses system roots (`/`, `/System`, `/Library`, etc.) — see [#2](https://github.com/PsychQuant/logos/issues/2). TCC-protected dirs (`~/Documents`, `~/Library`, photo libraries) are shown as locked, non-expandable nodes rather than walked (no consent-dialog cascade) — see [#7](https://github.com/PsychQuant/logos/issues/7)/[#13](https://github.com/PsychQuant/logos/issues/13)
- **Launching in a project directory** ([#8](https://github.com/PsychQuant/logos/issues/8)): pass `--workspace <path>` — a folder or a `.code-workspace` file — to open a specific workspace at launch:
  ```bash
  open -a Logos --args --workspace ~/Developer/logos
  # a VS Code multi-root workspace file works too:
  open -a Logos --args --workspace ~/Developer/logos/logos.code-workspace
  # or, launching the binary directly (inherits cwd as a fallback):
  cd ~/Developer/logos && /Applications/Logos.app/Contents/MacOS/Logos
  ```
  Precedence: `--workspace` arg → last-opened (persisted) → current directory (direct-binary launch only; system paths like `/` are refused so a normal GUI launch is unaffected) → welcome. When the locator is a `.code-workspace` file, its `folders` become the workspace roots and the hosted claude spawns in the first folder ([#96](https://github.com/PsychQuant/logos/issues/96)). An ergonomic `logos .` CLI shim is future work.
- **Read-only viewer**: tabbed editor pane, Highlightr xcode-theme syntax highlighting (~250 languages), Markdown rendered via AttributedString, 5MB file size cap with `Open in external editor` fallback
- Tearing/flicker still inherited from upstream SwiftTerm — fix lives in sub-plan C.2+ (renderer rewrite)
- claude not in `$PATH`? App shows `ClaudeNotFoundBanner` with install link
- No active account? App shows `NoActiveAccountBanner` directing to status bar

**How to install + run:**

```bash
# One-time install to /Applications (then launch via Spotlight: cmd+space → Logos)
make install

# Other useful targets
make run               # Build + bundle + open (dev iteration)
make tests             # Run all unit tests
make uninstall         # Remove from /Applications
make release-signed    # Developer ID sign + notarize + .dmg (for distribution)
make help              # List all targets
```

First launch from /Applications may show "unidentified developer" warning since the local install uses ad-hoc signature. Right-click → Open once to permanently trust.

For distribution to others, `make release-signed` produces a notarized `.dmg` (requires the `che-mcps-notary` keychain profile and Developer ID cert per `~/.claude/CLAUDE.md`).

**Next**:
- Merge [PR #1](https://github.com/PsychQuant/logos/pull/1) (sub-plan C.1) into main after review
- Collect remaining baseline captures (plan mode / rate-limit / permission) organically
- Sub-plan C.2 — frame-rate renderer (the moat work begins)
- Sub-plan E — multi-account Keychain switcher (independent of C)

Design doc: [`docs/design/2026-05-25-logos-design.md`](docs/design/2026-05-25-logos-design.md)
All plans: [`docs/superpowers/plans/`](docs/superpowers/plans/)

## Local data & privacy

Logos stores window layout and non-secret app preferences in a standard macOS
`UserDefaults` plist at `~/Library/Preferences/app.getlogos.logos.plist`
(e.g. the last-opened workspace path under `logos.lastWorkspacePath`). Because
Logos is **not sandboxed**, this file is readable by other unsandboxed processes
running as your user account — this is standard macOS behaviour for non-sandboxed
apps, not a defect. No credentials or tokens are written there: account secrets
live in the macOS Keychain (service `app.getlogos.logos.credentials`), guarded by
the system's per-item access controls.

## License

MIT — see [LICENSE](LICENSE).
