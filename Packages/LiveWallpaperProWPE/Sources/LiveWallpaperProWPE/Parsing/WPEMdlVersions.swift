import Foundation

// Per-section feature gates for the `.mdl` container. `WPEMdlParser` must not compare a version
// number against a literal — every such comparison lives here, so one file answers "which version
// has which block".
//
// The format grows by appending, so gates are open-ended ranges and both directions extrapolate:
// below the oldest sampled version every gate is false (fewer fields), above the newest one the
// highest tier applies (a prefix-compatible superset). A closed range means the block was removed
// again, and must carry its upper-bound evidence on the same line.
//
// `sampled` is only ever used to log an unrecognised version. It must not gate parsing: rejecting
// an unsampled version is how a whole section goes missing without a diagnostic.

public struct WPEMdlvFeatures: Equatable, Sendable {
    /// Mesh flags move from the file header into each mesh record.
    public let perMeshFlags: Bool
    /// Each mesh record carries an authored min/max bounding box.
    public let meshBounds: Bool
    /// Mesh records end with the uv2 + part-table sub-block.
    public let partTable: Bool
    /// The part-table sub-block is followed by a clip-mask group block.
    public let clipGroups: Bool
    /// Index buffers may use 32-bit elements; below this they are always 16-bit.
    public let wideIndices: Bool

    public static let sampled: ClosedRange<Int> = 4 ... 23

    public init(version: Int) {
        perMeshFlags = version >= 15
        meshBounds = version >= 17
        partTable = version >= 21
        clipGroups = version >= 22
        wideIndices = version >= 23
    }
}

public struct WPEMdlsFeatures: Equatable, Sendable {
    /// World-bind matrices sit inside the MDLS body. Closed because 0003+ moved them out: no
    /// sampled MDLS0002 file carries an MDLE block, while 0003/0004 files routinely do.
    public let worldBindsInSection: Bool
    /// Trailing block after the bone list. Nothing downstream reads it yet, so the parser consumes
    /// it by size; `nil` means the version has no such block.
    public let boneTable: WPEMdlsBoneTableLayout?

    public static let sampled: ClosedRange<Int> = 1 ... 4

    public init(version: Int) {
        worldBindsInSection = (2 ... 2).contains(version)
        switch version {
        case ..<2: boneTable = nil
        case 2: boneTable = WPEMdlsBoneTableLayout(headerBytes: 1, indexArrayCount: 1)
        default: boneTable = WPEMdlsBoneTableLayout(headerBytes: 12, indexArrayCount: 2)
        }
    }
}

/// MDLS trailing block: a per-bone transform array, then `indexArrayCount` bone-index arrays that
/// each carry their own one-byte present flag. Array 0 is a permutation of the bone indices.
public struct WPEMdlsBoneTableLayout: Equatable, Sendable {
    /// `float3` followed by a row-major affine 4x4.
    public static let transformBytes = 3 * MemoryLayout<Float>.size + 16 * MemoryLayout<Float>.size

    public let headerBytes: Int
    public let indexArrayCount: Int

    public func byteCount(boneCount: Int) -> Int {
        headerBytes
            + boneCount * Self.transformBytes
            + indexArrayCount * (1 + boneCount * MemoryLayout<UInt32>.size)
    }
}

public struct WPEMdlaFeatures: Equatable, Sendable {
    /// Per-animation translation track block, then the blend-curve block.
    public let transBlock: Bool
    /// One-byte discriminator followed by the v4 event list.
    public let v4Events: Bool
    /// Six floats of animation-space AABB.
    public let boundingBox: Bool
    /// A second curve block after the AABB.
    public let scalarCurves: Bool

    public static let sampled: ClosedRange<Int> = 1 ... 6

    public init(version: Int) {
        transBlock = version >= 3
        v4Events = version >= 4
        boundingBox = version >= 5
        scalarCurves = version >= 6
    }
}
