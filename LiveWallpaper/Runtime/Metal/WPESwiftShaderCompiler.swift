#if !LITE_BUILD
import Foundation
import Metal

/// `recordFailure` false (off-thread pre-warm) so a failing shader is recorded once by the real first-frame render, not twice.
struct WPESwiftShaderCompiler: Sendable {
    let device: MTLDevice
    let translationCache: WPEShaderTranslationCache
    let libraryRegistry: WPEMetalLibraryRegistry
    /// Fragment-only: vertex execution stays on the built-in fullscreen quad; model/vertex-domain shaders are never compiled here.
    static let fixedVertexFunctionName = "wpe_fullscreen_vertex"

    init(
        device: MTLDevice,
        translationCache: WPEShaderTranslationCache = .shared,
        libraryRegistry: WPEMetalLibraryRegistry = .shared
    ) {
        self.device = device
        self.translationCache = translationCache
        self.libraryRegistry = libraryRegistry
    }

    func compile(_ request: WPEShaderCompileRequest, recordFailure: Bool = true) throws -> WPEShaderCompileResult {
        let cacheKey = request.translationCacheKey
        if let payload = translationCache.lookup(cacheKey) {
            do {
                return try assemble(
                    mslSource: payload.mslSource,
                    vertexFunctionName: payload.vertexFunctionName,
                    fragmentFunctionName: payload.fragmentFunctionName,
                    uniformLayout: payload.uniformSlots(),
                    samplerNames: payload.samplerNames,
                    textureSlotCount: payload.textureSlotCount,
                    shaderName: request.shaderName,
                    processedVertex: request.processedVertexSource,
                    processedFragment: request.processedFragmentSource,
                    recordFailure: recordFailure
                )
            } catch {
                translationCache.remove(cacheKey)
            }
        }

        let translation: WPEShaderTranslationResult
        let fragmentSource = Self.fragmentSourceByAddingVertexUniformsIfNeeded(
            fragmentSource: request.processedFragmentSource,
            vertexSource: request.processedVertexSource
        )
        do {
            translation = try WPEShaderTranspiler.translateFragment(
                shaderName: request.shaderName,
                preprocessedSource: fragmentSource,
                comboValues: request.comboValues,
                premultipliedInputSlots: request.premultipliedInputSlots,
                premultipliedOutput: request.premultipliedOutput
            )
        } catch let err as WPEShaderCompilerError {
            if recordFailure {
                WPESceneDebugArtifacts.shared.recordShaderFailure(
                    shaderName: request.shaderName,
                    originalVertex: nil,
                    processedVertex: request.processedVertexSource,
                    originalFragment: nil,
                    processedFragment: request.processedFragmentSource,
                    translatedMSL: nil,
                    errorText: "translation failed: \(String(describing: err))"
                )
            }
            throw err
        } catch {
            if recordFailure {
                WPESceneDebugArtifacts.shared.recordShaderFailure(
                    shaderName: request.shaderName,
                    originalVertex: nil,
                    processedVertex: request.processedVertexSource,
                    originalFragment: nil,
                    processedFragment: request.processedFragmentSource,
                    translatedMSL: nil,
                    errorText: "transpiler crashed: \(error)"
                )
            }
            throw WPEShaderCompilerError.translationFailed(
                "transpiler crashed for '\(request.shaderName)': \(error)"
            )
        }

        let result = try assemble(
            mslSource: translation.mslSource,
            vertexFunctionName: Self.fixedVertexFunctionName,
            fragmentFunctionName: "wpe_translated_fragment",
            uniformLayout: translation.uniformLayout,
            samplerNames: translation.samplers,
            textureSlotCount: translation.textureSlotCount,
            shaderName: request.shaderName,
            processedVertex: request.processedVertexSource,
            processedFragment: request.processedFragmentSource,
            recordFailure: recordFailure
        )
        if let payload = WPEShaderTranslationCache.Payload.from(result) {
            translationCache.store(payload, for: cacheKey)
        }
        return result
    }

    private func assemble(
        mslSource: String,
        vertexFunctionName: String,
        fragmentFunctionName: String,
        uniformLayout: [WPEUniformSlot],
        samplerNames: [String],
        textureSlotCount: Int,
        shaderName: String,
        processedVertex: String,
        processedFragment: String,
        recordFailure: Bool
    ) throws -> WPEShaderCompileResult {
        let library: MTLLibrary
        do {
            library = try libraryRegistry.library(device: device, source: mslSource)
        } catch {
            if recordFailure {
                WPESceneDebugArtifacts.shared.recordShaderFailure(
                    shaderName: shaderName,
                    originalVertex: nil,
                    processedVertex: processedVertex,
                    originalFragment: nil,
                    processedFragment: processedFragment,
                    translatedMSL: mslSource,
                    errorText: "Metal rejected MSL: \(error.localizedDescription)"
                )
            }
            // Don't inline the generated MSL into the thrown reason: it can flow into user-facing diagnostics.
            throw WPEShaderCompilerError.mslLibraryFailed(
                "Metal rejected translated MSL for '\(shaderName)': \(error.localizedDescription)"
            )
        }
        return WPEShaderCompileResult(
            library: library,
            vertexFunctionName: vertexFunctionName,
            fragmentFunctionName: fragmentFunctionName,
            mslSource: mslSource,
            uniformLayout: uniformLayout,
            samplerNames: samplerNames,
            textureSlotCount: textureSlotCount
        )
    }

    private static func fragmentSourceByAddingVertexUniformsIfNeeded(
        fragmentSource: String,
        vertexSource: String
    ) -> String {
        // Scan the fragment AFTER branch stripping: a uniform only in an inactive `#if` would count as existing, then vanish with its branch.
        let activeFragment = WPEShaderTranspiler.stripInactivePreprocessorBranches(in: fragmentSource)
        let existing = Set(uniformDeclarations(in: activeFragment).map(\.name))
        let activeVertex = WPEShaderTranspiler.stripInactivePreprocessorBranches(in: vertexSource)
        var seen = Set<String>()
        // Inject the ORIGINAL declaration lines: the trailing `// {"material":…}` annotation binds constantshadervalues; a bare re-declaration would unbind them.
        let missingLines = activeVertex.components(separatedBy: .newlines).compactMap { raw -> String? in
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            guard let uniform = WPEUniformDecl.parse(line: trimmed),
                  !existing.contains(uniform.name),
                  seen.insert(uniform.name).inserted,
                  shouldExposeVertexUniformToFragment(uniform) else { return nil }
            return trimmed
        }
        guard !missingLines.isEmpty else { return fragmentSource }
        return missingLines.joined(separator: "\n") + "\n" + fragmentSource
    }

    private static func uniformDeclarations(in source: String) -> [WPEUniformDecl] {
        source.components(separatedBy: .newlines).compactMap { raw in
            WPEUniformDecl.parse(line: raw.trimmingCharacters(in: .whitespaces))
        }
    }

    private static func shouldExposeVertexUniformToFragment(_ uniform: WPEUniformDecl) -> Bool {
        !uniform.type.hasPrefix("mat") && !uniform.name.hasPrefix("g_Model")
    }
}
#endif
