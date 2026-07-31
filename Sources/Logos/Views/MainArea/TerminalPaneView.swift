import SwiftUI
import AppKit
import LogoSwitch
import LogosGateway

struct TerminalPaneView: View {
    @Environment(TerminalConfig.self) private var config
    @Environment(AdvancedSettings.self) private var advanced
    @Environment(AutoHandleEngine.self) private var engine
    @Environment(AccountManager.self) private var accountMgr
    /// #42: which account THIS window shows. Per-window state — the pane spawns claude
    /// for this account (not the global active one), so two windows run two accounts
    /// in parallel. The account list + isolation stay global on `accountMgr`.
    @Environment(WindowAccountSelection.self) private var windowSelection
    /// #49 Part 2: this window's live usage model. The terminal reports its spawned
    /// `--session-id` here so the status bar reads exactly this session's transcript.
    @Environment(WindowUsageModel.self) private var usage
    /// #96: the workspace, so the spawned claude inherits the workspace's first folder as
    /// its working directory (the deterministic first-folder cwd rule). The fuller
    /// session ↔ workspace model (§10.7) is deferred; here the session binds to the primary
    /// root, so re-establishing a different primary folder re-spawns claude in the new cwd.
    @Environment(WorkspaceModel.self) private var workspace
    /// Lifecycle of the hosted claude session (#18). Drives the exit-state
    /// overlay and the generation-based restart. Owned here so it survives the
    /// view recreation that a restart triggers.
    @State private var sessionState = TerminalSessionState()
    /// The per-account gateway pool (spec 2026-07-31). Injected rather than global
    /// so a test or preview can supply its own.
    @Environment(\.gatewayPool) private var gatewayPool
    /// This pane's gateway outcome. `nil` means "still resolving" — `GatewayPool`
    /// spawns a child and waits for readiness, which a SwiftUI body cannot await,
    /// so acquisition lives in `.task(id:)` and parks its result here.
    @State private var gateway: GatewayResolution?

    var body: some View {
        // H-Task 9: AdvancedSettings.claudePathOverride wins over PATH lookup.
        // #24: a `--ui-testing --claude-path` launch arg wins over everything so a
        // UI test's claude resolves even on a dev machine with a persisted override
        // (uiTestingClaudePath is nil outside a UI test → no production effect).
        let effectivePath = TerminalConfig.uiTestingClaudePath()
            ?? advanced.claudePathOverride
            ?? config.resolvedClaudePath

        Group {
            if let active = WindowAccountResolver.resolve(
                selected: windowSelection.accountId,
                accounts: accountMgr.accounts
            ), let claudePath = effectivePath {
                switch gateway {
                case .none:
                    GatewayResolvingPlaceholder()

                case .blocked(let reason):
                    // Fail-closed: this account has a custom upstream, so running
                    // direct would route traffic somewhere the operator did not
                    // direct it. No terminal at all.
                    GatewayUnavailableBanner(reason: reason, isBlocking: true)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .background(Color.black.opacity(0.9))

                case .resolved(let gatewayURL):
                    terminal(active: active, claudePath: claudePath, gatewayURL: gatewayURL)
                }
            } else if effectivePath == nil {
                ClaudeNotFoundBanner()
            } else {
                NoActiveAccountBanner()
            }
        }
        .task(id: resolvedAccountID) {
            await resolveGateway()
        }
    }

    /// The account this pane shows, as a `.task(id:)` key. Changing accounts must
    /// re-resolve, because the gateway is per account.
    private var resolvedAccountID: String? {
        WindowAccountResolver.resolve(
            selected: windowSelection.accountId,
            accounts: accountMgr.accounts
        )?.id
    }

    /// Acquire this account's gateway, hold the reference for as long as the pane
    /// lives, and hand it back on teardown.
    private func resolveGateway() async {
        guard let active = WindowAccountResolver.resolve(
            selected: windowSelection.accountId,
            accounts: accountMgr.accounts
        ) else { return }

        guard advanced.gatewayEnabled else {
            gateway = .success(nil)
            return
        }

        let command = advanced.gatewayCommand ?? GatewayCommandResolver.resolve()
        let upstream = active.upstream.flatMap(URL.init(string:))

        do {
            let url = try await gatewayPool.acquire(
                account: active, command: command, upstream: upstream)
            gateway = .success(url)
        } catch {
            gateway = GatewayResolution.classify(
                hasCustomUpstream: active.upstream != nil,
                error: .unavailable(error.localizedDescription))
            return   // nothing was acquired, so nothing to release
        }

        // Park until SwiftUI cancels this task — the pane went away, or the account
        // changed. Only then release, so the pool's refcount tracks pane lifetime
        // rather than leaking a reference and keeping a gateway alive forever.
        while !Task.isCancelled {
            do { try await Task.sleep(for: .seconds(60)) } catch { break }
        }
        await gatewayPool.release(accountID: active.id)
    }

