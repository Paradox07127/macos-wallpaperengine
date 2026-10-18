#if !LITE_BUILD
import Foundation
@testable import LiveWallpaper
import LiveWallpaperProWPE
import Testing

struct WPEParityShaderStoreTests {
    private actor Compiler: WPEParityShaderCompiling {
        enum Failure: Error { case failed }
        private(set) var calls = 0
        var failuresRemaining: Int
        let invalidReflection: Bool

        init(failuresRemaining: Int = 0, invalidReflection: Bool = false) {
            self.failuresRemaining = failuresRemaining
            self.invalidReflection = invalidReflection
        }

        func compile(_ request: WPEParityShaderCompileRequest) async throws -> WPEParityCompiledStages {
            calls += 1
            let shouldFail = failuresRemaining > 0
            if shouldFail {
                failuresRemaining -= 1
            }
            try await Task.sleep(for: .milliseconds(100))
            if shouldFail {
                throw Failure.failed
            }
            return Self.output(for: request, invalidReflection: invalidReflection)
        }

        static func output(for request: WPEParityShaderCompileRequest,
                           invalidReflection: Bool = false) -> WPEParityCompiledStages {
            var stages: [WPEParityShaderKey.Stage: WPEParityCompiledStages.Stage] = [:]
            for stage in request.stages {
                let json = """
                {"schema":1,"stage":"\(stage.rawValue)","entry":"\(stage.rawValue)Main",
                 "cbuffers":[],"resources":[],"topLevelArgumentBuffer":[],
                 "vertexInputs":[],"stageOutputs":[],"mscReflection":{}}
                """
                stages[stage] = .init(metallib: Data(repeating: 0xAB, count: 512),
                                      reflectionJSON: Data((invalidReflection ? "invalid" : json).utf8),
                                      stageIn: stage == .vertex && request.stages.contains(.geometry)
                                          ? Data(repeating: 0xCD, count: 64) : nil)
            }
            return .init(stages: stages)
        }
    }

    private actor ConcurrencyProbe: WPEParityShaderCompiling {
        private var running = 0
        private(set) var peak = 0

        func compile(_ request: WPEParityShaderCompileRequest) async throws -> WPEParityCompiledStages {
            running += 1
            peak = max(peak, running)
            defer { running -= 1 }
            try await Task.sleep(for: .milliseconds(20))
            return Compiler.output(for: request)
        }
    }

    /// Every compile waits until `open()`.
    private actor GatedCompiler: WPEParityShaderCompiling {
        private(set) var calls = 0
        private var failuresRemaining: Int
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        init(failuresRemaining: Int = 0) {
            self.failuresRemaining = failuresRemaining
        }

        func compile(_ request: WPEParityShaderCompileRequest) async throws -> WPEParityCompiledStages {
            calls += 1
            if !isOpen {
                await withCheckedContinuation { waiters.append($0) }
            }
            if failuresRemaining > 0 {
                failuresRemaining -= 1
                throw Compiler.Failure.failed
            }
            return Compiler.output(for: request)
        }

        func open() {
            isOpen = true
            waiters.forEach { $0.resume() }
            waiters = []
        }
    }

    /// Starts `first` on one store, then `second` on another sharing its in-flight table, and opens the compiler
    /// once the second request has joined.
    private func joinedPair(_ compiler: GatedCompiler, in directory: URL)
        async -> (first: Result<WPEParityShaderArtifact, Error>, second: Result<WPEParityShaderArtifact, Error>,
                  stores: [WPEParityShaderStore]) {
        let table = WPEParityShaderInFlightTable()
        let stores = ["a", "b"].map {
            let disk = WPEParityShaderDiskCache(cachesURL: directory.appendingPathComponent($0, isDirectory: true))
            return WPEParityShaderStore(compiler: compiler, diskCache: disk, inFlight: table)
        }
        let shader = request()
        let first = Task { try await stores[0].artifact(for: shader) }
        while await compiler.calls == 0 {
            await Task.yield()
        }
        let second = Task { try await stores[1].artifact(for: shader) }
        while stores[1].statistics.joinedRequests == 0 {
            await Task.yield()
        }
        await compiler.open()
        return await (first.result, second.result, stores)
    }

