#if !LITE_BUILD
import Foundation
import LiveWallpaperProWPE
import os

/// FIFO counting semaphore; a cancelled waiter throws CancellationError without taking a permit.
final class WPEParityShaderCompileLimiter: Sendable {
    static let shared = WPEParityShaderCompileLimiter(capacity: ProcessInfo.processInfo.activeProcessorCount)

    private struct State {
        var available: Int
        var waiters: [(id: UUID, continuation: CheckedContinuation<Void, Error>)] = []
    }

    private let state: OSAllocatedUnfairLock<State>

    init(capacity: Int) {
        state = OSAllocatedUnfairLock(initialState: State(available: max(1, capacity)))
    }

    func acquire() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let granted: Bool? = state.withLock { state in
                    // Cancellation before enqueueing is only visible here: the handler found no waiter to remove.
                    if Task.isCancelled {
                        return false
                    }
                    if state.available > 0 {
                        state.available -= 1
                        return true
                    }
                    state.waiters.append((id, continuation))
                    return nil
                }
                switch granted {
                case true?: continuation.resume()
                case false?: continuation.resume(throwing: CancellationError())
                case nil: break
                }
            }
        } onCancel: {
            let waiter = state.withLock { state in
                state.waiters.firstIndex { $0.id == id }.map { state.waiters.remove(at: $0).continuation }
            }
            waiter?.resume(throwing: CancellationError())
        }
    }

    func release() {
        let next = state.withLock { state in
            if state.waiters.isEmpty {
                state.available += 1
                return nil as CheckedContinuation<Void, Error>?
            }
            return state.waiters.removeFirst().continuation
        }
        next?.resume()
    }
}

actor WPEParityShaderStore {
    enum ArtifactError: Error {
        case invalidStages
        case invalidReflection
    }

    /// Each request has one outcome: memoryHits, joinedRequests, diskHits or compilations.
    struct Statistics: Sendable, Equatable {
        var requests = 0
        var memoryHits = 0
        var joinedRequests = 0
        var diskHits = 0
        /// Includes disk entries that failed decode.
        var compilations = 0
        /// Compilations that threw or whose output failed decode.
        var compilationFailures = 0
    }

    private let compiler: any WPEParityShaderCompiling
    private let diskCache: WPEParityShaderDiskCache
    private let limiter: WPEParityShaderCompileLimiter
    private var memory: [WPEParityShaderKey: WPEParityShaderArtifact] = [:]
    private var inFlight: [WPEParityShaderKey: Task<WPEParityShaderArtifact, Error>] = [:]
    private nonisolated let counts = OSAllocatedUnfairLock(initialState: Statistics())

    nonisolated var statistics: Statistics {
        counts.withLock { $0 }
    }

    init(compiler: any WPEParityShaderCompiling, diskCache: WPEParityShaderDiskCache,
         limiter: WPEParityShaderCompileLimiter = .shared) {
        self.compiler = compiler
        self.diskCache = diskCache
        self.limiter = limiter
    }

    func artifact(for request: WPEParityShaderCompileRequest) async throws -> WPEParityShaderArtifact {
        count(\.requests)
        if let artifact = memory[request.key] {
            count(\.memoryHits)
            return artifact
        }
        if let task = inFlight[request.key] {
            count(\.joinedRequests)
            return try await task.value
        }
        let task = Task { try await self.load(request) }
        inFlight[request.key] = task
        return try await task.value
    }

    private func load(_ request: WPEParityShaderCompileRequest) async throws -> WPEParityShaderArtifact {
        defer { inFlight[request.key] = nil }
        if let compiled = await diskCache.read(request.key) {
            if let artifact = try? Self.decode(compiled, for: request) {
                count(\.diskHits)
                memory[request.key] = artifact
                return artifact
            }
            await diskCache.remove(request.key)
        }
        count(\.compilations)
        let compiled: WPEParityCompiledStages
        let artifact: WPEParityShaderArtifact
        do {
            compiled = try await compileHoldingPermit(request)
            artifact = try Self.decode(compiled, for: request)
        } catch {
            count(\.compilationFailures)
            throw error
        }
        await diskCache.write(compiled, for: request.key)
        memory[request.key] = artifact
        return artifact
    }

    private func compileHoldingPermit(_ request: WPEParityShaderCompileRequest) async throws -> WPEParityCompiledStages {
        try await limiter.acquire()
        defer { limiter.release() }
        return try await compiler.compile(request)
    }

    private nonisolated func count(_ outcome: any WritableKeyPath<Statistics, Int> & Sendable) {
        counts.withLock { $0[keyPath: outcome] += 1 }
    }

    private static func decode(_ compiled: WPEParityCompiledStages,
                               for request: WPEParityShaderCompileRequest) throws -> WPEParityShaderArtifact {
        guard Set(compiled.stages.keys) == request.stages,
              compiled.stages[.vertex] != nil, compiled.stages[.fragment] != nil else {
            throw ArtifactError.invalidStages
        }
        let geometry = request.stages.contains(.geometry)
        func stage(_ name: WPEParityShaderKey.Stage) throws -> WPEParityShaderArtifact.Stage {
            guard let bytes = compiled.stages[name], !bytes.metallib.isEmpty,
                  (bytes.stageIn?.isEmpty == false) == (geometry && name == .vertex) else {
                throw ArtifactError.invalidStages
            }
            let reflection = try JSONDecoder().decode(WPEStageReflection.self, from: bytes.reflectionJSON)
            guard reflection.schema == 1, reflection.stage.rawValue == name.rawValue, !reflection.entry.isEmpty else {
                throw ArtifactError.invalidReflection
            }
            return .init(metallib: bytes.metallib, reflection: reflection, functionName: reflection.entry,
                         stageIn: bytes.stageIn)
        }
        return try WPEParityShaderArtifact(vertex: stage(.vertex), fragment: stage(.fragment),
                                           geometry: compiled.stages[.geometry] == nil ? nil : stage(.geometry))
    }
}
#endif
