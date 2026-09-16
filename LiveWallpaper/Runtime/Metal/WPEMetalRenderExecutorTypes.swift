#if !LITE_BUILD
import CoreGraphics
import Foundation
import LiveWallpaperProWPE
import Metal
import MetalKit
import os
import simd

struct WPEMetalInitialSceneClearStats: Equatable {
    var passID: String?
    var skipped = 0
    var fallback = 0
    var rejectReason: String?
}

struct WPEMetalSceneQuadBatchStats {
    var encoders = 0
    var draws = 0
    var texturedDraws = 0
    var rejectedPasses: [String: Int] = [:]
}

/// Only the owner closes borrowed encoders.
final class WPEMetalSolidSceneRun {
    var encoder: MTLRenderCommandEncoder?
    var destinationTexture: MTLTexture?
    var encoderCount = 0
    var drawCount = 0
    var texturedDrawCount = 0
    private var deferredAliasPassIndices: [Int] = []
    private let releaseAliasPass: (Int) -> Void

    init(releaseAliasPass: @escaping (Int) -> Void = { _ in }) {
        self.releaseAliasPass = releaseAliasPass
    }

    /// A sampled FBO stays leased until the entire encoder has finished encoding.
    /// No later allocation may reuse its heap interval while this run is open.
    func deferEndPass(_ index: Int) {
        deferredAliasPassIndices.append(index)
    }

    func end() {
        encoder?.endEncoding()
        encoder = nil
        destinationTexture = nil
        for index in deferredAliasPassIndices { releaseAliasPass(index) }
        deferredAliasPassIndices.removeAll(keepingCapacity: true)
    }

    /// This is admission to a shared attachment, never an identity-copy proof.
    static func texturedRejectionReason(
        _ layer: WPEPreparedRenderLayer, textures: [String: MTLTexture],
        output: MTLTexture, hasMediaSubstitution: Bool,
        finalCopyPass: WPEPreparedRenderPass? = nil, frameState: WPEMetalFrameState? = nil
    ) -> String? {
        let graph = layer.graphLayer
        guard graph.visible else { return "hidden" }
        guard layer.puppetModel == nil, graph.puppetPath == nil, graph.attachment == nil,
              graph.groupRenderTarget == nil, graph.groupCompositeSource == nil,
              graph.groupLocalGeometry == nil,
              (graph.imagePath as NSString).pathExtension.lowercased() != "mdl",
              !WPETextLayerSynthesis.isTargetPath(graph.imagePath) else { return "special-layer" }
        let pass: WPEPreparedRenderPass
        if let finalCopyPass {
            guard layer.passes.last?.id == finalCopyPass.id,
                  WPEBuiltinShaderKind(normalizing: finalCopyPass.pass.shader) == .copy else {
                return "not-final-copy"
            }
            pass = finalCopyPass
        } else {
            guard layer.passes.count == 1, let onlyPass = layer.passes.first else { return "multi-pass" }
            pass = onlyPass
        }
        guard pass.shader?.isBuiltin == true,
              let kind = WPEBuiltinShaderKind(normalizing: pass.pass.shader),
              kind == .copy || kind == .genericImage2 || kind == .genericImage4 else { return "shader" }
        switch pass.pass.phase {
        case .material: break
        case .command(let file) where kind == .copy && file == WPERenderPassPhase.sceneCopyCommandFile: break
        default: return "phase"
        }
        guard pass.pass.target == .scene, pass.pass.visibilityGate == nil else { return "target-or-gate" }
        guard pass.pass.depthTest.lowercased() == "disabled",
              pass.pass.depthWrite.lowercased() == "disabled" else { return "depth" }
        guard !hasMediaSubstitution else { return "media-substitution" }
        guard output.sampleCount == 1 else { return "multisample" }
        func rejection(_ reference: WPETextureReference) -> String? {
            switch reference {
            case .previous: return "target-dependency"
            case .fbo(let name):
                guard finalCopyPass != nil, !WPETextureReference.isSceneAliasName(name) else {
                    return "target-dependency"
                }
                // latestNamedTextures alone may refer to a previous frame or a
                // cache seed. Only an explicit write in this frame proves provenance.
                guard let frameState, frameState.writtenTargets.contains(.named(name)),
                      let texture = frameState.latestNamedTextures[name],
                      frameState.hasInitialized(texture) else { return "fbo-not-written-this-frame" }
                return samplesAttachment(texture, output: output) ? "attachment-alias" : nil
            case .image(let path), .asset(let path):
                guard let texture = textures[path] else { return "unresolved-texture" }
                return samplesAttachment(texture, output: output) ? "attachment-alias" : nil
            }
        }
        // Keep the existing prepared-before-raw diagnostic priority. Physical
        // alias and this-frame producer checks cannot be reduced to read sets.
        return rejection(pass.access.source)
            ?? pass.access.references(in: .preparedBindings).lazy.compactMap(rejection).first
            ?? pass.access.references(in: .rawTextures).lazy.compactMap(rejection).first
            ?? pass.access.references(in: .rawBinds).lazy.compactMap(rejection).first
    }

