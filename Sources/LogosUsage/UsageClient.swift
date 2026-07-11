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
        // A per-task delegate strips the bearer token on a cross-host redirect.
        // `URLSession.shared` ignores a session-level delegate but honors the
        // per-task one (macOS 12+), so the default session is kept.
        let (data, response) = try await session.data(for: request, delegate: RedirectSanitizer())
        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
        return (data, code)
    }

    /// Redirect policy for the token-bearing usage request. A same-host redirect
    /// follows unchanged; a cross-host redirect follows with the `Authorization`
    /// header stripped, so the OAuth bearer never crosses to another origin.
    /// Pure and Foundation-only — unit-tested without a live redirect server.
    static func sanitizedRedirect(_ proposed: URLRequest) -> URLRequest {
        guard proposed.url?.host == endpoint.host else {
            var stripped = proposed
            stripped.setValue(nil, forHTTPHeaderField: "Authorization")
            return stripped
        }
        return proposed
    }
}

/// Per-task URLSession delegate that routes every redirect through
/// `LiveUsageFetcher.sanitizedRedirect`, dropping the Authorization header on any
/// cross-host hop. Stateless, hence safely `Sendable`.
private final class RedirectSanitizer: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(LiveUsageFetcher.sanitizedRedirect(request))
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
            /// One usage window. `utilization` is the only load-bearing field; a
            /// type-drift there invalidates the window (it becomes nil at the
            /// `Response` level). `resets_at` is decoded leniently so a drifted
            /// date never sinks a valid utilization.
            struct Window: Decodable {
                let utilization: Double?
                let resets_at: String?

                private enum CodingKeys: String, CodingKey {
                    case utilization
                    case resets_at
                }

                init(from decoder: Decoder) throws {
                    let container = try decoder.container(keyedBy: CodingKeys.self)
                    utilization = try container.decodeIfPresent(Double.self, forKey: .utilization)
                    resets_at = try? container.decodeIfPresent(String.self, forKey: .resets_at)
                }
            }
            let five_hour: Window?
            let seven_day: Window?

            private enum CodingKeys: String, CodingKey {
                case five_hour
                case seven_day
            }

            /// Per-window lenient decode: a type-drift inside one window nils that
            /// window instead of throwing and sinking the sibling's valid data. The
            /// top-level container is still required — a non-object body throws
            /// here, propagates through the caller's `try?`, and stays `.malformed`.
            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                five_hour = try? container.decodeIfPresent(Window.self, forKey: .five_hour)
                seven_day = try? container.decodeIfPresent(Window.self, forKey: .seven_day)
            }
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else { return nil }

        var windows: [UsageWindow] = []
        func append(_ window: Response.Window?, id: String, label: String) {
            guard let window, let utilization = window.utilization else { return }
            windows.append(UsageWindow(
                id: id,
                label: label,
                utilization: utilization,
                resetsAt: window.resets_at.flatMap(parseDate)))
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
