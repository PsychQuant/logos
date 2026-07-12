import Foundation
import Testing
@testable import LogosUsage

@Suite("UsageClient.parse")
struct UsageParseTests {
    /// Mirrors the live `api/oauth/usage` response shape (extra keys included to
    /// prove tolerance). `utilization` is 0–100; `resets_at` carries microsecond
    /// fractional seconds + a `+00:00` offset.
    static let liveShapeJSON = Data(#"""
    {
      "five_hour": {
        "utilization": 24.0,
        "resets_at": "2026-07-02T16:39:59.942822+00:00",
        "limit_dollars": 50.0,
        "remaining_dollars": 38.0,
        "used_dollars": 12.0
      },
      "seven_day": {
        "utilization": 44.0,
        "resets_at": "2026-07-06T00:00:00.000000+00:00",
        "limit_dollars": 200.0,
        "remaining_dollars": 112.0,
        "used_dollars": 88.0
      },
      "limits": [{"kind": "five_hour", "percent": 24, "is_active": true}],
      "spend": {"amount": 12.0},
      "member_dashboard_available": true
    }
    """#.utf8)

    @Test("decodes both windows with correct utilization and remaining")
    func decodesWindows() throws {
        let usage = try #require(UsageClient.parse(Self.liveShapeJSON))
        #expect(usage.windows.count == 2)

        let session = try #require(usage.windows.first { $0.id == "five_hour" })
        #expect(session.utilization == 24.0)
        #expect(session.percentRemaining == 76.0)
        #expect(session.resetsAt != nil)

        let weekly = try #require(usage.windows.first { $0.id == "seven_day" })
        #expect(weekly.utilization == 44.0)
        #expect(weekly.percentRemaining == 56.0)
    }

    @Test("windows are ordered session-first, then weekly")
    func windowOrder() throws {
        let usage = try #require(UsageClient.parse(Self.liveShapeJSON))
        #expect(usage.windows.map(\.id) == ["five_hour", "seven_day"])
    }

    /// #94: the per-model weekly window ("Current week (Fable)") lives ONLY in the `limits`
    /// array's `weekly_scoped` entry — the flat `seven_day_<model>` fields are null on the live
    /// endpoint. Mirrors the real shape: session + weekly_all + a weekly_scoped(Fable) limit.
    static let perModelJSON = Data(#"""
    {
      "five_hour": {"utilization": 72.0, "resets_at": "2026-07-12T09:10:00.494222+00:00"},
      "seven_day": {"utilization": 52.0, "resets_at": "2026-07-15T03:00:00.494247+00:00"},
      "seven_day_opus": null,
      "seven_day_sonnet": null,
      "limits": [
        {"kind": "session", "group": "session", "percent": 72, "is_active": true},
        {"kind": "weekly_all", "group": "weekly", "percent": 52, "is_active": false},
        {"kind": "weekly_scoped", "group": "weekly", "percent": 70,
         "resets_at": "2026-07-15T03:00:00.494582+00:00",
         "scope": {"model": {"display_name": "Fable"}}, "is_active": false}
      ]
    }
    """#.utf8)

    @Test("a per-model weekly_scoped limit becomes its own window, after the flat windows")
    func perModelWeeklyFromLimits() throws {
        let usage = try #require(UsageClient.parse(Self.perModelJSON))
        // five_hour + seven_day from the flat fields, then the ONE scoped window. The session /
        // weekly_all limits are NOT re-added (they'd double-count the flat windows).
        #expect(usage.windows.map(\.id) == ["five_hour", "seven_day", "weekly_scoped:Fable"])

        let fable = try #require(usage.windows.first { $0.id == "weekly_scoped:Fable" })
        #expect(fable.utilization == 70.0)
        #expect(fable.label == "每週（Fable）")
        #expect(fable.resetsAt != nil)
    }

    @Test("a weekly_scoped limit with no model scope is skipped (not a nameless window)")
    func scopedWithoutModelSkipped() throws {
        let json = Data(#"""
        {"five_hour": {"utilization": 10.0},
         "limits": [{"kind": "weekly_scoped", "percent": 88, "scope": {"model": {"display_name": null}}}]}
        """#.utf8)
        let usage = try #require(UsageClient.parse(json))
        #expect(usage.windows.map(\.id) == ["five_hour"])
    }

    @Test("valid JSON object with no known windows yields empty, not nil")
    func emptyObjectTolerated() throws {
        let usage = try #require(UsageClient.parse(Data("{}".utf8)))
        #expect(usage.windows.isEmpty)
    }

    @Test("a single present window still decodes")
    func partialResponse() throws {
        let json = Data(#"{"seven_day": {"utilization": 10.0}}"#.utf8)
        let usage = try #require(UsageClient.parse(json))
        #expect(usage.windows.map(\.id) == ["seven_day"])
        #expect(usage.windows.first?.percentRemaining == 90.0)
    }

    @Test("a type-drifted window does not sink its valid sibling")
    func driftedWindowDoesNotSinkSibling() throws {
        // five_hour.utilization drifted to a String; seven_day is valid. The
        // drifted window must drop out on its own, leaving the sibling intact —
        // not fail the entire response.
        let json = Data(#"""
        {
          "five_hour": {"utilization": "twenty-four"},
          "seven_day": {"utilization": 44.0}
        }
        """#.utf8)
        let usage = try #require(UsageClient.parse(json))
        #expect(usage.windows.map(\.id) == ["seven_day"])
        #expect(usage.windows.first?.utilization == 44.0)
    }

    @Test("both windows drifted → valid-but-empty parse, not nil")
    func bothWindowsDriftedYieldsEmpty() throws {
        // A well-formed JSON object whose windows are both type-drifted is a
        // valid (empty) parse — distinct from a non-object body, which stays nil.
        let json = Data(#"""
        {
          "five_hour": {"utilization": "nope"},
          "seven_day": {"utilization": "nope"}
        }
        """#.utf8)
        let usage = try #require(UsageClient.parse(json))
        #expect(usage.windows.isEmpty)
    }

    @Test("a drifted resets_at does not sink the window's valid utilization")
    func driftedResetsAtKeepsUtilization() throws {
        // resets_at drifted to a number; utilization is the only load-bearing
        // field, so the window survives with a nil reset date.
        let json = Data(#"{"five_hour": {"utilization": 24.0, "resets_at": 12345}}"#.utf8)
        let usage = try #require(UsageClient.parse(json))
        let window = try #require(usage.windows.first { $0.id == "five_hour" })
        #expect(window.utilization == 24.0)
        #expect(window.resetsAt == nil)
    }

    @Test("non-JSON body yields nil")
    func malformedYieldsNil() {
        #expect(UsageClient.parse(Data("not json at all".utf8)) == nil)
    }

    @Test("percentRemaining clamps out-of-range utilization")
    func remainingClamps() {
        #expect(UsageWindow(id: "x", label: "x", utilization: 130).percentRemaining == 0)
        #expect(UsageWindow(id: "x", label: "x", utilization: -5).percentRemaining == 100)
    }

    // MARK: date parsing

    @Test("parses ISO8601 with microsecond fractional seconds and offset")
    func parsesMicrosecondDate() {
        #expect(UsageClient.parseDate("2026-07-02T16:39:59.942822+00:00") != nil)
    }

    @Test("parses ISO8601 without fractional seconds")
    func parsesPlainDate() {
        #expect(UsageClient.parseDate("2026-07-02T16:39:59+00:00") != nil)
    }

    @Test("unparseable date string yields nil")
    func badDate() {
        #expect(UsageClient.parseDate("yesterday") == nil)
    }
}

@Suite("LiveUsageFetcher redirect policy")
struct RedirectPolicyTests {
    private func authorizedRequest(url: String) -> URLRequest {
        var request = URLRequest(url: URL(string: url)!)
        request.setValue("Bearer secret", forHTTPHeaderField: "Authorization")
        return request
    }

    @Test("a same-host redirect keeps the Authorization header")
    func sameHostKeepsToken() {
        let proposed = authorizedRequest(url: "https://api.anthropic.com/api/oauth/usage?page=2")
        let result = LiveUsageFetcher.sanitizedRedirect(proposed)
        #expect(result.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
    }

    @Test("a cross-host redirect strips the Authorization header so the token cannot leak")
    func crossHostStripsToken() {
        let proposed = authorizedRequest(url: "https://evil.example.com/collect")
        let result = LiveUsageFetcher.sanitizedRedirect(proposed)
        #expect(result.value(forHTTPHeaderField: "Authorization") == nil)
    }
}

/// Canned async fetcher: returns a fixed body + status, or throws a transport error.
private struct StubFetcher: UsageFetching {
    var body: Data = Data()
    var status: Int = 200
    var throwsTransport = false

    func fetch(accessToken: String) async throws -> (Data, Int) {
        if throwsTransport { throw URLError(.notConnectedToInternet) }
        return (body, status)
    }
}

@Suite("UsageClient.fetchUsage")
struct UsageFetchTests {
    @Test("200 with a valid body returns PlanUsage")
    func success() async throws {
        let client = UsageClient(fetcher: StubFetcher(body: UsageParseTests.liveShapeJSON, status: 200))
        let usage = try await client.fetchUsage(accessToken: "tok")
        #expect(usage.windows.count == 2)
    }

    @Test("401 maps to .unauthorized")
    func unauthorized() async {
        let client = UsageClient(fetcher: StubFetcher(status: 401))
        await #expect(throws: UsageError.unauthorized) {
            try await client.fetchUsage(accessToken: "tok")
        }
    }

    @Test("500 maps to .http(500)")
    func serverError() async {
        let client = UsageClient(fetcher: StubFetcher(status: 500))
        await #expect(throws: UsageError.http(500)) {
            try await client.fetchUsage(accessToken: "tok")
        }
    }

    @Test("200 with an undecodable body maps to .malformed")
    func malformedBody() async {
        let client = UsageClient(fetcher: StubFetcher(body: Data("not json".utf8), status: 200))
        await #expect(throws: UsageError.malformed) {
            try await client.fetchUsage(accessToken: "tok")
        }
    }

    @Test("transport failure maps to .transport")
    func transportFailure() async {
        let client = UsageClient(fetcher: StubFetcher(throwsTransport: true))
        await #expect(throws: (any Error).self) {
            try await client.fetchUsage(accessToken: "tok")
        }
    }
}
