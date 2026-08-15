import Foundation
@testable import LiveWallpaper
import Testing

@Suite("BoundedNetworkFetch")
struct BoundedNetworkFetchTests {
    private static let url = URL(string: "https://example.com/resource")!

    @Test("Rejects a declared Content-Length over the cap before reading any body")
    func rejectsOversizedDeclaredLength() async {
        BoundedFetchURLProtocolStub.plan = { _ in
            // Body itself fits the cap — only the header is oversized, isolating
            // the pre-check from the streamed-count check below.
            .http(status: 200, headers: ["Content-Length": "1000"], body: Data([0x01, 0x02]))
        }
        let session = Self.makeSession()
        await #expect(throws: BoundedNetworkFetch.ResponseTooLarge(byteCap: 100)) {
            _ = try await BoundedNetworkFetch.fetch(URLRequest(url: Self.url), session: session, byteCap: 100)
        }
    }

    @Test("Aborts once accumulated bytes exceed the cap when Content-Length is absent")
    func abortsOnOversizedStreamedBody() async {
        BoundedFetchURLProtocolStub.plan = { _ in
            .http(status: 200, headers: [:], body: Data(repeating: 0x41, count: 500))
        }
        let session = Self.makeSession()
        await #expect(throws: BoundedNetworkFetch.ResponseTooLarge(byteCap: 100)) {
            _ = try await BoundedNetworkFetch.fetch(URLRequest(url: Self.url), session: session, byteCap: 100)
        }
    }

    @Test("Rejects a body exactly one byte over the cap")
    func rejectsOneByteOverCap() async {
        BoundedFetchURLProtocolStub.plan = { _ in
            .http(status: 200, headers: [:], body: Data(repeating: 0x42, count: 101))
        }
        let session = Self.makeSession()
        await #expect(throws: BoundedNetworkFetch.ResponseTooLarge(byteCap: 100)) {
            _ = try await BoundedNetworkFetch.fetch(URLRequest(url: Self.url), session: session, byteCap: 100)
        }
    }

    @Test("Accepts a body exactly at the cap and returns it unmodified")
    func succeedsAtExactCap() async throws {
        let body = Data(repeating: 0x42, count: 100)
        BoundedFetchURLProtocolStub.plan = { _ in .http(status: 200, headers: [:], body: body) }
        let session = Self.makeSession()
        let (data, response) = try await BoundedNetworkFetch.fetch(URLRequest(url: Self.url), session: session, byteCap: 100)
        #expect(data == body)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
    }

    @Test("Returns the full body when comfortably within the cap")
    func succeedsWithinCap() async throws {
        let body = Data("hello world".utf8)
        BoundedFetchURLProtocolStub.plan = { _ in .http(status: 200, headers: [:], body: body) }
        let session = Self.makeSession()
        let (data, _) = try await BoundedNetworkFetch.fetch(URLRequest(url: Self.url), session: session, byteCap: 100)
        #expect(data == body)
    }

    private static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [BoundedFetchURLProtocolStub.self]
        return URLSession(configuration: config)
    }
}

private final class BoundedFetchURLProtocolStub: URLProtocol, @unchecked Sendable {
    enum Plan: @unchecked Sendable {
        case http(status: Int, headers: [String: String], body: Data)
        case error(Error)
    }

    nonisolated(unsafe) static var plan: (@Sendable (URLRequest) -> Plan)?

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
        switch plan(request) {
        case let .http(status, headers, body):
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: headers
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        case let .error(error):
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
