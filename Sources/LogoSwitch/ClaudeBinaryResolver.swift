import Foundation

/// Locates the `claude` binary (PsychQuant/logos#33). The discovery half of the
/// old `TerminalConfig` — extracted so it is UI-free and unit-testable, with the
/// app keeping the appearance config + the `--ui-testing` / `--claude-path`
/// launch-arg seams.
///
/// The search PATH is passed IN (callers hand it `LoginShellEnvironment.resolve()
/// ["PATH"]`) so the resolver itself stays a plain `Sendable` value with no
/// main-actor dependency — the login-shell hydration is the caller's concern.
///
/// Resolution order: explicit override → the hydrated PATH → bare `which` (the
/// pre-#33 fallback) → nil (caller surfaces "claude not found" + a manual
/// override). Red line: this only locates a path; it touches no credentials.
public struct ClaudeBinaryResolver: Sendable {

    public init() {}

    /// Resolve the binary path. `path` is the (already-hydrated) colon-separated
    /// search PATH. `isExecutable` / `which` are injectable for tests; production
    /// defaults hit the real filesystem + `/usr/bin/which`.
    public func resolve(
        binary: String = "claude",
        override: String? = nil,
        path: String?,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
        which: (String) -> String? = ClaudeBinaryResolver.systemWhich
    ) -> String? {
        if let override { return override }
        if let found = Self.searchPath(for: binary, in: path, isExecutable: isExecutable) {
            return found
        }
        return which(binary)
    }

    /// Search a colon-separated PATH for an executable named `binary`, honoring
    /// PATH order and skipping empty components. Pure; injectable executable check.
    public static func searchPath(
        for binary: String,
        in path: String?,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String? {
        guard let path, !path.isEmpty else { return nil }
        for dir in path.split(separator: ":") where !dir.isEmpty {
            let candidate = "\(dir)/\(binary)"
            if isExecutable(candidate) { return candidate }
        }
        return nil
    }

    /// `/usr/bin/which <binary>` → the resolved path, or nil. The bare fallback
    /// for when PATH search misses (pre-#33 behavior). Public so it can serve as
    /// `resolve`'s default `which` argument.
    public static func systemWhich(_ binary: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = [binary]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let resolved = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return resolved?.isEmpty == false ? resolved : nil
        } catch {
            return nil
        }
    }
}
