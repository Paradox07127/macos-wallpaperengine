#if !LITE_BUILD
import Foundation
@testable import LiveWallpaper
import Testing

/// Virtual clock for `WorkshopRetryPolicy`: `now` moves only when a test (or,
/// when `advancesOnSleep`, a recorded sleep) moves it, so a backoff or a
/// `Retry-After` wait costs the suite nothing.
final class RetryVirtualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    private var recorded: [TimeInterval] = []
    private let advancesOnSleep: Bool

    /// A whole second, so an HTTP-date `Retry-After` computed from it is exact.
    static let epoch = Date(timeIntervalSince1970: 1_800_000_000)

    init(advancesOnSleep: Bool = true) {
        current = Self.epoch
        self.advancesOnSleep = advancesOnSleep
    }

    var now: Date {
        lock.withLock { current }
    }

    var sleeps: [TimeInterval] {
        lock.withLock { recorded }
    }

    /// Time passing outside a sleep: a slow request, or another run's 429 landing.
    func advance(by seconds: TimeInterval) {
        lock.withLock { current = current.addingTimeInterval(seconds) }
    }

    func makePolicy() -> WorkshopRetryPolicy {
        WorkshopRetryPolicy(now: { self.now }, sleep: { self.recordSleep($0) })
    }

    private func recordSleep(_ seconds: TimeInterval) {
        lock.withLock {
            recorded.append(seconds)
            if advancesOnSleep {
                current = current.addingTimeInterval(seconds)
            }
        }
    }
}

/// Counts closure invocations across the policy's attempts.
private final class AttemptCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    /// Returns the 1-based ordinal of this attempt.
    func next() -> Int {
        lock.withLock {
            value += 1
            return value
        }
    }

    var count: Int {
        lock.withLock { value }
    }
}

/// A sleep that parks until the test releases it, so another run can reach the
/// policy while this one is inside its cooldown wait.
private final class GatedSleeper: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [TimeInterval] = []
    private var parked: [Int: CheckedContinuation<Void, Never>] = [:]

    var sleeps: [TimeInterval] {
        lock.withLock { recorded }
    }

    func sleep(_ seconds: TimeInterval) async {
        await withCheckedContinuation { continuation in
            lock.withLock {
                recorded.append(seconds)
                parked[recorded.count - 1] = continuation
            }
        }
    }

    /// Resumes the `index`-th sleep ever recorded.
    func release(_ index: Int) {
        lock.withLock { parked.removeValue(forKey: index) }?.resume()
    }

    func releaseAll() {
        let all = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            defer { parked.removeAll() }
            return Array(parked.values)
        }
        all.forEach { $0.resume() }
    }
}

/// Polls until `condition` holds or ~2 s pass; the caller asserts afterwards.
private func waitUntil(_ condition: @escaping @Sendable () -> Bool) async throws {
    for _ in 0 ..< 2000 where !condition() {
        try await Task.sleep(nanoseconds: 1_000_000)
    }
}

private func response(status: Int, host: String = "api.steampowered.com", headers: [String: String] = [:]) -> WorkshopRetryPolicy.Response {
    let http = HTTPURLResponse(
        url: URL(string: "https://\(host)/probe")!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers
    )!
    return (Data(), http)
}

@Suite("Workshop retry policy")
struct WorkshopRetryPolicyTests {
    private static let apiHost = "api.steampowered.com"
    private static let communityHost = "steamcommunity.com"

