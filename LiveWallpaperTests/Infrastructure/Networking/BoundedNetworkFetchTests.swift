import Foundation
@testable import LiveWallpaper
import Testing

@Suite("BoundedNetworkFetch", .serialized)
struct BoundedNetworkFetchTests {
    private static let url = URL(string: "https://example.com/resource")!

    @Test("Rejects a declared Content-Length over the cap before reading any body")
    func rejectsOversizedDeclaredLength() async {
        BoundedFetchURLProtocolStub.plan = { _ in
            // Body itself fits the cap — only the header is oversized, isolating
            // the pre-check from the streamed-count check below.
            (headers: ["Content-Length": "1000"], body: Data([0x01, 0x02]))
        }
        let session = Self.makeSession()
        await #expect(throws: BoundedNetworkFetch.ResponseTooLarge(byteCap: 100)) {
            _ = try await BoundedNetworkFetch.fetch(URLRequest(url: Self.url), session: session, byteCap: 100)
        }
    }

    @Test("Rejects streamed overflow, including one extra byte and a partially filled staging chunk", arguments: [
        (500, 100, UInt8(0x41)), (101, 100, 0x42), (150_000, 70000, 0x43)
    ])
    func rejectsOversizedStreamedBody(bodyCount: Int, byteCap: Int, byte: UInt8) async {
        BoundedFetchURLProtocolStub.plan = { _ in
            (headers: [:], body: Data(repeating: byte, count: bodyCount))
        }
        let session = Self.makeSession()
        await #expect(throws: BoundedNetworkFetch.ResponseTooLarge(byteCap: byteCap)) {
            _ = try await BoundedNetworkFetch.fetch(URLRequest(url: Self.url), session: session, byteCap: byteCap)
        }
    }

    @Test("Accepts a body exactly at the cap and returns it unmodified")
    func succeedsAtExactCap() async throws {
        let body = Data(repeating: 0x42, count: 100)
        BoundedFetchURLProtocolStub.plan = { _ in (headers: [:], body: body) }
        let session = Self.makeSession()
        let (data, response) = try await BoundedNetworkFetch.fetch(URLRequest(url: Self.url), session: session, byteCap: 100)
        #expect(data == body)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
    }

    @Test("Returns the full body when comfortably within the cap")
    func succeedsWithinCap() async throws {
        let body = Data("hello world".utf8)
        BoundedFetchURLProtocolStub.plan = { _ in (headers: [:], body: body) }
        let session = Self.makeSession()
        let (data, _) = try await BoundedNetworkFetch.fetch(URLRequest(url: Self.url), session: session, byteCap: 100)
        #expect(data == body)
    }

    @Test("A body spanning several staging chunks round-trips byte for byte")
    func spansStagingChunks() async throws {
        // Larger than the 64 KiB staging buffer, and not a multiple of it, so
        // both the flush path and the trailing remainder are exercised.
        let body = Data((0..<150_000).map { UInt8($0 % 251) })
        BoundedFetchURLProtocolStub.plan = { _ in (headers: [:], body: body) }
        let session = Self.makeSession()
        let (data, _) = try await BoundedNetworkFetch.fetch(
            URLRequest(url: Self.url), session: session, byteCap: 1_000_000
        )
        #expect(data == body)
    }

    private static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [BoundedFetchURLProtocolStub.self]
        return URLSession(configuration: config)
    }
}

private final class BoundedFetchURLProtocolStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var plan: (@Sendable (URLRequest) -> (headers: [String: String], body: Data))?

    override class func canInit(with _: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let plan = Self.plan else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        let (headers, body) = plan(request)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
