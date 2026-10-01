#if !LITE_BUILD && DEBUG
import CryptoKit
import Foundation
import LiveWallpaperProWPE
import Metal
import simd

/// DEBUG-only accumulator mirroring the Windows RenderDoc oracle into the shared `wpe.trace.v1`
/// schema. `@unchecked Sendable`: mutable state is guarded by `lock`, safe from the render
/// thread and the end-of-frame flush.
final class WPECanonicalTraceRecorder: @unchecked Sendable {
    static let shared = WPECanonicalTraceRecorder()

    struct TextureBindingInput {
        let slot: Int
        let name: String?
        let reference: WPETextureReference?
        let texture: MTLTexture?
        let fallbackToPrimary: Bool
        /// Address/filter/mip of the sampler actually bound to this slot. Leaving this nil makes the diff blind to wrap-mode divergence.
        let sampler: [String: String]?

        init(slot: Int, name: String?, reference: WPETextureReference?, texture: MTLTexture?,
             fallbackToPrimary: Bool, sampler: [String: String]? = nil) {
            self.slot = slot
            self.name = name
            self.reference = reference
            self.texture = texture
            self.fallbackToPrimary = fallbackToPrimary
            self.sampler = sampler
        }
    }

    /// `g_Texture7` -> 7. Mirrors `WPEShaderTranspiler.textureSlot(for:)`; kept
    /// local so the recorder never depends on transpiler internals.
    static func authoredTextureSlot(_ name: String?) -> Int? {
        guard let name, name.hasPrefix("g_Texture") else { return nil }
        return Int(name.dropFirst("g_Texture".count))
    }

    static func samplerName(at slot: Int, in names: [String]) -> String? {
        names.enumerated().first { (authoredTextureSlot($0.element) ?? $0.offset) == slot }?.element
    }

    /// A non-sprite texture a particle draw bound (group mask, refract normal,
    /// refract background snapshot).
    struct ParticleTextureInput {
        let slot: Int
        let name: String
        let texture: MTLTexture?
        let path: String?
    }

    struct PuppetUniformInput {
        let name: String
        let type: String
        let value: SIMD4<Float>
    }

    private let lock = NSLock()
    private var scene: SceneContext?
    private var frameComplete = false
    private var passes: [[String: Any]] = []
    private var attachmentOperations: [[String: Any]] = []
    private var attachmentPlan: [String: Any]?
    private var physicalAttachmentRevisions: [String: Int] = [:]
    private var resources: ResourceTables = ResourceTables()
    private var semanticCoverage: [WPEShaderSemanticCoverage] = []
    private var shaderImplementationInventory: [WPEShaderImplementationInventoryEntry] = []

    private let artifacts: WPESceneDebugArtifacts

    init(artifacts: WPESceneDebugArtifacts = .shared) {
        self.artifacts = artifacts
    }

    var isAccumulating: Bool {
        guard artifacts.isEnabled else { return false }
        lock.lock()
        defer { lock.unlock() }
        return scene != nil && !frameComplete
    }

    struct NativeRenderState {
        let attachment: MTLRenderPipelineColorAttachmentDescriptor
        let cullMode: MTLCullMode
        let frontCCW: Bool
        let depthAttached: Bool
        let depthCompare: MTLCompareFunction
        let depthWrite: Bool

        static func scenePass(
            blendMode: String,
            alphaWritePolicy: WPEMetalAlphaWritePolicy,
            cullMode: String,
            depthAttached: Bool,
            depthTest: String,
            depthWrite: String,
            reversedZ: Bool
        ) -> NativeRenderState {
            let attachment = MTLRenderPipelineColorAttachmentDescriptor()
            WPEMetalPipelineCache.applyBlendMode(blendMode.lowercased(), to: attachment)
            WPEMetalPipelineCache.applyAlphaWritePolicy(alphaWritePolicy, to: attachment)
            return NativeRenderState(
                attachment: attachment,
                cullMode: WPEMetalPipelineCache.cullMode(for: cullMode),
                frontCCW: true,
                depthAttached: depthAttached,
                depthCompare: WPEMetalDepthStateCache.compareFunction(
                    for: depthTest.lowercased(),
                    reversedZ: reversedZ
                ),
                depthWrite: WPEMetalDepthStateCache.depthWriteEnabled(depthWrite)
            )
        }

        /// Particle encoders never set winding, cull or depth state.
        static func particle(blendMode: WPEParticleBlendMode) -> NativeRenderState {
            let attachment = MTLRenderPipelineColorAttachmentDescriptor()
            WPEMetalRenderExecutor.applyParticleBlend(blendMode, to: attachment)
            WPEMetalPipelineCache.applyAlphaWritePolicy(WPEMetalAlphaWritePolicy.resolve(targetID: .scene, blendMode: blendMode.rawValue), to: attachment)
            return NativeRenderState(
                attachment: attachment,
                cullMode: .none,
                frontCCW: false,
                depthAttached: false,
                depthCompare: .always,
                depthWrite: false
            )
        }
    }

    /// Helper transfers are separate events, never synthetic shader draws. Revisions
    /// here identify encoded writes within this trace, not completed GPU contents.
    func recordAttachmentOperation(kind: String, label: String, source: MTLTexture? = nil,
                                   destination: MTLTexture, contract: WPEAttachmentLoadContract? = nil,
                                   writesPixels: Bool = true) {
        guard artifacts.isEnabled else { return }
        lock.lock()
        defer { lock.unlock() }
        guard scene != nil, !frameComplete else { return }
        let destinationID = textureResourceID(texture: destination, fallbackKey: "attachment")
        if resources.textures[destinationID] == nil {
            resources.textures[destinationID] = textureResource(id: destinationID, name: nil, reference: nil, texture: destination)
        }
        var sourceRecord: [String: Any]?
        if let source {
            let sourceID = textureResourceID(texture: source, fallbackKey: "attachment-source")
            if resources.textures[sourceID] == nil {
                resources.textures[sourceID] = textureResource(id: sourceID, name: nil, reference: nil, texture: source)
            }
            sourceRecord = ["resource": sourceID, "revision": physicalAttachmentRevisions[sourceID] ?? 0]
        }
        let before = physicalAttachmentRevisions[destinationID] ?? 0
        let after = before + (writesPixels ? 1 : 0)
        physicalAttachmentRevisions[destinationID] = after
        attachmentOperations.append([
            "ordinal": attachmentOperations.count, "recordedDrawsBefore": passes.count,
            "kind": kind, "label": label, "source": sourceRecord ?? NSNull(),
            "destination": ["resource": destinationID, "revisionBefore": before, "revisionAfter": after],
            "load": contract.map { Self.loadName($0.load) } ?? NSNull(),
            "store": contract.map { $0.store == .store ? "store" : "dontCare" } ?? NSNull(),
            "reason": contract.map(\.reason.rawValue) ?? NSNull(),
            "status": "encoded-not-gpu-completion", "revisionZero": "contents-unrecorded-or-external",
        ])
    }

    func recordAttachmentPlan(_ plan: WPEAttachmentPlan) {
        guard artifacts.isEnabled else { return }
        guard isAccumulating else { return }
        let record = plan.traceRecord()
        lock.lock()
        defer { lock.unlock() }
        guard scene != nil, !frameComplete else { return }
        attachmentPlan = record
    }

    private static func loadName(_ load: MTLLoadAction) -> String {
        switch load {
        case .load: "load"
        case .clear: "clear"
        case .dontCare: "dontCare"
        @unknown default: "unknown"
        }
    }

