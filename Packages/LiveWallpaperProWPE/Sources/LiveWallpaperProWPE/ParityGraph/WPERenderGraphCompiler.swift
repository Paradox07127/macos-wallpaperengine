public enum WPEParityGraphError: Error, Hashable, Sendable {
    case duplicateResource(WPEResourceID)
    case unknownResource(WPEResourceID, operation: Int)
    /// Empty or out-of-range mips, or an attachment/clear view spanning more than one mip.
    case invalidView(operation: Int)
    case drawWithoutTargets(operation: Int)
    /// A draw samples a subresource it is also rendering into.
    case feedbackLoop(operation: Int)
    case incompatibleCopy(operation: Int)
    case invalidResolve(operation: Int)
    case incompatibleSwap(operation: Int)
}

/// Compiles one structural generation of a WPE frame. Authored order is never changed:
/// clears are only deferred until the next access of the cleared view, and a resolve is
/// only folded into an encoder when nothing in between touches its source or destination.
public enum WPERenderGraphCompiler {
    public static func compile(resources: [WPELogicalResource],
                               operations: [WPERenderOperation], excludingDraws: Set<Int> = [],
                               drawReads: [Int: [WPETextureView]] = [:],
                               discardableHistory: Set<WPEResourceID> = [],
                               preservingTransfers: Set<Int> = []) throws(WPEParityGraphError)
        -> WPECompiledRenderGraph {
        var table: [WPEResourceID: WPELogicalResource] = [:]
        for resource in resources where table.updateValue(resource, forKey: resource.id) != nil {
            throw .duplicateResource(resource.id)
        }
        // Final draw preparation owns readiness and the reflected read set. Keep operation indices stable so
        // diagnostics and the provider still refer to the authored stream, but skipped draws have no accesses.
        let operations = operations.enumerated().map { index, operation in
            guard case let .draw(draw) = operation.kind, let reads = drawReads[index] else { return operation }
            return WPERenderOperation(pass: operation.pass, .draw(WPEDrawOperation(
                reads: reads, readsDestination: draw.readsDestination, overwritesTargets: draw.overwritesTargets,
                depthTest: draw.depthTest, depthWrite: draw.depthWrite, state: draw.state
            )))
        }
        let normalized = try normalize(operations, table, excludingDraws: excludingDraws)
        let versions = Versioning(normalized)
        var builders = formEncoders(normalized)
        foldResolves(&builders, normalized, versions, preserving: preservingTransfers)
        let swapped = Set(operations.flatMap { operation -> [WPEResourceID] in
            if case let .swapResources(first, second) = operation.kind {
                return [first, second]
            }
            if case let .resourceScope(_, resources) = operation.kind {
                return resources
            }
            return []
        })
        let (steps, downgraded) = deriveActions(builders, normalized, versions, table,
                                                discardableHistory: discardableHistory.subtracting(swapped))
        var stepOf: [Int: Int] = [:]
        for (index, step) in steps.enumerated() {
            for operation in step.operations {
                stepOf[operation] = index
            }
        }
        let lifetimes = lifetimes(steps)
        let (storage, groups) = allocate(steps, normalized, lifetimes, table, downgraded, swapped: swapped)
        return WPECompiledRenderGraph(
            resources: table, operations: operations, accesses: versions.accesses, steps: steps,
            dependencies: dependencies(steps, stepOf), lifetimes: lifetimes, storage: storage, allocationGroups: groups
        )
    }
}

// MARK: - 1. Normalize

private enum Normalized {
    case state
    case clear(WPESubresource, WPEClearValue)
    case draw(colors: [WPESubresource], depth: WPESubresource?, samples: [WPESubresource], WPEDrawOperation)
    case transfer(WPECompiledStep.Kind, reads: [WPESubresource], writes: [WPESubresource])

    var attachments: [WPESubresource] {
        if case let .draw(colors, depth, _, _) = self {
            colors + [depth].compactMap(\.self)
        } else {
            []
        }
    }