    private func request(_ byte: UInt8 = 1, geometry: Bool = false) -> WPEParityShaderCompileRequest {
        .init(program: .init(vertex: [byte], geometry: geometry ? [3] : nil, fragment: [2]),
              compilerIdentity: "test DXC; test MSC", bindingABIVersion: 1)
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func entry(_ request: WPEParityShaderCompileRequest, in directory: URL) -> URL {
        directory.appendingPathComponent("wpe-parity-shaders/v1/\(request.key.rawValue)", isDirectory: true)
    }

    private func byteCount(in directory: URL) throws -> Int {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])
            .reduce(0) { try $0 + ($1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
    }

    @Test func missThenMemoryAndDiskHit() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let compiler = Compiler()
        let disk = WPEParityShaderDiskCache(cachesURL: directory)
        let store = WPEParityShaderStore(compiler: compiler, diskCache: disk)
        let request = request(geometry: true)
        let artifact = try await store.artifact(for: request)
        #expect(artifact.vertex.functionName == "vertexMain")
        #expect(artifact.fragment.functionName == "fragmentMain")
        #expect(artifact.geometry?.functionName == "geometryMain")
        #expect(artifact.vertex.metallib == Data(repeating: 0xAB, count: 512))
        _ = try await store.artifact(for: request)
        let coldStore = WPEParityShaderStore(compiler: compiler, diskCache: WPEParityShaderDiskCache(cachesURL: directory))
        let restored = try await coldStore.artifact(for: request)
        #expect(restored.geometry?.reflection.stage == .geometry)
        #expect(restored.fragment.functionName == artifact.fragment.functionName)
        #expect(await compiler.calls == 1)
    }

