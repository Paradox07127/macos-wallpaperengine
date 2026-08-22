#if !LITE_BUILD && DEBUG
import CryptoKit
import Foundation
import LiveWallpaperProWPE
import Metal
import simd

/// DEBUG-only accumulator that mirrors the Windows RenderDoc oracle into the
/// shared `wpe.trace.v1` schema from the Mac Metal path.
///
/// Fed from the scene-debug hooks (not `.gputrace`): the Swift render path
/// carries semantic names for passes, materials, samplers, uniforms, texture
/// fallbacks, and render targets — what the divergence engine needs to align
/// against the Windows ground truth.
///
/// One `mac/trace.json` is written per `beginScene`: passes accumulate during the
/// next rendered frame, then `finishFrame` serialises once and latches so the live
/// render loop never re-accumulates. A multi-frame capture re-opens the window with
/// a second `beginScene` right before the frame it wants to describe.
///
/// `@unchecked Sendable`: all mutable state is guarded by `lock`, so the shared
/// singleton is safe to touch from the render thread and the end-of-frame flush.
final class WPECanonicalTraceRecorder: @unchecked Sendable {
    static let shared = WPECanonicalTraceRecorder()

    struct TextureBindingInput {
        let slot: Int
        let name: String?
        let reference: WPETextureReference?
        let texture: MTLTexture?
        let fallbackToPrimary: Bool
        /// Address/filter/mip of the sampler actually bound to this slot, read
        /// off the bound descriptor. Windows carries a full D3D11_SAMPLER_DESC;
        /// leaving this nil makes the diff blind to wrap-mode divergence.
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
    private var resources: ResourceTables = ResourceTables()

    private init() {}

    /// True only while a scene is mid-capture and the frame has not latched — the
    /// render path checks this before building any trace payload, so a production
    /// (non-oracle, non-scene-debug) frame pays one `isEnabled` read and nothing else.
    var isAccumulating: Bool {
        guard WPESceneDebugArtifacts.shared.isEnabled else { return false }
        lock.lock()
        defer { lock.unlock() }
        return scene != nil && !frameComplete
    }

    func beginScene(workshopID: String, projectJsonPath: String?, descriptor: String) {
        guard WPESceneDebugArtifacts.shared.isEnabled else { return }
        lock.lock()
        scene = SceneContext(workshopID: workshopID, projectJsonPath: projectJsonPath, descriptor: descriptor)
        frameComplete = false
        passes.removeAll(keepingCapacity: true)
        resources = ResourceTables()
        lock.unlock()
    }

    func recordCustomPass(
        pass: WPEPreparedRenderPass,
        destination: (id: WPEMetalTargetID, texture: MTLTexture),
        result: WPEShaderCompileResult,
        textureBindings: [TextureBindingInput],
        packedUniformSlots: [SIMD4<Float>],
        usesObjectQuad: Bool
    ) {
        guard WPESceneDebugArtifacts.shared.isEnabled else { return }
        lock.lock()
        defer { lock.unlock() }
        guard scene != nil, !frameComplete else { return }

        let ordinal = passes.count
        let target = destination.id
        let targetTexture = destination.texture
        let targetResource = renderTargetResourceID(target)
        let fragmentShaderID = shaderID(stage: "fs", stableInput: result.mslSource)
        let vertexShaderID = shaderID(stage: "vs", stableInput: result.vertexFunctionName)
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
            entryPoint: result.vertexFunctionName,
            source: result.vertexFunctionName,
            path: nil,
            layout: [],
            samplers: []
        )