    var reads: [WPESubresource] {
        switch self {
        case .state, .clear: []
        case let .draw(colors, depth, samples, draw):
            samples + (draw.readsDestination ? colors : []) + (draw.depthTest ? [depth].compactMap(\.self) : [])
        case let .transfer(_, reads, _): reads
        }
    }

    var writes: [WPESubresource] {
        switch self {
        case .state: []
        case let .clear(subresource, _): [subresource]
        case let .draw(colors, depth, _, draw): colors + (draw.depthWrite ? [depth].compactMap(\.self) : [])
        case let .transfer(_, _, writes): writes
        }
    }

    var touched: Set<WPESubresource> {
        Set(reads + writes + attachments)
    }
}

private func normalize(_ operations: [WPERenderOperation],
                       _ table: [WPEResourceID: WPELogicalResource],
                       excludingDraws: Set<Int>) throws(WPEParityGraphError) -> [Normalized] {
    var colors: [WPESubresource] = []
    var depth: WPESubresource?
    var result: [Normalized] = []

    for (index, operation) in operations.enumerated() {
        func resource(_ id: WPEResourceID) throws(WPEParityGraphError) -> WPELogicalResource {
            guard let resource = table[id] else { throw .unknownResource(id, operation: index) }
            return resource
        }
        func subresources(_ view: WPETextureView) throws(WPEParityGraphError) -> [WPESubresource] {
            let mipCount = try resource(view.resource).mipCount
            let mips = view.mips ?? 0 ..< mipCount
            guard !mips.isEmpty, mips.lowerBound >= 0, mips.upperBound <= mipCount else {
                throw .invalidView(operation: index)
            }
            return mips.map { WPESubresource(view.resource, mip: $0) }
        }
        func single(_ view: WPETextureView) throws(WPEParityGraphError) -> WPESubresource {
            let subresources = try subresources(view)
            guard subresources.count == 1 else { throw .invalidView(operation: index) }
            return subresources[0]
        }
        func allMips(_ id: WPEResourceID) throws(WPEParityGraphError) -> [WPESubresource] {
            try subresources(WPETextureView(id))
        }

        switch operation.kind {
        case let .setTargets(colorViews, depthView):
            colors = []
            for view in colorViews {
                try colors.append(single(view))
            }
            depth = if let depthView {
                try single(depthView)
            } else {
                nil
            }
            result.append(.state)
        case let .clearColor(view, color):
            try result.append(.clear(single(view), .color(color)))
        case let .clearDepth(view, value):
            try result.append(.clear(single(view), .depth(value)))
        case let .draw(draw):
            if excludingDraws.contains(index) {
                result.append(.state)
                continue
            }
            guard !colors.isEmpty || depth != nil else { throw .drawWithoutTargets(operation: index) }
            var samples: [WPESubresource] = []
            for view in draw.reads {
                try samples += subresources(view)
            }
            guard Set(colors + [depth].compactMap(\.self)).isDisjoint(with: samples) else {
                throw .feedbackLoop(operation: index)
            }
            result.append(.draw(colors: colors, depth: depth, samples: samples, draw))
        case let .copy(sourceID, destinationID):
            let (source, destination) = try (resource(sourceID), resource(destinationID))
            // A single-mip source fills only mip 0 of a mipmapped destination (_rt_MipMappedFrameBuffer).
            guard sourceID != destinationID, source.width == destination.width, source.height == destination.height,
                  source.format == destination.format, source.sampleCount == destination.sampleCount,
                  source.mipCount == destination.mipCount || source.mipCount == 1
            else { throw .incompatibleCopy(operation: index) }
            let mips = try allMips(sourceID)
            result.append(.transfer(.copy(source: sourceID, destination: destinationID),
                                    reads: mips, writes: mips.map { WPESubresource(destinationID, mip: $0.mip) }))
        case let .swapResources(first, second):
            let (a, b) = try (resource(first), resource(second))
            guard first != second, a.width == b.width, a.height == b.height, a.format == b.format,
                  a.sampleCount == b.sampleCount, a.mipCount == b.mipCount else {
                throw .incompatibleSwap(operation: index)
            }
            let touched = try allMips(first) + allMips(second)
            result.append(.transfer(.swapResources(first: first, second: second), reads: touched, writes: touched))
        case let .resourceScope(scope, resources):
            var touched: [WPESubresource] = []
            for id in resources {
                try touched += allMips(id)
            }
            // Versions describe the contents bound to each logical view. Scope changes, like swaps, change those
            // identities without copying pixels; account for all possible preserved physical versions.
            result.append(.transfer(.resourceScope(scope: scope, resources: resources), reads: touched, writes: touched))
        case let .generateMips(id):
            let mips = try allMips(id)
            result.append(.transfer(.generateMips(id), reads: [mips[0]], writes: Array(mips.dropFirst())))
        case let .resolve(sourceID, destinationID):
            let (source, destination) = try (resource(sourceID), resource(destinationID))
            guard source.sampleCount > 1, destination.sampleCount == 1,
                  source.width == destination.width, source.height == destination.height
            else { throw .invalidResolve(operation: index) }
            result.append(.transfer(.resolve(source: sourceID, destination: destinationID),
                                    reads: [WPESubresource(sourceID)], writes: [WPESubresource(destinationID)]))
        }
    }
    return result
}

