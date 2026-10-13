#if !LITE_BUILD
import LiveWallpaperProWPE

/// Graph operations keep the original draw plan indices; live particle entries select their prototype at encode.
enum WPEParityGraphDrawSource {
    case layout(Int)
    case particlePrefix(Int)
    case particleSnapshot(Int)
    case particleSuffix(Int)
    case state
}

struct WPEParityParticleGraph {
    let operations: [WPERenderOperation]
    let sources: [WPEParityGraphDrawSource]
    let preservingTransfers: Set<Int>
    let snapshotSkips: [String: WPEParityFrameSkip]

    init(frame: WPEParityFrame, state: WPEParitySceneState, draws: [Int: WPEParityFrameDrawPlan], variant: Int,
         snapshotObjects: Set<String>) {
        var operations: [WPERenderOperation] = []
        var sources: [WPEParityGraphDrawSource] = []
        var transfers: Set<Int> = []
        var snapshotSkips: [String: WPEParityFrameSkip] = [:]
        func append(_ operation: WPERenderOperation, _ source: WPEParityGraphDrawSource) {
            operations.append(operation)
            sources.append(source)
        }
        func visible(_ objectID: String) -> Bool {
            state.index(of: objectID).map(state.isVisible(at:)) ?? true
        }
        var cursor = 0
        var blockIndex = 0
        while cursor <= frame.operations.count {
            if blockIndex < frame.particleBlocks.count,
               frame.particleBlocks[blockIndex].operations.lowerBound == cursor {
                let block = frame.particleBlocks[blockIndex]
                if visible(block.objectID) {
                    if snapshotObjects.contains(block.objectID) {
                        let source = frame.resources.first { $0.id == block.snapshotSource }
                        let target = frame.resources.first { $0.id == WPEParitySceneResource.fullFrameBuffer }
                        guard let source, let target, source.width == target.width, source.height == target.height,
                              source.format == target.format, source.mipCount == target.mipCount else {
                            snapshotSkips[block.objectID] = .texture("particle snapshot from \(block.snapshotSource) has incompatible dimensions or format; native failure semantics unverified")
                            cursor = block.operations.upperBound
                            blockIndex += 1
                            continue
                        }
                    }
                    let entries = block.operations.compactMap { draws[$0] }
                    let reads = Set(entries.flatMap { entry in
                        entry.textures[variant].values.compactMap { source -> WPEResourceID? in
                            if case let .resource(id) = source {
                                return id
                            }
                            return nil
                        }
                    }).sorted().map { WPETextureView($0) }
                    let original = block.operations.compactMap { index -> WPEDrawOperation? in
                        guard draws[index] != nil, case let .draw(draw) = frame.operations[index].kind else { return nil }
                        return draw
                    }
                    let draw = WPEDrawOperation(reads: reads, readsDestination: true,
                                                depthTest: original.contains { $0.depthTest },
                                                depthWrite: original.contains { $0.depthWrite })
                    let pass = WPEPassIdentity("\(block.objectID)/particle/block")
                    let targets = WPERenderOperation(pass: pass,
                                                     .setTargets(color: [WPETextureView(block.color)], depth: block.depth.map { WPETextureView($0) }))
                    append(targets, .state)
                    append(WPERenderOperation(pass: pass, .draw(draw)), .particlePrefix(blockIndex))
                    if !snapshotObjects.contains(block.objectID) {
                        cursor = block.operations.upperBound
                        blockIndex += 1
                        continue
                    }
                    transfers.insert(operations.count)
                    let multisampled = frame.resources.first { $0.id == block.snapshotSource }.map { $0.sampleCount > 1 } ?? false
                    let snapshot: WPERenderOperation.Kind = multisampled
                        ? .resolve(source: block.snapshotSource, destination: WPEParitySceneResource.fullFrameBuffer)
                        : .copy(source: block.snapshotSource, destination: WPEParitySceneResource.fullFrameBuffer)
                    append(WPERenderOperation(pass: pass, snapshot), .particleSnapshot(blockIndex))
                    append(targets, .state)
                    append(WPERenderOperation(pass: pass, .draw(draw)), .particleSuffix(blockIndex))
                }
                cursor = block.operations.upperBound
                blockIndex += 1
                continue
            }
            guard cursor < frame.operations.count else { break }
            let index = cursor
            cursor += 1
            if let owner = frame.owners[index], !visible(owner) {
                continue
            }
            let operation = frame.operations[index]
            guard case let .draw(draw) = operation.kind else {
                append(operation, .layout(index))
                continue
            }
            guard let planned = draws[index] else { continue }
            let reads = planned.textures[variant].values.compactMap { source -> WPETextureView? in
                if case let .resource(id) = source {
                    return WPETextureView(id)
                }
                return nil
            }
            append(WPERenderOperation(pass: operation.pass, .draw(WPEDrawOperation(
                reads: reads, readsDestination: draw.readsDestination, overwritesTargets: false,
                depthTest: draw.depthTest, depthWrite: draw.depthWrite, state: draw.state
            ))), .layout(index))
        }
        self.operations = operations
        self.sources = sources
        preservingTransfers = transfers
        self.snapshotSkips = snapshotSkips
    }
}
#endif
