#if !LITE_BUILD
import Foundation
import LiveWallpaperProWPE

actor WPEParityShaderStore {
    enum ArtifactError: Error {
        case invalidStages
        case invalidReflection
    }

    private let compiler: any WPEParityShaderCompiling
    private let diskCache: WPEParityShaderDiskCache
    private var memory: [WPEParityShaderKey: WPEParityShaderArtifact] = [:]
    private var inFlight: [WPEParityShaderKey: Task<WPEParityShaderArtifact, Error>] = [:]

    init(compiler: any WPEParityShaderCompiling, diskCache: WPEParityShaderDiskCache) {
        self.compiler = compiler
        self.diskCache = diskCache
    }

    func artifact(for request: WPEParityShaderCompileRequest) async throws -> WPEParityShaderArtifact {
        if let artifact = memory[request.key] {
            return artifact
        }
        if let task = inFlight[request.key] {
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
                memory[request.key] = artifact
                return artifact
            }
            await diskCache.remove(request.key)
        }
        let compiled = try await compiler.compile(request)
        let artifact = try Self.decode(compiled, for: request)
        await diskCache.write(compiled, for: request.key)
        memory[request.key] = artifact
        return artifact
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
