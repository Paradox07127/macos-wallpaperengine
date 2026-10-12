#if !LITE_BUILD
import LiveWallpaperProWPE
import Metal

enum WPEParityGraphExecutionError: Error, Equatable {
    case unsupportedFormat(String)
    case allocationFailed(WPEResourceID)
    /// Heap, event or fence creation failed.
    case objectUnavailable
    case missingTexture(WPEResourceID)
    case incompatibleCopy(source: WPEResourceID, destination: WPEResourceID)
    case encoderUnavailable
}

/// Owns the frame-transient textures (`.aliased` in one untracked placement heap, `.memoryless` in
/// tile memory); every other resource is supplied by the caller per frame.
final class WPEParityGraphExecutor {
    enum Submission {
        case committed(MTLCommandBuffer)
        /// Every arena slot was in flight; nothing was encoded or committed.
        case skipped
    }

    typealias DrawProvider = (_ operation: Int, _ textures: [WPEResourceID: MTLTexture]) throws -> WPEParityDraw

    let graph: WPECompiledRenderGraph
    let heap: MTLHeap?
    let transientTextures: [WPEResourceID: MTLTexture]
    private let drawEncoder: WPEParityDrawEncoder
    private let arena: WPEParityFrameArena
    /// Consumer step -> producer steps whose fence it waits on before its first stage.
    private let waits: [Int: [Int]]
    private let fences: [Int: MTLFence]
    /// Orders heap use across frames, which per-encoder fences inside one command buffer do not cover.
    private let heapEvent: MTLEvent?
    private var frameCount: UInt64 = 0

    init(graph: WPECompiledRenderGraph, device: MTLDevice, drawEncoder: WPEParityDrawEncoder,
         arena: WPEParityFrameArena, pixelFormats: [String: MTLPixelFormat]) throws {
        func descriptor(_ resource: WPELogicalResource, _ storage: MTLStorageMode) throws -> MTLTextureDescriptor {
            guard let format = pixelFormats[resource.format] else {
                throw WPEParityGraphExecutionError.unsupportedFormat(resource.format)
            }
            let descriptor = MTLTextureDescriptor()
            descriptor.textureType = resource.sampleCount > 1 ? .type2DMultisample : .type2D
            descriptor.pixelFormat = format
            descriptor.width = resource.width
            descriptor.height = resource.height
            descriptor.mipmapLevelCount = resource.mipCount
            descriptor.sampleCount = resource.sampleCount
            descriptor.storageMode = storage
            descriptor.usage = storage == .memoryless ? .renderTarget : [.renderTarget, .shaderRead]
            return descriptor
        }

        var textures: [WPEResourceID: MTLTexture] = [:]
        for (id, storage) in graph.storage where storage == .memoryless {
            guard let resource = graph.resources[id],
                  let texture = try device.makeTexture(descriptor: descriptor(resource, .memoryless))
            else { throw WPEParityGraphExecutionError.allocationFailed(id) }
            textures[id] = texture
        }

        let layout = try graph.heapLayout { resource in
            let requirement = try device.heapTextureSizeAndAlign(descriptor: descriptor(resource, .private))
            return (requirement.size, requirement.align)
        }
        if layout.size > 0 {
            let heapDescriptor = MTLHeapDescriptor()
            heapDescriptor.type = .placement
            heapDescriptor.storageMode = .private
            heapDescriptor.hazardTrackingMode = .untracked
            heapDescriptor.size = layout.size
            guard let heap = device.makeHeap(descriptor: heapDescriptor),
                  let event = device.makeEvent()
            else { throw WPEParityGraphExecutionError.objectUnavailable }
            for (id, offset) in layout.offsets {
                guard let resource = graph.resources[id],
                      let texture = try heap.makeTexture(descriptor: descriptor(resource, .private), offset: offset)
                else { throw WPEParityGraphExecutionError.allocationFailed(id) }
                textures[id] = texture
            }
            self.heap = heap
            heapEvent = event
        } else {
            heap = nil
            heapEvent = nil
        }

        let waits = WPEParityGraphExecutor.heapWaits(graph, heapResources: Set(layout.offsets.keys))
        var fences: [Int: MTLFence] = [:]
        for producer in Set(waits.values.joined()) {
            guard let fence = device.makeFence() else { throw WPEParityGraphExecutionError.objectUnavailable }
            fences[producer] = fence
        }

        self.graph = graph
        transientTextures = textures
        self.drawEncoder = drawEncoder
        self.arena = arena
        self.waits = waits
        self.fences = fences
    }

