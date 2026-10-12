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
            var stages: [WPEParityShaderKey.Stage: WPEParityCompiledStages.Stage] = [:]
            for stage in request.stages {
                let json = """
                {"schema":1,"stage":"\(stage.rawValue)","entry":"\(stage.rawValue)Main",
                 "cbuffers":[],"resources":[],"topLevelArgumentBuffer":[],
                 "vertexInputs":[],"stageOutputs":[],"mscReflection":{}}
                """
                stages[stage] = .init(metallib: Data(repeating: 0xAB, count: 512),
                                      reflectionJSON: Data((invalidReflection ? "invalid" : json).utf8))
            }
            return .init(stages: stages)
        }
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
