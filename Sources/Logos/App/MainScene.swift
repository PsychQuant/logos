import SwiftUI
import AppKit
import os
import LogoSwitch

struct MainScene: Scene {

    // Owned by `LogosApp` as App-level `@State` and injected into BOTH the main
    // WindowGroup and the `Settings` scene (#20). A separate `Settings` scene does
    // NOT inherit the WindowGroup's environment — these must be the SAME instances
    // shared across both scenes so Settings edits affect the running app.
    let layout: WindowLayoutState
    let activityBar: ActivityBarSelection
    let statusBar: StatusBarViewModel
    let terminalConfig: TerminalConfig
    let autoHandleEngine: AutoHandleEngine
    let accountManager: AccountManager
    let workspace: WorkspaceModel
    let pdfPreview: PDFLivePreviewModel
    let generalSettings: GeneralSettings
    let advancedSettings: AdvancedSettings

    var body: some Scene {
        WindowGroup("Logos") {
            MainView()
                .environment(layout)
                .environment(activityBar)
                .environment(statusBar)
                .environment(terminalConfig)
                .environment(autoHandleEngine)
                .environment(accountManager)
                .environment(workspace)
                .environment(pdfPreview)
                .environment(generalSettings)
                .environment(advancedSettings)
                .frame(
                    minWidth: 900,
                    idealWidth: 1400,
                    minHeight: 600,
                    idealHeight: 900
                )
                .preferredColorScheme(generalSettings.theme.colorScheme)
                .onAppear {
                    Task { @MainActor in
                        // Launch lifecycle marker (#22 follow-up): the main scene is
                        // up. Anchors the headless smoke sequence; no payload.
                        Log.app.notice("launch finished — main scene up")

                        // E.2 behavior change (per #3): no auto-import on launch.
                        // Touching the system Claude keychain entry from
                        // MainActor onAppear triggers macOS's "找不到鑰匙圈來
                        // 儲存「<user>」" fallback dialog on macOS 26 for
                        // unsandboxed Developer-ID apps. The user-facing flow
                        // is now: open Settings → Accounts → "Capture current
                        // login" button (existing UI in AccountSwitcherSheet).

                        // #12: one-time, non-destructive migration to the
                        // isolated-credential model. Ensures per-account config
                        // dirs exist and flags accounts needs-reauth from
                        // promptless signals only — no Keychain read or write.
                        accountManager.migrateToIsolatedCredentialsIfNeeded()

                        await autoLoadWorkspaceIfNeeded()
                    }
                }
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Workspace…") {
                    openWorkspaceViaDialog()
                }
                .keyboardShortcut("o", modifiers: .command)
            }
        }
    }

    private func autoLoadWorkspaceIfNeeded() async {
        guard workspace.rootNode == nil else { return }
        // #11: use the model's persistence (one source of truth) rather than
        // constructing a second WorkspacePersistence instance here.
        let persistence = workspace.workspacePersistence
        let persisted = persistence.loadLastPath()

        // Resolve which workspace to auto-load at launch (#8). Precedence:
        // explicit `--workspace <path>` arg → persisted → guarded cwd → welcome.
        // Both arg and cwd are routed through WorkspaceLoader.isSystemPath so a
        // system path (notably cwd=`/` on GUI launch) is refused — structurally
        // cannot re-introduce #2's cwd=`/` walk.
        guard let target = Self.resolveLaunchWorkspace(
            arguments: CommandLine.arguments,
            persisted: persisted,
            cwd: FileManager.default.currentDirectoryPath,
            isSystem: { WorkspaceLoader.isSystemPath(WorkspaceLoader.canonical($0)) }
        ) else { return }

        // Validate the chosen path is an existing directory, off MainActor (#5/#9).
        guard await Self.directoryExistsOffMain(target) else {
            // Only the persisted path is cleared on a stale/invalid result — an
            // invalid arg/cwd shouldn't nuke a (different) persisted workspace.
            if target == persisted { persistence.clear() }
            return
        }
        await workspace.openWorkspaceAsync(at: target)
    }

    /// Pure precedence resolver for the launch workspace (#8). Injected inputs
    /// + `isSystem` predicate keep it deterministically testable without reading
    /// the real `CommandLine` / cwd. Returns nil → welcome state.
    ///
    /// `nonisolated` (#28): pure (args-in/value-out, no main-actor state), so it
    /// drops the `@MainActor` it would otherwise inherit from `MainScene: Scene`.
    /// This lets the non-`@MainActor` synchronous `@Test`s call it without an
    /// isolation violation under the strict Swift-6 toolchain (the CI compile
    /// failure), while the main-actor Scene body can still call it freely.
    nonisolated static func resolveLaunchWorkspace(
        arguments: [String],
        persisted: String?,
        cwd: String,
        isSystem: (String) -> Bool
    ) -> String? {
        // A candidate is acceptable only if it's an ABSOLUTE, non-system path.
        // Absolute: a relative arg (`.`, `..`, `Sources`) would resolve against
        // the process cwd unpredictably and slip past the system guard (#8 verify
        // M1). Non-system: routes through WorkspaceLoader.isSystemPath so `/`,
        // `/Users` (all-users tree), and system roots are refused.
        func acceptable(_ path: String) -> Bool {
            path.hasPrefix("/") && !isSystem(path)
        }
        // 1. Explicit --workspace arg (user's clear intent).
        if let arg = parseWorkspaceArgument(arguments), acceptable(arg) {
            return arg
        }
        // 2. Persisted workspace (current default behavior). Persisted paths
        //    were validated when first opened, so they're trusted as-is.
        if let persisted { return persisted }
        // 3. Guarded cwd fallback — only when no arg + no persisted. cwd=`/`
        //    (GUI launch), `/Users`, and system paths are refused → cannot
        //    re-introduce #2's unintended-large-tree walk.
        if acceptable(cwd) {
            return cwd
        }
        return nil
    }

    /// Extracts the value of `--workspace <path>` / `--workspace=<path>` from
    /// launch arguments. No positional support: macOS injects positional and
    /// `-psn_*` args on GUI launch, which a positional reader would misread (#8 D1).
    /// `nonisolated` (#28): pure, so it sheds the inherited `@MainActor` and is
    /// callable from the nonisolated sync `@Test`s under the strict CI toolchain.
    nonisolated static func parseWorkspaceArgument(_ args: [String]) -> String? {
        var i = 1   // skip arg[0] (binary path)
        while i < args.count {
            let a = args[i]
            if a == "--workspace", i + 1 < args.count {
                return args[i + 1]
            }
            if a.hasPrefix("--workspace=") {
                return String(a.dropFirst("--workspace=".count))
            }
            i += 1
        }
        return nil
    }

    /// Reports whether `path` exists **and is a directory**, evaluated off
    /// MainActor so a slow `stat(2)` (network mount unreachable, iCloud
    /// placeholder, ejected USB) doesn't block the UI thread (#5). The
    /// directory check guards against a persisted path that became a file (#9).
    static func directoryExistsOffMain(_ path: String) async -> Bool {
        await Task.detached(priority: .userInitiated) {
            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
            return exists && isDir.boolValue
        }.value
    }

    private func openWorkspaceViaDialog() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            Task { @MainActor in
                await workspace.openWorkspaceAsync(at: url.path)
            }
        }
    }
}
