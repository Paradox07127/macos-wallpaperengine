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
    case incompatibleTexture(WPEResourceID)
    case encoderUnavailable
}

typealias WPEParityResourceBindings = [WPEResourceBindingScope: [WPEResourceID: WPEResourceID]]

/// Owns the frame-transient textures (`.aliased` in one untracked placement heap, `.memoryless` in
/// tile memory); every other resource is supplied by the caller per frame.
final class WPEParityGraphExecutor {
    enum Submission {
        case committed(MTLCommandBuffer)
        /// Every arena slot was in flight; nothing was encoded or committed.
        case skipped
    }

    /// The draws one draw operation encodes, in order; with none its render pass still runs its load and store actions.
    /// `arena` is the frame's slot, for per-draw data the provider uploads itself.
    typealias DrawProvider = (_ operation: Int, _ textures: [WPEResourceID: MTLTexture],
                              _ arena: WPEParityFrameArena.Frame) throws -> [WPEParityDraw]
    /// Emits and encodes one draw before the next batch allocates its vertices.
    typealias DrawVisitor = (_ operation: Int, _ textures: [WPEResourceID: MTLTexture],
                             _ arena: WPEParityFrameArena.Frame,
                             _ emit: (WPEParityDraw) throws -> Void) throws -> Void

    let graph: WPECompiledRenderGraph
    let heap: MTLHeap?
    let transientTextures: [WPEResourceID: MTLTexture]
    private let drawEncoder: WPEParityDrawEncoder
    private let arena: WPEParityFrameArena
    private let pixelFormats: [String: MTLPixelFormat]
    /// Consumer step -> producer steps whose fence it waits on before its first stage.
    private let waits: [Int: [Int]]
    private let fences: [Int: MTLFence]
    /// Orders heap use across frames, which per-encoder fences inside one command buffer do not cover.
    private let heapEvent: MTLEvent?
    private var frameCount: UInt64 = 0
    /// Logical RT name -> physical RT identity after the last submitted command stream. Keep entries for disabled
    /// effects too: re-enabling one resumes its last binding rather than deriving it from elapsed frame count.
    private(set) var resourceBindings: WPEParityResourceBindings
    /// Draws marked `dropsWhenArenaIsFull` that were skipped for want of arena space, over the executor's life.
    private(set) var droppedDraws = 0

    init(graph: WPECompiledRenderGraph, device: MTLDevice, drawEncoder: WPEParityDrawEncoder,
         arena: WPEParityFrameArena, pixelFormats: [String: MTLPixelFormat],
         resourceBindings: WPEParityResourceBindings = [:]) throws {
        func descriptor(_ resource: WPELogicalResource, _ storage: MTLStorageMode) throws -> MTLTextureDescriptor {
            guard let format = pixelFormats[resource.format] else {
                throw WPEParityGraphExecutionError.unsupportedFormat(resource.format)
            }
            // Also guards heapTextureSizeAndAlign, which validates before a heap texture is allocated.
            let maximumDimension = WPEMetalTextureLimits.maximum2DTextureDimension(for: device)
            guard resource.width > 0, resource.height > 0,
                  resource.width <= maximumDimension, resource.height <= maximumDimension,
                  resource.mipCount > 0,
                  resource.mipCount <= Int.bitWidth - max(resource.width, resource.height).leadingZeroBitCount,
                  [1, 2, 4, 8].contains(resource.sampleCount), device.supportsTextureSampleCount(resource.sampleCount),
                  resource.sampleCount == 1 || resource.mipCount == 1,
                  storage != .memoryless || resource.mipCount == 1 else {
                throw WPEParityGraphExecutionError.incompatibleTexture(resource.id)
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
        self.pixelFormats = pixelFormats
        self.waits = waits
        self.fences = fences
        self.resourceBindings = resourceBindings
    }

    /// Shared color-only clear primitive for script commands and allocation initialization. Textures remain
    /// owned by the renderer; the command buffer retains each encoded version through GPU completion.
    static func encodeColorClear(_ texture: MTLTexture, color: WPEClearColor,
                                 on commandBuffer: MTLCommandBuffer) throws {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: color.red, green: color.green,
                                                            blue: color.blue, alpha: color.alpha)
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
            throw WPEParityGraphExecutionError.encoderUnavailable
        }
        encoder.endEncoding()
    }

