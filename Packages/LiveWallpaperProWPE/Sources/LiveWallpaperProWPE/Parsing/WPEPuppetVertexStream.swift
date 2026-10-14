import Foundation

/// One input element of WPE's MDLV vertex-format table. Offsets follow table order, not bit order.
public struct WPEPuppetVertexAttribute: Hashable, Sendable {
    public enum ComponentType: Hashable, Sendable {
        case float32
        case uint32
    }

    public let flag: UInt32
    public let semantic: String
    public let semanticIndex: Int
    public let byteOffset: Int
    public let componentType: ComponentType
    public let componentCount: Int
    public var byteSize: Int {
        componentCount * 4
    }
}

/// Immutable layout built once while loading a mesh. All 26 input elements come from the native PE tables
/// at 0x140482af0 (descriptors), 0x140484a20 (flags), and 0x1404849b0 (sizes).
public struct WPEPuppetVertexLayout: Hashable, Sendable {
    public let format: UInt32
    /// Compatibility for old synthetic MDLs without either POSITION0 bit; real authored layouts retain all bits.
    public let hasSyntheticPosition: Bool
    public let attributes: [WPEPuppetVertexAttribute]
    public let stride: Int
    /// Unknown bits are exposed for readiness diagnostics; they are not silently claimed as supported inputs.
    public var unsupportedFlags: UInt32 {
        format & ~0x03FF_FFFF
    }

    public init(format: UInt32, synthesizesMissingPosition: Bool = true) {
        self.format = format
        hasSyntheticPosition = synthesizesMissingPosition && format & 0x10001 == 0
        let effective = hasSyntheticPosition ? format | 1 : format
        var attributes: [WPEPuppetVertexAttribute] = []
        var offset = 0
        for element in Self.elements where effective & element.flag != 0 {
            attributes.append(.init(flag: element.flag, semantic: element.semantic, semanticIndex: element.index,
                                    byteOffset: offset, componentType: element.type, componentCount: element.count))
            offset += element.count * 4
        }
        self.attributes = attributes
        stride = offset
    }

    /// Duplicate authored elements are retained. Consumers must reject ambiguous semantics instead of inventing
    /// which POSITION0 or TEXCOORD variant wins.
    public func attributes(semantic: String, index: Int) -> [WPEPuppetVertexAttribute] {
        attributes.filter { $0.semantic.caseInsensitiveCompare(semantic) == .orderedSame && $0.semanticIndex == index }
    }

    private struct Element {
        let flag: UInt32
        let semantic: String
        let index: Int
        let type: WPEPuppetVertexAttribute.ComponentType
        let count: Int

        init(_ flag: UInt32, _ semantic: String, _ index: Int, _ count: Int,
             _ type: WPEPuppetVertexAttribute.ComponentType = .float32) {
            self.flag = flag
            self.semantic = semantic
            self.index = index
            self.type = type
            self.count = count
        }
    }

    private static let elements: [Element] = [
        .init(0x1, "POSITION", 0, 3), .init(0x10000, "POSITION", 0, 4),
        .init(0x2000000, "POSITION", 1, 3), .init(0x2, "NORMAL", 0, 3), .init(0x4, "TANGENT", 0, 4),
        .init(0x800000, "BLENDINDICES", 0, 4, .uint32), .init(0x1000000, "BLENDWEIGHT", 0, 4),
        .init(0x8, "TEXCOORD", 0, 2), .init(0x10, "TEXCOORD", 0, 3), .init(0x20, "TEXCOORD", 0, 4),
        .init(0x40, "TEXCOORD", 1, 2), .init(0x80, "TEXCOORD", 1, 3), .init(0x100, "TEXCOORD", 1, 4),
        .init(0x200, "TEXCOORD", 2, 2), .init(0x400, "TEXCOORD", 2, 3), .init(0x800, "TEXCOORD", 2, 4),
        .init(0x1000, "TEXCOORD", 3, 2), .init(0x2000, "TEXCOORD", 3, 3), .init(0x4000, "TEXCOORD", 3, 4),
        .init(0x20000, "TEXCOORD", 4, 2), .init(0x40000, "TEXCOORD", 4, 3), .init(0x80000, "TEXCOORD", 4, 4),
        .init(0x100000, "TEXCOORD", 5, 2), .init(0x200000, "TEXCOORD", 5, 3), .init(0x400000, "TEXCOORD", 5, 4),
        .init(0x8000, "COLOR", 0, 4),
    ]
}

/// The exact authored vertex bytes. Typed legacy vertices remain available without replacing shader inputs.
public struct WPEPuppetVertexStream: Hashable, Sendable {
    public let data: Data
    public let layout: WPEPuppetVertexLayout
    public var vertexCount: Int {
        layout.stride == 0 ? 0 : data.count / layout.stride
    }

    public init(data: Data, layout: WPEPuppetVertexLayout) {
        self.data = data
        self.layout = layout
    }
}

/// MDLV21's optional companion block, preserved without assigning unproved TEXCOORD or morph semantics.
public struct WPEPuppetMeshCompanion: Equatable, Sendable {
    public let hasPayload: UInt8
    public let headerWord: UInt16?
    public let headerByte: UInt8?
    public let declaredByteCount: UInt32?
    public let data: Data
}
