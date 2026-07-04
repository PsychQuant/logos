import Foundation

/// The per-account claude environment-layering transform (PsychQuant/logos#12/#21).
///
/// Extracted from `ClaudeProcessConfig` so the isolation contract is one pure,
/// directly-testable `[String: String] -> [String: String]` function with no
/// `Account` dependency at its boundary (it takes a `configDir` string). This is
/// the single place that decides what env a per-account claude is spawned with.
///
/// Red line: this only sets env vars. It never reads, writes, or moves a
/// credential — claude itself manages its per-`CLAUDE_CONFIG_DIR` keychain item.
public enum ClaudeConfigEnvironment {

    /// Layer per-account isolation onto `base`. `configDir == nil` ⇒ strip any
    /// inherited config-dir vars so the spawn falls through to the system
    /// `~/.claude` (#54); the `TERM`/`LC_ALL` defaults still apply.
    ///
    /// - Forces `TERM=xterm-256color`; defaults `LC_ALL` to `en_US.UTF-8`.
    /// - When `configDir` is nil (a system-default / non-account spawn), strips
    ///   BOTH `CLAUDE_CONFIG_DIR` and `CLAUDE_SECURESTORAGE_CONFIG_DIR` from the
    ///   base env so claude falls through to the system `~/.claude` rather than a
    ///   stale inherited value (#54). This subsumes the old empty-securestorage
    ///   collapse guard — an empty securestorage value would otherwise revert the
    ///   credential service name to the shared bare entry, defeating isolation (#12).
    /// - When `configDir` is given, sets BOTH `CLAUDE_CONFIG_DIR` and
    ///   `CLAUDE_SECURESTORAGE_CONFIG_DIR` to it (claude resolves the keychain
    ///   service from securestorage first, config dir only as fallback), so creds
    ///   land under `Claude Code-credentials-<hash>` per account.
    /// - **Never** touches `HOME` (#21): macOS resolves the login keychain via
    ///   `$HOME/Library/Keychains/...`; a per-account HOME has no keychain, so
    ///   claude's credential write would fail with the "找不到鑰匙圈" dialog. The
    ///   keychain is per-login-user, so isolation needs only the two
    ///   `CLAUDE_*_CONFIG_DIR` vars — never a per-account HOME.
    public static func apply(base: [String: String], configDir: String?) -> [String: String] {
        var env = base
        env["TERM"] = "xterm-256color"
        env["LC_ALL"] = env["LC_ALL"] ?? "en_US.UTF-8"

        if let configDir {
            env["CLAUDE_CONFIG_DIR"] = configDir
            env["CLAUDE_SECURESTORAGE_CONFIG_DIR"] = configDir
        } else {
            // #54 verify B2: a system-default (main) account — and any non-account
            // spawn — must NOT inherit a stale CLAUDE_CONFIG_DIR /
            // CLAUDE_SECURESTORAGE_CONFIG_DIR from the base (login-shell) env, or it
            // silently pins claude to that dir instead of falling through to the
            // system ~/.claude + the bare `Claude Code-credentials` entry. Stripping
            // both also subsumes the old empty-securestorage collapse guard (#12).
            env.removeValue(forKey: "CLAUDE_CONFIG_DIR")
            env.removeValue(forKey: "CLAUDE_SECURESTORAGE_CONFIG_DIR")
        }
        return env
    }
}