    @Test func concurrentRequestsShareOneCompile() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let compiler = Compiler()
        let store = WPEParityShaderStore(compiler: compiler, diskCache: WPEParityShaderDiskCache(cachesURL: directory))
        let request = request()
        let artifacts = try await withThrowingTaskGroup(of: WPEParityShaderArtifact.self) { group in
            for _ in 0 ..< 8 {
                group.addTask { try await store.artifact(for: request) }
            }
            var artifacts: [WPEParityShaderArtifact] = []
            for try await artifact in group {
                artifacts.append(artifact)
            }
            return artifacts
        }
        #expect(artifacts.count == 8)
        #expect(artifacts.allSatisfy { $0.vertex.functionName == "vertexMain" && $0.geometry == nil })
        #expect(await compiler.calls == 1)
    }

    @Test(.timeLimit(.minutes(1))) func compilesAcrossStoresShareOneConcurrencyLimit() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let probe = ConcurrencyProbe()
        let stores = (0 ..< 2).map { _ in
            WPEParityShaderStore(compiler: probe, diskCache: WPEParityShaderDiskCache(cachesURL: directory))
        }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for (index, store) in stores.enumerated() {
                for offset in 0 ..< 40 {
                    let shader = request(UInt8(index * 40 + offset))
                    group.addTask { _ = try await store.artifact(for: shader) }
                }
            }
            try await group.waitForAll()
        }
        let peak = await probe.peak
        #expect(peak <= ProcessInfo.processInfo.activeProcessorCount, "peak concurrent compiles: \(peak)")
    }

    @Test(.timeLimit(.minutes(1))) func cancelledPermitWaitersLeaveNoPermitBehind() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let limiter = WPEParityShaderCompileLimiter(capacity: 1)
        try await limiter.acquire()
        let waiters = (0 ..< 4).map { _ in
            Task { () -> Bool in
                do {
                    try await limiter.acquire()
                    return false
                } catch {
                    return error is CancellationError
                }
            }
        }
        try await Task.sleep(for: .milliseconds(50))
        waiters.forEach { $0.cancel() }
        for waiter in waiters {
            #expect(await waiter.value)
        }
        limiter.release()
        let store = WPEParityShaderStore(compiler: Compiler(), diskCache: WPEParityShaderDiskCache(cachesURL: directory),
                                         limiter: limiter)
        let artifact = try await store.artifact(for: request())
        #expect(artifact.vertex.functionName == "vertexMain")
        try await limiter.acquire()
        limiter.release()
    }

    @Test func statisticsSplitRequestsByOutcome() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let compiler = Compiler()
        let first = request(1), second = request(2)
        let storeA = WPEParityShaderStore(compiler: compiler, diskCache: WPEParityShaderDiskCache(cachesURL: directory))
        _ = try await storeA.artifact(for: first)
        #expect(storeA.statistics.compilations == 1)
        _ = try await storeA.artifact(for: first)
        #expect(storeA.statistics.memoryHits == 1)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0 ..< 8 {
                group.addTask { _ = try await storeA.artifact(for: second) }
            }
            try await group.waitForAll()
        }
        let a = storeA.statistics
        #expect(a.compilations == 2)
        #expect(a.memoryHits + a.joinedRequests == 8)

        let storeB = WPEParityShaderStore(compiler: compiler, diskCache: WPEParityShaderDiskCache(cachesURL: directory))
        _ = try await storeB.artifact(for: first)
        let b = storeB.statistics
        #expect(b.diskHits == 1)
        #expect(b.compilations == 0)

        let fresh = try self.directory()
        defer { try? FileManager.default.removeItem(at: fresh) }
        let storeC = WPEParityShaderStore(compiler: Compiler(failuresRemaining: 1),
                                          diskCache: WPEParityShaderDiskCache(cachesURL: fresh))
        _ = try? await storeC.artifact(for: first)
        let c = storeC.statistics
        #expect(c.compilationFailures == 1)

        for counts in [a, b, c] {
            #expect(counts.requests == counts.memoryHits + counts.joinedRequests + counts.diskHits + counts.compilations)
        }
    }

    @Test func failedCompileReachesAllWaitersAndRetries() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let compiler = Compiler(failuresRemaining: 1)
        let disk = WPEParityShaderDiskCache(cachesURL: directory)
        let store = WPEParityShaderStore(compiler: compiler, diskCache: disk)
        let request = request()
        let errors = await withTaskGroup(of: Bool.self) { group in
            for _ in 0 ..< 8 {
                group.addTask {
                    do {
                        _ = try await store.artifact(for: request)
                        return false
                    } catch Compiler.Failure.failed {
                        return true
                    } catch {
                        return false
                    }
                }
            }
            var errors = 0
            for await failed in group where failed {
                errors += 1
            }
            return errors
        }
        #expect(errors == 8)
        #expect(await compiler.calls == 1)
        #expect(await disk.read(request.key) == nil)
        _ = try await store.artifact(for: request)
        #expect(await compiler.calls == 2)
    }

    @Test(.timeLimit(.minutes(1))) func storesSharingInFlightTableCompileEachKeyOnce() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let compiler = GatedCompiler()
        let (first, second, stores) = await joinedPair(compiler, in: directory)
        #expect(try first.get().vertex.functionName == "vertexMain")
        #expect(try second.get().vertex.functionName == "vertexMain")
        #expect(await compiler.calls == 1)
        #expect(stores[0].statistics.compilations == 1)
        #expect(stores[0].statistics.joinedRequests == 0)
        #expect(stores[1].statistics.compilations == 0)
        #expect(stores[1].statistics.joinedRequests == 1)
        _ = try await stores[1].artifact(for: request())
        #expect(stores[1].statistics.memoryHits == 1)
        #expect(await compiler.calls == 1)
    }

    @Test(.timeLimit(.minutes(1))) func sharedInFlightFailureReachesJoinedStoreAndRetries() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let compiler = GatedCompiler(failuresRemaining: 1)
        let (first, second, stores) = await joinedPair(compiler, in: directory)
        for result in [first, second] {
            #expect(throws: Compiler.Failure.failed) { try result.get() }
        }
        #expect(await compiler.calls == 1)
        _ = try await stores[1].artifact(for: request())
        #expect(await compiler.calls == 2)
        #expect(stores[1].statistics.compilations == 1)
    }

    @Test func corruptOrMissingFilesAreDeletedAndRecompiled() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let compiler = Compiler()
        let disk = WPEParityShaderDiskCache(cachesURL: directory)
        let request = request()
        let store = WPEParityShaderStore(compiler: compiler, diskCache: disk)
        _ = try await store.artifact(for: request)
        let path = entry(request, in: directory)
        for (name, replacement) in [("vertex.metallib", Data(repeating: 0xCD, count: 512)),
                                    ("fragment.json", Data("short".utf8)),
                                    ("vertex.json", nil), ("manifest.json", Data("invalid".utf8))] {
            let file = path.appendingPathComponent(name)
            if let replacement {
                try replacement.write(to: file)
            } else {
                try FileManager.default.removeItem(at: file)
            }
            #expect(await disk.read(request.key) == nil)
            #expect(!FileManager.default.fileExists(atPath: path.path))
            let coldStore = WPEParityShaderStore(compiler: compiler, diskCache: disk)
            _ = try await coldStore.artifact(for: request)
        }
        #expect(await compiler.calls == 5)
    }

    @Test func evictionUsesLastReadAndIncludesManifestBytes() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let compiler = Compiler()
        let first = request(1), second = request(2), third = request(3)
        let initial = WPEParityShaderDiskCache(cachesURL: directory)
        let store = WPEParityShaderStore(compiler: compiler, diskCache: initial)
        _ = try await store.artifact(for: first)
        _ = try await store.artifact(for: second)
        let budget = try byteCount(in: entry(first, in: directory)) + byteCount(in: entry(second, in: directory)) + 32
        for (request, age) in [(first, 100.0), (second, 50.0)] {
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -age)],
                                                  ofItemAtPath: entry(request, in: directory).path)
        }
        let bounded = WPEParityShaderDiskCache(cachesURL: directory, sizeBudget: budget)
        #expect(await bounded.read(first.key) != nil)
        let boundedStore = WPEParityShaderStore(compiler: compiler, diskCache: bounded)
        _ = try await boundedStore.artifact(for: third)
        #expect(await bounded.read(first.key) != nil)
        #expect(await bounded.read(second.key) == nil)
        #expect(await bounded.read(third.key) != nil)
        let total = try byteCount(in: entry(first, in: directory)) + byteCount(in: entry(third, in: directory))
        #expect(total <= budget)
        _ = try await boundedStore.artifact(for: second)
        #expect(await compiler.calls == 4)
        let tiny = WPEParityShaderDiskCache(cachesURL: directory, sizeBudget: 1)
        let tinyStore = WPEParityShaderStore(compiler: compiler, diskCache: tiny)
        _ = try await tinyStore.artifact(for: request(4))
        #expect(await tiny.read(request(4).key) == nil)
    }

    @Test func evictionCountsEntriesLeftByAnEarlierInstance() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let compiler = Compiler()
        let first = request(1), second = request(2), third = request(3)
        let earlier = WPEParityShaderStore(compiler: compiler, diskCache: WPEParityShaderDiskCache(cachesURL: directory))
        _ = try await earlier.artifact(for: first)
        _ = try await earlier.artifact(for: second)
        let budget = try byteCount(in: entry(first, in: directory)) + byteCount(in: entry(second, in: directory)) + 32
        for (request, age) in [(first, 100.0), (second, 50.0)] {
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -age)],
                                                  ofItemAtPath: entry(request, in: directory).path)
        }
        let later = WPEParityShaderStore(compiler: compiler,
                                         diskCache: WPEParityShaderDiskCache(cachesURL: directory, sizeBudget: budget))
        _ = try await later.artifact(for: third)
        #expect(!FileManager.default.fileExists(atPath: entry(first, in: directory).path))
        #expect(FileManager.default.fileExists(atPath: entry(second, in: directory).path))
        #expect(FileManager.default.fileExists(atPath: entry(third, in: directory).path))
        let root = directory.appendingPathComponent("wpe-parity-shaders/v1", isDirectory: true)
        let total = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            .reduce(0) { try $0 + byteCount(in: $1) }
        #expect(total <= budget)
    }

    @Test func invalidCompilerOutputIsNotCached() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let compiler = Compiler(invalidReflection: true)
        let disk = WPEParityShaderDiskCache(cachesURL: directory)
        let store = WPEParityShaderStore(compiler: compiler, diskCache: disk)
        for _ in 0 ..< 2 {
            do {
                _ = try await store.artifact(for: request())
                Issue.record("Invalid reflection should fail")
            } catch is DecodingError {
                // Expected: decoding is part of compilation admission.
            }
        }
        #expect(await compiler.calls == 2)
        #expect(await disk.read(request().key) == nil)
    }
}
#endif