    func beginScene(
        workshopID: String,
        projectJsonPath: String?,
        descriptor: String,
        shaderImplementationInventory: [WPEShaderImplementationInventoryEntry] = []
    ) {
        guard artifacts.isEnabled else { return }
        lock.lock()
        scene = SceneContext(workshopID: workshopID, projectJsonPath: projectJsonPath, descriptor: descriptor)
        frameComplete = false
        passes.removeAll(keepingCapacity: true)
        attachmentOperations.removeAll(keepingCapacity: true)
        attachmentPlan = nil
        physicalAttachmentRevisions.removeAll(keepingCapacity: true)
        semanticCoverage.removeAll(keepingCapacity: true)
        resources = ResourceTables()
        self.shaderImplementationInventory = shaderImplementationInventory
        lock.unlock()
    }

    func recordShaderImplementationInventory(
        _ entries: [WPEShaderImplementationInventoryEntry]
    ) {
        guard !entries.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        guard scene != nil, !frameComplete else { return }
        shaderImplementationInventory = WPEShaderImplementationInventory.merging(
            shaderImplementationInventory,
            with: entries
        )
    }

    func recordCustomPass(
        pass: WPEPreparedRenderPass,
        destination: (id: WPEMetalTargetID, texture: MTLTexture),
        result: WPEShaderCompileResult,
        textureBindings: [TextureBindingInput],
        packedUniformSlots: [SIMD4<Float>],
        usesObjectQuad: Bool,
        nativeState: NativeRenderState,
        uniformSources: [WPEUniformValueSource]? = nil,
        vertexPath: WPEPassVertexPath? = nil,
        vertexUniformSlots: [SIMD4<Float>] = [],
        vertexUniformSources: [WPEUniformValueSource]? = nil,
        authoredVertexFallback: String? = nil,
        authoredObjectInputs: [SIMD4<Float>]? = nil
    ) {
        guard artifacts.isEnabled else { return }
        lock.lock()
        defer { lock.unlock() }
        guard scene != nil, !frameComplete else { return }

        let coverage = WPEShaderSemanticCoverage.observedCustomDraw(
            passID: pass.id,
            authoredEffectID: shaderImplementationInventory.first { $0.renderPassID == pass.id }?.stableEffectID,
            shaderName: pass.pass.shader,
            sourceClassification: pass.shader?.executionClassification.rawValue,
            sourceFingerprint: pass.shader?.sourceFingerprint,
            interface: result.shaderInterface, layout: result.uniformLayout, sources: uniformSources,
            vertexLayout: result.vertexStage?.uniformLayout ?? [], vertexSources: vertexUniformSources,
            authoredVertexExecuted: result.vertexStage != nil, authoredVertexFallback: authoredVertexFallback,
            authoredObjectQuadExecuted: result.vertexStage?.execution == .authoredObjectQuad
        )
        semanticCoverage.append(coverage)
        let ordinal = passes.count
        let target = destination.id
        let targetTexture = destination.texture
        let targetResource = renderTargetResourceID(target)
        let fragmentShaderID = shaderID(stage: "fs", stableInput: result.mslSource)
        let selectedVertexPath = vertexPath ?? (usesObjectQuad ? .objectQuad : .fullscreenQuad)
        let selectedVertexFunction = selectedVertexPath.functionName(default: result.vertexFunctionName)
        let vertexSource = result.vertexStage?.mslSource ?? selectedVertexFunction
        let vertexShaderID = shaderID(stage: "vs", stableInput: vertexSource)
        let packedBytes = packedUniformBytes(packedUniformSlots)
        let bufferResource = "buf-mac-pass-\(ordinal)"

        resources.renderTargets[targetResource] = renderTargetResource(target: target, texture: targetTexture, ordinal: ordinal)
        resources.buffers[bufferResource] = [
            "label": "Mac flat uniform slots pass \(ordinal)",
            "byteLength": packedBytes.count,
            "sha256": sha256Hex(packedBytes)
        ]
        resources.shaders[fragmentShaderID] = shaderResource(
            stage: "fragment",
            entryPoint: result.fragmentFunctionName,
            source: result.mslSource,
            path: "msl-\(pass.pass.id)-\(pass.pass.shader).metal",
            layout: result.uniformLayout,
            samplers: result.samplerNames
        )
        resources.shaders[vertexShaderID] = shaderResource(
            stage: "vertex",
            entryPoint: selectedVertexFunction,
            source: vertexSource,
            path: result.vertexStage == nil ? nil : "msl-vs-\(pass.pass.id)-\(pass.pass.shader).metal",
            layout: result.vertexStage?.uniformLayout ?? [],
            samplers: result.vertexStage?.samplerNames ?? []
        )

        var textures: [[String: Any]] = []
        for binding in textureBindings.sorted(by: { $0.slot < $1.slot }) {
            let texID = textureResourceID(texture: binding.texture, fallbackKey: "\(ordinal)-\(binding.slot)")
            resources.textures[texID] = textureResource(
                id: texID, name: binding.name, reference: binding.reference, texture: binding.texture
            )
            let stages = (binding.slot < result.textureSlotCount ? ["fragment"] : [])
                + (binding.slot < (result.vertexStage?.textureSlotCount ?? 0) ? ["vertex"] : [])
            for stage in stages {
                let names = stage == "vertex" ? (result.vertexStage?.samplerNames ?? []) : result.samplerNames
                let name = Self.samplerName(at: binding.slot, in: names)
                textures.append([
                    "stage": stage,
                    // The executor binds numeric authored registers directly, including holes.
                    "slot": binding.slot,
                    "name": jsonOrNull(name),
                "resource": texID,
                "reference": jsonOrNull(Self.describe(reference: binding.reference)),
                "fallback": binding.fallbackToPrimary,
                "width": jsonOrNull(binding.texture?.width),
                "height": jsonOrNull(binding.texture?.height),
                "format": jsonOrNull(binding.texture.map { pixelFormatName($0.pixelFormat) })
            ])
            }
        }

        let draw: [String: Any] = [
            "topology": result.vertexStage?.execution == .authoredObjectQuad ? "triangle-list" : (usesObjectQuad ? "object-quad" : "fullscreen-quad"),
            "vertexCount": result.vertexStage?.execution == .authoredObjectQuad ? 6 : 4,
            "indexCount": NSNull(),
            "instanceCount": 1,
            "viewport": [0, 0, Double(targetTexture.width), Double(targetTexture.height), 0, 1] as [Double],
            "scissor": [Double]()
        ]
        let colorTargets: [[String: Any]] = [[
            "slot": 0,
            "resource": targetResource,
            "load": NSNull(),
            "store": "store",
            "target": describe(target: target)
        ]]
        let constantBuffer: [String: Any] = [
            "name": "mac_flat_slots",
            "stage": "fragment",
            "slot": 0,
            "resource": bufferResource,
            "rawBytesSha256": sha256Hex(packedBytes),
            "variables": WPECanonicalUniformTrace.variables(
                layout: result.uniformLayout, slots: packedUniformSlots, sources: uniformSources
            ),
            "packedSlots": WPECanonicalUniformTrace.floatSlots(packedUniformSlots),
            "rawSlotBits": WPECanonicalUniformTrace.bitSlots(packedUniformSlots),
        ]
        var constantBuffers = [constantBuffer]
        if let vertex = result.vertexStage {
            let bytes = packedUniformBytes(vertexUniformSlots)
            let resource = "buf-mac-vertex-\(ordinal)"
            resources.buffers[resource] = ["label": "Mac authored VS slots pass \(ordinal)", "byteLength": bytes.count, "sha256": sha256Hex(bytes)]
            constantBuffers.append(["name": "mac_vertex_slots", "stage": "vertex", "slot": 0,
                                    "resource": resource, "rawBytesSha256": sha256Hex(bytes),
                                    "variables": WPECanonicalUniformTrace.variables(layout: vertex.uniformLayout, slots: vertexUniformSlots, sources: vertexUniformSources),
                                    "packedSlots": WPECanonicalUniformTrace.floatSlots(vertexUniformSlots), "rawSlotBits": WPECanonicalUniformTrace.bitSlots(vertexUniformSlots)])
        }
        // Numeric binding identity is authoritative; labels never renumber textures.
        let samplerBySlot = Dictionary(
            textureBindings.compactMap { binding in
                binding.sampler.map { (binding.slot, $0) }
            },
            uniquingKeysWith: { first, _ in first }
        )
        var samplers: [[String: Any]] = result.samplerNames.enumerated().map { index, name in
            let slot = Self.authoredTextureSlot(name) ?? index
            var entry: [String: Any] = ["stage": "fragment", "slot": slot, "name": name]
            if let descriptor = samplerBySlot[slot] { entry["descriptor"] = descriptor }
            return entry
        }
        for (index, name) in (result.vertexStage?.samplerNames ?? []).enumerated() {
            let slot = Self.authoredTextureSlot(name) ?? index
            var entry: [String: Any] = ["stage": "vertex", "slot": slot, "name": name]
            if let descriptor = samplerBySlot[slot] {
                entry["descriptor"] = descriptor
            }
            samplers.append(entry)
        }
        var state = nativeStateJSON(nativeState, logicalBlend: "\(pass.pass.blending)")
        state["samplers"] = samplers
        let output: [String: Any] = [
            "resource": targetResource,
            "png": NSNull(),
            "sha256": NSNull(),
            "visualStats": ["note": "Per-pass RT hash filled from scenePassDumps when WPEDumpScenePasses captured this pass."]
        ]
        var vertexContract = selectedVertexPath.traceRecord(defaultFunction: result.vertexFunctionName)
        if let authoredVertexFallback {
            vertexContract["fallbackReason"] = authoredVertexFallback
        }
        if let vertex = result.vertexStage {
            vertexContract["bufferValues"] = "recorded-in-constantBuffers"
            let requiredBuffers: [Int] = (vertex.uniformLayout.isEmpty ? [] : [0]) + (vertex.execution == .authoredObjectQuad ? [2] : [])
            vertexContract["requiredVertexBufferIndices"] = requiredBuffers
            if let inputs = authoredObjectInputs {
                vertexContract["geometryInput"] = ["bufferIndex": 2, "byteLength": inputs.count * MemoryLayout<SIMD4<Float>>.stride,
                                                   "positionAndUV": inputs.map { [$0.x, $0.y, $0.z, $0.w] }, "space": "centered-model-pixels"]
                vertexContract["bufferValues"] = "uniforms-in-constantBuffers; geometry-in-geometryInput"
            }
        }
        let passRecord: [String: Any] = [
            "ordinal": ordinal,
            "eventId": NSNull(),
            "layerId": jsonOrNull(layerID(forPassID: pass.pass.id)),
            "passId": pass.pass.id,
            "shaderName": pass.pass.shader,
            "draw": draw,
            "targets": ["color": colorTargets, "depth": NSNull()] as [String: Any],
            "textures": textures,
            "shaders": ["vs": vertexShaderID, "fs": fragmentShaderID],
            "constantBuffers": constantBuffers,
            "state": state,
            "output": output,
            "implementation": implementationRecord(for: pass.shader),
            "semanticCoverage": coverage.jsonObject(),
            "vertexContract": vertexContract,
            "colorContract": WPEPassColorContract(textureBindings: textureBindings, alpha: result.alphaContract,
                                                  target: targetTexture, nativeState: nativeState).jsonObject(),
        ]
        passes.append(passRecord)
    }