    @Test("A 429's Retry-After cools down every later request to that host, and only that host")
    func cooldownIsSharedAcrossRequestsOfTheSameHost() async throws {
        // The clock stays put, so request B starts inside A's cooldown.
        let clock = RetryVirtualClock(advancesOnSleep: false)
        let policy = clock.makePolicy()
        let attemptsA = AttemptCounter()

        let a = try await policy.run(host: Self.apiHost) {
            attemptsA.next() == 1 ? response(status: 429, headers: ["Retry-After": "5"]) : response(status: 200)
        }
        #expect(a.http.statusCode == 200)
        #expect(attemptsA.count == 2)
        #expect(clock.sleeps == [5])

        let attemptsB = AttemptCounter()
        let b = try await policy.run(host: Self.apiHost) {
            _ = attemptsB.next()
            return response(status: 200)
        }
        #expect(b.http.statusCode == 200)
        #expect(attemptsB.count == 1)
        #expect(clock.sleeps == [5, 5], "B waits out A's cooldown before its first attempt")

        let c = try await policy.run(host: Self.communityHost) { response(status: 200, host: Self.communityHost) }
        #expect(c.http.statusCode == 200)
        #expect(clock.sleeps == [5, 5], "another host is not cooled down")
    }

    /// The budget bounds every sleep of one run, the cooldown wait included:
    /// after 8 s waited, a second 8 s cooldown is not slept but reported.
    @Test("A cooldown that would overrun the sleep budget is thrown, not slept")
    func cooldownBeyondTheBudgetIsThrown() async throws {
        let clock = RetryVirtualClock()
        let policy = clock.makePolicy()
        let attempts = AttemptCounter()

        await #expect(throws: WorkshopQueryError.rateLimited(retryAfter: 8)) {
            try await policy.run(host: Self.apiHost) {
                attempts.next() < 3 ? response(status: 429, headers: ["Retry-After": "8"]) : response(status: 200)
            }
        }
        #expect(attempts.count == 2)
        #expect(clock.sleeps == [8])
    }

    /// Steam sends most 429s without a `Retry-After`; the host is still
    /// cooled down, for a local guess of 5 s, and every later run waits it out.
    @Test("A 429 without Retry-After cools the host down for five seconds")
    func headerlessRateLimitCoolsTheHostDown() async throws {
        let clock = RetryVirtualClock(advancesOnSleep: false)
        let policy = clock.makePolicy()
        let attemptsA = AttemptCounter()

        let a = try await policy.run(host: Self.apiHost) {
            attemptsA.next() == 1 ? response(status: 429) : response(status: 200)
        }
        #expect(a.http.statusCode == 200)
        #expect(attemptsA.count == 2)
        #expect(clock.sleeps == [5])

        let attemptsB = AttemptCounter()
        let b = try await policy.run(host: Self.apiHost) {
            _ = attemptsB.next()
            return response(status: 200)
        }
        #expect(b.http.statusCode == 200)
        #expect(attemptsB.count == 1)
        #expect(clock.sleeps == [5, 5], "B waits out A's cooldown before its first attempt")

        let c = try await policy.run(host: Self.communityHost) { response(status: 200, host: Self.communityHost) }
        #expect(c.http.statusCode == 200)
        #expect(clock.sleeps == [5, 5], "another host is not cooled down")
    }

    @Test("Retry-After is read only as a finite, non-negative number of seconds up to a day")
    func retryAfterBounds() {
        let policy = RetryVirtualClock().makePolicy()
        #expect(policy.retryAfter(from: response(status: 429, headers: ["Retry-After": "1e100"]).http) == nil)
        #expect(policy.retryAfter(from: response(status: 429, headers: ["Retry-After": "inf"]).http) == nil)
        #expect(policy.retryAfter(from: response(status: 429, headers: ["Retry-After": "nan"]).http) == nil)
        #expect(policy.retryAfter(from: response(status: 429, headers: ["Retry-After": "-3"]).http) == nil)
        #expect(policy.retryAfter(from: response(status: 429, headers: ["Retry-After": "86401"]).http) == nil)
        // Controls: the bounds are inclusive, and the header may be absent.
        #expect(policy.retryAfter(from: response(status: 429, headers: ["Retry-After": "8"]).http) == 8)
        #expect(policy.retryAfter(from: response(status: 429, headers: ["Retry-After": "0"]).http) == 0)
        #expect(policy.retryAfter(from: response(status: 429, headers: ["Retry-After": "86400"]).http) == 86400)
        #expect(policy.retryAfter(from: response(status: 429).http) == nil)
    }

    @Test("A cooldown longer than the acceptable wait is thrown, not slept")
    func cooldownBeyondAcceptableWaitIsThrown() async throws {
        let clock = RetryVirtualClock(advancesOnSleep: false)
        let policy = clock.makePolicy()

        await #expect(throws: WorkshopQueryError.rateLimited(retryAfter: 120)) {
            try await policy.run(host: Self.apiHost) { response(status: 429, headers: ["Retry-After": "120"]) }
        }
        await #expect(throws: WorkshopQueryError.rateLimited(retryAfter: 120)) {
            try await policy.run(host: Self.apiHost) { response(status: 200) }
        }
        #expect(clock.sleeps.isEmpty)
    }

    @Test("Cancelling during the backoff stops after the one attempt made")
    func cancellationDuringBackoffStopsAfterOneAttempt() async throws {
        // Real sleep, so the cancellation has a suspension point to land on.
        let policy = WorkshopRetryPolicy(sleep: { _ in try await Task.sleep(for: .seconds(30)) })
        let attempts = AttemptCounter()
        let task = Task {
            try await policy.run(host: Self.apiHost) { () -> WorkshopRetryPolicy.Response in
                _ = attempts.next()
                throw URLError(.timedOut)
            }
        }
        for _ in 0 ..< 2000 where attempts.count < 1 {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        task.cancel()

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(attempts.count == 1)
    }

    /// A run starts inside a cooldown, sleeps for it, and while it sleeps a
    /// request that was already in flight gets its own 429 with a longer
    /// `Retry-After`. Waking on the old deadline and sending would hit the
    /// extended one.
    @Test("A cooldown extended while a run sleeps on it is waited out too")
    func cooldownExtendedDuringSleepIsRechecked() async throws {
        let clock = RetryVirtualClock(advancesOnSleep: false)
        let gate = GatedSleeper()
        let policy = WorkshopRetryPolicy(now: { clock.now }, sleep: { await gate.sleep($0) })

        // B is already in flight (past the cooldown check) when A's 429 lands.
        let bEntered = GatedSleeper()
        let bAttempts = AttemptCounter()
        let b = Task {
            try await policy.run(host: Self.apiHost) {
                guard bAttempts.next() == 1 else { return response(status: 200) }
                await bEntered.sleep(0)
                return response(status: 429, headers: ["Retry-After": "8"])
            }
        }
        try await waitUntil { bEntered.sleeps.count == 1 }

        let aAttempts = AttemptCounter()
        let a = Task {
            try await policy.run(host: Self.apiHost) {
                aAttempts.next() == 1 ? response(status: 429, headers: ["Retry-After": "5"]) : response(status: 200)
            }
        }
        // t=0: A's 429 sets the deadline to t=5 and A sleeps on it.
        try await waitUntil { gate.sleeps.count == 1 }
        #expect(gate.sleeps == [5])

        // t=1: B's 429 pushes the deadline to t=9; B sleeps on that.
        clock.advance(by: 1)
        bEntered.release(0)
        try await waitUntil { gate.sleeps.count == 2 }
        #expect(gate.sleeps == [5, 8])

        // t=5: A wakes. The deadline moved, so A has 4 s more to wait (9 s in
        // all, inside the 10 s budget).
        clock.advance(by: 4)
        gate.release(0)
        try await waitUntil { gate.sleeps.count == 3 || aAttempts.count == 2 }
        #expect(gate.sleeps == [5, 8, 4])
        #expect(aAttempts.count == 1, "A must not send before the extended deadline")

        // t=9: both may go.
        clock.advance(by: 4)
        gate.releaseAll()
        let aResult = try await a.value
        let bResult = try await b.value
        #expect(aResult.http.statusCode == 200)
        #expect(bResult.http.statusCode == 200)
        #expect(aAttempts.count == 2)
        #expect(bAttempts.count == 2)
    }

    /// The budget exists to bound the sleeps of one run. A 20 s timeout is
    /// request time, and the one retry a timeout earns must still happen.
    @Test("Request time does not consume the retry budget")
    func requestTimeDoesNotConsumeTheBudget() async throws {
        let clock = RetryVirtualClock()
        let policy = clock.makePolicy()
        let attempts = AttemptCounter()

        let last = try await policy.run(host: Self.apiHost) { () -> WorkshopRetryPolicy.Response in
            guard attempts.next() > 1 else {
                clock.advance(by: 20)
                throw URLError(.timedOut)
            }
            return response(status: 200)
        }
        #expect(last.http.statusCode == 200)
        #expect(attempts.count == 2)
        #expect(clock.sleeps.count == 1)
    }

    /// Control for the budget: sleeps (the cooldown wait included) still count.
    @Test("The sleep budget stops a retry whose delay would overrun it")
    func budgetStopsRetriesBeforeTheDelayWouldOverrunIt() async throws {
        let clock = RetryVirtualClock()
        let policy = clock.makePolicy()
        let attempts = AttemptCounter()

        let last = try await policy.run(host: Self.apiHost) {
            switch attempts.next() {
            case 1: response(status: 429, headers: ["Retry-After": "9.5"])
            case 2: response(status: 503)
            default: response(status: 200)
            }
        }
        // 9.5 s waited + at least 0.75 s of backoff > 10 s: the 503 is final.
        #expect(last.http.statusCode == 503)
        #expect(attempts.count == 2)
        #expect(clock.sleeps == [9.5])
    }

    @Test(
        "Transport failures: not-connected retries once, timeouts to the cap, cancellation never",
        arguments: [
            (URLError.Code.notConnectedToInternet, 2),
            (URLError.Code.timedOut, 3),
            (URLError.Code.networkConnectionLost, 3),
            (URLError.Code.cancelled, 1),
            (URLError.Code.badServerResponse, 1),
        ]
    )
    func transportRetryCounts(code: URLError.Code, expectedAttempts: Int) async throws {
        let clock = RetryVirtualClock()
        let policy = clock.makePolicy()
        let attempts = AttemptCounter()

        await #expect(throws: URLError(code)) {
            try await policy.run(host: Self.apiHost) { () -> WorkshopRetryPolicy.Response in
                _ = attempts.next()
                throw URLError(code)
            }
        }
        #expect(attempts.count == expectedAttempts)
        #expect(clock.sleeps.count == expectedAttempts - 1)
    }
}