// MARK: - 2. Version resource contents

private struct Versioning {
    var accesses: [WPEOperationAccess] = []
    /// Per operation: the version of every subresource it touches, as seen before it runs.
    var before: [[WPESubresource: WPEResourceVersion]] = []
    var final: [WPESubresource: WPEResourceVersion] = [:]

    init(_ operations: [Normalized]) {
        for (index, operation) in operations.enumerated() {
            func current(_ subresource: WPESubresource) -> WPEResourceVersion {
                final[subresource] ?? WPEResourceVersion(subresource: subresource, revision: 0, producer: nil)
            }
            before.append(Dictionary(uniqueKeysWithValues: operation.touched.map { ($0, current($0)) }))
            let reads = operation.reads.map(current)
            let writes = operation.writes.map { subresource in
                let version = WPEResourceVersion(subresource: subresource, revision: current(subresource).revision + 1,
                                                 producer: index)
                final[subresource] = version
                return version
            }
            accesses.append(WPEOperationAccess(reads: reads, writes: writes))
        }
    }
}

// MARK: - 3/4. Form encoder groups

private struct StepBuilder {
    enum Kind {
        case render(colors: [WPESubresource], depth: WPESubresource?)
        case transfer(WPECompiledStep.Kind)
    }

    var kind: Kind
    var operations: [Int]
    /// Attachment -> the clear operation whose value becomes the encoder's load action.
    var clears: [WPESubresource: Int] = [:]
    var resolves: [WPESubresource: WPEResourceID] = [:]
}

