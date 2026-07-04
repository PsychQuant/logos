import Foundation

/// Failure modes when fetching plan usage. `unauthorized` (401) is called out
/// separately so the UI can show a "needs re-login" state instead of a generic
/// error — the token is expired and MultiStats deliberately does not refresh it.
public enum UsageError: Error, Equatable {
    case unauthorized
    case http(Int)
    case malformed
    case transport(String)
}

/// Abstracts the network call so tests can inject canned responses without a
/// live endpoint or real token.
public protocol UsageFetching: Sendable {
    /// Performs the usage GET and returns the raw body plus HTTP status code.
    func fetch(accessToken: String) async throws -> (Data, Int)
}

/// Live fetcher hitting the undocumented `api/oauth/usage` endpoint that Claude
/// Code itself uses. Headers mirror the client: OAuth bearer token + the
/// `oauth-2025-04-20` beta flag. No official public API exists for this.
public struct LiveUsageFetcher: UsageFetching {
    static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private let session: URLSession

    public init(session: URLSession = .shared) { self.session = session }

    public func fetch(accessToken: String) async throws -> (Data, Int) {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
        return (data, code)
    }
}

/// Fetches and decodes plan usage for one account's access token.
public struct UsageClient: Sendable {
    private let fetcher: UsageFetching

    public init(fetcher: UsageFetching = LiveUsageFetcher()) { self.fetcher = fetcher }

    public func fetchUsage(accessToken: String) async throws -> PlanUsage {
        let data: Data
        let code: Int
        do {
            (data, code) = try await fetcher.fetch(accessToken: accessToken)
        } catch {
            throw UsageError.transport(String(describing: error))
        }

        switch code {
        case 200: break
        case 401: throw UsageError.unauthorized
        default: throw UsageError.http(code)
        }

        guard let usage = Self.parse(data) else { throw UsageError.malformed }
        return usage
    }

    /// Version-tolerant decode of the usage response. Returns nil only when the
    /// body is not a decodable JSON object; a valid object with no recognized
    /// windows yields `PlanUsage(windows: [])`.
    static func parse(_ data: Data) -> PlanUsage? {
        struct Response: Decodable {
            struct Window: Decodable {
                let utilization: Double?
                let resets_at: String?
                let limit_dollars: Double?
                let remaining_dollars: Double?
            }
            let five_hour: Window?
            let seven_day: Window?
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else { return nil }

        var windows: [UsageWindow] = []
        func append(_ window: Response.Window?, id: String, label: String) {
            guard let window, let utilization = window.utilization else { return }
            windows.append(UsageWindow(
                id: id,
                label: label,
                utilization: utilization,
                resetsAt: window.resets_at.flatMap(parseDate),
                limitDollars: window.limit_dollars,
                remainingDollars: window.remaining_dollars))
        }
        append(response.five_hour, id: "five_hour", label: "工作階段（5 小時）")
        append(response.seven_day, id: "seven_day", label: "每週（7 天）")
        return PlanUsage(windows: windows)
    }

    /// Parses the endpoint's ISO8601 `resets_at` (microsecond fractional +
    /// offset). Returns nil rather than throwing so a bad date never sinks the
    /// whole window.
    static func parseDate(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        // The endpoint emits microsecond fractional seconds, which
        // ISO8601DateFormatter rejects. Strip the fraction and retry.
        let stripped = string.replacingOccurrences(
            of: #"\.\d+"#, with: "", options: .regularExpression)
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: stripped)
    }
}
