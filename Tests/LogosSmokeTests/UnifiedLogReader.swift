import Foundation

/// Reads Logos lifecycle events from the macOS unified-log store for headless
/// smoke / E2E assertions (testing-smoke-e2e-strategy, Track A).
///
/// Turns the os.Logger trail that #22 established into something a test can
/// assert against — no GUI, no TCC, no pixels. The single adapter over the
/// `log` CLI; nothing else in the smoke layer shells out to it.
enum UnifiedLogReader {

    static let subsystem = "app.getlogos.logos"

    /// One lifecycle record from the store. `level` mirrors `log`'s
    /// `messageType` ("Default" for `.notice`, "Error" for `.error").
    struct Event: Equatable {
        let category: String
        let level: String
        let message: String
    }

    /// Pure decode of `log show --style json` output into our subsystem's
    /// events. Records from other subsystems are filtered out. Separated from
    /// the shell-out below so it is unit-testable without the real store.
    static func parse(json data: Data) throws -> [Event] {
        let records = try JSONDecoder().decode([Record].self, from: data)
        return records
            .filter { $0.subsystem == subsystem }
            .map { Event(
                category: $0.category ?? "",
                level: $0.messageType ?? "",
                message: $0.eventMessage ?? ""
            ) }
    }

    /// Query the store for this subsystem's events emitted since `start`,
    /// polling until `satisfied` returns true or `timeout` elapses. Returns the
    /// most recent snapshot of events (empty if the store yields nothing).
    ///
    /// Uses the ABSOLUTE `/usr/bin/log` path deliberately: in the project shell
    /// `log` resolves to a builtin that shadows the binary and returns nothing,
    /// which would make every assertion silently pass-as-empty.
    static func waitForEvents(
        since start: Date,
        timeout: TimeInterval,
        pollInterval: TimeInterval = 1.0,
        satisfied: ([Event]) -> Bool
    ) -> [Event] {
        let deadline = Date().addingTimeInterval(timeout)
        var latest: [Event] = []
        repeat {
            latest = (try? parse(json: runLogShow(since: start))) ?? []
            if satisfied(latest) { return latest }
            Thread.sleep(forTimeInterval: pollInterval)
        } while Date() < deadline
        return latest
    }

    /// Convenience: do the captured events contain a record in `category` whose
    /// message contains `fragment`?
    static func contains(_ events: [Event], category: String, message fragment: String) -> Bool {
        events.contains { $0.category == category && $0.message.contains(fragment) }
    }

    // MARK: - Shell-out

    private static func runLogShow(since start: Date) -> Data {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        process.arguments = [
            "show",
            "--style", "json",
            "--predicate", "subsystem == \"\(subsystem)\"",
            "--start", formatter.string(from: start)
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return data
        } catch {
            return Data()
        }
    }

    private struct Record: Decodable {
        let subsystem: String?
        let category: String?
        let messageType: String?
        let eventMessage: String?
    }
}
