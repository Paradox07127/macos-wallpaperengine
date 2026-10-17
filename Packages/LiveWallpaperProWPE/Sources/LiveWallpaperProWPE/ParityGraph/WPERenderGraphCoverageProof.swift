/// What the caller established about one draw beyond its operation, which already carries blending and depth.
public struct WPEDrawCoverage: Hashable, Sendable {
    /// Encoding never skips the draw (readiness, visibility, zero instances).
    public let alwaysExecutes: Bool
    /// The vertex stage emits the unmodified full-target quad, and viewport and scissor span the whole target.
    public let fullscreenGeometry: Bool
    /// The fragment stage contains discard or clip.
    public let mayDiscard: Bool
    /// No sample mask or alpha-to-coverage drops samples.
    public let writesEverySample: Bool

    public init(alwaysExecutes: Bool, fullscreenGeometry: Bool, mayDiscard: Bool, writesEverySample: Bool) {
        self.alwaysExecutes = alwaysExecutes
        self.fullscreenGeometry = fullscreenGeometry
        self.mayDiscard = mayDiscard
        self.writesEverySample = writesEverySample
    }

    /// Every texel of every bound color target is written without being read.
    func covers(_ draw: WPEDrawOperation) -> Bool {
        // Blending, alphaMax and partial write masks reach the operation as `readsDestination`.
        alwaysExecutes && fullscreenGeometry && !mayDiscard && writesEverySample
            && !draw.readsDestination && !draw.depthTest
    }
}

/// Caller facts the compiler needs before it may drop the frame-entry history of a pooled target.
public struct WPERenderGraphCoverageProof: Hashable, Sendable {
    /// Operation index -> facts about that draw.
    public let draws: [Int: WPEDrawCoverage]
    /// Operation index -> the layer it renders for; unowned operations belong to no layer.
    public let owners: [Int: String]

    public init(draws: [Int: WPEDrawCoverage] = [:], owners: [Int: String] = [:]) {
        self.draws = draws
        self.owners = owners
    }

    func coveringDraws(_ operations: [WPERenderOperation]) -> Set<Int> {
        Set(draws.compactMap { index, facts in
            guard operations.indices.contains(index), case let .draw(draw) = operations[index].kind,
                  facts.covers(draw) else { return nil }
            return index
        })
    }
}

/// Which pooled targets may lose their history across frames and graph rebuilds. The compiler still requires that
/// every mip is written and nothing in the frame observes the entry contents.
enum WPEPooledHistoryRules {
    /// `firstTouchedByDraw`: resources whose first access this frame is a draw (attachment or sample).
    static func discardable(_ requested: Set<WPEResourceID>, _ table: [WPEResourceID: WPELogicalResource],
                            swapped: Set<WPEResourceID>, firstTouchedByDraw: Set<WPEResourceID>,
                            ownerTouches: [String: Set<WPEResourceID>]) -> Set<WPEResourceID> {
        // An effect toggle flips which composite of a ping-pong pair is drawn first and then reads its history.
        let pingPong = ownerTouches.values.map { $0.filter(isPooledComposite) }.filter { $0.count >= 2 }
        return requested.subtracting(swapped).subtracting(pingPong.joined()).filter { id in
            guard let resource = table[id], resource.lifetime == .pooled, !keepsHistory(resource) else { return false }
            // A composite filled by albedo or by the pass before it may be first-drawn in another graph.
            return !(isPooledComposite(id) && firstTouchedByDraw.contains(id))
        }
    }

    /// Engine snapshots and layer composites outlive the draws of one graph; an authored clear is applied once.
    static func keepsHistory(_ resource: WPELogicalResource) -> Bool {
        let name = resource.id.rawValue
        return resource.initialClear != nil || resource.id == WPEParitySceneResource.fullFrameBuffer
            || name == "_rt_MipMappedFrameBuffer"
            || (name.hasPrefix("_rt_imageLayerComposite_") && name.hasSuffix("_a"))
    }

    static func isPooledComposite(_ id: WPEResourceID) -> Bool {
        id.rawValue.hasPrefix("sc.")
    }
}