    /// Heap textures are untracked, so every hazard on them, and every hand-over of memory from one
    /// group member to the next, becomes a fence wait.
    private static func heapWaits(_ graph: WPECompiledRenderGraph,
                                  heapResources: Set<WPEResourceID>) -> [Int: [Int]] {
        let touches = graph.steps.map { step in
            var resources = Set((step.reads + step.writes).map(\.subresource.resource))
            if let encoder = step.encoder {
                for attachment in encoder.colorAttachments + [encoder.depthAttachment].compactMap(\.self) {
                    resources.insert(attachment.subresource.resource)
                }
            }
            return resources
        }
        var waits: [Int: Set<Int>] = [:]
        for dependency in graph.dependencies where heapResources.contains(dependency.subresource.resource) {
            waits[dependency.consumer, default: []].insert(dependency.producer)
        }
        for group in graph.allocationGroups {
            for (previous, next) in zip(group, group.dropFirst()) {
                guard let used = graph.lifetimes[previous], let start = graph.lifetimes[next]?.lowerBound else { continue }
                for step in used where touches[step].contains(previous) {
                    waits[start, default: []].insert(step)
                }
            }
        }
        return waits.mapValues { $0.sorted() }
    }

    /// Thrown errors after the arena slot is taken still commit the partial frame, so the slot and
    /// the heap event are released.
    func encodeFrame(on queue: MTLCommandQueue, textures external: [WPEResourceID: MTLTexture],
                     draw: DrawProvider) throws -> Submission {
        let textures = try frameTextures(external)
        guard let commandBuffer = queue.makeCommandBuffer() else {
            throw WPEParityGraphExecutionError.encoderUnavailable
        }
        guard let frame = arena.beginFrame(for: commandBuffer) else { return .skipped }
        frameCount += 1
        if let heapEvent {
            commandBuffer.encodeWaitForEvent(heapEvent, value: frameCount - 1)
        }

        var failure: (any Error)?
        do {
            for index in graph.steps.indices {
                try encodeStep(index, textures: textures, frame: frame, commandBuffer: commandBuffer, draw: draw)
            }
        } catch {
            failure = error
        }
        if let heapEvent {
            commandBuffer.encodeSignalEvent(heapEvent, value: frameCount)
        }
        commandBuffer.commit()
        if let failure {
            throw failure
        }
        return .committed(commandBuffer)
    }

    private func frameTextures(_ external: [WPEResourceID: MTLTexture]) throws -> [WPEResourceID: MTLTexture] {
        var textures = transientTextures
        for id in graph.lifetimes.keys where textures[id] == nil {
            guard let texture = external[id] else { throw WPEParityGraphExecutionError.missingTexture(id) }
            textures[id] = texture
        }
        for step in graph.steps {
            guard case let .copy(source, destination) = step.kind else { continue }
            guard let from = textures[source], let to = textures[destination],
                  from.width == to.width, from.height == to.height, from.pixelFormat == to.pixelFormat,
                  from.mipmapLevelCount == to.mipmapLevelCount, from.sampleCount == to.sampleCount,
                  from.textureType == to.textureType
            else { throw WPEParityGraphExecutionError.incompatibleCopy(source: source, destination: destination) }
        }
        return textures
    }

