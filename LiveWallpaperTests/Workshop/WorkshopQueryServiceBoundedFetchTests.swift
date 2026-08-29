#if !LITE_BUILD
    import Foundation
    @testable import LiveWallpaper
    import Testing

    @Suite("WorkshopQueryService bounded fetch")
    struct WorkshopQueryServiceBoundedFetchTests {
        private static let validKey = String(repeating: "a1b2c3d4", count: 4)

        @Test("validateAPIKey rejects a declared Content-Length over the cap")
        func rejectsOversizedDeclaredLength() async {
            WorkshopQueryURLProtocolStub.plan = { _ in
                .http(status: 200, headers: ["Content-Length": "\(9 * 1024 * 1024)"], body: Data("{}".utf8))
            }
            let service = Self.makeService()
            await #expect(throws: WorkshopQueryError.responseParseFailure) {
                _ = try await service.validateAPIKey(Self.validKey)
            }
        }

        @Test("validateAPIKey aborts once the streamed body exceeds the cap")
        func abortsOnOversizedStreamedBody() async {
            let oversized = Data(repeating: 0x41, count: 9 * 1024 * 1024)
            WorkshopQueryURLProtocolStub.plan = { _ in .http(status: 200, headers: [:], body: oversized) }
            let service = Self.makeService()
            await #expect(throws: WorkshopQueryError.responseParseFailure) {
                _ = try await service.validateAPIKey(Self.validKey)
            }
        }

        @Test("validateAPIKey still succeeds for a normal-size response")
        func succeedsForNormalResponse() async throws {
            WorkshopQueryURLProtocolStub.plan = { _ in .http(status: 200, headers: [:], body: Data("{}".utf8)) }
            let service = Self.makeService()
            #expect(try await service.validateAPIKey(Self.validKey) == true)
        }

        private static func makeService() -> WorkshopQueryService {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("workshop-query-bounded-fetch-\(UUID().uuidString)", isDirectory: true)
            let keychain = WorkshopKeychainStore(
                directory: directory,
                slot: WorkshopKeychainSlotSpy().slot()
            )
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [WorkshopQueryURLProtocolStub.self]
            return WorkshopQueryService(keychain: keychain, session: URLSession(configuration: config))
        }
    }

    private final class WorkshopQueryURLProtocolStub: URLProtocol, @unchecked Sendable {
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
#endif