    /// These passes have no transpiler reflection layout, so the trace intentionally leaves `constantBuffers` empty instead of inventing GLSL uniforms.
    func recordBuiltinPass(
        pass: WPEPreparedRenderPass,
        layer: WPERenderLayer,
        destination: (id: WPEMetalTargetID, texture: MTLTexture),
        builtinKind: String,
        vertexShaderName: String,
        fragmentShaderName: String,
        textureBindings: [TextureBindingInput],
        usesObjectQuad: Bool,
        nativeState: NativeRenderState
    ) {
        guard artifacts.isEnabled else { return }
        lock.lock()
        defer { lock.unlock() }
        guard scene != nil, !frameComplete else { return }

        let ordinal = passes.count
        let target = destination.id
        let targetTexture = destination.texture
        let targetResource = renderTargetResourceID(target)
        let vertexShaderID = shaderID(stage: "vs", stableInput: vertexShaderName)
        let fragmentShaderID = shaderID(stage: "fs", stableInput: fragmentShaderName)

        resources.renderTargets[targetResource] = renderTargetResource(
            target: target,
            texture: targetTexture,
            ordinal: ordinal
        )
        resources.shaders[vertexShaderID] = shaderResource(
            stage: "vertex",
            entryPoint: vertexShaderName,
            source: vertexShaderName,
            path: nil,
            layout: [],
            samplers: []
        )
        resources.shaders[fragmentShaderID] = shaderResource(
            stage: "fragment",
            entryPoint: fragmentShaderName,
            source: fragmentShaderName,
            path: nil,
            layout: [],
            samplers: textureBindings.compactMap(\.name)
        )

        var textures: [[String: Any]] = []
        for binding in textureBindings.sorted(by: { $0.slot < $1.slot }) {
            let textureID = textureResourceID(
                texture: binding.texture,
                fallbackKey: "builtin-\(ordinal)-\(binding.slot)"
            )
            resources.textures[textureID] = textureResource(
                id: textureID,
                name: binding.name,
                reference: binding.reference,
                texture: binding.texture
            )
            textures.append([
                "stage": "fragment",
                "slot": binding.slot,
                "name": jsonOrNull(binding.name),
                "resource": textureID,
                "reference": jsonOrNull(Self.describe(reference: binding.reference)),
                "fallback": binding.fallbackToPrimary,
                "width": jsonOrNull(binding.texture?.width),
                "height": jsonOrNull(binding.texture?.height),
                "format": jsonOrNull(binding.texture.map { pixelFormatName($0.pixelFormat) })
            ])
        }

        let draw: [String: Any] = [
            "topology": usesObjectQuad ? "object-quad" : "fullscreen-quad",
            "vertexCount": 4,
            "indexCount": NSNull(),
            "instanceCount": 1,
            "viewport": [0, 0, Double(targetTexture.width), Double(targetTexture.height), 0, 1] as [Double],
            "scissor": [Double]()
        ]
        let colorTargets: [[String: Any]] = [[
            "slot": 0,
            "resource": targetResource,
            "load": NSNull(),
            "store": "store",
            "target": describe(target: target)
        ]]
        var state = nativeStateJSON(nativeState, logicalBlend: "\(pass.pass.blending)")
        state["samplers"] = [Any]()
        let output: [String: Any] = [
            "resource": targetResource,
            "png": NSNull(),
            "sha256": NSNull(),
            "visualStats": [
                "note": "Builtin Metal pass; output hash filled from scenePassDumps when captured."
            ]
        ]
        let passRecord: [String: Any] = [
            "ordinal": ordinal,
            "eventId": NSNull(),
            "layerId": layer.objectID,
            "passId": pass.pass.id,
            "shaderName": pass.pass.shader,
            "draw": draw,
            "targets": ["color": colorTargets, "depth": NSNull()] as [String: Any],
            "textures": textures,
            "shaders": ["vs": vertexShaderID, "fs": fragmentShaderID],
            "constantBuffers": [Any](),
            "state": state,
            "output": output,
            "builtin": ["kind": builtinKind],
            "colorContract": WPEPassColorContract(textureBindings: textureBindings, alpha: nil,
                                                  target: targetTexture, nativeState: nativeState).jsonObject(),
            "implementation": implementationRecord(for: pass.shader)
        ]
        passes.append(passRecord)
    }