private func formEncoders(_ operations: [Normalized]) -> [StepBuilder] {
    var steps: [StepBuilder] = []
    var open: Int?
    var pending: [(subresource: WPESubresource, operations: [Int])] = []

    // A deferred clear must run before anything else observes or overwrites its view.
    func materialize(_ subresources: Set<WPESubresource>) {
        let due = pending.filter { subresources.contains($0.subresource) }
        guard !due.isEmpty else { return }
        pending.removeAll { subresources.contains($0.subresource) }
        open = nil
        for entry in due {
            let last = entry.operations[entry.operations.count - 1]
            let isDepth = if case .clear(_, .depth) = operations[last] {
                true
            } else {
                false
            }
            steps.append(StepBuilder(kind: .render(colors: isDepth ? [] : [entry.subresource],
                                                   depth: isDepth ? entry.subresource : nil),
                                     operations: entry.operations, clears: [entry.subresource: last]))
        }
    }

    for (index, operation) in operations.enumerated() {
        switch operation {
        case .state:
            continue
        case let .clear(subresource, _):
            if let entry = pending.firstIndex(where: { $0.subresource == subresource }) {
                pending[entry].operations.append(index)
            } else {
                pending.append((subresource, [index]))
            }
        case let .draw(colors, depth, samples, _):
            materialize(Set(samples))
            let attachments = Set(operation.attachments)
            if let current = open, case let .render(openColors, openDepth) = steps[current].kind,
               openColors == colors, openDepth == depth,
               !pending.contains(where: { attachments.contains($0.subresource) }) {
                steps[current].operations.append(index)
                continue
            }
            var step = StepBuilder(kind: .render(colors: colors, depth: depth), operations: [])
            for entry in pending where attachments.contains(entry.subresource) {
                step.operations += entry.operations
                step.clears[entry.subresource] = entry.operations[entry.operations.count - 1]
            }
            pending.removeAll { attachments.contains($0.subresource) }
            step.operations.append(index)
            open = steps.count
            steps.append(step)
        case let .transfer(kind, reads, writes):
            open = nil
            materialize(Set(reads + writes))
            steps.append(StepBuilder(kind: .transfer(kind), operations: [index]))
        }
    }
    materialize(Set(pending.map(\.subresource)))
    return steps
}

/// Folds a resolve into the encoder that last rendered its source when no step in between
/// writes the source or touches the destination, so the resolve can run at encoder exit.
private func foldResolves(_ steps: inout [StepBuilder], _ operations: [Normalized], _ versions: Versioning,
                          preserving: Set<Int>) {
    var index = 0
    while index < steps.count {
        guard case let .transfer(.resolve(_, destination)) = steps[index].kind else {
            index += 1
            continue
        }
        let operation = steps[index].operations[0]
        guard !preserving.contains(operation) else {
            index += 1
            continue
        }
        let read = versions.accesses[operation].reads[0]
        let source = read.subresource
        let target = WPESubresource(destination)
        guard let producer = read.producer,
              let encoder = steps.firstIndex(where: { $0.operations.contains(producer) }),
              case let .render(colors, _) = steps[encoder].kind, colors.contains(source),
              steps[encoder].resolves[source] == nil,
              steps[(encoder + 1) ..< index].flatMap(\.operations).allSatisfy({
                  !operations[$0].writes.contains(source) && !operations[$0].touched.contains(target)
              })
        else {
            index += 1
            continue
        }
        steps[encoder].operations.append(operation)
        steps[encoder].resolves[source] = destination
        steps.remove(at: index)
    }
}

// MARK: - 5. Attachment actions