    /// Views share their parent's allocation. Heap/buffer identity is deliberately
    /// conservative: distinct texture objects may still occupy overlapping bytes.
    static func samplesAttachment(_ texture: MTLTexture, output: MTLTexture) -> Bool {
        func root(_ texture: MTLTexture) -> MTLTexture {
            var result = texture
            while let parent = result.parent { result = parent }
            return result
        }
        let source = root(texture), destination = root(output)
        if source === destination { return true }
        if let heap = source.heap, let destinationHeap = destination.heap,
           heap === destinationHeap { return true }
        if let buffer = source.buffer, let destinationBuffer = destination.buffer,
           buffer === destinationBuffer { return true }
        if let surface = source.iosurface, let destinationSurface = destination.iosurface,
           surface === destinationSurface { return true }
        return false
    }

    static func accepts(_ layer: WPEPreparedRenderLayer) -> Bool {
        guard layer.graphLayer.visible, layer.puppetModel == nil, layer.graphLayer.puppetPath == nil,
              layer.passes.count == 1, let pass = layer.passes.first,
              pass.shader?.isBuiltin == true,
              WPEBuiltinShaderKind(normalizing: pass.pass.shader) == .solidLayer,
              pass.pass.target == .scene, pass.pass.visibilityGate == nil,
              pass.pass.depthTest.lowercased() == "disabled",
              pass.pass.depthWrite.lowercased() == "disabled",
              case .material = pass.pass.phase else { return false }
        // The builder inserts source at slot 0 even though solid shaders do not sample.
        // Reject dependencies that could request a snapshot before dispatch.
        return !pass.access.hasPreviousReference && pass.access.fboNames.isEmpty
    }
}

final class WPEMetalTextureSlotTable {
    private var textures: ContiguousArray<MTLTexture?>
    private var samplingDescriptors: ContiguousArray<WPETexSpriteSamplingDescriptor?>
    private var samplers: ContiguousArray<MTLSamplerState?>
    private var resolutions: ContiguousArray<WPEMetalTextureResolution?>

    init(slotCount: Int = WPEShaderTranspiler.customTextureSlotLimit) {
        let count = max(0, slotCount)
        textures = ContiguousArray(repeating: nil, count: count)
        samplingDescriptors = ContiguousArray(repeating: nil, count: count)
        samplers = ContiguousArray(repeating: nil, count: count)
        resolutions = ContiguousArray(repeating: nil, count: count)
    }

    var slotCount: Int { textures.count }

    subscript(slot: Int) -> MTLTexture? {
        get { textures.indices.contains(slot) ? textures[slot] : nil }
        set {
            guard textures.indices.contains(slot) else { return }
            textures[slot] = newValue
            samplingDescriptors[slot] = nil
            samplers[slot] = nil
            resolutions[slot] = nil
        }
    }

    func set(
        texture: MTLTexture?,
        samplingDescriptor: WPETexSpriteSamplingDescriptor?,
        sampler: MTLSamplerState? = nil,
        resolution: WPEMetalTextureResolution? = nil,
        at slot: Int
    ) {
        guard textures.indices.contains(slot) else { return }
        textures[slot] = texture
        samplingDescriptors[slot] = texture == nil ? nil : samplingDescriptor
        samplers[slot] = sampler
        resolutions[slot] = texture == nil ? nil : resolution
    }

    func samplingDescriptor(at slot: Int) -> WPETexSpriteSamplingDescriptor? {
        guard textures.indices.contains(slot), textures[slot] != nil else { return nil }
        return samplingDescriptors[slot]
    }

    func resolution(at slot: Int) -> WPEMetalTextureResolution? {
        guard textures.indices.contains(slot), textures[slot] != nil else { return nil }
        return resolutions[slot]
    }

    /// The same resolved slot values, submitted in two API calls without allocating
    /// per-draw arrays. Every encoder receives its own complete declared range.
    func bindFragmentResources(to encoder: MTLRenderCommandEncoder, count: Int) {
        precondition(count >= 0 && count <= slotCount)
        guard count > 0 else { return }
        let range = NSRange(location: 0, length: count)
        textures.withUnsafeBufferPointer {
            encoder.__setFragmentTextures($0.baseAddress!, with: range)
        }
        samplers.withUnsafeBufferPointer {
            encoder.__setFragmentSamplerStates($0.baseAddress!, with: range)
        }
    }

    func reset() {
        for index in textures.indices {
            textures[index] = nil
            samplingDescriptors[index] = nil
            samplers[index] = nil
            resolutions[index] = nil
        }
    }
}

enum WPEMetalSceneCaptureUtilityModels {
    enum OutputGeometry { case fullscreen, subregion }

