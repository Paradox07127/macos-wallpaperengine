#if !LITE_BUILD
import Foundation
@testable import LiveWallpaper
import Metal
import Testing

@Suite("Live Metal library sharing")
struct WPEMetalLibraryRegistryTests {
    private static let source = """
    #include <metal_stdlib>
    using namespace metal;
    kernel void registryProbe(device uint *output [[buffer(0)]]) { output[0] = 7; }
    """

    @Test func liveLibrariesAreReusedAcrossCompilerClients() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let counter = State()
        let registry = registry(counter)
        let first = try registry.library(device: device, source: Self.source)
        let second = try registry.library(device: device, source: Self.source)
        #expect(first === second)
        #expect(counter.count == 1)
    }

    @Test func sourceAndCompileOptionsArePartOfTheIdentity() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let counter = State()
        let registry = registry(counter)
        let first = try registry.library(device: device, source: Self.source)
        let changed = try registry.library(device: device, source: Self.source + "\n// variant")
        let precise = try registry.library(
            device: device, source: Self.source,
            configuration: .init(fastMathEnabled: false)
        )
        withExtendedLifetime([first, changed, precise]) {
            #expect(counter.count == 3)
        }
    }

    @Test func concurrentRequestsShareOneCompile() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let state = State()
        let registry = registry(state)
        DispatchQueue.concurrentPerform(iterations: 16) { _ in
            do {
                try state.append(registry.library(device: device, source: Self.source))
            } catch {
                Issue.record(error)
            }
        }
        #expect(state.count == 1)
        #expect(state.libraries.count == 16)
        if let first = state.libraries.first {
            #expect(state.libraries.allSatisfy { $0 === first })
        }
    }

    @Test func failedCompileDoesNotPoisonLaterRequests() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let state = State()
        let registry = WPEMetalLibraryRegistry { device, source, configuration in
            if state.increment() == 1 {
                throw ProbeError.firstAttempt
            }
            return try device.makeLibrary(source: source, options: configuration.makeOptions())
        }
        #expect(throws: ProbeError.self) {
            try registry.library(device: device, source: Self.source)
        }
        let recovered = try registry.library(device: device, source: Self.source)
        #expect(recovered.makeFunction(name: "registryProbe") != nil)
        #expect(state.count == 2)
    }

    @Test func concurrentFailureReachesEveryWaiterAndLaterCallCanRetry() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let state = State()
        let ownerEntered = DispatchSemaphore(value: 0)
        let releaseOwner = DispatchSemaphore(value: 0)
        let registry = WPEMetalLibraryRegistry { device, source, configuration in
            if state.increment() == 1 {
                ownerEntered.signal()
                // Bound the gate even if the test's waiter assertion fails.
                _ = releaseOwner.wait(timeout: .now() + 20)
                throw ProbeError.firstAttempt
            }
            return try device.makeLibrary(source: source, options: configuration.makeOptions())
        }
        defer { releaseOwner.signal() }
        let queue = DispatchQueue(label: "registry.failure-fanout", qos: .userInitiated, attributes: .concurrent)
        let completed = DispatchGroup()
        let request: @Sendable () -> Void = {
            do {
                try state.append(registry.library(device: device, source: Self.source))
                Issue.record("The failing flight unexpectedly returned a library")
            } catch ProbeError.firstAttempt {
                state.recordExpectedFailure()
            } catch {
                Issue.record(error)
            }
        }
        queue.async(group: completed, execute: request)
        try #require(ownerEntered.wait(timeout: .now() + 5) == .success)
        for _ in 0 ..< 7 {
            queue.async(group: completed, execute: request)
        }

        // Observe the real registry wait branch; a start barrier or fixed sleep
        // cannot prove the callers joined the same flight before its failure.
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while registry.waitingRequestCountForTesting < 7,
              ProcessInfo.processInfo.systemUptime < deadline {
            Thread.sleep(forTimeInterval: 0.001)
        }
        let joinedWaiters = registry.waitingRequestCountForTesting
        releaseOwner.signal()
        try #require(completed.wait(timeout: .now() + 10) == .success)
        #expect(joinedWaiters == 7)
        #expect(state.count == 1)
        #expect(state.expectedFailureCount == 8)
        #expect(state.libraries.isEmpty)
        #expect(registry.waitingRequestCountForTesting == 0)
        #expect(registry.entryCountForTesting == 0)

        let recovered = try registry.library(device: device, source: Self.source)
        #expect(recovered.makeFunction(name: "registryProbe") != nil)
        #expect(state.count == 2)
    }

    @Test func registryDoesNotRetainLibrariesAfterTheirOwnersReleaseThem() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let registry = WPEMetalLibraryRegistry()
        weak var released: MTLLibrary?
        try autoreleasepool {
            let library = try registry.library(device: device, source: Self.source)
            released = library
            #expect(released != nil)
        }
        #expect(released == nil)
    }

    @Test func metadataIsBoundedEvenWhileClientsKeepLibrariesAlive() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let registry = WPEMetalLibraryRegistry(capacity: 2)
        let libraries = try (0 ..< 4).map { index in
            try registry.library(device: device, source: Self.source + "\n// \(index)")
        }
        withExtendedLifetime(libraries) {
            #expect(registry.entryCountForTesting == 2)
        }
    }

    @Test func modernMathOptionsPreserveTheLegacyPolicy() {
        if #available(macOS 15.0, *) {
            let fast = WPEMetalLibraryRegistry.Configuration().makeOptions()
            #expect(fast.mathMode == .fast)
            #expect(fast.mathFloatingPointFunctions == .fast)
            let precise = WPEMetalLibraryRegistry.Configuration(fastMathEnabled: false).makeOptions()
            #expect(precise.mathMode == .safe)
            #expect(precise.mathFloatingPointFunctions == .precise)
        }
    }

    private func registry(_ state: State) -> WPEMetalLibraryRegistry {
        WPEMetalLibraryRegistry { device, source, configuration in
            _ = state.increment()
            return try device.makeLibrary(source: source, options: configuration.makeOptions())
        }
    }

    private enum ProbeError: Error { case firstAttempt }

    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var storedCount = 0
        private var storedLibraries: [MTLLibrary] = []
        private var storedExpectedFailureCount = 0

        var count: Int {
            lock.withLock { storedCount }
        }

        var libraries: [MTLLibrary] {
            lock.withLock { storedLibraries }
        }

        var expectedFailureCount: Int {
            lock.withLock { storedExpectedFailureCount }
        }

        func recordExpectedFailure() {
            lock.withLock { storedExpectedFailureCount += 1 }
        }

        func increment() -> Int {
            lock.withLock {
                storedCount += 1
                return storedCount
            }
        }

        func append(_ library: MTLLibrary) {
            lock.withLock { storedLibraries.append(library) }
        }
    }
}
#endif