private func deriveActions(_ builders: [StepBuilder], _ operations: [Normalized], _ versions: Versioning,
                           _ table: [WPEResourceID: WPELogicalResource],
                           discardableHistory: Set<WPEResourceID>)
    -> (steps: [WPECompiledStep], downgraded: Set<WPEResourceID>) {
    struct Pending {
        var reads: [WPEResourceVersion]
        var writes: [WPESubresource: WPEResourceVersion]
        var loads: [WPESubresource: WPELoadAction] = [:]
        var exits: [WPESubresource: WPEResourceVersion] = [:]
    }

    var pending: [Pending] = []
    for builder in builders {
        let ordered = builder.operations.sorted()
        let members = Set(ordered)
        var reads: [WPEResourceVersion] = []
        var writes: [WPESubresource: WPEResourceVersion] = [:]
        for operation in ordered {
            for version in versions.accesses[operation].reads where !(version.producer.map(members.contains) ?? false) {
                if !reads.contains(version) {
                    reads.append(version)
                }
            }
            for version in versions.accesses[operation].writes {
                writes[version.subresource] = version
            }
        }
        var step = Pending(reads: reads, writes: writes)
        if case let .render(colors, depth) = builder.kind {
            for attachment in colors + [depth].compactMap(\.self) {
                guard let first = ordered.first(where: { operations[$0].touched.contains(attachment) }),
                      let entry = versions.before[first][attachment] else { continue }
                step.exits[attachment] = writes[attachment] ?? entry
                step.loads[attachment] = loadAction(attachment, entry: entry, first: operations[first],
                                                    clear: builder.clears[attachment].map { operations[$0] },
                                                    isColor: colors.contains(attachment), table: table)
                if step.loads[attachment] == .load, !step.reads.contains(entry) {
                    step.reads.append(entry)
                }
            }
        }
        pending.append(step)
    }

    var readers: [WPEResourceVersion: [Int]] = [:]
    for (index, step) in pending.enumerated() {
        for version in step.reads {
            readers[version, default: []].append(index)
        }
    }

    // Every mip is written and no step observes frame-entry contents (sample, load or transfer read).
    let downgraded = Set(table.values.filter { resource in
        resource.lifetime == .pooled
            && discardableHistory.contains(resource.id)
            && (0 ..< resource.mipCount).allSatisfy { versions.final[WPESubresource(resource.id, mip: $0)] != nil }
            && !readers.keys.contains { $0.subresource.resource == resource.id && $0.revision == 0 }
    }.map(\.id))

    let steps = zip(builders, pending).enumerated().map { index, pair in
        let (builder, step) = pair
        func action(_ attachment: WPESubresource) -> WPEAttachmentAction {
            let exit = step.exits[attachment]
            let transient = table[attachment.resource]?.lifetime == .frameTransient
                || downgraded.contains(attachment.resource)
            let needed = exit.map { exit in
                readers[exit, default: []].contains { $0 > index }
                    // A subresource never written this frame has no `final` entry; its entry version is final.
                    || (!transient && (versions.final[attachment] ?? exit) == exit)
            } ?? false
            let store: WPEStoreAction = switch (builder.resolves[attachment], needed) {
            case let (destination?, true): .storeAndMultisampleResolve(into: destination)
            case let (destination?, false): .multisampleResolve(into: destination)
            case (nil, true): .store
            case (nil, false): .dontCare
            }
            return WPEAttachmentAction(subresource: attachment, load: step.loads[attachment] ?? .dontCare, store: store)
        }
        let kind: WPECompiledStep.Kind = switch builder.kind {
        case let .transfer(kind): kind
        case let .render(colors, depth):
            .render(WPEEncoderGroup(colorAttachments: colors.map(action), depthAttachment: depth.map(action)))
        }
        return WPECompiledStep(kind: kind, operations: builder.operations.sorted(), reads: step.reads,
                               writes: step.writes.values.sorted { $0.subresource < $1.subresource })
    }
    return (steps, downgraded)
}

private func loadAction(_ attachment: WPESubresource, entry: WPEResourceVersion, first: Normalized, clear: Normalized?,
                        isColor: Bool, table: [WPEResourceID: WPELogicalResource]) -> WPELoadAction {
    if case let .clear(_, value) = clear {
        return .clear(value)
    }
    if entry.revision == 0, table[attachment.resource]?.lifetime == .frameTransient {
        return .dontCare
    }
    return isColor && overwritesBeforeReading(first) ? .dontCare : .load
}

private func overwritesBeforeReading(_ operation: Normalized) -> Bool {
    if case let .draw(_, _, _, draw) = operation {
        draw.overwritesTargets && !draw.readsDestination
    } else {
        false
    }
}

/// Every texel of `attachment` is defined by its encoder before anything observes it.
private func coveredOnEntry(_ attachment: WPEAttachmentAction, in step: WPECompiledStep,
                            _ operations: [Normalized]) -> Bool {
    if case .clear = attachment.load {
        return true
    }
    guard step.encoder?.colorAttachments.contains(attachment) == true,
          let first = step.operations.first(where: { operations[$0].touched.contains(attachment.subresource) })
    else { return false }
    return overwritesBeforeReading(operations[first])
}

// MARK: - Dependencies

