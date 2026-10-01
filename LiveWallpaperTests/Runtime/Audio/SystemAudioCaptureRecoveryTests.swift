#if !LITE_BUILD
import Foundation
@testable import LiveWallpaper
import Testing

@MainActor
private final class RecoveryCaptureService: SystemAudioCaptureServing {
    enum Failure: Error { case expected }
    let fails: Bool
    private(set) var starts = 0
    private(set) var stops = 0
    private(set) var invalidation: (@MainActor @Sendable () -> Void)?
    init(fails: Bool = false) {
        self.fails = fails
    }

    func start() throws {
        starts += 1
        if fails {
            throw Failure.expected
        }
    }

    func stop() {
        stops += 1
    }

    func setInvalidationHandler(_ handler: @escaping @MainActor @Sendable () -> Void) {
        invalidation = handler
    }
}

@MainActor
@Suite("System audio capture invalidation recovery", .serialized)
struct SystemAudioCaptureRecoveryTests {
    @Test("One active capture invalidation rebuilds once, dropping the retired generation burst")
    func activeInvalidationRebuildsOnce() throws {
        var services: [RecoveryCaptureService] = []
        let manager = SystemAudioCaptureManager {
            let service = RecoveryCaptureService()
            services.append(service)
            return service
        }
        defer { manager.shutdown() }
        manager.setEnabled(true)
        manager.retain()
        let old = try #require(services.first?.invalidation)
        for _ in 0 ..< 10000 {
            old()
        }
        #expect(services.count == 2)
        #expect(services[0].stops == 1)
        #expect(services[1].starts == 1)
        #expect(manager.state == .capturing)
    }

    @Test("A failed hardware rebuild remains latched until explicit user retry")
    func rebuildFailureDoesNotRetryOnDemandChurn() throws {
        var services: [RecoveryCaptureService] = []
        let manager = SystemAudioCaptureManager {
            let service = RecoveryCaptureService(fails: services.count == 1)
            services.append(service)
            return service
        }
        defer { manager.shutdown() }
        manager.setEnabled(true)
        manager.retain()
        let old = try #require(services.first?.invalidation)
        old()
        #expect(services.count == 2)
        guard case .failed = manager.state else { Issue.record("Rebuild failure must be latched"); return }
        old()
        manager.release()
        manager.retain()
        #expect(services.count == 2)
        manager.retryAccessRequest()
        #expect(services.count == 3)
        #expect(manager.state == .capturing)
        old()
        #expect(services.count == 3)
    }
}
#endif
