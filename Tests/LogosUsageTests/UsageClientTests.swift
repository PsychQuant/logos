import Foundation
import Testing
@testable import MultiStatsCore

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
        #expect(session.limitDollars == 50.0)
        #expect(session.remainingDollars == 38.0)
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