    func recordPuppetPass(
        pass: WPEPreparedRenderPass,
        nativeState: NativeRenderState,
        stage: String,
        layer: WPERenderLayer,
        modelPath: String?,
        meshes: [WPEPuppetMesh],
        bones: [WPEPuppetBone],
        destination: (id: WPEMetalTargetID, texture: MTLTexture),
        textureBindings: [TextureBindingInput],
        vertexShaderName: String,
        fragmentShaderName: String,
        fragmentUniforms: [PuppetUniformInput],
        vertexUniforms: [PuppetUniformInput],
        bonePalette: [simd_float4x4],
        skinningEnabled: Bool,
        localSize: SIMD2<Float>,
        meshCenter: SIMD2<Float>,
        objectCenterAndSize: SIMD4<Float>?,
        meshUniformsInFragment: Bool = false
    ) {
        guard artifacts.isEnabled else { return }
        lock.lock()
        defer { lock.unlock() }
        guard scene != nil, !frameComplete else { return }

        let ordinal = passes.count
        let target = destination.id
        let targetTexture = destination.texture
        let targetResource = renderTargetResourceID(target)
        let vertexShaderID = shaderID(stage: "vs", stableInput: vertexShaderName)
        let fragmentShaderID = shaderID(stage: "fs", stableInput: fragmentShaderName)
        let fragmentUniformBytes = packedUniformBytes(fragmentUniforms.map(\.value))
        let vertexUniformBytes = packedUniformBytes(vertexUniforms.map(\.value))
        let paletteBytes = puppetPaletteBytes(bonePalette)
        let paletteHash = bonePalette.isEmpty ? nil : sha256Hex(paletteBytes)
        let fragmentBufferResource = "buf-mac-puppet-fragment-\(ordinal)"
        let vertexBufferResource = "buf-mac-puppet-vertex-\(ordinal)"
        let paletteBufferResource = "buf-mac-puppet-palette-\(ordinal)"

        resources.renderTargets[targetResource] = renderTargetResource(target: target, texture: targetTexture, ordinal: ordinal)
        resources.buffers[fragmentBufferResource] = [
            "label": "Mac puppet fragment uniforms pass \(ordinal)",
            "byteLength": fragmentUniformBytes.count,
            "sha256": sha256Hex(fragmentUniformBytes)
        ]
        resources.buffers[vertexBufferResource] = [
            "label": "Mac puppet vertex uniforms pass \(ordinal)",
            "byteLength": vertexUniformBytes.count,
            "sha256": sha256Hex(vertexUniformBytes)
        ]
        resources.buffers[paletteBufferResource] = [
            "label": "Mac puppet bone palette pass \(ordinal)",
            "byteLength": paletteBytes.count,
            "sha256": jsonOrNull(paletteHash)
        ]
        resources.shaders[vertexShaderID] = shaderResource(
            stage: "vertex",
            entryPoint: vertexShaderName,
            source: vertexShaderName,
            path: nil,
            layout: [],
            samplers: []
        )
        resources.shaders[fragmentShaderID] = shaderResource(
            stage: "fragment",
            entryPoint: fragmentShaderName,
            source: fragmentShaderName,
            path: nil,
            layout: [],
            samplers: textureBindings.compactMap(\.name)
        )

        var textures: [[String: Any]] = []
        for binding in textureBindings.sorted(by: { $0.slot < $1.slot }) {
            let texID = textureResourceID(texture: binding.texture, fallbackKey: "puppet-\(ordinal)-\(binding.slot)")
            resources.textures[texID] = textureResource(
                id: texID, name: binding.name, reference: binding.reference, texture: binding.texture
            )
            textures.append([
                "stage": "fragment",
                "slot": binding.slot,
                "name": jsonOrNull(binding.name),
                "resource": texID,
                "reference": jsonOrNull(Self.describe(reference: binding.reference)),
                "fallback": binding.fallbackToPrimary,
                "width": jsonOrNull(binding.texture?.width),
                "height": jsonOrNull(binding.texture?.height),
                "format": jsonOrNull(binding.texture.map { pixelFormatName($0.pixelFormat) })
            ])
        }

        let draw: [String: Any] = [
            "topology": "indexed-triangle-list",
            "vertexCount": puppetVertexCount(meshes),
            "indexCount": puppetIndexCount(meshes),
            "encodedDrawCount": meshes.count,
            "instanceCount": 1,
            "viewport": [0, 0, Double(targetTexture.width), Double(targetTexture.height), 0, 1] as [Double],
            "scissor": [Double]()
        ]
        let colorTargets: [[String: Any]] = [[
            "slot": 0,
            "resource": targetResource,
            "load": NSNull(),
            "store": "store",
            "target": describe(target: target),
        ]]
        var constantBuffers: [[String: Any]] = [
            [
                "name": "puppet_fragment_uniforms",
                "stage": "fragment",
                "slot": 0,
                "resource": fragmentBufferResource,
                "rawBytesSha256": sha256Hex(fragmentUniformBytes),
                "variables": puppetUniformVariables(fragmentUniforms)
            ],
            [
                "name": "puppet_vertex_uniforms",
                "stage": "vertex",
                "slot": 1,
                "resource": vertexBufferResource,
                "rawBytesSha256": sha256Hex(vertexUniformBytes),
                "variables": puppetUniformVariables(vertexUniforms)
            ],
            [
                "name": "puppet_bone_palette",
                "stage": "vertex",
                "slot": 2,
                "resource": paletteBufferResource,
                "rawBytesSha256": jsonOrNull(paletteHash),
                "variables": [[
                    "name": "bonePalette",
                    "type": "mat4[]",
                    "arrayLength": bonePalette.count,
                    "rawBytesSha256": jsonOrNull(paletteHash)
                ]]
            ],
        ]
        if meshUniformsInFragment {
            constantBuffers.append([
                "name": "scene_model_mesh_uniforms", "stage": "fragment", "slot": 1,
                "resource": vertexBufferResource, "rawBytesSha256": sha256Hex(vertexUniformBytes),
                "variables": puppetUniformVariables(vertexUniforms),
            ])
        }
        var state = nativeStateJSON(nativeState, logicalBlend: "\(pass.pass.blending)")
        state["samplers"] = textureBindings.sorted(by: { $0.slot < $1.slot }).map {
            ["stage": "fragment", "slot": $0.slot, "name": jsonOrNull($0.name)] as [String: Any]
        }
        let output: [String: Any] = [
            "resource": targetResource,
            "png": NSNull(),
            "sha256": NSNull(),
            "visualStats": ["note": "Puppet built-in mesh pass; output hash filled from scenePassDumps when captured."]
        ]
        let puppet: [String: Any] = [
            "stage": stage,
            "modelPath": jsonOrNull(modelPath),
            "skinningEnabled": skinningEnabled,
            "paletteCount": bonePalette.count,
            "paletteSha256": jsonOrNull(paletteHash),
            "meshCenter": [Double(meshCenter.x), Double(meshCenter.y)],
            "localSize": [Double(localSize.x), Double(localSize.y)],
            "objectCenterAndSize": jsonOrNull(objectCenterAndSize.map {
                [Double($0.x), Double($0.y), Double($0.z), Double($0.w)]
            }),
            "worldBinds": bones.compactMap { bone -> [String: Any]? in
                guard let matrix = bone.worldBindMatrix else { return nil }
                return [
                    "boneIndex": bone.index,
                    "parentIndex": jsonOrNull(bone.parentIndex),
                    "matrix": matrix.map(Double.init)
                ]
            }
        ]
        let passRecord: [String: Any] = [
            "ordinal": ordinal,
            "eventId": NSNull(),
            "layerId": layer.objectID,
            "passId": pass.pass.id,
            "shaderName": pass.pass.shader,
            "draw": draw,
            "targets": ["color": colorTargets, "depth": NSNull()] as [String: Any],
            "textures": textures,
            "shaders": ["vs": vertexShaderID, "fs": fragmentShaderID],
            "constantBuffers": constantBuffers,
            "state": state,
            "output": output,
            "puppet": puppet,
            "implementation": nativeImplementationRecord()
        ]
        passes.append(passRecord)
    }

