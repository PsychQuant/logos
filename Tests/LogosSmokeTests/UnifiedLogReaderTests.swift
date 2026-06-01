import Testing
import Foundation

/// Pure-parse coverage for `UnifiedLogReader` (testing-smoke-e2e-strategy, Task
/// 2.1). Runs in any `swift test` — no app launch, no store access. Locks the
/// `log show --style json` field mapping (subsystem / category / messageType /
/// eventMessage) and the other-subsystem filtering the smoke assertions rely on.
@Suite("UnifiedLogReader")
struct UnifiedLogReaderTests {

    /// Shape mirrors a real `log show --style json` array: extra keys present,
    /// one foreign-subsystem record that MUST be filtered out.
    private static let fixture = Data("""
    [
      {
        "subsystem": "app.getlogos.logos",
        "category": "app",
        "messageType": "Default",
        "eventMessage": "launch finished — main scene up",
        "processID": 123,
        "timestamp": "2026-06-01 05:09:52.332"
      },
      {
        "subsystem": "app.getlogos.logos",
        "category": "renderer",
        "messageType": "Error",
        "eventMessage": "Metal renderer unavailable, staying on CoreGraphics: <private>"
      },
      {
        "subsystem": "com.apple.something.else",
        "category": "noise",
        "messageType": "Default",
        "eventMessage": "not ours — must be filtered"
      }
    ]
    """.utf8)

    @Test("parse keeps only our subsystem and maps category/level/message")
    func parseFiltersAndMaps() throws {
        let events = try UnifiedLogReader.parse(json: Self.fixture)

        #expect(events.count == 2)
        #expect(events.allSatisfy { $0.category != "noise" })

        let app = try #require(events.first { $0.category == "app" })
        #expect(app.level == "Default")
        #expect(app.message == "launch finished — main scene up")

        let renderer = try #require(events.first { $0.category == "renderer" })
        #expect(renderer.level == "Error")
        #expect(renderer.message.contains("<private>"))
    }

    @Test("contains matches by category + message fragment")
    func containsHelper() throws {
        let events = try UnifiedLogReader.parse(json: Self.fixture)
        #expect(UnifiedLogReader.contains(events, category: "app", message: "main scene up"))
        #expect(!UnifiedLogReader.contains(events, category: "app", message: "never emitted"))
        #expect(!UnifiedLogReader.contains(events, category: "settings", message: "main scene up"))
    }

    @Test("empty data parses as no events, not a crash")
    func emptyDataIsEmpty() throws {
        #expect(try UnifiedLogReader.parse(json: Data("[]".utf8)).isEmpty)
    }
}
