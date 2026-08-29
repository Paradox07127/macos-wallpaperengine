#if !LITE_BUILD
    import Foundation
    @testable import LiveWallpaper
    import Testing

    @Suite("Workshop API key rejection")
    struct WorkshopAPIKeyRejectionTests {
        private static let validKey = String(repeating: "a1b2c3d4", count: 4)

        @Test("Valve 403 reports a rejection; a later keyed success clears it")
        @MainActor
        func valveRejectionMarksStoredKeyRejected() async throws {
            let log = VerdictLog()
            let service = try await Self.makeService()
            await service.setAuthVerdictHandler { accepted, _ in log.append(accepted) }

            APIKeyRejectionURLProtocolStub.plan = { _ in
                .http(status: 403, headers: [:], body: Data("{}".utf8))
            }
            await #expect(throws: WorkshopQueryError.unauthorized) {
                _ = try await service.fetch(WorkshopQueryRequest(sort: .mostPopular))
            }
            #expect(log.values == [false])

            // A later successful keyed request reports acceptance (different
            // request so the cache/in-flight map can't swallow the fetch).
            APIKeyRejectionURLProtocolStub.plan = { _ in
                .http(status: 200, headers: [:], body: Data(#"{"response":{"total":0}}"#.utf8))
            }
            _ = try await service.fetch(WorkshopQueryRequest(sort: .mostPopular, page: 2))
            #expect(log.values == [false, true])

            // The stored fact drives the Settings facet.
            let services = WorkshopServices()
            services.hasWebAPIKey = true
            services.noteAuthVerdict(accepted: false, keyFingerprint: "deadbeef")
            #expect(services.apiKeyRejected)
            services.noteAuthVerdict(accepted: true, keyFingerprint: "deadbeef")
            #expect(!services.apiKeyRejected)
        }

        @Test("Network failure reports no verdict — offline must not mark a key bad")
        func networkErrorLeavesVerdictUntouched() async throws {
            let log = VerdictLog()
            let service = try await Self.makeService()
            await service.setAuthVerdictHandler { accepted, _ in log.append(accepted) }

            APIKeyRejectionURLProtocolStub.plan = { _ in
                .error(URLError(.notConnectedToInternet))
            }
            await #expect(throws: WorkshopQueryError.networkUnreachable) {
                _ = try await service.fetch(WorkshopQueryRequest(sort: .mostPopular))
            }
            #expect(log.values.isEmpty)
        }

        private static func makeService() async throws -> WorkshopQueryService {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("workshop-key-rejection-\(UUID().uuidString)", isDirectory: true)
            let keychain = WorkshopKeychainStore(
                directory: root.appendingPathComponent("keychain", isDirectory: true),
                slot: WorkshopKeychainSlotSpy().slot()
            )
            try await keychain.setWebAPIKey(validKey)
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [APIKeyRejectionURLProtocolStub.self]
            return WorkshopQueryService(
                keychain: keychain,
                cache: WorkshopQueryCache(directoryURL: root.appendingPathComponent("cache", isDirectory: true)),
                session: URLSession(configuration: config)
            )
        }
    }

    // @unchecked Sendable: every access to `entries` goes through `lock`.
    private final class VerdictLog: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [Bool] = []

        func append(_ accepted: Bool) {
            lock.lock()
            entries.append(accepted)
            lock.unlock()
        }

        var values: [Bool] {
            lock.lock()
            defer { lock.unlock() }
            return entries
        }
    }

    private final class APIKeyRejectionURLProtocolStub: URLProtocol, @unchecked Sendable {
        enum Plan: @unchecked Sendable {
            case http(status: Int, headers: [String: String], body: Data)
            case error(Error)
        }

        nonisolated(unsafe) static var plan: (@Sendable (URLRequest) -> Plan)?

        override class func canInit(with _: URLRequest) -> Bool { true }

        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

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