    func recordPassOutputs(_ entries: [(label: String, texture: MTLTexture)]) {
        guard artifacts.isEnabled else { return }
        lock.lock()
        let shouldRecord = !frameComplete
        lock.unlock()
        guard shouldRecord else { return }

        // Read back + hash OUTSIDE the lock: getBytes on a scene-pass snapshot is
        // expensive and must never block recordCustomPass on the render thread.
        let hashed: [(label: String, sha256: String, visualStats: [String: Any])] = entries.compactMap { entry in
            guard let metrics = textureMetrics(entry.texture) else { return nil }
            return (entry.label, metrics.sha256, metrics.visualStats)
        }
        guard !hashed.isEmpty else { return }

        lock.lock()
        defer { lock.unlock() }
        guard !frameComplete else { return }
        for item in hashed {
            // Match the first still-unhashed pass with this id, so repeated pass ids (e.g. ping-pong blur) fill in draw order instead of colliding.
            guard let index = passes.firstIndex(where: {
                ($0["passId"] as? String) == item.label
                    && (($0["output"] as? [String: Any])?["sha256"] is NSNull)
            }) else { continue }
            var record = passes[index]
            var output = record["output"] as? [String: Any] ?? [:]
            output["sha256"] = item.sha256
            output["visualStats"] = item.visualStats
            record["output"] = output
            passes[index] = record
        }
    }

    func recordParticlePass(
        index: Int,
        particleCount: Int,
        sprite: MTLTexture?,
        blendMode: String,
        nativeState: NativeRenderState,
        target: MTLTexture,
        spriteSheet: (cols: Int, rows: Int, frames: Int, alphaMask: Bool)?,
        overbright: Float,
        layerID: String? = nil,
        spritePath: String? = nil,
        extraTextures: [ParticleTextureInput] = [],
        vertices: [[String: Any]] = [],
        verticesTruncated: Bool = false
    ) {
        guard artifacts.isEnabled else { return }
        lock.lock()
        defer { lock.unlock() }
        guard scene != nil, !frameComplete else { return }

        let ordinal = passes.count
        let targetResource = "rt-scene"
        // Create rt-scene only if no pass registered it yet: a blind assign would wipe the `lineage` the structural golden reads as the FBO graph.
        if resources.renderTargets[targetResource] == nil {
            resources.renderTargets[targetResource] = [
                "label": "scene", "width": target.width, "height": target.height,
                "format": pixelFormatName(target.pixelFormat), "lineage": [String]()
            ]
        }
        let spriteID = textureResourceID(texture: sprite, fallbackKey: "particle-\(index)")
        var spriteResource = textureResource(id: spriteID, name: "g_Texture0", reference: nil, texture: sprite)
        if let spritePath { spriteResource["sourcePath"] = spritePath }
        resources.textures[spriteID] = spriteResource

        // Slot 0 plus whatever else the draw actually bound. Hardcoding slot 0 made every REFRACT particle look like it was missing its normal map.
        var textures: [[String: Any]] = [[
            "stage": "fragment", "slot": 0, "name": "g_Texture0", "resource": spriteID,
            "reference": jsonOrNull(spritePath), "fallback": false,
            "width": jsonOrNull(sprite?.width), "height": jsonOrNull(sprite?.height),
            "format": jsonOrNull(sprite.map { pixelFormatName($0.pixelFormat) })
        ]]
        for extra in extraTextures.sorted(by: { $0.slot < $1.slot }) {
            let extraID = textureResourceID(
                texture: extra.texture, fallbackKey: "particle-\(index)-\(extra.slot)")
            var resource = textureResource(
                id: extraID, name: extra.name, reference: nil, texture: extra.texture)
            if let path = extra.path { resource["sourcePath"] = path }
            resources.textures[extraID] = resource
            textures.append([
                "stage": "fragment", "slot": extra.slot, "name": extra.name,
                "resource": extraID, "reference": jsonOrNull(extra.path), "fallback": false,
                "width": jsonOrNull(extra.texture?.width),
                "height": jsonOrNull(extra.texture?.height),
                "format": jsonOrNull(extra.texture.map { pixelFormatName($0.pixelFormat) })
            ])
        }
        let draw: [String: Any] = [
            "topology": "particle", "vertexCount": particleCount, "indexCount": NSNull(),
            "instanceCount": particleCount,
            "viewport": [0, 0, Double(target.width), Double(target.height), 0, 1] as [Double],
            "scissor": [Double]()
        ]
        let colorTargets: [[String: Any]] = [[
            "slot": 0, "resource": targetResource, "load": "load", "store": "store"
        ]]
        var variables: [[String: Any]] = []
        if let sheet = spriteSheet {
            variables.append([
                "name": "g_SpriteSheet", "type": "vec4",
                "value": [Double(sheet.cols), Double(sheet.rows), Double(sheet.frames), sheet.alphaMask ? 1.0 : 0.0]
            ])
        }
        variables.append([
            "name": "g_Overbright", "type": "float",
            "value": Double(overbright)
        ])
        let constantBuffer: [String: Any] = [
            "name": "particle", "stage": "fragment", "slot": 0, "variables": variables
        ]
        var state = nativeStateJSON(nativeState, logicalBlend: blendMode)
        state["samplers"] = [["stage": "fragment", "slot": 0, "name": "g_Texture0"]] as [[String: Any]]
        let output: [String: Any] = [
            "resource": targetResource, "png": NSNull(), "sha256": NSNull(),
            "visualStats": ["note": "particle pass (instanced quads, \(particleCount) alive)"]
        ]
        var passRecord: [String: Any] = [
            "ordinal": ordinal, "eventId": NSNull(), "layerId": jsonOrNull(layerID),
            "passId": "particle.\(index)", "shaderName": "particle/\(blendMode)",
            "draw": draw,
            "targets": ["color": colorTargets, "depth": NSNull()] as [String: Any],
            "textures": textures,
            "shaders": ["vs": "shader-vs-particle", "fs": "shader-fs-particle"],
            "constantBuffers": [constantBuffer],
            "state": state,
            "output": output,
            "implementation": nativeImplementationRecord()
        ]
        // Same shape and 256-cap as the Windows side's decoded POINTLIST vertex
        // buffers, so the diff can compare per-particle aggregates on both sides.
        if !vertices.isEmpty {
            passRecord["vertices"] = vertices
            if verticesTruncated { passRecord["verticesTruncated"] = true }
        }
        passes.append(passRecord)
    }