    /// Fullscreen/project always cover the frame. A composelayer stays fullscreen unless its authored footprint is a safe sub-rect.
    static func outputGeometry(
        path: String,
        geometry: WPERenderLayerGeometry,
        sceneSize: CGSize
    ) -> OutputGeometry {
        outputGeometry(
            kind: WPEUtilityModelKind.classify(path),
            geometry: geometry,
            sceneSize: sceneSize
        )
    }

    static func outputGeometry(
        kind: WPEUtilityModelKind?,
        geometry: WPERenderLayerGeometry,
        sceneSize: CGSize
    ) -> OutputGeometry {
        guard kind == .composeLayer else { return .fullscreen }
        guard let size = geometry.size else { return .fullscreen }
        let sceneW = max(Float(sceneSize.width), 1)
        let sceneH = max(Float(sceneSize.height), 1)
        let width = Float(size.width) * max(abs(Float(geometry.scale.x)), 0.0001)
        let height = Float(size.height) * max(abs(Float(geometry.scale.y)), 0.0001)
        guard width.isFinite, height.isFinite, width > 1, height > 1 else { return .fullscreen }
        let rotationEpsilon: Float = 0.001
        let zAxisTurn = normalizedAbsoluteZTurn(Float(geometry.angles.z))
        let isHalfTurn = abs(zAxisTurn - .pi) <= rotationEpsilon
        if abs(Float(geometry.angles.x)) > rotationEpsilon
            || abs(Float(geometry.angles.y)) > rotationEpsilon {
            return .fullscreen
        }
        let flipsX = geometry.scale.x < 0
        let flipsY = geometry.scale.y < 0
        if flipsX != flipsY && !isHalfTurn { return .fullscreen }
        let fullCoverage: Float = 0.95
        if width >= sceneW * fullCoverage && height >= sceneH * fullCoverage { return .fullscreen }
        return .subregion
    }

    private static func normalizedAbsoluteZTurn(_ radians: Float) -> Float {
        guard radians.isFinite else { return .infinity }
        return abs(radians.remainder(dividingBy: 2 * .pi))
    }
}

/// Memo of `outputGeometry` per layer. Key omits fields the function never reads.
final class WPESceneCaptureOutputGeometryMemo {
    private struct Entry {
        let path: String
        let size: CGSize?
        let scale: SIMD3<Double>
        let angles: SIMD3<Double>
        let sceneSize: CGSize
        let result: WPEMetalSceneCaptureUtilityModels.OutputGeometry
    }

    private var entries: [String: Entry] = [:]

    func outputGeometry(
        layer: WPERenderLayer,
        geometry: WPERenderLayerGeometry,
        sceneSize: CGSize
    ) -> WPEMetalSceneCaptureUtilityModels.OutputGeometry {
        let path = layer.imagePath
        let objectID = layer.objectID
        if let entry = entries[objectID],
           entry.sceneSize == sceneSize,
           entry.size == geometry.size,
           entry.scale == geometry.scale,
           entry.angles == geometry.angles,
           entry.path == path {
            return entry.result
        }
        let result = WPEMetalSceneCaptureUtilityModels.outputGeometry(
            kind: layer.utilityModelKind,
            geometry: geometry,
            sceneSize: sceneSize
        )
        if entries.count >= 512, entries[objectID] == nil {
            entries.removeAll(keepingCapacity: true)
        }
        entries[objectID] = Entry(
            path: path,
            size: geometry.size,
            scale: geometry.scale,
            angles: geometry.angles,
            sceneSize: sceneSize,
            result: result
        )
        return result
    }

    func removeAll() {
        entries.removeAll(keepingCapacity: false)
    }
}

/// Thread-safe sink for GPU command-buffer errors: they surface in the completed handler on a
/// GPU thread AFTER the frame call returned, so they can't throw. Bounded to count + last
/// message so a persistently-failing GPU never grows memory.
final class WPEGPUErrorSink: @unchecked Sendable {
    private let lock = NSLock()
    private var errorCount = 0
    private var lastMessage: String?

    /// First five, then every 300th — same cadence as present drawable-miss logs.
    static func shouldLogOccurrence(_ count: Int) -> Bool {
        count <= 5 || count % 300 == 0
    }

    @discardableResult
    func record(_ message: String) -> Int {
        lock.lock()
        errorCount += 1
        lastMessage = message
        let n = errorCount
        lock.unlock()
        return n
    }

    var summary: (count: Int, last: String?) {
        lock.lock()
        defer { lock.unlock() }
        return (errorCount, lastMessage)
    }
}

final class WPEShaderErrorSink: @unchecked Sendable {
    private let lock = NSLock()
    private var failures: [String: String] = [:]

    func record(shader: String, reason: String) {
        lock.lock()
        failures[shader] = reason
        lock.unlock()
    }

    func reset() {
        lock.lock()
        failures.removeAll()
        lock.unlock()
    }

    var summary: (count: Int, entries: [(shader: String, reason: String)]) {
        lock.lock()
        defer { lock.unlock() }
        let entries = failures.sorted { $0.key < $1.key }.map { (shader: $0.key, reason: $0.value) }
        return (entries.count, entries)
    }
}
#endif
