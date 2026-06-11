import Foundation

/// Resolves the user's REAL environment by running their login shell once and
/// capturing its `env` dump (PsychQuant/logos#33).
///
/// Why: a Finder/Spotlight launch hands a GUI app the bare launchd environment
/// (PATH = /usr/bin:/bin:/usr/sbin:/sbin — no homebrew, no ~/.local/bin), so
/// claude can't be found and any child process runs in an impoverished env. A
/// real terminal (Ghostty/Terminal.app) spawns `$SHELL -l`, sourcing the user's
/// profile first — this resolver reproduces that (the same pattern VS Code's
/// shell-env / fix-path use): run `$SHELL -ilc` once, dump `/usr/bin/env -0`
/// between sentinels, parse, cache for the rest of the launch.
///
/// `-il` (interactive + login), not just `-l`: macOS zsh setups commonly add
/// PATH entries in `~/.zshrc`, which only an interactive shell sources. The
/// interactive shell is why the hang guards exist (stdin=/dev/null + watchdog
/// timeout) — a profile that waits for input must never wedge Logos.
///
/// Failure is always graceful: any spawn/timeout/parse problem falls back to
/// the process's own environment (today's behavior — no regression).
@MainActor
public enum LoginShellEnvironment {

    /// Markers around the env dump so profile stdout noise (motd, echoes from
    /// ~/.zshrc) is never parsed as environment entries. First BEGIN + last END
    /// win, so noise containing the marker text can't truncate the region.
    nonisolated static let beginSentinel = "__LOGOS_ENV_BEGIN__"
    nonisolated static let endSentinel = "__LOGOS_ENV_END__"

    /// Hard bound on the shell spawn (a hung interactive profile must not block
    /// the app for more than this; normal dumps take ~100-300 ms). The first
    /// `resolve()` call may block the main actor for at most this long — after
    /// that the cached result is free.
    nonisolated static let timeout: TimeInterval = 3.0

    /// Cached once per launch — the login env doesn't change mid-session, and
    /// caching keeps restarts (#18) from re-spawning a shell.
    private static var cached: [String: String]?

    /// Injectable for tests (canned dumps; counts invocations). Production
    /// value spawns the real shell.
    static var dumpProvider: (_ shell: String, _ timeout: TimeInterval) -> Data? = runLoginShellDump

    /// The user's login-shell environment, hydrated once and cached. Falls back
    /// to `processEnvironment` (the launchd env) whenever the shell dump fails,
    /// times out, or parses to nothing — never returns an *emptier* env than
    /// the caller already had.
    public static func resolve(
        processEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        if let cached { return cached }
        let shell = processEnvironment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        let result: [String: String]
        if let raw = dumpProvider(shell, timeout),
           let parsed = parse(raw),
           !parsed.isEmpty {
            result = parsed
            // Lifecycle marker (#22): hydration succeeded — count only (env
            // contents carry usernames/paths, never logged).
            Log.terminal.notice("login-shell environment hydrated — vars=\(parsed.count, privacy: .public)")
        } else {
            result = processEnvironment
            Log.terminal.notice("login-shell environment hydration failed — falling back to process env (#33)")
        }
        cached = result
        return result
    }

    /// Parse a raw dump: bytes between the first BEGIN and last END sentinel,
    /// split on NUL (`/usr/bin/env -0`) into `KEY=VALUE` entries — the NUL
    /// delimiter is what lets values contain newlines. Splits on the FIRST `=`
    /// only (values commonly contain `=`). Returns nil when the sentinels are
    /// missing/misordered (shell never ran our command).
    nonisolated static func parse(_ raw: Data) -> [String: String]? {
        guard let begin = raw.range(of: Data(beginSentinel.utf8)),
              let end = raw.range(of: Data(endSentinel.utf8), options: .backwards),
              begin.upperBound <= end.lowerBound else { return nil }
        var region = raw.subdata(in: begin.upperBound..<end.lowerBound)
        // `echo BEGIN` terminates with a newline that precedes the first entry.
        if region.first == UInt8(ascii: "\n") { region.removeFirst() }

        var env: [String: String] = [:]
        for chunk in region.split(separator: 0) {
            guard let entry = String(data: Data(chunk), encoding: .utf8),
                  let eq = entry.firstIndex(of: "=") else { continue }
            let key = String(entry[..<eq])
            guard !key.isEmpty else { continue }
            env[key] = String(entry[entry.index(after: eq)...])
        }
        return env
    }

    /// Spawn the user's shell and capture the sentinel-delimited env dump.
    /// stdin is /dev/null (an interactive profile waiting on input gets EOF)
    /// and a watchdog terminates the shell at `timeout` — `readDataToEndOfFile`
    /// then returns because the pipe closes. A terminated shell exits non-zero
    /// → nil → caller falls back.
    nonisolated private static func runLoginShellDump(shell: String, timeout: TimeInterval) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-ilc", "echo \(beginSentinel); /usr/bin/env -0; echo \(endSentinel)"]
        process.standardInput = FileHandle.nullDevice
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()   // discard profile stderr noise

        do { try process.run() } catch { return nil }

        // Process is documented thread-safe for terminate(); the unsafe capture
        // only crosses to the watchdog queue.
        nonisolated(unsafe) let proc = process
        let watchdog = DispatchWorkItem { if proc.isRunning { proc.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)

        // Blocks until the write end closes (normal exit or watchdog terminate)
        // — reading BEFORE waitUntilExit avoids the full-pipe deadlock.
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()

        guard process.terminationStatus == 0 else { return nil }
        return data
    }

    /// Test hook: clear the cache + restore the real dump provider.
    static func _resetForTesting() {
        cached = nil
        dumpProvider = runLoginShellDump
    }
}