    @discardableResult
    func finishFrame(
        outputTexture: MTLTexture,
        runtimeUniforms: WPEMetalRuntimeUniforms?,
        firstFrameStats: WPEMetalTextureVisualStats?,
        resolutionDiagnostics: WPEResolutionDiagnosticsSnapshot,
        frameOrdinal: Int = 0
    ) -> Data? {
        guard artifacts.isEnabled else { return nil }
        lock.lock()
        guard let scene, !frameComplete else { lock.unlock(); return nil }
        frameComplete = true
        let passSnapshot = passes
        let attachmentOperationSnapshot = attachmentOperations
        let attachmentPlanSnapshot = attachmentPlan
        let semanticCoverageSnapshot = semanticCoverage
        let resourceSnapshot = resources
        let shaderImplementationInventorySnapshot = shaderImplementationInventory
        lock.unlock()

        // Everything below runs WITHOUT the lock: the final-texture readback and
        // JSON serialization must not stall a concurrent render-thread call.
        let width = outputTexture.width
        let height = outputTexture.height
        let finalHash = textureMetrics(outputTexture)?.sha256
        let missedRefs = resolutionDiagnostics.missedRefs

        let producer: [String: Any] = [
            "side": "mac-metal",
            "tool": "WPECanonicalTraceRecorder",
            "toolVersion": "1",
            "wpeVersion": "2.8.26",
            "appBuild": jsonOrNull(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String)
        ]
        let assetRoots: [String] = scene.projectJsonPath.map { [URL(fileURLWithPath: $0).deletingLastPathComponent().path] } ?? []
        let sceneBlock: [String: Any] = [
            "workshopId": scene.workshopID,
            "projectJson": scene.projectJsonPath ?? "",
            "projectJsonSha256": jsonOrNull(scene.projectJsonPath.flatMap { sha256File(path: $0) }),
            "entryFile": jsonOrNull(scene.projectJsonPath.map { URL(fileURLWithPath: $0).lastPathComponent }),
            "assetRoots": assetRoots
        ]
        let determinism: [String: Any] = [
            "time": jsonOrNull(runtimeUniforms?.time),
            "daytime": jsonOrNull(runtimeUniforms?.daytime),
            "pointer": [runtimeUniforms?.pointerPosition.x ?? 0.5, runtimeUniforms?.pointerPosition.y ?? 0.5] as [Double],
            "audioMode": "zeroed",
            "mouseParallax": "centered"
        ]
        let firstMisses: [[String: Any]] = missedRefs.prefix(16).map {
            ["ref": $0.ref, "outcome": $0.finalOutcome.debugLabel]
        }
        let resolutionSummary: [String: Any] = [
            "events": resolutionDiagnostics.events.count,
            "resolved": resolutionDiagnostics.resolvedCount,
            "missing": missedRefs.count,
            "firstMisses": firstMisses
        ]
        let capture: [String: Any] = [
            "jobId": scene.workshopID,
            "mode": "shader-first",
            "frameOrdinal": frameOrdinal,
            "resolution": ["width": width, "height": height],
            "wallpaperWindow": ["class": "MTKView", "hwnd": NSNull(), "pid": NSNull()] as [String: Any],
            "determinism": determinism,
            "resolutionSummary": resolutionSummary,
            "descriptor": scene.descriptor
        ]
        let renderTargets: [String: [String: Any]] = resourceSnapshot.renderTargets.isEmpty
            ? ["rt-scene": [
                "label": "scene", "width": width, "height": height,
                "format": pixelFormatName(outputTexture.pixelFormat), "lineage": [String]()
            ]]
            : resourceSnapshot.renderTargets
        let resourceBlock: [String: Any] = [
            "textures": resourceSnapshot.textures,
            "renderTargets": renderTargets,
            "buffers": resourceSnapshot.buffers,
            "shaders": resourceSnapshot.shaders
        ]
        let finalBlock: [String: Any] = [
            "resource": "rt-scene",
            "png": NSNull(),
            "sha256": jsonOrNull(finalHash),
            "visualStats": firstFrameStats.map(Self.visualStats) ?? NSNull()
        ]
        let trace: [String: Any] = [
            "schema": "wpe.trace.v1",
            "producer": producer,
            "scene": sceneBlock,
            "capture": capture,
            "resources": resourceBlock,
            "passes": passSnapshot,
            "attachmentOperations": ["schema": "wpe.attachment-operations.v1", "events": attachmentOperationSnapshot],
            "attachmentPlan": attachmentPlanSnapshot ?? NSNull(),
            "semanticCoverage": WPEShaderSemanticCoverage.jsonObject(WPEShaderSemanticCoverage.Summary(semanticCoverageSnapshot)),
            "shaderImplementationInventory": shaderImplementationInventorySnapshot.map(
                Self.shaderImplementationInventoryRecord
            ),
            "final": finalBlock
        ]
        let passCount = passSnapshot.count

        guard JSONSerialization.isValidJSONObject(trace) else {
            let issues = Self.jsonValidationIssues(trace)
            let detail = issues.joined(separator: "\n")
            artifacts.recordNote(name: "trace-serialization-error.txt", contents: detail)
            print("[canonical-trace] trace.json serialization failed: \(detail)")
            return nil
        }
        guard let data = try? JSONSerialization.data(withJSONObject: trace, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            artifacts.appendLog("[canonical-trace] trace.json serialization failed", level: .error)
            return nil
        }
        artifacts.recordNote(name: "trace.json", contents: text)
        artifacts.appendLog(
            "[canonical-trace] wrote trace.json passes=\(passCount) frame=\(frameOrdinal)", level: .info
        )
        return data
    }

    // MARK: - Description helpers (mirror WPESceneDebugArtifacts)

    static func executionClassification(
        for program: WPEShaderProgram?
    ) -> WPEShaderExecutionClassification? {
        program?.executionClassification
    }

    static func shaderImplementationInventoryRecord(
        _ entry: WPEShaderImplementationInventoryEntry
    ) -> [String: Any] {
        let renderPassID: Any = entry.renderPassID.map { $0 as Any } ?? NSNull()
        let shaderPath: Any = entry.authoredShaderPath.map { $0 as Any } ?? NSNull()
        let authoredOverrideID: Any = entry.authoredOverrideID.map { $0 as Any } ?? NSNull()
        return [
            "effectId": entry.stableEffectID,
            "passId": entry.stablePassID,
            "authoredOverrideId": authoredOverrideID,
            "renderPassId": renderPassID,
            "effectPath": entry.authoredEffectPath,
            "shaderPath": shaderPath,
            "classification": entry.classification.rawValue,
            "consumerDisposition": entry.consumerDisposition.rawValue,
            "metadataKind": entry.metadataKind,
            "metadataSources": entry.metadataSources
        ]
    }

    private func implementationRecord(for program: WPEShaderProgram?) -> [String: Any] {
        [
            "classification": jsonOrNull(Self.executionClassification(for: program)?.rawValue)
        ]
    }

    private func nativeImplementationRecord() -> [String: Any] {
        ["classification": WPEShaderExecutionClassification.nativeApproximation.rawValue]
    }

    static func describe(reference: WPETextureReference?) -> String? {
        guard let reference else { return nil }
        switch reference {
        case .image(let path): return "image(\(path))"
        case .asset(let path): return "asset(\(path))"
        case .fbo(let name): return "fbo(\(name))"
        case .previous: return "previous"
        }
    }

    private func describe(target: WPEMetalTargetID) -> String {
        switch target {
        case .scene: return "scene"
        case .named(let name): return name
        }
    }