private func dependencies(_ steps: [WPECompiledStep], _ stepOf: [Int: Int]) -> [WPEStepDependency] {
    var result: Set<WPEStepDependency> = []
    var lastWriter: [WPESubresource: Int] = [:]
    var readers: [WPESubresource: [Int]] = [:]
    for (index, step) in steps.enumerated() {
        for version in step.reads {
            if let producer = version.producer.flatMap({ stepOf[$0] }), producer != index {
                result.insert(WPEStepDependency(producer: producer, consumer: index,
                                                subresource: version.subresource, hazard: .readAfterWrite))
            }
        }
        for version in step.writes {
            let subresource = version.subresource
            for reader in readers[subresource, default: []] where reader != index {
                result.insert(WPEStepDependency(producer: reader, consumer: index,
                                                subresource: subresource, hazard: .writeAfterRead))
            }
            if let writer = lastWriter[subresource], writer != index {
                result.insert(WPEStepDependency(producer: writer, consumer: index,
                                                subresource: subresource, hazard: .writeAfterWrite))
            }
        }
        for version in step.reads {
            readers[version.subresource, default: []].append(index)
        }
        for version in step.writes {
            lastWriter[version.subresource] = index
            readers[version.subresource] = []
        }
    }
    return result.sorted()
}

// MARK: - 6. Physical allocation

private func lifetimes(_ steps: [WPECompiledStep]) -> [WPEResourceID: ClosedRange<Int>] {
    var result: [WPEResourceID: ClosedRange<Int>] = [:]
    for (index, step) in steps.enumerated() {
        var touched = (step.reads + step.writes).map(\.subresource.resource)
        if let encoder = step.encoder {
            touched += (encoder.colorAttachments + [encoder.depthAttachment].compactMap(\.self)).map(\.subresource.resource)
        }
        for resource in touched {
            let range = result[resource]
            result[resource] = (range?.lowerBound ?? index) ... index
        }
    }
    return result
}

private func allocate(_ steps: [WPECompiledStep], _ operations: [Normalized],
                      _ lifetimes: [WPEResourceID: ClosedRange<Int>], _ table: [WPEResourceID: WPELogicalResource],
                      _ downgraded: Set<WPEResourceID>, swapped: Set<WPEResourceID>)
    -> ([WPEResourceID: WPEResourceStorage], [[WPEResourceID]]) {
    var storage: [WPEResourceID: WPEResourceStorage] = [:]
    var scratch: [(id: WPEResourceID, range: ClosedRange<Int>)] = []
    for resource in table.values {
        if swapped.contains(resource.id) {
            storage[resource.id] = .dedicated
            continue
        }
        switch downgraded.contains(resource.id) ? .frameTransient : resource.lifetime {
        case .persistent, .pooled, .output:
            storage[resource.id] = .dedicated
        case .imported:
            storage[resource.id] = .external
        case .frameTransient:
            guard let range = lifetimes[resource.id] else { continue }
            // A single step also rules out a depth buffer shared by several encoders.
            let step = steps[range.lowerBound]
            if range.count == 1, resource.mipCount == 1, let attachment = step.encoder?.attachment(resource.id),
               coveredOnEntry(attachment, in: step, operations),
               attachment.store == .dontCare || attachment.store.isResolveOnly {
                storage[resource.id] = .memoryless
            } else {
                scratch.append((resource.id, range))
            }
        }
    }

    var groups: [[WPEResourceID]] = []
    var groupEnds: [Int] = []
    for entry in scratch.sorted(by: { ($0.range.lowerBound, $0.id) < ($1.range.lowerBound, $1.id) }) {
        let group: Int
        if let free = groupEnds.firstIndex(where: { $0 < entry.range.lowerBound }) {
            group = free
            groups[free].append(entry.id)
            groupEnds[free] = entry.range.upperBound
        } else {
            group = groups.count
            groups.append([entry.id])
            groupEnds.append(entry.range.upperBound)
        }
        storage[entry.id] = .aliased(group: group)
    }
    return (storage, groups)
}

private extension WPEStoreAction {
    var isResolveOnly: Bool {
        if case .multisampleResolve = self {
            true
        } else {
            false
        }
    }
}
