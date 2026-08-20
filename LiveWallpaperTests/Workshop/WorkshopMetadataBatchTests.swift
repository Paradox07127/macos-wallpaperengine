#if !LITE_BUILD
import Foundation
import Testing
@testable import LiveWallpaper

@Suite("Workshop metadata batch fetch", .serialized)
struct WorkshopMetadataBatchTests {

    // MARK: - Body construction

    @Test("Batch body follows Valve's itemcount + indexed publishedfileids convention")
    func batchBodyEncoding() {
        #expect(SteamWorkshopMetadataService.formBody(publishedFileIDs: [111, 222, 333])
            == "itemcount=3&publishedfileids%5B0%5D=111&publishedfileids%5B1%5D=222&publishedfileids%5B2%5D=333")
        // The single-id shape is pinned by InstalledOwnershipTests against the
        // live request; pin the builder to the same string here.
        #expect(SteamWorkshopMetadataService.formBody(publishedFileIDs: [100])
            == "itemcount=1&publishedfileids%5B0%5D=100")
    }

    // MARK: - Batch decode routing

    @Test("Batch decode routes each payload to its requested id and fails closed on gaps")
    func batchDecodeRoutesPerID() throws {
        let body = Self.batchPayload(items: [
            .success(id: "111"),
            .resultCode(id: "222", code: 9),
            .resultCode(id: "333", code: 2),
            .resultCode(id: "555", code: 15),
        ])
        let results = SteamWorkshopMetadataService.decodeBatch(
            data: body,
            requestedIDs: [111, 222, 333, 444, 555]
        )

        let first = try #require(results[111]).get()
        #expect(first.publishedFileID == 111)
        #expect(first.title == "Fixture 111")
        #expect(first.appID == 431_960)

        #expect(results[222] == .failure(.itemNotFound))
        #expect(results[333] == .failure(.itemNotFound))
        // 444 is absent from the response entirely.
        #expect(results[444] == .failure(.itemNotFound))
        #expect(results[555] == .failure(.itemPrivate))
        #expect(results.count == 5)
    }

    @Test("A duplicated id keeps the first payload, so a trailing failure can't flip it")
    func batchDecodeDuplicateIDKeepsFirst() throws {
        let body = Self.batchPayload(items: [
            .success(id: "111"),
            .resultCode(id: "111", code: 9),
        ])
        let results = SteamWorkshopMetadataService.decodeBatch(data: body, requestedIDs: [111])

        let metadata = try #require(results[111]).get()
        #expect(metadata.publishedFileID == 111)
        #expect(results.count == 1)
    }

    @Test("Malformed batch JSON fails every requested id as a parse failure")
    func batchDecodeMalformedJSON() {
        let results = SteamWorkshopMetadataService.decodeBatch(
            data: Data("not json".utf8),
            requestedIDs: [111, 222]
        )
        #expect(results[111] == .failure(.responseParseFailure))
        #expect(results[222] == .failure(.responseParseFailure))
    }

    // MARK: - Transport fan-out

    @Test("Batch fetch sends one POST and fans a 429 out to every id")
    @MainActor
    func batchFetchRateLimitFansOut() async {
        let recorder = BatchRequestRecorder { _, _ in
            .http(status: 429, headers: ["Retry-After": "12"], body: Data())
        }
        defer { recorder.releaseAll() }
        let service = Self.metadataService(recorder)

        let results = await service.fetch(publishedFileIDs: [111, 222, 333])
        #expect(results[111] == .failure(.rateLimited(retryAfter: 12)))
        #expect(results[222] == .failure(.rateLimited(retryAfter: 12)))
        #expect(results[333] == .failure(.rateLimited(retryAfter: 12)))
        #expect(recorder.bodies == ["itemcount=3&publishedfileids%5B0%5D=111&publishedfileids%5B1%5D=222&publishedfileids%5B2%5D=333"])
    }

    @Test("Empty id array short-circuits without any network request")
    @MainActor
    func emptyBatchSkipsNetwork() async {
        let recorder = BatchRequestRecorder { _, _ in .http(status: 500, headers: [:], body: Data()) }
        defer { recorder.releaseAll() }
        let service = Self.metadataService(recorder)

        let results = await service.fetch(publishedFileIDs: [])
        #expect(results.isEmpty)
        #expect(recorder.bodies.isEmpty)
    }

    // MARK: - Paste queue batching

    @Test("Ingesting three links issues a single batched POST and settles every row")
    @MainActor
    func ingestionBatchesIntoOneRequest() async {
        let recorder = BatchRequestRecorder { _, body in
            .http(status: 200, headers: [:], body: Self.successPayload(forRequestBody: body))
        }
        defer { recorder.releaseAll() }
        let model = WorkshopPasteQueueModel(metadataService: Self.metadataService(recorder))

        model.updateRawInput("111 222 333")
        model.ingestFromRawInput()
        await Self.waitUntilSettled(model)

        #expect(recorder.bodies == ["itemcount=3&publishedfileids%5B0%5D=111&publishedfileids%5B1%5D=222&publishedfileids%5B2%5D=333"])
        #expect(model.rows.count == 3)
        #expect(model.rows.allSatisfy { $0.state == .ready })
        #expect(model.rows.compactMap(\.metadata?.publishedFileID) == [111, 222, 333])
    }

    @Test("A 51-link paste splits into a 50-id chunk and a 1-id chunk, run sequentially")
    @MainActor
    func ingestionChunksAtFiftyAndRunsSequentially() async throws {
        let recorder = BatchRequestRecorder(autoRelease: false) { _, body in
            .http(status: 200, headers: [:], body: Self.successPayload(forRequestBody: body))
        }
        defer { recorder.releaseAll() }
        let model = WorkshopPasteQueueModel(metadataService: Self.metadataService(recorder))

        model.updateRawInput((1...51).map(String.init).joined(separator: " "))
        model.ingestFromRawInput()

        await recorder.waitUntilStarted(count: 1)
        // Second chunk must not start while the first is still in flight.
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(recorder.bodies.count == 1)
        let firstBody = try #require(recorder.bodies.first)
        #expect(firstBody.hasPrefix("itemcount=50&publishedfileids%5B0%5D=1&"))
        #expect(firstBody.hasSuffix("publishedfileids%5B49%5D=50"))

        recorder.releaseNext()
        await recorder.waitUntilStarted(count: 2)
        #expect(recorder.bodies.last == "itemcount=1&publishedfileids%5B0%5D=51")
        recorder.releaseNext()

        await Self.waitUntilSettled(model)
        #expect(model.rows.count == 51)
        #expect(model.rows.allSatisfy { $0.state == .ready })
    }

    @Test("removeAll cancels the running batch: the second chunk is never requested")
    @MainActor
    func removeAllCancelsPendingChunks() async {
        let recorder = BatchRequestRecorder(autoRelease: false) { _, body in
            .http(status: 200, headers: [:], body: Self.successPayload(forRequestBody: body))
        }
        defer { recorder.releaseAll() }
        let model = WorkshopPasteQueueModel(metadataService: Self.metadataService(recorder))

        model.updateRawInput((1...51).map(String.init).joined(separator: " "))
        model.ingestFromRawInput()
        await recorder.waitUntilStarted(count: 1)

        model.removeAll()
        #expect(model.rows.isEmpty)
        recorder.releaseAll()

        // A fresh single-row ingestion still works after the cancellation…
        model.updateRawInput("999")
        model.ingestFromRawInput()
        await Self.waitUntilSettled(model)
        #expect(model.rows.count == 1)
        #expect(model.rows.first?.state == .ready)

        // …and the cancelled ingestion's second chunk (id 51 alone) never ran.
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(!recorder.bodies.contains("itemcount=1&publishedfileids%5B0%5D=51"))
        #expect(recorder.bodies.last == "itemcount=1&publishedfileids%5B0%5D=999")
    }

    @Test("Removing a row mid-batch drops its result while siblings still apply")
    @MainActor
    func removedRowResultIsDropped() async throws {
        let recorder = BatchRequestRecorder(autoRelease: false) { _, body in
            .http(status: 200, headers: [:], body: Self.successPayload(forRequestBody: body))
        }
        defer { recorder.releaseAll() }
        let model = WorkshopPasteQueueModel(metadataService: Self.metadataService(recorder))

        model.updateRawInput("111 222")
        model.ingestFromRawInput()
        await recorder.waitUntilStarted(count: 1)

        let removedRowID = try #require(model.rows.first { $0.publishedFileID == 222 }?.id)
        model.remove(rowID: removedRowID)
        recorder.releaseAll()

        await Self.waitUntilSettled(model)
        #expect(model.rows.count == 1)
        #expect(model.rows.first?.publishedFileID == 111)
        #expect(model.rows.first?.state == .ready)
    }

    @Test("retry keeps the single-id request path")
    @MainActor
    func retryStaysSingleID() async throws {
        let recorder = BatchRequestRecorder { ordinal, body in
            ordinal == 1
                ? .http(status: 500, headers: [:], body: Data())
                : .http(status: 200, headers: [:], body: Self.successPayload(forRequestBody: body))
        }
        defer { recorder.releaseAll() }
        let model = WorkshopPasteQueueModel(metadataService: Self.metadataService(recorder))

        model.updateRawInput("111")
        model.ingestFromRawInput()
        await Self.waitUntilSettled(model)
        #expect(model.rows.first?.state == .failed)
        #expect(model.rows.first?.error == .http(status: 500))

        let rowID = try #require(model.rows.first?.id)
        model.retry(rowID: rowID)
        await Self.waitUntilSettled(model)
        #expect(model.rows.first?.state == .ready)
        #expect(recorder.bodies == [
            "itemcount=1&publishedfileids%5B0%5D=111",
            "itemcount=1&publishedfileids%5B0%5D=111",
        ])
    }

    // MARK: - Fixtures

    private enum FixtureItem {
        case success(id: String)
        case resultCode(id: String, code: Int)
    }

    private static func batchPayload(items: [FixtureItem]) -> Data {
        let details = items.map { item -> String in
            switch item {
            case .success(let id):
                return """
                {"publishedfileid":"\(id)","result":1,"consumer_app_id":431960,\
                "title":"Fixture \(id)","short_description":"summary",\
                "time_updated":1720000000,"visibility":0,"banned":0}
                """
            case .resultCode(let id, let code):
                // Non-OK payloads mirror Steam: no consumer_app_id, no content fields.
                return "{\"publishedfileid\":\"\(id)\",\"result\":\(code)}"
            }
        }.joined(separator: ",")
        return Data("{\"response\":{\"result\":1,\"resultcount\":\(items.count),\"publishedfiledetails\":[\(details)]}}".utf8)
    }

    /// Builds a success envelope answering exactly the ids the request asked for.
    private static func successPayload(forRequestBody body: String) -> Data {
        let ids = body.components(separatedBy: "&").compactMap { part -> String? in
            guard part.hasPrefix("publishedfileids%5B") else { return nil }
            return part.components(separatedBy: "=").last
        }
        return batchPayload(items: ids.map { .success(id: $0) })
    }

    @MainActor
    private static func metadataService(_ recorder: BatchRequestRecorder) -> SteamWorkshopMetadataService {
        BatchMetadataStubProtocol.recorder = recorder
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BatchMetadataStubProtocol.self]
        return SteamWorkshopMetadataService(session: URLSession(configuration: configuration))
    }

    @MainActor
    private static func waitUntilSettled(_ model: WorkshopPasteQueueModel) async {
        for _ in 0..<2000 {
            if !model.rows.isEmpty, model.rows.allSatisfy({ $0.state != .fetchingMetadata }) { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        Issue.record("Paste queue rows never settled")
    }
}

// MARK: - Network stub

private final class BatchMetadataStubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var recorder: BatchRequestRecorder?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let recorder = Self.recorder else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        switch recorder.response(for: request) {
        case .http(let status, let headers, let body):
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: headers
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        case .error(let error):
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

/// Records request bodies in arrival order and optionally gates responses so a
/// test can prove chunks run sequentially (or never run at all after cancel).
private final class BatchRequestRecorder: @unchecked Sendable {
    enum Plan: @unchecked Sendable {
        case http(status: Int, headers: [String: String], body: Data)
        case error(Error)
    }

    private let condition = NSCondition()
    private let makeResponse: @Sendable (Int, String) -> Plan
    private var recordedBodies: [String] = []
    private var releasedCount: Int

    init(autoRelease: Bool = true, makeResponse: @escaping @Sendable (Int, String) -> Plan) {
        self.releasedCount = autoRelease ? .max : 0
        self.makeResponse = makeResponse
    }

    var bodies: [String] {
        condition.lock()
        defer { condition.unlock() }
        return recordedBodies
    }

    func response(for request: URLRequest) -> Plan {
        let body = Self.bodyString(from: request) ?? ""
        condition.lock()
        recordedBodies.append(body)
        let ordinal = recordedBodies.count
        condition.broadcast()
        while releasedCount < ordinal {
            condition.wait()
        }
        condition.unlock()
        return makeResponse(ordinal, body)
    }

    @MainActor
    func waitUntilStarted(count: Int) async {
        for _ in 0..<2000 {
            if bodies.count >= count { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        Issue.record("Batched metadata request never entered the URLSession seam")
    }

    func releaseNext() {
        condition.lock()
        releasedCount += 1
        condition.broadcast()
        condition.unlock()
    }

    func releaseAll() {
        condition.lock()
        releasedCount = .max
        condition.broadcast()
        condition.unlock()
    }

    private static func bodyString(from request: URLRequest) -> String? {
        if let body = request.httpBody { return String(data: body, encoding: .utf8) }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 512)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return String(data: data, encoding: .utf8)
    }
}
#endif