    private func renderTargetResourceID(_ target: WPEMetalTargetID) -> String {
        switch target {
        case .scene: return "rt-scene"
        case .named(let name): return "rt-\(safeID(name))"
        }
    }

    // MARK: - Resource builders

    private func shaderResource(
        stage: String, entryPoint: String, source: String,
        path: String?, layout: [WPEUniformSlot], samplers: [String]
    ) -> [String: Any] {
        let sourceHash = sha256Hex(Data(source.utf8))
        // Report the AUTHORED register slot (`g_Texture7` -> 7), not the dense index: MSL packs samplers into tex0..texN.
        let reflectionSamplers: [[String: Any]] = samplers.enumerated().map { index, name in
            ["name": name, "slot": Self.authoredTextureSlot(name) ?? index, "type": "SAMPLER"]
        }
        let reflectionTextures: [[String: Any]] = samplers.enumerated().map { index, name in
            ["name": name, "slot": Self.authoredTextureSlot(name) ?? index, "type": "TEXTURE"]
        }
        let constantBlocks: [[String: Any]] = layout.isEmpty ? [] : [["name": "mac_flat_slots", "slot": 0, "type": "CBUFFER"]]
        let uniforms: [[String: Any]] = layout.map { slot in
            [
                "name": slot.name,
                "type": slot.glslType,
                "slot": slot.slot,
                "slotCount": slot.slotCount,
                "startOffset": slot.slot * MemoryLayout<SIMD4<Float>>.stride,
                "arrayLength": jsonOrNull(slot.arrayLength),
                "materialName": jsonOrNull(slot.materialName)
            ]
        }
        let reflection: [String: Any] = [
            "samplers": reflectionSamplers,
            "textures": reflectionTextures,
            "constantBlocks": constantBlocks,
            "uniforms": uniforms
        ]
        return [
            "stage": stage,
            "sourceLanguage": "MSL",
            "entryPoint": entryPoint,
            "sourcePath": jsonOrNull(path),
            "sourceSha256": sourceHash,
            "disassembly": ["path": jsonOrNull(path), "sha256": sourceHash] as [String: Any],
            "reflection": reflection
        ]
    }

    private func puppetUniformVariables(_ inputs: [PuppetUniformInput]) -> [[String: Any]] {
        inputs.enumerated().map { index, input in
            let values = WPECanonicalUniformTrace.floatSlots([input.value])[0]
            return [
                "name": input.name,
                "type": input.type,
                "slot": index,
                "slotCount": 1,
                "rawSlotFloats": values,
                "value": values
            ]
        }
    }

    private func puppetVertexCount(_ meshes: [WPEPuppetMesh]) -> Int {
        meshes.reduce(0) { $0 + $1.vertices.count }
    }

    private func puppetIndexCount(_ meshes: [WPEPuppetMesh]) -> Int {
        meshes.reduce(0) { total, mesh in
            guard !mesh.parts.isEmpty else { return total + mesh.indices.count }
            let partCount = mesh.parts.reduce(0) { partial, part in
                let start = max(part.start, 0)
                let count = min(part.count, max(mesh.indices.count - start, 0))
                return partial + max(count, 0)
            }
            return total + partCount
        }
    }

    private func textureResource(id: String, name: String?, reference: WPETextureReference?, texture: MTLTexture?) -> [String: Any] {
        [
            "label": name ?? Self.describe(reference: reference) ?? id,
            "sourcePath": jsonOrNull(Self.describe(reference: reference)),
            "width": jsonOrNull(texture?.width),
            "height": jsonOrNull(texture?.height),
            "format": jsonOrNull(texture.map { pixelFormatName($0.pixelFormat) }),
            "colorView": jsonOrNull(texture.map { WPEPixelColorContract($0.pixelFormat).jsonObject() }),
            "mips": jsonOrNull(texture?.mipmapLevelCount),
            "sha256": NSNull(),
            "png": NSNull()
        ]
    }

    private func renderTargetResource(target: WPEMetalTargetID, texture: MTLTexture, ordinal: Int) -> [String: Any] {
        [
            "label": describe(target: target),
            "width": texture.width,
            "height": texture.height,
            "format": pixelFormatName(texture.pixelFormat),
            "colorStorage": WPEPixelColorContract(texture.pixelFormat).jsonObject(),
            "lineage": ["pass-\(String(format: "%04d", ordinal))"]
        ]
    }

    /// Preserve invalid observations as diagnostics rather than silently replacing
    /// them with zero or dropping a whole scene without naming the offending field.
    static func jsonValidationIssues(_ value: Any, path: String = "$") -> [String] {
        if value is NSNull || value is String {
            return []
        }
        if let number = value as? NSNumber {
            return number.doubleValue.isFinite ? [] : ["\(path): non-finite number \(number)"]
        }
        if let object = value as? [String: Any] {
            return Array(object.keys.sorted().flatMap { key in
                jsonValidationIssues(object[key]!, path: "\(path).\(key)")
            }.prefix(32))
        }
        if let array = value as? [Any] {
            return Array(array.enumerated().flatMap { index, entry in
                jsonValidationIssues(entry, path: "\(path)[\(index)]")
            }.prefix(32))
        }
        return ["\(path): unsupported JSON type \(String(reflecting: type(of: value)))"]
    }

    // MARK: - Texture metrics (best-effort, post-commit only)

    private func textureMetrics(_ texture: MTLTexture) -> (sha256: String, visualStats: [String: Any])? {
        // Output ring is `.private`; one staging copy for hash + visual stats.
        guard let texture = WPEMetalTextureSnapshotter.stagedForCPURead(texture) else {
            artifacts.appendLog(
                "[canonical-trace] CPU staging blit failed for texture metrics",
                level: .warning
            )
            return nil
        }
        guard let data = readbackTextureBytes(texture) else { return nil }
        let stats = WPEMetalTextureVisualStats.analyze(texture: texture)
        let pixels = max(texture.width * texture.height, 1)
        let visualStats: [String: Any] = [
            "coverage": jsonOrNull(stats.map { Double($0.nonBlackPixelCount) / Double(pixels) }),
            "meanRGBA": NSNull(),
            "width": texture.width,
            "height": texture.height,
            "nonBlackPixelCount": jsonOrNull(stats?.nonBlackPixelCount),
            "nonTransparentPixelCount": jsonOrNull(stats?.nonTransparentPixelCount)
        ]
        return (sha256Hex(data), visualStats)
    }

    private static func visualStats(_ stats: WPEMetalTextureVisualStats) -> [String: Any] {
        [
            "coverage": Double(stats.nonBlackPixelCount) / Double(max(stats.width * stats.height, 1)),
            "meanRGBA": NSNull(),
            "width": stats.width,
            "height": stats.height,
            "nonBlackPixelCount": stats.nonBlackPixelCount,
            "nonTransparentPixelCount": stats.nonTransparentPixelCount,
            "nonBlackCoversFullFrame": stats.nonBlackCoversFullFrame
        ]
    }