    /// A cached graph must resume the most recently submitted permutation, not the one it last executed.
    /// Texture allocation/reuse remains with the renderer; this changes bindings without allocating GPU objects.
    func restoreResourceBindings(_ bindings: WPEParityResourceBindings) {
        resourceBindings = bindings
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
    /// the heap event are released. `prepare` encodes ahead of the graph and runs only on a buffer that is committed.
    func encodeFrame(on queue: MTLCommandQueue, textures external: [WPEResourceID: MTLTexture],
                     prepare: (MTLCommandBuffer) throws -> Void = { _ in },
                     clearColor: (WPEPassIdentity) -> WPEClearColor? = { _ in nil },
                     draw: DrawProvider) throws -> Submission {
        try encodeFrame(on: queue, textures: external, prepare: prepare, clearColor: clearColor, visit: { operation, textures, frame, emit in
            for provided in try draw(operation, textures, frame) {
                try emit(provided)
            }
        })
    }

    func encodeFrame(on queue: MTLCommandQueue, textures external: [WPEResourceID: MTLTexture],
                     prepare: (MTLCommandBuffer) throws -> Void = { _ in },
                     shouldTransfer: (Int) -> Bool = { _ in true },
                     clearColor: (WPEPassIdentity) -> WPEClearColor? = { _ in nil },
                     visit: DrawVisitor) throws -> Submission {
        let physicalTextures = try frameTextures(external)
        var textures = try Self.scopedTextures(physicalTextures, bindings: resourceBindings, scope: .frame)
        guard let commandBuffer = queue.makeCommandBuffer() else {
            throw WPEParityGraphExecutionError.encoderUnavailable
        }
        guard let frame = arena.beginFrame(for: commandBuffer) else { return .skipped }
        frameCount += 1
        if let heapEvent {
            commandBuffer.encodeWaitForEvent(heapEvent, value: frameCount - 1)
        }

        var failure: (any Error)?
        var bindings = resourceBindings
        var scope = WPEResourceBindingScope.frame
        do {
            try prepare(commandBuffer)
            for index in graph.steps.indices {
                try encodeStep(index, textures: &textures, physicalTextures: physicalTextures,
                               bindings: &bindings, scope: &scope, frame: frame,
                               commandBuffer: commandBuffer, shouldTransfer: shouldTransfer, clearColor: clearColor, visit: visit)
            }
        } catch {
            failure = error
        }
        if let heapEvent {
            commandBuffer.encodeSignalEvent(heapEvent, value: frameCount)
        }
        commandBuffer.commit()
        // Even an error above submits its already encoded prefix. Only swaps reached by that prefix take effect.
        resourceBindings = bindings
        if let failure {
            throw failure
        }
        return .committed(commandBuffer)
    }

    private func frameTextures(_ external: [WPEResourceID: MTLTexture]) throws -> [WPEResourceID: MTLTexture] {
        var textures = transientTextures
        for id in graph.lifetimes.keys where textures[id] == nil {
            guard let texture = external[id] else {
                throw WPEParityGraphExecutionError.missingTexture(id)
            }
            if let descriptor = graph.resources[id], descriptor.lifetime != .imported {
                guard texture.width == descriptor.width, texture.height == descriptor.height,
                      texture.mipmapLevelCount == descriptor.mipCount, texture.sampleCount == descriptor.sampleCount,
                      texture.pixelFormat == pixelFormats[descriptor.format] else {
                    throw WPEParityGraphExecutionError.incompatibleTexture(id)
                }
            }
            textures[id] = texture
        }
        for step in graph.steps {
            guard case let .copy(source, destination) = step.kind else { continue }
            guard let from = textures[source], let to = textures[destination],
                  from.width == to.width, from.height == to.height, from.pixelFormat == to.pixelFormat,
                  from.mipmapLevelCount == to.mipmapLevelCount || from.mipmapLevelCount == 1,
                  from.sampleCount == to.sampleCount,
                  from.textureType == to.textureType
            else { throw WPEParityGraphExecutionError.incompatibleCopy(source: source, destination: destination) }
        }
        return textures
    }

    /// Apply the frame permutation first, then the effect-local permutation to that result. Script calls and
    /// graph scope changes share this composition, including frame swaps of effect-swapped targets.
    static func scopedTextures(_ physical: [WPEResourceID: MTLTexture], bindings: WPEParityResourceBindings,
                               scope: WPEResourceBindingScope, resources: [WPEResourceID]? = nil) throws
        -> [WPEResourceID: MTLTexture] {
        let frame = try boundTextures(physical, bindings: bindings[.frame, default: [:]])
        return scope == .frame ? frame : try boundTextures(frame, bindings: bindings[scope, default: [:]],
                                                           resources: resources)
    }

    private static func boundTextures(_ physical: [WPEResourceID: MTLTexture],
                                      bindings: [WPEResourceID: WPEResourceID],
                                      resources: [WPEResourceID]? = nil) throws -> [WPEResourceID: MTLTexture] {
        guard !bindings.isEmpty else { return physical }
        var textures = physical
        for id in resources ?? Array(bindings.keys) where physical[id] != nil {
            guard let destination = bindings[id] else { continue }
            guard let texture = physical[destination] else {
                throw WPEParityGraphExecutionError.missingTexture(destination)
            }
            textures[id] = texture
        }
        return textures
    }

    private func encodeStep(_ index: Int, textures: inout [WPEResourceID: MTLTexture],
                            physicalTextures: [WPEResourceID: MTLTexture], bindings: inout WPEParityResourceBindings,
                            scope: inout WPEResourceBindingScope, frame: WPEParityFrameArena.Frame,
                            commandBuffer: MTLCommandBuffer, shouldTransfer: (Int) -> Bool,
                            clearColor: (WPEPassIdentity) -> WPEClearColor?,
                            visit: DrawVisitor) throws {
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
        case .copy, .resolve:
            if let operation = step.operations.first, !shouldTransfer(operation) {
                // Consumers still need the graph's fence hand-over when this frame preserves old history.
                if !waitFences.isEmpty || fence != nil {
                    try blit { _ in }
                }
                return
            }
        default: break
        }
        switch step.kind {
        case let .resourceScope(next, resources):
            scope = next
            textures = try Self.scopedTextures(physicalTextures, bindings: bindings, scope: next, resources: resources)
            return
        case let .swapResources(first, second):
            let (a, b) = try (texture(first), texture(second))
            textures[first] = b
            textures[second] = a
            var local = bindings[scope, default: [:]]
            let (aID, bID) = (local[first] ?? first, local[second] ?? second)
            local[first] = bID == first ? nil : bID
            local[second] = aID == second ? nil : aID
            bindings[scope] = local.isEmpty ? nil : local
            return
        case let .copy(source, destination):
            let (from, to) = try (texture(source), texture(destination))
            try blit {
                $0.copy(from: from, sourceSlice: 0, sourceLevel: 0, to: to, destinationSlice: 0, destinationLevel: 0,
                        sliceCount: 1, levelCount: from.mipmapLevelCount)
            }
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
                if case .clear(.color) = action.load,
                   let operation = step.operations.reversed().first(where: { operation in
                       guard case let .clearColor(view, _) = graph.operations[operation].kind else { return false }
                       return view.resource == action.subresource.resource && (view.mips?.contains(action.subresource.mip) ?? true)
                   }), let color = clearColor(graph.operations[operation].pass) {
                    // Folded clears retain their original operation. Match the last clear of this exact view,
                    // so an effect's later clear cannot inherit a text background's live color.
                    pass.colorAttachments[slot].clearColor = MTLClearColor(red: color.red, green: color.green,
                                                                           blue: color.blue, alpha: color.alpha)
                }
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
            try visit(operation, textures, frame) { provided in
                do {
                    try drawEncoder.encode(provided, frame: frame,
                                           hasDepthAttachment: pass.depthAttachment.texture != nil, on: encoder)
                } catch WPEParityExecutionError.arenaExhausted where provided.dropsWhenArenaIsFull {
                    droppedDraws += 1
                }
            }
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