    @ViewBuilder
    private func terminal(
        active: Account,
        claudePath: String,
        gatewayURL: URL?
    ) -> some View {
        VStack(spacing: 0) {
            // Fail-open: the gateway was wanted but is unavailable, and this account
            // has no custom upstream, so claude runs direct — working, but unpaced
            // and invisible to rate-limit telemetry. The system-default account is
            // excluded because it is SUPPOSED to have no Logos gateway.
            if gatewayURL == nil, advanced.gatewayEnabled, !active.isSystemDefault {
                GatewayUnavailableBanner(
                    reason: "No gateway is running for this account. Requests go direct and are not paced.",
                    isBlocking: false
                )
            }

            let processConfig = ClaudeProcessConfig(
                executablePath: claudePath,
                account: active,
                extraArgs: advanced.claudeExtraArgs,  // #19: dangerous-mode toggle
                // #96: spawn claude in the workspace's first folder (deterministic cwd
                // rule). nil (no workspace open yet) falls back to the process default.
                workingDirectory: workspace.rootNode?.path,
                // #33: spawn claude with the user's REAL (login-shell) env, not
                // the bare launchd env a Finder launch provides. Per-account
                // CLAUDE_* overrides are layered on top inside the init (#12).
                baseEnvironment: LoginShellEnvironment.resolve(),
                // spec 2026-07-31: this account's OWN gateway, or nil to strip.
                gatewayBaseURL: gatewayURL
            )
            SwiftTermView(
                    config: config,
                    processConfig: processConfig,
                    engine: engine,
                    accountManager: accountMgr,
                    sessionState: sessionState,
                    // #49 Part 2: bind the status bar to the exact session this pane spawns.
                    onSessionSpawned: { usage.setSessionId($0) }
                )
                .background(Color.black)
                // Recreate on path / account / restart. The generation suffix
                // makes Restart re-spawn a fresh claude (fresh detector/parser +
                // re-materialized creds) by changing the view identity (#18).
                // The gateway URL is part of the identity: a changed gateway must
                // re-spawn claude rather than leave it pointed at a dead port.
                .id("\(active.id)-\(claudePath)-\(workspace.rootNode?.path ?? "")-\(gatewayURL?.absoluteString ?? "direct")-\(sessionState.generation)")
                .overlay {
                    if sessionState.hasExited {
                        TerminalExitedOverlay(
                            exitCode: sessionState.exitCode,
                            isAbnormal: sessionState.isAbnormal,
                            onRestart: { sessionState.restart() },
                            onClose: { NSApplication.shared.keyWindow?.performClose(nil) }
                        )
                    }
                }
                // #27: a launch-arg-gated terminate affordance. The XCUITest runner
                // sandbox blocks `Process` (can't kill claude's child to drive exit),
                // so a UI test drives the clean-exit overlay via this click instead —
                // it calls the exact `markExited(0)` transition `processTerminated`
                // drives. Inert in production (the `--ui-testing` arg never appears).
                .overlay(alignment: .topLeading) {
                    if CommandLine.arguments.contains("--ui-testing") {
                        Button("⏚") { sessionState.markExited(0) }
                            .accessibilityIdentifier("logos.terminal.uitestTerminate")
                            .padding(6)
                    }
                }
                // #29: passive re-auth nudge when the hosted claude is
                // unauthenticated (detected from its 401 / "Please run /login"
                // output). Non-blocking top strip — the terminal stays usable so
                // the user types `/login` themselves; Logos never touches the token.
                .overlay(alignment: .top) {
                    if sessionState.needsAuth {
                        // Dismiss clears the banner AND un-forces the active
                        // account's live-401 override (#34, bug #4) — so the banner
                        // and the switcher (both derived from needsReauth) stay
                        // coherent; the old dismiss left the switcher pinned.
                        AuthNeededBanner(onDismiss: {
                            sessionState.dismissNeedsAuth()
                            // #42: acknowledge THIS pane's account, not the global active.
                            accountMgr.acknowledgeReauth(active.id)
                        })
                    }
                }
        }
    }
}

/// Shown while the pane waits for its account's gateway to spawn and accept
/// connections. Brief in practice, but never zero — the pool starts a child
/// process and probes it before claude may be spawned.
private struct GatewayResolvingPlaceholder: View {
    var body: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text("Preparing gateway…")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.9))
        .accessibilityIdentifier("logos.gateway.resolving")
    }
}

private struct ClaudeNotFoundBanner: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40))
                .foregroundStyle(.yellow)
            Text("claude CLI not found")
                .font(.headline)
                .foregroundStyle(.white)
            Text("Install Claude Code and ensure 'claude' is in your $PATH, or set the path explicitly in Settings → Advanced.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
            Link(
                "Install instructions →",
                destination: URL(string: "https://docs.claude.com/en/docs/claude-code/")!
            )
            .font(.caption)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.9))
    }
}

private struct NoActiveAccountBanner: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.crop.circle.badge.questionmark")
                .font(.system(size: 40))
                .foregroundStyle(.yellow)
            Text("No active account")
                .font(.headline)
                .foregroundStyle(.white)
            Text("Add an account from the status bar (👤) to get started.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.9))
    }
}

/// #29: passive, non-blocking re-auth nudge. PASSIVE BY DESIGN — it only tells the
/// user to type `/login`; it does NOT run the login, proxy the OAuth callback, or
/// touch the token. The genuine `claude` owns the whole auth lifecycle (and
/// `OAuthURLDetector` opens the browser). Keeps Logos a first-party host, not a
/// third-party auth client.
private struct AuthNeededBanner: View {
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "person.crop.circle.badge.exclamationmark")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("This account isn't signed in")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Text("Type `/login` in the terminal to authenticate with Claude.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("Dismiss", action: onDismiss)
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .bannerStyle()
        .padding(8)
        .accessibilityIdentifier("logos.terminal.authBanner")
    }
}
