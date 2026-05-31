import os

/// Centralized `os.Logger` factory for Logos (PsychQuant/logos#22).
///
/// One `Logger` per area under a shared subsystem, so `log stream` / `log show`
/// predicates can filter Logos consistently — no GUI, no TCC:
///
///     log stream --level debug --predicate 'subsystem == "app.getlogos.logos"'
///     log show --last 5m --predicate 'subsystem == "app.getlogos.logos"'
///
/// **Level policy (#22 D2):** lifecycle events use `.notice` — those persist to
/// the unified-log store, so `log show` finds them after the fact. Errors use
/// `.error`; verbose detail uses `.debug` (stream-only, not persisted).
///
/// **Privacy (#22 D3):** `os.Logger` redacts interpolated dynamic values
/// (`<private>`) by default. Mark `privacy: .public` ONLY for clearly
/// non-sensitive scalars (exit codes, bools, enum case names, counts). Never a
/// credential, token, filesystem path, or account id.
public enum Log {
    private static let subsystem = "app.getlogos.logos"

    public static let terminal = Logger(subsystem: subsystem, category: "terminal")
    public static let account = Logger(subsystem: subsystem, category: "account")
    public static let session = Logger(subsystem: subsystem, category: "session")
    public static let renderer = Logger(subsystem: subsystem, category: "renderer")
    public static let settings = Logger(subsystem: subsystem, category: "settings")
    public static let workspace = Logger(subsystem: subsystem, category: "workspace")
}
