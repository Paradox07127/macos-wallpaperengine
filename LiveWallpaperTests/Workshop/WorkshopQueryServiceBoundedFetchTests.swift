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

    /// The keyed `QueryFiles` path, which the keyless public-search suite can't
    /// cover: it reaches Steam with an API key and decodes a different payload.
    @Suite("WorkshopQueryService keyed fields")
    struct WorkshopQueryServiceKeyedFieldsTests {
        private static let validKey = String(repeating: "a1b2c3d4", count: 4)

        @Test("A keyed query carries Steam's view and favorite counts into the browse item")
        func keyedQueryCarriesViewAndFavoriteCounts() async throws {
            let service = Self.makeService(slot: WorkshopKeychainSlotSpy(stored: Self.validKey).slot())
            let page = try await service.fetch(WorkshopQueryRequest(sort: .mostPopular))
            let item = try #require(page.items.first)

            #expect(item.viewCount == 6_100)
            // Lifetime wins over the current tally, matching `subscriptionCount`.
            #expect(item.favoriteCount == 900)
        }

        @Test("A refused keychain read reports the locked key, not a missing one")
        func refusedKeychainReadIsNotReportedAsMissing() async {
            let service = Self.makeService(
                slot: WorkshopKeychainSlotSpy(stored: Self.validKey, readDenied: true).slot()
            )
            await #expect(throws: WorkshopQueryError.keychainAccessDenied) {
                _ = try await service.fetch(WorkshopQueryRequest(sort: .mostPopular))
            }
        }

        @Test("Control: no stored key still reports a missing one")
        func absentKeyStillReportsMissing() async {
            let service = Self.makeService(slot: WorkshopKeychainSlotSpy().slot())
            await #expect(throws: WorkshopQueryError.missingAPIKey) {
                _ = try await service.fetch(WorkshopQueryRequest(sort: .mostPopular))
            }
        }

        private static func makeService(slot: WorkshopKeychainSlot) -> WorkshopQueryService {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("workshop-query-keyed-\(UUID().uuidString)", isDirectory: true)
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [WorkshopQueryKeyedStub.self]
            return WorkshopQueryService(
                keychain: WorkshopKeychainStore(directory: directory, slot: slot),
                cache: WorkshopQueryCache(directoryURL: directory.appendingPathComponent("cache")),
                session: URLSession(configuration: config)
            )
        }
    }

    /// Fixed body, so this stub shares no mutable state with the bounded-fetch one.
    private final class WorkshopQueryKeyedStub: URLProtocol, @unchecked Sendable {
        private static let body = Data("""
        {"response":{"total":1,"publishedfiledetails":[\
        {"publishedfileid":"777","result":1,"title":"Counted","short_description":"summary",\
        "visibility":0,"banned":0,"subscriptions":410,"lifetime_subscriptions":95000,\
        "favorited":12,"lifetime_favorited":900,"views":6100}]}}
        """.utf8)

        override class func canInit(with _: URLRequest) -> Bool { true }

        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Self.body)
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
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