    private func readbackTextureBytes(_ texture: MTLTexture) -> Data? {
        // rgba8/bgra8 unorm are hashed raw; HDR rgba16Float is decoded to canonical clamped 8-bit FIRST — raw Float16 bytes are non-deterministic across runs.
        let isFloat16: Bool
        let bytesPerPixel: Int
        switch texture.pixelFormat {
        case .rgba8Unorm, .rgba8Unorm_srgb, .bgra8Unorm, .bgra8Unorm_srgb:
            bytesPerPixel = 4
            isFloat16 = false
        case .rgba16Float:
            bytesPerPixel = 8
            isFloat16 = true
        default:
            return nil
        }
        // `textureMetrics` stages via `stagedForCPURead` (shared or managed).
        // A `.private` texture here is a caller bug — skip rather than hash garbage.
        guard texture.storageMode == .shared || texture.storageMode == .managed else {
            artifacts.appendLog(
                "[canonical-trace] skipped getBytes for non-shared texture (storageMode=\(texture.storageMode.rawValue))",
                level: .warning
            )
            return nil
        }
        let width = texture.width
        let height = texture.height
        let bytesPerRow = width * bytesPerPixel
        var raw = [UInt8](repeating: 0, count: bytesPerRow * height)
        raw.withUnsafeMutableBytes { ptr in
            guard let base = ptr.baseAddress else { return }
            texture.getBytes(
                base,
                bytesPerRow: bytesPerRow,
                from: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0
            )
        }
        guard isFloat16 else { return Data(raw) }
        // Float16 RGBA → canonical clamped 8-bit. Non-finite and negatives collapse to 0; values ≥1 clamp to 255.
        let componentCount = width * height * 4
        var canonical = [UInt8](repeating: 0, count: componentCount)
        raw.withUnsafeBytes { rawPtr in
            let halfs = rawPtr.bindMemory(to: UInt16.self)
            for index in 0..<componentCount {
                let value = Float(Float16(bitPattern: halfs[index]))
                let clamped = value.isFinite ? min(max(value, 0), 1) : 0
                canonical[index] = UInt8((clamped * 255).rounded())
            }
        }
        return Data(canonical)
    }

    // MARK: - Small helpers

    private func packedUniformBytes(_ slots: [SIMD4<Float>]) -> Data {
        var data = Data(capacity: slots.count * MemoryLayout<SIMD4<Float>>.stride)
        for slot in slots {
            for value in [slot.x, slot.y, slot.z, slot.w] {
                withUnsafeBytes(of: value) { data.append(contentsOf: $0) }
            }
        }
        return data
    }

    private func puppetPaletteBytes(_ palette: [simd_float4x4]) -> Data {
        var data = Data(capacity: palette.count * MemoryLayout<simd_float4x4>.stride)
        palette.withUnsafeBytes { data.append(contentsOf: $0) }
        return data
    }

    private func pixelFormatName(_ format: MTLPixelFormat) -> String { "\(format.rawValue)" }

    private func nativeStateJSON(_ native: NativeRenderState, logicalBlend: String) -> [String: Any] {
        let a = native.attachment
        let attachment: [String: Any] = [
            "enabled": a.isBlendingEnabled,
            "writeMask": Self.d3dWriteMask(a.writeMask),
            "sourceRGB": Self.blendToken(a.sourceRGBBlendFactor),
            "destinationRGB": Self.blendToken(a.destinationRGBBlendFactor),
            "operationRGB": Self.operationToken(a.rgbBlendOperation),
            "sourceAlpha": Self.blendToken(a.sourceAlphaBlendFactor),
            "destinationAlpha": Self.blendToken(a.destinationAlphaBlendFactor),
            "operationAlpha": Self.operationToken(a.alphaBlendOperation),
        ]
        return [
            "blend": ["mode": logicalBlend, "attachments": [attachment]] as [String: Any],
            // Metal has no depth-enable flag: the test only runs with a depth attachment.
            "depth": [
                "enabled": native.depthAttached,
                "writes": native.depthAttached && native.depthWrite,
                "function": Self.compareToken(native.depthCompare),
            ] as [String: Any],
            "raster": [
                "cullMode": Self.cullToken(native.cullMode),
                "fillMode": "solid",
                "frontCCW": native.frontCCW,
            ] as [String: Any],
        ]
    }

    private static func blendToken(_ factor: MTLBlendFactor) -> String {
        switch factor {
        case .zero: "zero"
        case .one: "one"
        case .sourceColor: "src-color"
        case .oneMinusSourceColor: "inv-src-color"
        case .sourceAlpha: "src-alpha"
        case .oneMinusSourceAlpha: "inv-src-alpha"
        case .destinationColor: "dest-color"
        case .oneMinusDestinationColor: "inv-dest-color"
        case .destinationAlpha: "dest-alpha"
        case .oneMinusDestinationAlpha: "inv-dest-alpha"
        case .sourceAlphaSaturated: "src-alpha-sat"
        case .blendColor, .blendAlpha: "blend-factor"
        case .oneMinusBlendColor, .oneMinusBlendAlpha: "inv-blend-factor"
        case .source1Color: "src1-color"
        case .oneMinusSource1Color: "inv-src1-color"
        case .source1Alpha: "src1-alpha"
        case .oneMinusSource1Alpha: "inv-src1-alpha"
        // Metal 4 pipeline specialization placeholder, not a real factor: no D3D11 counterpart, so it gets its own token rather than colliding with one Windows can emit.
        case .unspecialized: "unspecialized"
        @unknown default: "mtl-\(factor.rawValue)"
        }
    }

    private static func operationToken(_ operation: MTLBlendOperation) -> String {
        switch operation {
        case .add: "add"
        case .subtract: "subtract"
        case .reverseSubtract: "rev-subtract"
        case .min: "min"
        case .max: "max"
        case .unspecialized: "unspecialized"
        @unknown default: "mtl-\(operation.rawValue)"
        }
    }

    private static func compareToken(_ function: MTLCompareFunction) -> String {
        switch function {
        case .never: "never"
        case .less: "less"
        case .equal: "equal"
        case .lessEqual: "less-equal"
        case .greater: "greater"
        case .notEqual: "not-equal"
        case .greaterEqual: "greater-equal"
        case .always: "always"
        @unknown default: "mtl-\(function.rawValue)"
        }
    }

    private static func cullToken(_ mode: MTLCullMode) -> String {
        switch mode {
        case .none: "none"
        case .front: "front"
        case .back: "back"
        @unknown default: "mtl-\(mode.rawValue)"
        }
    }

    /// D3D11 write-mask bit order (R1 G2 B4 A8); Metal's option set uses the reverse order.
    private static func d3dWriteMask(_ mask: MTLColorWriteMask) -> Int {
        (mask.contains(.red) ? 1 : 0) | (mask.contains(.green) ? 2 : 0)
            | (mask.contains(.blue) ? 4 : 0) | (mask.contains(.alpha) ? 8 : 0)
    }

    private func layerID(forPassID passID: String) -> String? {
        guard let prefix = passID.split(separator: ".").first.map(String.init), prefix != passID else { return nil }
        return prefix
    }

    private func shaderID(stage: String, stableInput: String) -> String {
        "shader-\(stage)-\(sha256Hex(Data(stableInput.utf8)).prefix(16))"
    }

    private func textureResourceID(texture: MTLTexture?, fallbackKey: String) -> String {
        guard let texture else { return "tex-missing-\(safeID(fallbackKey))" }
        return "tex-\(UInt(bitPattern: ObjectIdentifier(texture).hashValue))"
    }

    private func safeID(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        return value.unicodeScalars.map { allowed.contains($0) ? String($0) : "_" }.joined()
    }

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func sha256File(path: String) -> String? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        return sha256Hex(data)
    }

    private func jsonOrNull<T>(_ value: T?) -> Any { value ?? NSNull() }

    private struct SceneContext {
        let workshopID: String
        let projectJsonPath: String?
        let descriptor: String
    }

    private struct ResourceTables {
        var textures: [String: [String: Any]] = [:]
        var renderTargets: [String: [String: Any]] = [:]
        var buffers: [String: [String: Any]] = [:]
        var shaders: [String: [String: Any]] = [:]
    }
}
#endif
