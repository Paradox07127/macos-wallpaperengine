import Foundation
import simd

/// Per-frame scene inputs of a particle object; the defaults leave every control point at its offset.
public struct WPEParityParticleFrameContext: Sendable {
    /// Scene time in seconds (ctx+0x130): turbulence, turbulentvelocityrandom and positionoffsetrandom read it.
    public var time: Float
    /// ctx+0x150 = renderer+0x160: the previous global frame interval, independent of instance/prewarm dt.
    /// Construction seeds it with 1/30; the renderer's first ordinary update publishes its prior current dt (0).
    public var previousFrametime: Float
    /// Cursor in [0, 1]², y down; nil leaves cursor-following control points where they are.
    public var cursor: SIMD2<Float>?
    public var viewProjection: simd_float4x4
    /// Owner W at the public frame boundary; each System resolves its own update-stack U before simulation.
    public var objectMatrix: simd_float4x4
    /// Owner layer world translation, unchanged when a child resolves its update-stack U (native layerorigin).
    public var layerOrigin: SIMD3<Float>
    /// Particles simulate in world space rather than in the object's space.
    public var worldSpace: Bool
    /// ctx+0x140, the remap "timeofday" input, supplied from the same frame clock as `time`.
    public var timeOfDay: Float

    public init(
        time: Float = 0,
        cursor: SIMD2<Float>? = nil,
        viewProjection: simd_float4x4 = matrix_identity_float4x4,
        objectMatrix: simd_float4x4 = matrix_identity_float4x4,
        timeOfDay: Float = 0,
        previousFrametime: Float = Float(bitPattern: 0x3D08_8889)
    ) {
        self.time = time
        self.previousFrametime = previousFrametime
        self.cursor = cursor
        self.viewProjection = viewProjection
        self.objectMatrix = objectMatrix
        layerOrigin = SIMD3(objectMatrix.columns.3.x, objectMatrix.columns.3.y, objectMatrix.columns.3.z)
        worldSpace = false
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

    var controlPointCount: Int {
        bulkControlPointStart == nil ? config.controlPointCount : 8
    }

    /// 22c3c0 initializes authored current/base before constructing children; 22ebe0 seeds history later.
    mutating func initializeControlPoints() {
        for index in controlPoints.indices {
            let point = config.controlPoints[index]
            controlPointBases[index] = Self.translation(point.offset)
            if point.flags & 0x10005 == 0 {
                rebuildControlPointBase(index)
            }
            controlPoints[index] = controlPointBases[index]
            previousControlPoints[index] = controlPoints[index]
        }
        controlPointsSeeded = false
    }

    /// Native CP+0x40 stores all four columns only after operators (or the explicit fresh seed).
    mutating func commitControlPointHistory() {
        for index in 0 ..< controlPointCount {
            previousControlPoints[index] = controlPoints[index]
        }
        controlPointsSeeded = true
    }

    /// The property hook writes base/current for ordinary points without committing the previous matrix.
    mutating func applyControlPointInstance() {
        for index in 0 ..< controlPointCount where config.controlPoints[index].flags & 0x10005 == 0 {
            let offset = instance.controlPointOffsets[index]
            let angles = instance.controlPointAngles[index]
            // 22bd40: both sentinel means no write, including a current changed by a remap operator.
            guard offset != nil || angles != nil else { continue }
            if let angles {
                let rotation = Self.instanceControlPointTransform(offset: .zero, angles: angles)
                for column in 0 ..< 3 {
                    for row in 0 ..< 3 {
                        controlPointBases[index][column][row] = rotation[column][row]
                    }
                }
            }
            if let offset {
                controlPointBases[index].columns.3 = SIMD4(offset, controlPointBases[index].columns.3.w)
            }
            controlPoints[index] = controlPointBases[index]
            updateOrdinaryControlPoint(index)
        }
    }

    private mutating func rebuildControlPointBase(_ index: Int) {
        controlPointBases[index] = Self.instanceControlPointTransform(
            offset: instance.controlPointOffsets[index] ?? config.controlPoints[index].offset,
            angles: instance.controlPointAngles[index] ?? .zero
        )
    }

    private mutating func updateOrdinaryControlPoint(_ index: Int) {
        let flags = config.controlPoints[index].flags
        if frameContext.worldSpace {
            if flags & 2 == 0 || index == 0 {
                controlPoints[index] = frameContext.objectMatrix * controlPointBases[index]
            }
        } else if flags & 2 != 0 {
            controlPoints[index] = frameContext.objectMatrix.inverse * controlPointBases[index]
        }
    }

    /// 22e3e0: frozen > cursor > parent-copy > ordinary. Up is the stack entry before this child's push.
    mutating func updateControlPoints(parent: [simd_float4x4]?, parentCount: Int = 0,
                                      parentUpdateMatrix: simd_float4x4 = matrix_identity_float4x4,
                                      parentWorldSpace: Bool = false) {
        let frame = frameContext
        for index in 0 ..< controlPointCount {
            let point = config.controlPoints[index]
            if point.flags & 0x10000 != 0 {
                continue
            }
            if point.flags & 1 != 0 {
                guard let cursor = frame.cursor else { continue }
                var world = frame.viewProjection.inverse * SIMD4<Float>(2 * cursor.x - 1, 1 - 2 * cursor.y, 0, 1)
                world /= world.w
                world.z = 0
                if !frame.worldSpace {
                    world = frame.objectMatrix.inverse * world
                }
                var current = controlPointBases[index]
                current.columns.3.x = world.x
                current.columns.3.y = world.y
                current.columns.3.z = world.z
                controlPoints[index] = current
            } else if point.flags & 4 != 0 {
                guard let parent, point.parent < parentCount, parent.indices.contains(point.parent) else {
                    updateOrdinaryControlPoint(index)
                    continue
                }
                let source = parent[point.parent]
                if point.flags & 8 != 0 || frame.worldSpace && parentWorldSpace {
                    controlPoints[index] = source
                } else if frame.worldSpace {
                    controlPoints[index] = parentUpdateMatrix * source
                } else {
                    controlPoints[index] = frame.objectMatrix.inverse
                        * (parentWorldSpace ? source : parentUpdateMatrix * source)
                }
            } else if bulkControlPointStart.map({ index >= $0 }) != true {
                updateOrdinaryControlPoint(index)
            }
        }
    }

    /// 22a580 runs under the parent U before a child update push. A special target does not advance the index.
    mutating func copyBulkControlPoints(positions: [SIMD3<Float>], lifetimes: [Float], highWater: Int,
                                        parentUpdateMatrix: simd_float4x4, parentWorldSpace: Bool) {
        guard var target = bulkControlPointStart else { return }
        let world = config.flags & 1 != 0
        let mapping = parentWorldSpace == world ? matrix_identity_float4x4
            : (world ? parentUpdateMatrix : parentUpdateMatrix.inverse)
        for slot in 0 ..< highWater where lifetimes[slot] != 0 {
            guard target < 8 else { break }
            guard config.controlPoints[target].flags & 0x10005 == 0 else { continue }
            let point = mapping * SIMD4(positions[slot], 1)
            controlPoints[target].columns.3.x = point.x
            controlPoints[target].columns.3.y = point.y
            controlPoints[target].columns.3.z = point.z
            target += 1
        }
    }

    /// Conditional 229760 for fresh/event, unconditional 229810 for normal static descendants.
    mutating func setUpdateFrame(_ frame: WPEParityParticleFrameContext,
                                 parentUpdateMatrix: simd_float4x4, conditional: Bool) {
        frameContext = frame
        frameContext.worldSpace = config.flags & 1 != 0
        frameContext.objectMatrix = conditional && frameContext.worldSpace
            ? instanceTransform : parentUpdateMatrix * instanceTransform
    }

    func eventTransform(_ child: WPEParityParticleChildConfig, position: SIMD3<Float>) -> simd_float4x4 {
        let base = Self.translation(position) * Self.childTransform(child)
        let parentWorld = config.flags & 1 != 0, childWorld = child.config.flags & 1 != 0
        if parentWorld == childWorld {
            return base
        }
        return (childWorld ? frameContext.objectMatrix : frameContext.objectMatrix.inverse) * base
    }

    /// Authored child angles are radians; B = T * Rz * Ry * Rx * S.
    static func childTransform(_ child: WPEParityParticleChildConfig) -> simd_float4x4 {
        var base = instanceControlPointTransform(offset: child.origin, angles: child.anglesRadians)
        base.columns.0 *= child.scale.x
        base.columns.1 *= child.scale.y
        base.columns.2 *= child.scale.z
        return base
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
