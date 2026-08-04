import Foundation

/// #113: the only authoritative source for a claude session's context window.
///
/// **Why this exists at all.** Enumerating every subcommand of the CLI (2.1.221) confirmed
/// there is no read-only way to ask a session how large its window is: `claude config`,
/// `claude models` and `claude status` do not exist; `claude doctor` and `claude auth status`
/// carry no such field; and `claude agents --json` — the one command that lists *other*
/// sessions from outside — deliberately carries no model, usage or context field.
///
/// Nor is it on disk. An exhaustive search of the account config dir found the `[1m]` strings
/// only in **static catalogs** (a per-model severity table, the model-picker menu cache), never
/// as per-session state; `orgModelDefaultCache` and `autoCompactWindowsCache` were null across
/// an hour of rotating backups; and a *structural* scan of 922 transcript records (matching key
/// paths, not string contents) found **zero** context-window fields.
///
/// The number exists in exactly one place: data the running session **pushes** to a configured
/// `statusLine` command, as `context_window.context_window_size` — 200000 or 1000000. So Logos
/// configures such a command and reads what the session tells it.
///
/// **Where this may write, and where it may not.** Installing means writing a claude settings
/// file, which is a boundary Logos had not crossed before (it previously only read claude's
/// artifacts and injected process env). The line drawn is ownership, not convenience:
///
/// - **Isolated accounts** — Logos created these config dirs itself, so configuring one is
///   configuring our own provisioning, not editing the user's personal setup.
/// - **The system-default ("Main") account** — that is the user's own `~/.claude`. Logos does
///   not write there (#54 already forbids it for the gateway, for the same reason). Main keeps
///   the inference ladder, and reads its window late rather than wrongly.
///
/// Within an owned dir the write is still conservative: an existing `statusLine` the user
/// configured is **never** replaced, an unparseable settings file is left verbatim rather than
/// rewritten, and every unrelated key survives.
enum StatusLineChannel {

    /// What an install attempt did — surfaced rather than swallowed, so a declined install can
    /// be explained instead of looking like a silent failure.
    enum InstallOutcome: Equatable {
        case installed
        case alreadyInstalled
        /// The user has their own statusLine. Theirs wins; we read nothing.
        case declinedForeignStatusLine
        /// settings.json exists but is not readable JSON — left untouched.
        case declinedUnreadableSettings
        case failed(String)
    }

    /// Marks a `statusLine` entry as ours, so re-install is idempotent and uninstall can tell
    /// our command apart from one the user wrote.
    private static let ownerMarker = "app.getlogos.logos"
    private static let settingsFilename = "settings.json"
    private static let helperFilename = "logos-statusline.sh"
    private static let reportFilename = "logos-statusline.json"

    /// Where the helper drops what the session pushed. Inside the account's own config dir, so
    /// `AccountReaper` removes it with the account and no new cleanup path is needed — the same
    /// placement decision the per-account gateway made for its state.
    static func reportPath(inConfigDir configDir: String) -> String {
        "\(configDir)/\(reportFilename)"
    }

    static func helperPath(inConfigDir configDir: String) -> String {
        "\(configDir)/\(helperFilename)"
    }

    /// The helper claude runs each turn. It captures the pushed JSON and prints **nothing**:
    /// this is a data channel, not a second status bar. Logos already renders the readout, and
    /// emitting text here would insert a row into the user's terminal that they never asked for.
    private static func helperScript(reportPath: String) -> String {
        """
        #!/bin/sh
        # Installed by Logos (#113) — captures the context-window size claude pushes to
        # statusLine, which is the only place that number is observable from outside the
        # session. Prints nothing on purpose: Logos renders the readout in its own status
        # bar, so emitting text here would add an unrequested row to the terminal.
        # Remove the "statusLine" key from this account's settings.json to disable.
        cat > '\(reportPath).tmp' 2>/dev/null && mv -f '\(reportPath).tmp' '\(reportPath)' 2>/dev/null
        exit 0
        """
    }

    /// Configure this account's claude to report its context window.
    ///
    /// Idempotent and safe to call on every window open. **Never** call for the system-default
    /// account — see the type doc.
    @discardableResult
    static func install(inConfigDir configDir: String) -> InstallOutcome {
        let settingsURL = URL(fileURLWithPath: "\(configDir)/\(settingsFilename)")
        var settings: [String: Any] = [:]

        if let data = try? Data(contentsOf: settingsURL) {
            guard let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                // Do not rewrite a file we could not read — that would destroy whatever the
                // user has there, which is a far worse outcome than not reading a window size.
                return .declinedUnreadableSettings
            }
            settings = parsed

            if let existing = settings["statusLine"] as? [String: Any] {
                guard existing["_owner"] as? String == ownerMarker else {
                    return .declinedForeignStatusLine
                }
                if existing["command"] as? String == helperPath(inConfigDir: configDir),
                   FileManager.default.isExecutableFile(atPath: helperPath(inConfigDir: configDir)) {
                    return .alreadyInstalled
                }
            }
        }

        do {
            try FileManager.default.createDirectory(
                atPath: configDir, withIntermediateDirectories: true)
            let helper = helperPath(inConfigDir: configDir)
            try helperScript(reportPath: reportPath(inConfigDir: configDir))
                .write(toFile: helper, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: helper)

            settings["statusLine"] = [
                "type": "command",
                "command": helper,
                // Our marker. Its presence is what makes re-install idempotent and lets
                // uninstall leave a user's own command alone.
                "_owner": ownerMarker,
            ]
            let data = try JSONSerialization.data(
                withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: settingsURL, options: .atomic)
            return .installed
        } catch {
            return .failed(String(describing: error))
        }
    }

    /// Remove our command, leaving everything else — including a `statusLine` the user wrote
    /// themselves — untouched.
    static func uninstall(inConfigDir configDir: String) {
        let settingsURL = URL(fileURLWithPath: "\(configDir)/\(settingsFilename)")
        guard let data = try? Data(contentsOf: settingsURL),
              var settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let existing = settings["statusLine"] as? [String: Any],
              existing["_owner"] as? String == ownerMarker
        else { return }

        settings["statusLine"] = nil
        if let out = try? JSONSerialization.data(
            withJSONObject: settings, options: [.prettyPrinted, .sortedKeys]) {
            try? out.write(to: settingsURL, options: .atomic)
        }
        try? FileManager.default.removeItem(atPath: helperPath(inConfigDir: configDir))
        try? FileManager.default.removeItem(atPath: reportPath(inConfigDir: configDir))
    }

    /// The context window the session most recently reported, or `nil` when it has not reported
    /// one yet (fresh session, channel not installed, or a payload we could not read).
    ///
    /// A non-positive size is treated as no signal rather than displayed — the same refusal to
    /// render a nonsensical number that #110 established for the usage bars.
    static func reportedContextWindow(inConfigDir configDir: String) -> Int? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: reportPath(inConfigDir: configDir))),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let window = obj["context_window"] as? [String: Any],
              let size = window["context_window_size"] as? Int,
              size > 0
        else { return nil }
        return size
    }
}
