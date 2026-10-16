import Foundation

/// Script-created model indices retain their native width.
public struct WPEParityModelDataIndices: Equatable, Sendable {
    public let data: Data
    public let elementWidth: WPEPuppetIndexElementWidth
    public var count: Int {
        data.count / elementWidth.rawValue
    }

    public init(data: Data, elementWidth: WPEPuppetIndexElementWidth) {
        self.data = data
        self.elementWidth = elementWidth
    }
}

public struct WPEParityModelDataShapePatch: Equatable, Sendable {
    public enum Indices: Equatable, Sendable {
        case unchanged, remove
        case buffer(WPEParityModelDataIndices)
    }

    public var remove = false
    /// Exact Float32Array view bytes; no conversion through Double, JSON or another vertex array.
    public var vertices: Data?
    /// Native format mask; zero means unspecified in a partial update.
    public var vertexFormat: UInt32 = 0
    public var indices: Indices = .unchanged
    /// Resolved native filename bytes, including native length/C-string admission by the resource provider.
    public var material: Data?
    public var isVertexBufferDynamic: Bool?
    public var isIndexBufferDynamic: Bool?

    public init() {}

    /// The same immutable PE-table layout already consumed by the parity frame planner.
    public var vertexStream: WPEPuppetVertexStream? {
        guard let vertices, vertexFormat != 0 else { return nil }
        let layout = WPEPuppetVertexLayout(format: vertexFormat, synthesizesMissingPosition: false)
        return WPEPuppetVertexStream(data: vertices, layout: layout)
    }
}

public struct WPEParityModelDataPatch: Equatable, Sendable {
    public let shapes: [WPEParityModelDataShapePatch]
    public let bounds: WPEPuppetMeshBounds?

    public init(shapes: [WPEParityModelDataShapePatch], bounds: WPEPuppetMeshBounds?) {
        self.shapes = shapes
        self.bounds = bounds
    }
}
