public struct WPESubresource: Hashable, Comparable, Sendable {
    public let resource: WPEResourceID
    public let mip: Int

    public init(_ resource: WPEResourceID, mip: Int = 0) {
        self.resource = resource
        self.mip = mip
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.resource, lhs.mip) < (rhs.resource, rhs.mip)
    }
}

public struct WPEResourceVersion: Hashable, Sendable {
    public let subresource: WPESubresource
    /// Revision 0 is the content at frame entry: history for persistent resources, undefined for transients.
    public let revision: Int
    /// Index into `WPECompiledRenderGraph.operations`; `nil` for frame-entry content.
    public let producer: Int?
}

public struct WPEOperationAccess: Hashable, Sendable {
    public let reads: [WPEResourceVersion]
    public let writes: [WPEResourceVersion]
}

public enum WPEClearValue: Hashable, Sendable {
    case color(WPEClearColor)
    case depth(Double)
}

public enum WPELoadAction: Hashable, Sendable {
    case load
    case clear(WPEClearValue)
    case dontCare
}

public enum WPEStoreAction: Hashable, Sendable {
    case store
    case dontCare
    case multisampleResolve(into: WPEResourceID)
    case storeAndMultisampleResolve(into: WPEResourceID)
}

public struct WPEAttachmentAction: Hashable, Sendable {
    public let subresource: WPESubresource
    public let load: WPELoadAction
    public let store: WPEStoreAction
}

public struct WPEEncoderGroup: Hashable, Sendable {
    public let colorAttachments: [WPEAttachmentAction]
    public let depthAttachment: WPEAttachmentAction?

    public func attachment(_ resource: WPEResourceID) -> WPEAttachmentAction? {
        (colorAttachments + [depthAttachment].compactMap(\.self)).first { $0.subresource.resource == resource }
    }
}

public struct WPECompiledStep: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        /// One render encoder; folded clears and resolves are expressed by its attachment actions.
        case render(WPEEncoderGroup)
        case copy(source: WPEResourceID, destination: WPEResourceID)
        case generateMips(WPEResourceID)
        case resolve(source: WPEResourceID, destination: WPEResourceID)
    }

    public let kind: Kind
    /// Indices into `WPECompiledRenderGraph.operations`, in authored order; `setTargets` never appears.
    public let operations: [Int]
    /// Versions produced before this step that it observes, including attachment loads.
    public let reads: [WPEResourceVersion]
    /// Last version of each subresource this step writes.
    public let writes: [WPEResourceVersion]

    public var encoder: WPEEncoderGroup? {
        if case let .render(group) = kind {
            group
        } else {
            nil
        }
    }
}

public struct WPEStepDependency: Hashable, Comparable, Sendable {
    public enum Hazard: Int, Hashable, Comparable, Sendable {
        case readAfterWrite, writeAfterRead, writeAfterWrite

        public static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    public let producer: Int
    public let consumer: Int
    public let subresource: WPESubresource
    public let hazard: Hazard

    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.consumer, lhs.producer, lhs.subresource, lhs.hazard) < (rhs.consumer, rhs.producer, rhs.subresource, rhs.hazard)
    }
}

public enum WPEResourceStorage: Hashable, Sendable {
    /// Tile memory only: every access is as an attachment of one encoder and nothing survives it.
    case memoryless
    /// Frame scratch that may share memory with the other members of `allocationGroups[group]`.
    case aliased(group: Int)
    /// Persistent or output storage that is never shared.
    case dedicated
    case external
}

public struct WPECompiledRenderGraph: Hashable, Sendable {
    public let resources: [WPEResourceID: WPELogicalResource]
    public let operations: [WPERenderOperation]
    /// Parallel to `operations`.
    public let accesses: [WPEOperationAccess]
    public let steps: [WPECompiledStep]
    public let dependencies: [WPEStepDependency]
    /// Inclusive step-index range over which each accessed resource must hold its contents.
    public let lifetimes: [WPEResourceID: ClosedRange<Int>]
    /// Unaccessed frame-transient resources have no entry.
    public let storage: [WPEResourceID: WPEResourceStorage]
    /// Members of one group have pairwise disjoint lifetimes.
    public let allocationGroups: [[WPEResourceID]]

    public var encoders: [WPEEncoderGroup] {
        steps.compactMap(\.encoder)
    }
}
