import Foundation
import simd

/// Per-frame scene inputs of a particle object; the defaults leave every control point at its offset.
public struct WPEParityParticleFrameContext: Sendable {
    /// Scene time in seconds (ctx+0x130): turbulence, turbulentvelocityrandom and positionoffsetrandom read it.
    public var time: Float
    /// Cursor in [0, 1]², y down; nil leaves cursor-following control points where they are.
    public var cursor: SIMD2<Float>?
    public var viewProjection: simd_float4x4
    /// The particle object's model matrix.
    public var objectMatrix: simd_float4x4
    /// Particles simulate in world space rather than in the object's space.
    public var worldSpace: Bool
    /// ctx+0x140, the remap "timeofday" input, supplied from the same frame clock as `time`.
    public var timeOfDay: Float

    public init(
        time: Float = 0,
        cursor: SIMD2<Float>? = nil,
        viewProjection: simd_float4x4 = matrix_identity_float4x4,
        objectMatrix: simd_float4x4 = matrix_identity_float4x4,
        worldSpace: Bool = false,
        timeOfDay: Float = 0
    ) {
        self.time = time
        self.cursor = cursor
        self.viewProjection = viewProjection
        self.objectMatrix = objectMatrix
        self.worldSpace = worldSpace
        self.timeOfDay = timeOfDay
    }
}

/// One `controlpoint` entry (B:10155-10176).
struct WPEParityParticleControlPoint: Equatable, Sendable {
    static let count = 8

    var offset: SIMD3<Float> = .zero
    var flags = 0
    var parent = 0
}

extension WPEParityParticleSystem {
    func controlPointTranslation(_ index: Int) -> SIMD3<Float> {
        let column = controlPoints[index].columns.3
        return SIMD3(column.x, column.y, column.z)
    }

    func controlPointBasis(_ index: Int) -> simd_float3x3 {
        let matrix = controlPoints[index]
        func axis(_ column: SIMD4<Float>) -> SIMD3<Float> {
            SIMD3(column.x, column.y, column.z)
        }
        return simd_float3x3(axis(matrix.columns.0), axis(matrix.columns.1), axis(matrix.columns.2))
    }

    func previousControlPointTranslation(_ index: Int) -> SIMD3<Float> {
        let column = previousControlPoints[index].columns.3
        return SIMD3(column.x, column.y, column.z)
    }

    /// Native CP+0x40 stores all four columns after operators, not just a translation during CP update.
    mutating func commitControlPointHistory() {
        for index in controlPoints.indices {
            previousControlPoints[index] = controlPoints[index]
        }
        controlPointsSeeded = true
    }

    /// R19 控制点: 0x10000 frozen, 1 follows the cursor, 4 copies the parent system's point, else the offset
    /// (flags 2: a world-space offset). Operators read history until the simulation commits it.
    mutating func updateControlPoints(parent: [simd_float4x4]?) {
        let frame = frameContext
        let objectInverse = frame.objectMatrix.inverse
        for (index, point) in config.controlPoints.enumerated() {
            if point.flags & 0x10000 != 0 {
                // Frozen.
            } else if point.flags & 1 != 0 {
                if let cursor = frame.cursor {
                    let ndc = SIMD4<Float>(2 * cursor.x - 1, 1 - 2 * cursor.y, 0, 1)
                    var world = frame.viewProjection.inverse * ndc
                    world /= world.w
                    // Native unprojection retains only x/y; z=0 precedes the object-space conversion.
                    world.z = 0
                    if !frame.worldSpace {
                        world = objectInverse * world
                    }
                    controlPoints[index] = Self.translation(SIMD3(world.x, world.y, world.z))
                }
            } else if point.flags & 4 != 0 {
                if let parent, parent.indices.contains(point.parent) {
                    controlPoints[index] = parent[point.parent]
                }
            } else {
                // The instance hook only overrides ordinary points, not frozen/cursor/parent-copy points.
                // Angles are radians with no descriptor degree conversion (14024d940; 14022bd40:120–149).
                var base = instanceControlPointRotations[index]
                base.columns.3 = SIMD4(instance.controlPointOffsets[index] ?? point.offset, 1)
                if point.flags & 2 != 0 {
                    controlPoints[index] = frame.worldSpace ? base : objectInverse * base
                } else {
                    controlPoints[index] = frame.worldSpace ? frame.objectMatrix * base : base
                }
            }
        }
        if !controlPointsSeeded { commitControlPointHistory() }
    }

    static func translation(_ offset: SIMD3<Float>) -> simd_float4x4 {
        var matrix = matrix_identity_float4x4
        matrix.columns.3 = SIMD4(offset, 1)
        return matrix
    }

    /// Rz * Ry * Rx, with the basis and translation laid out as 14022bd40 writes the local CP matrix.
    static func instanceControlPointTransform(offset: SIMD3<Float>, angles: SIMD3<Float>) -> simd_float4x4 {
        guard angles != .zero else { return translation(offset) }
        let (sx, cx) = (sin(angles.x), cos(angles.x))
        let (sy, cy) = (sin(angles.y), cos(angles.y))
        let (sz, cz) = (sin(angles.z), cos(angles.z))
        return simd_float4x4(
            SIMD4(cy * cz, cy * sz, -sy, 0),
            SIMD4(sy * cz * sx - cx * sz, sy * sz * sx + cx * cz, sx * cy, 0),
            SIMD4(cx * cz * sy + sx * sz, cx * sz * sy - sx * cz, cx * cy, 0),
            SIMD4(offset, 1)
        )
    }
}