        var textures: [[String: Any]] = []
        for binding in textureBindings.sorted(by: { $0.slot < $1.slot }) {
            let texID = textureResourceID(texture: binding.texture, fallbackKey: "\(ordinal)-\(binding.slot)")
            resources.textures[texID] = textureResource(
                id: texID, name: binding.name, reference: binding.reference, texture: binding.texture
            )
            textures.append([
                "stage": "fragment",
                // Authored register slot, matching the reflection above and the
                // Windows side. `binding.slot` is our dense Metal binding index.
                "slot": Self.authoredTextureSlot(binding.name) ?? binding.slot,
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
        let constantBuffer: [String: Any] = [
            "name": "mac_flat_slots",
            "stage": "fragment",
            "slot": 0,
            "resource": bufferResource,
            "rawBytesSha256": sha256Hex(packedBytes),
            "variables": uniformVariables(layout: result.uniformLayout, slots: packedUniformSlots),
            "packedSlots": packedUniformSlots.map { [Double($0.x), Double($0.y), Double($0.z), Double($0.w)] }
        ]
        // Keyed by authored slot so it lines up with the sampler entries below
        // and with the Windows side's register numbering.
        let samplerBySlot = Dictionary(
            textureBindings.compactMap { binding in
                binding.sampler.map { (Self.authoredTextureSlot(binding.name) ?? binding.slot, $0) }
            },
            uniquingKeysWith: { first, _ in first }
        )
        let samplers: [[String: Any]] = result.samplerNames.enumerated().map { index, name in
            let slot = Self.authoredTextureSlot(name) ?? index
            var entry: [String: Any] = ["stage": "fragment", "slot": slot, "name": name]
            if let descriptor = samplerBySlot[slot] { entry["descriptor"] = descriptor }
            return entry
        }
        let state: [String: Any] = [
            // Was hardcoded null, which left 40 of 49 passes with no blend at all
            // while Windows recorded it on every one — blend divergence was
            // structurally undetectable on the custom-shader path.
            "blend": ["mode": "\(pass.pass.blending)"] as [String: Any],
            "depth": NSNull(),
            "raster": NSNull(),
            "samplers": samplers
        ]
        let output: [String: Any] = [
            "resource": targetResource,
            "png": NSNull(),
            "sha256": NSNull(),
            "visualStats": ["note": "Per-pass RT hash filled from scenePassDumps when WPEDumpScenePasses captured this pass."]
        ]
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
            "constantBuffers": [constantBuffer],
            "state": state,
            "output": output
        ]
        passes.append(passRecord)
    }

    /// Record one draw handled by the hand-authored Metal builtin dispatcher.
    /// These passes have no transpiler reflection layout, so the canonical trace
    /// intentionally leaves `constantBuffers` empty instead of inventing GLSL
    /// uniforms. Target, texture, shader, topology, and blend data are still the
    /// real bound values and make the pass alignable with the Windows oracle.
    func recordBuiltinPass(
        pass: WPEPreparedRenderPass,
        layer: WPERenderLayer,
        destination: (id: WPEMetalTargetID, texture: MTLTexture),
        builtinKind: String,
        vertexShaderName: String,
        fragmentShaderName: String,
        textureBindings: [TextureBindingInput],
        usesObjectQuad: Bool
    ) {
        guard WPESceneDebugArtifacts.shared.isEnabled else { return }
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
        let state: [String: Any] = [
            "blend": ["mode": "\(pass.pass.blending)"] as [String: Any],
            "depth": NSNull(),
            "raster": NSNull(),
            "samplers": [Any]()
        ]
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
            "builtin": ["kind": builtinKind]
        ]
        passes.append(passRecord)
    }

