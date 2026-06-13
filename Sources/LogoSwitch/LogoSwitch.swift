// LogoSwitch — first-party-safe claude multi-account switching + auth.
//
// LogoSwitch is a LAUNCHER, never a credential manager. It sets per-account
// env (CLAUDE_CONFIG_DIR + CLAUDE_SECURESTORAGE_CONFIG_DIR), spawns claude, and
// invokes claude's OWN `auth login/logout/status` subcommands. It NEVER reads,
// copies, decrypts, moves, overwrites, or refreshes an OAuth token; never
// proxies the OAuth callback; never calls the Anthropic API. claude owns its own
// credentials, written per-CLAUDE_CONFIG_DIR into the login keychain at spawn.
//
// The structural guarantee: this target does not import `Security`, so a
// keychain (SecItem*) call is a compile error. RedLineAuditTests enforces that
// invariant plus the shell-out forms (`/usr/bin/security`, find/add-generic-password).
//
// See PsychQuant/logos#34. The concrete surface (Account, AccountPaths,
// AccountStore, AccountManager, ClaudeConfigEnvironment, ClaudeProcessConfig,
// LoginShellEnvironment, ClaudeBinaryResolver, ProcessRunner, ClaudeAuthInvoker,
// AuthCoordinator, Detectors/…) lands incrementally per #34's staged migration.

/// Namespace marker for the LogoSwitch module. Carries no behavior; the module's
/// real surface is the individual public types listed above.
public enum LogoSwitch {}
