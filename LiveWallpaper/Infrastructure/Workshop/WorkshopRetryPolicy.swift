#if !LITE_BUILD
import Foundation
import LiveWallpaperCore

/// Bounded retry for the Workshop request paths (keyed `QueryFiles`, the
/// keyless browse page and its `GetPublishedFileDetails` batch), plus the
/// per-host cooldown a 429 imposes on every later request to that host.
///
/// `run` retries transport failures and 429/5xx responses; anything else
/// (401/403 in particular — Valve's body says "Retrying will not help") comes
/// back to the caller untouched. A 429 whose `Retry-After` exceeds
/// `maxAcceptableWait` is surfaced at once as `.rateLimited(retryAfter:)` so
/// the UI can show the remaining seconds instead of hanging on a sleep.
actor WorkshopRetryPolicy {
    typealias Response = (data: Data, http: HTTPURLResponse)

    static let maxAttempts = 3
    static let maxAcceptableWait: TimeInterval = 15
    /// Budget for the sleeps of one `run` (cooldown waits and backoff delays).
    /// Request time does not count: a 20 s timeout would otherwise consume the
    /// budget and cancel the one retry it earned.
    static let totalBudget: TimeInterval = 10
    /// Steam sends most 429s without a `Retry-After`; the host is cooled down
    /// for this long instead. A local, conservative guess, not a measured value.
    static let assumedCooldown: TimeInterval = 5
    /// A `Retry-After` past a day is a malformed header, not a wait.
    private static let maxRetryAfter: TimeInterval = 86400
    private static let retryableStatuses: Set<Int> = [500, 502, 503, 504]

    private let now: @Sendable () -> Date
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    /// Earliest time the host may be contacted again, from the last 429.
    private var notBefore: [String: Date] = [:]

    init(
        now: @escaping @Sendable () -> Date = Date.init,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }
    ) {
        self.now = now
        self.sleep = sleep
    }

    /// `attempt` throws `URLError` for transport failures and returns whatever
    /// HTTP response it got; any other error it throws ends the run as is.
    /// Returns the last response (5xx included, so the caller's status switch
    /// decides the error), throws the last `URLError`, or throws
    /// `WorkshopQueryError.rateLimited` when a 429 cannot be waited out.
    func run(host: String, _ attempt: @Sendable () async throws -> Response) async throws -> Response {
        var slept: TimeInterval = 0
        for index in 0 ..< Self.maxAttempts {
            try Task.checkCancellation()
            slept += try await waitForCooldown(host: host, slept: slept)
            let isLast = index == Self.maxAttempts - 1

            let response: Response
            do {
                response = try await attempt()
            } catch let error as URLError {
                guard !isLast, Self.isRetryable(error.code, attemptIndex: index) else { throw error }
                guard let delay = try await backOff(attemptIndex: index, slept: slept) else { throw error }
                slept += delay
                continue
            }

            let status = response.http.statusCode
            if status == 429 {
                let retryAfter = retryAfter(from: response.http)
                notBefore[host] = max(
                    notBefore[host] ?? .distantPast,
                    now().addingTimeInterval(retryAfter ?? Self.assumedCooldown)
                )
                guard !isLast, (retryAfter ?? 0) <= Self.maxAcceptableWait else {
                    throw WorkshopQueryError.rateLimited(retryAfter: retryAfter)
                }
                // The cooldown check at the top of the next iteration is the wait.
                continue
            }
            if Self.retryableStatuses.contains(status), !isLast {
                guard let delay = try await backOff(attemptIndex: index, slept: slept) else { return response }
                slept += delay
                continue
            }
            return response
        }
        preconditionFailure("run exits from inside the loop")
    }

    /// Seconds or an HTTP-date (RFC 1123); anything else — a negative,
    /// non-finite or over-a-day value included — reads as no header.
    nonisolated func retryAfter(from response: HTTPURLResponse) -> TimeInterval? {
        guard let raw = response.value(forHTTPHeaderField: "Retry-After")?
            .trimmingCharacters(in: .whitespaces)
        else { return nil }
        let seconds: TimeInterval
        if let number = TimeInterval(raw) {
            seconds = number
        } else {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "GMT")
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            guard let date = formatter.date(from: raw) else { return nil }
            seconds = max(0, date.timeIntervalSince(now()))
        }
        // `contains` is false for NaN and infinity as well.
        guard (0 ... Self.maxRetryAfter).contains(seconds) else { return nil }
        return seconds
    }

    /// Returns the time slept. `slept` is what this run has slept so far: the
    /// cooldown wait draws on the same budget as the backoff delays.
    private func waitForCooldown(host: String, slept sleptBefore: TimeInterval) async throws -> TimeInterval {
        var slept: TimeInterval = 0
        while let until = notBefore[host] {
            let remaining = until.timeIntervalSince(now())
            guard remaining > 0 else {
                notBefore[host] = nil
                break
            }
            guard sleptBefore + slept + remaining <= Self.totalBudget else {
                throw WorkshopQueryError.rateLimited(retryAfter: remaining)
            }
            try await sleep(remaining)
            slept += remaining
            // Another run's 429 may have pushed the deadline out while this
            // one slept; only an unchanged deadline has been waited out.
            if notBefore[host] == until {
                break
            }
        }
        return slept
    }

    /// The delay slept, or nil when it would overrun `totalBudget`; the caller then gives up.
    private func backOff(attemptIndex: Int, slept: TimeInterval) async throws -> TimeInterval? {
        let delay = 0.5 * pow(2, Double(attemptIndex)) * Double.random(in: 0.75 ... 1.25)
        guard slept + delay <= Self.totalBudget else { return nil }
        Logger.debug("Workshop request retry scheduled after \(delay) s", category: .workshop)
        try await sleep(delay)
        return delay
    }

    private static func isRetryable(_ code: URLError.Code, attemptIndex: Int) -> Bool {
        switch code {
        case .timedOut, .networkConnectionLost, .cannotConnectToHost, .dnsLookupFailed:
            true
        // Once: a second attempt covers a flapping interface, a third only delays the message.
        case .notConnectedToInternet:
            attemptIndex == 0
        default:
            false
        }
    }
}
#endif