/// The two request paths through the stubbed session: what each retries,
/// what each refuses to retry, and what the UI is handed when the policy gives up.
@Suite("Workshop request retry", .serialized)
struct WorkshopRequestRetryTests {
    private static let validKey = String(repeating: "a1b2c3d4", count: 4)
    private static let keyedPage = Data("""
    {"response":{"total":1,"publishedfiledetails":[\
    {"publishedfileid":"777","result":1,"title":"Counted","visibility":0,"banned":0}]}}
    """.utf8)

    // MARK: - Keyed QueryFiles

    @Test("A timeout is retried and the second answer is the page")
    func keyedTransportFailureIsRetried() async throws {
        RetrySequenceStub.plan([.error(URLError(.timedOut)), .http(status: 200, headers: [:], body: Self.keyedPage)])
        let clock = RetryVirtualClock()
        let service = try await Self.makeKeyedService(policy: clock.makePolicy())

        let page = try await service.fetch(WorkshopQueryRequest(sort: .mostPopular))

        #expect(page.items.map(\.id) == [777])
        #expect(RetrySequenceStub.requestCount == 2)
        let backoff = try #require(clock.sleeps.first)
        #expect(clock.sleeps.count == 1)
        #expect((0.375 ... 0.625).contains(backoff), "0.5 s ± 25 %, got \(backoff)")
    }