    private func encodeStep(_ index: Int, textures: [WPEResourceID: MTLTexture], frame: WPEParityFrameArena.Frame,
                            commandBuffer: MTLCommandBuffer, draw: DrawProvider) throws {
        let step = graph.steps[index]
        let waitFences = waits[index, default: []].compactMap { fences[$0] }
        let fence = fences[index]

        func texture(_ id: WPEResourceID) throws -> MTLTexture {
            guard let texture = textures[id] else { throw WPEParityGraphExecutionError.missingTexture(id) }
            return texture
        }
        func blit(_ body: (MTLBlitCommandEncoder) -> Void) throws {
            guard let encoder = commandBuffer.makeBlitCommandEncoder() else {
                throw WPEParityGraphExecutionError.encoderUnavailable
            }
            for waitFence in waitFences {
                encoder.waitForFence(waitFence)
            }
            body(encoder)
            if let fence {
                encoder.updateFence(fence)
            }
            encoder.endEncoding()
        }

        let pass = MTLRenderPassDescriptor()
        switch step.kind {
        case let .copy(source, destination):
            let (from, to) = try (texture(source), texture(destination))
            try blit { $0.copy(from: from, to: to) }
            return
        case let .generateMips(id):
            let mipmapped = try texture(id)
            try blit { $0.generateMipmaps(for: mipmapped) }
            return
        case let .resolve(source, destination):
            // The source keeps its samples: the compiler stored them for this step and possibly later ones.
            pass.colorAttachments[0].texture = textures[source]
            pass.colorAttachments[0].loadAction = .load
            pass.colorAttachments[0].storeAction = .storeAndMultisampleResolve
            pass.colorAttachments[0].resolveTexture = textures[destination]
        case let .render(group):
            for (slot, action) in group.colorAttachments.enumerated() {
                Self.configure(pass.colorAttachments[slot], action, textures)
            }
            if let depth = group.depthAttachment, let texture = textures[depth.subresource.resource] {
                Self.configure(pass.depthAttachment, depth, textures)
                if [.depth32Float_stencil8, .depth24Unorm_stencil8].contains(texture.pixelFormat) {
                    // D3D clears depth only; stencil keeps its contents unless it has no memory to keep them in.
                    let keeps = texture.storageMode != .memoryless
                    pass.stencilAttachment.texture = texture
                    pass.stencilAttachment.level = depth.subresource.mip
                    pass.stencilAttachment.loadAction = keeps ? .load : .dontCare
                    pass.stencilAttachment.storeAction = keeps ? .store : .dontCare
                }
            }
        }

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
            throw WPEParityGraphExecutionError.encoderUnavailable
        }
        defer { encoder.endEncoding() }
        for waitFence in waitFences {
            encoder.waitForFence(waitFence, before: .vertex)
        }
        for operation in step.operations {
            guard case .draw = graph.operations[operation].kind else { continue }
            try drawEncoder.encode(draw(operation, textures), frame: frame, on: encoder)
        }
        if let fence {
            encoder.updateFence(fence, after: .fragment)
        }
    }

    private static func configure(_ attachment: MTLRenderPassAttachmentDescriptor, _ action: WPEAttachmentAction,
                                  _ textures: [WPEResourceID: MTLTexture]) {
        attachment.texture = textures[action.subresource.resource]
        attachment.level = action.subresource.mip
        switch action.load {
        case .load:
            attachment.loadAction = .load
        case .dontCare:
            attachment.loadAction = .dontCare
        case let .clear(.color(color)):
            attachment.loadAction = .clear
            (attachment as? MTLRenderPassColorAttachmentDescriptor)?.clearColor =
                MTLClearColor(red: color.red, green: color.green, blue: color.blue, alpha: color.alpha)
        case let .clear(.depth(depth)):
            attachment.loadAction = .clear
            (attachment as? MTLRenderPassDepthAttachmentDescriptor)?.clearDepth = depth
        }
        switch action.store {
        case .store:
            attachment.storeAction = .store
        case .dontCare:
            attachment.storeAction = .dontCare
        case let .multisampleResolve(into: destination):
            attachment.storeAction = .multisampleResolve
            attachment.resolveTexture = textures[destination]
        case let .storeAndMultisampleResolve(into: destination):
            attachment.storeAction = .storeAndMultisampleResolve
            attachment.resolveTexture = textures[destination]
        }
    }
}
#endif