    /// Record one built-in puppet mesh draw so Mac traces can be aligned against
    /// Windows captures bone-by-bone. These draws bypass the custom-shader recorder
    /// and are otherwise invisible to the canonical pass stream.
    func recordPuppetPass(
        pass: WPEPreparedRenderPass,
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
        objectCenterAndSize: SIMD4<Float>?
    ) {
        guard WPESceneDebugArtifacts.shared.isEnabled else { return }
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
        let constantBuffers: [[String: Any]] = [
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
            ]
        ]
        let state: [String: Any] = [
            "blend": ["mode": "\(pass.pass.blending)"] as [String: Any],
            "depth": NSNull(),
            "raster": NSNull(),
            "samplers": textureBindings.sorted(by: { $0.slot < $1.slot }).map {
                ["stage": "fragment", "slot": $0.slot, "name": jsonOrNull($0.name)] as [String: Any]
            }
        ]
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
            "puppet": puppet
        ]
        passes.append(passRecord)
    }

    /// Best-effort: fill per-pass output hashes from the scene-target snapshots
    /// the executor collected. Only populated when `WPEDumpScenePasses` is on and
    /// this runs before `finishFrame` latches the trace.
    func recordPassOutputs(_ entries: [(label: String, texture: MTLTexture)]) {
        guard WPESceneDebugArtifacts.shared.isEnabled else { return }
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
            // Match the first still-unhashed pass with this id, so repeated pass
            // ids (e.g. ping-pong blur) fill in draw order instead of colliding.
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

    /// Record one particle-system draw as a pass so the divergence engine can
    /// align it against WPE's POINTLIST particle passes. Particles are encoded
    /// inline in the scene pass (`encodeParticleSystem`, interleaved by paint
    /// index), so without this hook they show up only as "missing" WPE passes
    /// even though we render them.
    func recordParticlePass(
        index: Int,
        particleCount: Int,
        sprite: MTLTexture?,
        blendMode: String,
        target: MTLTexture,
        spriteSheet: (cols: Int, rows: Int, frames: Int, alphaMask: Bool)?,
        overbright: Float,
        layerID: String? = nil,
        spritePath: String? = nil,
        extraTextures: [ParticleTextureInput] = [],
        vertices: [[String: Any]] = [],
        verticesTruncated: Bool = false
    ) {
        guard WPESceneDebugArtifacts.shared.isEnabled else { return }
        lock.lock()
        defer { lock.unlock() }
        guard scene != nil, !frameComplete else { return }

        let ordinal = passes.count
        let targetResource = "rt-scene"
        // Create rt-scene only if no pass registered it yet — same reason as the text
        // pass. Particles are interleaved by paint index, so in a scene whose last
        // .scene-targeting pass precedes them (3460973721 pass-0001, 3462491575
        // pass-0031) a blind assign wiped the `lineage` the structural golden reads
        // as the FBO graph; 3554161528 only kept its lineage because a custom pass
        // happened to draw after its particles.
        if resources.renderTargets[targetResource] == nil {
            resources.renderTargets[targetResource] = [
                "label": "scene", "width": target.width, "height": target.height,
                "format": pixelFormatName(target.pixelFormat), "lineage": [String]()
            ]
        }
        let spriteID = textureResourceID(texture: sprite, fallbackKey: "particle-\(index)")
        var spriteResource = textureResource(id: spriteID, name: "g_Texture0", reference: nil, texture: sprite)
        // The sprite's material path is known by the SYSTEM, not by any
        // WPETextureReference — thread it in so the asset bucket can say which
        // file this pass sampled (30/57 textures had a null sourcePath before).
        if let spritePath { spriteResource["sourcePath"] = spritePath }
        resources.textures[spriteID] = spriteResource

        // Slot 0 plus whatever else the draw actually bound. Hardcoding slot 0
        // made every REFRACT particle look like it was missing its normal map:
        // 3713073223's rain authors `combos:{REFRACT:1}` with
        // `textures:[sharp_halo, sharp_halo_normal]`, WPE binds both, and the
        // trace showed slot 1 empty on our side purely because nothing recorded it.
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
        // WPE's particle RDEF exposes g_Overbright/g_CutoutStart/g_CutoutEnd/g_Opacity;
        // emitting the material's overbright multiplier by name closes most of the
        // interface-name-set gap the fidelity diff's particle-pass Jaccard flagged
        // (see self-oracle-runbook.md's seed-capture `firstDivergence`). Trace-only —
        // no pixel is touched by this.
        variables.append([
            "name": "g_Overbright", "type": "float",
            "value": Double(overbright)
        ])
        let constantBuffer: [String: Any] = [
            "name": "particle", "stage": "fragment", "slot": 0, "variables": variables
        ]
        let state: [String: Any] = [
            "blend": ["mode": blendMode] as [String: Any], "depth": NSNull(), "raster": NSNull(),
            "samplers": [["stage": "fragment", "slot": 0, "name": "g_Texture0"]] as [[String: Any]]
        ]
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
            "output": output
        ]
        // Same shape and 256-cap as the Windows side's decoded POINTLIST vertex
        // buffers, so the diff can compare per-particle aggregates on both sides.
        if !vertices.isEmpty {
            passRecord["vertices"] = vertices
            if verticesTruncated { passRecord["verticesTruncated"] = true }
        }
        passes.append(passRecord)
    }

    func finishFrame(
        outputTexture: MTLTexture,
        runtimeUniforms: WPEMetalRuntimeUniforms?,
        firstFrameStats: WPEMetalTextureVisualStats?,
        resolutionDiagnostics: WPEResolutionDiagnosticsSnapshot,
        frameOrdinal: Int = 0
    ) {
        guard WPESceneDebugArtifacts.shared.isEnabled else { return }
        lock.lock()
        guard let scene, !frameComplete else { lock.unlock(); return }
        frameComplete = true
        let passSnapshot = passes
        let resourceSnapshot = resources
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
            "final": finalBlock
        ]
        let passCount = passSnapshot.count

        guard JSONSerialization.isValidJSONObject(trace),
              let data = try? JSONSerialization.data(withJSONObject: trace, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            WPESceneDebugArtifacts.shared.appendLog("[canonical-trace] trace.json serialization failed", level: .error)
            return
        }
        WPESceneDebugArtifacts.shared.recordNote(name: "trace.json", contents: text)
        WPESceneDebugArtifacts.shared.appendLog(
            "[canonical-trace] wrote trace.json passes=\(passCount) frame=\(frameOrdinal)", level: .info
        )
    }

    // MARK: - Description helpers (mirror WPESceneDebugArtifacts)

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
        // Report the AUTHORED register slot (`g_Texture7` -> 7), not the dense
        // enumeration index. Our MSL packs samplers densely into tex0..texN, so a
        // shader declaring g_Texture0/1/7 used to reflect as slots 0/1/2 while
        // Windows reflects 0/1/7 — the diff then compared our g_Texture7 against
        // whatever D3D had left in register 2, which is where 329 of 333 spurious
        // `asset/texture/fallback` findings came from. Rendering is unaffected:
        // the dense index is a Metal binding detail and is self-consistent.
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

    private func uniformVariables(layout: [WPEUniformSlot], slots: [SIMD4<Float>]) -> [[String: Any]] {
        layout.map { uniform in
            let floats: [Double] = (0..<max(uniform.slotCount, 0)).flatMap { offset -> [Double] in
                let index = uniform.slot + offset
                guard slots.indices.contains(index) else { return [] }
                let v = slots[index]
                return [Double(v.x), Double(v.y), Double(v.z), Double(v.w)]
            }
            var variable: [String: Any] = [
                "name": uniform.name,
                "type": uniform.glslType,
                "slot": uniform.slot,
                "slotCount": uniform.slotCount,
                "arrayLength": jsonOrNull(uniform.arrayLength),
                "materialName": jsonOrNull(uniform.materialName),
                "rawSlotFloats": floats
            ]
            switch uniform.glslType {
            case "float", "int", "bool":
                variable["value"] = jsonOrNull(floats.first)
            case "vec2": variable["value"] = Array(floats.prefix(2))
            case "vec3": variable["value"] = Array(floats.prefix(3))
            case "vec4": variable["value"] = Array(floats.prefix(4))
            case "mat4":
                let m = Array(floats.prefix(16))
                variable["value"] = m
                if m.count == 16 {
                    variable["matrix4x4"] = m
                    variable["matrixMajor"] = "row"
                }
            default:
                variable["value"] = floats
            }
            return variable
        }
    }

    private func puppetUniformVariables(_ inputs: [PuppetUniformInput]) -> [[String: Any]] {
        inputs.enumerated().map { index, input in
            let values = [Double(input.value.x), Double(input.value.y), Double(input.value.z), Double(input.value.w)]
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
            "lineage": ["pass-\(String(format: "%04d", ordinal))"]
        ]
    }

    // MARK: - Texture metrics (best-effort, post-commit only)

    private func textureMetrics(_ texture: MTLTexture) -> (sha256: String, visualStats: [String: Any])? {
        // Output ring is `.private`; one staging copy for hash + visual stats.
        guard let texture = WPEMetalTextureSnapshotter.stagedForCPURead(texture) else {
            WPESceneDebugArtifacts.shared.appendLog(
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
        // Deterministic readback for hashing. rgba8/bgra8 unorm are hashed raw (exact,
        // no NaN/denormal). HDR rgba16Float is decoded to canonical clamped 8-bit
        // FIRST: raw Float16 bytes are non-deterministic across runs (NaN payloads,
        // ±0, denormals, and stale/aliased bytes in HDR targets' unwritten texels)
        // even when the rendered image is identical — SDR scenes hash byte-stably,
        // HDR ones did not. Clamp+quantize to the visual result removes that noise.
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
            WPESceneDebugArtifacts.shared.appendLog(
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
        // Float16 RGBA → canonical clamped 8-bit (the visual output). Non-finite
        // (NaN/±Inf) and negatives collapse to 0; values ≥1 (incl. stale garbage in
        // unwritten HDR texels) clamp to 255 — both deterministic across runs.
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