    @Test("Control: a 403 is final on the first answer")
    func keyed403IsNotRetried() async throws {
        RetrySequenceStub.plan([.http(status: 403, headers: [:], body: Data("{}".utf8)), .http(status: 200, headers: [:], body: Self.keyedPage)])
        let clock = RetryVirtualClock()
        let service = try await Self.makeKeyedService(policy: clock.makePolicy())

        await #expect(throws: WorkshopQueryError.unauthorized) {
            try await service.fetch(WorkshopQueryRequest(sort: .mostPopular))
        }
        #expect(RetrySequenceStub.requestCount == 1)
        #expect(clock.sleeps.isEmpty)
    }

    @Test("A Retry-After beyond the acceptable wait is handed to the UI at once")
    func keyedLongRetryAfterIsNotWaitedOut() async throws {
        RetrySequenceStub.plan([.http(status: 429, headers: ["Retry-After": "120"], body: Data()), .http(status: 200, headers: [:], body: Self.keyedPage)])
        let clock = RetryVirtualClock()
        let service = try await Self.makeKeyedService(policy: clock.makePolicy())

        await #expect(throws: WorkshopQueryError.rateLimited(retryAfter: 120)) {
            try await service.fetch(WorkshopQueryRequest(sort: .mostPopular))
        }
        #expect(RetrySequenceStub.requestCount == 1)
        #expect(clock.sleeps.isEmpty)
    }

    @Test("An HTTP-date Retry-After two seconds out is waited for, then retried")
    func keyedHTTPDateRetryAfterIsHonoured() async throws {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        let retryAt = formatter.string(from: RetryVirtualClock.epoch.addingTimeInterval(2))
        RetrySequenceStub.plan([.http(status: 429, headers: ["Retry-After": retryAt], body: Data()), .http(status: 200, headers: [:], body: Self.keyedPage)])
        let clock = RetryVirtualClock()
        let service = try await Self.makeKeyedService(policy: clock.makePolicy())

        let page = try await service.fetch(WorkshopQueryRequest(sort: .mostPopular))

        #expect(page.items.map(\.id) == [777])
        #expect(RetrySequenceStub.requestCount == 2)
        #expect(clock.sleeps == [2])
    }

    @Test("Cancellation during the backoff surfaces as .cancelled after one request")
    func keyedCancellationDuringBackoffIsCancelled() async throws {
        RetrySequenceStub.plan([.http(status: 503, headers: [:], body: Data()), .http(status: 200, headers: [:], body: Self.keyedPage)])
        let policy = WorkshopRetryPolicy(sleep: { _ in throw CancellationError() })
        let service = try await Self.makeKeyedService(policy: policy)

        await #expect(throws: WorkshopQueryError.cancelled) {
            try await service.fetch(WorkshopQueryRequest(sort: .mostPopular))
        }
        #expect(RetrySequenceStub.requestCount == 1)
    }

    @Test("Three server errors exhaust the attempts; the third is reported, no fourth is made")
    func keyedThreeServerErrorsGiveUp() async throws {
        RetrySequenceStub.plan([
            .http(status: 503, headers: [:], body: Data()),
            .http(status: 503, headers: [:], body: Data()),
            .http(status: 503, headers: [:], body: Data()),
            .http(status: 200, headers: [:], body: Self.keyedPage),
        ])
        let clock = RetryVirtualClock()
        let service = try await Self.makeKeyedService(policy: clock.makePolicy())

        await #expect(throws: WorkshopQueryError.http(status: 503)) {
            try await service.fetch(WorkshopQueryRequest(sort: .mostPopular))
        }
        #expect(RetrySequenceStub.requestCount == 3)
        #expect(clock.sleeps.count == 2)
    }

    /// The persona lookup is best-effort, but it still has to respect the
    /// cooldown a 429 put on the host — it is the same host as the page.
    @Test("The creator-name lookup waits out the host's cooldown first")
    func personaLookupWaitsOutTheCooldown() async throws {
        let creatorPage = Data("""
        {"response":{"total":1,"publishedfiledetails":[\
        {"publishedfileid":"777","result":1,"title":"Counted","creator":"76561198000000001","visibility":0,"banned":0}]}}
        """.utf8)
        let personas = Data(#"{"response":{"players":[{"steamid":"76561198000000001","personaname":"Alice"}]}}"#.utf8)
        RetrySequenceStub.plan([
            .http(status: 429, headers: ["Retry-After": "5"], body: Data()),
            .http(status: 200, headers: [:], body: creatorPage),
            .http(status: 200, headers: [:], body: personas),
        ])
        // The clock stays put, so the lookup starts inside the page's cooldown.
        let clock = RetryVirtualClock(advancesOnSleep: false)
        let service = try await Self.makeKeyedService(policy: clock.makePolicy())
        let request = WorkshopQueryRequest(sort: .mostPopular)

        let page = try await service.fetch(request)
        #expect(page.items.first?.creatorID == "76561198000000001")
        #expect(clock.sleeps == [5])

        let names = await service.resolveCreatorNames(for: page, request: request)

        #expect(names == ["76561198000000001": "Alice"])
        #expect(RetrySequenceStub.requestCount == 3)
        #expect(clock.sleeps == [5, 5], "the lookup waited out the cooldown before sending")
    }

    @Test("Key validation retries a timeout like a query does")
    func validateAPIKeyRetriesTransportFailure() async throws {
        RetrySequenceStub.plan([.error(URLError(.timedOut)), .http(status: 200, headers: [:], body: Data("{}".utf8))])
        let clock = RetryVirtualClock()
        let service = try await Self.makeKeyedService(policy: clock.makePolicy())

        #expect(try await service.validateAPIKey(Self.validKey))
        #expect(RetrySequenceStub.requestCount == 2)
        #expect(clock.sleeps.count == 1)
    }

    // MARK: - Keyless browse page + details

    @Test("A dropped connection on the browse page GET is retried")
    @MainActor
    func keylessPageTransportFailureIsRetried() async throws {
        let ssrPage = try Data(WorkshopBrowseFixture.base().utf8)
        RetrySequenceStub.plan([.error(URLError(.networkConnectionLost)), .http(status: 200, headers: [:], body: ssrPage)])
        let clock = RetryVirtualClock()
        let (source, directory) = Self.makeKeylessSource(policy: clock.makePolicy())
        defer { try? FileManager.default.removeItem(at: directory) }

        let page = try await source.fetch(WorkshopPublicSearchSSRTests.fixtureRequest)

        #expect(page.items.map(\.id) == WorkshopPublicSearchSSRTests.expectedIDs)
        #expect(RetrySequenceStub.requestCount == 2)
        #expect(clock.sleeps.count == 1)
    }

    @Test("A 503 on the details POST is retried and the page completes")
    @MainActor
    func keylessDetailsServerErrorIsRetried() async throws {
        let harvestPage = try Data(WorkshopBrowseFixture.withoutSSRScript().utf8)
        RetrySequenceStub.plan([
            .http(status: 200, headers: [:], body: harvestPage),
            .http(status: 503, headers: [:], body: Data()),
            .http(status: 200, headers: [:], body: Self.detailsJSON()),
        ])
        let clock = RetryVirtualClock()
        let (source, directory) = Self.makeKeylessSource(policy: clock.makePolicy())
        defer { try? FileManager.default.removeItem(at: directory) }

        let page = try await source.fetch(WorkshopPublicSearchSSRTests.fixtureRequest)

        #expect(page.items.map(\.id) == WorkshopPublicSearchSSRTests.expectedIDs)
        #expect(RetrySequenceStub.requestCount == 3)
        #expect(clock.sleeps.count == 1)
    }

    @Test("Control: a 404 on the details POST is final")
    @MainActor
    func keylessDetails404IsNotRetried() async throws {
        let harvestPage = try Data(WorkshopBrowseFixture.withoutSSRScript().utf8)
        RetrySequenceStub.plan([
            .http(status: 200, headers: [:], body: harvestPage),
            .http(status: 404, headers: [:], body: Data()),
            .http(status: 200, headers: [:], body: Self.detailsJSON()),
        ])
        let clock = RetryVirtualClock()
        let (source, directory) = Self.makeKeylessSource(policy: clock.makePolicy())
        defer { try? FileManager.default.removeItem(at: directory) }

        // The endpoint, not the items, was not found: an HTTP failure, never
        // "every item is gone" (which would now be cached as an empty page).
        await #expect(throws: WorkshopQueryError.http(status: 404)) {
            try await source.fetch(WorkshopPublicSearchSSRTests.fixtureRequest)
        }
        #expect(RetrySequenceStub.requestCount == 2)
        #expect(clock.sleeps.isEmpty)
    }

    // MARK: - Fixtures

    private static func makeKeyedService(policy: WorkshopRetryPolicy) async throws -> WorkshopQueryService {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("workshop-request-retry-\(UUID().uuidString)", isDirectory: true)
        let keychain = WorkshopKeychainStore(
            directory: root.appendingPathComponent("keychain", isDirectory: true),
            slot: WorkshopKeychainSlotSpy().slot()
        )
        try await keychain.setWebAPIKey(validKey)
        return WorkshopQueryService(
            keychain: keychain,
            cache: WorkshopQueryCache(directoryURL: root.appendingPathComponent("cache", isDirectory: true)),
            session: RetrySequenceStub.makeSession(),
            retryPolicy: policy,
            countIssuedRequest: {}
        )
    }

    @MainActor
    private static func makeKeylessSource(policy: WorkshopRetryPolicy) -> (WorkshopPublicSearchSource, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("workshop-request-retry-keyless-\(UUID().uuidString)", isDirectory: true)
        let session = RetrySequenceStub.makeSession()
        let source = WorkshopPublicSearchSource(
            metadata: SteamWorkshopMetadataService(session: session),
            session: session,
            appID: WorkshopQueryService.wallpaperEngineAppID,
            cache: WorkshopQueryCache(directoryURL: directory),
            retryPolicy: policy
        )
        return (source, directory)
    }

    private static func detailsJSON() -> Data {
        let entries = WorkshopPublicSearchSSRTests.expectedIDs.map { id in
            #"{"publishedfileid":"\#(id)","result":1,"consumer_app_id":431960,"title":"Item \#(id)","visibility":0,"banned":0,"tags":[{"tag":"Scene"}]}"#
        }
        return Data(#"{"response":{"result":1,"resultcount":\#(entries.count),"publishedfiledetails":[\#(entries.joined(separator: ","))]}}"#.utf8)
    }
}

/// Answers requests in planned order, whatever their URL; a request past the
/// plan fails with `.unknown` so an unexpected extra attempt cannot pass.
private final class RetrySequenceStub: URLProtocol, @unchecked Sendable {
    enum Step: @unchecked Sendable {
        case http(status: Int, headers: [String: String], body: Data)
        case error(Error)
    }

    private static let lock = NSLock()
    private nonisolated(unsafe) static var steps: [Step] = []
    private nonisolated(unsafe) static var served = 0

    static func plan(_ steps: [Step]) {
        lock.withLock {
            Self.steps = steps
            served = 0
        }
    }

    static var requestCount: Int {
        lock.withLock { served }
    }

    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RetrySequenceStub.self]
        return URLSession(configuration: config)
    }

    override static func canInit(with _: URLRequest) -> Bool {
        true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let step: Step? = Self.lock.withLock {
            let index = Self.served
            Self.served += 1
            return index < Self.steps.count ? Self.steps[index] : nil
        }
        switch step {
        case let .http(status, headers, body):
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        case let .error(error):
            client?.urlProtocol(self, didFailWithError: error)
        case nil:
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
        }
    }

    override func stopLoading() {}
}
#endif
