import os

/// `os.Logger` factory for the LogoSwitch module (PsychQuant/logos#34).
///
/// Uses the SAME subsystem as the host app (`app.getlogos.logos`) so existing
/// `log show` / `log stream` predicates keep finding LogoSwitch events — only the
/// category distinguishes them:
///
///     log show --last 5m --predicate 'subsystem == "app.getlogos.logos"'
///
/// LogoSwitch must not depend on the app target, so it cannot reuse the app's
/// `Log` enum — this is the module-local mirror.
///
/// **Privacy (#22):** `os.Logger` redacts interpolated dynamic values by default.
/// Mark `.public` ONLY for non-sensitive scalars (counts, bools, enum cases).
/// Never a credential, token, account id, email, or filesystem path.
enum LogoSwitchLog {
    private static let subsystem = "app.getlogos.logos"

    /// Login-shell environment hydration (#33).
    static let shell = Logger(subsystem: subsystem, category: "logoswitch.shell")
    /// Account model / manager lifecycle (#12/#31).
    static let account = Logger(subsystem: subsystem, category: "logoswitch.account")
    /// claude `auth login/logout/status` invocation (#34).
    static let auth = Logger(subsystem: subsystem, category: "logoswitch.auth")
}
